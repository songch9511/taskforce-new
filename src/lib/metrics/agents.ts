// OA I-oa: 에이전트 지표 카드. 이벤트 등록부 + 순수 계산 (읽기는 load.ts의 loadAgentMetrics, 화면은 /admin/metrics).
//
// 새 이벤트를 만들지 않는다. 각 WP가 이미 남긴 행(metric_events · execution_events · execution_steps · bridge_commands ·
// conversation_messages의 상태 열 · agent_tasks · agent_path_leases)을 읽어 센다. 글 0: 받는 값은 토큰 · 숫자 · 시각 · id뿐이다.
// 지연 · 기다린 시간은 서버 트랜잭션 시각끼리만 뺀다 (Mac 시계 값은 쓰지 않는다). 백분위는 nearest-rank (= percentile_disc).
// 목록의 집은 이 파일이다: 문서(docs/design/taskforce-0.2.0-assistant-contract-2026-10-12.md 8장 끝)는 이 파일을 가리킨다.
// tests/metrics/agent-event-registry.test.ts가 최신 CHECK ↔ 이 등록부 ↔ 원천 함수 ↔ 시험 파일을 정적으로 대조한다.

import { BRIDGE_COMMAND_RETENTION_DAYS } from "@/lib/execution/limits";

import type { Period } from "./compute";

// ─── 이벤트 등록부 ───

/** 이벤트를 남기는 곳: SQL 함수(최신 정의가 metric_events에 쓴다) 또는 TS 파일(그 파일이 type을 insert한다) */
export type EventSource = { kind: "sql"; fn: string } | { kind: "ts"; file: string };

export type AgentEventSpec = {
  type: string;
  /** 남기는 곳. 비어 있으면 아직 남기는 곳이 없다 (gap에 이유) */
  sources: EventSource[];
  /** 카드 ①이 adapter 말고 가르는 props 키 (토큰 · 불리언만) */
  dims: string[];
  /** 숫자 props 키: 카드 ①이 p50 · p95를 보인다 */
  numeric?: string;
  /** 리텐션 활동인가. 사용자가 그 시각에 한 일이면 true, 서버가 사용자 없이 남기면 false (compute.ts SERVER_EVENTS와 같아야 한다) */
  activity: boolean;
  /** 측정 공백 */
  gap?: string;
};

const sql = (fn: string): EventSource => ({ kind: "sql", fn });

