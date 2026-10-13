import { handleListTargets, realTargetsDeps } from "@/lib/api/agent-conversations";

// 대상 목록 (OA D1d, 계약 4.5): taskforce + 연결한 에이전트(상태 · 등급). 읽기만 하고 이벤트를 쓰지 않는다 (CSRF 대상 아님).
export async function GET(request: Request) {
  return handleListTargets(request, realTargetsDeps());
}
