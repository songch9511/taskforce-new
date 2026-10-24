import { PROJECT_SESSIONS_OPENED, handleAgentTreeDayMetric, realAgentTreeMetricsDeps } from "@/lib/api/agent-tree-metrics";

// 프로젝트 이슈 목록의 Sessions 묶음이 행 1개 이상으로 펼쳐 보인 날의 지표 project_sessions_opened (T3s): 종류만 (본문은 빈 객체), 응답은 204, 사용자별 UTC 날짜마다 한 번. v1 metric-events는 동결이라 새 지표는 v2다.
export async function POST(request: Request) {
  return handleAgentTreeDayMetric(request, PROJECT_SESSIONS_OPENED, realAgentTreeMetricsDeps());
}
