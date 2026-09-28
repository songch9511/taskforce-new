import { timingSafeEqual } from "node:crypto";

import { retentionCutoff } from "@/lib/retention";
import { createAdminClient } from "@/lib/supabase/admin";

// 원문 보관 기간 정리 (Vercel Cron, 매일). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
// 90일이 지난 원문의 글 · 판정 기록, 하루 지난 시도 기록(rate_limit_events · missing_reports)을 지운다 (src/lib/retention.ts).
// 한 번에 최대 PURGE_LIMIT건씩 지우므로, 밀린 게 있으면(어느 하나라도 한도만큼 지워졌으면) 시간 한도 안에서 반복해서 부른다.
export const maxDuration = 60;

const PURGE_LIMIT = 5000;
// maxDuration보다 조금 일찍 멈추고 남은 것은 다음 날 마저 지운다 (응답을 만들 시간을 남긴다).
const TIME_BUDGET_MS = (maxDuration - 10) * 1000;

type PurgeCounts = { sources_purged: number; judge_logs_deleted: number; rate_limit_events_deleted: number; missing_reports_deleted: number };

export async function GET(request: Request) {
  const secret = Buffer.from(process.env.CRON_SECRET ?? "");
  const given = Buffer.from(request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ?? "");
  if (secret.length === 0 || given.length !== secret.length || !timingSafeEqual(given, secret)) {
    return Response.json({ error: { code: "unauthorized", message: "cron 인증 실패" } }, { status: 401 });
  }

  const admin = createAdminClient();
  const before = retentionCutoff(new Date()).toISOString();
  const totals: PurgeCounts = { sources_purged: 0, judge_logs_deleted: 0, rate_limit_events_deleted: 0, missing_reports_deleted: 0 };
  const deadline = Date.now() + TIME_BUDGET_MS;
  let calls = 0;
  for (;;) {
    calls++;
    const { data } = await admin
      .rpc("purge_expired_source_text", { p_before: before, p_limit: PURGE_LIMIT })
      .single<PurgeCounts>()
      .throwOnError();
    for (const key of Object.keys(totals) as (keyof PurgeCounts)[]) totals[key] += data[key];
    const moreLeft = Object.values(data).some((n) => n >= PURGE_LIMIT);
    if (!moreLeft || Date.now() > deadline) break;
  }
  return Response.json({ ...totals, calls });
}
