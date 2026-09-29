import { timingSafeEqual } from "node:crypto";

import { errorResponse } from "./respond";

// Vercel Cron 요청 확인: Authorization: Bearer $CRON_SECRET 인 요청만 받는다. CRON_SECRET이 비어 있으면 모두 거절한다.

export function cronAuthorized(request: Request): boolean {
  const secret = Buffer.from(process.env.CRON_SECRET ?? "");
  const given = Buffer.from(request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "");
  return secret.length > 0 && given.length === secret.length && timingSafeEqual(given, secret);
}

export const cronUnauthorized = () => errorResponse(401, "unauthorized", "cron 인증 실패");
