import { z } from "zod";

import type { CreditDetails, CreditTotals } from "@/lib/execution/credit-details";
import { DRAFT_ESTIMATE_CREDITS } from "@/lib/execution/limits";
import { RunActionNotFoundError } from "@/lib/execution/types";

import { consentRequired } from "./consent";
import {
  createRunRequestSchema,
  type CreateRunRequest,
  type CreateRunResponse,
  type CreditsResponse,
  type RunSummary,
  type StopRunResponse,
} from "./contract";
import { retryAfterSeconds } from "./rate-limit";
import { errorResponse, parseBody, unauthorized } from "./respond";

// 실행 route 처리 (U2, docs/EXECUTION.md): POST /api/v1/runs · POST /api/v1/runs/:id/stop · GET /api/v1/credits.
// 인증 · 판단 · 저장을 인자로 받아 Route Handler 밖에서 테스트한다. 요청 글(request)은 로그에 남기지 않는다.
// 입구 확인 순서: 기능 플래그 → 로그인 → 실행 주체 허용 목록. 플래그가 꺼졌거나 허용 목록 밖이면 404 (존재를 드러내지 않는다).
// 부르기 전 판단(차단 스위치 · 허용 목록 · 크레딧)은 실행기의 begin_call이 한다. route의 확인은 막힐 run을 만들지 않으려는 것뿐이다.

export const EXECUTION_UNAVAILABLE_MESSAGE = "실행 기능을 쓸 수 없습니다.";
const unavailable = () => errorResponse(404, "not_found", EXECUTION_UNAVAILABLE_MESSAGE);

export type ExecutionGateDeps<User> = {
  /** EXECUTION_ENABLED (env.ts executionEnabled) */
  enabled: () => boolean;
  authenticate: (request: Request) => Promise<User | null>;
  /** 실행 주체 허용 목록(execution_actors) 안인가 */
  isActor: (user: User) => Promise<boolean>;
};

async function gate<User>(request: Request, deps: ExecutionGateDeps<User>): Promise<{ user: User } | { error: Response }> {
  if (!deps.enabled()) return { error: unavailable() };
  const user = await deps.authenticate(request);
  if (!user) return { error: unauthorized() };
  if (!(await deps.isActor(user))) return { error: unavailable() };
  return { user };
}

export type CreateRunDeps<User> = ExecutionGateDeps<User> & {
  /** 차단 스위치의 전체 행이 막혔거나 없다. 막혀 있으면 새 run을 받지 않는다 (만들어도 begin_call이 막아 기다리기만 한다) */
  globallyBlocked: () => Promise<boolean>;
  hasConsent: (user: User) => Promise<boolean>;
  /** 사용자 권한(RLS)으로 Action이 열려 있는지 본다 (없거나 남의 것이면 false) */
  actionOpen: (user: User, actionId: string) => Promise<boolean>;
  /** 한도(10분에 10번)에 찼으면 다시 할 수 있는 시각, 아니면 시도를 남기고 null */
  rateLimit: (user: User) => Promise<Date | null>;
  /** create_run (run + 첫 계획 단계, 실행 이벤트는 같은 트랜잭션). 열린 Action이 아니면 RunActionNotFoundError */
  createRun: (user: User, run: CreateRunRequest) => Promise<string>;
  loadRun: (user: User, runId: string) => Promise<RunSummary | null>;
  /** 응답 뒤 첫 단계(계획)를 돈다 (after()) */
  schedule: (runId: string) => void;
  now?: () => Date;
};

