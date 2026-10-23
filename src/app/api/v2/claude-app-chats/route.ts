import { handleDeleteAllClaudeAppChats, handleSaveClaudeAppChat, realClaudeAppChatsDeps } from "@/lib/api/claude-app-chats";

// Claude 데스크톱 세션과 나눈 대화 저장 (OA PR-D3s, 계약 25 · 26장): Mac이 Claude 데스크톱 세션으로 보낸 글("Received"로 확인된 것)과 그 뒤 답 글(도구 단계 이름만)을 한 교환 단위로 올린다 (멱등, ≤20행).
// CLAUDE_APP_CHATS_ENABLED(기본 꺼짐) · 대화 v2 · adapter 플래그 · 베타 명단이 모두 맞을 때만 열린다. 서버가 시작하는 보내기 길은 없다. 인증 Bearer · 쿠키(CSRF).
export async function PUT(request: Request) {
  return handleSaveClaudeAppChat(request, realClaudeAppChatsDeps());
}

// 사용자가 저장된 Claude 데스크톱 대화를 **모두** 지운다 (OA D3v-s, 계약 27장): 200 { deleted: 지운 채팅 수 }. 한 SQL 함수가 한 트랜잭션으로 지운다(일부만 지워진 상태 없음, 묘비로 재시도가 되살리지 못함).
// **늘 열려 있다**: PUT과 달리 CLAUDE_APP_CHATS_ENABLED · 대화 v2 · adapter 플래그도 베타 명단도 보지 않는다 (대화마다 지우는 DELETE와 같다). 로그인(Bearer · 쿠키 + CSRF)은 필요하고 자기 행만 지운다. 속도 제한 10분에 5번.
export async function DELETE(request: Request) {
  return handleDeleteAllClaudeAppChats(request, realClaudeAppChatsDeps());
}
