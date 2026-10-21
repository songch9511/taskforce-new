import { handleReportExternalSessions, realExternalSessionsDeps } from "@/lib/api/external-sessions";

// 외부 세션 목록 보고 (OA 외부 세션 PR1, 계약 16장): Mac이 Taskforce 밖에서 시작한 Claude Code 세션의 제목 · 상태 · 마지막 활동 시각 · 불투명 id를 스냅샷으로 알린다.
// 대화 본문 · 경로 · 폴더 이름 · Claude 세션 id는 받지 않는다. 이어받기(PR2)는 이 route가 아니다.
export async function PUT(request: Request) {
  return handleReportExternalSessions(request, realExternalSessionsDeps());
}
