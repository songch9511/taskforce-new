import { NextResponse } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { hasAiConsent } from "@/lib/api/profile-store";
import { webConnector } from "@/lib/connectors/registry";
import { webOAuthStartResponse } from "@/lib/connectors/web-start";

// google(Calendar · Meet 전사) 연결 시작 (웹 /lab, 내부 시험용): 로그인한 사용자를 Google 권한 화면으로 보낸다. 앱은 POST /api/v1/connections/google/start(서명된 state)를 쓴다.
// state는 httpOnly 쿠키에 두고 callback에서 비교한다. 연결하면 Meet 전사를 원문으로 처리하므로 외부 AI 처리 동의가 먼저다.
// 앱에 Google 연결을 열기 전(GOOGLE_CONNECT_ENABLED)에는 운영자(ADMIN_EMAILS)만 운영에서 시험할 수 있다.
export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return NextResponse.redirect(new URL("/login", request.url));
  const connector = webConnector("google", context.user.email);
  if (!connector) return NextResponse.redirect(new URL("/lab?google=unavailable", request.url));
  if (!(await hasAiConsent(context))) return NextResponse.redirect(new URL("/lab?google=consent_required", request.url));

  return webOAuthStartResponse(request, "google", context.user.id, (state) => connector.authorizeUrl(state));
}
