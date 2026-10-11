import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { COORDINATOR_LEASE_SECONDS, COORDINATOR_MAX_ATTEMPTS } from "./coordinator.config";
import type { ClaimedEvent, FinishStatus, InboxEnvelope, Outcome } from "./types";

// 사건 큐의 DB 쪽 (service role). 판단(순서 · 직렬화 · lease · 예산)은 SQL 함수에만 있고(20261110000000_coordinator_core), 여기는 RPC 호출뿐이다.
// 사용자 글(원문 · 발화)은 이 경로에 없다: 사건은 id · 종류만 담는다. 로그에도 숫자 · 종류만 남긴다.

export interface CoordinatorStore {
  /** 멱등 적재 (같은 dedup_key는 한 번). 생산자 트리거가 못 하는 곳(후속 레인의 TS 생산자 · 시험)이 쓴다 */
  enqueue(envelope: InboxEnvelope): Promise<{ eventId: string; created: boolean }>;
  /** 사용자마다 머리 사건 하나, 오래 기다린 머리부터 limit개 */
  claim(consumer: string, limit: number): Promise<ClaimedEvent[]>;
  /** 집은 토큰의 소비자만, lease가 살아 있을 때만 처리 완료 */
  finish(event: ClaimedEvent, outcome: Outcome): Promise<FinishStatus>;
  /** 처리하지 못했다: 까닭 종류만 남기고 재시도를 늦춘다 */
  fail(event: ClaimedEvent, errorKind: string, retryAfterSeconds: number): Promise<boolean>;
  /** 관리(생성) 모델 호출 예약 (호출 전에): 사건당 한 번만 true */
  reserveModelCall(event: ClaimedEvent): Promise<boolean>;
  /** Jev 호출 예약 (호출 전에): 합이 cap을 넘으면 하나도 더하지 않고 false */
  reserveJevCalls(event: ClaimedEvent, count: number, cap: number): Promise<boolean>;
  /** 기한 창 timer 적재 (sweep) */
  enqueueDueTimers(windowSeconds: number, limit: number): Promise<number>;
  /** 삼킨 적재 회수 (sweep) */
  recoverMissing(lookbackSeconds: number, limit: number): Promise<number>;
}

export function supabaseCoordinatorStore(admin: SupabaseClient, options: { leaseSeconds?: number; maxAttempts?: number } = {}): CoordinatorStore {
  const leaseSeconds = options.leaseSeconds ?? COORDINATOR_LEASE_SECONDS;
  const maxAttempts = options.maxAttempts ?? COORDINATOR_MAX_ATTEMPTS;
  const rpc = async <T>(fn: string, args: Record<string, unknown>) => (await admin.rpc(fn, args).throwOnError()).data as T;

  return {
    async enqueue(envelope) {
      const rows = await rpc<{ event_id: string; created: boolean }[]>("coordinator_enqueue", {
        p_user_id: envelope.user_id,
        p_type: envelope.type,
        p_dedup_key: envelope.dedup_key,
        p_refs: envelope.refs,
      });
      return { eventId: rows[0].event_id, created: rows[0].created };
    },

    async claim(consumer, limit) {
      return (await rpc<ClaimedEvent[] | null>("coordinator_claim", { p_consumer: consumer, p_lease_seconds: leaseSeconds, p_limit: limit, p_max_attempts: maxAttempts })) ?? [];
    },

    async finish(event, outcome) {
      return rpc<FinishStatus>("coordinator_finish", {
        p_event_id: event.event_id,
        p_claim_token: event.claim_token,
        p_result_kind: outcome.kind,
        p_result_ids: outcome.ids,
        p_evidence: outcome.evidence,
      });
    },

    async fail(event, errorKind, retryAfterSeconds) {
      return rpc<boolean>("coordinator_fail", { p_event_id: event.event_id, p_claim_token: event.claim_token, p_error_kind: errorKind, p_retry_after_seconds: retryAfterSeconds });
    },

    async reserveModelCall(event) {
      return rpc<boolean>("coordinator_reserve_model_call", { p_event_id: event.event_id, p_claim_token: event.claim_token });
    },

    async reserveJevCalls(event, count, cap) {
      return rpc<boolean>("coordinator_reserve_jev_calls", { p_event_id: event.event_id, p_claim_token: event.claim_token, p_count: count, p_cap: cap });
    },

    async enqueueDueTimers(windowSeconds, limit) {
      return Number(await rpc<number>("coordinator_enqueue_due_timers", { p_window_seconds: windowSeconds, p_limit: limit }));
    },

    async recoverMissing(lookbackSeconds, limit) {
      return Number(await rpc<number>("coordinator_recover_missing", { p_lookback_seconds: lookbackSeconds, p_limit: limit }));
    },
  };
}
