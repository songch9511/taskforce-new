import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { grantedFeatures } from "@/lib/connectors/google/run";

import { readAll } from "../read-all";
import {
  connections,
  discoveryCost,
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
  actor: "ai" | "user";
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
  const userWrites = await readAll<{ user_id: string; action_id: string; created_at: string }>((from, to) =>
    admin.from("action_events").select("user_id, action_id, created_at").eq("actor", "user").order("created_at").order("id").range(from, to),
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
