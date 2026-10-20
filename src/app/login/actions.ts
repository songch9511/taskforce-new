"use server";

import { redirect } from "next/navigation";
import { z } from "zod";

import { LOGIN_CODE_ATTEMPT_LIMIT, takeEmailCodeAttempt } from "@/lib/api/rate-limit-store";
import { isAdmin } from "@/lib/metrics/load";
import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";

import { loginCodeErrorMessage, maskEmail } from "./errors";

// 웹 /login은 내부 도구(운영자)다. 이메일로 8자리 코드를 받아 로그인한다. 새 계정은 만들지 않는다: 사용자 화면은 앱이다 (CLAUDE.md "플랫폼").
// 이메일 템플릿에 링크를 두지 않으므로(docs/go-live/email-templates.md) 링크 로그인 대신 코드를 입력한다.
// `sent`에 `error`가 있으면 코드 칸의 오류다. 없는 주소로 보내도 같은 화면으로 간다 (주소가 있는지 알려 주지 않는다).
//
// 이메일 로그인을 모두에게 연 뒤(20261201000000)에는 Supabase의 공개 OTP API가 누구에게나 열려 있다. 웹 /login까지 열어 두면
// 이 서버(Vercel)가 아무 주소의 코드를 맞히거나 메일 한도를 비우는 창구가 되므로, 운영자 목록(ADMIN_EMAILS)에 있는 주소만 Supabase를 부른다.
// 목록 밖이면 부르지 않고 같은 화면을 돌려준다 (목록에 있는지 알려 주지 않는다). 목록 안의 주소는 확인 시도를 주소별로 센다.
export type LoginState =
  | { status: "idle" }
  | { status: "sent"; email: string; error?: string }
  | { status: "error"; message: string; email: string };

const emailSchema = z.email();
const codeSchema = z.string().regex(/^\d{8}$/);

// 틀린 코드 · 만료 · 운영자 목록 밖 · 시도 상한 · 기록 실패가 모두 같은 문구다 (어느 쪽인지 알려 주지 않는다). 구별은 서버 로그의 낱말로 한다.
const WRONG_CODE_MESSAGE = "코드가 맞지 않거나 만료되었습니다. 가장 최근 메일의 코드를 입력하거나 다시 받아 주세요.";

export async function sendCode(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const input = String(formData.get("email") ?? "").trim();
  const parsed = emailSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "이메일 주소를 확인해 주세요.", email: input };
  }

  // 운영자 목록 밖: Supabase를 부르지 않고 같은 "보냈다" 화면 (열거 0 · 메일 한도 소진 0)
  if (!isAdmin(parsed.data)) return { status: "sent", email: parsed.data };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data,
    options: { shouldCreateUser: false },
  });

  if (error) {
    // 새 계정을 만들지 않는 요청이 없는 주소에 간 경우: 있는지 알려 주지 않는다
    if (error.code === "otp_disabled") return { status: "sent", email: parsed.data };
    // 원인 파악용 로그. 오류 문구에 섞일 수 있는 이메일 주소는 (대소문자 상관없이) 가린다.
    console.error("[login] signInWithOtp 실패", {
      code: error.code,
      status: error.status,
      message: maskEmail(error.message, parsed.data),
    });
    return { status: "error", message: loginCodeErrorMessage(error), email: input };
  }

  return { status: "sent", email: parsed.data };
}

export async function verifyCode(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const input = String(formData.get("email") ?? "").trim();
  const email = emailSchema.safeParse(input);
  if (!email.success) {
    return { status: "error", message: "이메일 주소를 확인해 주세요.", email: input };
  }
  const token = codeSchema.safeParse(String(formData.get("token") ?? "").replace(/\s+/g, ""));
  if (!token.success) {
    return { status: "sent", email: email.data, error: "8자리 숫자 코드를 입력해 주세요." };
  }

  const wrongCode: LoginState = { status: "sent", email: email.data, error: WRONG_CODE_MESSAGE };

  // 운영자 목록 밖: Supabase도 시도 기록도 건드리지 않고 틀린 코드와 같은 화면
  if (!isAdmin(email.data)) return wrongCode;

  // 확인하기 전에 주소별 시도를 먼저 남긴다 (한 주소에 10분 5번). 동시에 여러 번 보내도 DB 함수 하나가 세어 상한을 넘지 못한다.
  // 기록하지 못하면 닫는다. 주소 · 코드 · 오류 내용은 로그에 싣지 않는다.
  let retryAt: Date | null;
  try {
    retryAt = await takeEmailCodeAttempt(createAdminClient(), email.data, LOGIN_CODE_ATTEMPT_LIMIT);
  } catch {
    console.error("[login] login_code_attempts_unavailable");
    return wrongCode;
  }
  if (retryAt) {
    console.error("[login] login_code_attempts_exhausted");
    return wrongCode;
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.verifyOtp({ email: email.data, token: token.data, type: "email" });
  if (error) {
    // 이메일 주소 · 코드는 로그에 싣지 않는다
    console.error("[login] verifyOtp 실패", { code: error.code, status: error.status });
    return wrongCode;
  }

  redirect("/");
}
