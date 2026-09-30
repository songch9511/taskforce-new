import { describe, expect, it, vi } from "vitest";

import { oauthCookie } from "./callback";
import { webOAuthStartResponse } from "./web-start";

describe("web OAuth start adapter", () => {
  it.each(["notion", "slack", "gmail", "google"] as const)("sets the %s state cookie", (provider) => {
    const authorize = vi.fn((state: string) => `https://auth.example.test/?state=${state}`);
    const response = webOAuthStartResponse(new Request("https://app.example.test/start"), provider, "user-1", authorize);
    const state = authorize.mock.calls[0][0];
    const cookie = response.cookies.get(oauthCookie(provider).name);

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://auth.example.test/?state=${state}`);
    expect(state).toMatch(/^[A-Za-z0-9_-]{32}$/);
    expect(cookie?.value).toBe(`${state}.user-1`);
    expect(response.headers.get("set-cookie")).toContain(`Path=${oauthCookie(provider).path}`);
    expect(response.headers.get("set-cookie")).toContain("Max-Age=600");
    expect(response.headers.get("set-cookie")).toContain("HttpOnly");
    expect(response.headers.get("set-cookie")).toContain("Secure");
    expect(response.headers.get("set-cookie")).toContain("SameSite=lax");
  });

  it("omits Secure for an HTTP development request", () => {
    const response = webOAuthStartResponse(new Request("http://localhost:3000/start"), "notion", "user-1", () => "https://auth.example.test/");

    expect(response.headers.get("set-cookie")).not.toContain("Secure");
  });
});
