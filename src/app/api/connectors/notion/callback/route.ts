import { timingSafeEqual } from "node:crypto";

import { cookies } from "next/headers";
import { NextResponse } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { exchangeCode } from "@/lib/connectors/notion/api";
import { notionOAuthConfig } from "@/lib/connectors/notion/run";
import { saveConnection } from "@/lib/connectors/store";
import { createAdminClient } from "@/lib/supabase/admin";

// Notion 권한 화면에서 돌아오는 곳: state를 확인하고 code를 토큰으로 바꿔 암호화해 저장한다.
export async function GET(request: Request) {
  const url = new URL(request.url);
  const back = (status: string) => {
    const response = NextResponse.redirect(new URL(`/lab?notion=${status}`, request.url));
    response.cookies.delete({ name: "notion_oauth_state", path: "/api/connectors/notion" });
    return response;
  };

  const context = await authenticateRequest(request);
  if (!context) return NextResponse.redirect(new URL("/login", request.url));

  const [expectedState = "", expectedUser = ""] = ((await cookies()).get("notion_oauth_state")?.value ?? "").split(".");
  const expected = Buffer.from(expectedState);
  const given = Buffer.from(url.searchParams.get("state") ?? "");
  const stateOk = expected.length > 0 && expected.length === given.length && timingSafeEqual(expected, given);
  if (!stateOk || expectedUser !== context.user.id) return back("invalid_state");

  const code = url.searchParams.get("code");
  if (!code) return back(url.searchParams.get("error") === "access_denied" ? "denied" : "error");

  try {
    const token = await exchangeCode(notionOAuthConfig(), code);
    await saveConnection(createAdminClient(), {
      userId: context.user.id,
      provider: "notion",
      externalAccountId: token.workspace_id,
      displayName: token.workspace_name ?? null,
      token,
    });
    return back("connected");
  } catch (error) {
    console.error("Notion 연결 실패:", error instanceof Error ? error.message : error);
    return back("error");
  }
}
