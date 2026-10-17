import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { grantedFeatures } from "@/lib/connectors/google/run";

import { readAll } from "../read-all";
import {
  agentDelivery,
  agentQuestions,
  agentStops,
  agentUsage,
  COMMAND_RETENTION_MS,
  type AgentEventRow,
  type DeliveryCard,
  type DeliveryStep,
  type OpenTask,
  type QuestionCard,
  type StepEvent,
  type StopCard,
  type UsageCard,
} from "./agents";
import {
  connections,
  discoveryCost,
  execution,
  gmailFiltering,
  googleActivity,
  meetingLinkage,
  metricActivity,
  misjudgment,
  missed,
  retention,
  shadowList,
  sourceFailures,
  timeToStart,
  type ActionEventRow,
  type Activity,
  type ExecutionMetric,
  type MetricEventRow,
  type Period,
  type WeeklyCheckRow,
} from "./compute";

// 관리자 지표: 모든 사용자의 이벤트를 service role로 읽어 숫자만 만든다.
// 이벤트의 before · after에는 할 일 제목 · 기한 값이 들어 있지만, 읽자마자 "어느 필드가 바뀌었나"와 상태 값만 남기고 버린다.
// 원문 · 인용은 읽지 않고, 원문 제목은 시험용 원문을 가려낼 때만 서버 쿼리 조건으로 쓴다.
// 주간 질문(weekly_checks)은 답(있다 · 없다 · 건너뜀)만, 연동 요청(connection_requests)은 서비스 이름만 읽는다.
// Gmail · Google 연결은 설정 중 개수(settings.stats)만 읽는다 (주소 · 계정은 읽지 않는다). 회의 원문은 외부 id와 붙은 일정 id만 읽는다.
// 발견 원가는 처리를 마친 원문의 처리 시각과 처리 요약 중 원가(processing_summary.cost)만 읽는다.
// 실행(U2)은 상태 · 시각 · 원가 · 크레딧 숫자 열만 읽는다 (요청 · 계획 · 초안 · receipt는 읽지 않는다).
// 에이전트 카드(OA I-oa)는 토큰 · 숫자 · 시각 · id 열과 JSON 열에서 허용한 키(->>)만 읽는다 (메시지 · 질문 · 답 글, 경로, 산출물 요약, args · receipt · pending_question 통째는 읽지 않는다).

