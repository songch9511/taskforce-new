import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { fakeAdmin } from "@/lib/agents/fake-admin";
import { AGENT_REGISTRY } from "@/lib/agents/registry";

const mocks = vi.hoisted(() => ({ admin: vi.fn(() => ({ admin: true })), auth: vi.fn(), readConversationTarget: vi.fn(), resolveAgentTarget: vi.fn(), stopAgentSession: vi.fn(), startNextQueuedTurn: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/agents/conversations", () => ({ readConversationTarget: mocks.readConversationTarget, createAgentConversation: vi.fn() }));
vi.mock("@/lib/agents/targets", async (original) => ({ ...(await original<typeof import("@/lib/agents/targets")>()), resolveAgentTarget: mocks.resolveAgentTarget }));
vi.mock("@/lib/agents/tasks", async (original) => ({ ...(await original<typeof import("@/lib/agents/tasks")>()), stopAgentSession: mocks.stopAgentSession }));
vi.mock("@/lib/agents/turns", async (original) => ({ ...(await original<typeof import("@/lib/agents/turns")>()), startNextQueuedTurn: mocks.startNextQueuedTurn }));

import { POST } from "./route";

const USER = "11111111-0000-4000-8000-000000000001";
const CONV = "cccccccc-0000-4000-8000-000000000001";
const SESSION = "5e5e5e5e-0000-4000-8000-000000000001";
const CONN = "c0c0c0c0-0000-4000-8000-000000000001";
const TASK = "7a7a7a7a-0000-4000-8000-000000000001";
const MESSAGE = "dddddddd-0000-4000-8000-000000000001";
/** Stop 뒤 "다음 대기 메시지"를 읽는 표: 대기열 머리(delivery) + 세션 → 연결 */
const queue = (head: { state: string; reason?: string | null; selected?: Record<string, unknown> } | null = { state: "queued" }, actions: string[] = []) =>
  fakeAdmin({
    tables: {
      conversation_messages: head ? [{ id: MESSAGE, user_id: USER, refs: {}, selected: head.selected ?? { action_ids: [], context_ids: [] }, delivery_state: head.state, delivery_reason: head.reason ?? null }] : [],
      execution_policies: [],
      actions: actions.map((id) => ({ id, user_id: USER })),
      agent_sessions: [{ id: SESSION, user_id: USER, connection_id: CONN }],
      agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "active" }],
    },
    rpc: { next_queued_agent_message: () => (head ? MESSAGE : null), start_agent_turn_auto: () => ({ status: "skipped" }), mark_agent_message_not_sent: () => ({ status: "not_sent", reason: "write_gate_closed" }) },
  });
const call = () => POST(new Request(`https://api.example.dev/api/v2/conversations/${CONV}/stop`, { method: "POST", body: "{}" }), { params: Promise.resolve({ id: CONV }) });

beforeEach(() => {
  mocks.admin.mockReturnValue({ admin: true });
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: SESSION });
  mocks.resolveAgentTarget.mockResolvedValue({ adapter: "agent:codex", capability: AGENT_REGISTRY["agent:codex"], mode: "manual", connectionStatus: "active", enabled: true });
  mocks.stopAgentSession.mockResolvedValue({ tasks: [{ agent_task_id: TASK, cancel: "confirmed" }] });
  mocks.startNextQueuedTurn.mockResolvedValue(null);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("POST /api/v2/conversations/{id}/stop (route)", () => {
  it("gate가 꺼져 있으면 404: 인증 · DB · 중단 0", async () => {
    expect((await call()).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.stopAgentSession).not.toHaveBeenCalled();
  });

  it("그 대화의 세션을 surface 'assistant'로 멈추고, 확정된 작업이 있으면 다음 대기 메시지를 한 번 시작해 본다 — 고른 머리 id를 SQL 래퍼에 넘기고 turns.ts의 startNextQueuedTurn은 쓰지 않는다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("EXECUTION_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    const fake = queue();
    mocks.admin.mockReturnValue(fake.admin as never);
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ tasks: [{ agent_task_id: TASK, cancel: "confirmed" }] });
    expect(mocks.stopAgentSession).toHaveBeenCalledExactlyOnceWith(fake.admin, { userId: USER, sessionId: SESSION, surface: "assistant" });
    expect(fake.rpcCalls().map((rpc) => rpc.target)).toEqual(["next_queued_agent_message", "start_agent_turn_auto"]);
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_user_id: USER, p_message_id: MESSAGE });
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
  });

  it("검토 반영 8-2: 첨부 뒤 Action이 지워졌어도 Stop 뒤 자동 시작은 지워진 칩만 빼고 성공한다 — 저장된 selected는 그대로", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("EXECUTION_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    const KEPT = "ac000000-0000-4000-8000-000000000001";
    const GONE = "ac000000-0000-4000-8000-0000000000ff";
    const selected = { action_ids: [KEPT, GONE], context_ids: [], attachments: [{ kind: "action", id: KEPT, origin: "added" }, { kind: "action", id: GONE, origin: "added" }] };
    const fake = queue({ state: "queued", selected }, [KEPT]);
    mocks.admin.mockReturnValue(fake.admin as never);
    expect((await call()).status).toBe(200);
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_message_id: MESSAGE, p_action_ids: [KEPT] });
    expect(fake.tables.conversation_messages[0].selected).toEqual(selected);
  });

  it("D2a 보안 검토 P1 방어: 실행 kill switch가 꺼져 있으면 Stop은 그대로 하되 다음 턴을 시작하지 않고 queued 머리를 write_gate_closed로 표시한다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    const fake = queue();
    mocks.admin.mockReturnValue(fake.admin as never);
    const response = await call();
    expect(response.status).toBe(200);
    expect(mocks.stopAgentSession).toHaveBeenCalledTimes(1);
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
    expect(fake.rpcCalls().map((rpc) => rpc.target)).toEqual(["next_queued_agent_message", "mark_agent_message_not_sent"]);
  });

  it.each(["spawn_failed", "usage_limited", "write_gate_closed"])("검토 반영 7-1: Stop 뒤 대기열 머리가 not_sent/%s이면 시작하지도 이유를 덮어쓰지도 않는다 (실행 플래그가 켜져 있든 꺼져 있든, 실패한 머리는 Send again으로만)", async (reason) => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
    for (const execution of ["true", "false"]) {
      vi.stubEnv("EXECUTION_ENABLED", execution);
      const fake = queue({ state: "not_sent", reason });
      mocks.admin.mockReturnValue(fake.admin as never);
      expect((await call()).status).toBe(200);
      expect(fake.rpcCalls("mark_agent_message_not_sent")).toEqual([]);
      // gate 계열은 플래그가 켜져 있을 때만 다시 시작한다
      expect(fake.rpcCalls("start_agent_turn_auto")).toHaveLength(reason === "write_gate_closed" && execution === "true" ? 1 : 0);
      expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
    }
  });

  it("롤백 규칙: adapter 플래그가 꺼져 있어도 Stop은 200 — 이미 있는 턴을 멈추고(confirmed) 다음 턴은 시작하지 않는다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("EXECUTION_ENABLED", "true");
    mocks.resolveAgentTarget.mockResolvedValue({ adapter: "agent:codex", capability: AGENT_REGISTRY["agent:codex"], mode: "manual", connectionStatus: "active", enabled: false });
    const response = await call();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ tasks: [{ agent_task_id: TASK, cancel: "confirmed" }] });
    expect(mocks.stopAgentSession).toHaveBeenCalledExactlyOnceWith({ admin: true }, { userId: USER, sessionId: SESSION, surface: "assistant" });
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
  });

  it("세션이 없는 대화는 { tasks: [] }이고 중단 · 시작을 부르지 않는다", async () => {
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    mocks.readConversationTarget.mockResolvedValue({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: null });
    const response = await call();
    expect(await response.json()).toEqual({ tasks: [] });
    expect(mocks.stopAgentSession).not.toHaveBeenCalled();
    expect(mocks.startNextQueuedTurn).not.toHaveBeenCalled();
  });
});
