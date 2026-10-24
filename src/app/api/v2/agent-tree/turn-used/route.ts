import { SUBAGENT_TURN_USED, handleAgentTreeTurnMetric, realAgentTreeMetricsDeps } from "@/lib/api/agent-tree-metrics";

// Taskforce가 띄운 Claude 턴이 하위 에이전트를 하나 이상 쓴 일의 지표 subagent_turn_used (T3s): 본문은 { agent_task_id } 하나, 이 사용자의 Claude Code 턴이 아니면 404, 응답은 204, 턴마다 한 번.
export async function POST(request: Request) {
  return handleAgentTreeTurnMetric(request, SUBAGENT_TURN_USED, realAgentTreeMetricsDeps());
}
