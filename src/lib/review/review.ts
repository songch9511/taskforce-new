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
//  - 결정 대기는 실제 원천(SQL coordinator_pending_inputs)에서 그때그때 계산한다. 코디네이터 게이트와 무관하다. 계산은 아무것도 해결하지 않는다.
//  - 제안: 생산(지금 있는 결정적 사실, 멱등) → 노출(비긴급 하루 한 묶음 3개 · 긴급은 상한 밖). 코디네이터 결과를 쓰는 종류는 COORDINATOR_ENABLED일 때만 읽는다.
//    이 호출은 읽기만 하지 않는다: 제안 생산 · 노출 표시(shown_at · 그날의 비긴급 묶음 소비 · snooze 끝난 제안 다시 열기 · 증거 있는 expired)를 멱등으로 쓴다. 제안을 보는 것은 Action · run · Claim을 만들지 않는다.
//  - 한 쪽을 읽지 못하면 그 쪽을 unavailable로 표시한다 — 비었다고 하지 않는다. 시간대(하루 경계)도 같다. empty는 모든 원천을 읽었고 둘 다 비었을 때만이다.

export type ReviewOptions = {
  /** COORDINATOR_ENABLED. 켜져 있을 때만 C2 처리 결과(inbox_events)를 읽는 제안 종류를 만든다 */
  coordinatorEnabled: boolean;
  /** 사용자 시간대 읽기(주입: 시험). 기본은 보고 설정 표를 읽고, 표가 없으면 모른다(null) */
  timeZone?: (admin: SupabaseClient, userId: string) => Promise<string | null>;
};

const failureName = (reason: unknown) => (reason instanceof Error ? reason.name : "unknown");
/** DB 오류 코드(SQLSTATE · PostgREST)만. 메시지 · 값은 남기지 않는다 */
const errorCode = (reason: unknown) => (typeof (reason as { code?: unknown } | null)?.code === "string" ? (reason as { code: string }).code : undefined);

export async function loadReview(admin: SupabaseClient, userId: string, now: Date, options: ReviewOptions): Promise<ReviewResponse> {
  const readZone = options.timeZone ?? loadUserTimeZone;

  // 사용자 시간대: "저장된 시간대가 없다 / 이 스택에 설정 표가 없다"(null)는 정당한 모름이다. 예상 못한 읽기 오류는 모름이 아니라 읽지 못한 것이다 —
  // 둘 다 새 비긴급은 내지 않지만(시간대를 지어내지 않는다), 후자는 time_zone unavailable · complete false · empty false로 정직하게 알린다.
  let zone: string | null = null;
  let zoneStatus: ReviewResponse["sources"]["time_zone"] = "ok";
  try {
    zone = await readZone(admin, userId);
  } catch (error) {
    zoneStatus = "unavailable";
    console.error(JSON.stringify({ event: "review_time_zone_failed", error: failureName(error), code: errorCode(error) }));
  }
  const day = zone ? localDay(now, zone) : null;

  const [decided, offered] = await Promise.allSettled([
    loadPendingDecisions(admin, userId, now),
    (async () => {
      await produceSuggestions(admin, userId, now, { coordinatorEnabled: options.coordinatorEnabled });
      return exposeSuggestions(admin, userId, day, now);
    })(),
  ]);
  if (decided.status === "rejected") console.error(JSON.stringify({ event: "review_pending_failed", error: failureName(decided.reason) }));
  if (offered.status === "rejected") console.error(JSON.stringify({ event: "review_suggestions_failed", error: failureName(offered.reason) }));

  const decisions: PendingDecisionGroup[] | null = decided.status === "fulfilled" ? decided.value.map(pendingGroupDto) : null;
  const suggestions: Suggestion[] | null = offered.status === "fulfilled" ? offered.value.suggestions : null;
  // 이 코드가 모르는 종류의 열린 제안이 있으면 목록은 일부다: 지어서 보이지 않고, 비었다고도 하지 않는다
  const suggestionsStatus: ReviewResponse["sources"]["suggestions"] = offered.status === "fulfilled" && offered.value.unrecognized === 0 ? "ok" : "unavailable";
  const complete = decisions !== null && suggestions !== null && suggestionsStatus === "ok" && zoneStatus === "ok";
  return {
    generated_at: now.toISOString(),
    complete,
    empty: complete && decisions.length === 0 && suggestions.length === 0,
    sources: { decisions: decisions ? "ok" : "unavailable", suggestions: suggestionsStatus, time_zone: zoneStatus },
    decisions,
    suggestions,
    suggestion_batch: { state: zoneStatus === "unavailable" ? "unavailable" : day ? "ready" : "needs_time_zone", local_day: day, size: SUGGESTION_DAILY_BATCH_SIZE },
  };
}
