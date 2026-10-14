import "server-only";
import { createHash, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import { authenticateRequest, type ApiContext } from "@/lib/api/auth";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { createAdminClient } from "@/lib/supabase/admin";

export const bridgeRecordSchema = z.object({ id: z.guid(), status: z.enum(["active", "revoked"]), secret_hash: z.string().nullable(), capabilities: z.unknown() });
export type BridgeRecord = z.infer<typeof bridgeRecordSchema>;
export function verifyBridgeSecret(secret: string | null, hash: string | null): boolean {
  if (!secret || !/^[A-Za-z0-9_-]{43}$/.test(secret) || !hash || !/^[0-9a-f]{64}$/.test(hash)) return false;
  return timingSafeEqual(createHash("sha256").update(secret).digest(), Buffer.from(hash, "hex"));
}
export async function authenticateBridge(request: Request, bridgeId: string): Promise<
  { error: Response } | { user: NonNullable<Awaited<ReturnType<typeof authenticateRequest>>>["user"]; admin: ReturnType<typeof createAdminClient>; bridge: BridgeRecord }
> {
  const auth = await authenticateRequest(request);
  if (!auth) return { error: unauthorized() };
  return verifyBridgeDevice(request, bridgeId, auth);
}
export async function verifyBridgeDevice(request: Request, bridgeId: string, auth: ApiContext): ReturnType<typeof authenticateBridge> {
  const admin = createAdminClient();
  const { data } = await admin.from("bridges").select("id,status,secret_hash,capabilities")
    .eq("user_id", auth.user.id).eq("id", bridgeId).maybeSingle().throwOnError();
  if (!data) return { error: errorResponse(404, "not_found", "Bridge not found.") };
  const bridge = bridgeRecordSchema.parse(data);
  if (bridge.status === "revoked") return { error: errorResponse(403, "unauthorized", "Bridge revoked.") };
  if (!verifyBridgeSecret(request.headers.get("X-Taskforce-Bridge-Secret"), bridge.secret_hash)) return { error: unauthorized() };
  return { user: auth.user, admin, bridge };
}
export async function bridgeOwnsSession(userId: string, bridgeId: string, deviceSecret: string, sessionId: string): Promise<boolean> {
  if (![userId, bridgeId, sessionId].every((id) => z.guid().safeParse(id).success)) return false;
  const admin = createAdminClient();
  const { data } = await admin.from("bridges").select("id,status,secret_hash,capabilities")
    .eq("user_id", userId).eq("id", bridgeId).maybeSingle().throwOnError();
  if (!data) return false;
  const bridge = bridgeRecordSchema.parse(data);
  if (bridge.status !== "active" || !verifyBridgeSecret(deviceSecret, bridge.secret_hash)) return false;
  const { data: session } = await admin.from("agent_sessions").select("connection_id,status")
    .eq("user_id", userId).eq("id", sessionId).maybeSingle().throwOnError();
  if (!session || session.status === "closed" || session.status === "external") return false;
  const { data: connection } = await admin.from("agent_connections").select("bridge_id")
    .eq("user_id", userId).eq("id", z.guid().parse(session.connection_id)).maybeSingle().throwOnError();
  return connection?.bridge_id === bridgeId;
}
