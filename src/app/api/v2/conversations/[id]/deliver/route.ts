import { handleDeliverAgentMessages, realDeliverDeps } from "@/lib/api/agent-conversations";

// Send again (OA D1d, 계약 2.3): 보내지 못한(not_sent) · 만료된(expired) 에이전트 메시지를 다시 보낸다. { message_ids?: uuid[] } — 없으면 그 대화의 대상 상태 전부.
// gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404 (인증 · DB를 부르지 않는다). 규칙은 requeue_agent_messages(SQL)와 src/lib/agents/messages.ts. 두 번 눌러도 새 전달은 한 번이다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleDeliverAgentMessages(request, id, realDeliverDeps());
}
