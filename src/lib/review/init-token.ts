import { isDigest, isMicroTimestamp } from "./cursor";

// 복귀 요약 첫 표시 기준점의 초기화 토큰 (서버가 조회 때 낸다, 클라이언트는 그대로 돌려줄 뿐 열어 보지 않는다).
//  - h: 지평(이 시각까지 보이던 기준점 범위의 사건을 조회가 봤다), d: 기준점 범위 — run 결과 전부 + 읽은 시각이 없는 대화 메시지 — 의 (사건, 작업) 쌍 집합 digest (SQL return_summary_digest의 기준점 범위).
//    확정은 같은 지평으로 그 범위를 다시 세어 digest가 같을 때만, 그 집합의 쌍만 읽음으로 표시한다. 시각이 읽음의 근거가 아니다(P2-A).
//  - u: 사용자 id. 남의 토큰은 받지 않는다. 토큰은 권한 증거가 아니다.
//  - Clear 커서(c3.)와 접두가 다르다: 서로 바꿔 쓸 수 없다.

const USER = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PREFIX = "i1.";
export const INIT_TOKEN_MAX_LENGTH = 400;

export type InitToken = { userId: string; horizon: string; digest: string };

export function encodeInitToken(token: InitToken): string {
  return PREFIX + Buffer.from(JSON.stringify([token.userId, token.horizon, token.digest]), "utf8").toString("base64url");
}

/** 모양이 틀렸거나(다른 접두 · 잘림 · 마이크로초가 없음) 다른 사용자의 토큰이면 null */
export function decodeInitToken(raw: string, userId: string): InitToken | null {
  if (typeof raw !== "string" || raw.length > INIT_TOKEN_MAX_LENGTH || !raw.startsWith(PREFIX)) return null;
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
