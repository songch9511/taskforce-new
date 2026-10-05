import "server-only";

import { randomUUID } from "node:crypto";

import { budgetFetch } from "@/lib/ai/budget";
import { completeJson, llmConfigFromEnv } from "@/lib/ai/llm";
import { createAdminClient } from "@/lib/supabase/admin";

import { advance, type AdvanceResult } from "./executor";
import { supabaseExecutionStore } from "./store";

// 깨우기 (EXECUTION 2장 K2): 상태를 commit한 뒤 다음 단계는 새 함수 호출에서 한다 (함수 호출 한 번 = 단계 하나).
// 다음 단계는 CRON_SECRET을 실은 자기 호출(POST /api/cron/execution-advance)로 부른다. 그 route는 바로 202로 답하고 after()에서 단계 하나를 돈다.
// 자기 호출이 실패해도 run은 DB에 남아 있어 1분마다 도는 sweep이 이어 간다.

export const ADVANCE_PATH = "/api/cron/execution-advance";
/** 자기 호출은 202 응답만 기다린다 (단계는 받은 쪽의 after()에서 돈다) */
export const WAKE_TIMEOUT_MS = 10_000;

/**
 * 자기 호출을 보낼 주소. 요청 헤더(Host)에서 만들지 않는다: CRON_SECRET을 실어 보내므로 정해 둔 곳에만 보낸다.
 * EXECUTION_WAKE_ORIGIN(예: https://taskforce.example.com) → 운영 배포면 Vercel이 넣는 VERCEL_PROJECT_PRODUCTION_URL → 개발 서버면 localhost.
 * 모르면 null: 깨우지 않고 sweep(1분)이 이어 간다. 미리보기 배포는 null이고 Vercel cron도 돌지 않아 첫 단계 뒤에 이어지지 않는다
 * (실행은 운영 · 로컬 개발에서만 쓴다).
 */
export function wakeOrigin(env: Record<string, string | undefined> = process.env): string | null {
  const explicit = env.EXECUTION_WAKE_ORIGIN?.trim();
  if (explicit) {
    // 비밀값이 평문으로 나가지 않게 http는 이 컴퓨터(로컬 개발)만
    const url = URL.parse(explicit);
    const local = url?.hostname === "localhost" || url?.hostname === "127.0.0.1";
    return url && (url.protocol === "https:" || (url.protocol === "http:" && local)) ? url.origin : null;
  }
  const production = env.VERCEL_PROJECT_PRODUCTION_URL?.trim();
  if (env.VERCEL_ENV === "production" && production) return `https://${production}`;
  if (env.NODE_ENV === "development") return `http://localhost:${env.PORT?.trim() || "3000"}`;
  return null;
}

export type WakeOptions = { origin?: string | null; secret?: string; fetch?: typeof fetch };

/** run의 다음 단계를 새 함수 호출에서 돌게 한다. 받아들여지면 true. 실패해도 던지지 않는다 (sweep이 이어 간다) */
export async function wakeRun(runId: string, options: WakeOptions = {}): Promise<boolean> {
  const origin = options.origin === undefined ? wakeOrigin() : options.origin;
  const secret = options.secret ?? process.env.CRON_SECRET ?? "";
  if (!origin || !secret) return false;
  try {
    const response = await (options.fetch ?? fetch)(new URL(ADVANCE_PATH, origin), {
      method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
      body: JSON.stringify({ run_id: runId }),
      signal: AbortSignal.timeout(WAKE_TIMEOUT_MS),
    });
    if (response.status !== 202) console.error(JSON.stringify({ event: "execution_wake_failed", run: runId, status: response.status }));
    return response.status === 202;
  } catch (error) {
    console.error(JSON.stringify({ event: "execution_wake_failed", run: runId, error: error instanceof Error ? error.name : "unknown" }));
    return false;
  }
}

/** 단계 하나를 돌고(advance), 다음 단계를 붙였으면 깨운다. route의 after()가 부른다. 실패는 로그만 남긴다 (run은 DB에 남아 sweep이 이어 간다) */
export async function advanceAndWake(runId: string): Promise<AdvanceResult | null> {
  try {
    const admin = createAdminClient();
    const store = supabaseExecutionStore(admin);
    const run = await store.loadRun(runId);
    if (!run) return null;
    const llm = { ...llmConfigFromEnv(), fetch: budgetFetch(admin, run.user_id) };
    const result = await advance(
      { store, complete: (request) => completeJson(llm, request), owner: `fn-${randomUUID()}` },
      runId,
    );
    if (result.status === "completed" && result.next) await wakeRun(runId);
    return result;
  } catch (error) {
    console.error(JSON.stringify({ event: "execution_advance_failed", run: runId, error: error instanceof Error ? error.message : "unknown" }));
    return null;
  }
}
