import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { syncConnections } from "@/lib/connectors/registry";
import { sweepExpiredOAuth } from "@/lib/connectors/store";
import { createAdminClient } from "@/lib/supabase/admin";

// 주기 동기화 (Vercel Cron 등). Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
export const maxDuration = 300;

export async function GET(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();

  const admin = createAdminClient();
  // 만료된 OAuth nonce · 완료 대기(handoff, 암호화된 code)를 모든 사용자에서 치운다. 실패해도 동기화는 한다.
  const swept = await sweepExpiredOAuth(admin).catch((error) => {
    console.error("만료된 OAuth 기록 정리 실패:", error instanceof Error ? error.message : error);
    return null;
  });
  // 실행 시간 한도보다 조금 일찍 멈추고 남은 연결은 다음 차례로 미룬다. 외부 AI 처리 동의가 없는 사용자의 연결은 건너뛴다.
  const { outcomes, withoutConsent } = await syncConnections(admin, { deadline: Date.now() + (maxDuration - 60) * 1000 });
  return Response.json({
    oauth_swept: swept,
    synced: outcomes.length,
    failed: outcomes.filter((o) => !o.ok).length,
    created: outcomes.reduce((n, o) => n + (o.ok ? o.result.created.length : 0), 0),
    without_consent: withoutConsent,
  });
}
