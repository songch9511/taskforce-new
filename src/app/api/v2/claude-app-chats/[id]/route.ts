import { handleDeleteClaudeAppChat, realClaudeAppChatsDeps } from "@/lib/api/claude-app-chats";

// 사용자가 저장된 Claude 데스크톱 대화를 지운다 (OA PR-D3s, 계약 25.3 · 26장): 채팅과 모든 행을 지운다. 남의 · 없는 id는 404. 보관은 이 삭제나 계정 삭제로만 끝난다 (자동 삭제 없음).
// **늘 열려 있다**: CLAUDE_APP_CHATS_ENABLED · 대화 v2 · adapter 플래그도 베타 명단도 보지 않는다 (BYOK 키 DELETE와 같다). 로그인(Bearer · 쿠키 + CSRF)은 필요하고 자기 행만 지운다.
export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleDeleteClaudeAppChat(request, id, realClaudeAppChatsDeps());
}
