import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { flagEnabled } from "@/lib/flags";
import { apnsConfigFromEnv } from "@/lib/notify/apns";
import { runDailyReports } from "@/lib/reports/job";
import { supabaseReportStore } from "@/lib/reports/store";
import { createAdminClient } from "@/lib/supabase/admin";

// 일일 보고 (0.2.0 H1). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
// REPORTS_V2_ENABLED가 꺼져 있으면 아무것도 읽거나 보내지 않고 { enabled: false } (기존 cron/reminders는 따로 그대로 돈다).
// 운영 스케줄(vercel.json "*/5 * * * *")은 출시 단계에서 더한다 (docs/FEATURE_MAP.md 3-8). 사용자 시간대의 보고 시각을 5분 안에 잡는다.
// 한 사용자는 기기마다 APNs 한도 10초라 60초면 넉넉하다. 시간이 모자라면 남은 사용자는 다음 실행이 창(2시간) 안에서 잡는다.
export const maxDuration = 60;

export async function GET(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();
  if (!flagEnabled("REPORTS_V2_ENABLED")) return Response.json({ enabled: false });
  const config = apnsConfigFromEnv();
  // APNs 키가 없으면 보낼 수 없으니 원장도 만들지 않는다 (기존 알림과 같다)
  if (!config) return Response.json({ enabled: true, configured: false });

  // 시각은 잡기 · 보내기마다 다시 읽는다 (job 안의 시계). 응답할 시간을 남긴다
  const result = await runDailyReports(supabaseReportStore(createAdminClient()), { config }, { deadline: Date.now() + (maxDuration - 15) * 1000 });
  (result.failed > 0 || result.errors > 0 || result.fence_missed > 0 ? console.error : console.info)(JSON.stringify({ event: "daily_reports", ...result }));
  return Response.json({ enabled: true, configured: true, ...result });
}
