import { handleClaudeAppChatStatus, realClaudeAppChatsDeps } from "@/lib/api/claude-app-chats";

// Mac이 글을 보내기 전에 서버 저장이 켜졌는지 묻는다 (OA PR-D3s, 계약 25.3): { save: true, max_batch: 20 }. 꺼짐 · 명단 밖은 404 — 그러면 Mac은 글을 서버로 한 바이트도 보내지 않는다.
export async function GET(request: Request) {
  return handleClaudeAppChatStatus(request, realClaudeAppChatsDeps());
}
