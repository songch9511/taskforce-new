import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { bridgeV1HeartbeatRequestSchema, bridgeV1HeartbeatResponseSchema, type BridgeV1HeartbeatRequest } from "@/lib/api/contract";
import { BRIDGE_HEARTBEAT_SECONDS, BRIDGE_KICK_LIMIT } from "@/lib/execution/limits";
import type { BridgeRecord } from "./auth";
import { normalizeBridgeReport } from "./register";
import { drainBridgeSessionEvents } from "./events";
import { kickBridgeConnections, kickBridgeSessions } from "./triggers";
export async function heartbeatBridge(admin: SupabaseClient, input: { userId: string; bridge: BridgeRecord; input: BridgeV1HeartbeatRequest }) {
  const body = bridgeV1HeartbeatRequestSchema.parse(input.input);
  const { data } = await admin.rpc("bridge_heartbeat", { p_user_id: input.userId, p_bridge_id: input.bridge.id, p_tasks: body.tasks,
    p_report: body.adapters ? normalizeBridgeReport(body.adapters) : null, p_app_version: body.app_version ?? null,
  }).throwOnError();
  if (data?.status === "not_found") return { status: "not_found" as const };
  if (data?.throttled === true) return bridgeV1HeartbeatResponseSchema.parse({ heartbeat_interval_seconds: BRIDGE_HEARTBEAT_SECONDS, server_time: new Date().toISOString(), pending_commands: data.pending_commands, unknown_task_ids: data.unknown_task_ids, missing_task_ids: data.missing_task_ids, throttled: true });
  const result = z.object({ revived_session_ids: z.array(z.guid()), kick_session_ids: z.array(z.guid()), activated_connection_ids: z.array(z.guid()),
    pending_commands: z.number().int().nonnegative(), unknown_task_ids: z.array(z.guid()), missing_task_ids: z.array(z.guid()) }).parse(data);
  try { await drainBridgeSessionEvents(admin, { userId: input.userId, bridgeId: input.bridge.id }); }
  catch { /* Pending descriptors are retried by heartbeat and sweep. */ }
  await kickBridgeSessions(admin, input.userId, result.kick_session_ids);
  try {
    // Include already-active connections so a failed unbound-message kick is retried.
    const { data: connections } = await admin.from("agent_connections").select("id")
      .eq("user_id", input.userId).eq("bridge_id", input.bridge.id).eq("status", "active").limit(BRIDGE_KICK_LIMIT).throwOnError();
    await kickBridgeConnections(admin, input.userId, z.array(z.object({ id: z.guid() })).parse(connections).map((connection) => connection.id), process.env, result.kick_session_ids);
  } catch { /* The next heartbeat retries the durable queue. */ }
  return bridgeV1HeartbeatResponseSchema.parse({ heartbeat_interval_seconds: BRIDGE_HEARTBEAT_SECONDS, server_time: new Date().toISOString(), pending_commands: result.pending_commands, unknown_task_ids: result.unknown_task_ids, missing_task_ids: result.missing_task_ids });
}
