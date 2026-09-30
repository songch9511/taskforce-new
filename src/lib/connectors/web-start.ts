import { randomBytes } from "node:crypto";

import { NextResponse } from "next/server";

import type { ConnectProvider } from "@/lib/api/contract";

import { oauthCookie } from "./callback";

export function webOAuthStartResponse(
  request: Request,
  provider: ConnectProvider,
  userId: string,
  authorize: (state: string) => string,
) {
  const state = randomBytes(24).toString("base64url");
  const response = NextResponse.redirect(authorize(state));
  const cookie = oauthCookie(provider);
  response.cookies.set(cookie.name, `${state}.${userId}`, {
    httpOnly: true,
    secure: new URL(request.url).protocol === "https:",
    sameSite: "lax",
    path: cookie.path,
    maxAge: 600,
  });
  return response;
}
