import { openAgentAdapters } from "@/lib/agents/registry";
import { authenticateRequest } from "@/lib/api/auth";
import { BRIDGE_ANSWER_LOCAL_MAX_BYTES, bridgeV1AnswerLocalRequestSchema } from "@/lib/api/contract";
import { RateLimitedError, retryAfterSeconds, takeBridgeRequestLimit } from "@/lib/api/rate-limit";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { answerSecretLocally } from "@/lib/bridge/answer-local";
import { verifyBridgeDevice } from "@/lib/bridge/auth";

// 비밀값 질문의 로컬 답 표시 (OA F2). 값은 이 route로 오지 않는다 — 본문은 UUID 둘 + 고정 길이 소문자 16진 하나뿐인 닫힌 모양이고 512바이트를 넘으면 읽기를 끊는다.
// 순서: gate(대화 v2 ∧ 켜진 adapter, 닫히면 404 · 인증 · DB 0) → 인증 → 본문 → 기기 → 한도 → 일. 쿼리 문자열 · 경로 인자는 읽지 않는다.
// 400은 고정 문구다 (parseBody는 틀린 필드 이름을 되돌려주므로 쓰지 않는다). 로그는 {event} 한 줄뿐이다.
export const maxDuration = 15;
const invalidRequest = () => errorResponse(400, "invalid_request", "Invalid local answer request.");

async function readLimitedJson(request: Request): Promise<unknown> {
  const reader = request.body?.getReader();
  if (!reader) return undefined;
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > BRIDGE_ANSWER_LOCAL_MAX_BYTES) {
        await reader.cancel();
        return undefined;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    return undefined;
  }
}

export async function POST(request: Request) {
  const adapters = openAgentAdapters();
  if (adapters.length === 0) return errorResponse(404, "not_found", "Not found.");
  try {
    const account = await authenticateRequest(request);
    if (!account) return unauthorized();
    const body = bridgeV1AnswerLocalRequestSchema.safeParse(await readLimitedJson(request));
    if (!body.success) return invalidRequest();
    const auth = await verifyBridgeDevice(request, body.data.bridge_id, account);
    if ("error" in auth) return auth.error;
    await takeBridgeRequestLimit(auth.admin, auth.user.id, auth.bridge.id, "bridge_ack");
    const result = await answerSecretLocally(auth.admin, {
      userId: auth.user.id, bridgeId: auth.bridge.id, deviceSecret: request.headers.get("X-Taskforce-Bridge-Secret") ?? "", input: body.data, adapters,
    });
    if (result.status === "not_found") return errorResponse(404, "not_found", "Local answer target not found.");
    if (result.status === "invalid") return invalidRequest();
    if (result.status === "busy") return errorResponse(409, "conflict", "Busy, retry.");
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "Please try again later.");
      response.headers.set("Retry-After", String(retryAfterSeconds(error.retryAt, new Date())));
      return response;
    }
    console.error(JSON.stringify({ event: "bridge_answer_local_failed" }));
    return errorResponse(500, "internal_error", "Bridge request failed.");
  }
}