export async function handleCreateRun<User>(request: Request, deps: CreateRunDeps<User>): Promise<Response> {
  const gated = await gate(request, deps);
  if ("error" in gated) return gated.error;
  const { user } = gated;
  const body = await parseBody(request, createRunRequestSchema);
  if ("error" in body) return body.error;
  // 초안 한 건의 예약보다 작은 예산은 초안을 한 번도 부르지 못하고 지급으로도 풀리지 않는다
  if (body.data.budget_credits !== undefined && body.data.budget_credits < DRAFT_ESTIMATE_CREDITS) {
    return errorResponse(400, "invalid_request", `잘못된 필드: budget_credits (${DRAFT_ESTIMATE_CREDITS} 이상)`);
  }

  try {
    if (await deps.globallyBlocked()) return unavailable();
    // 계획 · 초안 단계가 근거 원문을 외부 AI로 보낸다
    if (!(await deps.hasConsent(user))) return consentRequired();
    if (!(await deps.actionOpen(user, body.data.action_id))) return errorResponse(404, "not_found", "열린 Action이 없습니다.");
    const retryAt = await deps.rateLimit(user);
    if (retryAt) {
      const response = errorResponse(429, "rate_limited", "실행 요청이 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, deps.now?.() ?? new Date())));
      return response;
    }
    const runId = await deps.createRun(user, body.data);
    const run = await deps.loadRun(user, runId);
    if (!run) throw new Error("만든 run을 읽지 못했습니다");
    deps.schedule(runId);
    return Response.json({ run } satisfies CreateRunResponse, { status: 202 });
  } catch (error) {
    if (error instanceof RunActionNotFoundError) return errorResponse(404, "not_found", "열린 Action이 없습니다.");
    console.error("run 만들기 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "실행을 시작하지 못했습니다.");
  }
}

export type StopRunDeps<User> = ExecutionGateDeps<User> & {
  /** stop_run: 멈춘 뒤의 run 상태, 그 사용자의 run이 없으면 null. 교착(40P01)이면 다시 부른다 */
  stopRun: (user: User, runId: string) => Promise<string | null>;
  loadRun: (user: User, runId: string) => Promise<RunSummary | null>;
};

export async function handleStopRun<User>(request: Request, runId: string, deps: StopRunDeps<User>): Promise<Response> {
  const gated = await gate(request, deps);
  if ("error" in gated) return gated.error;
  const notFound = () => errorResponse(404, "not_found", "run이 없습니다.");
  if (!z.uuid().safeParse(runId).success) return notFound();
  try {
    // 이미 끝난 run은 바꾸지 않고 그 상태를 돌려준다 (다시 눌러도 같다)
    if ((await deps.stopRun(gated.user, runId)) === null) return notFound();
    const run = await deps.loadRun(gated.user, runId);
    if (!run) return notFound();
    return Response.json({ run } satisfies StopRunResponse);
  } catch (error) {
    console.error("run 멈추기 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "멈추지 못했습니다.");
  }
}

export type CreditsDeps<User> = ExecutionGateDeps<User> & {
  /** 계정 행의 합계 (store.ts loadCredits) */
  credits: (user: User) => Promise<CreditTotals>;
  /** 원장에서 세는 S3 숫자: 진행 중 run · 정산 보류 · since 이후 사용 (store.ts loadCreditDetails) */
  details: (user: User, since: Date) => Promise<CreditDetails>;
  /** 차단 스위치의 전체 행이 막혔거나 없다 (POST /runs가 404로 받지 않는 상태) */
  globallyBlocked: () => Promise<boolean>;
  now?: () => Date;
};

const sinceSchema = z.iso.datetime({ offset: true });

/**
 * used를 셀 시작 시각 (?since=). 없으면 UTC 이번 달 1일. 오프셋 없는 시각 · 날짜만 · 형식 오류 · 미래 · 1년 넘게 전이면 null (400).
 * 앱은 기기 시간대의 이번 달 1일 00:00을 보낸다
 */
function creditsSince(url: URL, now: Date): Date | null {
  const raw = url.searchParams.get("since");
  if (raw === null) return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  if (!sinceSchema.safeParse(raw).success) return null;
  const since = new Date(raw);
  if (Number.isNaN(since.getTime())) return null;
  const yearAgo = new Date(now);
  yearAgo.setUTCFullYear(now.getUTCFullYear() - 1);
  return since > now || since < yearAgo ? null : since;
}

export async function handleCredits<User>(request: Request, deps: CreditsDeps<User>): Promise<Response> {
  const gated = await gate(request, deps);
  if ("error" in gated) return gated.error;
  const since = creditsSince(new URL(request.url), deps.now?.() ?? new Date());
  if (!since) return errorResponse(400, "invalid_request", "잘못된 필드: since (오프셋이 있는 ISO 8601, 지금부터 1년 안)");
  try {
    const [totals, details, blocked] = await Promise.all([deps.credits(gated.user), deps.details(gated.user, since), deps.globallyBlocked()]);
    return Response.json({
      ...totals,
      ...details,
      accepting_runs: !blocked,
      draft_estimate_credits: DRAFT_ESTIMATE_CREDITS,
    } satisfies CreditsResponse);
  } catch (error) {
    console.error("크레딧 읽기 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "크레딧을 읽지 못했습니다.");
  }
}
