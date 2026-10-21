import { handleAttachSession, realAttachDeps } from "@/lib/api/agent-conversations";

// 외부 세션 이어받기 (OA 외부 세션 PR2s, 계약 7장 ES-16 · ES-17): Taskforce 밖에서 시작한 Claude Code 세션의 UUID와 가상 루트(/taskforce/ws_<uuid>)만 받아
// 이 Mac의 세션 + 대화로 묶는다. 실제 경로 · 대화 글 · 제목은 받지 않는다. AGENT_ATTACH_EXISTING_ENABLED(기본 꺼짐)가 켜져 있고
// 대화 v2 · adapter 플래그 · 베타 명단 · registry의 session.attach_existing이 모두 맞을 때만 열린다. 인증 Bearer · 쿠키(CSRF).
export async function POST(request: Request) {
  return handleAttachSession(request, realAttachDeps());
}