/** OA 지표 type 19개 (CHECK 블록 v3, 20261123000000_agent_path_leases.sql + 외부 세션 2개: 20261203000000_external_sessions_list.sql · 20261204000000_agent_session_attach.sql). 1–11 · 17이 에이전트 대화, 12–16이 프로젝트 · 이슈 정리, 18이 외부 세션 목록, 19가 외부 세션 이어받기 */
export const AGENT_EVENTS: readonly AgentEventSpec[] = [
  // 전달 시작마다: 사용자가 보낸 순간이 아니라 대기열 · 재전달 · Mac 복귀 때도 생긴다 (리텐션 활동이 아니다, Q5)
  { type: "agent_message_sent", sources: [sql("start_agent_turn")], dims: [], activity: false },
  // 저장 뒤 insert라 실패하면 그 지표만 빠진다 (agent-gateway.md)
  { type: "context_attached", sources: [{ kind: "ts", file: "src/lib/agents/messages.ts" }], dims: ["target_kind", "origin", "sent"], activity: true },
  { type: "stop_requested", sources: [sql("stop_agent_session")], dims: ["surface"], activity: true },
  { type: "message_resent", sources: [sql("requeue_agent_messages")], dims: ["from"], activity: true },
  // 질문 답 route · 승인 · 비밀값 로컬 답. 자유 글 답(route_agent_message)은 지표 행이 없다 — 카드 ③이 답 단계로 센다 (Q4 A)
  {
    type: "question_answered",
    sources: [sql("answer_agent_question_recorded"), sql("answer_agent_approval"), sql("answer_agent_question_locally")],
    dims: ["kind", "answered_locally", "decision"],
    activity: true,
  },
  { type: "session_renamed", sources: [sql("rename_agent_session")], dims: [], activity: true },
  { type: "session_opened_external", sources: [sql("open_agent_session_external")], dims: [], activity: true },
  { type: "session_resumed", sources: [sql("resume_agent_session_here")], dims: [], activity: true },
  // bridge가 부른다 (사용자 행동이 아니다). bridge 로컬 결정 · TS 사전 한도 거절은 분모에 없다
  { type: "tool_call_decided", sources: [sql("decide_agent_tool_call")], dims: ["decision", "reason"], numeric: "server_ms", activity: false },
  // 에이전트 산출물이 일으킨다 (사용자 행동이 아니다)
  { type: "path_conflict_found", sources: [sql("agent_path_leases_on_artifact")], dims: [], activity: false },
  { type: "path_conflict_resolved", sources: [sql("resolve_path_conflict")], dims: ["keep"], activity: true },
  { type: "issue_moved", sources: [sql("change_context_membership_with_metric")], dims: ["via"], activity: true },
  { type: "project_created", sources: [sql("create_work_context")], dims: [], activity: true },
  { type: "project_renamed", sources: [sql("update_work_context")], dims: [], activity: true },
  { type: "project_icon_changed", sources: [sql("update_work_context")], dims: [], activity: true },
  { type: "project_archived", sources: [sql("update_work_context")], dims: [], activity: true },
  // 앱 insert 정책(owner_insert_client_app_types)은 이미 허용하지만 앱이 아직 보내지 않는다
  { type: "assistant_opened", sources: [], dims: [], activity: true, gap: "남기는 곳 없음 (Mac 후속: 앱이 Supabase로 직접 insert)" },
  // 레일의 외부 세션 목록(On this Mac)이 행 1개 이상으로 보인 날 (하루 한 번). 앱이 POST /api/v2/external-sessions/shown으로 알리고 route가 서버 권한으로 남긴다. props는 구간 문자열뿐(rows_bucket · held_bucket)이라 dims로 가르지 않는다
  { type: "external_sessions_shown", sources: [{ kind: "ts", file: "src/lib/api/external-sessions.ts" }], dims: [], activity: true },
  // 외부 세션 이어받기로 세션 행이 새로 생겼을 때(OA 외부 세션 PR2s): 사용자가 Resume here를 확인한 일이라 활동이다. attach_agent_session이 세션 · 대화와 같은 트랜잭션에서 남기고(대화만 다시 만든 호출은 세지 않는다) props는 adapter뿐이다
  { type: "session_attached", sources: [sql("attach_agent_session")], dims: [], activity: true },
  // 사용자가 Claude 데스크톱 세션 보기(레일 링 · Sessions의 줄)를 연 날 (하루 한 번, OA PR-D2). 앱이 POST /api/v2/external-sessions/claude-app-opened로 알리고 route가 서버 권한으로 남긴다. 종류만 (props 0)이라 dims가 없다
  { type: "claude_app_session_opened", sources: [{ kind: "ts", file: "src/lib/api/external-sessions.ts" }], dims: [], activity: true },
];

// ─── 결제 · 키 이벤트 등록부 (OA 결제 PR-A, 20261129000000) ───

/**
 * 결제 · 키 지표 type 20개 (CHECK 블록 v4, 20261129000000_billing_pro_lifetime.sql; 키 셋의 원천 함수는 20261130000000_user_ai_keys.sql). 에이전트 카드의 대상이 아니라 따로 둔 묶음이다.
 * 상태 전이 SQL 함수가 같은 트랜잭션에서 billing_emit(…)으로 남긴다(재전달에 두 번 세지 않는다). 금액 · 이메일 · LS id · 키는 props에 없다.
 * 읽는 카드(/admin/metrics 결제 카드)는 후속이고, 지금은 이 목록이 "모르는 type"으로 새지 않게 하고 CHECK ↔ 원천 함수 ↔ 시험을 대조하는 집이다
 * (tests/metrics/agent-event-registry.test.ts R1 · R2b · R3b · R6).
 */
