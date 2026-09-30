import { NextResponse } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { hasAiConsent } from "@/lib/api/profile-store";
import { authorizeUrl } from "@/lib/connectors/notion/api";
import { notionOAuthConfig } from "@/lib/connectors/notion/run";
import { webOAuthStartResponse } from "@/lib/connectors/web-start";

// Notion 연결 시작 (웹 /lab): 로그인한 사용자를 Notion 권한 화면(페이지 고르기 포함)으로 보낸다.
// state는 httpOnly 쿠키에 두고 callback에서 비교해 다른 사이트가 연결을 끼워 넣지 못하게 한다.
// 앱은 POST /api/v1/connections/notion/start(서명된 state)를 쓴다.
// 연결하면 곧바로 원문을 가져와 처리하므로 외부 AI 처리 동의가 먼저다 (없으면 /lab?notion=consent_required).
export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return NextResponse.redirect(new URL("/login", request.url));
  if (!(await hasAiConsent(context))) return NextResponse.redirect(new URL("/lab?notion=consent_required", request.url));

  return webOAuthStartResponse(request, "notion", context.user.id, (state) => authorizeUrl(notionOAuthConfig(), state));
}
