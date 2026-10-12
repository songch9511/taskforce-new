import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { validTimeZone } from "./day";

// 사용자 시간대: 비긴급 제안의 "하루" 경계에만 쓴다. 이 스택에는 시간대 설정 저장소가 없다 — 보고 설정(H1, `report_preferences.time_zone`)이 같은 값을 갖는다.
// H1은 별도 스택이라 이 스택의 DB에는 그 표가 없을 수 있다: 표가 없으면 "모른다"(null)로 닫고 추측하지 않는다(H1도 시간대에 기본값을 두지 않는다).
// 모르면 새 비긴급 제안은 내지 않는다(긴급과 이미 낸 제안은 그대로). 표가 있는데 읽기가 실패하면 그 오류는 그대로 던진다(모르는 것과 읽지 못한 것은 다르다).

const MISSING_TABLE = new Set(["42P01", "PGRST205", "PGRST106"]);

export async function loadUserTimeZone(admin: SupabaseClient, userId: string): Promise<string | null> {
  try {
    const { data } = await admin.from("report_preferences").select("time_zone").eq("user_id", userId).maybeSingle().throwOnError();
    const zone = (data as { time_zone?: unknown } | null)?.time_zone;
    return typeof zone === "string" && validTimeZone(zone) ? zone : null;
  } catch (error) {
    const code = (error as { code?: unknown } | null)?.code;
    if (typeof code === "string" && MISSING_TABLE.has(code)) return null;
    throw error;
  }
}
