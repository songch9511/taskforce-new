import "server-only";

import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import { publicEnv } from "@/lib/env";

// service role 클라이언트: RLS를 우회한다. 사용자 세션이 없는 서버 작업(연동 동기화 · 토큰 저장)에만 쓴다.
// 이 클라이언트로 쓰는 코드는 user_id를 반드시 직접 넣고, 다른 사용자의 행을 건드리지 않게 조건을 건다.
export function createAdminClient(): SupabaseClient {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) throw new Error("SUPABASE_SERVICE_ROLE_KEY가 필요합니다 (서버 전용, NEXT_PUBLIC_ 금지).");
  return createClient(publicEnv().NEXT_PUBLIC_SUPABASE_URL, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}