export type BillingEventSpec = { type: string; sources: EventSource[]; gap?: string };

export const BILLING_EVENTS: readonly BillingEventSpec[] = [
  { type: "billing_checkout_started", sources: [sql("billing_checkout_url_v2")] },
  { type: "billing_trial_started", sources: [sql("billing_apply_subscription_v2")] },
  { type: "billing_subscription_activated", sources: [sql("billing_apply_subscription_v2")] },
  { type: "billing_payment_succeeded", sources: [sql("billing_apply_subscription_v2")] },
  { type: "billing_payment_failed", sources: [sql("billing_apply_subscription_v2")] },
  { type: "billing_plan_changed", sources: [sql("billing_apply_subscription_v2")] },
  // 사용자가 해지하면 구독 반영 함수가, Lifetime에 밀려 서버가 취소하면 billing_record_event(by: system)가 남긴다
  { type: "billing_subscription_cancelled", sources: [sql("billing_apply_subscription_v2"), sql("billing_record_event")] },
  { type: "billing_subscription_resumed", sources: [sql("billing_apply_subscription_v2")] },
  { type: "billing_subscription_ended", sources: [sql("billing_apply_subscription_v2")] },
  { type: "billing_lifetime_purchased", sources: [sql("billing_apply_lifetime")] },
  { type: "billing_refund_requested", sources: [sql("billing_record_event")] },
  { type: "billing_refunded", sources: [sql("billing_apply_subscription_v2"), sql("billing_apply_lifetime")] },
  { type: "billing_portal_opened", sources: [sql("billing_record_event")] },
  { type: "billing_duplicate_purchase", sources: [sql("billing_apply_subscription_v2"), sql("billing_apply_lifetime"), sql("billing_record_event")] },
  // 처음 묶을 때 확실한 조작이 아닌 어긋남(이미 다른 구독에 묶인 intent · 발급 안 된 intent · 되풀이 체험 · 허락 없는 할인): 자격은 결제 사실대로 두고 사람이 본다 (결제 계약 23장)
  { type: "billing_review_needed", sources: [sql("billing_apply_subscription_v2"), sql("billing_apply_lifetime")] },
  { type: "billing_legacy_marked", sources: [sql("billing_seed_legacy")] },
  { type: "billing_notice_scheduled", sources: [sql("billing_schedule_legacy_notice")] },
  // BYOK 키 저장소(20261130000000): 키를 쓰는 SQL이 같은 트랜잭션에서 남긴다. props는 {replaced} · {}(사용자 지우기) · {by:"refund" | "system"}(삭제 트리거: 환불 · 직접 삭제) ·
  // {by:"provider"}뿐이고 키 · 암호문은 없다. 지우기는 어떤 길로 지워지든 삭제 트리거 함수 하나가 남긴다
  { type: "ai_key_saved", sources: [sql("ai_key_put")] },
  { type: "ai_key_deleted", sources: [sql("ai_key_after_delete")] },
  { type: "ai_key_revoked", sources: [sql("ai_key_mark_revoked")] },
];

/** OA 전에 있던 type 7개 (compute.ts의 지표 1–5 · 연결 카드가 읽는다) */
export const PRE_OA_TYPES: readonly string[] = [
  "app_opened",
  "action_started",
  "handoff_used",
  "connection_created",
  "connection_reauth",
  "reconnect_notified",
  "source_failed",
];

// ─── 공통 ───

const inRange = (at: string, period: Period) => {
  const t = Date.parse(at);
  return t >= period.from.getTime() && t < period.to.getTime();
};

const byValue = (a: DimCount, b: DimCount) => b.n - a.n || (a.value < b.value ? -1 : a.value > b.value ? 1 : 0);

