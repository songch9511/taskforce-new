import "server-only";

import { createClient as createSupabaseClient, type SupabaseClient } from "@supabase/supabase-js";

import { accountDisplayName } from "@/lib/api/profile";
import { publicEnv } from "@/lib/env";
import { createClient as createCookieClient } from "@/lib/supabase/server";

// /api/v1 인증. 앱은 `Authorization: Bearer <Supabase access token>`, 웹은 쿠키 세션을 보낸다.
// 어느 쪽이든 getClaims로 JWT 서명을 검증하고, 그 사용자 권한(RLS)으로 DB에 접근하는 클라이언트를 돌려준다.

export type ApiUser = {
  id: string;
  email: string | null;
  /** 원문에서 사용자를 찾을 때 쓰는 기본 이름 */
  name: string;
};

export type ApiContext = { user: ApiUser; supabase: SupabaseClient };

export async function authenticateRequest(request: Request): Promise<ApiContext | null> {
  const header = request.headers.get("authorization");
  const token = header?.match(/^Bearer\s+(.+)$/i)?.[1]?.trim();

  let supabase: SupabaseClient;
  if (token) {
    const env = publicEnv();
    supabase = createSupabaseClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
  } else {
    supabase = await createCookieClient();
  }

  const { data, error } = await supabase.auth.getClaims(token);
  if (error || !data?.claims) return null;

  const claims = data.claims;
  const email = typeof claims.email === "string" ? claims.email : null;
  return { user: { id: claims.sub, email, name: accountDisplayName(claims.user_metadata, email) }, supabase };
}
