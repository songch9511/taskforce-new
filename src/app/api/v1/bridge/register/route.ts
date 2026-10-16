import { authenticateRequest } from "@/lib/api/auth";
import { bridgeV1RegisterRequestWithDeviceSchema, bridgeV1RevokeRequestSchema } from "@/lib/api/contract";
import { RateLimitedError, retryAfterSeconds } from "@/lib/api/rate-limit";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { registerBridge, revokeBridge } from "@/lib/bridge/register";
import { createAdminClient } from "@/lib/supabase/admin";

export async function POST(request: Request) {
  try {
    const auth = await authenticateRequest(request);
    if (!auth) return unauthorized();
    const body = await parseBody(request, bridgeV1RegisterRequestWithDeviceSchema);
    if ("error" in body) return body.error;
    const result = await registerBridge(createAdminClient(), auth.user.id, body.data);
    if ("status" in result) return result.status === "too_many_bridges"
      ? errorResponse(409, "conflict", "too_many_bridges")
      : errorResponse(403, "unauthorized", "Explicit reactivation is required.");
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    if (error instanceof RateLimitedError) {
      const response = errorResponse(429, "rate_limited", "Please try again later.");
      response.headers.set("Retry-After", String(retryAfterSeconds(error.retryAt, new Date())));
      return response;
    }
    console.error(JSON.stringify({ event: "bridge_register_failed" }));
    return errorResponse(500, "internal_error", "Bridge registration failed.");
  }
}

export async function DELETE(request: Request) {
  try {
    const auth = await authenticateRequest(request);
    if (!auth) return unauthorized();
    const body = await parseBody(request, bridgeV1RevokeRequestSchema);
    if ("error" in body) return body.error;
    const result = await revokeBridge(createAdminClient(), auth.user.id, body.data.bridge_id);
    if (result.status === "not_found") return errorResponse(404, "not_found", "Bridge not found.");
    return Response.json(result);
  } catch {
    console.error(JSON.stringify({ event: "bridge_revoke_failed" }));
    return errorResponse(500, "internal_error", "Bridge revocation failed.");
  }
}
