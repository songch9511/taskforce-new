import { readFileSync } from "node:fs";
import path from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createClient } from "@/lib/supabase/server";

import { sendCode, verifyCode, type LoginState } from "./actions";

// 웹 /login(내부 도구, 운영자): 이메일 6자리 코드. 새 계정은 만들지 않는다 (shouldCreateUser: false) — 사용자 화면은 앱이다 (CLAUDE.md "플랫폼").
// 템플릿에서 링크를 빼므로(docs/go-live/email-templates.md) 링크 로그인 대신 코드 입력이다.

vi.mock("@/lib/supabase/server", () => ({ createClient: vi.fn() }));
vi.mock("next/navigation", () => ({
  redirect: vi.fn((to: string) => {
    throw new Error(`NEXT_REDIRECT ${to}`);
  }),
}));

type AuthError = { code?: string; status?: number; message: string };
const idle: LoginState = { status: "idle" };

function fakeSupabase({ otp = null, verify = null }: { otp?: AuthError | null; verify?: AuthError | null } = {}) {
  const signInWithOtp = vi.fn(async () => ({ data: {}, error: otp }));
  const verifyOtp = vi.fn(async () => ({ data: {}, error: verify }));
  vi.mocked(createClient).mockResolvedValue({ auth: { signInWithOtp, verifyOtp } } as unknown as Awaited<ReturnType<typeof createClient>>);
  return { signInWithOtp, verifyOtp };
}

const form = (values: Record<string, string>) => {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
};

beforeEach(() => {
  vi.clearAllMocks();
});
afterEach(() => {
  vi.restoreAllMocks();
});

describe("sendCode", () => {
  it("이메일 모양이 아니면 서버를 부르지 않는다", async () => {
    const { signInWithOtp } = fakeSupabase();
    expect(await sendCode(idle, form({ email: "not-an-email" }))).toMatchObject({ status: "error", email: "not-an-email" });
    expect(signInWithOtp).not.toHaveBeenCalled();
  });

  it("새 계정을 만들지 않고(shouldCreateUser: false) 링크 주소 없이 코드만 부른다", async () => {
    const { signInWithOtp } = fakeSupabase();
    expect(await sendCode(idle, form({ email: "  Operator@Example.com " }))).toEqual({ status: "sent", email: "Operator@Example.com" });
    expect(signInWithOtp).toHaveBeenCalledExactlyOnceWith({ email: "Operator@Example.com", options: { shouldCreateUser: false } });
  });

  it("없는 주소(otp_disabled)도 같은 화면으로 보낸다 (주소가 있는지 알려 주지 않는다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    fakeSupabase({ otp: { code: "otp_disabled", status: 422, message: "Signups not allowed for otp" } });
    expect(await sendCode(idle, form({ email: "nobody@example.com" }))).toEqual({ status: "sent", email: "nobody@example.com" });
  });

  it("보내기 실패는 원인 문구로 알리고, 로그에는 이메일 주소를 가린다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    fakeSupabase({ otp: { code: "over_email_send_rate_limit", status: 429, message: "email rate limit exceeded for operator@example.com" } });
    const state = await sendCode(idle, form({ email: "operator@example.com" }));
    expect(state).toMatchObject({ status: "error", email: "operator@example.com" });
    expect((state as { message: string }).message).toMatch(/한도/);
    expect(JSON.stringify(error.mock.calls)).not.toContain("operator@example.com");
    expect(JSON.stringify(error.mock.calls)).toContain("over_email_send_rate_limit");
  });
});

