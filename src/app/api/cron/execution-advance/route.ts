import { after } from "next/server";
import { z } from "zod";

import { cronAuthorized, cronUnauthorized } from "@/lib/api/cron";
import { errorResponse, parseBody } from "@/lib/api/respond";
import { EXECUTION_UNAVAILABLE_MESSAGE } from "@/lib/api/runs";
import { executionEnabled } from "@/lib/env";
import { advanceAndWake } from "@/lib/execution/wake";

// 실행기 자기 호출 (EXECUTION 2장 K2): run의 다음 단계 하나를 새 함수 호출에서 돈다. 단계를 끝낸 함수 · sweep이 부른다.
// Authorization: Bearer $CRON_SECRET 인 요청만 받는다. 바로 202로 답하고(부른 쪽은 기다리지 않는다) 단계는 after()에서 돈다.
// 같은 run을 두 번 깨워도 단계는 한 번이다 (prepare_step · begin_call의 CAS). 부르기 전 판단은 begin_call이 한다 (스위치를 꺼도 calling 0).
// 실행 한도 = lease(330초) - 여유 30초 (limits.ts EXECUTION_MAX_DURATION_S, route.test.ts가 같은지 본다).
export const maxDuration = 300;

const advanceRequestSchema = z.object({ run_id: z.uuid() });

export async function POST(request: Request) {
  if (!cronAuthorized(request)) return cronUnauthorized();
  if (!executionEnabled()) return errorResponse(404, "not_found", EXECUTION_UNAVAILABLE_MESSAGE);
  const body = await parseBody(request, advanceRequestSchema);
  if ("error" in body) return body.error;
  after(() => advanceAndWake(body.data.run_id));
  return Response.json({ accepted: true }, { status: 202 });
}
