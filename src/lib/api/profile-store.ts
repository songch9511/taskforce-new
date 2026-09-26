import "server-only";

import type { ApiContext } from "./auth";
import { profileSchema, type Profile } from "./contract";

export async function loadProfile({ supabase }: ApiContext): Promise<Profile | null> {
  const { data } = await supabase.from("profiles").select("display_name, aliases, emails").maybeSingle().throwOnError();
  return data ? profileSchema.parse(data) : null;
}

export async function saveProfile({ supabase, user }: ApiContext, profile: Profile): Promise<void> {
  await supabase.from("profiles").upsert({ user_id: user.id, ...profile }, { onConflict: "user_id" }).throwOnError();
}
