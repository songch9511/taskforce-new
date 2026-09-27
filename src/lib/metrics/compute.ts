// PRD 6장 성공 지표를 이벤트에서 계산한다 (순수 함수). 불러오기는 load.ts, 화면은 /admin/metrics.
//
// 1 AI 오판율   (사용자가 수정 · 삭제한 AI 생성 Action) / (AI 생성 Action). 필드별 · 단계별(추출 / 매칭 · 갱신)로 나눈다.
// 2 착수 시간   app_opened → 첫 action_started / handoff_used
// 3 리텐션      첫 활동 주부터 N주 뒤에도 활동했는가
// 4 AI 누락률   (신고된 누락) / (AI 생성 + 신고된 누락). 누락 신고(user_reported_missing)가 생기기 전에는 측정 전
// 5 그림자 목록  주간 질문 응답. 아직 모으지 않으므로 측정 전

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

export type MetricEventRow = { userId: string; type: string; actionId: string | null; at: string };

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
 */
function correctedFields(event: ActionEventRow, earlier: ActionEventRow[]): ErrorField[] {
  if (event.type === "user_deleted") return ["deleted"];
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
      for (const field of correctedFields(event, sorted.slice(0, index))) {
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

export function timeToStart(events: MetricEventRow[], period: Period): StartMetric {
  const byUser = new Map<string, MetricEventRow[]>();
  for (const event of events) byUser.set(event.userId, [...(byUser.get(event.userId) ?? []), event]);

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
        if (next.type !== "action_started" && next.type !== "handoff_used") continue;
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

export type MissedMetric = { reported: number; rate: number | null; available: boolean };

/** 누락 신고가 아직 없으면(기능 전) 측정 전으로 둔다. 신고는 실제 누락의 하한이다. */
export function missed(events: ActionEventRow[], misjudged: MisjudgmentMetric, period: Period, reportingAvailable: boolean): MissedMetric {
  const reported = events.filter((e) => e.type === "user_reported_missing" && inPeriod(e.at, period)).length;
  if (!reportingAvailable) return { reported, rate: null, available: false };
  const total = misjudged.aiCreated + reported;
  return { reported, rate: total > 0 ? reported / total : null, available: true };
}
