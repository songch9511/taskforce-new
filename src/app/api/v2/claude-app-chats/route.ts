import { handleSaveClaudeAppChat, realClaudeAppChatsDeps } from "@/lib/api/claude-app-chats";

// Claude 데스크톱 세션과 나눈 대화 저장 (OA PR-D3s, 계약 25 · 26장): Mac이 Claude 데스크톱 세션으로 보낸 글("Received"로 확인된 것)과 그 뒤 답 글(도구 단계 이름만)을 한 교환 단위로 올린다 (멱등, ≤20행).
// CLAUDE_APP_CHATS_ENABLED(기본 꺼짐) · 대화 v2 · adapter 플래그 · 베타 명단이 모두 맞을 때만 열린다. 서버가 시작하는 보내기 길은 없다. 인증 Bearer · 쿠키(CSRF).
export async function PUT(request: Request) {
  return handleSaveClaudeAppChat(request, realClaudeAppChatsDeps());
}
