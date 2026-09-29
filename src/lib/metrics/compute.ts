import type { MissStage } from "@/lib/pipeline/missing";

// PRD 6장 성공 지표를 이벤트에서 계산한다 (순수 함수). 불러오기는 load.ts, 화면은 /admin/metrics.
//
// 1 AI 오판율   (사용자가 수정 · 삭제한 AI 생성 Action) / (AI 생성 Action). 필드별 · 단계별(추출 / 매칭 · 갱신)로 나눈다.
//               누락 신고 · 직접 추가로 생긴 Action은 AI가 스스로 만든 것이 아니므로 뺀다.
// 2 착수 시간   app_opened → 첫 action_started / handoff_used. action_started는 Action마다 처음 한 번만 착수로 본다
//               (착수를 되돌렸다가 다시 시작하거나 착수를 다시 눌러도 새 착수가 아니다)
// 3 리텐션      첫 활동 주부터 N주 뒤에도 활동했는가
// 4 AI 누락률   (신고된 누락 + 직접 추가) / (AI 생성 + 신고된 누락 + 직접 추가). 신고(user_reported_missing)는 놓친 단계별로도 센다.
//               직접 추가(user_created)는 추출이 놓친 할 일을 사용자가 적은 것으로 본다 (원문을 고르지 않으면 단계를 알 수 없다)
// 5 그림자 목록  주간 질문 "Taskforce 밖에 따로 적어둔 할 일이 있나요?"에 "있다" / ("있다" + "없다"). 건너뛰기는 응답 수에만 넣는다

export type ActionEventRow = {
  actionId: string;
  userId: string;
  type: string;
  actor: "ai" | "user";
  before: Record<string, unknown> | null;
  after: Record<string, unknown> | null;
  at: string;
  /** 이 이벤트의 원문 종류 (meeting · email · task 등). 사용자 이벤트는 null */
  sourceKind: string | null;
};

/** provider: 연결 이벤트(connection_created · connection_reauth · reconnect_notified)의 서비스. 그 밖의 이벤트, 열이 생기기 전의 connection_created는 없다 */
export type MetricEventRow = { userId: string; type: string; actionId: string | null; at: string; provider?: string | null };

export type Period = { from: Date; to: Date };

/** 오판을 필드로 나눈다. deleted = 사용자가 지움 */
export type ErrorField = "title" | "due" | "owner" | "status" | "deleted";
/** 틀린 값을 만든 단계: 처음 만들 때(추출) / 나중 원문으로 고칠 때(매칭 · 갱신) */
export type ErrorStage = "extract" | "update";

export type MisjudgmentMetric = {
  /** AI가 원문에서 만든 Action (할 일 DB에서 속성을 옮겨 온 것은 뺀다) */
  aiCreated: number;
  /** 할 일 DB에서 가져온 Action (참고: AI 판단이 아니다) */
  imported: number;
  /** 사용자가 고치거나 지운 AI 생성 Action */
  corrected: number;
  rate: number | null;
  byField: Record<ErrorField, number>;
  byStage: Record<ErrorStage, number>;
  /**
   * 만들 때 바로 반영했는지(auto) · 확인 요청으로 물었는지(asked). 자동 반영이 틀린 것이 진짜 오판이고,
   * 물어본 것에 "아니에요"는 설계대로 동작한 것이다. 이 구분이 생기기 전 이벤트는 unknown.
   */
  byConfirmation: Record<"auto" | "asked" | "unknown", { created: number; corrected: number }>;
  /** 확인 요청에 "맞아요"로 답한 수 (오판 아님, 확인 부담을 본다) */
  confirmed: number;
};

const AI_FIELD_EVENTS: Record<string, ErrorField[]> = {
  created: ["title", "due", "owner", "status"],
  scope_changed: ["title"],
  due_changed: ["due"],
  owner_changed: ["owner"],
  completed: ["status"],
  dropped: ["status"],
  reopened: ["status"],
  merged: [],
};

