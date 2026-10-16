import { authenticateRequest } from "@/lib/api/auth";
import { handleConfirmProposal } from "@/lib/api/conversations";
import { confirmProposal, loadMessage } from "@/lib/conversation/store";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 삭제 · 병합 확인 카드의 Delete · Merge 버튼 (OA D4c-2): 카드(제안)를 읽고 쓰기 계획을 세워 한 트랜잭션으로 쓴다. 두 번 눌러도 한 번, 대상이 카드 뒤에 바뀌었으면 409 superseded(쓰기 0).
// gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404. 인증은 Bearer · 쿠키(쿠키 쓰기는 CSRF 확인). AI를 부르지 않는다 (동의 검사 · 한도 없음).
export async function POST(request: Request, { params }: { params: Promise<{ id: string; proposal_id: string }> }) {
  const { id, proposal_id: proposalId } = await params;
  return handleConfirmProposal(request, id, proposalId, {
    enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED"),
    authenticate: authenticateRequest,
    confirm: ({ user }, conversationId, proposal) => confirmProposal(createAdminClient(), user.id, conversationId, proposal),
    dismiss: async () => "not_found",
    loadMessage: ({ user }, messageId) => loadMessage(createAdminClient(), user.id, messageId),
  });
}
