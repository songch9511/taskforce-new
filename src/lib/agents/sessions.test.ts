import { describe, expect, it, vi } from "vitest";

import { agentSessionSchema } from "@/lib/api/contract";

import { fakeAdmin } from "./fake-admin";
import { loadAgentSession, loadSessionAdapter, openAgentSessionExternal, renameAgentSession, resumeAgentSessionHere } from "./sessions";

const USER = "10000000-0000-4000-8000-000000000001";
const OTHER = "20000000-0000-4000-8000-000000000002";
const CONN = "c0000000-0000-4000-8000-000000000001";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const MSG = "a1000000-0000-4000-8000-000000000001";
const TASK = "7a000000-0000-4000-8000-000000000001";
const CODEX = { AGENT_ADAPTER_CODEX_ENABLED: "true", EXECUTION_ENABLED: "true" };
const OFF = { AGENT_ADAPTER_CODEX_ENABLED: "true" };
const started = { status: "started", action_id: TASK, run_id: TASK, agent_task_id: TASK, step_id: TASK, turn_seq: 2, created_action: false };

const sessionRow = (extra: Record<string, unknown> = {}) => ({
  id: SESSION, user_id: USER, connection_id: CONN, display_name: "Pricing copy", status: "bound", last_turn_seq: 3, updated_at: "2026-10-14T01:00:00Z", ...extra,
});
function world(extra: Record<string, Record<string, unknown>[]> = {}) {
  return {
    agent_sessions: [sessionRow()],
    agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "active" }],
    agent_tasks: [{ id: TASK, user_id: USER, message_id: MSG }],
    metric_events: [],
    ...extra,
  };
}
const writes = (fake: ReturnType<typeof fakeAdmin>) => fake.calls.filter((call) => ["insert", "update", "upsert"].includes(call.kind));