const inPeriod = (at: string, period: Period) => {
  const t = Date.parse(at);
  return t >= period.from.getTime() && t < period.to.getTime();
};

/**
 * 사용자 수정 이벤트에서 AI가 틀린 필드. 상태는 AI가 끝냈다고(완료 · 취소) 본 일을 사용자가 다시 연 경우만 넣는다:
 * 완료로 바꾼 것은 일을 끝낸 것이고, 자기가 잘못 눌러 완료한 것을 되돌린 것도 AI의 잘못이 아니다.
 * 착수 · 착수 되돌리기(user_started · user_unstarted, 작업 상태)는 사용자의 진행 기록이라 오판이 아니다.
 * 삭제는 AI가 만들지 말았어야 한 일로 세되, 끝낸 일을 치운 것과 지운 뒤 되살린 것은 뺀다.
 */
function correctedFields(event: ActionEventRow, earlier: ActionEventRow[], later: ActionEventRow[]): ErrorField[] {
  if (event.type === "user_deleted") {
    // 끝낸 일을 치운 것은 AI가 틀린 게 아니다
    if ((event.before ?? {}).status === "done") return [];
    // 지운 뒤 사용자가 되살렸으면(되돌리기 · 마음을 바꿈) 지운 것으로 세지 않는다
    const restored = later.some((e) => e.type === "user_edited" && e.actor === "user" && ["open", "done"].includes(String((e.after ?? {}).status)));
    return restored ? [] : ["deleted"];
  }
  if (event.type !== "user_edited") return [];
  const fields: ErrorField[] = [];
  const after = event.after ?? {};
  if ("title" in after) fields.push("title");
  if ("due" in after) fields.push("due");
  if ("owner" in after) fields.push("owner");
  if (after.status === "open") {
    const lastStatus = [...earlier].reverse().find((e) => e.type === "completed" || e.type === "dropped" || (e.after ?? {}).status !== undefined);
    if (lastStatus?.actor === "ai" && (lastStatus.type === "completed" || lastStatus.type === "dropped")) fields.push("status");
  }
  return fields;
}

export function misjudgment(events: ActionEventRow[], period: Period): MisjudgmentMetric {
  const byAction = new Map<string, ActionEventRow[]>();
  for (const event of events) byAction.set(event.actionId, [...(byAction.get(event.actionId) ?? []), event]);

  const result: MisjudgmentMetric = {
    aiCreated: 0,
    imported: 0,
    corrected: 0,
    rate: null,
    byField: { title: 0, due: 0, owner: 0, status: 0, deleted: 0 },
    byStage: { extract: 0, update: 0 },
    byConfirmation: { auto: { created: 0, corrected: 0 }, asked: { created: 0, corrected: 0 }, unknown: { created: 0, corrected: 0 } },
    confirmed: 0,
  };

  for (const list of byAction.values()) {
    const sorted = [...list].sort((a, b) => a.at.localeCompare(b.at));
    const created = sorted.find((e) => e.type === "created" && e.actor === "ai");
    // 이 기간에 만들어진 Action만 센다. 고친 것은 기간이 지나서여도 센다 (고침은 만든 뒤에 온다).
    if (!created || !inPeriod(created.at, period)) continue;
    // 누락 신고 · 직접 추가로 생긴 Action은 사용자가 알려준 것이다 (지표 4에서 센다)
    if (sorted.some((e) => e.type === "user_reported_missing" || e.type === "user_created")) continue;
    if (created.sourceKind === "task") {
      result.imported++;
      continue;
    }
    result.aiCreated++;
    result.confirmed += sorted.filter((e) => e.type === "user_confirmed").length;
    const asked = created.after?.needs_confirmation;
    const bucket = result.byConfirmation[asked === true ? "asked" : asked === false ? "auto" : "unknown"];
    bucket.created++;

    const fields = new Set<ErrorField>();
    const stages = new Set<ErrorStage>();
    sorted.forEach((event, index) => {
      for (const field of correctedFields(event, sorted.slice(0, index), sorted.slice(index + 1))) {
        fields.add(field);
        if (field === "deleted") {
          // 지운 일은 애초에 만들지 말았어야 한 것으로 본다 (추출 단계)
          stages.add("extract");
          continue;
        }
        // 이 필드를 마지막으로 정한 AI 이벤트가 처음 만들 때였는지, 나중 원문으로 고칠 때였는지
        const last = sorted
          .slice(0, index)
          .reverse()
          .find((e) => e.actor === "ai" && (AI_FIELD_EVENTS[e.type] ?? []).includes(field));
        stages.add(!last || last.type === "created" ? "extract" : "update");
      }
    });
    if (fields.size > 0) {
      result.corrected++;
      bucket.corrected++;
      for (const field of fields) result.byField[field]++;
      for (const stage of stages) result.byStage[stage]++;
    }
  }
  result.rate = result.aiCreated > 0 ? result.corrected / result.aiCreated : null;
  return result;
}

