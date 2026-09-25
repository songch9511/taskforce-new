import { timingSafeEqual } from "node:crypto";

import { syncAllNotion } from "@/lib/connectors/notion/run";
import { createAdminClient } from "@/lib/supabase/admin";

// 주기 동기화 (Vercel Cron 등). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
export const maxDuration = 300;

export async function GET(request: Request) {
  const secret = Buffer.from(process.env.CRON_SECRET ?? "");
  const given = Buffer.from(request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "");
  if (secret.length === 0 || given.length !== secret.length || !timingSafeEqual(given, secret)) {
    return Response.json({ error: { code: "unauthorized", message: "cron 인증 실패" } }, { status: 401 });
  }

  // 실행 시간 한도보다 조금 일찍 멈추고 남은 연결은 다음 차례로 미룬다.
  const outcomes = await syncAllNotion(createAdminClient(), { deadline: Date.now() + (maxDuration - 60) * 1000 });
  return Response.json({
    synced: outcomes.length,
    failed: outcomes.filter((o) => !o.ok).length,
    created: outcomes.reduce((n, o) => n + (o.ok ? o.result.created.length : 0), 0),
  });
}
