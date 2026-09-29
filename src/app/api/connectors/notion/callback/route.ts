import { cookies } from "next/headers";
import { after } from "next/server";

import { authenticateRequest, type ApiContext } from "@/lib/api/auth";
import { hasAiConsent } from "@/lib/api/profile-store";
import { handleOAuthCallback, oauthCookie } from "@/lib/connectors/callback";
import { afterConnected, connectorFor } from "@/lib/connectors/registry";
import { consumeOAuthNonce, saveOAuthHandoff } from "@/lib/connectors/store";
import { oauthStateSecret } from "@/lib/env";
import { createAdminClient } from "@/lib/supabase/admin";

// Notion 권한 화면에서 돌아오는 곳 (Notion에 등록한 Redirect URI). 웹(/lab, 쿠키 state)과 앱(서명된 state) 흐름을 모두 받는다.
// 웹은 바로 연결한다. 앱은 code를 암호화해 완료 대기(handoff)로 두고 taskforce://로 돌려보낸다
// (연결은 앱이 POST /api/v1/connections/notion/complete로 마친다, lib/connectors/callback.ts).
export const maxDuration = 60;

export async function GET(request: Request) {
  const admin = createAdminClient();
  let context: ApiContext | null = null;
  return handleOAuthCallback(request, {
    provider: "notion",
    stateSecret: () => oauthStateSecret(),
    cookieState: async () => {
      const [state = "", userId = ""] = ((await cookies()).get(oauthCookie("notion").name)?.value ?? "").split(".");
      return state ? { state, userId } : null;
    },
    authenticate: async () => {
      context = await authenticateRequest(request);
      return context?.user ?? null;
    },
    hasConsent: async () => (context ? hasAiConsent(context) : false),
    connect: (userId, code) => connectorFor("notion")!.connect(admin, userId, code),
    onConnected: (userId) => after(() => afterConnected(admin, userId, "notion", { firstSync: false })),
    consumeNonce: (payload) => consumeOAuthNonce(admin, payload),
    saveHandoff: ({ id, userId, code }) => saveOAuthHandoff(admin, { id, userId, provider: "notion", code }),
  });
}