describe("verifyCode", () => {
  it("공백을 지운 6자리 코드를 type: 'email'로 확인하고 /로 보낸다", async () => {
    const { verifyOtp } = fakeSupabase();
    const { redirect } = await import("next/navigation");
    await expect(verifyCode(idle, form({ email: "operator@example.com", token: " 123 456 " }))).rejects.toThrow("NEXT_REDIRECT /");
    expect(verifyOtp).toHaveBeenCalledExactlyOnceWith({ email: "operator@example.com", token: "123456", type: "email" });
    expect(redirect).toHaveBeenCalledExactlyOnceWith("/");
  });

  it("6자리 숫자가 아니면 서버를 부르지 않고 코드 칸으로 돌려보낸다", async () => {
    const { verifyOtp } = fakeSupabase();
    for (const token of ["", "12345", "1234567", "12345a", "abcdef"]) {
      const state = await verifyCode(idle, form({ email: "operator@example.com", token }));
      expect(state).toMatchObject({ status: "sent", email: "operator@example.com" });
      expect((state as { error?: string }).error).toBeTruthy();
    }
    expect(verifyOtp).not.toHaveBeenCalled();
  });

  it("이메일 모양이 아니면 처음 칸으로 돌려보낸다", async () => {
    const { verifyOtp } = fakeSupabase();
    expect(await verifyCode(idle, form({ email: "nope", token: "123456" }))).toMatchObject({ status: "error" });
    expect(verifyOtp).not.toHaveBeenCalled();
  });

  it("틀린 · 만료된 코드는 같은 문구로 알리고, 로그에는 이메일 주소 · 코드를 싣지 않는다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    fakeSupabase({ verify: { code: "otp_expired", status: 403, message: "Token has expired or is invalid for operator@example.com 654321" } });
    const state = await verifyCode(idle, form({ email: "operator@example.com", token: "654321" }));
    expect(state).toMatchObject({ status: "sent", email: "operator@example.com" });
    expect((state as { error?: string }).error).toMatch(/코드/);
    const logged = JSON.stringify(error.mock.calls);
    expect(logged).not.toContain("operator@example.com");
    expect(logged).not.toContain("654321");
    expect(logged).toContain("otp_expired");
  });
});

// 템플릿 문서 시험: 이 파일에 둔 이유 — vitest가 찾는 경로가 src · tests뿐이라 docs/ 아래 *.test.ts는 npm run test에 들지 않는다.
describe("docs/go-live/email-templates.md", () => {
  const doc = readFileSync(path.resolve(__dirname, "../../../docs/go-live/email-templates.md"), "utf8");
  const blocks = [...doc.matchAll(/```(html|text)\n([\s\S]*?)```/g)].map((m) => ({ kind: m[1], body: m[2] }));

  it("붙여 넣을 본문(HTML · 글자판)이 있다", () => {
    expect(blocks.map((b) => b.kind)).toEqual(["html", "text"]);
  });

  it("본문은 코드({{ .Token }})만 싣고 링크 · 이미지 · 추적이 없다", () => {
    for (const { kind, body } of blocks) {
      expect(body, kind).toContain("{{ .Token }}");
      expect(body, kind).not.toContain("ConfirmationURL");
      expect(body, kind).not.toContain("SiteURL");
      expect(body, kind).not.toContain("TokenHash");
      expect(body, kind).not.toMatch(/https?:/i);
      expect(body, kind).not.toMatch(/<(a|img|link|script|iframe|video)\b/i);
      expect(body, kind).not.toMatch(/\bsrc\s*=|\bhref\s*=|url\(/i);
    }
  });

  it("Magic Link와 Confirm signup 둘 다 같은 본문을 붙이라고 적는다", () => {
    expect(doc).toContain("Magic Link");
    expect(doc).toContain("Confirm signup");
    expect(doc).toContain("Your Taskforce sign-in code");
  });

  it("운영 메모: 시간당 메일 한도 30 · 코드 6자리 · 만료 600초 · 하루 상한이면 Pro", () => {
    expect(doc).toMatch(/시간당[^\n]*\b30\b/);
    expect(doc).toContain("600");
    expect(doc).toMatch(/6자리/);
    expect(doc).toMatch(/하루 상한[^\n]*Pro/);
    expect(doc).not.toMatch(/시간당[^\n]*\b60\b/);
  });
});
