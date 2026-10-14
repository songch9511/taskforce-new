import { TOOL_DECISION_NOTES } from "@/lib/agents/tool-decision";
import { authenticateRequest } from "@/lib/api/auth";
import { bridgeV1ToolDecisionRequestSchema } from "@/lib/api/contract";
import { takeBridgeDecisionPreflightLimit } from "@/lib/api/rate-limit";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { verifyBridgeDevice } from "@/lib/bridge/auth";
import { decideBridgeToolCall } from "@/lib/bridge/tool-decision";
import { TOOL_DECISION_MAX_BYTES } from "@/lib/execution/limits";

export const maxDuration = 5;
export async function POST(request: Request) {
  const startedAt = performance.now();
  try {
    const account = await authenticateRequest(request);
    if (!account) return unauthorized();
    const reader = request.body?.getReader();
    if (!reader) return errorResponse(400, "invalid_request", "A tool request is required.");
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > TOOL_DECISION_MAX_BYTES) {
          await reader.cancel();
          return errorResponse(400, "invalid_request", "Tool request is too large.");
        }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    const body = await parseBody(new Request(request.url, { method: "POST", body: Buffer.concat(chunks).toString("utf8") }), bridgeV1ToolDecisionRequestSchema);
    if ("error" in body) return errorResponse(400, "invalid_request", "Invalid tool request.");
    const auth = await verifyBridgeDevice(request, body.data.bridge_id, account);
    if ("error" in auth) return auth.error;
    if (takeBridgeDecisionPreflightLimit(auth.user.id, auth.bridge.id)) return Response.json({
      decision: "deny", reason: "rate_limited", agent_note: TOOL_DECISION_NOTES.rate_limited, card_flags: [], server_time: new Date().toISOString(),
    }, { headers: { "Cache-Control": "no-store" } });
    const result = await decideBridgeToolCall(auth.admin, { userId: auth.user.id, bridge: auth.bridge, input: body.data, startedAt });
    if ("status" in result) return errorResponse(404, "not_found", "Tool task not found.");
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch {
    console.error(JSON.stringify({ event: "bridge_tool_decision_failed" }));
    return errorResponse(500, "internal_error", "Tool request failed.");
  }
}
