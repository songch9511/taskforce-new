import { SUBAGENT_ROW_OPENED, handleAgentTreeDayMetric, realAgentTreeMetricsDeps } from "@/lib/api/agent-tree-metrics";

// 하위 에이전트 줄을 눌러 꼬리 보기를 연 날의 지표 subagent_row_opened (T3s): 종류만 (본문은 빈 객체), 응답은 204, 사용자별 UTC 날짜마다 한 번. v1 metric-events는 동결이라 새 지표는 v2다.
export async function POST(request: Request) {
  return handleAgentTreeDayMetric(request, SUBAGENT_ROW_OPENED, realAgentTreeMetricsDeps());
}
