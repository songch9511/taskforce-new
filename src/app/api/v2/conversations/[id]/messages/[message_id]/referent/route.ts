import { handleSetReferent, realReferentDeps } from "@/lib/api/agent-conversations";

// 지시 대상 고르기 (OA D1d, 계약 2.4 · AC-4): added 이슈 칩이 둘 이상이라 needs_referent인 메시지에 후보 하나를 정한다 { action_id }. 같은 메시지를 그대로 한 번 전달한다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string; message_id: string }> }) {
  const { id, message_id: messageId } = await params;
  return handleSetReferent(request, id, messageId, realReferentDeps());
}
