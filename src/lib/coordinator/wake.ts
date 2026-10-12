import "server-only";

import { randomUUID } from "node:crypto";

import { wakeOrigin } from "@/lib/execution/wake";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

import { supabaseCoordinatorReads } from "./reads";
import { supabaseCoordinatorStore } from "./store";
import { coordinatorPass, type PassResult } from "./sweep";

// 깨우기 (아키텍처 7.1): 사건을 처리한 뒤 더 남았으면(또는 1분 sweep이) 자기 호출(POST /api/cron/coordinator-advance)로 새 함수 호출에 맡긴다.
// 그 route는 바로 202로 답하고 after()에서 한 번 돈다 (coordinatorPass). 자기 호출이 실패해도 사건은 DB에 남아 있어 다음 1분 sweep이 다시 깨운다.
// 같은 사건을 두 호출이 동시에 처리하려 해도 DB의 집기(skip locked + 사용자 잠금 + lease)가 하나만 통과시키므로 깨우기가 겹쳐도(중복) 안전하다.
// COORDINATOR_ENABLED가 꺼져 있으면 깨우지 않는다 (네트워크 호출 0).

export const COORDINATOR_ADVANCE_PATH = "/api/cron/coordinator-advance";
/** 자기 호출은 202 응답만 기다린다 (처리는 받은 쪽의 after()에서 돈다) */
export const COORDINATOR_WAKE_TIMEOUT_MS = 10_000;

export type CoordinatorWakeOptions = { env?: Record<string, string | undefined>; origin?: string | null; secret?: string; fetch?: typeof fetch };

/** 코디네이터를 새 함수 호출에서 돌게 한다. 받아들여지면 true. 꺼져 있거나 실패해도 던지지 않는다 (sweep이 이어 간다) */
export async function wakeCoordinator(options: CoordinatorWakeOptions = {}): Promise<boolean> {
  const env = options.env ?? process.env;
  if (!flagEnabled("COORDINATOR_ENABLED", env)) return false;
  const origin = options.origin === undefined ? wakeOrigin(env) : options.origin;
  const secret = options.secret ?? env.CRON_SECRET ?? "";
  if (!origin || !secret) return false;
  try {
    const response = await (options.fetch ?? fetch)(new URL(COORDINATOR_ADVANCE_PATH, origin), {
      method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
      body: "{}",
      signal: AbortSignal.timeout(COORDINATOR_WAKE_TIMEOUT_MS),
    });
    if (response.status !== 202) console.error(JSON.stringify({ event: "coordinator_wake_failed", status: response.status }));
    return response.status === 202;
  } catch (error) {
    console.error(JSON.stringify({ event: "coordinator_wake_failed", error: error instanceof Error ? error.name : "unknown" }));
    return false;
  }
}

/** 한 번 돌고(coordinatorPass), 더 남았으면 깨운다. route의 after()가 부른다. 실패는 로그만 남긴다 (사건은 DB에 남아 sweep이 이어 간다) */
export async function advanceCoordinator(options: CoordinatorWakeOptions = {}): Promise<PassResult | null> {
  const env = options.env ?? process.env;
  if (!flagEnabled("COORDINATOR_ENABLED", env)) return null;
  try {
    const admin = createAdminClient();
    // 운영 배선은 모델 포트를 주지 않는다: 지금 데이터에는 모델 판정이 필요한 경로가 없다 (judgments.ts 머리말, docs/coordinator.md)
    const result = await coordinatorPass({ store: supabaseCoordinatorStore(admin), reads: supabaseCoordinatorReads(admin), consumer: `fn-${randomUUID()}` });
    (result.errors > 0 ? console.error : console.info)(JSON.stringify({ event: "coordinator_pass", ...result }));
    if (result.run?.more) await wakeCoordinator(options);
    return result;
  } catch (error) {
    console.error(JSON.stringify({ event: "coordinator_advance_failed", error: error instanceof Error ? error.message : "unknown" }));
    return null;
  }
}
