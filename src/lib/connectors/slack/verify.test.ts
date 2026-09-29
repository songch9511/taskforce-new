import { createHmac } from "node:crypto";

import { describe, expect, it } from "vitest";

import { verifySlackSignature } from "./verify";

const secret = "8f742231b10e8888abcd99yyyzzz85a5";
const body = '{"type":"event_callback","event":{"type":"message"}}';
const now = new Date("2026-10-05T10:00:00Z");
const timestamp = String(now.getTime() / 1000);
const sign = (ts: string, text: string, key = secret) => `v0=${createHmac("sha256", key).update(`v0:${ts}:${text}`).digest("hex")}`;

describe("verifySlackSignature", () => {
  it("서명 키 · 시각 · 본문이 맞으면 ok", () => {
    expect(verifySlackSignature({ secret, timestamp, signature: sign(timestamp, body), body, now })).toBe("ok");
  });

  it("본문이 바뀌었거나 다른 키로 서명했으면 invalid", () => {
    expect(verifySlackSignature({ secret, timestamp, signature: sign(timestamp, body), body: body.replace("message", "x"), now })).toBe("invalid");
    expect(verifySlackSignature({ secret, timestamp, signature: sign(timestamp, body, "other"), body, now })).toBe("invalid");
    expect(verifySlackSignature({ secret, timestamp, signature: "v0=short", body, now })).toBe("invalid");
  });

  it("헤더가 없거나 시각이 숫자가 아니면 invalid", () => {
    expect(verifySlackSignature({ secret, timestamp: null, signature: sign(timestamp, body), body, now })).toBe("invalid");
    expect(verifySlackSignature({ secret, timestamp, signature: null, body, now })).toBe("invalid");
    expect(verifySlackSignature({ secret, timestamp: "1e9", signature: sign("1e9", body), body, now })).toBe("invalid");
  });

  it("5분보다 오래됐거나 먼 미래의 요청은 stale", () => {
    const old = String(now.getTime() / 1000 - 301);
    expect(verifySlackSignature({ secret, timestamp: old, signature: sign(old, body), body, now })).toBe("stale");
    const future = String(now.getTime() / 1000 + 301);
    expect(verifySlackSignature({ secret, timestamp: future, signature: sign(future, body), body, now })).toBe("stale");
  });
});
