import { handleClaudeAppSessionOpened, realExternalSessionsDeps } from "@/lib/api/external-sessions";

// 사용자가 Claude 데스크톱 세션 보기를 연 날의 지표 claude_app_session_opened (OA PR-D2): 종류만 (본문은 빈 객체), 응답은 204. v1 metric-events는 동결이라 새 지표는 v2다.
export async function POST(request: Request) {
  return handleClaudeAppSessionOpened(request, realExternalSessionsDeps());
}
