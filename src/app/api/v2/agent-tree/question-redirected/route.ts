import { SUBAGENT_QUESTION_REDIRECTED, handleAgentTreeTurnMetric, realAgentTreeMetricsDeps } from "@/lib/api/agent-tree-metrics";

// 자식의 질문 · 승인 대기가 거절돼 부모에게 돌아간 일의 지표 subagent_question_redirected (T3s): 본문은 { agent_task_id } 하나, 이 사용자의 Claude Code 턴이 아니면 404, 응답은 204, 턴마다 한 번.
export async function POST(request: Request) {
  return handleAgentTreeTurnMetric(request, SUBAGENT_QUESTION_REDIRECTED, realAgentTreeMetricsDeps());
}
