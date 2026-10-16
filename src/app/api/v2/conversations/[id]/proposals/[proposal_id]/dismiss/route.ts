import { authenticateRequest } from "@/lib/api/auth";
import { handleDismissProposal } from "@/lib/api/conversations";
import { dismissProposal, loadMessage } from "@/lib/conversation/store";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 삭제 · 병합 확인 카드의 Cancel 버튼 (OA D4c-2): 열린 카드만 dismissed로 (쓰기 0). gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404.
export async function POST(request: Request, { params }: { params: Promise<{ id: string; proposal_id: string }> }) {
  const { id, proposal_id: proposalId } = await params;
  return handleDismissProposal(request, id, proposalId, {
    enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED"),
    authenticate: authenticateRequest,
    confirm: async () => ({ status: "not_found" }),
    dismiss: ({ user }, conversationId, proposal) => dismissProposal(createAdminClient(), user.id, conversationId, proposal),
    loadMessage: ({ user }, messageId) => loadMessage(createAdminClient(), user.id, messageId),
  });
}
