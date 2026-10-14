import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { appendBridgeSessionEvent } from "@/lib/bridge/events";
import { drainPathLeaseNotices, listPathConflicts, resolvePathConflict, stopPathConflictRuns, sweepPathLeases } from "./path-leases";

vi.mock("@/lib/bridge/events", () => ({ appendBridgeSessionEvent: vi.fn() }));
const USER = "11111111-1111-4111-8111-111111111111";
const BRIDGE = "22222222-2222-4222-8222-222222222222";
const LEASE = "33333333-3333-4333-8333-333333333333";
const TASK = "44444444-4444-4444-8444-444444444444";
const SESSION = "55555555-5555-4555-8555-555555555555";
const RUN = "66666666-6666-4666-8666-666666666666";
const AT = "2026-10-14T00:00:00Z";
const notice = { lease_id: LEASE, user_id: USER, session_id: SESSION, task_id: TASK, turn_seq: 1,
  event_id: `path-free:${LEASE}:${RUN}`, text: "pricing.mdx is free now", originating_only: true,
  released_at: AT, conflict_at: null, conflict_stop_at: null };
function client(rows: unknown[] = []) {
  const rpcRun = vi.fn(async (name: string): Promise<{ data: unknown }> => ({ data:
    name === "sweep_agent_path_leases" ? { expired: 2, run_ended: 1 } : name === "stop_agent_run_for_path_conflict" ? { status: "stopped", tasks: [{ status: "requested_only" }] } :
      name === "list_path_lease_notices" || name === "list_path_conflicts" ? [] : name === "resolve_path_conflict" ? { status: "resolved" } : 1 }));
  const rpc = vi.fn((name: string) => ({ throwOnError: () => name === "list_pending_path_conflict_stops" ? Promise.resolve({ data: rows }) : rpcRun(name) }));
  const from = vi.fn();
  return { admin: { rpc, from } as unknown as SupabaseClient, rpc, rpcRun, from };
}
beforeEach(() => { vi.clearAllMocks(); vi.mocked(appendBridgeSessionEvent).mockResolvedValue(undefined); });
describe("path lease lifecycle wrappers", () => {
  it("scopes postcommit stops to the authenticated user and bridge", async () => {
    const { admin, rpc } = client([{ id: LEASE, user_id: USER }]);
    expect(await stopPathConflictRuns(admin, { userId: USER, bridgeId: BRIDGE })).toEqual({ stopped: 1, errors: 0 });
    expect(rpc).toHaveBeenNthCalledWith(1, "list_pending_path_conflict_stops", { p_user_id: USER, p_bridge_id: BRIDGE, p_limit: 500 });
    expect(rpc).toHaveBeenNthCalledWith(2, "stop_agent_run_for_path_conflict", { p_user_id: USER, p_lease_id: LEASE });
  });
  it("retries contention three attempts and leaves persistent failures for the next sweep", async () => {
    const { admin, rpc, rpcRun } = client([{ id: LEASE, user_id: USER }]);
    rpcRun.mockRejectedValue({ code: "55P03", message: "private path" });
    expect(await stopPathConflictRuns(admin, { userId: USER })).toEqual({ stopped: 0, errors: 1 });
    expect(rpc).toHaveBeenCalledTimes(4);
  });
  it("does not retry non-contention stop failures or stop after one bad lease", async () => {
    const other = "77777777-7777-4777-8777-777777777777";
    const { admin, rpc, rpcRun } = client([{ id: LEASE, user_id: USER }, { id: other, user_id: USER }]);
    rpcRun.mockRejectedValueOnce({ code: "XX000" });
    expect(await stopPathConflictRuns(admin, {})).toEqual({ stopped: 1, errors: 1 });
    expect(rpc).toHaveBeenCalledTimes(3);
  });
  it("marks a lease only after all notice appends succeed, retaining partial fanout for retry", async () => {
    const { admin, rpc, rpcRun } = client();
    rpcRun.mockResolvedValueOnce({ data: [notice, { ...notice, event_id: `path-conflict:${LEASE}:${RUN}`, originating_only: false }] });
    vi.mocked(appendBridgeSessionEvent).mockRejectedValueOnce(new Error("private"));
    expect(await drainPathLeaseNotices(admin)).toEqual({ notified: 0, errors: 1 });
    expect(rpc).not.toHaveBeenCalledWith("mark_path_lease_notices", expect.anything());
    rpcRun.mockResolvedValueOnce({ data: [notice] });
    expect(await drainPathLeaseNotices(admin)).toEqual({ notified: 1, errors: 0 });
    expect(appendBridgeSessionEvent).toHaveBeenLastCalledWith(admin, {
      userId: USER, sessionId: SESSION, taskId: TASK, turnSeq: 1, eventId: notice.event_id, text: notice.text, originatingOnly: true,
    });
    expect(rpc).toHaveBeenLastCalledWith("mark_path_lease_notices", { p_ids: [{ lease_id: LEASE, released_at: AT, conflict_at: null, conflict_stop_at: null }] });
  });
  it("does not count a stale notification mark as delivered", async () => {
    const { admin, rpcRun } = client();
    rpcRun.mockResolvedValueOnce({ data: [notice] }).mockResolvedValueOnce({ data: 0 });
    expect(await drainPathLeaseNotices(admin)).toEqual({ notified: 0, errors: 0 });
  });
  it("external notices fan out to the whole session and keep their deterministic id", async () => {
    const { admin, rpcRun } = client();
    const external = { ...notice, event_id: `path-external:${SESSION}:1791936000`, text: "File locks released", originating_only: false };
    rpcRun.mockResolvedValueOnce({ data: [external] });
    await drainPathLeaseNotices(admin);
    expect(appendBridgeSessionEvent).toHaveBeenCalledExactlyOnceWith(admin, expect.objectContaining({ eventId: external.event_id, text: external.text, originatingOnly: false }));
  });
  it("continues conflict stop and notices after expiry cleanup fails", async () => {
    const { admin, rpc, rpcRun, from } = client();
    rpcRun.mockRejectedValueOnce(new Error("private"));
    expect(await sweepPathLeases(admin)).toEqual({ expired: 0, run_ended: 0, stopped: 0, notified: 0, errors: 1 });
    expect(from).not.toHaveBeenCalled();
    expect(rpc).toHaveBeenCalledWith("list_pending_path_conflict_stops", { p_user_id: null, p_bridge_id: null, p_limit: 500 });
    expect(rpc).toHaveBeenCalledWith("list_path_lease_notices", { p_limit: 500 });
  });
  it("uses bounded sweep limits and aggregates cleanup, stop and notice outcomes", async () => {
    const { admin, rpc } = client([{ id: LEASE, user_id: USER }]);
    expect(await sweepPathLeases(admin)).toEqual({ expired: 2, run_ended: 1, stopped: 1, notified: 0, errors: 0 });
    expect(rpc).toHaveBeenCalledWith("sweep_agent_path_leases", { p_limit: 500 });
  });
  it("passes conflict owner and version to the list and resolution RPCs", async () => {
    const { admin, rpc } = client();
    expect(await listPathConflicts(admin, USER)).toEqual([]);
    expect(rpc).toHaveBeenLastCalledWith("list_path_conflicts", { p_user_id: USER, p_limit: 500 });
    expect(await resolvePathConflict(admin, { userId: USER, leaseId: LEASE, keep: "later", conflictVersion: 7 })).toEqual({ status: "resolved" });
    expect(rpc).toHaveBeenLastCalledWith("resolve_path_conflict", { p_user_id: USER, p_lease_id: LEASE, p_keep: "later", p_conflict_version: 7 });
  });
});

