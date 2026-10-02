import { AuthInvalidJwtError, AuthRetryableFetchError, createClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { getVerifiedClaims } from "./claims";

const url = "https://project.example.test";
const key = "sb_publishable_local-test";
const userId = "11111111-1111-4111-8111-111111111111";
const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
const token = (header: unknown, payload: unknown) => `${encode(header)}.${encode(payload)}.c2ln`;
const claims = { sub: userId, role: "authenticated", exp: 4_102_444_800 };
const invalidJsonToken = `eyJhbGciOiJIUzI1NiJ9.${Buffer.from("not-json").toString("base64url")}.c2ln`;

function client(fetch: typeof globalThis.fetch = globalThis.fetch) {
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { fetch },
  });
}

function cookieClient(accessToken: unknown) {
  const session = {
    access_token: accessToken,
    token_type: "bearer",
    expires_in: 3600,
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    refresh_token: "local-test-refresh-token",
    user: { id: userId },
  };
  return createClient(url, key, {
    auth: {
      storage: {
        getItem: async () => JSON.stringify(session),
        setItem: async () => {},
        removeItem: async () => {},
      },
      persistSession: true,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
}

describe("getVerifiedClaims", () => {
  it("turns malformed JWT JSON into the SDK's invalid-JWT result for Bearer and cookie sessions", async () => {
    const bearer = await getVerifiedClaims(client(), invalidJsonToken);
    expect(bearer.data).toBeNull();
    expect(bearer.error).toBeInstanceOf(AuthInvalidJwtError);

    const cookie = await getVerifiedClaims(cookieClient(invalidJsonToken));
    expect(cookie.data).toBeNull();
    expect(cookie.error).toBeInstanceOf(AuthInvalidJwtError);
  });

  it("rejects null and non-string algorithm headers only when the SDK throws on them", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>();
    const supabase = client(fetch);

    for (const malformed of [token(null, claims), token({ alg: 1, kid: "test" }, claims)]) {
      const result = await getVerifiedClaims(supabase, malformed);
      expect(result.data).toBeNull();
      expect(result.error).toBeInstanceOf(AuthInvalidJwtError);
    }

    expect(fetch).not.toHaveBeenCalled();
  });

  it("uses getSession only to reject malformed cookie token shapes", async () => {
    for (const accessToken of [token({ alg: 1, kid: "test" }, claims), 123]) {
      const result = await getVerifiedClaims(cookieClient(accessToken));
      expect(result.data).toBeNull();
      expect(result.error).toBeInstanceOf(AuthInvalidJwtError);
    }
  });

  it("keeps JWKS response failures as SDK errors", async () => {
    const fetch: typeof globalThis.fetch = async () => new Response("{", { status: 200 });
    const result = await getVerifiedClaims(client(fetch), token({ alg: "RS256", kid: "test" }, claims));

    expect(result.data).toBeNull();
    expect(result.error).toBeInstanceOf(AuthRetryableFetchError);
  });

  it("does not swallow WebCrypto failures for a valid header", async () => {
    const fetch: typeof globalThis.fetch = async () =>
      new Response(JSON.stringify({ keys: [{ kty: "RSA", kid: "test", alg: "RS256", n: "AQAB", e: "AQAB" }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    const cryptoFailure = new TypeError("subtle import fixture failure");
    const importKey = vi.spyOn(globalThis.crypto.subtle, "importKey").mockRejectedValue(cryptoFailure);

    try {
      await expect(getVerifiedClaims(client(fetch), token({ alg: "RS256", kid: "test" }, claims))).rejects.toBe(cryptoFailure);
    } finally {
      importKey.mockRestore();
    }
  });
});
