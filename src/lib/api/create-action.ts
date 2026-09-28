import type { NewUserAction } from "@/lib/actions/service";
import { actionEmbedText } from "@/lib/pipeline/merge";
import { quoteInText } from "@/lib/pipeline/text";
import { PURGED_SOURCE_MESSAGE } from "@/lib/retention";

import { createActionRequestSchema, type ActionSummary, type CreateActionResponse } from "./contract";
import { retryAfterSeconds } from "./rate-limit";
import { errorResponse, parseBody, unauthorized } from "./respond";

// POST /api/v1/actions 처리 (직접 추가). 인증 · 원문 읽기 · 이미 있는 Action 찾기 · 횟수 제한 · 동의 확인 · 임베딩 · 쓰기를 인자로 받아
// Route Handler 밖에서 테스트한다. 제목 · 구절은 로그에 남기지 않는다 (오류 메시지만).

export type RelatedSource = { kind: string; raw_text: string; raw_text_purged_at: string | null };

export type CreateActionDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  /** 사용자 권한(RLS)으로 원문을 읽는다. 없거나 남의 원문이면 null */
  loadSource: (user: User, sourceId: string) => Promise<RelatedSource | null>;
  /** 이 원문에서 구절이 이미 근거인 Action (누락 신고의 trackedAction과 같은 확인). 없으면 null */
  trackedAction: (user: User, sourceId: string, quote: string) => Promise<ActionSummary | null>;
  /** 한도에 찼으면 다시 할 수 있는 시각, 아니면 시도를 남기고 null */
  rateLimit: (user: User) => Promise<Date | null>;
  hasConsent: (user: User) => Promise<boolean>;
  /** 매칭용 임베딩 하나 (모델 호출) */
  embed: (user: User, text: string) => Promise<number[]>;
  create: (user: User, action: NewUserAction) => Promise<ActionSummary>;
  now?: () => Date;
};

export async function handleCreateAction<User>(request: Request, deps: CreateActionDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, createActionRequestSchema);
  if ("error" in body) return body.error;
  const { title, due_date, source_id, quote } = body.data;
  const source = source_id && quote ? { id: source_id, quote } : null;

  try {
    if (source) {
      const row = await deps.loadSource(user, source.id);
      if (!row) return errorResponse(404, "not_found", "원문이 없습니다.");
      // 누락 신고(sources/[id]/missing)와 같은 확인. 할 일 DB 항목은 속성을 그대로 옮겨 이미 Action이 되므로 고를 수 없다.
      if (row.kind === "task") return errorResponse(400, "invalid_request", "할 일 DB에서 가져온 항목은 고를 수 없습니다.");
      if (row.raw_text_purged_at) return errorResponse(400, "invalid_request", PURGED_SOURCE_MESSAGE);
      if (!quoteInText(source.quote, row.raw_text)) return errorResponse(400, "invalid_request", "원문에 없는 구절입니다.");

      // 이미 그 구절로 만든 Action이 있으면(끝냈거나 지운 것도) 새로 만들지 않고 그대로 돌려준다 (원칙 4).
      // 보낸 제목 · 기한은 반영하지 않는다: 사용자가 고친 값은 PATCH로만 남긴다 (이벤트 · 지표 1).
      // 횟수 제한보다 먼저 본다: 쓰기도 모델 호출도 없으므로 누락 신고의 already_tracked처럼 세지 않는다 (만들 때만 한 번 센다).
      const tracked = await deps.trackedAction(user, source.id, source.quote);
      if (tracked) return Response.json({ action: tracked, status: "already_tracked" } satisfies CreateActionResponse, { status: 200 });
    }

    const retryAt = await deps.rateLimit(user);
    if (retryAt) {
      const response = errorResponse(429, "rate_limited", "추가가 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, deps.now?.() ?? new Date())));
      return response;
    }

    const embedding = await matchEmbedding(user, actionEmbedText(title, source?.quote ?? null), deps);
    const action = await deps.create(user, { title, dueDate: due_date ?? null, source, embedding });
    return Response.json({ action, status: "created" } satisfies CreateActionResponse, { status: 201 });
  } catch (error) {
    console.error("직접 추가 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "저장하지 못했습니다.");
  }
}

/**
 * 매칭용 임베딩. match_open_actions는 embedding이 없는 Action을 후보로 보지 않아서, 없으면 나중 원문에서 같은 일이 나와도
 * 새 Action이 하나 더 생긴다 (원칙 4). 임베딩은 제목 · 구절을 외부 AI로 보내는 모델 호출이라 외부 AI 처리에 동의했을 때만 만든다.
 * 동의 전이거나 실패하면 null로 두고 Action은 그대로 만든다 (사용자가 적은 할 일을 잃지 않는 것이 먼저).
 * 비어 있는 임베딩은 다음 원문 처리가 매칭 전에 채운다 (pipeline/backfill-embeddings.ts).
 */
async function matchEmbedding<User>(user: User, text: string, deps: CreateActionDeps<User>): Promise<number[] | null> {
  try {
    if (!(await deps.hasConsent(user))) return null;
    return await deps.embed(user, text);
  } catch (error) {
    console.error("직접 추가 임베딩 실패:", error instanceof Error ? error.message : error);
    return null;
  }
}
