import { randomBytes } from "node:crypto";

import { NextResponse } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { hasAiConsent } from "@/lib/api/profile-store";
import { oauthCookie } from "@/lib/connectors/callback";
import { webConnector } from "@/lib/connectors/registry";
import { slackAuthorizeUrl } from "@/lib/connectors/slack/client";
import { slackOAuthConfig } from "@/lib/connectors/slack/run";

// Slack 연결 시작 (웹 /lab, 내부 시험용): 로그인한 사용자를 Slack 권한 화면으로 보낸다. 앱은 POST /api/v1/connections/slack/start(서명된 state)를 쓴다.
// state는 httpOnly 쿠키에 두고 callback에서 비교한다. 연결하면 받은 메시지를 원문으로 처리하므로 외부 AI 처리 동의가 먼저다.
// 앱에 Slack 연결을 열기 전(SLACK_CONNECT_ENABLED)에는 운영자(ADMIN_EMAILS)만 운영에서 시험할 수 있다.
export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return NextResponse.redirect(new URL("/login", request.url));
  if (!webConnector("slack", context.user.email)) return NextResponse.redirect(new URL("/lab?slack=unavailable", request.url));
  if (!(await hasAiConsent(context))) return NextResponse.redirect(new URL("/lab?slack=consent_required", request.url));

  const state = randomBytes(24).toString("base64url");
  const response = NextResponse.redirect(slackAuthorizeUrl(slackOAuthConfig(), state));
  // 시작한 계정까지 묶어, 그 사이 다른 계정으로 바꿔 로그인해도 연결이 엉뚱한 계정에 붙지 않게 한다.
  const cookie = oauthCookie("slack");
  response.cookies.set(cookie.name, `${state}.${context.user.id}`, {
    httpOnly: true,
    secure: new URL(request.url).protocol === "https:",
    sameSite: "lax",
    path: cookie.path,
    maxAge: 600,
  });
  return response;
}
