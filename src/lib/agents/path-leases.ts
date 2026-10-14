import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { appendBridgeSessionEvent } from "@/lib/bridge/events";
import { PATH_LEASE_SWEEP_LIMIT } from "@/lib/execution/limits";
import { retryOnConflict } from "./retry";

const count = z.number().int().nonnegative();
const stopResult = z.object({ status: z.enum(["stopped", "noop", "not_found"]), tasks: z.array(z.unknown()).optional() });
const noticeSchema = z.object({
  lease_id: z.guid(), user_id: z.guid(), session_id: z.guid(), task_id: z.guid(), turn_seq: z.number().int().positive(),
  event_id: z.string(), text: z.string(), originating_only: z.boolean(),
  released_at: z.string().nullable(), conflict_at: z.string().nullable(), conflict_stop_at: z.string().nullable(),
});
const conflictSchema = z.object({
  lease_id: z.guid(), holder_run_id: z.guid(), holder_action_id: z.guid().nullable(),
  conflict_run_id: z.guid(), conflict_action_id: z.guid().nullable(), rel_path: z.string(), workspace_ref: z.string(),
  conflict_at: z.string(), conflict_version: z.number().int().positive(), released: z.boolean(),
});
export type PathConflict = z.infer<typeof conflictSchema>;

/** Called after event commit; SQL owns cancellation and releases the stopped run's leases. */
export async function stopPathConflictRuns(admin: SupabaseClient, scope: { userId?: string; bridgeId?: string } = {}) {
  const { data } = await admin.rpc("list_pending_path_conflict_stops", {
    p_user_id: scope.userId ?? null, p_bridge_id: scope.bridgeId ?? null, p_limit: PATH_LEASE_SWEEP_LIMIT,
  }).throwOnError();
  const rows = z.array(z.object({ id: z.guid(), user_id: z.guid() })).parse(data);
  const result = { stopped: 0, errors: 0 };
  for (const row of rows) {
    try {
      const { data } = await retryOnConflict(async () => await admin.rpc("stop_agent_run_for_path_conflict", { p_user_id: row.user_id, p_lease_id: row.id }).throwOnError());
      if (stopResult.parse(data).status === "stopped") result.stopped++;
    } catch { result.errors++; }
  }
  return result;
}

/** Only acknowledge a whole lease's fanout; CAS timestamps leave later lifecycle changes pending. */
export async function drainPathLeaseNotices(admin: SupabaseClient) {
  const { data } = await admin.rpc("list_path_lease_notices", { p_limit: PATH_LEASE_SWEEP_LIMIT }).throwOnError();
  const notices = z.array(noticeSchema).parse(data);
  const groups = new Map<string, typeof notices>();
  for (const notice of notices) {
    const group = groups.get(notice.lease_id) ?? [];
    group.push(notice);
    groups.set(notice.lease_id, group);
  }
  const result = { notified: 0, errors: 0 };
  for (const group of groups.values()) {
    try {
      for (const notice of group) {
        await appendBridgeSessionEvent(admin, {
          userId: notice.user_id, sessionId: notice.session_id, taskId: notice.task_id, turnSeq: notice.turn_seq,
          eventId: notice.event_id, text: notice.text, originatingOnly: notice.originating_only,
        });
      }
      const { lease_id, released_at, conflict_at, conflict_stop_at } = group[0];
      const { data: marked } = await admin.rpc("mark_path_lease_notices", { p_ids: [{ lease_id, released_at, conflict_at, conflict_stop_at }] }).throwOnError();
      result.notified += count.parse(marked);
    } catch { result.errors++; }
  }
  return result;
}

/** Each stage is independent so one failure cannot prevent committed conflicts from stopping. */
export async function sweepPathLeases(admin: SupabaseClient) {
  const result = { expired: 0, run_ended: 0, stopped: 0, notified: 0, errors: 0 };
  try {
    const { data } = await admin.rpc("sweep_agent_path_leases", { p_limit: PATH_LEASE_SWEEP_LIMIT }).throwOnError();
    Object.assign(result, z.object({ expired: count, run_ended: count }).parse(data));
  } catch { result.errors++; }
  try {
    const stopped = await stopPathConflictRuns(admin);
    result.stopped = stopped.stopped;
    result.errors += stopped.errors;
  } catch { result.errors++; }
  try {
    const notices = await drainPathLeaseNotices(admin);
    result.notified = notices.notified;
    result.errors += notices.errors;
  } catch { result.errors++; }
  return result;
}

export async function listPathConflicts(admin: SupabaseClient, userId: string): Promise<PathConflict[]> {
  const { data } = await admin.rpc("list_path_conflicts", { p_user_id: z.guid().parse(userId), p_limit: PATH_LEASE_SWEEP_LIMIT }).throwOnError();
  return z.array(conflictSchema).parse(data);
}

export async function resolvePathConflict(admin: SupabaseClient, input: { userId: string; leaseId: string; keep: "holder" | "later"; conflictVersion: number }) {
  const { data } = await admin.rpc("resolve_path_conflict", {
    p_user_id: z.guid().parse(input.userId), p_lease_id: z.guid().parse(input.leaseId),
    p_keep: z.enum(["holder", "later"]).parse(input.keep), p_conflict_version: z.number().int().positive().parse(input.conflictVersion),
  }).throwOnError();
  return z.object({ status: z.enum(["resolved", "stale", "not_found"]) }).parse(data);
}
