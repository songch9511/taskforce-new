import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));

import { authenticateRequest } from "./auth";

const userId = "11111111-1111-4111-8111-111111111111";
const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
const jwt = (payload: unknown) => `${encode({ alg: "HS256", typ: "JWT" })}.${encode(payload)}.c2ln`;
const request = (headers: Record<string, string> = {}, method = "GET") =>
  new Request("https://api.example.test/api/v1/now", { method, headers });

function cookieClient(getClaims: ReturnType<typeof vi.fn>) {
  return { auth: { getClaims } } as unknown as SupabaseClient;
}

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
});

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

describe("authenticateRequest", () => {
  it("maps verified Bearer claims and skips cookie CSRF checks", async () => {
    const accessToken = jwt({
      sub: userId,
      role: "authenticated",
      email: "doyun@example.test",
      user_metadata: { full_name: "도윤" },
      exp: Math.floor(Date.now() / 1000) + 3600,
    });
    const fetch = vi.fn(async () =>
      new Response(JSON.stringify({ id: userId, email: "doyun@example.test", user_metadata: { full_name: "도윤" } }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetch);

    const result = await authenticateRequest(
      request({ authorization: `Bearer ${accessToken}`, "sec-fetch-site": "cross-site" }, "POST"),
    );

    expect(result?.user).toEqual({ id: userId, email: "doyun@example.test", name: "도윤" });
    expect(fetch).toHaveBeenCalledOnce();
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
  });

  it("returns null for malformed and expired Bearer tokens", async () => {
    const noNetwork = vi.fn(async () => new Response("unexpected", { status: 500 }));
    vi.stubGlobal("fetch", noNetwork);
    const malformed = `eyJhbGciOiJIUzI1NiJ9.${Buffer.from("not-json").toString("base64url")}.c2ln`;

    expect(await authenticateRequest(request({ authorization: `Bearer ${malformed}` }))).toBeNull();
    expect(await authenticateRequest(request({ authorization: `Bearer ${jwt({ sub: userId, exp: 1 })}` }))).toBeNull();
    expect(noNetwork).not.toHaveBeenCalled();
  });

  it("uses the cookie client for same-origin writes and rejects cross-site cookie writes", async () => {
    const getClaims = vi.fn().mockResolvedValue({
      data: { claims: { sub: userId, email: "doyun@example.test", user_metadata: { name: "도윤" } } },
      error: null,
    });
    mocks.createCookieClient.mockResolvedValue(cookieClient(getClaims));

    const sameOrigin = await authenticateRequest(request({ origin: "https://api.example.test" }, "POST"));
    expect(sameOrigin?.user).toEqual({ id: userId, email: "doyun@example.test", name: "도윤" });
    expect(getClaims).toHaveBeenCalledWith(undefined);

    mocks.createCookieClient.mockClear();
    expect(await authenticateRequest(request({ "sec-fetch-site": "cross-site" }, "POST"))).toBeNull();
    expect(mocks.createCookieClient).not.toHaveBeenCalled();
  });

  it("keeps configuration failures visible", async () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "");
    await expect(authenticateRequest(request({ authorization: "Bearer token" }))).rejects.toThrow(/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY/);
  });
});
