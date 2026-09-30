import { cookies } from "next/headers";
import { after } from "next/server";

import { authenticateRequest, type ApiContext } from "@/lib/api/auth";
import { hasAiConsent } from "@/lib/api/profile-store";
import { handleOAuthCallback, oauthCookie } from "@/lib/connectors/callback";
import { afterConnected, webConnector } from "@/lib/connectors/registry";
import { consumeOAuthNonce, saveOAuthHandoff } from "@/lib/connectors/store";
import { oauthStateSecret } from "@/lib/env";
import { createAdminClient } from "@/lib/supabase/admin";

// Google 권한 화면에서 돌아오는 곳 (Google 프로젝트 A(Calendar · Meet)의 redirect URI = GOOGLE_REDIRECT_URI). 웹(/lab, 쿠키 state)과 앱(서명된 state) 흐름을 모두 받는다.
// 웹은 바로 연결한다. 앱은 code를 암호화해 완료 대기(handoff)로 두고 taskforce://로 돌려보낸다
// (연결은 앱이 POST /api/v1/connections/google/complete로 마친다, lib/connectors/callback.ts).
export const maxDuration = 60;

export async function GET(request: Request) {
  const admin = createAdminClient();
  // 웹 흐름에서 연결할 수 있는 사용자인가 (앱에 연 뒤, 또는 그 전의 운영자). 앱 흐름은 여기서 연결하지 않는다(complete가 확인한다)
  let context: ApiContext | null = null;
  return handleOAuthCallback(request, {
    provider: "google",
    stateSecret: () => oauthStateSecret(),
    cookieState: async () => {
      const [state = "", userId = ""] = ((await cookies()).get(oauthCookie("google").name)?.value ?? "").split(".");
      return state ? { state, userId } : null;
    },
    authenticate: async () => {
      context = await authenticateRequest(request);
      return context?.user ?? null;
    },
    hasConsent: async () => (context ? hasAiConsent(context) : false),
    connect: (userId, code) => {
      const connector = webConnector("google", context?.user.email ?? null);
      if (!connector) throw new Error("Google 연결을 아직 열지 않았습니다 (GOOGLE_CONNECT_ENABLED).");
      return connector.connect(admin, userId, code);
    },
    onConnected: (userId) => after(() => afterConnected(admin, userId, "google", { firstSync: false })),
    consumeNonce: (payload) => consumeOAuthNonce(admin, payload),
    saveHandoff: ({ id, userId, code }) => saveOAuthHandoff(admin, { id, userId, provider: "google", code }),
  });
}
