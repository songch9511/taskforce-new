// 복귀 요약 Clear 커서 (서버가 조회 때 낸다, 클라이언트는 그대로 돌려줄 뿐 열어 보지 않는다).
//  - w: 조회 때 Clear 위치(null = 한 번도 Clear하지 않음), h: 지평(이 시각까지의 사건을 봤다), d: 그 범위의 사건 digest (SQL return_summary_digest).
//  - 시각은 SQL이 만든 마이크로초 글자 그대로다. JS Date를 거치지 않는다(밀리초로 잘리면 Clear가 stale이 된다 — 정직하게).
//  - u: 사용자 id. 남의 커서는 받지 않는다. 커서는 권한 증거가 아니다: 서버가 사용자별로 범위를 다시 세어 digest가 같을 때만 Clear한다.

const USER = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MICRO_TS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const DIGEST = /^a:\d+:-?\d+\|r:\d+:-?\d+\|m:\d+:-?\d+$/;
const PREFIX = "c1.";
const MAX_LENGTH = 400;

export type SummaryCursor = { userId: string; since: string | null; horizon: string; digest: string };

export const isMicroTimestamp = (value: unknown): value is string => typeof value === "string" && MICRO_TS.test(value);
export const isDigest = (value: unknown): value is string => typeof value === "string" && DIGEST.test(value);

export function encodeCursor(cursor: SummaryCursor): string {
  return PREFIX + Buffer.from(JSON.stringify([cursor.userId, cursor.since, cursor.horizon, cursor.digest]), "utf8").toString("base64url");
}

/** 모양이 틀렸거나(다른 버전 · 잘림 · 마이크로초가 없음) 다른 사용자의 커서면 null */
export function decodeCursor(raw: string, userId: string): SummaryCursor | null {
  if (typeof raw !== "string" || raw.length > MAX_LENGTH || !raw.startsWith(PREFIX)) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(raw.slice(PREFIX.length), "base64url").toString("utf8"));
    if (!Array.isArray(parsed) || parsed.length !== 4) return null;
    const [u, w, h, d] = parsed as unknown[];
    if (typeof u !== "string" || !USER.test(u) || u.toLowerCase() !== userId.toLowerCase()) return null;
    if (!(w === null || isMicroTimestamp(w)) || !isMicroTimestamp(h) || !isDigest(d)) return null;
    return { userId: u, since: w, horizon: h, digest: d };
  } catch {
    return null;
  }
}
