import { authenticateRequest } from "@/lib/api/auth";
import { bridgeV1HeartbeatRequestWithDeviceSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { verifyBridgeDevice } from "@/lib/bridge/auth";
import { heartbeatBridge } from "@/lib/bridge/heartbeat";

export async function POST(request: Request) {
  try {
    const account = await authenticateRequest(request);
    if (!account) return unauthorized();
    const body = await parseBody(request, bridgeV1HeartbeatRequestWithDeviceSchema);
    if ("error" in body) return errorResponse(400, "invalid_request", "Invalid bridge request.");
    const auth = await verifyBridgeDevice(request, body.data.bridge_id, account);
    if ("error" in auth) return auth.error;
    const result = await heartbeatBridge(auth.admin, { userId: auth.user.id, bridge: auth.bridge, input: body.data });
    if ("status" in result && result.status === "not_found") return errorResponse(404, "not_found", "Bridge command or device not found.");
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch {
    console.error(JSON.stringify({ event: "bridge_heartbeat_failed" }));
    return errorResponse(500, "internal_error", "Bridge request failed.");
  }
}
