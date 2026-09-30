import { webConnector } from "@/lib/connectors/registry";
import { handleOAuthCallbackRoute } from "@/lib/connectors/route-callback";

// Google 권한 화면에서 돌아오는 곳 (Google 프로젝트 A(Calendar · Meet)의 redirect URI = GOOGLE_REDIRECT_URI). 웹(/lab, 쿠키 state)과 앱(서명된 state) 흐름을 모두 받는다.
// 웹은 바로 연결한다. 앱은 code를 암호화해 완료 대기(handoff)로 두고 taskforce://로 돌려보낸다
// (연결은 앱이 POST /api/v1/connections/google/complete로 마친다, lib/connectors/callback.ts).
export const maxDuration = 60;

export async function GET(request: Request) {
  // 웹 흐름에서만 연결한다. 앱 흐름은 로그인한 사용자가 complete에서 마친다.
  return handleOAuthCallbackRoute(request, "google", (admin, userId, code, context) => {
    const connector = webConnector("google", context?.user.email ?? null);
    if (!connector) throw new Error("Google 연결을 아직 열지 않았습니다 (GOOGLE_CONNECT_ENABLED).");
    return connector.connect(admin, userId, code);
  });
}
