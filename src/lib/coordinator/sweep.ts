import { runCoordinator, type CoordinatorDeps, type RunSummary } from "./coordinate";
import {
  RECOVERY_EVERY_MINUTES,
  RECOVERY_LIMIT,
  RECOVERY_LOOKBACK_SECONDS,
  TIMER_ENQUEUE_LIMIT,
  URGENT_WINDOW_HOURS,
} from "./coordinator.config";

// 코디네이터 한 번 돌기 (POST /api/cron/coordinator-advance가 after()에서 부른다. 1분 sweep이 execution-sweep을 통해 이 route를 깨운다).
// 순서: ① 기한 창 timer 적재 ② (30분마다) 삼킨 적재 회수 ③ 사건 처리. 단계마다 실패를 가둔다 (한 단계가 실패해도 다음 단계는 한다, 실패 수만 센다).
// COORDINATOR_ENABLED가 꺼져 있으면 이 함수를 부르는 route가 없다: 적재(생산자 트리거)만 있고 집기 · 처리 · 모델 · 깨우기는 0이다.
// 로그에는 숫자만 남긴다. 사건의 refs · 결과 id도 남기지 않는다.

export type PassDeps = CoordinatorDeps & { consumer: string; now?: () => Date; runOptions?: { maxEvents?: number; timeBudgetMs?: number; claimBatch?: number } };

export type PassResult = {
  timers: number;
  recovered: number;
  run: (RunSummary & { more: boolean }) | null;
  errors: number;
};

export async function coordinatorPass(deps: PassDeps): Promise<PassResult> {
  const now = deps.now?.() ?? new Date();
  const result: PassResult = { timers: 0, recovered: 0, run: null, errors: 0 };
  const phase = async (name: string, run: () => Promise<void>) => {
    try {
      await run();
    } catch (error) {
      result.errors++;
      console.error(JSON.stringify({ event: "coordinator_pass_error", phase: name, error: error instanceof Error ? error.name : "unknown" }));
    }
  };

  await phase("timers", async () => {
    result.timers = await deps.store.enqueueDueTimers(URGENT_WINDOW_HOURS * 3600, TIMER_ENQUEUE_LIMIT);
  });

  await phase("recover", async () => {
    if (now.getUTCMinutes() % RECOVERY_EVERY_MINUTES !== 0) return;
    result.recovered = await deps.store.recoverMissing(RECOVERY_LOOKBACK_SECONDS, RECOVERY_LIMIT);
  });

  await phase("process", async () => {
    result.run = await runCoordinator(deps, { consumer: deps.consumer, ...deps.runOptions });
  });

  return result;
}
