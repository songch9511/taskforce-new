import { z } from "zod";

import { markActionSeen } from "@/lib/actions/service";
import { DeadlineExceededError, interactiveDeadline, logDeadlineExceeded } from "@/lib/ai/deadline";
import { authenticateRequest } from "@/lib/api/auth";
import { consentRequired } from "@/lib/api/consent";
import { missingReportRequestSchema, type MissingReportResponse } from "@/lib/api/contract";
import { RateLimitedError, retryAfterSeconds } from "@/lib/api/rate-limit";
import { resolveIdentity } from "@/lib/api/profile";
import { hasAiConsent, loadProfile } from "@/lib/api/profile-store";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { SourceKind } from "@/lib/pipeline/extract";
import type { Participants } from "@/lib/pipeline/identity";
import { QuoteNotInSourceError } from "@/lib/pipeline/missing";
import { quoteInText } from "@/lib/pipeline/text";
import { purgedSourceMessage } from "@/lib/retention";
import { processDepsFromEnv, reportMissing } from "@/lib/sources/process";
import { createAdminClient } from "@/lib/supabase/admin";

// 빠진 할 일 신고 (지표 4): 사용자가 원문 구절을 골라 "여기 내 할 일이 있다"고 알려준다.
// 동기로 처리해(추출 · Jev · 매칭, 수 초) 새로 만들었는지 · 이미 있던 할 일인지를 바로 돌려준다.
// 신고마다 모델을 부르므로 사용자별로 10분에 10번까지 받는다 (넘으면 429 rate_limited). 외부 AI 처리 동의 전이면 409.
// 보관 기간(90일)이 지나 글이 지워진 원문은 신고할 수 없다 (400).
// 앱도 60초 기다린다 (lib/ai/deadline.ts INTERACTIVE_MAX_DURATION_S와 같아야 한다, route.test.ts). 모델 호출 · 병합 대기는 실행 한도보다
// 8초 먼저 끝내고, 추출(LLM)은 첫 호출부터 추론량을 제한하며 뒤의 판정 · 병합에 시간을 남긴다 (lib/sources/process.ts reportMissing · processDepsFromEnv).
// 마감 안에 끝내지 못하면 500과 함께 deadline_exceeded 한 줄을 남긴다 (logDeadlineExceeded).
export const maxDuration = 60;

type Params = { params: Promise<{ id: string }> };

type SourceRow = {
  id: string;
  kind: SourceKind | "task" | "execution";
  raw_text: string;
  occurred_at: string;
  participants: Participants | null;
  processing_status: string;
  raw_text_purged_at: string | null;
  raw_text_purge_reason: string | null;
};


export async function POST(request: Request, { params }: Params) {
  const startedAt = Date.now();
  const deadline = interactiveDeadline(maxDuration, startedAt);
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const { id } = await params;
  if (!z.uuid().safeParse(id).success) return errorResponse(404, "not_found", "원문이 없습니다.");
  const body = await parseBody(request, missingReportRequestSchema);
  if ("error" in body) return body.error;
  // 신고한 구절과 앞뒤 원문을 외부 AI로 보내므로 동의가 먼저다 (철회한 뒤에도 보내지 않는다).
  if (!(await hasAiConsent(context))) return consentRequired();

  // 본인 원문인지는 사용자 권한(RLS)으로 읽어 확인한다.
  const { data: source, error } = await context.supabase
    .from("sources")
    .select("id, kind, raw_text, occurred_at, participants, processing_status, raw_text_purged_at, raw_text_purge_reason")
    .eq("id", id)
    .maybeSingle<SourceRow>();
  if (error) return errorResponse(500, "internal_error", "원문을 불러오지 못했습니다.");
  if (!source) return errorResponse(404, "not_found", "원문이 없습니다.");
  // 할 일 DB 항목은 속성을 그대로 옮기므로 빠질 구절이 없다.
  if (source.kind === "task") return errorResponse(400, "invalid_request", "할 일 DB에서 가져온 항목은 신고할 수 없습니다.");
  // 실행 receipt(초안 저장 기록)는 원문이 아니라 추출하지 않는다 (docs/EXECUTION.md 9장)
  if (source.kind === "execution") return errorResponse(400, "invalid_request", "실행 기록은 신고할 수 없습니다.");
  if (source.raw_text_purged_at) return errorResponse(400, "invalid_request", purgedSourceMessage(source.raw_text_purge_reason));
  if (!quoteInText(body.data.quote, source.raw_text)) return errorResponse(400, "invalid_request", "원문에 없는 구절입니다.");

  try {
    const identity = resolveIdentity(await loadProfile(context).catch(() => null), context.user);
    const admin = createAdminClient();
    const result = await reportMissing(
      admin,
      { id: source.id, userId: context.user.id, processingStatus: source.processing_status },
      {
        text: source.raw_text,
        kind: source.kind,
        occurredAt: new Date(source.occurred_at),
        identity,
        participants: source.participants ?? undefined,
        quote: body.data.quote,
      },
      deadline,
      processDepsFromEnv(deadline),
    );
    // 이미 있는 할 일에 붙었으면 사용자가 방금 그 할 일을 본 것이다: 신고로 붙은 AI 병합 · 변경으로 바뀜 점이 켜지지 않게 본 것으로 남긴다
    // (사용자 자신의 행동은 바뀜이 아니다, lib/actions/changed.ts). 곁가지라 실패해도 신고 결과는 그대로 돌려준다 (예: 마이그레이션 20261025000000 전)
    if (result.status === "already_tracked") {
      await markActionSeen(context.supabase, admin, context.user.id, result.action.id).catch((error) =>
        console.error("누락 신고 뒤 본 것 표시 실패:", error instanceof Error ? error.message : error),
      );
    }
    return Response.json(result satisfies MissingReportResponse);
  } catch (error) {
    if (error instanceof QuoteNotInSourceError) return errorResponse(400, "invalid_request", error.message);
    // 처리 도중에 동의를 철회함 (모델 호출 직전 확인)
    if (error instanceof ConsentRequiredError) return consentRequired();
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "신고가 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(error.retryAt, new Date())));
      return response;
    }
    if (error instanceof DeadlineExceededError) logDeadlineExceeded("missing", error, startedAt);
    // 오류 메시지에 원문 · 구절을 담지 않는다.
    console.error(`누락 신고 실패 (${source.id}):`, error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "신고를 처리하지 못했습니다.");
  }
}
