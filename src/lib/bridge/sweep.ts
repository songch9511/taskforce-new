import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { BRIDGE_REDELIVERY_LIMIT } from "@/lib/execution/limits";
import { drainBridgeSessionEvents } from "./events";
import { kickBridgeSessions, redeliverBridgeMessages } from "./triggers";
export async function sweepBridge(admin: SupabaseClient) {
  const result = { unreachable: 0, expired_leases: 0, reclaimed: 0, reclaim_busy: 0, redelivered: 0, errors: 0 };
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
  try {
    // 만료한 lease 전 prepared 회수 (OA F3): Mac이 꺼진 동안 24시간이 지난 메시지를 DB가 expired로 만든다. 회수한 세션은 뒤 메시지가 바로 갈 수 있게 kick한다 (bound인 세션만 실제로 시작).
    const { data } = await admin.rpc("expire_unleased_agent_messages", { p_limit: BRIDGE_REDELIVERY_LIMIT }).throwOnError();
    const reclaim = z.strictObject({
      reclaimed: z.number().int().nonnegative(), busy: z.number().int().nonnegative(),
      sessions: z.array(z.strictObject({ user_id: z.guid(), agent_session_id: z.guid() })),
    }).parse(data);
    result.reclaimed = reclaim.reclaimed;
    result.reclaim_busy = reclaim.busy;
    const byUser = new Map<string, string[]>();
    for (const session of reclaim.sessions) byUser.set(session.user_id, [...(byUser.get(session.user_id) ?? []), session.agent_session_id]);
    for (const [userId, sessionIds] of byUser) await kickBridgeSessions(admin, userId, sessionIds);
  } catch { result.errors++; }
  try { result.redelivered = await redeliverBridgeMessages(admin); } catch { result.errors++; }
  return result;
}
