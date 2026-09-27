import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { misjudgment, missed, retention, timeToStart, type ActionEventRow, type Activity, type MetricEventRow, type Period } from "./compute";

// 관리자 지표: 모든 사용자의 이벤트를 service role로 읽어 숫자만 만든다.
// 이벤트의 before · after에는 할 일 제목 · 기한 값이 들어 있지만, 읽자마자 "어느 필드가 바뀌었나"와 상태 값만 남기고 버린다.
// 원문 · 인용은 읽지 않고, 원문 제목은 시험용 원문을 가려낼 때만 서버 쿼리 조건으로 쓴다.

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

async function readAll<T>(page: (from: number, to: number) => PromiseLike<{ data: unknown[] | null; error: unknown }>): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await page(from, from + 999);
    if (error) throw error;
    rows.push(...((data ?? []) as T[]));
    if ((data ?? []).length < 1000) return rows;
  }
}

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

/** 지표에 필요한 것만 남긴다: 바뀐 필드 이름 · 상태 · 만들 때 확인 요청이었는지. 제목 · 기한 값은 버린다. */
function keep(values: Record<string, unknown> | null): Record<string, unknown> | null {
  if (!values) return null;
  const kept: Record<string, unknown> = {};
  for (const key of ["title", "due", "owner"]) if (key in values) kept[key] = true;
  if ("status" in values) kept.status = values.status;
  if ("needs_confirmation" in values) kept.needs_confirmation = values.needs_confirmation;
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
  // 리텐션은 사용자의 처음 활동부터 본다 (기간으로 자르면 오래 쓴 사용자가 새 사용자로 보인다)
  const metricEvents = await readAll<{ user_id: string; type: string; action_id: string | null; at: string }>((from, to) =>
    admin.from("metric_events").select("user_id, type, action_id, at").order("at").order("id").range(from, to),
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
    }));
  const metrics: MetricEventRow[] = metricEvents
    .filter((e) => !e.action_id || !testActions.has(e.action_id))
    .map((e) => ({ userId: e.user_id, type: e.type, actionId: e.action_id, at: e.at }));
  const activity: Activity[] = [
    ...metrics.map((e) => ({ userId: e.userId, at: e.at })),
    ...userWrites.filter((e) => !testActions.has(e.action_id)).map((e) => ({ userId: e.user_id, at: e.created_at })),
  ];

  const misjudged = misjudgment(rows, period);
  return {
    period,
    excludedTestActions: testActions.size,
    misjudgment: misjudged,
    start: timeToStart(metrics, period),
    retention: retention(activity, period.to, RETENTION_WEEKS),
    // 누락 신고(user_reported_missing)는 아직 만들지 않았다 (PRD 6장 "누락 신호를 모으는 방법")
    missed: missed(rows, misjudged, period, false),
  };
}

export type MetricsReport = Awaited<ReturnType<typeof loadMetrics>>;