/** 관리자 이메일 (ADMIN_EMAILS, 쉼표로 구분). 비어 있으면 아무도 관리자가 아니다 */
export function isAdmin(email: string | null): boolean {
  const admins = (process.env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return Boolean(email) && admins.includes(email!.toLowerCase());
}

/** 시험용 원문(E2E 검증 스크립트가 만든 것)에서 나온 Action은 지표에서 뺀다 */
const TEST_SOURCE_TITLE_PREFIX = "[E2E 테스트]";

/** 리텐션을 볼 주 수 */
const RETENTION_WEEKS = 4;

type EventRecord = {
  action_id: string;
  user_id: string;
  type: string;
  actor: "ai" | "user" | "agent";
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
  created_at: string;
  source_id: string | null;
};

/** 지표에 필요한 것만 남긴다: 바뀐 필드 이름 · 상태 · 만들 때 확인 요청이었는지 · 누락 신고의 단계. 제목 · 기한 값은 버린다. */
function keep(values: Record<string, unknown> | null): Record<string, unknown> | null {
  if (!values) return null;
  const kept: Record<string, unknown> = {};
  for (const key of ["title", "due", "owner"]) if (key in values) kept[key] = true;
  if ("status" in values) kept.status = values.status;
  if ("needs_confirmation" in values) kept.needs_confirmation = values.needs_confirmation;
  if (typeof values.stage === "string") kept.stage = values.stage;
  return kept;
}

/**
 * 실행 지표 (U2). 실행 표는 마이그레이션 20261021000000 · 20261022000000 뒤에 있다:
 * 읽지 못하면(적용 전 등) null로 두고 다른 지표는 그대로 보여 준다.
 */
export async function loadExecution(admin: SupabaseClient, period: Period): Promise<ExecutionMetric | null> {
  const since = period.from.toISOString();
  try {
    const runs = await readAll<{ state: string; created_at: string }>((from, to) =>
      admin.from("execution_runs").select("state, created_at").gte("created_at", since).order("created_at").order("id").range(from, to),
    );
    // 막힘(hold)과 승인 대기로 간 run 전이만
    const events = await readAll<{ type: string; to_state: string | null; at: string }>((from, to) =>
      admin
        .from("execution_events")
        .select("type, to_state, at")
        .or("type.eq.hold,to_state.eq.waiting_approval")
        .gte("at", since)
        .order("at")
        .order("id")
        .range(from, to),
    );
    const { count: unknownOutcome } = await admin
      .from("execution_steps")
      .select("id", { count: "exact", head: true })
      .eq("state", "unknown_outcome")
      .throwOnError();
    const usage = await readAll<{ cost_usd: number | string | null; cost_status: string; billable: boolean; created_at: string }>((from, to) =>
      admin
        .from("execution_usage")
        .select("cost_usd, cost_status, billable, created_at")
        .gte("created_at", since)
        .order("created_at")
        .order("id")
        .range(from, to),
    );
    const settles = await readAll<{ credits: number; rate_version: string; created_at: string }>((from, to) =>
      admin
        .from("credit_ledger")
        .select("credits, rate_version, created_at")
        .eq("kind", "settle")
        .gte("created_at", since)
        .order("created_at")
        .order("id")
        .range(from, to),
    );
    const { data: rates } = await admin.from("credit_rates").select("version, usd_per_credit").throwOnError();
    const usdPerCredit = new Map((rates ?? []).map((r) => [r.version as string, Number(r.usd_per_credit)]));

    return execution(
      {
        runs: runs.map((r) => ({ state: r.state, createdAt: r.created_at })),
        events: events.map((e) => ({ type: e.type, toState: e.to_state, at: e.at })),
        unknownOutcome: unknownOutcome ?? 0,
        // numeric 열: 문자열로 와도 숫자로 읽는다
        usage: usage.map((u) => ({
          costUsd: u.cost_usd === null ? null : Number(u.cost_usd),
          confirmed: u.cost_status === "confirmed",
          billable: u.billable,
          at: u.created_at,
        })),
        settles: settles.map((s) => ({ credits: s.credits, usdPerCredit: usdPerCredit.get(s.rate_version) ?? null, at: s.created_at })),
      },
      period,
    );
  } catch (error) {
    console.error("실행 지표 읽기 실패:", error instanceof Error ? error.message : error);
    return null;
  }
}

export type AgentMetrics = { usage: UsageCard | null; delivery: DeliveryCard | null; questions: QuestionCard | null; stops: StopCard | null };

const AGENT_STEP_KINDS = ["agent_message", "agent_cancel"];
const DELIVERY_STATES = ["queued", "not_sent", "dispatched", "expired", "cancelled"];
/** 단계 사건 중 지연 · 결과에 쓰는 전이 (집어 감 = calling, 접수 = called, 끝남 = failed · skipped) */
const STEP_EVENT_STATES = ["calling", "called", "failed", "skipped"];
/** bridge_sweep의 lease_busy와 같은 값: 5초 넘게 만료한 채 남은 calling 단계 수 (src/lib/bridge/sweep.ts) */
const OVERDUE_LEASE_GRACE_SECONDS = 5;
/** 열린 충돌만 고르는 하한 (conflict_at이 있는 lease) */
const EPOCH = "1970-01-01T00:00:00Z";
/** in()에 한 번에 넣는 id 수 */
const ID_CHUNK = 100;

type StepRecord = {
  id: string;
  kind: string;
  provider: string | null;
  purpose: string;
  created_at: string;
  task_id: string | null;
  request_id: string | null;
  answer_message_id: string | null;
  answered_locally: string | null;
  reason: string | null;
};
type AgentEventRecord = { at: string; event_type: string; status: string; kind: string | null; question_key: unknown };

/** 한 번 읽고 나눠 쓴다: 읽기가 실패하면 그것을 쓰는 카드가 모두 실패한다 (카드마다 따로 로그) */
function once<T>(read: () => Promise<T>): () => Promise<T> {
  let promise: Promise<T> | undefined;
  return () => (promise ??= read());
}

/** 카드 하나: 읽기가 던지면 그 카드만 null. 로그에는 카드 이름과 오류 이름만 남긴다 (메시지 · 값은 쓰지 않는다) */
async function card<T>(name: string, read: () => Promise<T>): Promise<T | null> {
  try {
    return await read();
  } catch (error) {
    console.error(JSON.stringify({ event: "agent_metrics_failed", card: name, error: error instanceof Error ? error.name : "unknown" }));
    return null;
  }
}

/**
 * 에이전트 지표 카드 넷 (OA I-oa): 이미 남은 행을 읽어 센다. 새 이벤트 · 마이그레이션은 없다.
 * 카드마다 실패를 가둔다: 에이전트 표가 없는 환경(마이그레이션 전)에서도 지표 1–5는 그대로 보인다.
 */
export async function loadAgentMetrics(admin: SupabaseClient, period: Period): Promise<AgentMetrics> {
  const since = period.from.toISOString();
  const until = period.to.toISOString();

  const steps = once(() =>
    readAll<StepRecord>((from, to) =>
      admin
        .from("execution_steps")
        .select(
          "id, kind, provider, purpose, created_at, task_id:args->>agent_task_id, request_id:args->>provider_request_id, answer_message_id:args->>answer_message_id, answered_locally:args->>answered_locally, reason:receipt->>reason",
        )
        .in("kind", AGENT_STEP_KINDS)
        .gte("created_at", since)
        .order("created_at")
        .order("id")
        .range(from, to),
    ).then((rows): DeliveryStep[] =>
      rows.map((r) => ({
        id: r.id,
        kind: r.kind,
        adapter: r.provider,
        purpose: r.purpose,
        createdAt: r.created_at,
        taskId: r.task_id,
        requestId: r.request_id,
        answerMessageId: r.answer_message_id,
        answeredLocally: r.answered_locally,
        receiptReason: r.reason,
      })),
    ),
  );

  const stepEvents = once(async (): Promise<StepEvent[]> => {
    // 기간 안에 만든 단계의 사건만 (단계 · 사건은 지우지 않으므로 90일 보기도 그대로 된다)
    const ids = (await steps()).filter((step) => Date.parse(step.createdAt) < period.to.getTime()).map((step) => step.id);
    const events: StepEvent[] = [];
    for (let i = 0; i < ids.length; i += ID_CHUNK) {
      const chunk = ids.slice(i, i + ID_CHUNK);
      const rows = await readAll<{ step_id: string; to_state: string; gate: string | null; at: string }>((from, to) =>
        admin
          .from("execution_events")
          .select("step_id, to_state, gate, at")
          .eq("type", "step")
          .in("to_state", STEP_EVENT_STATES)
          .in("step_id", chunk)
          .order("at")
          .order("id")
          .range(from, to),
      );
      events.push(...rows.map((r) => ({ stepId: r.step_id, toState: r.to_state, gate: r.gate, at: r.at })));
    }
    return events;
  });

  // 질문 · 끝난 턴 사건: 감사 payload의 허용한 키만 (question_key = [작업 id, 요청 id])
  const agentEvents = once(async (): Promise<AgentEventRow[]> => {
    const rows = await readAll<AgentEventRecord>((from, to) =>
      admin
        .from("execution_events")
        .select("at, event_type:payload->>event_type, status:payload->>status, kind:payload->>kind, question_key:payload->question_key")
        .eq("type", "agent")
        .in("payload->>event_type", ["question", "turn_completed"])
        .gte("at", since)
        .lt("at", until)
        .order("at")
        .order("id")
        .range(from, to),
    );
    return rows.map((r) => {
      const key = Array.isArray(r.question_key) ? r.question_key : [];
      return {
        at: r.at,
        eventType: r.event_type,
        status: r.status,
        kind: r.kind,
        taskId: typeof key[0] === "string" ? key[0] : null,
        requestId: typeof key[1] === "string" ? key[1] : null,
      };
    });
  });

  // 지금 열린 작업: 답을 기다리는 것 · 연결이 끊긴 것
  const openTasks = once(async (): Promise<OpenTask[]> => {
    const rows = await readAll<{ id: string; state: string; request_id: string | null }>((from, to) =>
      admin
        .from("agent_tasks")
        .select("id, state, request_id:pending_question->>provider_request_id")
        .in("state", ["awaiting_answer", "unreachable"])
        .order("id")
        .range(from, to),
    );
    return rows.map((r) => ({ id: r.id, state: r.state, requestId: r.request_id }));
  });

  const [usage, delivery, questions, stops] = await Promise.all([
    card("usage", async (): Promise<UsageCard> => {
      // 모르는 type을 세려고 기간 안의 지표 이벤트를 type 필터 없이 읽는다 (props는 토큰 · 숫자뿐)
      const rows = await readAll<{ user_id: string; type: string; at: string; props: unknown }>((from, to) =>
        admin.from("metric_events").select("user_id, type, at, props").gte("at", since).lt("at", until).order("at").order("id").range(from, to),
      );
      // 에이전트에게 맡겨 이슈가 생김: action_events의 rule 열 (TT: user_created, rule assistant_agent)
      const issues = await readAll<{ user_id: string; created_at: string }>((from, to) =>
        admin
          .from("action_events")
          .select("user_id, created_at")
          .eq("type", "user_created")
          .eq("rule", "assistant_agent")
          .gte("created_at", since)
          .lt("created_at", until)
          .order("created_at")
          .order("id")
          .range(from, to),
      );
      return agentUsage(
        rows.map((r) => ({ userId: r.user_id, type: r.type, at: r.at, props: r.props })),
        issues.map((r) => ({ userId: r.user_id, at: r.created_at })),
        period,
      );
    }),
    card("delivery", async (): Promise<DeliveryCard> => {
      const [stepRows, events] = await Promise.all([steps(), stepEvents()]);
      const messages = await readAll<{ id: string; delivery_state: string; delivery_reason: string | null; created_at: string }>((from, to) =>
        admin
          .from("conversation_messages")
          .select("id, delivery_state, delivery_reason, created_at")
          .in("delivery_state", DELIVERY_STATES)
          .gte("created_at", since)
          .lt("created_at", until)
          .order("created_at")
          .order("id")
          .range(from, to),
      );
      // 명령은 끝난 뒤 30일이 지나면 지운다: 그보다 먼 과거는 읽지 않는다
      const commandsSince = new Date(Math.max(period.from.getTime(), period.to.getTime() - COMMAND_RETENTION_MS)).toISOString();
      const commands = await readAll<{ kind: string; outcome: string | null; created_at: string }>((from, to) =>
        admin.from("bridge_commands").select("kind, outcome, created_at").gte("created_at", commandsSince).lt("created_at", until).order("created_at").order("id").range(from, to),
      );
      return agentDelivery(
        {
          steps: stepRows,
          events,
          messages: messages.map((r) => ({ id: r.id, deliveryState: r.delivery_state, deliveryReason: r.delivery_reason, createdAt: r.created_at })),
          commands: commands.map((r) => ({ kind: r.kind, outcome: r.outcome, createdAt: r.created_at })),
        },
        period,
      );
    }),
    card("questions", async (): Promise<QuestionCard> => {
      const [stepRows, events, tasks] = await Promise.all([steps(), agentEvents(), openTasks()]);
      return agentQuestions({ events, steps: stepRows, tasks }, period);
    }),
    card("stops", async (): Promise<StopCard> => {
      const [events, tasks] = await Promise.all([agentEvents(), openTasks()]);
      // 대화 run이 멈춘 까닭: task run의 stopped는 세지 않는다
      const stopEvents = await readAll<{ run_id: string; gate: string | null; at: string }>((from, to) =>
        admin
          .from("execution_events")
          .select("run_id, gate, at")
          .eq("type", "run")
          .eq("to_state", "stopped")
          .gte("at", since)
          .lt("at", until)
          .order("at")
          .order("id")
          .range(from, to),
      );
      const runIds = [...new Set(stopEvents.map((e) => e.run_id))];
      const conversationRunIds = new Set<string>();
      for (let i = 0; i < runIds.length; i += ID_CHUNK) {
        const chunk = runIds.slice(i, i + ID_CHUNK);
        const rows = await readAll<{ id: string }>((from, to) => admin.from("execution_runs").select("id").eq("kind", "conversation").in("id", chunk).order("id").range(from, to));
        for (const row of rows) conversationRunIds.add(row.id);
      }
      const { count, error: countError } = await admin.from("execution_steps").select("id", { count: "exact", head: true }).in("kind", AGENT_STEP_KINDS).eq("state", "unknown_outcome");
      if (countError) throw countError;
      const { data: overdue, error: overdueError } = await admin.rpc("count_overdue_agent_step_leases", { p_grace_seconds: OVERDUE_LEASE_GRACE_SECONDS });
      if (overdueError) throw overdueError;
      const conflicts = await readAll<{ conflict_at: string }>((from, to) =>
        admin.from("agent_path_leases").select("conflict_at").gt("conflict_at", EPOCH).order("conflict_at").order("id").range(from, to),
      );
      return agentStops(
        {
          stopEvents: stopEvents.map((e) => ({ runId: e.run_id, gate: e.gate, at: e.at })),
          conversationRunIds,
          events,
          overdueLeases: Number(overdue ?? 0),
          unknownOutcome: count ?? 0,
          tasks,
          conflicts: conflicts.map((c) => ({ conflictAt: c.conflict_at })),
        },
        period,
      );
    }),
  ]);
  return { usage, delivery, questions, stops };
}

export async function loadMetrics(admin: SupabaseClient, period: Period) {
  const since = period.from.toISOString();

  // 시험용 원문에서 만든 Action (기간과 상관없이)
  const { data: testSources } = await admin.from("sources").select("id").like("title", `${TEST_SOURCE_TITLE_PREFIX}%`).throwOnError();
  const testSourceIds = (testSources ?? []).map((s) => s.id as string);
  const testActions = new Set<string>();
  for (let i = 0; i < testSourceIds.length; i += 100) {
    const { data } = await admin.from("evidence").select("action_id").eq("role", "created").in("source_id", testSourceIds.slice(i, i + 100)).throwOnError();
    for (const row of (data ?? []) as { action_id: string }[]) testActions.add(row.action_id);
  }

  const events = await readAll<EventRecord>((from, to) =>
    admin
      .from("action_events")
      .select("action_id, user_id, type, actor, before, after, created_at, source_id")
      .gte("created_at", since)
      .order("created_at")
      .order("id")
      .range(from, to),
  );
  // 리텐션은 사용자의 처음 활동부터 본다 (기간으로 자르면 오래 쓴 사용자가 새 사용자로 보인다).
  // 착수 시간도 Action마다 처음 착수만 세므로 처음부터 읽는다.
  const metricEvents = await readAll<{ user_id: string; type: string; action_id: string | null; at: string; provider: string | null }>((from, to) =>
    admin.from("metric_events").select("user_id, type, action_id, at, provider").order("at").order("id").range(from, to),
  );
  const weeklyChecks = await readAll<{ user_id: string; week_start: string; answer: WeeklyCheckRow["answer"]; answered_at: string }>((from, to) =>
    admin.from("weekly_checks").select("user_id, week_start, answer, answered_at").gte("answered_at", since).order("answered_at").order("id").range(from, to),
  );
  // 본 것 표시(user_seen, U1 바뀜 점)는 사용자의 쓰기가 아니라 활동에 넣지 않는다 (리텐션 정의를 바꾸지 않게)
  const userWrites = await readAll<{ user_id: string; action_id: string; created_at: string }>((from, to) =>
    admin
      .from("action_events")
      .select("user_id, action_id, created_at")
      .eq("actor", "user")
      .neq("type", "user_seen")
      .order("created_at")
      .order("id")
      .range(from, to),
  );

  // 이벤트의 원문 종류: 할 일 DB에서 온 Action은 AI 판단이 아니다
  const sourceIds = [...new Set(events.map((e) => e.source_id).filter((id): id is string => Boolean(id)))];
  const sources = new Map<string, string>();
  for (let i = 0; i < sourceIds.length; i += 100) {
    const { data } = await admin.from("sources").select("id, kind").in("id", sourceIds.slice(i, i + 100)).throwOnError();
    for (const s of (data ?? []) as { id: string; kind: string }[]) sources.set(s.id, s.kind);
  }

  const rows: ActionEventRow[] = events
    .filter((e) => !testActions.has(e.action_id))
    .map((e) => ({
      actionId: e.action_id,
      userId: e.user_id,
      type: e.type,
      actor: e.actor,
      before: keep(e.before),
      after: keep(e.after),
      at: e.created_at,
      sourceKind: e.source_id ? (sources.get(e.source_id) ?? null) : null,
      // 직접 추가(user_created)는 원문 구절을 골랐을 때만 source_id가 있다 (지표 4는 그것만 센다, A42)
      hasSource: e.source_id !== null,
    }));
  const metrics: MetricEventRow[] = metricEvents
    .filter((e) => !e.action_id || !testActions.has(e.action_id))
    .map((e) => ({ userId: e.user_id, type: e.type, actionId: e.action_id, at: e.at, provider: e.provider }));
  const activity: Activity[] = [
    // 연결 완료 · 만료 · 재연결 알림은 서버가 남기는 이벤트라 활동(앱 열기 · 착수 · 수정 · 확인)에 넣지 않는다 (리텐션 정의를 바꾸지 않게)
    ...metricActivity(metrics),
    ...userWrites.filter((e) => !testActions.has(e.action_id)).map((e) => ({ userId: e.user_id, at: e.created_at })),
  ];

  // 2단계 연동 "원해요": 서비스 이름만 읽는다
  const connectionRequests = await readAll<{ provider: string }>((from, to) =>
    admin.from("connection_requests").select("provider").order("created_at").order("id").range(from, to),
  );

  const gmailStats = await readAll<{ stats: unknown }>((from, to) =>
    admin.from("connections").select("stats:settings->stats").eq("provider", "gmail").order("id").range(from, to),
  );

  const googleStats = await readAll<{ user_id: string; stats: unknown; scopes: unknown }>((from, to) =>
    admin.from("connections").select("user_id, stats:settings->stats, scopes:settings->scopes").eq("provider", "google").order("id").range(from, to),
  );
  // Calendar를 허용한 google 연결이 있는 사용자: 그 사용자의 Notion 회의록만 "일정이 붙은 비율"의 분모에 든다
  const calendarUsers = new Set(
    googleStats
      .filter((row) => Array.isArray(row.scopes) && grantedFeatures(row.scopes.filter((scope): scope is string => typeof scope === "string")).calendar)
      .map((row) => row.user_id),
  );
  // 회의 원문에 일정이 붙은 비율: 기간 안에 들어온 회의 원문의 외부 id와 붙은 일정 id만 읽는다 (sources.meeting은 마이그레이션 20261016000000 뒤에 있다)
  const meetingRows = await readAll<{ user_id: string; external_id: string | null; calendar_event_id: string | null }>((from, to) =>
    admin
      .from("sources")
      .select("user_id, external_id, calendar_event_id:meeting->>calendar_event_id")
      .eq("kind", "meeting")
      .gte("created_at", since)
      .order("created_at")
      .order("id")
      .range(from, to),
  ).catch((error) => {
    console.error("회의 원문 일정 지표 읽기 실패:", error instanceof Error ? error.message : error);
    return [];
  });

  // 발견 원가 (A43): 기간 안에 처리를 마친 글 원문의 처리 시각과 원가만 읽는다
  const costRows = await readAll<{ processed_at: string | null; cost: unknown }>((from, to) =>
    admin
      .from("sources")
      .select("processed_at, cost:processing_summary->cost")
      .eq("processing_status", "done")
      .neq("kind", "task")
      .gte("processed_at", since)
      .order("processed_at")
      .order("id")
      .range(from, to),
  );

  const executionMetric = await loadExecution(admin, period);
  const agents = await loadAgentMetrics(admin, period);

  const misjudged = misjudgment(rows, period);
  return {
    period,
    excludedTestActions: testActions.size,
    misjudgment: misjudged,
    start: timeToStart(metrics, period),
    retention: retention(activity, period.to, RETENTION_WEEKS),
    // 누락 신고(POST /api/v1/sources/:id/missing, Phase A1) · 원문 구절을 고른 직접 추가. 구절 없는 직접 추가는 따로 센다
    missed: missed(rows, misjudged, period, true),
    discoveryCost: discoveryCost(
      costRows.map((row) => ({ processedAt: row.processed_at, cost: row.cost })),
      period,
    ),
    sourceFailures: sourceFailures(metrics, period),
    execution: executionMetric,
    agents,
    connections: connections(metrics, connectionRequests, period),
    gmail: gmailFiltering(gmailStats.map((row) => row.stats)),
    google: googleActivity(googleStats.map((row) => row.stats)),
    meetingLinkage: meetingLinkage(meetingRows, calendarUsers),
    shadowList: shadowList(
      weeklyChecks.map((c) => ({ userId: c.user_id, weekStart: c.week_start, answer: c.answer, at: c.answered_at })),
      period,
    ),
  };
}

export type MetricsReport = Awaited<ReturnType<typeof loadMetrics>>;