export type StartMetric = {
  opens: number;
  /** 연 뒤 한 시간 안에 착수(시작 · AI에게 넘기기)한 비율 */
  startedRate: number | null;
  /** 연 뒤 첫 착수까지 걸린 시간의 중앙값(분) */
  medianMinutes: number | null;
};

/** 앱을 연 뒤 이 시간 안의 첫 착수만 그 열기의 착수로 본다 */
const START_WINDOW_MINUTES = 60;

/**
 * Action마다 처음 action_started만 착수로 본다. 진행 중 → 할 일(user_unstarted)로 되돌렸다가 다시 시작하면 start_action이
 * action_started를 또 남기지만 그 Action의 첫 착수는 아니다. events는 처음부터 전부여야 한다 (load.ts는 기간으로 자르지 않는다).
 * Action이 없는(action_id null) 착수는 하나씩 센다.
 */
function firstStarts(events: MetricEventRow[]): Set<MetricEventRow> {
  const first = new Set<MetricEventRow>();
  const seen = new Set<string>();
  for (const event of [...events].sort((a, b) => a.at.localeCompare(b.at))) {
    if (event.type !== "action_started") continue;
    if (event.actionId !== null && seen.has(event.actionId)) continue;
    if (event.actionId !== null) seen.add(event.actionId);
    first.add(event);
  }
  return first;
}

export function timeToStart(events: MetricEventRow[], period: Period): StartMetric {
  const byUser = new Map<string, MetricEventRow[]>();
  for (const event of events) byUser.set(event.userId, [...(byUser.get(event.userId) ?? []), event]);
  const starts = firstStarts(events);

  let opens = 0;
  const minutes: number[] = [];
  for (const list of byUser.values()) {
    const sorted = [...list].sort((a, b) => a.at.localeCompare(b.at));
    sorted.forEach((event, index) => {
      if (event.type !== "app_opened" || !inPeriod(event.at, period)) return;
      opens++;
      const openedAt = Date.parse(event.at);
      // 다음에 다시 열기 전까지의 첫 착수
      for (const next of sorted.slice(index + 1)) {
        if (next.type === "app_opened") break;
        if (next.type !== "handoff_used" && !starts.has(next)) continue;
        const gap = (Date.parse(next.at) - openedAt) / 60_000;
        if (gap <= START_WINDOW_MINUTES) minutes.push(gap);
        break;
      }
    });
  }
  return { opens, startedRate: opens > 0 ? minutes.length / opens : null, medianMinutes: median(minutes) };
}

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

export type RetentionMetric = {
  /** 주(월요일 시작, 한국 시간)마다 활동한 사용자 수 */
  weeklyActive: { week: string; users: number }[];
  /** 첫 활동 주 기준 N주 뒤 활동 비율 (index 0 = 첫 주) */
  retention: (number | null)[];
  cohortSize: number;
};

/** 한국 시간 기준 그 주 월요일 (YYYY-MM-DD) */
export function kstWeek(at: string): string {
  const kst = new Date(Date.parse(at) + 9 * 3_600_000);
  const day = (kst.getUTCDay() + 6) % 7; // 월요일 = 0
  kst.setUTCDate(kst.getUTCDate() - day);
  return kst.toISOString().slice(0, 10);
}

