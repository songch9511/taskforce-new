import { handleClaudeAppSent, realClaudeAppChatsDeps } from "@/lib/api/claude-app-chats";

// 보내기 결과 지표 claude_app_message_sent (OA PR-D3s): 코드만 받고(글 0) 저장 플래그와 무관하게 열린다. 저장이 켜져 있으면 received는 저장 함수가 남기므로 여기서는 남기지 않는다. 응답은 204.
// v1 metric-events는 동결이라 새 지표는 v2다.
export async function POST(request: Request) {
  return handleClaudeAppSent(request, realClaudeAppChatsDeps());
}