/** nearest-rank (= percentile_disc): 정렬한 값의 ceil(p·n)번째. p는 정수 백분율이라 부동소수점 오차가 없다 */
function rank(sorted: number[], percent: number): number | null {
  if (sorted.length === 0) return null;
  return sorted[Math.max(0, Math.ceil((percent * sorted.length) / 100) - 1)];
}

export type Quantiles = { n: number; p50: number | null; p95: number | null; max: number | null };

function quantiles(values: number[]): Quantiles {
  const sorted = [...values].sort((a, b) => a - b);
  return { n: sorted.length, p50: rank(sorted, 50), p95: rank(sorted, 95), max: sorted.length ? sorted[sorted.length - 1] : null };
}

/** 카드에 글이 새지 않게: 토큰(영문 · 숫자 · _ . : -, 64자 이하)과 불리언만 보인다. 그 밖의 값은 "(기타)" */
const TOKEN = /^[A-Za-z0-9_.:-]{1,64}$/;
const NONE = "(없음)";
const OTHER = "(기타)";

function token(value: unknown): string {
  if (value === undefined || value === null) return NONE;
  if (typeof value === "boolean") return String(value);
  if (typeof value === "string" && TOKEN.test(value)) return value;
  return OTHER;
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);

function tally(values: string[]): DimCount[] {
  const counts = new Map<string, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return [...counts].map(([value, n]) => ({ value, n })).sort(byValue);
}

const seconds = (fromAt: string, toAt: string) => (Date.parse(toAt) - Date.parse(fromAt)) / 1000;

// ─── ① 에이전트 사용 (지표 이벤트) ───

export type AgentMetricRow = { userId: string; type: string; at: string; props: unknown };
export type AgentIssueRow = { userId: string; at: string };
export type DimCount = { value: string; n: number };
export type NumericSummary = { key: string; n: number; p50: number | null; p95: number | null };
export type UsageType = {
  type: string;
  n: number;
  users: number;
  adapters: DimCount[];
  dims: { key: string; values: DimCount[] }[];
  numeric: NumericSummary | null;
};
export type UsageCard = {
  /** 등록부 순서, 기간 안에 없는 type도 0으로 */
  types: UsageType[];
  /** 에이전트에게 맡겨 이슈가 생김 (action_events user_created, rule assistant_agent) */
  agentIssues: { n: number; users: number };
  /** 에이전트 등록부 18개 · OA 전 7개 · 결제 · 키 등록부 20개 밖의 type: 버리지 않고 따로 센다 */
  unknown: { types: number; events: number };
  /** 에이전트 기록이 하나도 없다 */
  empty: boolean;
};

const KNOWN_TYPES = new Set<string>([...PRE_OA_TYPES, ...AGENT_EVENTS.map((e) => e.type), ...BILLING_EVENTS.map((e) => e.type)]);

export function agentUsage(rows: AgentMetricRow[], issues: AgentIssueRow[], period: Period): UsageCard {
  const inside = rows.filter((row) => inRange(row.at, period));
  const types = AGENT_EVENTS.map((spec): UsageType => {
    const mine = inside.filter((row) => row.type === spec.type);
    const props = mine.map((row) => (isRecord(row.props) ? row.props : {}));
    const samples = spec.numeric ? props.map((p) => p[spec.numeric!]).filter((v): v is number => typeof v === "number" && Number.isFinite(v) && v >= 0) : [];
    const summary = spec.numeric ? quantiles(samples) : null;
    return {
      type: spec.type,
      n: mine.length,
      users: new Set(mine.map((row) => row.userId)).size,
      adapters: tally(props.map((p) => token(p.adapter))),
      dims: spec.dims.map((key) => ({ key, values: tally(props.map((p) => token(p[key]))) })),
      numeric: spec.numeric && summary ? { key: spec.numeric, n: summary.n, p50: summary.p50, p95: summary.p95 } : null,
    };
  });
  const unknownRows = inside.filter((row) => !KNOWN_TYPES.has(row.type));
  const madeIssues = issues.filter((issue) => inRange(issue.at, period));
  return {
    types,
    agentIssues: { n: madeIssues.length, users: new Set(madeIssues.map((issue) => issue.userId)).size },
    unknown: { types: new Set(unknownRows.map((row) => row.type)).size, events: unknownRows.length },
    empty: types.every((t) => t.n === 0) && madeIssues.length === 0,
  };
}

