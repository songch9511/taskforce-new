import { handleAnswerQuestion, realAnswerDeps } from "@/lib/api/agent-conversations";

// 에이전트 질문에 답하기 (OA D1d, 계약 3.6 · OD-14): { provider_request_id, answers }. input 질문만 — 승인은 409 approval_via_review, 비밀값은 409 secret_requires_local.
// 열쇠가 다르면 409 question_stale. 같은 답을 다시 보내면 duplicate(같은 step).
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleAnswerQuestion(request, id, realAnswerDeps());
}
