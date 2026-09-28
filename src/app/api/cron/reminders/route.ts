import { timingSafeEqual } from "node:crypto";

import { notifyDueSoon } from "@/lib/notify/service";
import { createAdminClient } from "@/lib/supabase/admin";

// 아침 알림 (Vercel Cron, 매일 09:00 KST). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
export async function GET(request: Request) {
  const secret = Buffer.from(process.env.CRON_SECRET ?? "");
  const given = Buffer.from(request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "");
  if (secret.length === 0 || given.length !== secret.length || !timingSafeEqual(given, secret)) {
    return Response.json({ error: { code: "unauthorized", message: "cron 인증 실패" } }, { status: 401 });
  }
  return Response.json(await notifyDueSoon(createAdminClient()));
}
