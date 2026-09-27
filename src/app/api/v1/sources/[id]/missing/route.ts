import { z } from "zod";

import { authenticateRequest } from "@/lib/api/auth";
import { missingReportRequestSchema, type MissingReportResponse } from "@/lib/api/contract";
import { RateLimitedError } from "@/lib/api/rate-limit";
import { resolveIdentity } from "@/lib/api/profile";
import { loadProfile } from "@/lib/api/profile-store";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import type { SourceKind } from "@/lib/pipeline/extract";
import type { Participants } from "@/lib/pipeline/identity";
import { QuoteNotInSourceError } from "@/lib/pipeline/missing";
import { quoteInText } from "@/lib/pipeline/text";
import { reportMissing } from "@/lib/sources/process";
import { createAdminClient } from "@/lib/supabase/admin";

// 빠진 할 일 신고 (지표 4): 사용자가 원문 구절을 골라 "여기 내 할 일이 있다"고 알려준다.
// 동기로 처리해(추출 · Jev · 매칭, 수 초) 새로 만들었는지 · 이미 있던 할 일인지를 바로 돌려준다.
// 신고마다 모델을 부르므로 사용자별로 10분에 10번까지 받는다 (넘으면 429 rate_limited).
export const maxDuration = 60;

type Params = { params: Promise<{ id: string }> };

type SourceRow = {
  id: string;
  kind: SourceKind | "task";
  raw_text: string;
  occurred_at: string;
  participants: Participants | null;
  processing_status: string;
};

export async function POST(request: Request, { params }: Params) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const { id } = await params;
  if (!z.uuid().safeParse(id).success) return errorResponse(404, "not_found", "원문이 없습니다.");
  const body = await parseBody(request, missingReportRequestSchema);
  if ("error" in body) return body.error;

  // 본인 원문인지는 사용자 권한(RLS)으로 읽어 확인한다.
  const { data: source, error } = await context.supabase
    .from("sources")
    .select("id, kind, raw_text, occurred_at, participants, processing_status")
    .eq("id", id)
    .maybeSingle<SourceRow>();
  if (error) return errorResponse(500, "internal_error", "원문을 불러오지 못했습니다.");
  if (!source) return errorResponse(404, "not_found", "원문이 없습니다.");
  // 할 일 DB 항목은 속성을 그대로 옮기므로 빠질 구절이 없다.
  if (source.kind === "task") return errorResponse(400, "invalid_request", "할 일 DB에서 가져온 항목은 신고할 수 없습니다.");
  if (!quoteInText(body.data.quote, source.raw_text)) return errorResponse(400, "invalid_request", "원문에 없는 구절입니다.");

  try {
    const identity = resolveIdentity(await loadProfile(context).catch(() => null), context.user);
    const result = await reportMissing(
      createAdminClient(),
      { id: source.id, userId: context.user.id, processingStatus: source.processing_status },
      {
        text: source.raw_text,
        kind: source.kind,
        occurredAt: new Date(source.occurred_at),
        identity,
        participants: source.participants ?? undefined,
        quote: body.data.quote,
      },
    );
    return Response.json(result satisfies MissingReportResponse);
  } catch (error) {
    if (error instanceof QuoteNotInSourceError) return errorResponse(400, "invalid_request", error.message);
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "신고가 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(Math.max(1, Math.ceil((error.retryAt.getTime() - Date.now()) / 1000))));
      return response;
    }
    // 오류 메시지에 원문 · 구절을 담지 않는다.
    console.error(`누락 신고 실패 (${source.id}):`, error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "신고를 처리하지 못했습니다.");
  }
}
