import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { PendingDecisionGroup, ReviewResponse, Suggestion } from "@/lib/api/contract";
import { loadPendingDecisions } from "@/lib/coordinator/pending";

import { localDay } from "./day";
import { pendingGroupDto } from "./dto";
import { SUGGESTION_DAILY_BATCH_SIZE } from "./review.config";
import { exposeSuggestions, produceSuggestions } from "./suggestions";
import { loadUserTimeZone } from "./time-zone";

// Review (런타임 계약 6장 pending_decisions + 8장 suggestions): C2 결정 대기 계산(개수 상한 없음, 숨긴 항목을 gone으로 만들지 않는다) + 열린 제안.
//  - 결정 대기는 실제 원천(SQL coordinator_pending_inputs)에서 그때그때 계산한다. 코디네이터 게이트와 무관하다. 읽기는 아무것도 해결하지 않는다.
//  - 제안: 생산(지금 있는 결정적 사실, 멱등) → 노출(비긴급 하루 한 묶음 3개 · 긴급은 상한 밖). 코디네이터 결과를 쓰는 종류는 COORDINATOR_ENABLED일 때만 읽는다.
//    제안을 보는 것은 Action · run을 만들지 않는다.
//  - 한 쪽을 읽지 못하면 그 쪽을 unavailable로 표시하고 null로 둔다 — 비었다고 하지 않는다. empty는 둘 다 읽었고 둘 다 비었을 때만이다.

export type ReviewOptions = {
  /** COORDINATOR_ENABLED. 켜져 있을 때만 C2 처리 결과(inbox_events)를 읽는 제안 종류를 만든다 */
  coordinatorEnabled: boolean;
  /** 사용자 시간대 읽기(주입: 시험). 기본은 보고 설정 표를 읽고, 표가 없으면 모른다(null) */
  timeZone?: (admin: SupabaseClient, userId: string) => Promise<string | null>;
};

const failureName = (reason: unknown) => (reason instanceof Error ? reason.name : "unknown");

export async function loadReview(admin: SupabaseClient, userId: string, now: Date, options: ReviewOptions): Promise<ReviewResponse> {
  const readZone = options.timeZone ?? loadUserTimeZone;

  // 사용자 시간대를 읽지 못하면(오류) 모르는 것으로 둔다: 새 비긴급을 내지 않는 쪽이 안전하다 (긴급 · 이미 낸 제안은 그대로)
  let zone: string | null = null;
  try {
    zone = await readZone(admin, userId);
  } catch (error) {
    console.error(JSON.stringify({ event: "review_time_zone_failed", error: failureName(error) }));
  }
  const day = zone ? localDay(now, zone) : null;

  const [decided, offered] = await Promise.allSettled([
    loadPendingDecisions(admin, userId, now),
    (async (): Promise<Suggestion[]> => {
      await produceSuggestions(admin, userId, now, { coordinatorEnabled: options.coordinatorEnabled });
      return exposeSuggestions(admin, userId, day, now);
    })(),
  ]);
  if (decided.status === "rejected") console.error(JSON.stringify({ event: "review_pending_failed", error: failureName(decided.reason) }));
  if (offered.status === "rejected") console.error(JSON.stringify({ event: "review_suggestions_failed", error: failureName(offered.reason) }));

  const decisions: PendingDecisionGroup[] | null = decided.status === "fulfilled" ? decided.value.map(pendingGroupDto) : null;
  const suggestions: Suggestion[] | null = offered.status === "fulfilled" ? offered.value : null;
  const complete = decisions !== null && suggestions !== null;
  return {
    generated_at: now.toISOString(),
    complete,
    empty: complete && decisions.length === 0 && suggestions.length === 0,
    sources: { decisions: decisions ? "ok" : "unavailable", suggestions: suggestions ? "ok" : "unavailable" },
    decisions,
    suggestions,
    suggestion_batch: { state: day ? "ready" : "needs_time_zone", local_day: day, size: SUGGESTION_DAILY_BATCH_SIZE },
  };
}
