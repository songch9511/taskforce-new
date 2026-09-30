import { NextRequest } from "next/server";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createServerClient: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@supabase/ssr", () => ({ createServerClient: mocks.createServerClient }));

import { isApiPath, isPublicPath, updateSession } from "./proxy";

type RefreshCookie = { name: string; value: string; options?: { path?: string; httpOnly?: boolean; sameSite?: "lax" } };
type ServerClientOptions = {
  cookies: {
    getAll: () => unknown[];
    setAll: (cookies: RefreshCookie[], headers: Record<string, string>) => void;
  };
};

beforeEach(() => {
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
});

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("isPublicPath", () => {
  it.each(["/login", "/auth/confirm", "/auth/signout"])("%s는 로그인 없이 열린다", (path) => {
    expect(isPublicPath(path)).toBe(true);
  });

  it.each(["/", "/actions/1", "/loginx", "/authx"])("%s는 로그인이 필요하다", (path) => {
    expect(isPublicPath(path)).toBe(false);
  });
});

describe("isApiPath", () => {
  it.each(["/api/v1/sources", "/api"])("%s는 Route Handler가 직접 인증한다", (path) => {
    expect(isApiPath(path)).toBe(true);
  });

  it.each(["/", "/apix", "/lab"])("%s는 API가 아니다", (path) => {
    expect(isApiPath(path)).toBe(false);
  });
});

describe("updateSession", () => {
  it("continues public and API paths, and redirects protected pages for malformed cookie JWTs", async () => {
    mocks.createServerClient.mockReturnValue({
      auth: { getClaims: vi.fn().mockRejectedValue(new SyntaxError("malformed cookie JWT fixture")) },
    });

    const apiResponse = await updateSession(new NextRequest("https://app.example.test/api/v1/now"));
    expect(apiResponse.status).toBe(200);
    expect(apiResponse.headers.get("x-middleware-next")).toBe("1");

    const publicResponse = await updateSession(new NextRequest("https://app.example.test/login"));
    expect(publicResponse.status).toBe(200);
    expect(publicResponse.headers.get("x-middleware-next")).toBe("1");

    const protectedResponse = await updateSession(new NextRequest("https://app.example.test/lab"));
    expect(protectedResponse.status).toBe(307);
    expect(new URL(protectedResponse.headers.get("location")!).pathname).toBe("/login");
  });

  it("preserves refresh cookies and headers on an authenticated response", async () => {
    let options: ServerClientOptions | null = null;
    const supabase = {
      auth: {
        getClaims: vi.fn(async () => {
          options?.cookies.setAll(
            [{ name: "sb-test-auth-token", value: "rotated", options: { path: "/", httpOnly: true, sameSite: "lax" } }],
            { "x-auth-refresh": "updated" },
          );
          return { data: { claims: { sub: "11111111-1111-4111-8111-111111111111" } }, error: null };
        }),
      },
    };
    mocks.createServerClient.mockImplementation((_url: string, _key: string, rawOptions: unknown) => {
      options = rawOptions as ServerClientOptions;
      return supabase;
    });

    const response = await updateSession(new NextRequest("https://app.example.test/lab"));
    expect(response.status).toBe(200);
    expect(response.cookies.get("sb-test-auth-token")?.value).toBe("rotated");
    expect(response.headers.get("x-auth-refresh")).toBe("updated");
  });
});
