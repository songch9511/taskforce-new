"use server";

import { redirect } from "next/navigation";
import { z } from "zod";

import { createClient } from "@/lib/supabase/server";

import { loginCodeErrorMessage } from "./errors";

// 웹 /login은 내부 도구(운영자)다. 이메일로 6자리 코드를 받아 로그인한다. 새 계정은 만들지 않는다: 사용자 화면은 앱이다 (CLAUDE.md "플랫폼").
// 이메일 템플릿에 링크를 두지 않으므로(docs/go-live/email-templates.md) 링크 로그인 대신 코드를 입력한다.
// `sent`에 `error`가 있으면 코드 칸의 오류다. 없는 주소로 보내도 같은 화면으로 간다 (주소가 있는지 알려 주지 않는다).
export type LoginState =
  | { status: "idle" }
  | { status: "sent"; email: string; error?: string }
  | { status: "error"; message: string; email: string };

const emailSchema = z.email();
const codeSchema = z.string().regex(/^\d{6}$/);

export async function sendCode(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const input = String(formData.get("email") ?? "").trim();
  const parsed = emailSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "이메일 주소를 확인해 주세요.", email: input };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data,
    options: { shouldCreateUser: false },
  });

  if (error) {
    // 새 계정을 만들지 않는 요청이 없는 주소에 간 경우: 있는지 알려 주지 않는다
    if (error.code === "otp_disabled") return { status: "sent", email: parsed.data };
    // 원인 파악용 로그. 오류 문구에 섞일 수 있는 이메일 주소는 가린다.
    console.error("[login] signInWithOtp 실패", {
      code: error.code,
      status: error.status,
      message: error.message.replaceAll(parsed.data, "<email>"),
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
    return { status: "sent", email: email.data, error: "6자리 숫자 코드를 입력해 주세요." };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.verifyOtp({ email: email.data, token: token.data, type: "email" });
  if (error) {
    // 이메일 주소 · 코드는 로그에 싣지 않는다
    console.error("[login] verifyOtp 실패", { code: error.code, status: error.status });
    return { status: "sent", email: email.data, error: "코드가 맞지 않거나 만료되었습니다. 가장 최근 메일의 코드를 입력하거나 다시 받아 주세요." };
  }

  redirect("/");
}
