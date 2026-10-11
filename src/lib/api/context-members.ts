import type { ContextMemberChange, ContextMemberOutcome, ContextMemberWritten } from "@/lib/context/member-writes";

import {
  contextMemberMoveRequestSchema,
  contextMembershipWriteRequestSchema,
  type ContextMemberMoveResponse,
  type ContextMembershipEffect,
  type ContextMembershipResponse,
} from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

// /api/v2/contexts/{id}/members 처리 (구현 계획 S3b): 사용자가 ProjectLink에서 할 일을 범위에 넣기 · 빼기 · 옮기기 · Undo (origin user).
// 인증 · gate · 쓰기를 인자로 받아 Route Handler 밖에서 테스트한다. 읽기(범위 목록 · 범위 version · 지금 멤버)는 앱이 Supabase에서 직접 한다 (RLS, work_contexts · context_members select).
// gate MEMORY_ENABLED(범위 기능)가 꺼져 있으면 404: 인증 · DB를 부르지 않는다. AI를 부르지 않고 run · Action · 정책을 만들지 않는다 (멤버십은 권한이 아니다, D13).
// 조건부 쓰기: 요청이 본 범위 version(expected_context_version, 옮기기는 expected_from_context_version도)이 지금과 다르면 쓰기 0 + 409 conflict.
// 옛 요청(응답을 잃은 재전송 · 오래 열린 화면 · 늦은 Undo)이 더 새 사용자 결정을 덮지 못한다. 새 멱등성 저장소는 없다: 응답을 잃은 성공 요청의 재전송도 409일 수 있고
// 앱은 409를 성공으로 보지 않고 다시 읽는다. version은 범위 전체의 신호라 무관한 변경에도 올라 거짓 409가 생길 수 있다.
// 응답: 200 { member, context_version, change } (옮기기는 { member, from_member, context_version, from_context_version, change }) · 404 gate 꺼짐 · 잘못된 id ·
// 남의/없는/보관된 범위 · 남의/없는 할 일 · 409 conflict · 400 잘못된 본문 · S3b가 받지 않는 멤버 종류(source · person) · 같은 범위로 옮기기.
// change = 실제로 바뀐 것(added/removed 범위와 그 쓰기 직후 version): Undo는 이 변화의 역연산만 보낸다.

const NOT_FOUND_CONTEXT = "범위가 없습니다.";
const NOT_FOUND_ACTION = "할 일이 없습니다.";
const CONFLICT = "그 사이 범위가 바뀌었습니다. 다시 불러온 뒤 시도해 주세요.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type AppUser = { user: { id: string } };

type BaseDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
};

export type ChangeContextMemberDeps<User extends AppUser> = BaseDeps<User> & {
  change: (user: User, change: ContextMemberChange) => Promise<ContextMemberOutcome>;
};

function failure(outcome: Exclude<ContextMemberOutcome, { status: "ok" }>): Response {
  if (outcome.status === "conflict") return errorResponse(409, "conflict", CONFLICT);
  return errorResponse(404, "not_found", outcome.status === "context_not_found" ? NOT_FOUND_CONTEXT : NOT_FOUND_ACTION);
}

function internalError(event: string, error: unknown): Response {
  // 오류 이름 · DB 오류 코드만 (요청의 id도 남기지 않는다)
  const code = typeof (error as { code?: unknown } | null)?.code === "string" ? (error as { code: string }).code : undefined;
  console.error(JSON.stringify({ event, error: error instanceof Error ? error.name : "unknown", code }));
  return errorResponse(500, "internal_error", "범위를 바꾸지 못했습니다.");
}

/** 실제 변화: 확인된 멤버가 바뀐 범위만 (그 범위의 쓰기 직후 version과 함께) */
function effectOf(added: ContextMemberWritten | null, removed: ContextMemberWritten | null): ContextMembershipEffect {
  const entry = (written: ContextMemberWritten) => ({ context_id: written.member.context_id, context_version: written.contextVersion });
  return { added: added?.changed ? [entry(added)] : [], removed: removed?.changed ? [entry(removed)] : [] };
}

/**
 * POST /api/v2/contexts/{id}/members — { op: "add" | "remove", member_kind: "action", member_id, expected_context_version }.
 * add = 그 범위에 origin user 멤버(auto · inferred 행이면 user로 승격, 사용자가 뺀 행이면 되살림), remove = 행을 남기고 removed_at(자동 규칙이 다시 넣지 못한다).
 * 요청이 본 version이 지금과 다르면 409(쓰기 0). 내 active 범위 · 내 할 일만(아니면 404)
 */
export async function handleChangeContextMember<User extends AppUser>(request: Request, contextId: string, deps: ChangeContextMemberDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(contextId)) return errorResponse(404, "not_found", NOT_FOUND_CONTEXT);
  const body = await parseBody(request, contextMembershipWriteRequestSchema);
  if ("error" in body) return body.error;
  try {
    const target = { contextId, expectedVersion: body.data.expected_context_version };
    const outcome = await deps.change(user, { actionId: body.data.member_id, ...(body.data.op === "add" ? { add: target } : { remove: target }) });
    if (outcome.status !== "ok") return failure(outcome);
    const result = outcome.added ?? outcome.removed;
    if (!result) return internalError("context_member_failed", new Error("NoResult"));
    return Response.json({ member: result.member, context_version: result.contextVersion, change: effectOf(outcome.added, outcome.removed) } satisfies ContextMembershipResponse);
  } catch (error) {
    return internalError("context_member_failed", error);
  }
}

export type MoveContextMemberDeps<User extends AppUser> = ChangeContextMemberDeps<User>;

/**
 * POST /api/v2/contexts/{to}/members/move — { member_kind: "action", member_id, from_context_id, expected_context_version, expected_from_context_version }.
 * 한 트랜잭션에서 from 범위에서 빼고(removed_at) 경로의 범위에 넣는다(origin user). 전체 교체가 아니다: 그 할 일의 다른 범위 멤버십은 그대로.
 * 두 범위가 모두 내 active 범위이고 할 일이 내 것일 때만 쓴다(하나라도 아니면 404, 아무것도 쓰지 않는다). 두 version 중 하나라도 다르면 409(쓰기 0).
 * 같은 범위로는 옮기지 않는다(400). change로 실제 변화를 알린다: 이미 멤버였던 도착 범위는 added에 없다
 */
export async function handleMoveContextMember<User extends AppUser>(request: Request, toContextId: string, deps: MoveContextMemberDeps<User>): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(toContextId)) return errorResponse(404, "not_found", NOT_FOUND_CONTEXT);
  const body = await parseBody(request, contextMemberMoveRequestSchema);
  if ("error" in body) return body.error;
  if (body.data.from_context_id.toLowerCase() === toContextId.toLowerCase()) return errorResponse(400, "invalid_request", "같은 범위로는 옮길 수 없습니다.");
  try {
    const outcome = await deps.change(user, {
      actionId: body.data.member_id,
      add: { contextId: toContextId, expectedVersion: body.data.expected_context_version },
      remove: { contextId: body.data.from_context_id, expectedVersion: body.data.expected_from_context_version },
    });
    if (outcome.status !== "ok") return failure(outcome);
    if (!outcome.added || !outcome.removed) return internalError("context_member_move_failed", new Error("NoResult"));
    return Response.json({
      member: outcome.added.member,
      from_member: outcome.removed.member,
      context_version: outcome.added.contextVersion,
      from_context_version: outcome.removed.contextVersion,
      change: effectOf(outcome.added, outcome.removed),
    } satisfies ContextMemberMoveResponse);
  } catch (error) {
    return internalError("context_member_move_failed", error);
  }
}
