import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { Suggestion } from "@/lib/api/contract";

import { suggestionDto, type SuggestionRow } from "./dto";
import { SUGGESTION_DAILY_BATCH_SIZE, SUGGESTION_URGENT_WINDOW_HOURS } from "./review.config";

// 제안(suggestions) DB 호출 (service role, 모든 함수가 user_id로 좁힌다). 규칙은 SQL 20261111000000_review_summary가 가진다:
//  - 생산: 지금 있는 결정적 사실에서만, dedup = kind + subject + 계기 revision(날짜 아님), topic 거절은 새 계기도 막는다.
//  - 노출: 비긴급은 사용자 현지 날짜마다 한 묶음 3개(처음 노출), 긴급은 상한 밖. 증거 있는 stale만 expired.
//  - 전이: snooze(사용자가 고른 시점) · dismiss(this | topic)만, state + version 조건부 쓰기. 채택(accept)은 없다.
// 제안은 Action · run · Claim · 정책 · 승인을 만들거나 바꾸지 않는다 (R5 · I04 · I14). 글을 읽지도 쓰지도 않는다.

/** 제안을 만든다 (멱등). 코디네이터 결과를 쓰는 종류는 coordinatorEnabled일 때만 읽는다. 새로 만든 개수 */
export async function produceSuggestions(admin: SupabaseClient, userId: string, now: Date, options: { coordinatorEnabled: boolean }): Promise<number> {
  const { data } = await admin
    .rpc("suggestions_produce", {
      p_user_id: userId,
      p_now: now.toISOString(),
      p_window_hours: SUGGESTION_URGENT_WINDOW_HOURS,
      p_with_coordinator: options.coordinatorEnabled,
    })
    .throwOnError();
  return Number(data ?? 0);
}

/**
 * 지금 보이는 열린 제안. localDay가 null이면(시간대를 모름) 새 비긴급은 내지 않는다.
 * 제안을 보는 것만으로 Action · run은 생기지 않는다 (노출 표시만 쓴다).
 */
export async function exposeSuggestions(admin: SupabaseClient, userId: string, localDay: string | null, now: Date): Promise<Suggestion[]> {
  const { data } = await admin
    .rpc("suggestions_expose", {
      p_user_id: userId,
      p_local_day: localDay,
      p_batch_size: SUGGESTION_DAILY_BATCH_SIZE,
      p_now: now.toISOString(),
    })
    .throwOnError();
  return ((data ?? []) as SuggestionRow[]).map(suggestionDto).filter((s): s is Suggestion => s !== null);
}

export type TransitionOutcome = { status: "ok"; suggestion: Suggestion } | { status: "not_found" | "conflict" | "invalid" };

type TransitionPayload = { status: "ok" | "not_found" | "conflict" | "invalid"; suggestion?: SuggestionRow };

async function transition(
  admin: SupabaseClient,
  userId: string,
  suggestionId: string,
  expectedVersion: number,
  op: "snooze" | "dismiss",
  extra: { snoozeUntil?: Date; scope?: "this" | "topic" },
  now: Date,
): Promise<TransitionOutcome> {
  const { data } = await admin
    .rpc("suggestion_transition", {
      p_user_id: userId,
      p_id: suggestionId,
      p_expected_version: expectedVersion,
      p_op: op,
      p_snooze_until: extra.snoozeUntil ? extra.snoozeUntil.toISOString() : null,
      p_dismiss_scope: extra.scope ?? null,
      p_now: now.toISOString(),
    })
    .throwOnError();
  const payload = data as TransitionPayload | null;
  if (!payload) throw new Error("suggestion_transition: 응답 없음");
  if (payload.status !== "ok") return { status: payload.status };
  const suggestion = payload.suggestion ? suggestionDto(payload.suggestion) : null;
  // 모르는 kind의 제안은 앱이 처리할 수 없다 (이 코드보다 새 서버가 만든 것): 성공으로 꾸미지 않는다
  if (!suggestion) throw new Error("suggestion_transition: 모르는 제안 종류");
  return { status: "ok", suggestion };
}

/** 사용자가 고른 시점까지 숨긴다. 시점이 지금 이전이면 invalid */
export const snoozeSuggestion = (admin: SupabaseClient, userId: string, id: string, expectedVersion: number, until: Date, now: Date) =>
  transition(admin, userId, id, expectedVersion, "snooze", { snoozeUntil: until }, now);

/** 거절한다: this = 이 계기만, topic = 같은 종류 + 주제의 새 계기도 */
export const dismissSuggestion = (admin: SupabaseClient, userId: string, id: string, expectedVersion: number, scope: "this" | "topic", now: Date) =>
  transition(admin, userId, id, expectedVersion, "dismiss", { scope }, now);
