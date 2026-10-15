import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { retryOnConflict } from "@/lib/agents/retry";
import { bridgeV1AnswerLocalRequestSchema, bridgeV1AnswerLocalResponseSchema, type BridgeV1AnswerLocalRequest, type BridgeV1AnswerLocalResponse } from "@/lib/api/contract";
import { bridgeOwnsSession } from "./auth";

// OA F2: 비밀값 질문을 그 세션을 가진 Mac이 "여기서 답했다"고 표시한다. 이 모듈이 answer_agent_question_locally를 부르는 단 하나의 곳이다.
// 값은 오지 않는다: SQL 인자에는 값 자리가 없다 (사용자 · bridge · 작업 id, 요청 id의 SHA-256 16진, 열린 adapter 목록).
// 소유 증명은 두 겹이다. 여기서는 앞단 거름(bridgeOwnsSession: 기기 secret + 세션의 연결이 이 bridge)이고, 권위는 SQL이 쓰기와 같은 트랜잭션에서 다시 확인한다.
// 아무것도 로그로 남기지 않는다 (id · digest · secret 포함). 오류는 던지고 route가 {event} 한 줄만 남긴다.

const sqlResultSchema = z.union([
  bridgeV1AnswerLocalResponseSchema,
  z.strictObject({ status: z.literal("not_found") }),
  z.strictObject({ status: z.literal("invalid") }),
]);
/** busy = 잠금 경합이 3번 시도 뒤에도 그대로 (retry.ts의 CONFLICT_CODES와 같은 코드). 멱등이라 다시 보내도 된다 */
export type AnswerLocalOutcome = BridgeV1AnswerLocalResponse | { status: "not_found" } | { status: "invalid" } | { status: "busy" };
const BUSY_CODES: readonly string[] = ["40001", "40P01", "55P03"];
const isBusy = (error: unknown) => typeof error === "object" && error !== null && "code" in error && typeof error.code === "string" && BUSY_CODES.includes(error.code);

export async function answerSecretLocally(admin: SupabaseClient, input: {
  userId: string; bridgeId: string; deviceSecret: string; input: BridgeV1AnswerLocalRequest; adapters: readonly string[];
}): Promise<AnswerLocalOutcome> {
  const request = bridgeV1AnswerLocalRequestSchema.parse(input.input);
  if (input.adapters.length === 0) return { status: "not_found" };
  const { data: task } = await admin.from("agent_tasks").select("agent_session_id")
    .eq("user_id", input.userId).eq("id", request.agent_task_id).maybeSingle().throwOnError();
  const session = z.guid().safeParse(task?.agent_session_id);
  if (!session.success) return { status: "not_found" };
  if (!(await bridgeOwnsSession(input.userId, input.bridgeId, input.deviceSecret, session.data))) return { status: "not_found" };
  try {
    const { data } = await retryOnConflict(async () => admin.rpc("answer_agent_question_locally", {
      p_user_id: input.userId, p_bridge_id: input.bridgeId, p_agent_task_id: request.agent_task_id,
      p_request_digest: request.request_digest, p_adapters: [...input.adapters],
    }).throwOnError());
    return sqlResultSchema.parse(data);
  } catch (error) {
    if (isBusy(error)) return { status: "busy" };
    throw error;
  }
}
