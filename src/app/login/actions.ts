"use server";

import { headers } from "next/headers";
import { z } from "zod";

import { createClient } from "@/lib/supabase/server";

import { magicLinkErrorMessage } from "./errors";

export type LoginState =
  | { status: "idle" }
  | { status: "sent"; email: string }
  | { status: "error"; message: string; email: string };

const emailSchema = z.email();

export async function sendMagicLink(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const input = String(formData.get("email") ?? "").trim();
  const parsed = emailSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "이메일 주소를 확인해 주세요.", email: input };
  }

  const origin = (await headers()).get("origin");
  if (!origin) {
    return { status: "error", message: "요청 주소를 확인할 수 없습니다. 다시 시도해 주세요.", email: input };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithOtp({
    email: parsed.data,
    options: { emailRedirectTo: `${origin}/auth/confirm` },
  });

  if (error) {
    // 원인 파악용 로그. 오류 문구에 섞일 수 있는 이메일 주소는 가린다.
    console.error("[login] signInWithOtp 실패", {
      code: error.code,
      status: error.status,
      message: error.message.replaceAll(parsed.data, "<email>"),
    });
    return { status: "error", message: magicLinkErrorMessage(error), email: input };
  }

  return { status: "sent", email: parsed.data };
}
