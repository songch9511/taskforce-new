import { afterEach, describe, expect, it, vi } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { loadPendingDecisions } from "@/lib/coordinator/pending";
import { createAgentConversation } from "./conversations";
import { startPinnedAgentMessage } from "./next-turn";
import { AGENT_REGISTRY } from "./registry";
import { listAssistantTargets } from "./targets";
import { startAgentTurn, startNextQueuedTurn } from "./turns";

vi.mock("server-only", () => ({}));

const USER = "10000000-0000-4000-8000-000000000001";
const OUTSIDER = "20000000-0000-4000-8000-000000000002";
const env = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", AGENT_BETA_USER_IDS: USER };
function noDatabase() {
  const from = vi.fn(() => { throw new Error("unexpected database access"); });
  const rpc = vi.fn(() => { throw new Error("unexpected database mutation"); });
  return { admin: { from, rpc } as unknown as SupabaseClient, from, rpc };
}
describe("agent beta boundary", () => {
  it("outsider gets only Taskforce without querying agent data", async () => {
    const db = noDatabase();
    expect(await listAssistantTargets(db.admin, OUTSIDER, env)).toEqual([{ kind: "taskforce" }]);
    expect(db.from).not.toHaveBeenCalled();
  });
  it("denies all start entry points without side effects", async () => {
    const db = noDatabase();
    const target = { capability: AGENT_REGISTRY["agent:claude-code"], mode: "manual" as const, connectionStatus: "active" as const };
    expect(await startPinnedAgentMessage(db.admin, { userId: OUTSIDER, messageId: USER, state: "queued", reason: null, chips: { action_ids: [], context_ids: [] }, target }, env)).toEqual({ status: "skipped" });
    expect(await startAgentTurn(db.admin, { userId: OUTSIDER, messageId: USER, ...target }, env)).toEqual({ status: "not_found" });
    expect(await startNextQueuedTurn(db.admin, { userId: OUTSIDER, sessionId: USER }, env)).toBeNull();
    expect(await createAgentConversation(db.admin, OUTSIDER, { contextId: null, connectionId: USER }, env)).toEqual({ status: "not_found" });
    expect(db.rpc).not.toHaveBeenCalled();
    expect(db.from).not.toHaveBeenCalled();
  });
});

afterEach(() => vi.unstubAllEnvs());
it("outsider Review keeps coordinator decisions but never loads agent inputs", async () => {
  for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
  const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: [] }) }));
  expect(await loadPendingDecisions({ rpc } as unknown as SupabaseClient, OUTSIDER, new Date(), { agentAdapters: ["agent:claude-code"] })).toEqual([]);
  expect(rpc).toHaveBeenCalledExactlyOnceWith("coordinator_pending_inputs", { p_user_id: OUTSIDER });
});
