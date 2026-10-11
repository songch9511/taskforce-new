import { after } from "next/server";

import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { errorResponse } from "@/lib/api/respond";
import { advanceCoordinator } from "@/lib/coordinator/wake";
import { flagEnabled } from "@/lib/flags";

// 코디네이터 자기 호출 (아키텍처 7.1): 기한 창 timer 적재 · (30분마다) 적재 회수 · 쌓인 사건 처리를 새 함수 호출에서 한 번 돈다.
// 1분 execution-sweep(vercel.json 그대로)과 사건을 처리한 함수가 부른다. Authorization: Bearer $CRON_SECRET 인 요청만 받는다.
// 바로 202로 답하고(부른 쪽은 기다리지 않는다) 처리는 after()에서 돈다. 같은 사건을 두 번 깨워도 처리는 한 번이다 (DB 집기).
// COORDINATOR_ENABLED가 꺼져 있으면 404: 집기 · 처리 · 모델 0 (적재만 계속된다).
// 실행 한도 = lease(90초) − 여유 30초 (coordinator.config.ts COORDINATOR_MAX_DURATION_S, route.test.ts가 같은지 본다).
export const maxDuration = 60;

export async function POST(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();
  if (!flagEnabled("COORDINATOR_ENABLED")) return errorResponse(404, "not_found", "코디네이터가 켜져 있지 않습니다.");
  after(() => advanceCoordinator());
  return Response.json({ accepted: true }, { status: 202 });
}
