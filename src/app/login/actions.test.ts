import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";

import { sendCode, verifyCode, type LoginState } from "./actions";

// 웹 /login(내부 도구, 운영자): 이메일 8자리 코드. 새 계정은 만들지 않는다 (shouldCreateUser: false) — 사용자 화면은 앱이다 (CLAUDE.md "플랫폼").
// 템플릿에서 링크를 빼므로(docs/go-live/email-templates.md) 링크 로그인 대신 코드 입력이다.
// 이메일 로그인을 모두에게 연 뒤(20261201000000)에도 웹은 운영자(ADMIN_EMAILS)에게만 Supabase를 부른다: Vercel이 Supabase의 IP 제한을 대신 맞는 창구가 되지 않게.

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: vi.fn() }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn() }));
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

type Attempt = { p_email_hash: string; p_max: number; p_window_seconds: number };

/** 확인 시도 상한 함수(take_login_code_attempt)를 흉내 낸다: 해시마다 max번까지 null, 그 뒤는 다시 할 수 있는 시각 */
function fakeAdmin({ fail = false }: { fail?: boolean } = {}) {
  const counts = new Map<string, number>();
  const calls: { fn: string; args: Attempt }[] = [];
  const rpc = vi.fn((fn: string, args: Attempt) => {
    calls.push({ fn, args });
    return {
      throwOnError: async () => {
        if (fail) throw new Error("PRIVATE-DB-ERROR operator@example.com");
        const used = counts.get(args.p_email_hash) ?? 0;
        if (used >= args.p_max) return { data: "2026-10-20T12:10:00.000Z" };
        counts.set(args.p_email_hash, used + 1);
        return { data: null };
      },
    };
  });
  vi.mocked(createAdminClient).mockReturnValue({ rpc } as unknown as ReturnType<typeof createAdminClient>);
  return { rpc, calls };
}

const sha256 = (value: string) => createHash("sha256").update(value).digest("hex");

const form = (values: Record<string, string>) => {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
};

