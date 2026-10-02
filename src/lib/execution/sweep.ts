import type { GenerationLookup } from "@/lib/ai/generation";

import { RECONCILE_WINDOW_HOURS, SWEEP_RECONCILE_LIMIT, SWEEP_RELEASE_LIMIT, SWEEP_WAKE_LIMIT } from "./limits";
import type { ExecutionStore } from "./types";

// 실행 sweep (Vercel Cron 1분, GET /api/cron/execution-sweep). 깨우기를 놓친 run과 막혔다 풀린 run을 이어 간다 (EXECUTION 2 · 3 · 12장).
// 단계를 직접 돌리지 않는다: 이어 갈 run마다 자기 호출(wake)로 새 함수 호출에 맡긴다 (함수 호출 한 번 = 단계 하나).
// 모두 다시 해도 같은 결과인 RPC라 겹쳐 돌아도 된다. 한 번에 다루는 양은 정해 둔다(limits.ts).
//   ① sweep_expire: lease가 끝난 calling → 내부 효과는 다시 준비(2번을 넘으면 실패), 외부 효과는 결과 불명
//   ② 미확정 원가: generation 조회로 비용을 찾으면 reconcile_usage (행마다 RPC 한 번, 찾으면 그 단계를 정산)
//   ③ 보조 안전망: 끝난 run에 남은 예약 → release_run_credits (run마다 RPC 한 번, 한 트랜잭션에서 여러 run을 잠그지 않는다)
//   ④ 이어 갈 run 깨우기: 끝나지 않았고 부르는 중인 단계가 없는 run (다시 준비된 재시도 · 승인 대기 · 막힌 run 포함, begin_call이 다시 본다)
// 한 단계가 실패해도 다음 단계는 한다 (실패 수만 errors에 센다). 로그에는 숫자만 남긴다.

export type SweepDeps = {
  store: ExecutionStore;
  /** OpenRouter generation 조회 (generation.ts fetchGeneration) */
  lookupGeneration: (generationId: string) => Promise<GenerationLookup>;
  /** 자기 호출로 run의 다음 단계를 맡긴다 (wake.ts wakeRun) */
  wake: (runId: string) => Promise<boolean>;
  now?: () => Date;
};

export type SweepResult = {
  expired: number;
  reconciled: number;
  released: number;
  woken: number;
  wake_failed: number;
  errors: number;
};

export async function sweep(deps: SweepDeps): Promise<SweepResult> {
  const { store } = deps;
  const result: SweepResult = { expired: 0, reconciled: 0, released: 0, woken: 0, wake_failed: 0, errors: 0 };
  const phase = async (name: string, run: () => Promise<void>) => {
    try {
      await run();
    } catch (error) {
      result.errors++;
      console.error(JSON.stringify({ event: "execution_sweep_error", phase: name, error: error instanceof Error ? error.message : "unknown" }));
    }
  };

  await phase("expire", async () => {
    result.expired = await store.sweepExpire();
  });

  await phase("reconcile", async () => {
    const since = new Date((deps.now?.() ?? new Date()).getTime() - RECONCILE_WINDOW_HOURS * 3_600_000);
    const rows = await store.unconfirmedUsage(SWEEP_RECONCILE_LIMIT, since);
    // 조회는 함께 (시간 한도 10초씩), 확정은 행마다 RPC 한 번 (원가 행 → 계정 순서로 잠근다)
    const lookups = await Promise.all(rows.map((row) => deps.lookupGeneration(row.generation_id).catch(() => null)));
    for (const [i, lookup] of lookups.entries()) {
      if (lookup?.status !== "found") continue;
      if (await store.reconcileUsage(rows[i].id, lookup.generation.costUsd)) result.reconciled++;
    }
  });

  await phase("release", async () => {
    for (const runId of await store.openEndedCreditRuns(SWEEP_RELEASE_LIMIT)) {
      result.released += await store.releaseRunCredits(runId);
    }
  });

  await phase("wake", async () => {
    const woken = await Promise.all((await store.wakeableRuns(SWEEP_WAKE_LIMIT)).map((runId) => deps.wake(runId)));
    result.woken = woken.filter(Boolean).length;
    result.wake_failed = woken.length - result.woken;
  });

  return result;
}
