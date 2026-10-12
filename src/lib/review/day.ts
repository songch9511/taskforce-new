// 사용자 현지 날짜 (순수 함수): 비긴급 제안의 "하루"는 서버 시각을 사용자 시간대로 옮긴 달력 날짜다.
// 시계는 호출하는 쪽이 넘긴다(고정 시계로 시험). DST로 하루가 23 · 25시간이어도 달력 날짜는 하나다 — 시각 차이가 아니라 현지 날짜 글자로 정한다.

/** IANA 이름 모양 (H1 report_preferences.time_zone CHECK와 같다): "+09:00" 같은 오프셋은 이름이 아니라서 받지 않는다 */
const IANA_SHAPE = /^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/;

/** IANA 시간대 이름이 이 런타임(Intl)에서 유효한가 */
export function validTimeZone(timeZone: string): boolean {
  if (typeof timeZone !== "string" || timeZone.length === 0 || timeZone.length > 64 || !IANA_SHAPE.test(timeZone)) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone });
    return true;
  } catch {
    return false;
  }
}

/** now를 timeZone의 현지 달력 날짜 "YYYY-MM-DD"로. 시간대가 유효하지 않으면 null (추측하지 않는다) */
export function localDay(now: Date, timeZone: string): string | null {
  if (!validTimeZone(timeZone) || Number.isNaN(now.getTime())) return null;
  const parts = new Intl.DateTimeFormat("en-US", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(now);
  const pick = (type: string) => parts.find((part) => part.type === type)?.value;
  const [year, month, day] = [pick("year"), pick("month"), pick("day")];
  return year && month && day ? `${year.padStart(4, "0")}-${month}-${day}` : null;
}