// ─── ② 전달 · 지연 (ONE-TF-11 서버 구간) + 전달 결과 ───

/** 전달 · 답 · 취소 단계 (execution_steps, kind agent_message · agent_cancel). 글(args.answers · receipt 통째)은 읽지 않는다 */
export type DeliveryStep = {
  id: string;
  kind: string;
  adapter: string | null;
  /** message:<id>[:n] · answer:<task>:<request> 모양. 종류와 메시지 id를 가르는 데만 쓰고 카드에 내보내지 않는다 */
  purpose: string;
  createdAt: string;
  taskId: string | null;
  requestId: string | null;
  answerMessageId: string | null;
  /** args.answeredLocally의 글자 ("true") */
  answeredLocally: string | null;
  /** receipt.reason */
  receiptReason: string | null;
};
export type StepEvent = { stepId: string; toState: string; gate: string | null; at: string };
export type MessageRow = { id: string; deliveryState: string; deliveryReason: string | null; createdAt: string };
export type CommandRow = { kind: string; outcome: string | null; createdAt: string };

export type LatencyKind = "message" | "answer" | "cancel";
export type LatencyGroup = {
  kind: LatencyKind;
  adapter: string;
  n: number;
  /** 시작 → Mac이 집어 감 (gate bridge_lease의 첫 calling), 초 */
  lease: Quantiles;
  /** 집어 간 시간의 3 · 8 · 25초 칸 (≤ 경계) */
  buckets: { le3: number; le8: number; le25: number; gt25: number };
  /** 아직 아무도 집지 않고 끝나지도 않았다 */
  waiting: number;
  /** 집힌 적 없이 failed · skipped로 끝났다 */
  neverLeased: number;
  /** 시작 → 접수 (첫 called), 초. Claude Code의 접수는 그 턴의 첫 assistant 사건이라 모델의 첫 출력 시간이 들어 있다 (상한) */
  accept: Quantiles;
  /** 시각 이상(집힌 때 · 접수가 만든 때보다 앞)이라 표본에서 뺀 단계 */
  anomalies: number;
};
/** 칸 이름: 3 · 8 · 25초 칸은 겹치지 않는 구간이다 (누적이 아니다) */
export const BUCKET_LABELS = { le3: "3초 이하", le8: "3초 초과 ~ 8초 이하", le25: "8초 초과 ~ 25초 이하", gt25: "25초 초과" } as const;

export function bucketText(buckets: LatencyGroup["buckets"]): string {
  return (Object.keys(BUCKET_LABELS) as (keyof typeof BUCKET_LABELS)[]).map((key) => `${BUCKET_LABELS[key]} ${buckets[key]}`).join(" · ");
}

export type DeliveryCard = {
  groups: LatencyGroup[];
  results: { state: string; reason: string; n: number }[];
  commands: { kind: string; outcome: string; n: number }[];
  /** 명령은 30일 뒤 지워서 기간이 30일보다 길면 최근 30일만 센 것이다 */
  commandsClamped: boolean;
};

const KIND_ORDER: readonly string[] = ["message", "answer", "cancel"];
const STATE_ORDER: readonly string[] = ["queued", "dispatched", "not_sent", "expired", "cancelled"];
const OUTCOME_ORDER: readonly string[] = ["sent", "task_unknown", "received", "not_received", "unknown", "request_closed", "declined", "withdrawn", "(진행 중)"];
/** bridge_commands는 끝난 뒤 이 기간이 지나면 지운다 (BRIDGE_COMMAND_RETENTION_DAYS): 명령 결과는 최근 이 기간만 센다 */
export const COMMAND_RETENTION_MS = BRIDGE_COMMAND_RETENTION_DAYS * 86_400_000;