export type Activity = { userId: string; at: string };

/** 서버가 남기는 연결 이벤트: 사용자의 활동이 아니다 (연결 완료 · 연결 만료 · 재연결 알림) */
const SERVER_CONNECTION_EVENTS = new Set(["connection_created", "connection_reauth", "reconnect_notified"]);

/** 지표 이벤트 중 사용자의 활동(앱 열기 · 착수 · 넘기기 등). 서버 연결 이벤트는 넣지 않는다: 리텐션 정의를 바꾸지 않게 */
export function metricActivity(events: MetricEventRow[]): Activity[] {
  return events.filter((e) => !SERVER_CONNECTION_EVENTS.has(e.type)).map((e) => ({ userId: e.userId, at: e.at }));
}

/**
 * 활동: 앱 열기 · 착수 · 넘기기(지표 이벤트)와 사용자의 Action 쓰기(수정 · 삭제 · 확인 · 착수).
 * 베타 초기에는 앱 대신 시험대로 쓰기도 해서 쓰기도 활동으로 본다.
 * activity는 사용자의 처음 활동부터 전부여야 한다 (기간으로 자르면 오래 쓴 사용자가 새 사용자로 보인다).
 * 아직 끝나지 않은 이번 주는 N주 뒤 판단에 쓰지 않는다.
 */
export function retention(activity: Activity[], now: Date, weeks = 4): RetentionMetric {
  const weeksByUser = new Map<string, Set<string>>();
  for (const { userId, at } of activity) weeksByUser.set(userId, (weeksByUser.get(userId) ?? new Set()).add(kstWeek(at)));

  const counts = new Map<string, number>();
  for (const set of weeksByUser.values()) for (const week of set) counts.set(week, (counts.get(week) ?? 0) + 1);
  const weeklyActive = [...counts].sort(([a], [b]) => a.localeCompare(b)).map(([week, users]) => ({ week, users }));

  const addWeeks = (week: string, n: number) => new Date(Date.parse(`${week}T00:00:00Z`) + n * 7 * 86_400_000).toISOString().slice(0, 10);
  const lastComplete = addWeeks(kstWeek(now.toISOString()), -1);
  const retentionRates = Array.from({ length: weeks + 1 }, (_, n) => {
    // N주 뒤가 아직 끝나지 않은 사용자는 분모에서 뺀다 (첫 주는 진행 중이어도 센다)
    const eligible = [...weeksByUser.values()].filter((set) => n === 0 || addWeeks([...set].sort()[0], n) <= lastComplete);
    if (eligible.length === 0) return null;
    return eligible.filter((set) => set.has(addWeeks([...set].sort()[0], n))).length / eligible.length;
  });
  return { weeklyActive, retention: retentionRates, cohortSize: weeksByUser.size };
}

export type MissedMetric = {
  /** 누락 신고 (원문 구절을 골라 신고, user_reported_missing) */
  reported: number;
  /** 직접 추가 (user_created) */
  added: number;
  rate: number | null;
  available: boolean;
  /** 원래 처리에서 놓친 단계별 신고 수 (단계 기록이 없으면 unknown) */
  byStage: Record<MissStage | "unknown", number>;
};

/** 누락 신고가 아직 없으면(기능 전) 측정 전으로 둔다. 신고 · 직접 추가는 실제 누락의 하한이다. */
export function missed(events: ActionEventRow[], misjudged: MisjudgmentMetric, period: Period, reportingAvailable: boolean): MissedMetric {
  const reports = events.filter((e) => e.type === "user_reported_missing" && inPeriod(e.at, period));
  const added = events.filter((e) => e.type === "user_created" && inPeriod(e.at, period)).length;
  const byStage: MissedMetric["byStage"] = { processing_failed: 0, not_extracted: 0, judge_rejected: 0, merge_absorbed: 0, unknown: 0 };
  for (const report of reports) {
    const stage = report.after?.stage;
    byStage[typeof stage === "string" && stage in byStage ? (stage as MissStage) : "unknown"]++;
  }
  const reported = reports.length;
  if (!reportingAvailable) return { reported, added, rate: null, available: false, byStage };
  const total = misjudged.aiCreated + reported + added;
  return { reported, added, rate: total > 0 ? (reported + added) / total : null, available: true, byStage };
}