const WRONG_CODE = "코드가 맞지 않거나 만료되었습니다. 가장 최근 메일의 코드를 입력하거나 다시 받아 주세요.";

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("ADMIN_EMAILS", "operator@example.com, Ops@Example.com");
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("sendCode", () => {
  it("이메일 모양이 아니면 서버를 부르지 않는다", async () => {
    const { signInWithOtp } = fakeSupabase();
    expect(await sendCode(idle, form({ email: "not-an-email" }))).toMatchObject({ status: "error", email: "not-an-email" });
    expect(signInWithOtp).not.toHaveBeenCalled();
  });

  it("운영자 주소는 새 계정을 만들지 않고(shouldCreateUser: false) 링크 주소 없이 코드만 부른다 (대소문자 · 공백 무시)", async () => {
    const { signInWithOtp } = fakeSupabase();
    expect(await sendCode(idle, form({ email: "  Operator@Example.com " }))).toEqual({ status: "sent", email: "Operator@Example.com" });
    expect(signInWithOtp).toHaveBeenCalledExactlyOnceWith({ email: "Operator@Example.com", options: { shouldCreateUser: false } });
    signInWithOtp.mockClear();
    expect(await sendCode(idle, form({ email: "OPS@example.COM" }))).toMatchObject({ status: "sent" });
    expect(signInWithOtp).toHaveBeenCalledOnce();
  });

  it("운영자 목록 밖의 주소는 Supabase를 부르지 않고 같은 '보냈다' 화면을 돌려준다 (열거 0 · 한도 소진 0)", async () => {
    const { signInWithOtp } = fakeSupabase();
    const admin = fakeAdmin();
    const outside = await sendCode(idle, form({ email: "someone@example.com" }));
    expect(outside).toEqual({ status: "sent", email: "someone@example.com" });
    // 운영자 주소가 받는 성공 화면과 모양이 같다
    const inside = await sendCode(idle, form({ email: "operator@example.com" }));
    expect(Object.keys(outside).sort()).toEqual(Object.keys(inside).sort());
    expect(signInWithOtp).toHaveBeenCalledOnce();
    expect(signInWithOtp).toHaveBeenCalledWith({ email: "operator@example.com", options: { shouldCreateUser: false } });
    expect(admin.rpc).not.toHaveBeenCalled();
  });

  it("목록 밖이면 Supabase 클라이언트를 만들지도 않는다", async () => {
    await sendCode(idle, form({ email: "someone@example.com" }));
    expect(createClient).not.toHaveBeenCalled();
    expect(createAdminClient).not.toHaveBeenCalled();
  });

  it("ADMIN_EMAILS가 비어 있으면 아무도 부르지 못한다", async () => {
    vi.stubEnv("ADMIN_EMAILS", "");
    const { signInWithOtp } = fakeSupabase();
    expect(await sendCode(idle, form({ email: "operator@example.com" }))).toEqual({ status: "sent", email: "operator@example.com" });
    expect(signInWithOtp).not.toHaveBeenCalled();
  });

  it("목록 안인데 계정이 없는 주소(otp_disabled)도 같은 화면으로 보낸다 (주소가 있는지 알려 주지 않는다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    fakeSupabase({ otp: { code: "otp_disabled", status: 422, message: "Signups not allowed for otp" } });
    expect(await sendCode(idle, form({ email: "operator@example.com" }))).toEqual({ status: "sent", email: "operator@example.com" });
  });

  it("보내기 실패는 원인 문구로 알리고, 로그에는 이메일 주소를 (대소문자 상관없이) 가린다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    fakeSupabase({
      otp: { code: "over_email_send_rate_limit", status: 429, message: "email rate limit exceeded for Operator@EXAMPLE.com and operator@example.com and OPERATOR@example.COM" },
    });
    const state = await sendCode(idle, form({ email: "operator@example.com" }));
    expect(state).toMatchObject({ status: "error", email: "operator@example.com" });
    expect((state as { message: string }).message).toMatch(/한도/);
    const logged = JSON.stringify(error.mock.calls);
    expect(logged.toLowerCase()).not.toContain("operator@example.com");
    expect(logged).toContain("<email>");
    expect(logged).toContain("over_email_send_rate_limit");
  });

  it("화면에 보이는 오류 문구에는 내부 설정 안내(.env · Supabase 대시보드 · Resend · 문서 경로)가 없다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const codes: AuthError[] = [
      { code: "over_email_send_rate_limit", status: 429, message: "x" },
      { code: "email_address_invalid", status: 400, message: "x" },
      { code: "email_address_not_authorized", status: 400, message: "x" },
      { code: "email_provider_disabled", status: 422, message: "x" },
      { code: undefined, status: 401, message: "x" },
      { code: undefined, status: 403, message: "x" },
      { code: undefined, status: undefined, message: "x" },
      { code: "unexpected_failure", status: 500, message: "x" },
    ];
    for (const otp of codes) {
      fakeSupabase({ otp });
      const state = await sendCode(idle, form({ email: "operator@example.com" }));
      const message = (state as { message: string }).message;
      expect(message, JSON.stringify(otp)).toBeTruthy();
      expect(message, JSON.stringify(otp)).not.toMatch(/\.env|NEXT_PUBLIC|Supabase|Resend|\bPro\b|runbook|docs\/|터미널|대시보드|Authentication/);
    }
  });
});