const orderOf = (list: readonly string[], value: string) => {
  const index = list.indexOf(value);
  return index === -1 ? list.length : index;
};

export function latencyKind(step: Pick<DeliveryStep, "kind" | "purpose">): LatencyKind {
  if (step.kind === "agent_cancel") return "cancel";
  return step.purpose.startsWith("answer:") ? "answer" : "message";
}

/** message:<id> · message:<id>:<n> → <id> */
const messageIdOf = (purpose: string) => /^message:([^:]+)(?::\d+)?$/.exec(purpose)?.[1] ?? null;

export function agentDelivery(
  input: { steps: DeliveryStep[]; events: StepEvent[]; messages: MessageRow[]; commands: CommandRow[] },
  period: Period,
): DeliveryCard {
  const steps = input.steps.filter((step) => inRange(step.createdAt, period));
  const times = new Map<string, { leased?: string; called?: string; ended?: string }>();
  for (const event of input.events) {
    const entry = times.get(event.stepId) ?? {};
    const earlier = (current: string | undefined) => current === undefined || Date.parse(event.at) < Date.parse(current);
    if (event.toState === "calling" && event.gate === "bridge_lease" && earlier(entry.leased)) entry.leased = event.at;
    if (event.toState === "called" && earlier(entry.called)) entry.called = event.at;
    if ((event.toState === "failed" || event.toState === "skipped") && earlier(entry.ended)) entry.ended = event.at;
    times.set(event.stepId, entry);
  }

  const grouped = new Map<string, { kind: LatencyKind; adapter: string; steps: DeliveryStep[] }>();
  for (const step of steps) {
    const kind = latencyKind(step);
    const adapter = token(step.adapter);
    const key = `${kind}\u0000${adapter}`;
    const group = grouped.get(key) ?? { kind, adapter, steps: [] };
    group.steps.push(step);
    grouped.set(key, group);
  }

  const groups = [...grouped.values()]
    .sort((a, b) => orderOf(KIND_ORDER, a.kind) - orderOf(KIND_ORDER, b.kind) || (a.adapter < b.adapter ? -1 : a.adapter > b.adapter ? 1 : 0))
    .map((group): LatencyGroup => {
      const lease: number[] = [];
      const accept: number[] = [];
      const buckets = { le3: 0, le8: 0, le25: 0, gt25: 0 };
      let waiting = 0;
      let neverLeased = 0;
      let anomalies = 0;
      for (const step of group.steps) {
        const t = times.get(step.id) ?? {};
        if (t.leased === undefined && t.ended === undefined) waiting++;
        if (t.leased === undefined && t.ended !== undefined) neverLeased++;
        let anomalous = false;
        if (t.leased !== undefined) {
          const gap = seconds(step.createdAt, t.leased);
          if (gap < 0) anomalous = true;
          else {
            lease.push(gap);
            if (gap <= 3) buckets.le3++;
            else if (gap <= 8) buckets.le8++;
            else if (gap <= 25) buckets.le25++;
            else buckets.gt25++;
          }
        }
        if (t.called !== undefined) {
          const gap = seconds(step.createdAt, t.called);
          if (gap < 0) anomalous = true;
          else accept.push(gap);
        }
        if (anomalous) anomalies++;
      }
      return { kind: group.kind, adapter: group.adapter, n: group.steps.length, lease: quantiles(lease), buckets, waiting, neverLeased, accept: quantiles(accept), anomalies };
    });

  // 전달 결과: expired는 lease 전에 거둔 것(전달 단계 receipt.reason이 expired)과 대기열에서 만료된 것(sweep)으로 가른다
  const expiredBeforeLease = new Set<string>();
  for (const step of input.steps) {
    const id = messageIdOf(step.purpose);
    if (id !== null && step.receiptReason === "expired") expiredBeforeLease.add(id);
  }
  const results = tally(
    input.messages
      .filter((message) => inRange(message.createdAt, period))
      .map((message) => {
        const state = token(message.deliveryState);
        const reason = state === "expired" ? (expiredBeforeLease.has(message.id) ? "expired_before_lease" : "expired_queue") : token(message.deliveryReason);
        return `${state}\u0000${reason}`;
      }),
  )
    .map(({ value, n }) => {
      const [state, reason] = value.split("\u0000");
      return { state, reason, n };
    })
    .sort((a, b) => orderOf(STATE_ORDER, a.state) - orderOf(STATE_ORDER, b.state) || b.n - a.n || (a.reason < b.reason ? -1 : a.reason > b.reason ? 1 : 0));

  const commandsFrom = Math.max(period.from.getTime(), period.to.getTime() - COMMAND_RETENTION_MS);
  const commands = tally(
    input.commands
      .filter((command) => {
        const t = Date.parse(command.createdAt);
        return t >= commandsFrom && t < period.to.getTime();
      })
      .map((command) => `${token(command.kind)}\u0000${command.outcome === null ? "(진행 중)" : token(command.outcome)}`),
  )
    .map(({ value, n }) => {
      const [kind, outcome] = value.split("\u0000");
      return { kind, outcome, n };
    })
    .sort((a, b) => orderOf(KIND_ORDER, a.kind) - orderOf(KIND_ORDER, b.kind) || orderOf(OUTCOME_ORDER, a.outcome) - orderOf(OUTCOME_ORDER, b.outcome));

  return { groups, results, commands, commandsClamped: period.from.getTime() < period.to.getTime() - COMMAND_RETENTION_MS };
}

