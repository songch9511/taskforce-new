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

describe("renameAgentSession (R14 · 검토 반영 7-5)", () => {
  const rename = (status: string) => ({ rename_agent_session: () => ({ status }) });

  it("SQL 함수 한 번으로 이름과 지표를 같은 트랜잭션에서 바꾼다: TS는 별도 update · insert를 하지 않고 바뀐 세션을 다시 읽어 돌려준다", async () => {
    const fake = fakeAdmin({ tables: world({ agent_sessions: [sessionRow({ display_name: "새 이름" })] }), rpc: rename("renamed") });
    const result = await renameAgentSession(fake.admin, USER, SESSION, "새 이름");
    expect(result).toMatchObject({ status: "renamed", session: { id: SESSION, display_name: "새 이름" } });
    expect(fake.rpcCalls("rename_agent_session")).toHaveLength(1);
    expect(fake.rpcCalls("rename_agent_session")[0].args).toEqual({ p_user_id: USER, p_session_id: SESSION, p_display_name: "새 이름" });
    expect(writes(fake)).toEqual([]); // 이름 update · 지표 insert 0 (SQL이 같은 트랜잭션에서 한다)
  });

  it("unchanged는 세션을 읽어 그대로 돌려준다 (지표 0은 SQL 몫)", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rename("unchanged") });
    expect(await renameAgentSession(fake.admin, USER, SESSION, "Pricing copy")).toMatchObject({ status: "unchanged", session: { display_name: "Pricing copy" } });
    expect(writes(fake)).toEqual([]);
  });

  it("없거나 남의 세션은 not_found: 세션을 읽지 않는다", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rename("not_found") });
    expect(await renameAgentSession(fake.admin, USER, SESSION, "x")).toEqual({ status: "not_found" });
    expect(fake.calls.filter((call) => call.kind === "select")).toEqual([]);
  });

  it("바뀐 직후 세션을 읽지 못하면 not_found, 모르는 결과는 던진다", async () => {
    expect(await renameAgentSession(fakeAdmin({ tables: world({ agent_sessions: [] }), rpc: rename("renamed") }).admin, USER, SESSION, "x")).toEqual({ status: "not_found" });
    await expect(renameAgentSession(fakeAdmin({ tables: world(), rpc: rename("later") }).admin, USER, SESSION, "x")).rejects.toThrow();
  });
});

