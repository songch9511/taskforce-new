import { connectorFor } from "@/lib/connectors/registry";
import { handleOAuthCallbackRoute } from "@/lib/connectors/route-callback";

// Notion 권한 화면에서 돌아오는 곳 (Notion에 등록한 Redirect URI). 웹(/lab, 쿠키 state)과 앱(서명된 state) 흐름을 모두 받는다.
// 웹은 바로 연결한다. 앱은 code를 암호화해 완료 대기(handoff)로 두고 taskforce://로 돌려보낸다
// (연결은 앱이 POST /api/v1/connections/notion/complete로 마친다, lib/connectors/callback.ts).
export const maxDuration = 60;

export async function GET(request: Request) {
  return handleOAuthCallbackRoute(request, "notion", (admin, userId, code) => connectorFor("notion")!.connect(admin, userId, code));
}
