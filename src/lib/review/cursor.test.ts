import { describe, expect, it } from "vitest";

import { decodeCursor, encodeCursor, isDigest, isMicroTimestamp } from "./cursor";

const USER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const base = { userId: USER, since: "2026-10-12T00:00:00.000100Z", horizon: "2026-10-12T00:00:00.123456Z", digest: "a:2:-123|r:0:0|m:1:99" };

describe("Clear 커서: 서버가 만든 글자 그대로 오간다", () => {
  it("왕복: 마이크로초 시각 · digest가 그대로 돌아온다 (JS Date를 거치지 않는다)", () => {
    const decoded = decodeCursor(encodeCursor(base), USER);
    expect(decoded).toEqual(base);
    expect(decoded?.horizon.endsWith(".123456Z")).toBe(true);
  });

  it("한 번도 Clear하지 않은 커서(since null)도 왕복한다", () => {
    expect(decodeCursor(encodeCursor({ ...base, since: null }), USER)).toEqual({ ...base, since: null });
  });

  it("다른 사용자의 커서는 받지 않는다 (대소문자 차이는 같은 사용자)", () => {
    expect(decodeCursor(encodeCursor(base), OTHER)).toBeNull();
    expect(decodeCursor(encodeCursor({ ...base, userId: USER.toUpperCase() }), USER)).not.toBeNull();
  });

  it.each([
    ["빈 글자", ""],
    ["다른 접두", "x1.abc"],
    ["깨진 base64", "c1.@@@"],
    ["JSON이 아님", `c1.${Buffer.from("nope").toString("base64url")}`],
    ["배열이 아님", `c1.${Buffer.from(JSON.stringify({ a: 1 })).toString("base64url")}`],
    ["원소 수가 다름", `c1.${Buffer.from(JSON.stringify([USER, null, base.horizon])).toString("base64url")}`],
    ["밀리초로 잘린 지평", encodeCursor({ ...base, horizon: "2026-10-12T00:00:00.123Z" })],
    ["시각이 아님", encodeCursor({ ...base, horizon: "yesterday" })],
    ["since가 밀리초", encodeCursor({ ...base, since: "2026-10-12T00:00:00Z" })],
    ["digest 모양이 아님", encodeCursor({ ...base, digest: "1 or 1=1" })],
    ["너무 김", `c1.${"A".repeat(500)}`],
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
