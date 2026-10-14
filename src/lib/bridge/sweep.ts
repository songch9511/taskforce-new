import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { BRIDGE_REDELIVERY_LIMIT } from "@/lib/execution/limits";
import { drainBridgeSessionEvents } from "./events";
import { redeliverBridgeMessages } from "./triggers";
export async function sweepBridge(admin: SupabaseClient) {
  const result = { unreachable: 0, expired_leases: 0, redelivered: 0, errors: 0 };
  try {
    const { data } = await admin.rpc("sweep_bridge_heartbeats", { p_limit: BRIDGE_REDELIVERY_LIMIT }).throwOnError();
    const rows = z.array(z.union([
      z.object({ user_id: z.guid(), bridge_id: z.guid(), agent_session_id: z.guid(), agent_task_id: z.guid().nullable(), turn_seq: z.number().int().positive().nullable(), failure_count: z.literal(0) }),
      z.object({ user_id: z.null(), bridge_id: z.null(), agent_session_id: z.null(), agent_task_id: z.null(), turn_seq: z.null(), failure_count: z.number().int().positive() }),
    ])).parse(data);
    result.unreachable = rows.filter((row) => row.agent_session_id !== null).length;
    result.errors += rows.reduce((count, row) => count + row.failure_count, 0);
  } catch { result.errors++; }
  try { result.errors += await drainBridgeSessionEvents(admin); } catch { result.errors++; }
  try {
    const { data } = await admin.rpc("sweep_agent_step_leases", { p_now: null }).throwOnError();
    result.expired_leases = z.number().int().nonnegative().parse(data);
  } catch { result.errors++; }
  try { result.redelivered = await redeliverBridgeMessages(admin); } catch { result.errors++; }
  return result;
}
