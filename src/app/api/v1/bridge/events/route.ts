import { stopPathConflictRuns } from "@/lib/agents/path-leases";
import { RateLimitedError, retryAfterSeconds, takeBridgeRequestLimit } from "@/lib/api/rate-limit";
import { authenticateRequest } from "@/lib/api/auth";
import { bridgeV1EventsRequestSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { verifyBridgeDevice } from "@/lib/bridge/auth";
import { applyBridgeEvents } from "@/lib/bridge/events";
import { BRIDGE_EVENTS_MAX_BYTES } from "@/lib/execution/limits";

export async function POST(request: Request) {
  try {
    const account = await authenticateRequest(request);
    if (!account) return unauthorized();
    const reader = request.body?.getReader();
    if (!reader) return errorResponse(400, "invalid_request", "An event batch is required.");
    const chunks: Uint8Array[] = [];
    let size = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > BRIDGE_EVENTS_MAX_BYTES) {
          await reader.cancel();
          return errorResponse(400, "invalid_request", "Event batch is too large.");
        }
        chunks.push(value);
      }
    } finally {
      reader.releaseLock();
    }
    const body = await parseBody(new Request(request.url, { method: "POST", body: Buffer.concat(chunks).toString("utf8") }), bridgeV1EventsRequestSchema);
    if ("error" in body) return errorResponse(400, "invalid_request", "Invalid event batch.");
    const auth = await verifyBridgeDevice(request, body.data.bridge_id, account);
    if ("error" in auth) return auth.error;
    await takeBridgeRequestLimit(auth.admin, auth.user.id, auth.bridge.id, "bridge_events");
    const result = await applyBridgeEvents(auth.admin, { userId: auth.user.id, bridgeId: auth.bridge.id, events: body.data.events });
    await stopPathConflictRuns(auth.admin, { userId: auth.user.id, bridgeId: auth.bridge.id }).then(({ errors }) => { if (errors) console.error(JSON.stringify({ event: "path_conflict_stop_failed" })); }).catch(() => console.error(JSON.stringify({ event: "path_conflict_stop_failed" })));
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "Please try again later.");
      response.headers.set("Retry-After", String(retryAfterSeconds(error.retryAt, new Date())));
      return response;
    }
    console.error(JSON.stringify({ event: "bridge_events_failed" }));
    return errorResponse(500, "internal_error", "Bridge events could not be applied.");
  }
}
