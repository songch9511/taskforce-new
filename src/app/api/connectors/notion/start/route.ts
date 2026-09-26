import { randomBytes } from "node:crypto";

import { NextResponse } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { authorizeUrl } from "@/lib/connectors/notion/api";
import { notionOAuthConfig } from "@/lib/connectors/notion/run";

// Notion 연결 시작: 로그인한 사용자를 Notion 권한 화면(페이지 고르기 포함)으로 보낸다.
// state는 httpOnly 쿠키에 두고 callback에서 비교해 다른 사이트가 연결을 끼워 넣지 못하게 한다.
export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return NextResponse.redirect(new URL("/login", request.url));

  const state = randomBytes(24).toString("base64url");
  const response = NextResponse.redirect(authorizeUrl(notionOAuthConfig(), state));
  // 시작한 계정까지 묶어, 그 사이 다른 계정으로 바꿔 로그인해도 연결이 엉뚱한 계정에 붙지 않게 한다.
  response.cookies.set("notion_oauth_state", `${state}.${context.user.id}`, {
    httpOnly: true,
    secure: new URL(request.url).protocol === "https:",
    sameSite: "lax",
    path: "/api/connectors/notion",
    maxAge: 600,
  });
  return response;
}
