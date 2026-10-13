import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { stopAgentSession } from "./tasks";

const id = "10000000-0000-4000-8000-000000000001";
function db(adapter = "agent:codex", result: unknown = { tasks: [{ agent_task_id: id, cancel: "requested_only", processes: "may_continue" }] }) {
  const rows: Record<string, unknown> = { agent_sessions: { connection_id: id }, agent_connections: { adapter } };
  const queries: { eq: ReturnType<typeof vi.fn> }[] = [];
  const from = vi.fn((table: string) => {
    const query = { select: vi.fn(), eq: vi.fn(), maybeSingle: vi.fn(), throwOnError: vi.fn().mockImplementation(async () => ({ data: rows[table] })) };
    query.select.mockReturnValue(query); query.eq.mockReturnValue(query); query.maybeSingle.mockReturnValue(query); queries.push(query);
    return query;
  });
  const rpc = vi.fn().mockReturnValue({ throwOnError: vi.fn().mockResolvedValue({ data: result }) });
  return { admin: { from, rpc } as unknown as SupabaseClient, rpc, rows, queries };
}
const input = { userId: id, sessionId: id, surface: "assistant" as const };
describe("stopAgentSession", () => {
  it.each([["agent:codex", "turn"], ["agent:claude-code", "turn_and_processes"]])("resolves %s cancel scope from the owned connection", async (adapter, scope) => {
    const d = db(adapter);
    await stopAgentSession(d.admin, input);
    expect(d.rpc).toHaveBeenCalledExactlyOnceWith("stop_agent_session", { p_user_id: id, p_session_id: id, p_surface: "assistant", p_cancel_scope: scope });
    for (const query of d.queries) expect(query.eq).toHaveBeenCalledWith("user_id", id);
  });
  it("accepts session panel and confirmed cancellation", async () => {
    const result = { tasks: [{ agent_task_id: id, cancel: "confirmed" }] };
    expect(await stopAgentSession(db("agent:claude-code", result).admin, { ...input, surface: "session_panel" })).toEqual(result);
  });
  it.each(["agent_sessions", "agent_connections"])("returns not_found for missing %s without RPC", async (table) => {
    const d = db(); d.rows[table] = null;
    expect(await stopAgentSession(d.admin, input)).toEqual({ status: "not_found" });
    expect(d.rpc).not.toHaveBeenCalled();
  });
  it("rejects an unrecognized adapter without RPC", async () => {
    const d = db("untrusted");
    await expect(stopAgentSession(d.admin, input)).rejects.toThrow();
    expect(d.rpc).not.toHaveBeenCalled();
  });
  it.each([1, 2])("retries %s rolled-back lock conflicts without re-reading the registry", async (count) => {
    const d = db();
    const execute = vi.fn();
    for (let attempt = 0; attempt < count; attempt++) execute.mockRejectedValueOnce({ code: "55P03" });
    execute.mockResolvedValueOnce({ data: { tasks: [] } });
    d.rpc.mockReturnValue({ throwOnError: execute });
    expect(await stopAgentSession(d.admin, input)).toEqual({ tasks: [] });
    expect(d.rpc).toHaveBeenCalledTimes(count + 1);
    expect(d.queries).toHaveLength(2);
  });
  it.each([["55P03", 3], ["40001", 1], ["XX000", 1]])("propagates %s after %s attempts", async (code, attempts) => {
    const d = db();
    const error = { code };
    d.rpc.mockReturnValue({ throwOnError: vi.fn().mockRejectedValue(error) });
    await expect(stopAgentSession(d.admin, input)).rejects.toBe(error);
    expect(d.rpc).toHaveBeenCalledTimes(attempts);
  });
  it.each([{ tasks: [{ agent_task_id: id, cancel: "maybe" }] }, { tasks: [{ agent_task_id: id, cancel: "confirmed", secret: "leak" }] }, { tasks: [], extra: true }])("rejects malformed output", async (result) => {
    await expect(stopAgentSession(db("agent:codex", result).admin, input)).rejects.toThrow();
  });
});
