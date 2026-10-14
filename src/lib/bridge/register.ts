import { createHash, randomBytes } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { bridgeV1AdapterReportSchema, bridgeV1RegisterRequestSchema, bridgeV1RegisterResponseSchema, bridgeV1RevokeResponseSchema, type BridgeV1RegisterRequest } from "@/lib/api/contract";
import { takeBridgeRegistrationLimit } from "@/lib/api/rate-limit";
import { BRIDGE_HEARTBEAT_SECONDS, BRIDGE_LONG_POLL_MAX_SECONDS, BRIDGE_UNREACHABLE_AFTER_SECONDS } from "@/lib/execution/limits";
import { kickBridgeConnections } from "./triggers";

export function normalizeBridgeReport(adapters: z.infer<typeof bridgeV1AdapterReportSchema>[]) {
  return { reported_at: new Date().toISOString(), adapters: Object.fromEntries(adapters.map(({ adapter, ...report }) => [adapter, report])) };
}
export async function registerBridge(admin: SupabaseClient, userId: string, input: BridgeV1RegisterRequest) {
  const body = bridgeV1RegisterRequestSchema.parse(input);
  await takeBridgeRegistrationLimit(admin, userId);
  const secret = randomBytes(32).toString("base64url");
  const { data } = await admin.rpc("register_bridge", {
    p_user_id: userId, p_device_ref: createHash("sha256").update(`${userId}:${body.device_id}`).digest("hex"),
    p_secret_hash: createHash("sha256").update(secret).digest("hex"), p_app_version: body.app_version,
    p_report: normalizeBridgeReport(body.adapters), p_connect: body.connect, p_reactivate: body.reactivate,
  }).throwOnError();
  if (data?.status === "revoked") return { status: "revoked" as const };
  if (data?.status === "too_many_bridges") return { status: "too_many_bridges" as const };
  const result = z.object({ status: z.enum(["registered", "rotated", "reactivated"]), bridge_id: z.guid(), connections: z.array(z.object({ connection_id: z.guid(), adapter: bridgeV1AdapterReportSchema.shape.adapter, status: z.enum(["active", "error", "revoked"]), activated: z.boolean() })) }).parse(data);
  await kickBridgeConnections(admin, userId, result.connections.filter((connection) => connection.activated).map((connection) => connection.connection_id));
  return bridgeV1RegisterResponseSchema.parse({ bridge_id: result.bridge_id, bridge_secret: secret,
    heartbeat_interval_seconds: BRIDGE_HEARTBEAT_SECONDS, unreachable_after_seconds: BRIDGE_UNREACHABLE_AFTER_SECONDS, long_poll_max_seconds: BRIDGE_LONG_POLL_MAX_SECONDS,
    connections: result.connections.map(({ connection_id, adapter, status }) => ({ connection_id, adapter, status })),
  });
}
export async function revokeBridge(admin: SupabaseClient, userId: string, bridgeId: string) {
  for (let attempt = 1; ; attempt++) {
    try {
      const { data } = await admin.rpc("revoke_bridge", { p_user_id: userId, p_bridge_id: bridgeId }).throwOnError();
      if (data?.status === "not_found") return { status: "not_found" as const };
      return bridgeV1RevokeResponseSchema.parse(data);
    } catch (error) {
      if (attempt >= 3 || typeof error !== "object" || error === null || !("code" in error) || error.code !== "55P03") throw error;
    }
  }
}
