"use server";

import { headers } from "next/headers";
import { z } from "zod";

import { createClient } from "@/lib/supabase/server";

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
    return {
      status: "error",
      message: "로그인 링크를 보내지 못했습니다. 잠시 후 다시 시도해 주세요.",
      email: input,
    };
  }

  return { status: "sent", email: parsed.data };
}
