import { describe, expect, it } from "vitest";

import { isCrossSiteWrite } from "./csrf";

const req = (method: string, headers: Record<string, string> = {}) => new Request("https://api.taskforcelabs.dev/api/v1/connections/sync", { method, headers });

describe("isCrossSiteWrite", () => {
  it("같은 출처의 쓰기 · 주소창에서 직접 연 요청은 통과", () => {
    expect(isCrossSiteWrite(req("POST", { "sec-fetch-site": "same-origin" }))).toBe(false);
    expect(isCrossSiteWrite(req("POST", { "sec-fetch-site": "none" }))).toBe(false);
    expect(isCrossSiteWrite(req("DELETE", { origin: "https://api.taskforcelabs.dev" }))).toBe(false);
  });

  it("다른 사이트 · 같은 사이트의 다른 출처에서 온 쓰기 요청은 거절", () => {
    expect(isCrossSiteWrite(req("POST", { "sec-fetch-site": "cross-site" }))).toBe(true);
    expect(isCrossSiteWrite(req("POST", { "sec-fetch-site": "same-site" }))).toBe(true);
    expect(isCrossSiteWrite(req("PATCH", { origin: "https://evil.example" }))).toBe(true);
    // Sec-Fetch-Site가 있으면 그것을 따른다
    expect(isCrossSiteWrite(req("POST", { "sec-fetch-site": "cross-site", origin: "https://api.taskforcelabs.dev" }))).toBe(true);
  });

  it("읽기 요청 · 브라우저가 아닌 요청(헤더 없음)은 막지 않는다", () => {
    expect(isCrossSiteWrite(req("GET", { "sec-fetch-site": "cross-site" }))).toBe(false);
    expect(isCrossSiteWrite(req("POST"))).toBe(false);
  });
});
