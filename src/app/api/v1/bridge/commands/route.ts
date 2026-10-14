import { RateLimitedError, retryAfterSeconds, takeBridgeRequestLimit } from "@/lib/api/rate-limit";
import { authenticateRequest } from "@/lib/api/auth";
import { bridgeV1CommandsQuerySchema } from "@/lib/api/contract";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { verifyBridgeDevice } from "@/lib/bridge/auth";
import { pollBridgeCommands } from "@/lib/bridge/commands";

export const maxDuration = 30;

export async function GET(request: Request) {
  try {
    const account = await authenticateRequest(request);
    if (!account) return unauthorized();
    const query = bridgeV1CommandsQuerySchema.safeParse(Object.fromEntries(new URL(request.url).searchParams));
    if (!query.success) return errorResponse(400, "invalid_request", "Invalid bridge query.");
    const auth = await verifyBridgeDevice(request, query.data.bridge_id, account);
    if ("error" in auth) return auth.error;
    await takeBridgeRequestLimit(auth.admin, auth.user.id, auth.bridge.id, "bridge_poll");
    const result = await pollBridgeCommands(auth.admin, { userId: auth.user.id, bridgeId: auth.bridge.id, after: query.data.after, wait: query.data.wait, signal: request.signal });
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "Please try again later.");
      response.headers.set("Retry-After", String(retryAfterSeconds(error.retryAt, new Date())));
      return response;
    }
    console.error(JSON.stringify({ event: "bridge_commands_failed" }));
    return errorResponse(500, "internal_error", "Bridge commands could not be read.");
  }
}
