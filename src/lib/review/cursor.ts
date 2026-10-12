import { RETURN_SUMMARY_MAX_WORKS } from "./review.config";

// 복귀 요약 Clear 커서 (서버가 조회 때 낸다, 클라이언트는 그대로 돌려줄 뿐 열어 보지 않는다).
//  - h: 지평(이 시각까지 보이던 후보 사건을 조회가 봤다), d: 그 후보 (사건, 작업) 쌍 집합의 digest (SQL return_summary_digest).
//    Clear는 같은 지평으로 후보 집합을 다시 세어 digest가 같을 때만, 그 **집합의 id만** 읽음으로 표시한다. 시각이 읽음의 근거가 아니다
//    (created_at은 트랜잭션 시작 시각이라 "지평 이전은 다 봤다"를 증명하지 못한다). 지평 뒤 · 아직 commit되지 않은 사건은 집합에 없어 읽음이 되지 않는다.
//  - 시각은 SQL이 만든 마이크로초 글자 그대로다. JS Date를 거치지 않는다(밀리초로 잘리면 Clear가 stale이 된다 — 정직하게).
//  - p: 조회가 **잘렸을 때만**, 보인 작업의 id(최대 RETURN_SUMMARY_MAX_WORKS개, 16바이트 id를 base64url 22글자씩 이어 붙인다). Clear는 그 작업들의 사건만 읽음으로 표시한다 —
//    보이지 않은 작업은 읽음이 아니다. 집합을 Clear 때 다시 계산하지 않고 실어 나르는 이유: 순위가 읽음 표시에 의존하므로 Clear가 적용된 뒤의 재시도 · 다른 기기의 Clear가 끼면
//    같은 집합이 다시 나오지 않는다(응답 유실 재시도가 409가 된다). 실어 나르면 digest가 읽음 여부와 무관해 재시도 · 두 기기에서도 같다. 커서 길이는 약 6.4KB를 넘지 않는다.
//  - b: 조회 때 읽음 기준이 없었다(Clear한 적도 첫 정상 표시 기준점도 없음). 이때의 Clear가 run · 대화 이력도 기준으로 삼는다. 기준점이 있으면 꺼져 있다(기준점 이력을 다시 다루지 않는다).
//  - u: 사용자 id. 남의 커서는 받지 않는다. 커서는 권한 증거가 아니다: 서버가 사용자별로 집합을 다시 세어 digest가 같을 때만 Clear한다.

const USER = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MICRO_TS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const DIGEST = /^a:\d+:-?\d+\|r:\d+:-?\d+\|m:\d+:-?\d+$/;
const PREFIX = "c3.";
/** 커서 최대 길이: 보인 작업 id 300개를 실은 커서가 약 8.9KB다 (JSON 바깥 base64url 포함) */
export const CURSOR_MAX_LENGTH = 10_000;
const MAX_LENGTH = CURSOR_MAX_LENGTH;
const COMPACT_ID = /^[A-Za-z0-9_-]{22}$/;

export type SummaryCursor = {
  userId: string;
  horizon: string;
  digest: string;
  /** 잘린 조회가 보인 작업 id (Clear 범위). 잘리지 않았으면 null = 후보 전부 */
  page: string[] | null;
  /** 조회 때 읽음 기준이 없었다 (Clear한 적도 기준점도 없음) */
  baseline: boolean;
};

const packId = (id: string) => Buffer.from(id.replace(/-/g, ""), "hex").toString("base64url");
const unpackId = (packed: string) => {
  const hex = Buffer.from(packed, "base64url").toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
};

export const isMicroTimestamp = (value: unknown): value is string => typeof value === "string" && MICRO_TS.test(value);
export const isDigest = (value: unknown): value is string => typeof value === "string" && DIGEST.test(value);

export function encodeCursor(cursor: SummaryCursor): string {
  const page = cursor.page === null ? null : cursor.page.map(packId).join("");
  return PREFIX + Buffer.from(JSON.stringify([cursor.userId, cursor.horizon, cursor.digest, cursor.baseline ? 1 : 0, page]), "utf8").toString("base64url");
}

/** 모양이 틀렸거나(다른 버전 · 잘림 · 마이크로초가 없음) 다른 사용자의 커서면 null */
export function decodeCursor(raw: string, userId: string): SummaryCursor | null {
  if (typeof raw !== "string" || raw.length > MAX_LENGTH || !raw.startsWith(PREFIX)) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(raw.slice(PREFIX.length), "base64url").toString("utf8"));
    if (!Array.isArray(parsed) || parsed.length !== 5) return null;
    const [u, h, d, b, p] = parsed as unknown[];
    if (typeof u !== "string" || !USER.test(u) || u.toLowerCase() !== userId.toLowerCase()) return null;
    if (!isMicroTimestamp(h) || !isDigest(d) || (b !== 0 && b !== 1)) return null;
    let page: string[] | null = null;
    if (p !== null) {
      if (typeof p !== "string" || p.length === 0 || p.length % 22 !== 0 || p.length / 22 > RETURN_SUMMARY_MAX_WORKS) return null;
      const packed = p.match(/.{22}/g) ?? [];
      if (!packed.every((chunk) => COMPACT_ID.test(chunk))) return null;
      page = packed.map(unpackId);
      if (new Set(page).size !== page.length) return null;
    }
    return { userId: u, horizon: h, digest: d, page, baseline: b === 1 };
  } catch {
    return null;
  }
}