// ─── ③ 질문 → 답 ───

/** execution_events type 'agent' 사건의 감사 payload (글 0: event_type · status · kind · question_key만) */
export type AgentEventRow = { at: string; eventType: string; status: string; kind: string | null; taskId: string | null; requestId: string | null };
/** 지금 열려 있는 작업 (agent_tasks state awaiting_answer · unreachable). requestId = 열린 질문의 provider_request_id */
export type OpenTask = { id: string; state: string; requestId: string | null };

export type QuestionPath = "route" | "message" | "local" | "unanswered_open" | "unanswered_closed";
export type QuestionGroup = { kind: string; path: QuestionPath; n: number; wait: Quantiles };
export type QuestionCard = {
  groups: QuestionGroup[];
  /** 기간 안에 받은 질문 사건 */
  asked: number;
  /** 답이 질문보다 앞서 기다림 표본에서 뺀 수 */
  anomalies: number;
};

const PATH_ORDER: readonly string[] = ["route", "message", "local", "unanswered_open", "unanswered_closed"];

export function agentQuestions(input: { events: AgentEventRow[]; steps: DeliveryStep[]; tasks: OpenTask[] }, period: Period): QuestionCard {
  // 질문(task, request)마다 첫 답 단계 (다시 보낸 회차는 첫 단계만)
  const answers = new Map<string, { at: string; viaMessage: boolean; local: boolean }>();
  for (const step of input.steps) {
    if (step.kind !== "agent_message" || !step.purpose.startsWith("answer:") || step.taskId === null || step.requestId === null) continue;
    const key = `${step.taskId}\u0000${step.requestId}`;
    const current = answers.get(key);
    answers.set(key, {
      at: current && Date.parse(current.at) <= Date.parse(step.createdAt) ? current.at : step.createdAt,
      viaMessage: (current?.viaMessage ?? false) || step.answerMessageId !== null,
      local: (current?.local ?? false) || step.answeredLocally === "true",
    });
  }
  const open = new Set(input.tasks.filter((task) => task.state === "awaiting_answer" && task.requestId !== null).map((task) => `${task.id}\u0000${task.requestId}`));

  const asked = input.events.filter((event) => event.eventType === "question" && event.status === "applied" && inRange(event.at, period));
  const groups = new Map<string, { kind: string; path: QuestionPath; n: number; waits: number[] }>();
  let anomalies = 0;
  for (const event of asked) {
    const key = event.taskId !== null && event.requestId !== null ? `${event.taskId}\u0000${event.requestId}` : null;
    const answer = key === null ? undefined : answers.get(key);
    const kind = token(event.kind);
    let path: QuestionPath;
    let wait: number | null = null;
    if (!answer) path = key !== null && open.has(key) ? "unanswered_open" : "unanswered_closed";
    else {
      path = answer.local ? "local" : answer.viaMessage ? "message" : "route";
      const gap = seconds(event.at, answer.at);
      if (gap < 0) anomalies++;
      else wait = gap;
    }
    const group = groups.get(`${kind}\u0000${path}`) ?? { kind, path, n: 0, waits: [] };
    group.n++;
    if (wait !== null) group.waits.push(wait);
    groups.set(`${kind}\u0000${path}`, group);
  }
  return {
    groups: [...groups.values()]
      .sort((a, b) => (a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : 0) || orderOf(PATH_ORDER, a.path) - orderOf(PATH_ORDER, b.path))
      .map((group) => ({ kind: group.kind, path: group.path, n: group.n, wait: quantiles(group.waits) })),
    asked: asked.length,
    anomalies,
  };
}

