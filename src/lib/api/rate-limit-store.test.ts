import { createHash } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import { LOGIN_CODE_ATTEMPT_LIMIT, takeEmailCodeAttempt, takeRateLimit } from "./rate-limit-store";

vi.mock("server-only", () => ({}));

// 서버 전용 횟수 제한 저장소: 세기와 남기기는 DB 함수 하나가 한다 (동시 요청도 한도를 넘지 못한다).
function fakeAdmin(result: { data?: unknown; error?: Error } = { data: null }) {
  const rpc = vi.fn(() => ({
    throwOnError: async () => {
      if (result.error) throw result.error;
      return { data: result.data ?? null };
    },
  }));
  return { admin: { rpc } as unknown as SupabaseClient, rpc };
}

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");

describe("takeRateLimit", () => {
  it("사용자 · 종류 · 한도를 DB 함수에 그대로 넘기고, 한도 안이면 null", async () => {
    const { admin, rpc } = fakeAdmin({ data: null });
    expect(await takeRateLimit(admin, "user-1", "ask", { max: 20, windowMs: 600_000 })).toBeNull();
    expect(rpc).toHaveBeenCalledExactlyOnceWith("take_rate_limit", { p_user_id: "user-1", p_kind: "ask", p_max: 20, p_window_seconds: 600 });
  });

  it("한도에 찼으면 다시 할 수 있는 시각", async () => {
    const { admin } = fakeAdmin({ data: "2026-10-20T12:10:00.000Z" });
    expect(await takeRateLimit(admin, "user-1", "ask", { max: 1, windowMs: 1000 })).toEqual(new Date("2026-10-20T12:10:00.000Z"));
  });
});

describe("takeEmailCodeAttempt (가입 전이라 사용자 id가 없는 로그인 코드 확인 시도)", () => {
  it("상한은 10분에 5번이다", () => {
    expect(LOGIN_CODE_ATTEMPT_LIMIT).toEqual({ max: 5, windowMs: 10 * 60_000 });
  });

  it("주소를 소문자 · 앞뒤 공백 없이 sha256으로 만들어 DB 함수에 넘긴다 (원본 주소는 보내지 않는다)", async () => {
    const { admin, rpc } = fakeAdmin({ data: null });
    expect(await takeEmailCodeAttempt(admin, "  Operator@Example.COM ", LOGIN_CODE_ATTEMPT_LIMIT)).toBeNull();
    expect(rpc).toHaveBeenCalledExactlyOnceWith("take_login_code_attempt", {
      p_email_hash: sha256("operator@example.com"),
      p_max: 5,
      p_window_seconds: 600,
    });
    expect(JSON.stringify(rpc.mock.calls)).not.toMatch(/operator@example/i);
  });

  it("한도에 찼으면 다시 할 수 있는 시각을 돌려준다", async () => {
    const { admin } = fakeAdmin({ data: "2026-10-20T12:10:00.000Z" });
    expect(await takeEmailCodeAttempt(admin, "operator@example.com", LOGIN_CODE_ATTEMPT_LIMIT)).toEqual(new Date("2026-10-20T12:10:00.000Z"));
  });

  it("DB 오류는 삼키지 않고 던진다 (부르는 쪽이 닫는다)", async () => {
    const { admin } = fakeAdmin({ error: new Error("db down") });
    await expect(takeEmailCodeAttempt(admin, "operator@example.com", LOGIN_CODE_ATTEMPT_LIMIT)).rejects.toThrow("db down");
  });
});
