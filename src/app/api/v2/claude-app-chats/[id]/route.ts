import { handleDeleteClaudeAppChat, realClaudeAppChatsDeps } from "@/lib/api/claude-app-chats";

// 사용자가 저장된 Claude 데스크톱 대화를 지운다 (OA PR-D3s, 계약 25.3 · 26장): 채팅과 모든 행을 지운다. 남의 · 없는 id는 404. 보관은 이 삭제나 계정 삭제로만 끝난다 (자동 삭제 없음).
export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleDeleteClaudeAppChat(request, id, realClaudeAppChatsDeps());
}
