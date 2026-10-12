import { randomUUID } from "node:crypto";

import { describe, expect, it } from "vitest";

import { CURSOR_MAX_LENGTH, decodeCursor, encodeCursor, isDigest, isMicroTimestamp } from "./cursor";
import { RETURN_SUMMARY_MAX_WORKS } from "./review.config";

const USER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const base = { userId: USER, horizon: "2026-10-12T00:00:00.123456Z", digest: "a:2:-123|r:0:0|m:1:99", page: null, baseline: false };
const pack = (cursor: unknown[]) => `c3.${Buffer.from(JSON.stringify(cursor)).toString("base64url")}`;

describe("Clear 커서: 서버가 만든 글자 그대로 오간다", () => {
  it("왕복: 마이크로초 시각 · digest가 그대로 돌아온다 (JS Date를 거치지 않는다)", () => {
    const decoded = decodeCursor(encodeCursor(base), USER);
    expect(decoded).toEqual(base);
    expect(decoded?.horizon.endsWith(".123456Z")).toBe(true);
  });

  it("잘린 조회의 커서는 보인 작업 id를 싣고 그대로 돌아온다 (순서 보존). baseline 표시도", () => {
    const page = [randomUUID(), randomUUID(), randomUUID()];
    expect(decodeCursor(encodeCursor({ ...base, page, baseline: true }), USER)).toEqual({ ...base, page, baseline: true });
  });

  it(`작업 ${RETURN_SUMMARY_MAX_WORKS}개를 실어도 커서가 ${CURSOR_MAX_LENGTH}자를 넘지 않는다 (한정적)`, () => {
    const page = Array.from({ length: RETURN_SUMMARY_MAX_WORKS }, () => randomUUID());
    const raw = encodeCursor({ ...base, page });
    expect(raw.length).toBeLessThan(CURSOR_MAX_LENGTH);
    expect(raw.length).toBeGreaterThan(5000);
    expect(decodeCursor(raw, USER)?.page).toEqual(page);
  });

  it("다른 사용자의 커서는 받지 않는다 (대소문자 차이는 같은 사용자)", () => {
    expect(decodeCursor(encodeCursor(base), OTHER)).toBeNull();
    expect(decodeCursor(encodeCursor({ ...base, userId: USER.toUpperCase() }), USER)).not.toBeNull();
  });

  it.each([
    ["빈 글자", ""],
    ["다른 접두", "x1.abc"],
    ["옛 버전 접두 (c1: 시각 위치가 읽음의 근거 · c2: 작업 집합 없음)", "c2.abc"],
    ["깨진 base64", "c3.@@@"],
    ["JSON이 아님", `c3.${Buffer.from("nope").toString("base64url")}`],
    ["배열이 아님", `c3.${Buffer.from(JSON.stringify({ a: 1 })).toString("base64url")}`],
    ["원소 수가 다름", pack([USER, base.horizon, base.digest])],
    ["밀리초로 잘린 지평", encodeCursor({ ...base, horizon: "2026-10-12T00:00:00.123Z" })],
    ["시각이 아님", encodeCursor({ ...base, horizon: "yesterday" })],
    ["digest 모양이 아님", encodeCursor({ ...base, digest: "1 or 1=1" })],
    ["baseline이 0/1이 아님", pack([USER, base.horizon, base.digest, 2, null])],
    ["작업 집합이 비어 있음", pack([USER, base.horizon, base.digest, 0, ""])],
    ["작업 id 길이가 22의 배수가 아님", pack([USER, base.horizon, base.digest, 0, "abc"])],
    ["작업 id에 허용 안 되는 글자", pack([USER, base.horizon, base.digest, 0, "!".repeat(22)])],
    ["작업 id가 중복", pack([USER, base.horizon, base.digest, 0, "A".repeat(22) + "A".repeat(22)])],
    [`작업 id가 ${RETURN_SUMMARY_MAX_WORKS}개를 넘음`, pack([USER, base.horizon, base.digest, 0, "A".repeat(22 * (RETURN_SUMMARY_MAX_WORKS + 1))])],
    ["너무 김", `c3.${"A".repeat(CURSOR_MAX_LENGTH + 1)}`],
  ])("모양이 틀린 커서는 null: %s", (_name, raw) => {
    expect(decodeCursor(raw, USER)).toBeNull();
  });

  it("검사 함수", () => {
    expect(isMicroTimestamp("2026-10-12T00:00:00.000001Z")).toBe(true);
    expect(isMicroTimestamp("2026-10-12T00:00:00.000001+00:00")).toBe(false);
    expect(isDigest("a:0:0|r:0:0|m:0:0")).toBe(true);
    expect(isDigest("a:1:2|r:3:4")).toBe(false);
  });
});