describe("verifyCode", () => {
  it("운영자 주소의 8자리 코드는 공백을 지우고 type: 'email'로 확인한 뒤 /로 보낸다", async () => {
    const { verifyOtp } = fakeSupabase();
    fakeAdmin();
    const { redirect } = await import("next/navigation");
    await expect(verifyCode(idle, form({ email: "operator@example.com", token: " 1234 5678 " }))).rejects.toThrow("NEXT_REDIRECT /");
    expect(verifyOtp).toHaveBeenCalledExactlyOnceWith({ email: "operator@example.com", token: "12345678", type: "email" });
    expect(redirect).toHaveBeenCalledExactlyOnceWith("/");
  });

  it("8자리 숫자가 아니면 서버를 부르지 않고 코드 칸으로 돌려보낸다 (예전 6자리도)", async () => {
    const { verifyOtp } = fakeSupabase();
    const admin = fakeAdmin();
    for (const token of ["", "123456", "1234567", "123456789", "1234567a", "abcdefgh"]) {
      const state = await verifyCode(idle, form({ email: "operator@example.com", token }));
      expect(state).toMatchObject({ status: "sent", email: "operator@example.com" });
      expect((state as { error?: string }).error).toMatch(/8자리/);
    }
    expect(verifyOtp).not.toHaveBeenCalled();
    expect(admin.rpc).not.toHaveBeenCalled();
  });

  it("이메일 모양이 아니면 처음 칸으로 돌려보낸다", async () => {
    const { verifyOtp } = fakeSupabase();
    expect(await verifyCode(idle, form({ email: "nope", token: "12345678" }))).toMatchObject({ status: "error" });
    expect(verifyOtp).not.toHaveBeenCalled();
  });

  it("목록 밖의 주소는 Supabase도 상한 기록도 건드리지 않고, 틀린 코드와 같은 화면을 돌려준다", async () => {
    const { verifyOtp } = fakeSupabase({ verify: { code: "otp_expired", status: 403, message: "Token has expired or is invalid" } });
    const admin = fakeAdmin();
    vi.spyOn(console, "error").mockImplementation(() => {});
    const outside = await verifyCode(idle, form({ email: "someone@example.com", token: "12345678" }));
    expect(outside).toEqual({ status: "sent", email: "someone@example.com", error: WRONG_CODE });
    const wrongInside = await verifyCode(idle, form({ email: "operator@example.com", token: "12345678" }));
    expect((wrongInside as { error?: string }).error).toBe(WRONG_CODE);
    expect(verifyOtp).toHaveBeenCalledOnce();
    expect(admin.rpc).toHaveBeenCalledOnce();
    expect(createClient).toHaveBeenCalledOnce();
  });

  it("틀린 · 만료된 코드는 같은 문구로 알리고, 로그에는 이메일 주소 · 코드를 싣지 않는다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    fakeSupabase({ verify: { code: "otp_expired", status: 403, message: "Token has expired or is invalid for operator@example.com 87654321" } });
    fakeAdmin();
    const state = await verifyCode(idle, form({ email: "operator@example.com", token: "87654321" }));
    expect(state).toMatchObject({ status: "sent", email: "operator@example.com" });
    expect((state as { error?: string }).error).toBe(WRONG_CODE);
    const logged = JSON.stringify(error.mock.calls);
    expect(logged).not.toContain("operator@example.com");
    expect(logged).not.toContain("87654321");
    expect(logged).toContain("otp_expired");
  });
});

