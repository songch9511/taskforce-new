import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { loadIdentity, loadToken, saveToken } from "../store";

import { calendarClient, lookupMeetingEvent, type MeetingLookup } from "./calendar";
import { googleOAuthConfig, grantedFeatures } from "./run";
import { googleSettingsSchema } from "./settings";
import { googleAccess } from "./token";

// Notion 회의록에 붙일 Calendar 일정 조회 (G3 · G4, docs/go-live/google-integration.md 2-2 notion/sync.ts · 2-4).
// 사용자의 google 연결이 Calendar를 허용했을 때만 만든다. 만들지 못하면 null: Notion 동기화는 일정 없이 그대로 돈다.

/** 찾을 Notion 회의록: 회의 날짜(한국 날짜, 없으면 페이지를 만든 날) · 페이지를 만든 시각 · 제목 */
export type NotionMeetingTarget = { day: string; createdAt: Date; title: string | null };

/** 조회가 실패하면 던진다 (토큰 만료 · 네트워크 · 속도 제한): 부르는 쪽(notion/sync.ts)이 그 동기화의 남은 페이지를 붙이지 않는다 */
export type MeetingEventLookup = (target: NotionMeetingTarget) => Promise<MeetingLookup>;

export type GoogleCalendarLookup = {
  /** 일정 잇기 결과를 세어 넣을 google 연결 (연결 설정 stats) */
  connectionId: string;
  lookup: MeetingEventLookup;
};

export async function googleCalendarLookup(admin: SupabaseClient, userId: string): Promise<GoogleCalendarLookup | null> {
  try {
    // 이 사용자의 google 연결: 쓸 수 있는 상태(active · error)만. reauth · revoked는 토큰을 쓸 수 없다
    const { data } = await admin
      .from("connections")
      .select("id, settings")
      .eq("user_id", userId)
      .eq("provider", "google")
      .in("status", ["active", "error"])
      .order("connected_at", { ascending: false })
      .limit(1)
      .throwOnError();
    const row = (data ?? [])[0] as { id: string; settings: Record<string, unknown> | null } | undefined;
    if (!row) return null;
    const settings = googleSettingsSchema.safeParse(row.settings ?? {});
    // 설정을 읽지 못하거나 Calendar를 허용하지 않았으면(Meet만) 조회하지 않는다 (G10)
    if (!settings.success || !grantedFeatures(settings.data.scopes).calendar) return null;

    const client = calendarClient(googleAccess({ load: () => loadToken(admin, row.id), save: (token) => saveToken(admin, row.id, token) }, googleOAuthConfig()));
    // 프로필 이름은 처음 조회할 때 읽는다: 이번 동기화에 붙일 회의록이 없으면 읽지 않는다
    let me: Promise<{ name: string; email: string | null }> | null = null;
    const user = () => (me ??= loadIdentity(admin, userId).then((identity) => ({ name: identity.name, email: settings.data.email })));
    return { connectionId: row.id, lookup: async (target) => lookupMeetingEvent(client, { kind: "notion", ...target }, await user()) };
  } catch (error) {
    // Notion 동기화를 막지 않는다 (env 누락 · 연결 조회 실패 등)
    console.error("Google 일정 조회 준비 실패:", error instanceof Error ? error.message : error);
    return null;
  }
}
