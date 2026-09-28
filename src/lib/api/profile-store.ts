import "server-only";

import { createAdminClient } from "@/lib/supabase/admin";

import type { ApiContext } from "./auth";
import { profileSchema, type Profile, type ProfileInput } from "./contract";

const PROFILE_COLUMNS = "display_name, aliases, emails, ai_consent_at";

export async function loadProfile({ supabase }: ApiContext): Promise<Profile | null> {
  const { data } = await supabase.from("profiles").select(PROFILE_COLUMNS).maybeSingle().throwOnError();
  return data ? profileSchema.parse(data) : null;
}

/** 이름 · 별칭 · 이메일만 쓴다. 동의 시각(ai_consent_at)은 클라이언트 권한으로 쓸 수 없다 (마이그레이션 20261003000000). */
export async function saveProfile({ supabase, user }: ApiContext, profile: ProfileInput): Promise<Profile> {
  const { data } = await supabase
    .from("profiles")
    .upsert({ user_id: user.id, ...profile }, { onConflict: "user_id" })
    .select(PROFILE_COLUMNS)
    .single()
    .throwOnError();
  return profileSchema.parse(data);
}

/** 외부 AI 처리에 동의했는가 (사용자 권한으로 자기 프로필을 읽는다) */
export async function hasAiConsent({ supabase }: ApiContext): Promise<boolean> {
  const { data } = await supabase.from("profiles").select("ai_consent_at").maybeSingle().throwOnError();
  return Boolean((data as { ai_consent_at: string | null } | null)?.ai_consent_at);
}

/** 동의 · 철회 (POST · DELETE /api/v1/consent). 동의 시각은 서버(service role)만 쓴다. */
export async function saveAiConsent({ user }: ApiContext, consentedAt: Date | null): Promise<void> {
  const admin = createAdminClient();
  if (consentedAt) {
    await admin.from("profiles").upsert({ user_id: user.id, ai_consent_at: consentedAt.toISOString() }, { onConflict: "user_id" }).throwOnError();
  } else {
    await admin.from("profiles").update({ ai_consent_at: null }).eq("user_id", user.id).throwOnError();
  }
}
