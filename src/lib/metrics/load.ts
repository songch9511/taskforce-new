import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { misjudgment, missed, retention, timeToStart, type ActionEventRow, type MetricEventRow, type Period } from "./compute";

// 관리자 지표: 모든 사용자의 이벤트를 service role로 읽어 숫자만 만든다. 원문 · 인용 · 할 일 제목은 읽지 않는다.

/** 관리자 이메일 (ADMIN_EMAILS, 쉼표로 구분). 비어 있으면 아무도 관리자가 아니다 */
export function isAdmin(email: string | null): boolean {
  const admins = (process.env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return Boolean(email) && admins.includes(email!.toLowerCase());
}

/** 시험용 원문(E2E 검증 스크립트가 만든 것)에서 나온 Action은 지표에서 뺀다 */
const TEST_SOURCE_TITLE = /^\[E2E 테스트\]/;

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

export async function loadMetrics(admin: SupabaseClient, period: Period) {
  // 리텐션은 기간보다 앞의 활동도 본다
  const since = new Date(Math.min(period.from.getTime(), period.to.getTime() - (RETENTION_WEEKS + 1) * 7 * 86_400_000)).toISOString();

  const events = await readAll<EventRecord>((from, to) =>
    admin
      .from("action_events")
      .select("action_id, user_id, type, actor, before, after, created_at, source_id")
      .gte("created_at", since)
      .order("created_at")
      .order("id")
      .range(from, to),
  );
  const metricEvents = await readAll<{ user_id: string; type: string; action_id: string | null; at: string }>((from, to) =>
    admin.from("metric_events").select("user_id, type, action_id, at").gte("at", since).order("at").order("id").range(from, to),
  );

  // 이벤트의 원문 종류(할 일 DB에서 온 것인지)와 시험용 원문인지: 제목은 여기서만 보고 밖으로 내보내지 않는다
  const sourceIds = [...new Set(events.map((e) => e.source_id).filter((id): id is string => Boolean(id)))];
  const sources = new Map<string, { kind: string; test: boolean }>();
  for (let i = 0; i < sourceIds.length; i += 100) {
    const { data } = await admin.from("sources").select("id, kind, title").in("id", sourceIds.slice(i, i + 100)).throwOnError();
    for (const s of (data ?? []) as { id: string; kind: string; title: string | null }[]) {
      sources.set(s.id, { kind: s.kind, test: TEST_SOURCE_TITLE.test(s.title ?? "") });
    }
  }
  const testActions = new Set(events.filter((e) => e.type === "created" && e.source_id && sources.get(e.source_id)?.test).map((e) => e.action_id));

  const rows: ActionEventRow[] = events
    .filter((e) => !testActions.has(e.action_id))
    .map((e) => ({
      actionId: e.action_id,
      userId: e.user_id,
      type: e.type,
      actor: e.actor,
      before: e.before,
      after: e.after,
      at: e.created_at,
      sourceKind: e.source_id ? (sources.get(e.source_id)?.kind ?? null) : null,
    }));
  const metrics: MetricEventRow[] = metricEvents
    .filter((e) => !e.action_id || !testActions.has(e.action_id))
    .map((e) => ({ userId: e.user_id, type: e.type, actionId: e.action_id, at: e.at }));

  const misjudged = misjudgment(rows, period);
  return {
    period,
    excludedTestActions: testActions.size,
    misjudgment: misjudged,
    start: timeToStart(metrics, period),
    retention: retention(metrics, rows, RETENTION_WEEKS),
    // 누락 신고(user_reported_missing)는 아직 만들지 않았다 (PRD 6장 "누락 신호를 모으는 방법")
    missed: missed(rows, misjudged, period, false),
  };
}

export type MetricsReport = Awaited<ReturnType<typeof loadMetrics>>;