describe("verifyCode: 이메일별 확인 시도 상한", () => {
  it("확인하기 전에 이메일 해시(소문자 sha256)로 10분에 5번까지의 시도를 먼저 남긴다 (원본 주소는 보내지 않는다)", async () => {
    fakeSupabase();
    const { calls } = fakeAdmin();
    await expect(verifyCode(idle, form({ email: "Operator@Example.com", token: "12345678" }))).rejects.toThrow("NEXT_REDIRECT /");
    expect(calls).toHaveLength(1);
    expect(calls[0].fn).toBe("take_login_code_attempt");
    expect(calls[0].args).toEqual({ p_email_hash: sha256("operator@example.com"), p_max: 5, p_window_seconds: 600 });
    expect(JSON.stringify(calls)).not.toMatch(/operator@example\.com/i);
  });

  it("같은 주소는 쓴 대소문자와 상관없이 한 상한을 나눠 쓴다: 5번까지 확인하고 6번째는 맞는 코드여도 Supabase를 부르지 않는다", async () => {
    const { verifyOtp } = fakeSupabase({ verify: { code: "otp_expired", status: 403, message: "invalid" } });
    fakeAdmin();
    vi.spyOn(console, "error").mockImplementation(() => {});
    const spellings = ["operator@example.com", "Operator@Example.com", "OPERATOR@EXAMPLE.COM", "operator@example.com", "Operator@example.com"];
    for (const email of spellings) {
      const state = await verifyCode(idle, form({ email, token: "11111111" }));
      expect((state as { error?: string }).error).toBe(WRONG_CODE);
    }
    expect(verifyOtp).toHaveBeenCalledTimes(5);
    // 이제 맞는 코드가 와도 막힌다: 같은 문구, 로그인 없음
    verifyOtp.mockResolvedValue({ data: {}, error: null });
    const sixth = await verifyCode(idle, form({ email: "operator@example.com", token: "22222222" }));
    expect(sixth).toEqual({ status: "sent", email: "operator@example.com", error: WRONG_CODE });
    expect(verifyOtp).toHaveBeenCalledTimes(5);
  });

  it("다른 운영자 주소의 상한은 따로 센다", async () => {
    const { verifyOtp } = fakeSupabase({ verify: { code: "otp_expired", status: 403, message: "invalid" } });
    fakeAdmin();
    vi.spyOn(console, "error").mockImplementation(() => {});
    for (let i = 0; i < 6; i++) await verifyCode(idle, form({ email: "operator@example.com", token: "11111111" }));
    expect(verifyOtp).toHaveBeenCalledTimes(5);
    await verifyCode(idle, form({ email: "ops@example.com", token: "11111111" }));
    expect(verifyOtp).toHaveBeenCalledTimes(6);
  });

  it("상한 기록을 못 하면(DB 오류) 닫는다: Supabase를 부르지 않고 같은 문구, 로그에는 이메일 · 오류 내용이 없다", async () => {
    const { verifyOtp } = fakeSupabase();
    fakeAdmin({ fail: true });
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const state = await verifyCode(idle, form({ email: "operator@example.com", token: "12345678" }));
    expect(state).toEqual({ status: "sent", email: "operator@example.com", error: WRONG_CODE });
    expect(verifyOtp).not.toHaveBeenCalled();
    expect(error).toHaveBeenCalled();
    const logged = JSON.stringify(error.mock.calls);
    expect(logged).not.toContain("operator@example.com");
    expect(logged).not.toContain("PRIVATE-DB-ERROR");
  });

  it("상한에 막힌 시도는 로그에 단어만 남긴다 (이메일 · 코드 없음)", async () => {
    fakeSupabase({ verify: { code: "otp_expired", status: 403, message: "invalid" } });
    fakeAdmin();
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    for (let i = 0; i < 6; i++) await verifyCode(idle, form({ email: "operator@example.com", token: "11111111" }));
    const logged = JSON.stringify(error.mock.calls);
    expect(logged).toContain("login_code_attempts_exhausted");
    expect(logged).not.toContain("operator@example.com");
    expect(logged).not.toContain("11111111");
  });
});

// 화면 글 시험: 공개 페이지에 내부 설정 안내가 없고 코드는 8자리다.
describe("웹 /login 화면 글", () => {
  const read = (file: string) => readFileSync(path.resolve(__dirname, file), "utf8");

  it("코드는 8자리로 안내한다 (6자리 흔적 없음)", () => {
    for (const file of ["page.tsx", "login-form.tsx", "actions.ts"]) {
      const text = read(file);
      expect(text, file).not.toMatch(/6자리|\b123456\b/);
      expect(text, file).toMatch(/8자리|12345678/);
    }
  });

  it("공개 페이지 · 화면 오류 문구에 내부 설정 안내가 없다", () => {
    for (const file of ["page.tsx", "login-form.tsx", "errors.ts"]) {
      const text = read(file);
      expect(text, file).not.toMatch(/\.env|NEXT_PUBLIC_|Resend|runbook|docs\/go-live|개발 서버|Authentication/);
    }
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

  it("Supabase 이메일 템플릿 여섯 개 모두에 같은 본문을 붙이라고 적는다 (앱이 안 쓰는 흐름도 링크가 남지 않게)", () => {
    for (const name of ["Confirm signup", "Magic Link", "Reset Password", "Invite user", "Change Email Address", "Reauthentication"]) {
      expect(doc, name).toContain(name);
    }
    expect(doc).toContain("Your Taskforce sign-in code");
    expect(doc).toMatch(/여섯|6개/);
  });

  it("운영 메모: 시간당 메일 한도 30 · 코드 8자리 · 만료 600초 · 하루 상한이면 Pro", () => {
    expect(doc).toMatch(/시간당[^\n]*\b30\b/);
    expect(doc).toContain("600");
    expect(doc).toMatch(/8자리/);
    expect(doc).not.toMatch(/6자리/);
    expect(doc).toMatch(/하루 상한[^\n]*Pro/);
    expect(doc).not.toMatch(/시간당[^\n]*\b60\b/);
  });
});
