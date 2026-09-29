import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { notifyDueSoon } from "@/lib/notify/service";
import { createAdminClient } from "@/lib/supabase/admin";

// 아침 알림 (Vercel Cron, 매일 09:00 KST). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
export async function GET(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();
  return Response.json(await notifyDueSoon(createAdminClient()));
}