it("review 9 preserves integer conflict versions even for released conflicts", async () => {
  const { admin, rpcRun } = client();
  const conflict = { lease_id: LEASE, holder_run_id: RUN, holder_action_id: null,
    conflict_run_id: TASK, conflict_action_id: null, rel_path: "a.md", workspace_ref: "/w/proj",
    conflict_at: "2026-10-14T00:00:00.123456Z", conflict_version: 7, released: true };
  rpcRun.mockResolvedValueOnce({ data: [conflict] });
  expect(await listPathConflicts(admin, USER)).toEqual([conflict]);
});
it.each([0, -1, 1.5, NaN, Number.MAX_SAFE_INTEGER + 1])("review 9 rejects invalid conflict version %s before RPC", async (conflictVersion) => {
  const { admin, rpc } = client();
  await expect(resolvePathConflict(admin, { userId: USER, leaseId: LEASE, keep: "later", conflictVersion })).rejects.toThrow();
  expect(rpc).not.toHaveBeenCalled();
});

it("queries pending conflict stops through the SQL live-run filter before applying its limit", async () => {
  const { admin, rpc, from } = client([{ id: LEASE, user_id: USER }]);
  expect(await stopPathConflictRuns(admin, { userId: USER, bridgeId: BRIDGE })).toEqual({ stopped: 1, errors: 0 });
  expect(rpc).toHaveBeenNthCalledWith(1, "list_pending_path_conflict_stops", { p_user_id: USER, p_bridge_id: BRIDGE, p_limit: 500 });
  expect(rpc).toHaveBeenNthCalledWith(2, "stop_agent_run_for_path_conflict", { p_user_id: USER, p_lease_id: LEASE });
  expect(from).not.toHaveBeenCalled();
});