// ─── ④ 멈춤 · 지금 막힌 것 ───

export type StopEvent = { runId: string; gate: string | null; at: string };
export type ConflictRow = { conflictAt: string };

export type StopGate = "stop" | "action_closed" | "path_conflict" | "session_deleted" | "other";
export type StopCard = {
  /** 기간 안에 대화 run이 멈춘 까닭 (stop = 사용자 Stop → stop_run, action_closed = 이슈 Done, path_conflict = 충돌로 멈춤, session_deleted = 세션 삭제) */
  stopped: { gate: StopGate; n: number }[];
  /** 기간 안에 끝난 턴 (applied turn_completed) */
  turnsCompleted: number;
  /** 지금 값 (기간 무관) */
  now: {
    overdueLeases: number;
    unknownOutcome: number;
    unreachable: number;
    awaitingAnswer: number;
    openConflicts: number;
    /** 가장 오래된 열린 충돌의 나이 (period.to 기준, 초) */
    oldestConflictAgeS: number | null;
  };
};

const STOP_GATES: readonly StopGate[] = ["stop", "action_closed", "path_conflict", "session_deleted", "other"];

export function agentStops(
  input: {
    stopEvents: StopEvent[];
    conversationRunIds: ReadonlySet<string>;
    events: AgentEventRow[];
    overdueLeases: number;
    unknownOutcome: number;
    tasks: OpenTask[];
    conflicts: ConflictRow[];
  },
  period: Period,
): StopCard {
  const counts = new Map<StopGate, number>(STOP_GATES.map((gate) => [gate, 0]));
  for (const event of input.stopEvents) {
    if (!inRange(event.at, period) || !input.conversationRunIds.has(event.runId)) continue;
    const gate = STOP_GATES.find((g) => g !== "other" && g === event.gate) ?? "other";
    counts.set(gate, (counts.get(gate) ?? 0) + 1);
  }
  const conflictTimes = input.conflicts.map((c) => Date.parse(c.conflictAt)).filter((t) => Number.isFinite(t));
  return {
    stopped: STOP_GATES.map((gate) => ({ gate, n: counts.get(gate) ?? 0 })),
    turnsCompleted: input.events.filter((e) => e.eventType === "turn_completed" && e.status === "applied" && inRange(e.at, period)).length,
    now: {
      overdueLeases: input.overdueLeases,
      unknownOutcome: input.unknownOutcome,
      unreachable: input.tasks.filter((task) => task.state === "unreachable").length,
      awaitingAnswer: input.tasks.filter((task) => task.state === "awaiting_answer").length,
      openConflicts: input.conflicts.length,
      oldestConflictAgeS: conflictTimes.length ? (period.to.getTime() - Math.min(...conflictTimes)) / 1000 : null,
    },
  };
}
