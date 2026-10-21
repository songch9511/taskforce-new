import { handleExternalSessionsShown, realExternalSessionsDeps } from "@/lib/api/external-sessions";

// 레일 외부 세션 목록이 보인 날의 지표 external_sessions_shown (OA 외부 세션 PR1): 구간 값만 받고 응답은 204. v1 metric-events는 동결이라 새 지표는 v2다.
export async function POST(request: Request) {
  return handleExternalSessionsShown(request, realExternalSessionsDeps());
}
