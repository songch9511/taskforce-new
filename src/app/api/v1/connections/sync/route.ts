import { authenticateRequest } from "@/lib/api/auth";
import { syncAllNotion } from "@/lib/connectors/notion/run";
import { createAdminClient } from "@/lib/supabase/admin";

// 지금 동기화: 로그인한 사용자의 연결만 바로 돌린다.
export const maxDuration = 300;

export async function POST(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return Response.json({ error: { code: "unauthorized", message: "로그인이 필요합니다." } }, { status: 401 });

  const outcomes = await syncAllNotion(createAdminClient(), {
    userId: context.user.id,
    deadline: Date.now() + 240_000,
    minIntervalMs: 60_000,
  });
  if (outcomes.length > 0 && outcomes.every((o) => !o.ok && o.busy)) {
    return Response.json({ error: { code: "rate_limited", message: "이미 동기화 중이거나 방금 동기화했습니다." } }, { status: 429 });
  }
  return Response.json({
    connections: outcomes.map((o) =>
      o.ok
        ? { id: o.connectionId, ok: true, created: o.result.created.length, scanned: o.result.scanned, skipped: o.result.skipped }
        : { id: o.connectionId, ok: false, error: o.error },
    ),
  });
}
