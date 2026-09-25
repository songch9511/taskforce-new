// 기한 표현("금요일까지", "다음 주 수요일")을 원문 작성 시점 기준 날짜로 코드가 다시 계산한다.
// 추출 프롬프트의 날짜 규칙과 같은 규칙이다. 확실히 아는 표현만 계산하고, 모르면 null을 돌려준다.

const DAY_MS = 86_400_000;
const WEEKDAY_INDEX: Record<string, number> = { 월: 0, 화: 1, 수: 2, 목: 3, 금: 4, 토: 5, 일: 6 };

type Day = { y: number; m: number; d: number };

function kstDay(date: Date): Date {
  const kst = new Date(date.getTime() + 9 * 60 * 60 * 1000);
  return new Date(Date.UTC(kst.getUTCFullYear(), kst.getUTCMonth(), kst.getUTCDate()));
}

const iso = (date: Date) => date.toISOString().slice(0, 10);
const addDays = (date: Date, days: number) => new Date(date.getTime() + days * DAY_MS);
// 월요일 = 0
const weekdayOf = (date: Date) => (date.getUTCDay() + 6) % 7;
const mondayOf = (date: Date) => addDays(date, -weekdayOf(date));

function validDay({ y, m, d }: Day): Date | null {
  const date = new Date(Date.UTC(y, m - 1, d));
  return date.getUTCMonth() === m - 1 && date.getUTCDate() === d ? date : null;
}

/** 작성 시점 기준으로 기한 표현을 날짜(YYYY-MM-DD)로 바꾼다. 모르는 표현이면 null. */
export function resolveDueText(dueText: string, occurredAt: Date): string | null {
  const text = dueText.replace(/\s+/g, " ").trim();
  const today = kstDay(occurredAt);
  const year = today.getUTCFullYear();
  const month = today.getUTCMonth() + 1;

  // 날짜를 직접 적은 경우: 10월 9일, 10/9
  const explicit = text.match(/(\d{1,2})\s*월\s*(\d{1,2})\s*일/) ?? text.match(/(?<![\d/])(\d{1,2})\/(\d{1,2})(?![\d/])/);
  if (explicit) {
    const m = Number(explicit[1]);
    const d = Number(explicit[2]);
    const date = validDay({ y: year, m, d });
    if (!date) return null;
    // 반년 넘게 지난 날짜면 내년으로 본다 (12월에 "1/5까지").
    return iso(date.getTime() < today.getTime() - 183 * DAY_MS ? (validDay({ y: year + 1, m, d }) ?? date) : date);
  }

  const weekday = text.match(/([월화수목금토일])\s*(?:요일|욜)/);
  if (weekday) {
    const target = WEEKDAY_INDEX[weekday[1]];
    if (/다다음\s*주/.test(text)) return iso(addDays(mondayOf(today), 14 + target));
    if (/다음\s*주/.test(text)) return iso(addDays(mondayOf(today), 7 + target));
    if (/(이번|이)\s*주/.test(text)) return iso(addDays(mondayOf(today), target));
    // 요일만 말하면 오늘 이후 가장 가까운 그 요일 (토·일에 "금요일"이면 다음 주 금요일)
    return iso(addDays(today, (target - weekdayOf(today) + 7) % 7));
  }

  if (/(이번|이)\s*주\s*(안|내|중|까지)/.test(text)) {
    return iso(addDays(mondayOf(today), 4));
  }

  if (/(이번\s*달|이달)\s*(말|안|내|까지)|월말/.test(text)) {
    return iso(new Date(Date.UTC(year, month, 0)));
  }

  const dayOfMonth = text.match(/(?<![\d월/])(\d{1,2})\s*일(?!\s*(?:안|내|후|뒤|간|동안))/);
  if (dayOfMonth) {
    const d = Number(dayOfMonth[1]);
    const thisMonth = validDay({ y: year, m: month, d });
    if (thisMonth && thisMonth.getTime() >= today.getTime()) return iso(thisMonth);
    const next = validDay({ y: month === 12 ? year + 1 : year, m: month === 12 ? 1 : month + 1, d });
    return next ? iso(next) : null;
  }

  if (/모레/.test(text)) return iso(addDays(today, 2));
  if (/내일/.test(text)) return iso(addDays(today, 1));
  if (/오늘|금일/.test(text)) return iso(today);

  return null;
}
