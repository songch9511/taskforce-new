import { describe, expect, it } from "vitest";

import { conversationWithTargetSchema } from "@/lib/api/contract";

import { createAgentConversation, readConversationTarget } from "./conversations";
import { fakeAdmin } from "./fake-admin";

const USER = "10000000-0000-4000-8000-000000000001";
const OTHER = "20000000-0000-4000-8000-000000000002";
const CONN = "c0000000-0000-4000-8000-000000000001";
const CONN2 = "c0000000-0000-4000-8000-000000000002";
const SESSION = "5e000000-0000-4000-8000-000000000001";
const SESSION2 = "5e000000-0000-4000-8000-000000000002";
const CONTEXT = "c7000000-0000-4000-8000-000000000001";
const CONV = "c1000000-0000-4000-8000-000000000001";
const CODEX = { AGENT_BETA_USER_IDS: USER, CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" };

const conversationRow = (extra: Record<string, unknown> = {}) => ({
  id: CONV, user_id: USER, title: null, context_id: null, created_at: "2026-10-14T00:00:00Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null,
  target_kind: "taskforce", agent_connection_id: null, agent_session_id: null, ...extra,
});
const DEFAULTS = { conversations: { title: null, context_id: null, created_at: "2026-10-14T00:00:00Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null } };
function world(extra: { conversations?: Record<string, unknown>[]; connections?: Record<string, unknown>[]; sessions?: Record<string, unknown>[]; contexts?: Record<string, unknown>[] } = {}) {
  return fakeAdmin({
    defaults: DEFAULTS,
    tables: {
      conversations: extra.conversations ?? [],
      agent_connections: extra.connections ?? [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "active" }, { id: CONN2, user_id: USER, adapter: "agent:codex", status: "active" }],
      agent_sessions: extra.sessions ?? [{ id: SESSION, user_id: USER, connection_id: CONN, status: "bound" }],
      work_contexts: extra.contexts ?? [{ id: CONTEXT, user_id: USER }],
    },
  });
}
const create = (fake: ReturnType<typeof world>, input: Partial<Parameters<typeof createAgentConversation>[2]> = {}, env: Record<string, string> = CODEX) =>
  createAgentConversation(fake.admin, USER, { id: CONV, contextId: null, connectionId: CONN, ...input }, { ...env, MEMORY_ENABLED: "true" });
const writes = (fake: ReturnType<typeof world>) => fake.calls.filter((call) => call.kind === "insert" || call.kind === "upsert" || call.kind === "update");

describe("readConversationTarget", () => {
  it("내 대화의 대상 · 연결 · 세션을 읽는다", async () => {
    const fake = world({ conversations: [conversationRow({ target_kind: "agent", agent_connection_id: CONN, agent_session_id: SESSION })] });
    expect(await readConversationTarget(fake.admin, USER, CONV)).toEqual({ id: CONV, targetKind: "agent", connectionId: CONN, sessionId: SESSION });
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });

  it("taskforce 대화는 연결 · 세션이 null, 없거나 남의 대화는 null", async () => {
    const fake = world({ conversations: [conversationRow(), conversationRow({ id: "c1000000-0000-4000-8000-000000000009", user_id: OTHER })] });
    expect(await readConversationTarget(fake.admin, USER, CONV)).toEqual({ id: CONV, targetKind: "taskforce", connectionId: null, sessionId: null });
    expect(await readConversationTarget(fake.admin, USER, "c1000000-0000-4000-8000-000000000009")).toBeNull();
    expect(await readConversationTarget(fake.admin, USER, "c1000000-0000-4000-8000-0000000000ff")).toBeNull();
  });
});

describe("createAgentConversation (R3 · AC-5 · OD-21)", () => {
  it("연결이 내 것이고 adapter gate가 켜져 있으면 대상 agent로 만든다 (201 created)", async () => {
    const fake = world();
    const result = await create(fake, { title: "Codex 대화" });
    expect(result.status).toBe("created");
    if (result.status !== "created") return;
    expect(conversationWithTargetSchema.parse(result.conversation)).toMatchObject({ id: CONV, target_kind: "agent", agent_connection_id: CONN, agent_session_id: null, title: "Codex 대화" });
    expect(fake.tables.conversations).toHaveLength(1);
    expect(fake.tables.conversations[0]).toMatchObject({ user_id: USER, target_kind: "agent", agent_connection_id: CONN });
  });

  it("세션(같은 연결 · closed 아님)을 함께 받으면 묶어서 만든다", async () => {
    const fake = world();
    const result = await create(fake, { sessionId: SESSION });
    expect(result).toMatchObject({ status: "created", conversation: { agent_session_id: SESSION } });
  });

  it("연결 상태 error는 만들 수 있다 (보내면 not_sent/not_connected)", async () => {
    const fake = world({ connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "error" }] });
    expect((await create(fake)).status).toBe("created");
  });

  it.each([
    ["남의 연결", { connections: [{ id: CONN, user_id: OTHER, adapter: "agent:codex", status: "active" }] }, CODEX],
    ["없는 연결", { connections: [] }, CODEX],
    ["꺼진 adapter", {}, {}],
    ["revoked 연결", { connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "revoked" }] }, CODEX],
    ["registry 밖 adapter", { connections: [{ id: CONN, user_id: USER, adapter: "agent:cursor", status: "active" }] }, CODEX],
    ["다른 연결의 세션", { sessions: [{ id: SESSION, user_id: USER, connection_id: CONN2, status: "bound" }] }, CODEX],
    ["남의 세션", { sessions: [{ id: SESSION, user_id: OTHER, connection_id: CONN, status: "bound" }] }, CODEX],
    ["닫힌 세션", { sessions: [{ id: SESSION, user_id: USER, connection_id: CONN, status: "closed" }] }, CODEX],
    ["없는 세션", { sessions: [] }, CODEX],
  ] as const)("%s: not_found, 대화 · 어떤 행도 쓰지 않는다 (Action · 세션 · run 0)", async (_name, extra, env) => {
    const fake = world(extra as Parameters<typeof world>[0]);
    expect(await create(fake, { sessionId: SESSION }, env as Record<string, string>)).toEqual({ status: "not_found" });
    expect(writes(fake)).toEqual([]);
    expect(fake.tables.conversations).toHaveLength(0);
  });

  it("범위: 기능이 꺼져 있으면 context_off, 내 범위가 아니면 context_not_found, 맞으면 대화에 둔다", async () => {
    const fake = world();
    expect(await createAgentConversation(fake.admin, USER, { id: CONV, contextId: CONTEXT, connectionId: CONN }, CODEX)).toEqual({ status: "context_off" });
    expect(await create(world({ contexts: [] }), { contextId: CONTEXT })).toEqual({ status: "context_not_found" });
    const ok = world();
    expect(await create(ok, { contextId: CONTEXT })).toMatchObject({ status: "created", conversation: { context_id: CONTEXT } });
    expect(writes(fake)).toEqual([]);
  });

  it("같은 id로 같은 대상이면 기존 대화를 그대로 돌려준다 (200 existing, 쓰기 0, 제목 · 범위를 덮지 않는다)", async () => {
    const fake = world({ conversations: [conversationRow({ title: "처음 제목", target_kind: "agent", agent_connection_id: CONN })] });
    const result = await create(fake, { title: "다른 제목", contextId: CONTEXT });
    expect(result).toMatchObject({ status: "existing", conversation: { title: "처음 제목", context_id: null, target_kind: "agent" } });
    expect(writes(fake)).toEqual([]);
  });

  it("요청에 세션이 있어도 기존 대화의 세션이 null이면 같은 대상이다 (첫 전달 때 묶인다)", async () => {
    const fake = world({ conversations: [conversationRow({ target_kind: "agent", agent_connection_id: CONN })] });
    expect(await create(fake, { sessionId: SESSION })).toMatchObject({ status: "existing", conversation: { agent_session_id: null } });
  });

  it.each([
    ["taskforce 대화", conversationRow(), {}],
    ["다른 연결", conversationRow({ target_kind: "agent", agent_connection_id: CONN2 }), {}],
    ["다른 세션", conversationRow({ target_kind: "agent", agent_connection_id: CONN, agent_session_id: SESSION2 }), { sessionId: SESSION }],
  ] as const)("같은 id의 기존 %s이면 target_mismatch (쓰기 0)", async (_name, row, input) => {
    const fake = world({ conversations: [row] });
    expect(await create(fake, input)).toEqual({ status: "target_mismatch" });
    expect(writes(fake)).toEqual([]);
  });

  it("같은 id를 가진 다른 사용자의 대화는 id_taken이다 (내 것인지 구별해 알려 주지 않는다)", async () => {
    const fake = world({ conversations: [conversationRow({ user_id: OTHER })] });
    expect(await create(fake)).toEqual({ status: "id_taken" });
    expect(fake.tables.conversations).toHaveLength(1);
  });

  it("id를 주지 않으면 새 id를 정한다", async () => {
    const fake = world();
    const result = await createAgentConversation(fake.admin, USER, { contextId: null, connectionId: CONN }, CODEX);
    expect(result.status).toBe("created");
    expect(fake.tables.conversations).toHaveLength(1);
  });

  it("동시에 같은 id로 만든 경우(upsert가 중복으로 무시됨): 다시 읽어 같은 대상이면 existing, 다르면 target_mismatch", async () => {
    for (const [raced, expected] of [
      [conversationRow({ target_kind: "agent", agent_connection_id: CONN }), "existing"],
      [conversationRow({ target_kind: "agent", agent_connection_id: CONN2 }), "target_mismatch"],
      [conversationRow({ user_id: OTHER }), "id_taken"],
    ] as const) {
      const tables = { conversations: [] as Record<string, unknown>[], agent_connections: [{ id: CONN, user_id: USER, adapter: "agent:codex", status: "active" }], agent_sessions: [], work_contexts: [] };
      const fake = fakeAdmin({ tables, defaults: DEFAULTS, beforeWrite: ({ op }) => { if (op === "upsert") tables.conversations.push({ ...raced }); } });
      expect((await createAgentConversation(fake.admin, USER, { id: CONV, contextId: null, connectionId: CONN }, CODEX)).status, expected).toBe(expected);
      expect(tables.conversations).toHaveLength(1);
    }
  });
});
