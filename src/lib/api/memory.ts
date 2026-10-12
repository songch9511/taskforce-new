import type { z } from "zod";

import type { MemoryWriteOutcome } from "@/lib/context/memory-edit";

import {
  memoryConfirmRequestSchema,
  memoryEditRequestSchema,
  memoryForgetRequestSchema,
  memoryScopeRequestSchema,
  type MemoryConfirmRequest,
  type MemoryEditRequest,
  type MemoryForgetRequest,
  type MemoryItemResponse,
  type MemoryScopeRequest,
} from "./contract";
import { errorResponse, parseBody, unauthorized } from "./respond";

// /api/v2/memory/{id} 쓰기 처리 (구현 계획 B3): 확인 · 정정 · 잊기 · 범위 옮기기. 인증 · gate · 쓰기를 인자로 받아 Route Handler 밖에서 테스트한다.
// 읽기(Remembered 목록 · 상세)는 앱이 Supabase에서 직접 한다 (RLS, memory_items select). 기억을 쓰는 데 AI를 부르지 않는다.
// gate MEMORY_ENABLED가 꺼져 있으면 404: 인증 · DB를 부르지 않는다. 요청 글(statement)은 로그에 남기지 않는다 (오류 이름 · 동작만).
// 응답: 200 { item } (확인 · 정정 · 옮기기는 새 지금 행, 잊기는 잊은 그 행). 404 없는/남의 기억 · 409 conflict(version 충돌 · 이미 정정 · 잊음) ·
// 409 confirm_unavailable / scope_unavailable(정책 보류: 다시 읽어도 소용없다, 앱은 그 동작을 감춘다) · 400 잘못된 본문.

const NOT_FOUND = "기억이 없습니다.";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type AppUser = { user: { id: string } };

type Op = "confirm" | "edit" | "forget" | "scope";

type BaseDeps<User extends AppUser> = {
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
};

async function handleMemoryWrite<User extends AppUser, T extends z.ZodType>(
  request: Request,
  id: string,
  op: Op,
  deps: BaseDeps<User>,
  schema: T,
  write: (user: User, body: z.infer<T>) => Promise<MemoryWriteOutcome>,
  unavailable?: { code: "confirm_unavailable" | "scope_unavailable"; message: string },
): Promise<Response> {
  if (!deps.enabled()) return errorResponse(404, "not_found", "없는 경로입니다.");
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!UUID.test(id)) return errorResponse(404, "not_found", NOT_FOUND);
  const body = await parseBody(request, schema);
  if ("error" in body) return body.error;
  try {
    const outcome = await write(user, body.data);
    switch (outcome.status) {
      case "ok":
        return Response.json({ item: outcome.item } satisfies MemoryItemResponse);
      case "not_found":
        return errorResponse(404, "not_found", NOT_FOUND);
      case "conflict":
        return errorResponse(409, "conflict", "그 사이 기억이 바뀌었습니다. 다시 불러온 뒤 시도해 주세요.");
      case "unavailable":
        return unavailable
          ? errorResponse(409, unavailable.code, unavailable.message)
          : errorResponse(409, "conflict", "그 사이 기억이 바뀌었습니다. 다시 불러온 뒤 시도해 주세요.");
      case "invalid":
        return errorResponse(400, "invalid_request", "valid_from이 valid_until보다 늦습니다.");
    }
  } catch (error) {
    // 요청 글 · 기억 글은 남기지 않는다 (동작 · 오류 이름 · DB 오류 코드만)
    const code = typeof (error as { code?: unknown } | null)?.code === "string" ? (error as { code: string }).code : undefined;
    console.error(JSON.stringify({ event: "memory_write_failed", op, error: error instanceof Error ? error.name : "unknown", code }));
    return errorResponse(500, "internal_error", "기억을 저장하지 못했습니다.");
  }
}

// ─── 확인 (inferred → explicit) ─────────────────────

export type ConfirmMemoryDeps<User extends AppUser> = BaseDeps<User> & {
  confirm: (user: User, id: string, body: MemoryConfirmRequest) => Promise<MemoryWriteOutcome>;
};

/** POST /api/v2/memory/{id}/confirm — 추정 후보를 사용자가 확인한다. Slack 원문에서 온 후보 · 추정이 아닌 항목은 409 confirm_unavailable */
export function handleConfirmMemory<User extends AppUser>(request: Request, id: string, deps: ConfirmMemoryDeps<User>): Promise<Response> {
  return handleMemoryWrite(request, id, "confirm", deps, memoryConfirmRequestSchema, (user, body) => deps.confirm(user, id, body), {
    code: "confirm_unavailable",
    message: "이 기억은 확인할 수 없습니다.",
  });
}

// ─── 정정 ───────────────────────────────────────────

export type EditMemoryDeps<User extends AppUser> = BaseDeps<User> & {
  edit: (user: User, id: string, body: MemoryEditRequest) => Promise<MemoryWriteOutcome>;
};

/** PATCH /api/v2/memory/{id} — 같은 사실 · 같은 범위의 정정. 범위는 바꾸지 않는다. Slack에서 온 후보를 글자만 그대로 정정하면 409 confirm_unavailable */
export function handleEditMemory<User extends AppUser>(request: Request, id: string, deps: EditMemoryDeps<User>): Promise<Response> {
  return handleMemoryWrite(request, id, "edit", deps, memoryEditRequestSchema, (user, body) => deps.edit(user, id, body), {
    code: "confirm_unavailable",
    message: "Slack에서 온 후보는 글을 고쳐 써야 저장할 수 있습니다.",
  });
}

// ─── 잊기 ───────────────────────────────────────────

export type ForgetMemoryDeps<User extends AppUser> = BaseDeps<User> & {
  forget: (user: User, id: string, body: MemoryForgetRequest) => Promise<MemoryWriteOutcome>;
};

/** POST /api/v2/memory/{id}/forget — 잊는다(되돌릴 수 없음). 이미 잊은 항목에 다시 보내면 200(멱등). 이미 보낸 묶음은 회수하지 않는다 */
export function handleForgetMemory<User extends AppUser>(request: Request, id: string, deps: ForgetMemoryDeps<User>): Promise<Response> {
  return handleMemoryWrite(request, id, "forget", deps, memoryForgetRequestSchema, (user, body) => deps.forget(user, id, body));
}

// ─── 범위 옮기기 ────────────────────────────────────

export type MoveMemoryDeps<User extends AppUser> = BaseDeps<User> & {
  move: (user: User, id: string, body: MemoryScopeRequest) => Promise<MemoryWriteOutcome>;
};

/** POST /api/v2/memory/{id}/scope — explicit 항목만 전체 · 내 active 범위로 옮긴다. observed · inferred · 다른 범위 종류는 409 scope_unavailable */
export function handleMoveMemory<User extends AppUser>(request: Request, id: string, deps: MoveMemoryDeps<User>): Promise<Response> {
  return handleMemoryWrite(request, id, "scope", deps, memoryScopeRequestSchema, (user, body) => deps.move(user, id, body), {
    code: "scope_unavailable",
    message: "이 기억의 범위는 바꿀 수 없습니다.",
  });
}
