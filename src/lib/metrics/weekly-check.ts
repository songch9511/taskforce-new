import { kstWeek } from "./compute";

// 주간 질문 "Taskforce 밖에 따로 적어둔 할 일이 있나요?" (지표 5: 그림자 목록 비율)를 언제 물을지 (순수 함수).
// GET /api/v1/now가 weekly_check로 내려주고, 답은 POST /api/v1/weekly-check로 받는다.

/** 첫 원문을 넣은 뒤 이만큼 지나야 묻는다 (한 주는 써 봐야 "밖에 적어둔 일"을 답할 수 있다) */
export const WEEKLY_CHECK_AFTER_DAYS = 7;

const addDays = (isoDate: string, days: number) => new Date(Date.parse(`${isoDate}T00:00:00Z`) + days * 86_400_000).toISOString().slice(0, 10);

/**
 * 이번 주(한국 시간 월요일 시작)에 물어야 하면 그 주 월요일, 아니면 null.
 * 조건: 켜져 있음 · 첫 원문이 7일 이상 전 · 이번 주에 아직 답(건너뛰기 포함)이 없음.
 * 지난주 질문에 이번 주 들어 답했으면(월요일 새벽에 지난주 카드에 답한 경우) 이번 주 답으로 본다: 방금 답한 카드가 바로 다시 뜨지 않게.
 */
export function weeklyCheckDue(input: {
  enabled: boolean;
  /** 사용자의 가장 오래된 원문을 넣은 시각. 원문이 없으면 null */
  firstSourceAt: string | null;
  /** 받은 답: 어느 주의 질문에(week_start) 언제 답했나(answered_at, 다시 답하면 마지막 시각) */
  answers: { week_start: string; answered_at: string }[];
  now: Date;
}): { week_start: string } | null {
  if (!input.enabled || !input.firstSourceAt) return null;
  if (input.now.getTime() - Date.parse(input.firstSourceAt) < WEEKLY_CHECK_AFTER_DAYS * 86_400_000) return null;
  const week = kstWeek(input.now.toISOString());
  const previous = previousKstWeek(input.now);
  const covered = input.answers.some((a) => a.week_start === week || (a.week_start === previous && kstWeek(a.answered_at) === week));
  return covered ? null : { week_start: week };
}

/** 바로 전 주(한국 시간)의 월요일 */
export function previousKstWeek(now: Date): string {
  return addDays(kstWeek(now.toISOString()), -7);
}

/** 답을 받을 수 있는 주: 이번 주, 또는 월요일 자정을 넘겨 답한 경우를 위해 바로 전 주 */
export function isAnswerableWeek(weekStart: string, now: Date): boolean {
  return weekStart === kstWeek(now.toISOString()) || weekStart === previousKstWeek(now);
}