export type WeeklyCheckRow = {
  userId: string;
  weekStart: string;
  answer: "yes" | "no" | "skipped";
  /** 마지막으로 답한 시각 (weekly_checks.answered_at. 다시 답하면 바뀐다) */
  at: string;
};

export type ShadowListMetric = {
  /** 응답 수 (건너뛰기 포함) */
  responses: number;
  yes: number;
  no: number;
  skipped: number;
  /** "밖에 따로 적어둔 할 일이 있다" / ("있다" + "없다"). 낮을수록 Taskforce 하나로 충분하다는 뜻 */
  rate: number | null;
};

/** 지표 5: 기간 안에 받은 주간 질문 응답 */
export function shadowList(checks: WeeklyCheckRow[], period: Period): ShadowListMetric {
  const inRange = checks.filter((c) => inPeriod(c.at, period));
  const count = (answer: WeeklyCheckRow["answer"]) => inRange.filter((c) => c.answer === answer).length;
  const yes = count("yes");
  const no = count("no");
  return { responses: inRange.length, yes, no, skipped: count("skipped"), rate: yes + no > 0 ? yes / (yes + no) : null };
}

/** 서비스 하나의 재연결 안내 (기간 안) */
export type ReconnectMetric = {
  provider: string;
  /** 연결이 reauth로 바뀐 수 (connection_reauth): 알림이 갔는지와 상관없이 센다 */
  expired: number;
  /** 그중 알림이 기기에 실제로 간 수 (reconnect_notified): 만료보다 적으면 기기가 없거나 알림을 받지 못한 만료가 있다 */
  notified: number;
  /** 연결을 마친 수 (connection_created): 만료 뒤 다시 연결했는지 견준다 */
  created: number;
};

export type ConnectionsMetric = {
  /** 기간 안에 연결을 마친 수 (connection_created) */
  created: number;
  /** 연결을 마친 사용자 수 */
  users: number;
  /** 기간 안에 연결이 reauth로 바뀐 수 (connection_reauth) */
  expired: number;
  /** 기간 안에 재연결 알림이 기기에 간 수 (reconnect_notified) */
  notified: number;
  /** 서비스별 재연결 안내: 만료나 알림이 있는 서비스만, 만료가 많은 순 */
  reconnect: ReconnectMetric[];
  /** 2단계 연동 "원해요" (전체 기간, 사용자 · 서비스마다 하나): 많은 순서 */
  requests: { provider: string; count: number }[];
};

/** 연결: 연결 완료 · 만료 · 재연결 알림 이벤트와 2단계 연동 요청 수 (원칙 6: 요청이 많은 순서로 붙인다) */
export function connections(events: MetricEventRow[], requests: { provider: string }[], period: Period): ConnectionsMetric {
  const inRange = events.filter((e) => inPeriod(e.at, period));
  const created = inRange.filter((e) => e.type === "connection_created");
  const expired = inRange.filter((e) => e.type === "connection_reauth");
  const notified = inRange.filter((e) => e.type === "reconnect_notified");
  const counts = new Map<string, number>();
  for (const { provider } of requests) counts.set(provider, (counts.get(provider) ?? 0) + 1);
  const withProvider = (list: MetricEventRow[], provider: string) => list.filter((e) => e.provider === provider).length;
  const providers = new Set([...expired, ...notified].map((e) => e.provider).filter((p): p is string => Boolean(p)));
  return {
    created: created.length,
    users: new Set(created.map((e) => e.userId)).size,
    expired: expired.length,
    notified: notified.length,
    reconnect: [...providers]
      .map((provider) => ({
        provider,
        expired: withProvider(expired, provider),
        notified: withProvider(notified, provider),
        created: withProvider(created, provider),
      }))
      .sort((a, b) => b.expired - a.expired || a.provider.localeCompare(b.provider)),
    requests: [...counts].map(([provider, count]) => ({ provider, count })).sort((a, b) => b.count - a.count || a.provider.localeCompare(b.provider)),
  };
}

