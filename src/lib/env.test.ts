import { describe, expect, it } from "vitest";

import { parsePublicEnv } from "./env";

describe("parsePublicEnv", () => {
  it("올바른 값이면 그대로 돌려준다", () => {
    const env = parsePublicEnv({
      NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "sb_publishable_x",
    });
    expect(env.NEXT_PUBLIC_SUPABASE_URL).toBe("https://abc.supabase.co");
  });

  it("값이 없으면 어떤 변수가 빠졌는지 알려준다", () => {
    expect(() => parsePublicEnv({ NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co" })).toThrow(
      /NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY/,
    );
  });

  it("URL 형식이 아니면 거부한다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "abc",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).toThrow(/NEXT_PUBLIC_SUPABASE_URL/);
  });

  it("대시보드 주소를 넣으면 API 주소를 쓰라고 알려준다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://supabase.com/dashboard/project/abc",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).toThrow(/경로 없이/);
  });

  it("/rest/v1/ 같은 경로가 붙으면 거부한다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co/rest/v1/",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).toThrow(/경로 없이/);
  });

  it("끝에 슬래시만 있는 주소는 허용한다", () => {
    expect(() =>
      parsePublicEnv({
        NEXT_PUBLIC_SUPABASE_URL: "https://abc.supabase.co/",
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "key",
      }),
    ).not.toThrow();
  });
});
