import { handleStopConversation, realStopConversationDeps } from "@/lib/api/agent-conversations";

// 세션 단위 중단 (OA D1d, 계약 5장 · AC-12): 이 대화에 묶인 세션의 진행 중인 턴과 열린 대화 run을 멈춘다. 본문 없음({}). 세션이 없는 대화는 { tasks: [] } (쓰기 0).
// 응답 { tasks: [{ agent_task_id, cancel: "requested_only" | "confirmed", processes? }] }. gate가 꺼져 있으면 404 (인증 · DB 0).
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleStopConversation(request, id, realStopConversationDeps());
}