export type GmailFilterMetric = {
  /** 통계가 있는 Gmail 연결 수 */
  connections: number;
  /** 이유 코드별 개수의 합 (ingested: 새 원문, sent · inbound: 남긴 메일, 그 밖: 거른 메일의 규칙) */
  counts: Record<string, number>;
};

/**
 * Gmail 거르기 (원칙 6): 연결마다 설정(stats.counts)에 쌓은 이유 코드별 개수를 더한다. 전체 기간(연결마다 첫 동기화부터).
 * 거른 메일은 원문이 남지 않아 여기서만 센다 (docs/go-live/google-integration.md 8장).
 */
export function gmailFiltering(stats: unknown[]): GmailFilterMetric {
  const counts: Record<string, number> = {};
  let withStats = 0;
  for (const entry of stats) {
    const entryCounts = (entry as { counts?: unknown } | null)?.counts;
    if (!entryCounts || typeof entryCounts !== "object") continue;
    withStats++;
    for (const [key, value] of Object.entries(entryCounts)) {
      if (typeof value === "number" && Number.isFinite(value)) counts[key] = (counts[key] ?? 0) + value;
    }
  }
  return { connections: withStats, counts };
}

/** Google(Calendar · Meet) 연결 설정의 개수 합: Gmail 거르기와 같은 모양(stats.counts)이다. 전사 수 · 일정 잇기 결과(붙음 · 애매 · 없음 · 실패) · 참석한 회의 찾기 */
export const googleActivity = gmailFiltering;

export type MeetingLinkageMetric = {
  /** 기간 안에 들어온 Notion 회의록(연동 회의 원문 중 Meet 전사가 아닌 것): 전체 · 일정이 붙은 것 · 붙은 일정에 Meet 전사도 있는 것 */
  notion: { total: number; linked: number; withTranscript: number };
  /** 기간 안에 들어온 Meet 전사: 전체 · 일정이 붙은 것 */
  meet: { total: number; linked: number };
};

/** Meet 전사의 외부 id는 conferenceRecords/{c}/transcripts/{t}다 (google/transcript.ts) */
const isMeetTranscript = (externalId: string) => externalId.startsWith("conferenceRecords/");

/**
 * 회의 원문에 일정이 붙은 비율 (원칙 6, google-integration.md 8장). 원문 글자는 읽지 않고 외부 id와 붙은 일정 id만 본다.
 * 직접 입력한 회의 원문(외부 id 없음)은 세지 않는다.
 */
export function meetingLinkage(rows: { user_id: string; external_id: string | null; calendar_event_id: string | null }[]): MeetingLinkageMetric {
  const metric: MeetingLinkageMetric = { notion: { total: 0, linked: 0, withTranscript: 0 }, meet: { total: 0, linked: 0 } };
  // 같은 일정 id가 다른 사용자의 캘린더에도 있으므로(같은 회의 초대) 사용자마다 따로 본다
  const eventKey = (row: { user_id: string; calendar_event_id: string | null }) => `${row.user_id}:${row.calendar_event_id}`;
  const transcriptEvents = new Set(rows.filter((r) => r.external_id && isMeetTranscript(r.external_id) && r.calendar_event_id).map(eventKey));
  for (const row of rows) {
    if (!row.external_id) continue;
    if (isMeetTranscript(row.external_id)) {
      metric.meet.total++;
      if (row.calendar_event_id) metric.meet.linked++;
    } else {
      metric.notion.total++;
      if (row.calendar_event_id) {
        metric.notion.linked++;
        if (transcriptEvents.has(eventKey(row))) metric.notion.withTranscript++;
      }
    }
  }
  return metric;
}
