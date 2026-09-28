import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

import { publicEnv } from "@/lib/env";

// 요청마다 새로 만든다. 요청 간에 클라이언트를 공유하지 않는다.
export async function createClient() {
  // cookies()를 먼저 읽어야 이 클라이언트를 쓰는 페이지가 요청 시점 렌더링으로 분류된다.
  const cookieStore = await cookies();
  const env = publicEnv();

  return createServerClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
        } catch {
          // Server Component에서는 쿠키를 쓸 수 없다. 세션 갱신은 src/proxy.ts가 맡는다.
        }
      },
    },
  });
}
