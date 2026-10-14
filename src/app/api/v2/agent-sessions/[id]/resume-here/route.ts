import { handleResumeHere, realResumeHereDeps } from "@/lib/api/agent-conversations";

// Resume here (OA D1d, 계약 3.8 · AC-36 · ONE-TF-13 서버 몫): { confirmed_terminal_closed: true }(터미널 세션을 닫았다는 사용자 확인)이 있어야 external을 bound로 되돌린다.
// 되돌린 뒤 대기 메시지를 보낸 순서대로 시작한다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleResumeHere(request, id, realResumeHereDeps());
}
