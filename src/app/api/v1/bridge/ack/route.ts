import { RateLimitedError, retryAfterSeconds, takeBridgeRequestLimit } from "@/lib/api/rate-limit";
import { authenticateRequest } from "@/lib/api/auth";
import { bridgeV1AckRequestSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { verifyBridgeDevice } from "@/lib/bridge/auth";
import { ackBridgeCommand } from "@/lib/bridge/commands";

export async function POST(request: Request) {
  try {
    const account = await authenticateRequest(request);
    if (!account) return unauthorized();
    const body = await parseBody(request, bridgeV1AckRequestSchema);
    if ("error" in body) return errorResponse(400, "invalid_request", "Invalid bridge request.");
    const auth = await verifyBridgeDevice(request, body.data.bridge_id, account);
    if ("error" in auth) return auth.error;
    await takeBridgeRequestLimit(auth.admin, auth.user.id, auth.bridge.id, "bridge_ack");
    const result = await ackBridgeCommand(auth.admin, { userId: auth.user.id, bridge: auth.bridge, input: body.data });
    if ("status" in result && result.status === "not_found") return errorResponse(404, "not_found", "Bridge command or device not found.");
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "Please try again later.");
      response.headers.set("Retry-After", String(retryAfterSeconds(error.retryAt, new Date())));
      return response;
    }
    console.error(JSON.stringify({ event: "bridge_ack_failed" }));
    return errorResponse(500, "internal_error", "Bridge request failed.");
  }
}