describe("renameAgentSession 경합 (검토 반영 9-2)", () => {
  it.each(["40001", "40P01", "55P03"])("%s로 두 번 롤백돼도 세 번째에 성공하면 그 결과를 돌려준다. 세 번 모두면 던진다", async (code) => {
    let calls = 0;
    const flaky = fakeAdmin({ tables: world({ agent_sessions: [sessionRow({ display_name: "새 이름" })] }), rpc: { rename_agent_session: () => { if (++calls < 3) throw Object.assign(new Error("conflict"), { code }); return { status: "renamed" }; } } });
    expect(await renameAgentSession(flaky.admin, USER, SESSION, "새 이름")).toMatchObject({ status: "renamed" });
    expect(flaky.rpcCalls("rename_agent_session")).toHaveLength(3);
    const stuck = fakeAdmin({ tables: world(), rpc: { rename_agent_session: () => { throw Object.assign(new Error("conflict"), { code }); } } });
    await expect(renameAgentSession(stuck.admin, USER, SESSION, "x")).rejects.toMatchObject({ code });
    expect(stuck.rpcCalls("rename_agent_session")).toHaveLength(3);
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

  const lock = () => Object.assign(new Error("could not obtain lock"), { code: "55P03" });

  it("검토 반영 7-2: 묶인 대화 잠금 경합(55P03)은 원자 실패이므로 다시 부른다 — 두 번 실패해도 세 번째에 성공하면 그 결과를 돌려준다", async () => {
    let calls = 0;
    const fake = fakeAdmin({ tables: world({ agent_sessions: [sessionRow({ status: "external" })] }), rpc: { open_agent_session_external: () => { if (++calls < 3) throw lock(); return { status: "external" }; } } });
    expect(await openAgentSessionExternal(fake.admin, USER, SESSION)).toMatchObject({ status: "external", session: { status: "external" } });
    expect(fake.rpcCalls("open_agent_session_external")).toHaveLength(3);
  });

  it("세 번 모두 경합이면 던진다 (route가 409 busy_retry로 바꾼다). 다른 오류는 다시 부르지 않는다", async () => {
    const stuck = fakeAdmin({ tables: world(), rpc: { open_agent_session_external: () => { throw lock(); } } });
    await expect(openAgentSessionExternal(stuck.admin, USER, SESSION)).rejects.toMatchObject({ code: "55P03" });
    expect(stuck.rpcCalls("open_agent_session_external")).toHaveLength(3);
    for (const code of ["40001", "40P01"]) {
      const conflict = fakeAdmin({ tables: world(), rpc: { open_agent_session_external: () => { throw Object.assign(new Error("db"), { code }); } } });
      await expect(openAgentSessionExternal(conflict.admin, USER, SESSION)).rejects.toMatchObject({ code });
      expect(conflict.rpcCalls("open_agent_session_external")).toHaveLength(3); // 검토 반영 9-2: 세 코드 모두 다시 한다
    }
    for (const code of ["XX000", "22023"]) {
      const other = fakeAdmin({ tables: world(), rpc: { open_agent_session_external: () => { throw Object.assign(new Error("db"), { code }); } } });
      await expect(openAgentSessionExternal(other.admin, USER, SESSION)).rejects.toMatchObject({ code });
      expect(other.rpcCalls("open_agent_session_external")).toHaveLength(1);
    }
  });

  it("모르는 결과는 던진다", async () => {
    await expect(openAgentSessionExternal(fakeAdmin({ tables: world(), rpc: { open_agent_session_external: () => ({ status: "later" }) } }).admin, USER, SESSION)).rejects.toThrow();
  });
});

describe("resumeAgentSessionHere (AC-36 · ONE-TF-13 서버 몫)", () => {
  const rpc = (status: string, next: unknown = null) => ({ resume_agent_session_here: () => ({ status }), next_queued_agent_message: () => next, start_agent_turn_auto: () => started });

  it("bound가 되면 commit 뒤 대기 메시지를 한 번 시작해 본다 (자동 전달 계기 ④). 시작된 메시지 id를 돌려준다", async () => {
    const fake = fakeAdmin({
      tables: world({
        agent_sessions: [sessionRow()],
        conversation_messages: [{ id: MSG, user_id: USER, refs: {}, selected: { action_ids: [], context_ids: [] }, delivery_state: "queued", delivery_reason: null }],
        execution_policies: [],
      }),
      rpc: rpc("bound", MSG),
    });
    const result = await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX);
    expect(result).toMatchObject({ status: "bound", session: { id: SESSION }, startedMessageId: MSG });
    // 순서: 상태 전이(commit) → 다음 시작
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["resume_agent_session_here", "next_queued_agent_message", "start_agent_turn_auto"]);
  });

  it("검토 반영 7-2: 묶인 대화 잠금 경합(55P03)이면 상태 전이가 롤백됐으니 다시 부른다 — 대기열 시작은 전이가 성공한 뒤 한 번만", async () => {
    let calls = 0;
    const fake = fakeAdmin({
      tables: world(),
      rpc: { ...rpc("bound", null), resume_agent_session_here: () => { if (++calls < 3) throw Object.assign(new Error("lock"), { code: "55P03" }); return { status: "bound" }; } },
    });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX)).toMatchObject({ status: "bound", startedMessageId: null });
    expect(fake.rpcCalls("resume_agent_session_here")).toHaveLength(3);
    expect(fake.rpcCalls("next_queued_agent_message")).toHaveLength(1);
    const stuck = fakeAdmin({ tables: world(), rpc: { resume_agent_session_here: () => { throw Object.assign(new Error("lock"), { code: "55P03" }); } } });
    await expect(resumeAgentSessionHere(stuck.admin, USER, SESSION, CODEX)).rejects.toMatchObject({ code: "55P03" });
    expect(stuck.rpcCalls("resume_agent_session_here")).toHaveLength(3);
    expect(stuck.rpcCalls("next_queued_agent_message")).toEqual([]);
  });

  it("검토 반영 8-2: 첨부 뒤 Action이 지워졌어도 Resume 뒤 자동 시작은 성공한다 — 지워진 칩만 처리 입력에서 빠지고 저장된 selected는 그대로", async () => {
    const GONE = "ac000000-0000-4000-8000-0000000000ff";
    const KEPT = "ac000000-0000-4000-8000-000000000001";
    const selected = { action_ids: [KEPT, GONE], context_ids: [], attachments: [{ kind: "action", id: KEPT, origin: "added" }, { kind: "action", id: GONE, origin: "added" }] };
    const fake = fakeAdmin({
      tables: world({ conversation_messages: [{ id: MSG, user_id: USER, refs: {}, selected, delivery_state: "queued", delivery_reason: null }], actions: [{ id: KEPT, user_id: USER }] }),
      rpc: rpc("bound", MSG),
    });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX)).toMatchObject({ status: "bound", startedMessageId: MSG });
    expect(fake.rpcCalls("start_agent_turn_auto")[0].args).toMatchObject({ p_message_id: MSG, p_action_ids: [KEPT] });
    expect(fake.tables.conversation_messages[0].selected).toEqual(selected);
  });

  it("대기 메시지가 없으면 시작 0, started_message_id는 null", async () => {
    const fake = fakeAdmin({ tables: world(), rpc: rpc("bound", null) });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, CODEX)).toMatchObject({ status: "bound", startedMessageId: null });
    expect(fake.rpcCalls("start_agent_turn_auto")).toEqual([]);
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

  it("D2a 보안 검토 P1 방어: 실행 kill switch가 꺼져 있으면 되돌려도 턴을 시작하지 않고 대기 메시지를 not_sent/write_gate_closed로 표시한다 (start_agent_turn_auto 0)", async () => {
    const fake = fakeAdmin({
      tables: world({ conversation_messages: [{ id: MSG, user_id: USER, refs: {}, selected: { action_ids: [], context_ids: [] }, delivery_state: "queued", delivery_reason: null }] }),
      rpc: { ...rpc("bound", MSG), mark_agent_message_not_sent_auto: () => ({ status: "not_sent", reason: "write_gate_closed" }) },
    });
    expect(await resumeAgentSessionHere(fake.admin, USER, SESSION, OFF)).toMatchObject({ status: "bound", startedMessageId: null });
    expect(fake.rpcCalls().map((call) => call.target)).toEqual(["resume_agent_session_here", "next_queued_agent_message", "mark_agent_message_not_sent_auto"]);
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