describe("loadAgentSession · loadSessionAdapter", () => {
  it("내 세션만, 응답 모양(agentSessionSchema)으로", async () => {
    const fake = fakeAdmin({ tables: world() });
    const session = await loadAgentSession(fake.admin, USER, SESSION);
    expect(agentSessionSchema.parse(session)).toEqual({ id: SESSION, connection_id: CONN, display_name: "Pricing copy", status: "bound", last_turn_seq: 3, updated_at: "2026-10-14T01:00:00.000Z" });
    expect(await loadAgentSession(fake.admin, OTHER, SESSION)).toBeNull();
    expect(await loadAgentSession(fake.admin, USER, MSG)).toBeNull();
  });

  it("세션 → 연결 → adapter와 gate (OD-2). 세션이 없거나 registry 밖 adapter면 null", async () => {
    expect(await loadSessionAdapter(fakeAdmin({ tables: world() }).admin, USER, SESSION, CODEX)).toEqual({ adapter: "agent:codex", enabled: true });
    expect(await loadSessionAdapter(fakeAdmin({ tables: world() }).admin, USER, SESSION, {})).toEqual({ adapter: "agent:codex", enabled: false });
    expect(await loadSessionAdapter(fakeAdmin({ tables: world() }).admin, OTHER, SESSION, CODEX)).toBeNull();
    expect(await loadSessionAdapter(fakeAdmin({ tables: world({ agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:cursor", status: "active" }] }) }).admin, USER, SESSION, CODEX)).toBeNull();
  });
});

describe("renameAgentSession (R14)", () => {
  it("이름을 바꾸고 지표 session_renamed 한 줄 (props는 adapter뿐, 이름 글 0)", async () => {
    const fake = fakeAdmin({ tables: world() });
    const result = await renameAgentSession(fake.admin, USER, SESSION, "새 이름");
    expect(result).toMatchObject({ status: "renamed", session: { id: SESSION, display_name: "새 이름" } });
    expect(fake.tables.agent_sessions[0].display_name).toBe("새 이름");
    expect(fake.tables.metric_events).toEqual([{ user_id: USER, type: "session_renamed", props: { adapter: "agent:codex" } }]);
    expect(JSON.stringify(fake.tables.metric_events)).not.toContain("새 이름");
  });

  it("같은 이름이면 unchanged: 쓰기 0, 지표 0", async () => {
    const fake = fakeAdmin({ tables: world() });
    expect(await renameAgentSession(fake.admin, USER, SESSION, "Pricing copy")).toMatchObject({ status: "unchanged", session: { display_name: "Pricing copy" } });
    expect(fake.tables.metric_events).toEqual([]);
    expect(writes(fake).filter((call) => call.target === "metric_events")).toEqual([]);
  });

  it("없거나 남의 세션은 not_found: 쓰기 0 (남의 세션 이름이 바뀌지 않는다)", async () => {
    const fake = fakeAdmin({ tables: world({ agent_sessions: [sessionRow({ user_id: OTHER })] }) });
    expect(await renameAgentSession(fake.admin, USER, SESSION, "x")).toEqual({ status: "not_found" });
    expect(fake.tables.agent_sessions[0].display_name).toBe("Pricing copy");
    expect(fake.tables.metric_events).toEqual([]);
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });
});

describe("openAgentSessionExternal (AC-36 서버 몫)", () => {
  it.each(["external", "unchanged"])("%s → 세션을 다시 읽어 돌려준다", async (status) => {
    const fake = fakeAdmin({ tables: world({ agent_sessions: [sessionRow({ status: "external" })] }), rpc: { open_agent_session_external: () => ({ status }) } });
    expect(await openAgentSessionExternal(fake.admin, USER, SESSION)).toMatchObject({ status, session: { id: SESSION, status: "external" } });
    expect(fake.rpcCalls("open_agent_session_external")[0].args).toEqual({ p_user_id: USER, p_session_id: SESSION });
  });

  it.each(["busy", "not_started", "not_bound", "not_found"])("%s는 세션을 읽지 않고 상태만 돌려준다", async (status) => {
    const fake = fakeAdmin({ tables: world(), rpc: { open_agent_session_external: () => ({ status }) } });
    expect(await openAgentSessionExternal(fake.admin, USER, SESSION)).toEqual({ status });
  });

  it("모르는 결과는 던진다", async () => {
    await expect(openAgentSessionExternal(fakeAdmin({ tables: world(), rpc: { open_agent_session_external: () => ({ status: "later" }) } }).admin, USER, SESSION)).rejects.toThrow();
  });
});

describe("resumeAgentSessionHere (AC-36 · ONE-TF-13 서버 몫)", () => {
  const rpc = (status: string, next: unknown = null) => ({ resume_agent_session_here: () => ({ status }), next_queued_agent_message: () => next, route_agent_message: () => started });

  it("bound가 되면 commit 뒤 대기 메시지를 한 번 시작해 본다 (자동 전달 계기 ④). 시작된 메시지 id를 돌려준다", async () => {
    const fake = fakeAdmin({
      tables: world({
        agent_sessions: [sessionRow()],
        conversation_messages: [{ id: MSG, user_id: USER, refs: {}, selected: { action_ids: [], context_ids: [] } }],
        execution_policies: [],
      }),
      rpc: rpc("bound", MSG),
    });
    const result = await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX);
    expect(result).toMatchObject({ status: "bound", session: { id: SESSION }, startedMessageId: MSG });
    // 순서: 상태 전이(commit) → 다음 시작
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["resume_agent_session_here", "next_queued_agent_message", "route_agent_message"]);
  });

  it("대기 메시지가 없으면 시작 0, started_message_id는 null", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpc("bound", null) });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX)).toMatchObject({ status: "bound", startedMessageId: null });
    expect(fake.rpcCalls("route_agent_message")).toEqual([]);
  });

  it("이미 bound(unchanged)여도 대기열을 한 번 확인한다 (앞선 시작이 실패했을 때 다시 눌러 이어 갈 수 있다)", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpc("unchanged", null) });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX)).toMatchObject({ status: "unchanged", startedMessageId: null });
    expect(fake.rpcCalls("next_queued_agent_message")).toHaveLength(1);
  });

  it.each(["not_external", "not_found"])("%s는 대기열을 건드리지 않는다", async (status) => {
    const fake = fakeAdmin({ tables: world(), rpc: rpc(status, MSG) });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX)).toEqual({ status, startedMessageId: null });
    expect(fake.rpcCalls("next_queued_agent_message")).toEqual([]);
  });

  it("D2a 보안 검토 P1 방어: 실행 kill switch가 꺼져 있으면 되돌려도 턴을 시작하지 않고 대기 메시지를 not_sent/write_gate_closed로 표시한다 (route_agent_message 0)", async () => {
    const fake = fakeAdmin({
      tables: world(),
      rpc: { ...rpc("bound", MSG), mark_agent_message_not_sent: () => ({ status: "not_sent", reason: "write_gate_closed" }) },
    });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, OFF)).toMatchObject({ status: "bound", startedMessageId: null });
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["resume_agent_session_here", "next_queued_agent_message", "mark_agent_message_not_sent"]);
  });

  it("다음 시작이 실패해도 상태 전이는 끝났으니 bound로 답한다 (오류 이름만 로그)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const fake = fakeAdmin({ tables: world(), rpc: { ...rpc("bound"), next_queued_agent_message: () => { throw Object.assign(new Error("원문"), { name: "PostgrestError" }); } } });
      expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX)).toMatchObject({ status: "bound", startedMessageId: null });
      expect(JSON.parse(String(log.mock.calls[0][0]))).toEqual({ event: "agent_start_next_failed", error: "PostgrestError" });
      expect(JSON.stringify(log.mock.calls)).not.toContain("원문");
    } finally {
      log.mockRestore();
    }
  });
});
