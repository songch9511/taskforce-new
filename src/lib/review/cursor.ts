// 복귀 요약 Clear 커서 (서버가 조회 때 낸다, 클라이언트는 그대로 돌려줄 뿐 열어 보지 않는다).
//  - h: 지평(이 시각까지 보이던 후보 사건을 조회가 봤다), d: 그 후보 사건 id 집합의 digest (SQL return_summary_digest).
//    Clear는 같은 지평으로 후보 집합을 다시 세어 digest가 같을 때만, 그 **집합의 id만** 읽음으로 표시한다. 시각이 읽음의 근거가 아니다
//    (created_at은 트랜잭션 시작 시각이라 "지평 이전은 다 봤다"를 증명하지 못한다). 지평 뒤 · 아직 commit되지 않은 사건은 집합에 없어 읽음이 되지 않는다.
//  - 시각은 SQL이 만든 마이크로초 글자 그대로다. JS Date를 거치지 않는다(밀리초로 잘리면 Clear가 stale이 된다 — 정직하게).
//  - u: 사용자 id. 남의 커서는 받지 않는다. 커서는 권한 증거가 아니다: 서버가 사용자별로 집합을 다시 세어 digest가 같을 때만 Clear한다.

const USER = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MICRO_TS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const DIGEST = /^a:\d+:-?\d+\|r:\d+:-?\d+\|m:\d+:-?\d+$/;
const PREFIX = "c2.";
const MAX_LENGTH = 400;

export type SummaryCursor = { userId: string; horizon: string; digest: string };

export const isMicroTimestamp = (value: unknown): value is string => typeof value === "string" && MICRO_TS.test(value);
export const isDigest = (value: unknown): value is string => typeof value === "string" && DIGEST.test(value);

export function encodeCursor(cursor: SummaryCursor): string {
  return PREFIX + Buffer.from(JSON.stringify([cursor.userId, cursor.horizon, cursor.digest]), "utf8").toString("base64url");
}

/** 모양이 틀렸거나(다른 버전 · 잘림 · 마이크로초가 없음) 다른 사용자의 커서면 null */
export function decodeCursor(raw: string, userId: string): SummaryCursor | null {
  if (typeof raw !== "string" || raw.length > MAX_LENGTH || !raw.startsWith(PREFIX)) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(raw.slice(PREFIX.length), "base64url").toString("utf8"));
    if (!Array.isArray(parsed) || parsed.length !== 3) return null;
    const [u, h, d] = parsed as unknown[];
    if (typeof u !== "string" || !USER.test(u) || u.toLowerCase() !== userId.toLowerCase()) return null;
    if (!isMicroTimestamp(h) || !isDigest(d)) return null;
    return { userId: u, horizon: h, digest: d };
  } catch {
    return null;
  }
}
