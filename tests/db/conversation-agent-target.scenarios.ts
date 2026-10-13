import { randomUUID } from "node:crypto";

import { describe, expect, it } from "vitest";

import { agentGatewayFixtures, type AgentGatewayDb } from "./agent-gateway-core.scenarios";

// 0.2.0 대화 대상과 에이전트 글 (20261114000000_conversation_agent_target, 구현 계획 D1b): 저장 + SQL 함수만 시험한다 —
// conversations의 대상 열 · 불변 트리거 · 복합 외래키, conversation_messages의 전달 상태 · 외부 사건 id · 대상 일치 백스톱,
// conversation_post_message의 대상별 규칙, conversation_append_agent_message(에이전트 글 저장), conversation_expire_agent_messages(만료),
// coordinator_on_user_message · coordinator_recover_missing(agent 대화는 사건을 만들지 않는다 — T4 · T12). 같은 시나리오를 PGlite(tests/db/conversation-agent-target.test.ts)와
// 실제 Postgres(tests/pg/conversation-agent-target.test.ts)에서 돌린다. 연결 둘이 겹치는 경합(T10)은 실제 Postgres 파일에만 있다.
// B2 대화 v2의 기존 시나리오(tests/db/conversations-v2.scenarios.ts)는 고치지 않고 그대로 통과해야 한다 — 이 파일의 T5는 대상 taskforce의 핵심만 다시 본다.

export type ConversationAgentDb = AgentGatewayDb;
export const D1B_MIGRATION = "20261114000000_conversation_agent_target.sql";

const NO_SELECTION = { action_ids: [], run_ids: [], artifact_ids: [] };
const DAY_MS = 24 * 60 * 60 * 1000;

type Post = { status: string; message_id: string | null; seq: number | null; reply_id: string | null };
type Append = { status: string; message_id: string | null; seq: number | null };

/** 에러 메시지가 정규식과 맞는지 (PGlite와 실제 Postgres 모두 같은 문구) */
const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 */
export function conversationAgentFixtures(db: () => ConversationAgentDb) {
  const g = agentGatewayFixtures(db);

  const f = {
    ...g,
    /** 대상 agent 대화 (연결 필수, 세션은 첫 전달 때 묶인다) */
    agentConversation: (userId: string, connectionId: string, sessionId: string | null = null) =>
      g.insertRow("conversations", { user_id: userId, target_kind: "agent", agent_connection_id: connectionId, agent_session_id: sessionId }),
    post: async (userId: string, conversationId: string, clientId: string, text: string, selected: Record<string, unknown> = NO_SELECTION) =>
      (await g.one(`select * from public.conversation_post_message($1, $2, $3, $4, $5::jsonb, 75)`, [userId, conversationId, clientId, text, JSON.stringify(selected)])) as Post,
    append: async (userId: string, conversationId: string, taskId: string, turnSeq: number | null, eventId: string, text: string, kind = "reply") =>
      (await g.one(`select * from public.conversation_append_agent_message($1, $2, $3, $4, $5, $6, $7)`, [userId, conversationId, taskId, turnSeq, eventId, text, kind])) as Append,
    expire: async (now: Date | string) => Number((await g.one(`select public.conversation_expire_agent_messages($1::timestamptz) as n`, [now instanceof Date ? now.toISOString() : now])).n),
    /** 메시지 한 줄 (전달 · 외부 사건 열 포함) */
    msg: (id: string) =>
      g.one(
        `select id, seq, role, text, reply_to, client_message_id, reply_lease_until, delivery_state, delivery_reason, delivery_expires_at, external_event_id, content, created_at
           from public.conversation_messages where id = $1`,
        [id],
      ),
    messages: (conversationId: string) =>
      g.q(`select id, seq, role, text, delivery_state, external_event_id from public.conversation_messages where conversation_id = $1 order by seq`, [conversationId]),
    /** 코디네이터 사건함의 user_message 수 (트리거가 적재한다) */
    userMessageEvents: (userId: string) => g.count(`select 1 from public.inbox_events where user_id = $1 and type = 'user_message'`, [userId]),
    /** 사용자 한 명의 에이전트 세계: bridge → 연결 → 세션 → 대화(세션에 묶임) → 대화 run → 사용자 메시지 하나(queued) → 그 턴의 작업(running) */
    async agentWorld() {
      const user = await g.user();
      const action = await g.action(user);
      const bridge = await g.bridge(user);
      const connection = await g.agentConnection(user, bridge);
      const session = await g.session(user, connection, { bound_action_id: action });
      const conversation = await f.agentConversation(user, connection, session);
      const run = await g.agentRun(user, action, { agent_session_id: session });
      const sent = await f.post(user, conversation, randomUUID(), "이어서 해 줘");
      const message = String(sent.message_id);
      const task = await g.task(user, run, session, { message_id: message, turn_seq: 1, state: "running" });
      return { user, action, bridge, connection, session, conversation, run, message, task };
    },
  };
  return f;
}

export function conversationAgentTargetTests(db: () => ConversationAgentDb) {
  const f = conversationAgentFixtures(db);
  const q = f.q;

  // ───────────────────────── 0) 열의 모양 ─────────────────────────
  describe("열의 모양 (저장 계약)", () => {
    it("새 열: 형 · null 허용 · 기본값", async () => {
      const rows = await q(
        `select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns
          where table_schema = 'public' and (
            (table_name = 'conversations' and column_name in ('target_kind', 'agent_connection_id', 'agent_session_id'))
            or (table_name = 'conversation_messages' and column_name in ('delivery_state', 'delivery_reason', 'delivery_expires_at', 'external_event_id')))
          order by table_name, column_name`,
      );
      expect(rows.map((r) => `${r.table_name}.${r.column_name} ${r.data_type} ${r.is_nullable === "YES" ? "null" : "not null"}${r.column_default ? ` = ${r.column_default}` : ""}`)).toEqual([
        "conversation_messages.delivery_expires_at timestamp with time zone null",
        "conversation_messages.delivery_reason text null",
        "conversation_messages.delivery_state text null",
        "conversation_messages.external_event_id text null",
        "conversations.agent_connection_id uuid null",
        "conversations.agent_session_id uuid null",
        "conversations.target_kind text not null = 'taskforce'::text",
      ]);
    });

    it("지금 코드가 만든 대화 · 메시지는 새 열이 기본값이다: 대상 taskforce, 연결 · 세션 없음, 전달 · 외부 사건 열 null", async () => {
      const user = await f.user();
      const conversation = await f.conversation(user);
      expect(await f.one(`select target_kind, agent_connection_id, agent_session_id from public.conversations where id = $1`, [conversation])).toEqual({
        target_kind: "taskforce",
        agent_connection_id: null,
        agent_session_id: null,
      });
      const message = await f.message(user, conversation);
      expect(await f.one(`select delivery_state, delivery_reason, delivery_expires_at, external_event_id from public.conversation_messages where id = $1`, [message])).toEqual({
        delivery_state: null,
        delivery_reason: null,
        delivery_expires_at: null,
        external_event_id: null,
      });
    });

    it("인덱스: 외부 사건 id는 대화마다 유일(부분), 보류 조회 · 만료 sweep · 세션 조회는 부분 인덱스", async () => {
      const rows = await q(
        `select indexname, indexdef from pg_indexes where schemaname = 'public' and indexname = any ($1) order by indexname`,
        [[
          "conversation_messages_external_event_key",
          "conversation_messages_delivery_pending_idx",
          "conversation_messages_delivery_expiry_idx",
          "conversations_agent_session_idx",
          "conversations_agent_connection_idx",
        ]],
      );
      const defs = Object.fromEntries(rows.map((r) => [String(r.indexname), String(r.indexdef).replace(/\s+/g, " ")]));
      expect(defs.conversation_messages_external_event_key).toMatch(/CREATE UNIQUE INDEX .* ON public\.conversation_messages USING btree \(conversation_id, external_event_id\) WHERE \(external_event_id IS NOT NULL\)/);
      expect(defs.conversation_messages_delivery_pending_idx).toMatch(/USING btree \(conversation_id, seq\) WHERE \(delivery_state = ANY \(ARRAY\['queued'::text, 'not_sent'::text\]\)\)/);
      expect(defs.conversation_messages_delivery_expiry_idx).toMatch(/USING btree \(delivery_expires_at\) WHERE \(delivery_state = ANY \(ARRAY\['queued'::text, 'not_sent'::text\]\)\)/);
      expect(defs.conversations_agent_session_idx).toMatch(/USING btree \(agent_session_id\) WHERE \(agent_session_id IS NOT NULL\)/);
      expect(defs.conversations_agent_connection_idx).toMatch(/USING btree \(agent_connection_id\) WHERE \(agent_connection_id IS NOT NULL\)/);
    });
  });

  // ───────────────────────── T1) CHECK · 트리거 ─────────────────────────
  describe("T1 대상 CHECK · 불변 트리거", () => {
    it("대상 값은 taskforce · agent뿐이고, agent는 연결이 필수이며 taskforce는 연결 · 세션이 없다", async () => {
      const w = await f.agentWorld();
      for (const bad of ["Agent", "claude", "", "taskforce "]) {
        await rejects(f.insertRow("conversations", { user_id: w.user, target_kind: bad }), /conversations_target_kind_check/);
      }
      // agent인데 연결 null
      await rejects(f.insertRow("conversations", { user_id: w.user, target_kind: "agent" }), /conversations_agent_target_check/);
      await rejects(f.insertRow("conversations", { user_id: w.user, target_kind: "agent", agent_connection_id: null, agent_session_id: w.session }), /conversations_agent_target_check/);
      // taskforce인데 연결 있음
      await rejects(f.insertRow("conversations", { user_id: w.user, target_kind: "taskforce", agent_connection_id: w.connection }), /conversations_agent_target_check/);
      // taskforce인데 세션 있음 (연결 없이)
      await rejects(f.insertRow("conversations", { user_id: w.user, target_kind: "taskforce", agent_session_id: w.session }), /conversations_taskforce_no_session/);
      // 되는 것: agent + 연결 (세션은 null 또는 값), taskforce
      await f.agentConversation(w.user, w.connection);
      await f.agentConversation(w.user, w.connection, w.session);
      await f.insertRow("conversations", { user_id: w.user, target_kind: "taskforce" });
      await f.insertRow("conversations", { user_id: w.user });
    });

    it("대상 · 연결은 만든 뒤 바뀌지 않는다: target_kind · agent_connection_id 변경 거절 (같은 값으로 쓰는 갱신은 된다)", async () => {
      const w = await f.agentWorld();
      const other = await f.agentConnection(w.user);
      const taskforce = await f.conversation(w.user);
      const unbound = await f.agentConversation(w.user, w.connection);
      // agent → taskforce, 연결을 같이 비워도
      await rejects(f.updateRow("conversations", unbound, { target_kind: "taskforce" }), /conversations_agent_target_guard: target_kind/);
      await rejects(f.updateRow("conversations", unbound, { target_kind: "taskforce", agent_connection_id: null }), /conversations_agent_target_guard: target_kind/);
      // taskforce → agent, 연결을 같이 줘도
      await rejects(f.updateRow("conversations", taskforce, { target_kind: "agent", agent_connection_id: w.connection }), /conversations_agent_target_guard: target_kind/);
      // 연결 바꾸기 (같은 사용자의 다른 연결 · taskforce 대화에 연결 붙이기 · 지우기)
      await rejects(f.updateRow("conversations", unbound, { agent_connection_id: other }), /conversations_agent_target_guard: agent_connection_id/);
      await rejects(f.updateRow("conversations", unbound, { agent_connection_id: null }), /conversations_agent_target_guard: agent_connection_id/);
      await rejects(f.updateRow("conversations", taskforce, { agent_connection_id: w.connection }), /conversations_agent_target_guard: agent_connection_id/);
      expect(await f.one(`select target_kind, agent_connection_id from public.conversations where id = $1`, [unbound])).toEqual({ target_kind: "agent", agent_connection_id: w.connection });
      expect(await f.one(`select target_kind, agent_connection_id from public.conversations where id = $1`, [taskforce])).toEqual({ target_kind: "taskforce", agent_connection_id: null });
      // 같은 값으로 쓰는 갱신 · 다른 열 갱신은 된다
      await f.updateRow("conversations", unbound, { target_kind: "agent", agent_connection_id: w.connection, title: "제목" });
      await f.updateRow("conversations", taskforce, { archived_at: new Date().toISOString() });
    });

    it("세션은 null → 값으로 한 번만 묶인다: 값 → 다른 값 거절, 같은 값은 된다, taskforce 대화에는 묶이지 않는다", async () => {
      const w = await f.agentWorld();
      const second = await f.session(w.user, w.connection);
      const unbound = await f.agentConversation(w.user, w.connection);
      await f.updateRow("conversations", unbound, { agent_session_id: w.session }); // null → 값
      expect(await f.one(`select agent_session_id from public.conversations where id = $1`, [unbound])).toEqual({ agent_session_id: w.session });
      await rejects(f.updateRow("conversations", unbound, { agent_session_id: second }), /conversations_agent_target_guard: agent_session_id/); // 값 → 다른 값
      await f.updateRow("conversations", unbound, { agent_session_id: w.session }); // 같은 값
      expect(await f.one(`select agent_session_id from public.conversations where id = $1`, [unbound])).toEqual({ agent_session_id: w.session });
      // taskforce 대화에 묶으려 하면 CHECK
      const taskforce = await f.conversation(w.user);
      await rejects(f.updateRow("conversations", taskforce, { agent_session_id: w.session }), /conversations_taskforce_no_session/);
    });

    it("세션을 지우면 대화의 agent_session_id만 비고 대화 · 연결은 남는다 (set null은 트리거가 막지 않는다). 비운 뒤에는 다시 묶을 수 있다", async () => {
      const w = await f.agentWorld();
      await q(`delete from public.agent_sessions where id = $1`, [w.session]);
      expect(await f.one(`select target_kind, agent_connection_id, agent_session_id from public.conversations where id = $1`, [w.conversation])).toEqual({
        target_kind: "agent",
        agent_connection_id: w.connection,
        agent_session_id: null,
      });
      const next = await f.session(w.user, w.connection);
      await f.updateRow("conversations", w.conversation, { agent_session_id: next });
      expect(await f.one(`select agent_session_id from public.conversations where id = $1`, [w.conversation])).toEqual({ agent_session_id: next });
    });
  });

  // ───────────────────────── T2) 복합 외래키 ─────────────────────────
  describe("T2 복합 외래키: 남의 연결 · 세션, 없는 id는 가리키지 못하고 내 것과 null은 된다", () => {
    it("conversations.agent_connection_id · agent_session_id", async () => {
      const [alice, bob] = [await f.agentWorld(), await f.agentWorld()];
      await rejects(f.agentConversation(alice.user, bob.connection), /conversations_agent_connection_fkey/);
      await rejects(f.agentConversation(alice.user, randomUUID()), /conversations_agent_connection_fkey/);
      await rejects(f.agentConversation(alice.user, alice.connection, bob.session), /conversations_agent_session_fkey/);
      await rejects(f.agentConversation(alice.user, alice.connection, randomUUID()), /conversations_agent_session_fkey/);
      // 갱신으로 묶어도 같다 (null → 값은 트리거가 허용하고 외래키가 막는다)
      const unbound = await f.agentConversation(alice.user, alice.connection);
      await rejects(f.updateRow("conversations", unbound, { agent_session_id: bob.session }), /conversations_agent_session_fkey/);
      await rejects(f.updateRow("conversations", unbound, { agent_session_id: randomUUID() }), /conversations_agent_session_fkey/);
      expect(await f.one(`select agent_session_id from public.conversations where id = $1`, [unbound])).toEqual({ agent_session_id: null });
      // 내 것은 된다
      await f.updateRow("conversations", unbound, { agent_session_id: alice.session });
    });
  });

  // ───────────────────────── T3) RLS · 권한 ─────────────────────────
  describe("T3 RLS · 권한: 앱은 새 열을 읽기만 하고 새 함수를 부르지 못한다", () => {
    it("자기 대화 · 메시지만 읽고(새 열 포함) 다른 사용자의 행은 0행이다. 대화 · 메시지의 insert · update · delete는 권한이 없다", async () => {
      const [alice, bob] = [await f.agentWorld(), await f.agentWorld()];
      await db().asUser(alice.user, async () => {
        expect(await q(`select id, target_kind, agent_connection_id, agent_session_id from public.conversations`)).toEqual([
          { id: alice.conversation, target_kind: "agent", agent_connection_id: alice.connection, agent_session_id: alice.session },
        ]);
        expect(await q(`select id, delivery_state, external_event_id from public.conversation_messages`)).toEqual([{ id: alice.message, delivery_state: "queued", external_event_id: null }]);
        expect(await q(`select id from public.conversations where id = $1`, [bob.conversation])).toEqual([]);
        expect(await q(`select id from public.conversation_messages where id = $1`, [bob.message])).toEqual([]);
        // 새 열을 쓸 수 없다
        await rejects(q(`update public.conversations set target_kind = 'taskforce' where id = $1`, [alice.conversation]), /permission denied/);
        await rejects(q(`update public.conversations set agent_session_id = null where id = $1`, [alice.conversation]), /permission denied/);
        await rejects(q(`update public.conversations set agent_connection_id = $2 where id = $1`, [alice.conversation, bob.connection]), /permission denied/);
        await rejects(q(`update public.conversation_messages set delivery_state = 'cancelled' where id = $1`, [alice.message]), /permission denied/);
        await rejects(q(`update public.conversation_messages set delivery_expires_at = now() where id = $1`, [alice.message]), /permission denied/);
        await rejects(q(`update public.conversation_messages set external_event_id = 'evt-x' where id = $1`, [alice.message]), /permission denied/);
        await rejects(q(`insert into public.conversations (user_id, target_kind, agent_connection_id) values ($1, 'agent', $2)`, [alice.user, alice.connection]), /permission denied/);
        await rejects(q(`delete from public.conversation_messages where id = $1`, [alice.message]), /permission denied/);
      });
      await db().asUser(bob.user, async () => {
        expect(await q(`select id from public.conversations where id = $1`, [alice.conversation])).toEqual([]);
        expect(await q(`select id from public.conversation_messages where id = $1`, [alice.message])).toEqual([]);
      });
      // 거절된 쓰기는 아무것도 바꾸지 않았다
      expect(await f.one(`select delivery_state, external_event_id from public.conversation_messages where id = $1`, [alice.message])).toEqual({ delivery_state: "queued", external_event_id: null });
      expect(await f.one(`select target_kind, agent_session_id from public.conversations where id = $1`, [alice.conversation])).toEqual({ target_kind: "agent", agent_session_id: alice.session });
    });

    it("서버 함수는 service_role만 실행한다: 새 함수 둘 · 교체한 post_message는 앱 · 익명이 실행하지 못한다 (public에도 권한이 없다)", async () => {
      const callable = [
        "public.conversation_append_agent_message(uuid, uuid, uuid, integer, text, text, text)",
        "public.conversation_expire_agent_messages(timestamptz)",
        "public.conversation_post_message(uuid, uuid, uuid, text, jsonb, integer)",
        "public.coordinator_recover_missing(integer, integer)", // 교체했지만 권한은 그대로: service_role만
      ];
      const hasExecute = async (role: string, signature: string) => (await f.one(`select has_function_privilege($1, $2::regprocedure, 'execute') as ok`, [role, signature])).ok;
      const publicHasExecute = async (signature: string) =>
        (await f.one(`select exists (select 1 from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where p.oid = $1::regprocedure and a.grantee = 0) as ok`, [signature])).ok;
      for (const signature of callable) {
        expect(await hasExecute("service_role", signature), `service_role ${signature}`).toBe(true);
        expect(await hasExecute("authenticated", signature), `authenticated ${signature}`).toBe(false);
        expect(await hasExecute("anon", signature), `anon ${signature}`).toBe(false);
        expect(await publicHasExecute(signature), `public ${signature}`).toBe(false);
      }
      // 트리거 함수도 앱이 직접 부르지 못한다. 코디네이터 트리거는 교체 뒤에도 service_role까지 막힌 그대로다
      for (const signature of ["public.conversations_agent_target_guard()", "public.conversation_messages_target_guard()", "public.coordinator_on_user_message()"]) {
        expect(await hasExecute("authenticated", signature), `authenticated ${signature}`).toBe(false);
        expect(await hasExecute("anon", signature), `anon ${signature}`).toBe(false);
        expect(await publicHasExecute(signature), `public ${signature}`).toBe(false);
      }
      expect(await hasExecute("service_role", "public.coordinator_on_user_message()")).toBe(false);

      // 교체한 함수의 속성(실행 권한 모델 · search_path)은 그대로다: 코디네이터 트리거만 security definer(소유자 권한), 나머지는 호출자 권한
      const attributes = await q(
        `select proname, prosecdef, proconfig::text as config from pg_proc
          where pronamespace = 'public'::regnamespace and proname = any ($1) order by proname`,
        [[
          "conversation_append_agent_message",
          "conversation_expire_agent_messages",
          "conversation_messages_target_guard",
          "conversation_post_message",
          "conversations_agent_target_guard",
          "coordinator_on_user_message",
          "coordinator_recover_missing",
        ]],
      );
      expect(attributes.map((r) => `${r.proname} ${r.prosecdef ? "definer" : "invoker"} ${r.config}`)).toEqual([
        'conversation_append_agent_message invoker {"search_path=\\"\\""}',
        'conversation_expire_agent_messages invoker {"search_path=\\"\\""}',
        'conversation_messages_target_guard invoker {"search_path=\\"\\""}',
        'conversation_post_message invoker {"search_path=\\"\\""}',
        'conversations_agent_target_guard invoker {"search_path=\\"\\""}',
        'coordinator_on_user_message definer {"search_path=\\"\\""}',
        'coordinator_recover_missing invoker {"search_path=\\"\\""}',
      ]);

      // 실제 호출도 거절된다
      const w = await f.agentWorld();
      await db().asUser(w.user, async () => {
        await rejects(q(`select * from public.conversation_append_agent_message($1, $2, $3, 1, 'evt-1', '글', 'reply')`, [w.user, w.conversation, w.task]), /permission denied for function/);
        await rejects(q(`select public.conversation_expire_agent_messages(now())`), /permission denied for function/);
        await rejects(q(`select * from public.conversation_post_message($1, $2, $3, '글', '{}'::jsonb, 75)`, [w.user, w.conversation, randomUUID()]), /permission denied for function/);
      });
      await q(`set role anon`);
      try {
        await rejects(q(`select public.conversation_expire_agent_messages(now())`), /permission denied for function/);
        await rejects(q(`select * from public.conversation_append_agent_message($1, $2, $3, 1, 'evt-1', '글', 'reply')`, [w.user, w.conversation, w.task]), /permission denied for function/);
      } finally {
        await q(`reset role`);
      }
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [w.conversation])).toBe(1);
    });
  });

  // ───────────────────────── T4) post_message (agent) ─────────────────────────
  describe("T4 conversation_post_message — 대상 agent", () => {
    it("새 메시지: queued · 만료 24시간 · 처리 표시(lease) 없음 · 코디네이터 사건 0 · last_message_at 갱신", async () => {
      const user = await f.user();
      const conversation = await f.agentConversation(user, await f.agentConnection(user));
      const clientId = randomUUID();
      const first = await f.post(user, conversation, clientId, "이어서 해 줘");
      expect(first).toMatchObject({ status: "created", seq: 1, reply_id: null });
      const row = await f.msg(String(first.message_id));
      expect(row).toMatchObject({
        role: "user",
        text: "이어서 해 줘",
        client_message_id: clientId,
        reply_lease_until: null,
        reply_to: null,
        delivery_state: "queued",
        delivery_reason: null,
        external_event_id: null,
      });
      expect((await f.one(`select delivery_expires_at - created_at = interval '24 hours' as ok from public.conversation_messages where id = $1`, [first.message_id])).ok).toBe(true);
      expect(await f.userMessageEvents(user)).toBe(0);
      expect((await f.one(`select last_message_at is not null as ok from public.conversations where id = $1`, [conversation])).ok).toBe(true);
      // seq는 이어서 센다
      expect(await f.post(user, conversation, randomUUID(), "둘째")).toMatchObject({ status: "created", seq: 2 });
      expect(await f.userMessageEvents(user)).toBe(0);
    });

    it("같은 제출은 exists(기존 id · seq)이고 행을 고치지 않는다. 글이 다르면 mismatch, 고른 대상이 다르면 refs_mismatch", async () => {
      const user = await f.user();
      const conversation = await f.agentConversation(user, await f.agentConnection(user));
      const clientId = randomUUID();
      const first = await f.post(user, conversation, clientId, "이어서 해 줘");
      const before = await f.msg(String(first.message_id));
      for (let i = 0; i < 3; i++) {
        expect(await f.post(user, conversation, clientId, "이어서 해 줘")).toEqual({ status: "exists", message_id: first.message_id, seq: 1, reply_id: null });
      }
      expect(await f.msg(String(first.message_id))).toEqual(before);
      expect(await f.post(user, conversation, clientId, "다른 글")).toEqual({ status: "mismatch", message_id: first.message_id, seq: 1, reply_id: null });
      expect(await f.post(user, conversation, clientId, "이어서 해 줘", { action_ids: [randomUUID()], run_ids: [], artifact_ids: [] })).toMatchObject({
        status: "refs_mismatch",
        message_id: first.message_id,
        seq: 1,
      });
      expect(await f.msg(String(first.message_id))).toEqual(before);
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [conversation])).toBe(1);
    });

    it("뒤에 새 메시지가 있어도 앞 메시지의 재제출은 exists이다 (B2의 stale 규칙을 쓰지 않는다). 전달 상태가 바뀐 뒤에도 같다", async () => {
      const user = await f.user();
      const conversation = await f.agentConversation(user, await f.agentConnection(user));
      const [c1, c2] = [randomUUID(), randomUUID()];
      const first = await f.post(user, conversation, c1, "하나");
      const second = await f.post(user, conversation, c2, "둘");
      expect(second).toMatchObject({ status: "created", seq: 2 });
      expect(await f.post(user, conversation, c1, "하나")).toEqual({ status: "exists", message_id: first.message_id, seq: 1, reply_id: null });
      expect(await f.post(user, conversation, c2, "둘")).toEqual({ status: "exists", message_id: second.message_id, seq: 2, reply_id: null });
      // 만료 · 취소 · 전달됨으로 바뀐 메시지도 재제출이 상태를 되돌리지 않는다
      for (const state of ["expired", "cancelled", "dispatched", "not_sent"]) {
        await q(`update public.conversation_messages set delivery_state = $2 where id = $1`, [first.message_id, state]);
        const before = await f.msg(String(first.message_id));
        expect(await f.post(user, conversation, c1, "하나")).toMatchObject({ status: "exists", message_id: first.message_id });
        expect(await f.msg(String(first.message_id)), state).toEqual(before);
      }
    });

    it("없는 · 남의 대화는 not_found이고 아무것도 쓰지 않는다. 잘못된 lease 초는 그대로 22023", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const aliceConversation = await f.agentConversation(alice, await f.agentConnection(alice));
      expect(await f.post(bob, aliceConversation, randomUUID(), "글")).toEqual({ status: "not_found", message_id: null, seq: null, reply_id: null });
      expect(await f.post(alice, randomUUID(), randomUUID(), "글")).toMatchObject({ status: "not_found" });
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [aliceConversation])).toBe(0);
      for (const seconds of [0, 601, -1]) {
        await rejects(q(`select * from public.conversation_post_message($1, $2, $3, '글', '{}'::jsonb, $4)`, [alice, aliceConversation, randomUUID(), seconds]), /lease seconds out of range/);
      }
    });
  });

  // ───────────────────────── T5) post_message (taskforce) ─────────────────────────
  describe("T5 conversation_post_message — 대상 taskforce는 그대로다 (B2 시나리오: tests/db/conversations-v2.scenarios.ts 무수정)", () => {
    it("created(lease 있음 · 전달 열 null) · in_progress · stale · retry, 코디네이터 사건 1", async () => {
      const user = await f.user();
      const conversation = await f.conversation(user);
      const [c1, c2] = [randomUUID(), randomUUID()];
      const first = await f.post(user, conversation, c1, "하나");
      expect(first).toMatchObject({ status: "created", seq: 1, reply_id: null });
      const row = await f.msg(String(first.message_id));
      expect(row).toMatchObject({ delivery_state: null, delivery_reason: null, delivery_expires_at: null, external_event_id: null });
      expect((await f.one(`select reply_lease_until > now() as ok from public.conversation_messages where id = $1`, [first.message_id])).ok).toBe(true);
      expect(await f.userMessageEvents(user)).toBe(1);
      expect((await f.one(`select refs from public.inbox_events where user_id = $1 and type = 'user_message'`, [user])).refs).toEqual({ conversation_id: conversation, message_id: first.message_id });
      // 처리 중
      expect(await f.post(user, conversation, c1, "하나")).toEqual({ status: "in_progress", message_id: first.message_id, seq: 1, reply_id: null });
      // 처리 표시가 풀리면 다시 처리
      await f.q(`select public.conversation_release_lease($1, $2)`, [user, first.message_id]);
      expect(await f.post(user, conversation, c1, "하나")).toMatchObject({ status: "retry", message_id: first.message_id });
      // 뒤에 새 사용자 메시지가 있으면 stale
      const second = await f.post(user, conversation, c2, "둘");
      expect(second).toMatchObject({ status: "created", seq: 2 });
      expect(await f.userMessageEvents(user)).toBe(2);
      expect(await f.post(user, conversation, c1, "하나")).toEqual({ status: "stale", message_id: first.message_id, seq: 1, reply_id: null });
      // 글 · 대상 불일치 판정도 그대로
      expect(await f.post(user, conversation, c1, "다른 글")).toMatchObject({ status: "mismatch" });
    });
  });

  // ───────────────────────── T6) 대상 일치 백스톱 · 제약 ─────────────────────────
  describe("T6 대상 일치 백스톱 (conversation_messages 트리거) · 새 CHECK", () => {
    const insertMessage = (user: string, conversation: string, seq: number, role: string, o: Record<string, unknown> = {}) =>
      f.insertRow("conversation_messages", {
        user_id: user,
        conversation_id: conversation,
        seq,
        role,
        ...(role === "user" ? { client_message_id: randomUUID(), text: "글" } : {}),
        ...o,
      });

    it("agent 대화: 사용자 메시지는 delivery_state가 있어야 하고, reply_to가 있는 assistant 행은 쓰지 못한다 (Taskforce 모델 답은 agent 대화에 쓰지 않는다)", async () => {
      const w = await f.agentWorld();
      await rejects(insertMessage(w.user, w.conversation, 10, "user"), /conversation_messages_target_guard: .*delivery_state/);
      await rejects(insertMessage(w.user, w.conversation, 10, "user", { delivery_state: null }), /conversation_messages_target_guard: .*delivery_state/);
      await rejects(insertMessage(w.user, w.conversation, 10, "assistant", { reply_to: w.message, text: "답" }), /conversation_messages_target_guard: .*reply_to/);
      // 갱신으로 비워도 같다
      await rejects(q(`update public.conversation_messages set delivery_state = null where id = $1`, [w.message]), /conversation_messages_target_guard: .*delivery_state/);
      await rejects(q(`update public.conversation_messages set role = 'assistant', reply_to = id where id = $1`, [w.message]), /conversation_messages_target_guard|conversation_messages_reply_not_self/);
      // 되는 것: 전달 상태가 있는 사용자 메시지, reply_to 없는 assistant · event
      await insertMessage(w.user, w.conversation, 10, "user", { delivery_state: "not_sent", delivery_reason: "sign_in_needed" });
      const agentReply = await insertMessage(w.user, w.conversation, 11, "assistant", { text: "에이전트 답", external_event_id: "evt-a" });
      await insertMessage(w.user, w.conversation, 12, "event", { text: "" });
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [w.conversation])).toBe(4);
      // 한 열만 고치는 갱신도 백스톱에 걸린다 (갱신 열 목록의 각 열): reply_to만 붙이기, role만 바꾸기
      await rejects(q(`update public.conversation_messages set reply_to = $2 where id = $1`, [agentReply, w.message]), /conversation_messages_target_guard: .*reply_to/);
      await rejects(q(`update public.conversation_messages set role = 'user' where id = $1`, [agentReply]), /conversation_messages_target_guard: .*delivery_state/);
      expect(await f.one(`select role, reply_to from public.conversation_messages where id = $1`, [agentReply])).toEqual({ role: "assistant", reply_to: null });
    });

    it("B2의 답 쓰기(conversation_finish_turn)는 agent 대화의 사용자 메시지에 답을 쓰지 못하고 아무것도 남기지 않는다", async () => {
      const w = await f.agentWorld();
      await rejects(q(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [w.user, w.message, JSON.stringify({ reply: { text: "모델 답" } })]), /conversation_messages_target_guard: .*reply_to/);
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [w.conversation])).toBe(1);
      expect(await f.one(`select intent, delivery_state from public.conversation_messages where id = $1`, [w.message])).toEqual({ intent: null, delivery_state: "queued" });
    });

    it("taskforce 대화: delivery_state · delivery_expires_at · external_event_id는 null이어야 한다 (넣기 · 갱신 모두)", async () => {
      const user = await f.user();
      const conversation = await f.conversation(user);
      const user1 = await insertMessage(user, conversation, 1, "user");
      const assistant = await insertMessage(user, conversation, 2, "assistant", { text: "답" });
      const guard = /conversation_messages_target_guard: .*taskforce/;
      await rejects(insertMessage(user, conversation, 3, "user", { delivery_state: "queued" }), guard);
      await rejects(insertMessage(user, conversation, 3, "user", { delivery_expires_at: new Date(Date.now() + DAY_MS).toISOString() }), guard);
      await rejects(insertMessage(user, conversation, 3, "assistant", { external_event_id: "evt-1" }), guard);
      await rejects(insertMessage(user, conversation, 3, "event", { external_event_id: "evt-1" }), guard);
      await rejects(f.updateRow("conversation_messages", user1, { delivery_state: "queued" }), guard);
      await rejects(f.updateRow("conversation_messages", user1, { delivery_expires_at: new Date().toISOString() }), guard);
      await rejects(f.updateRow("conversation_messages", assistant, { external_event_id: "evt-1" }), guard);
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [conversation])).toBe(2);
      // 되는 것: 전달 열이 모두 null인 행 (기존 B2 경로)
      await insertMessage(user, conversation, 3, "user");
      await insertMessage(user, conversation, 4, "assistant", { text: "답", reply_to: user1 });
    });

    it("CHECK: delivery_state 값 · delivery_reason 모양 · 역할 제한 · external_event_id 길이와 역할", async () => {
      const w = await f.agentWorld();
      let seq = 100; // 성공한 행마다 새 seq (거절된 행은 seq를 쓰지 않지만 단순하게 매번 올린다)
      const put = (role: string, o: Record<string, unknown>) => insertMessage(w.user, w.conversation, seq++, role, o);
      for (const bad of ["sent", "Queued", "", "accepted"]) await rejects(put("user", { delivery_state: bad }), /conversation_messages_delivery_state_check/);
      for (const good of ["queued", "not_sent", "dispatched", "expired", "cancelled"]) await put("user", { delivery_state: good });
      // reason: 소문자 시작 · 소문자 숫자 밑줄 · 64자 이하, reason이 허용되는 상태에서만
      for (const bad of ["Bad Reason", "1abc", "", "_x", "a-b", "a".repeat(65), "한글"]) {
        await rejects(put("user", { delivery_state: "not_sent", delivery_reason: bad }), /conversation_messages_delivery_reason_check/);
      }
      for (const good of ["sign_in_needed", "a", `a${"b".repeat(63)}`, "usage_limited", "session_external"]) {
        await put("user", { delivery_state: "queued", delivery_reason: good });
      }
      await rejects(put("user", { delivery_state: "dispatched", delivery_reason: "sign_in_needed" }), /conversation_messages_delivery_reason_state/);
      await put("user", { delivery_state: "not_sent", delivery_reason: "sign_in_needed" });
      await put("user", { delivery_state: "expired", delivery_reason: "sign_in_needed" });
      await put("user", { delivery_state: "cancelled", delivery_reason: "x" });
      // 전달 상태 없이 reason만 있는 행은 없다
      await rejects(put("assistant", { text: "답", delivery_reason: "sign_in_needed" }), /conversation_messages_delivery_reason_state/);
      // delivery_state는 사용자 메시지에만
      await rejects(put("assistant", { text: "답", delivery_state: "queued" }), /conversation_messages_delivery_role/);
      await rejects(put("event", { delivery_state: "queued" }), /conversation_messages_delivery_role/);
      // external_event_id: 1–200자, assistant · event에만
      for (const bad of ["", "x".repeat(201)]) await rejects(put("assistant", { text: "답", external_event_id: bad }), /conversation_messages_external_event_id_check/);
      await rejects(put("user", { delivery_state: "queued", external_event_id: "evt-u" }), /conversation_messages_external_event_role/);
      await put("assistant", { text: "답", external_event_id: "x" });
      await put("event", { external_event_id: "y".repeat(200) });
    });

    it("external_event_id는 대화마다 한 번만이다: 같은 대화 두 번은 거절, 다른 대화는 된다 (null은 여러 번)", async () => {
      const w = await f.agentWorld();
      const otherConversation = await f.agentConversation(w.user, w.connection, w.session);
      await f.insertRow("conversation_messages", { user_id: w.user, conversation_id: w.conversation, seq: 30, role: "assistant", text: "a", external_event_id: "evt-dup" });
      await rejects(
        f.insertRow("conversation_messages", { user_id: w.user, conversation_id: w.conversation, seq: 31, role: "assistant", text: "b", external_event_id: "evt-dup" }),
        /conversation_messages_external_event_key/,
      );
      await f.insertRow("conversation_messages", { user_id: w.user, conversation_id: otherConversation, seq: 1, role: "assistant", text: "c", external_event_id: "evt-dup" });
      await f.insertRow("conversation_messages", { user_id: w.user, conversation_id: w.conversation, seq: 31, role: "assistant", text: "d" });
      await f.insertRow("conversation_messages", { user_id: w.user, conversation_id: w.conversation, seq: 32, role: "assistant", text: "e" });
    });
  });

  // ───────────────────────── T7) append ─────────────────────────
  describe("T7 conversation_append_agent_message", () => {
    it("reply · question · event: seq · role · content.author.adapter · turn_seq · kind, reply_to 없음, 대화 last_message_at 갱신", async () => {
      const w = await f.agentWorld();
      await q(`update public.conversations set last_message_at = '2020-01-01T00:00:00Z' where id = $1`, [w.conversation]);
      const reply = await f.append(w.user, w.conversation, w.task, 1, "evt-reply", "고쳤어요", "reply");
      expect(reply).toMatchObject({ status: "created", seq: 2 });
      expect((await f.one(`select last_message_at > '2021-01-01' as ok from public.conversations where id = $1`, [w.conversation])).ok).toBe(true);
      expect(await f.msg(String(reply.message_id))).toMatchObject({
        role: "assistant",
        text: "고쳤어요",
        reply_to: null,
        client_message_id: null,
        reply_lease_until: null,
        delivery_state: null,
        delivery_expires_at: null,
        external_event_id: "evt-reply",
        content: { author: { kind: "agent", adapter: "agent:claude-code" }, turn_seq: 1, kind: "reply" },
      });
      const question = await f.append(w.user, w.conversation, w.task, 1, "evt-question", "어느 파일부터 볼까요?", "question");
      expect(question).toMatchObject({ status: "created", seq: 3 });
      expect(await f.msg(String(question.message_id))).toMatchObject({ role: "assistant", external_event_id: "evt-question", content: { author: { kind: "agent", adapter: "agent:claude-code" }, turn_seq: 1, kind: "question" } });
      const event = await f.append(w.user, w.conversation, w.task, 1, "evt-event", "연결이 끊겼어요", "event");
      expect(event).toMatchObject({ status: "created", seq: 4 });
      expect(await f.msg(String(event.message_id))).toMatchObject({ role: "event", text: "연결이 끊겼어요", reply_to: null, external_event_id: "evt-event", content: { author: { kind: "agent", adapter: "agent:claude-code" }, turn_seq: 1, kind: "event" } });
      // truncated 키는 자르지 않았으면 없다
      for (const id of [reply.message_id, question.message_id, event.message_id]) expect((await f.msg(String(id))).content).not.toHaveProperty("truncated");
      // 사용자 메시지(seq 1)와 이어서 센다. 모델 답 경로(reply_to)는 쓰이지 않았다
      expect((await f.messages(w.conversation)).map((m) => `${m.seq}:${m.role}`)).toEqual(["1:user", "2:assistant", "3:assistant", "4:event"]);
      expect((await f.one(`select count(*)::int as n from public.conversation_messages where conversation_id = $1 and reply_to is not null`, [w.conversation])).n).toBe(0);
      // adapter는 연결의 것을 따른다
      const codex = await f.agentConnection(w.user, null, { adapter: "agent:codex" });
      const codexSession = await f.session(w.user, codex);
      const codexConversation = await f.agentConversation(w.user, codex, codexSession);
      const codexMessage = await f.post(w.user, codexConversation, randomUUID(), "codex에게");
      const codexTask = await f.task(w.user, await f.agentRun(w.user, w.action, { agent_session_id: codexSession }), codexSession, { message_id: codexMessage.message_id, turn_seq: 1, state: "running" });
      const codexReply = await f.append(w.user, codexConversation, codexTask, 1, "evt-codex", "네", "reply");
      expect((await f.msg(String(codexReply.message_id))).content).toMatchObject({ author: { kind: "agent", adapter: "agent:codex" } });
    });

    it("turn_seq가 없는 event는 content에 turn_seq 키가 없다. 빈 글도 저장한다. event는 작업의 메시지와 무관하게 세션만 맞으면 된다", async () => {
      const w = await f.agentWorld();
      const event = await f.append(w.user, w.conversation, w.task, null, "evt-no-turn", "", "event");
      expect(event.status).toBe("created");
      const row = await f.msg(String(event.message_id));
      expect(row).toMatchObject({ role: "event", text: "" });
      expect(row.content).toEqual({ author: { kind: "agent", adapter: "agent:claude-code" }, kind: "event" });
      // 같은 세션에 묶인 다른 대화에도 event를 쓸 수 있다 (세션 단위 사건), 답 · 질문은 그 턴의 대화에만
      const sibling = await f.agentConversation(w.user, w.connection, w.session);
      expect(await f.append(w.user, sibling, w.task, 1, "evt-session", "중단했어요", "event")).toMatchObject({ status: "created", seq: 1 });
      expect(await f.append(w.user, sibling, w.task, 1, "evt-session-reply", "답", "reply")).toMatchObject({ status: "wrong_conversation", message_id: null, seq: null });
      expect(await f.append(w.user, sibling, w.task, 1, "evt-session-question", "질문", "question")).toMatchObject({ status: "wrong_conversation" });
      // 작업의 message_id가 지워졌어도(set null) 답 · 질문은 어느 대화에도 쓸 수 없다. event는 쓸 수 있다
      await q(`update public.agent_tasks set message_id = null where id = $1`, [w.task]);
      expect(await f.append(w.user, w.conversation, w.task, 1, "evt-orphan", "답", "reply")).toMatchObject({ status: "wrong_conversation" });
      expect(await f.append(w.user, w.conversation, w.task, 1, "evt-orphan-event", "알림", "event")).toMatchObject({ status: "created" });
    });

    it("같은 event id는 한 번만: 두 번째는 duplicate(기존 id · seq)이고 아무것도 쓰지 않는다 (글 · 종류가 달라도, 작업이 달라져도)", async () => {
      const w = await f.agentWorld();
      const first = await f.append(w.user, w.conversation, w.task, 1, "evt-1", "하나", "reply");
      const again = await f.append(w.user, w.conversation, w.task, 1, "evt-1", "하나", "reply");
      expect(again).toEqual({ status: "duplicate", message_id: first.message_id, seq: first.seq });
      expect(await f.append(w.user, w.conversation, w.task, 2, "evt-1", "다른 글", "question")).toEqual({ status: "duplicate", message_id: first.message_id, seq: first.seq });
      expect(await f.append(w.user, w.conversation, randomUUID(), 1, "evt-1", "없는 작업", "reply")).toEqual({ status: "duplicate", message_id: first.message_id, seq: first.seq });
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1 and external_event_id = 'evt-1'`, [w.conversation])).toBe(1);
      expect((await f.msg(String(first.message_id))).text).toBe("하나");
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [w.conversation])).toBe(2);
      // 다른 대화에서는 같은 id가 새 글이다
      const sibling = await f.agentConversation(w.user, w.connection, w.session);
      expect(await f.append(w.user, sibling, w.task, 1, "evt-1", "다른 대화", "event")).toMatchObject({ status: "created", seq: 1 });
    });

    it("대화 · 작업 확인: 없는 · 남의 대화나 작업은 not_found, 대상 taskforce는 wrong_target, 다른 세션의 작업은 wrong_session, 다른 대화의 작업(같은 세션)은 wrong_conversation — 모두 아무것도 쓰지 않는다", async () => {
      const [alice, bob] = [await f.agentWorld(), await f.agentWorld()];
      const rowsBefore = () => f.count(`select 1 from public.conversation_messages where user_id = $1`, [alice.user]);
      const before = await rowsBefore();
      // not_found
      expect(await f.append(bob.user, alice.conversation, alice.task, 1, "evt-n1", "글")).toEqual({ status: "not_found", message_id: null, seq: null });
      expect(await f.append(alice.user, randomUUID(), alice.task, 1, "evt-n2", "글")).toMatchObject({ status: "not_found" });
      expect(await f.append(alice.user, alice.conversation, randomUUID(), 1, "evt-n3", "글")).toMatchObject({ status: "not_found" });
      expect(await f.append(alice.user, alice.conversation, bob.task, 1, "evt-n4", "글")).toMatchObject({ status: "not_found" });
      // 남의 대화에 내 작업으로 써도 not_found (대화 조회가 사용자로 좁혀지지 않으면 wrong_session으로 보인다)
      expect(await f.append(bob.user, alice.conversation, bob.task, 1, "evt-n5", "글")).toMatchObject({ status: "not_found" });
      // wrong_target
      const taskforce = await f.conversation(alice.user);
      expect(await f.append(alice.user, taskforce, alice.task, 1, "evt-t1", "글")).toMatchObject({ status: "wrong_target" });
      expect(await f.append(alice.user, taskforce, alice.task, 1, "evt-t2", "알림", "event")).toMatchObject({ status: "wrong_target" });
      // wrong_session: 대화의 세션과 작업의 세션이 다르다 (세션이 아직 안 묶인 대화 포함)
      const otherSession = await f.session(alice.user, alice.connection);
      const otherConversation = await f.agentConversation(alice.user, alice.connection, otherSession);
      const unbound = await f.agentConversation(alice.user, alice.connection);
      for (const kind of ["reply", "question", "event"]) {
        expect(await f.append(alice.user, otherConversation, alice.task, 1, `evt-s-${kind}`, "글", kind), kind).toMatchObject({ status: "wrong_session" });
        expect(await f.append(alice.user, unbound, alice.task, 1, `evt-u-${kind}`, "글", kind), kind).toMatchObject({ status: "wrong_session" });
      }
      // wrong_conversation: 같은 세션에 묶인 다른 대화
      const sibling = await f.agentConversation(alice.user, alice.connection, alice.session);
      expect(await f.append(alice.user, sibling, alice.task, 1, "evt-c1", "글", "reply")).toMatchObject({ status: "wrong_conversation" });
      expect(await f.append(alice.user, sibling, alice.task, 1, "evt-c2", "글", "question")).toMatchObject({ status: "wrong_conversation" });
      expect(await rowsBefore()).toBe(before);
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = any ($1::uuid[])`, [[taskforce, otherConversation, unbound, sibling]])).toBe(0);
    });

    it("인자 검사: 종류 · event id(1–200자) · turn_seq(null 또는 1 이상) · 글(null 불가)이 어긋나면 22023이고 아무것도 쓰지 않는다", async () => {
      const w = await f.agentWorld();
      const call = (turnSeq: number | null, eventId: string | null, text: string | null, kind: string | null) =>
        q(`select * from public.conversation_append_agent_message($1, $2, $3, $4, $5, $6, $7)`, [w.user, w.conversation, w.task, turnSeq, eventId, text, kind]);
      for (const kind of ["other", "Reply", "", "answer", null]) await rejects(call(1, "evt-a", "글", kind), /conversation_append_agent_message: .*kind/);
      for (const eventId of ["", "x".repeat(201), null]) await rejects(call(1, eventId, "글", "reply"), /conversation_append_agent_message: .*event id/);
      for (const turnSeq of [0, -1]) await rejects(call(turnSeq, "evt-b", "글", "reply"), /conversation_append_agent_message: .*turn_seq/);
      await rejects(call(1, "evt-c", null, "reply"), /conversation_append_agent_message: .*text/);
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [w.conversation])).toBe(1);
      // 경계값은 된다
      await call(1, "x", "", "reply");
      await call(null, "y".repeat(200), "글", "event");
      await call(2147483647, "evt-max", "글", "reply");
    });

    it("읽기만 한다: agent_tasks · agent_sessions · 실행 표(runs · steps · events)를 쓰지 않는다", async () => {
      const w = await f.agentWorld();
      const snapshot = async () => ({
        task: await f.one(`select * from public.agent_tasks where id = $1`, [w.task]),
        session: await f.one(`select * from public.agent_sessions where id = $1`, [w.session]),
        run: await f.one(`select * from public.execution_runs where id = $1`, [w.run]),
        steps: await f.count(`select 1 from public.execution_steps where run_id = $1`, [w.run]),
        events: await f.count(`select 1 from public.execution_events where run_id = $1`, [w.run]),
        conversation: await f.one(`select target_kind, agent_connection_id, agent_session_id from public.conversations where id = $1`, [w.conversation]),
      });
      const before = await snapshot();
      await f.append(w.user, w.conversation, w.task, 1, "evt-ro-1", "답", "reply");
      await f.append(w.user, w.conversation, w.task, 1, "evt-ro-2", "질문", "question");
      await f.append(w.user, w.conversation, w.task, 1, "evt-ro-3", "알림", "event");
      expect(await snapshot()).toEqual(before);
    });
  });

  // ───────────────────────── T8) 자르기 ─────────────────────────
  describe("T8 글 자르기: 20,000자 · 32,768바이트 (글자 단위, 멀티바이트를 가르지 않는다)", () => {
    const sizes = async (id: string) =>
      f.one(
        `select char_length(text) as chars, octet_length(text) as bytes, content ->> 'truncated' as truncated, text from public.conversation_messages where id = $1`,
        [id],
      ) as Promise<{ chars: number; bytes: number; truncated: string | null; text: string }>;

    it("짧은 글 · 20,000자 ASCII는 그대로, 20,001자는 20,000자 + truncated", async () => {
      const w = await f.agentWorld();
      const short = await f.append(w.user, w.conversation, w.task, 1, "evt-short", "짧은 글");
      expect(await sizes(String(short.message_id))).toMatchObject({ chars: 4, truncated: null, text: "짧은 글" });
      const exact = await f.append(w.user, w.conversation, w.task, 1, "evt-exact", "a".repeat(20000));
      expect(await sizes(String(exact.message_id))).toMatchObject({ chars: 20000, bytes: 20000, truncated: null });
      const over = await f.append(w.user, w.conversation, w.task, 1, "evt-over", "a".repeat(20001));
      expect(await sizes(String(over.message_id))).toMatchObject({ chars: 20000, bytes: 20000, truncated: "true" });
      expect((await f.msg(String(over.message_id))).content).toMatchObject({ author: { kind: "agent" }, kind: "reply", turn_seq: 1, truncated: true });
      // 질문 · event도 같은 규칙
      const question = await f.append(w.user, w.conversation, w.task, 1, "evt-over-q", "b".repeat(30000), "question");
      expect(await sizes(String(question.message_id))).toMatchObject({ chars: 20000, truncated: "true" });
      const event = await f.append(w.user, w.conversation, w.task, 1, "evt-over-e", "c".repeat(30000), "event");
      expect(await sizes(String(event.message_id))).toMatchObject({ chars: 20000, truncated: "true" });
    });

    it("한글 12,000자(36KB)는 32,768바이트 이하의 온전한 글자 10,922자(32,766바이트)로 잘리고 앞부분 그대로이다", async () => {
      const w = await f.agentWorld();
      const text = "가".repeat(12000);
      const saved = await f.append(w.user, w.conversation, w.task, 1, "evt-ko", text);
      const row = await sizes(String(saved.message_id));
      expect(row.bytes).toBeLessThanOrEqual(32768);
      expect(row).toMatchObject({ chars: 10922, bytes: 32766, truncated: "true" });
      expect(row.text).toBe("가".repeat(10922));
      expect(row.text).not.toMatch(/�/);
    });

    it("정확히 32,768바이트는 자르지 않고, 한 글자 더하면 자른다 (경계). 4바이트 글자는 8,192자에서 멈춘다. 섞인 글은 바이트 한도에 맞춰 자른다", async () => {
      const w = await f.agentWorld();
      const atLimit = `${"가".repeat(10922)}ab`; // 32,766 + 2 = 32,768바이트
      const exact = await f.append(w.user, w.conversation, w.task, 1, "evt-edge-ok", atLimit);
      expect(await sizes(String(exact.message_id))).toMatchObject({ chars: 10924, bytes: 32768, truncated: null });
      const over = await f.append(w.user, w.conversation, w.task, 1, "evt-edge-over", `${atLimit}c`);
      expect(await sizes(String(over.message_id))).toMatchObject({ chars: 10924, bytes: 32768, truncated: "true" });
      const emoji = await f.append(w.user, w.conversation, w.task, 1, "evt-emoji", "😀".repeat(9000));
      const emojiRow = await sizes(String(emoji.message_id));
      expect(emojiRow).toMatchObject({ chars: 8192, bytes: 32768, truncated: "true" });
      expect(emojiRow.text).toBe("😀".repeat(8192));
      const mixed = await f.append(w.user, w.conversation, w.task, 1, "evt-mixed", `${"a".repeat(10000)}${"가".repeat(10000)}`);
      const mixedRow = await sizes(String(mixed.message_id));
      expect(mixedRow).toMatchObject({ chars: 17589, bytes: 32767, truncated: "true" });
      expect(mixedRow.text).toBe(`${"a".repeat(10000)}${"가".repeat(7589)}`);
    });
  });

  // ───────────────────────── T9) 만료 ─────────────────────────
  describe("T9 conversation_expire_agent_messages", () => {
    /** 상태와 만료 시각을 직접 정한 사용자 메시지 한 줄 (서버가 전달 경로에서 바꿔 놓은 상태처럼) */
    const seed = async (user: string, conversation: string, seq: number, state: string, expiresAt: string | null, reason: string | null = null) =>
      f.insertRow("conversation_messages", {
        user_id: user,
        conversation_id: conversation,
        seq,
        role: "user",
        client_message_id: randomUUID(),
        text: `글 ${seq}`,
        delivery_state: state,
        delivery_reason: reason,
        delivery_expires_at: expiresAt,
      });
    const stateOf = async (id: string) => f.one(`select delivery_state, delivery_reason, delivery_expires_at from public.conversation_messages where id = $1`, [id]);
    /** 다른 시험이 남긴, 이미 지난 queued · not_sent를 먼저 치운다 (이 시험의 반환 수가 시험 DB 전체의 상태에 기대지 않게) */
    const drain = async () => {
      // 상한이 있어야 sweep이 늘 0이 아닌 회귀가 시험을 멈추지 않고 실패로 드러난다
      for (let i = 0; i < 10 && (await f.expire(new Date())) > 0; i++);
    };

    it("지난 queued · not_sent만 expired가 되고(이유는 남는다) dispatched · cancelled · 이미 expired · 안 지난 것은 그대로다. 반환값은 바꾼 수이고, 한 번 더 부르면 0", async () => {
      const w = await f.agentWorld();
      // 시험 DB는 시나리오가 함께 쓰므로 실제 시각과 떨어진 시계로 돌려, 다른 시험의 queued 메시지(저장 + 24시간)를 건드리지 않는다
      const now = new Date("2020-06-01T12:00:00.000Z");
      const at = (offsetMs: number) => new Date(now.getTime() + offsetMs).toISOString();
      const queuedPast = await seed(w.user, w.conversation, 10, "queued", at(-DAY_MS));
      const notSentPast = await seed(w.user, w.conversation, 11, "not_sent", at(-60_000), "sign_in_needed");
      const dispatchedPast = await seed(w.user, w.conversation, 12, "dispatched", at(-DAY_MS));
      const cancelledPast = await seed(w.user, w.conversation, 13, "cancelled", at(-DAY_MS));
      const expiredPast = await seed(w.user, w.conversation, 14, "expired", at(-DAY_MS));
      const queuedFuture = await seed(w.user, w.conversation, 15, "queued", at(60_000));
      const notSentFuture = await seed(w.user, w.conversation, 16, "not_sent", at(DAY_MS), "usage_limited");
      const queuedExactly = await seed(w.user, w.conversation, 17, "queued", at(0)); // 정확히 지금 = 아직 안 지났다
      const queuedNoExpiry = await seed(w.user, w.conversation, 18, "queued", null);
      const before = {
        dispatchedPast: await stateOf(dispatchedPast),
        cancelledPast: await stateOf(cancelledPast),
        expiredPast: await stateOf(expiredPast),
        queuedFuture: await stateOf(queuedFuture),
        notSentFuture: await stateOf(notSentFuture),
        queuedExactly: await stateOf(queuedExactly),
        queuedNoExpiry: await stateOf(queuedNoExpiry),
      };

      expect(await f.expire(now)).toBe(2);
      expect(await stateOf(queuedPast)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
      expect(await stateOf(notSentPast)).toMatchObject({ delivery_state: "expired", delivery_reason: "sign_in_needed" });
      expect({
        dispatchedPast: await stateOf(dispatchedPast),
        cancelledPast: await stateOf(cancelledPast),
        expiredPast: await stateOf(expiredPast),
        queuedFuture: await stateOf(queuedFuture),
        notSentFuture: await stateOf(notSentFuture),
        queuedExactly: await stateOf(queuedExactly),
        queuedNoExpiry: await stateOf(queuedNoExpiry),
      }).toEqual(before);
      // 한 번 더: 바꿀 것이 없다
      expect(await f.expire(now)).toBe(0);
      // 시계가 가면 지난다 (정확히 지금이던 것도)
      expect(await f.expire(at(1))).toBe(1);
      expect(await stateOf(queuedExactly)).toMatchObject({ delivery_state: "expired" });
      expect(await stateOf(queuedFuture)).toMatchObject({ delivery_state: "queued" });
      expect(await f.expire(at(2 * DAY_MS))).toBe(2); // queuedFuture · notSentFuture
      expect(await stateOf(dispatchedPast)).toMatchObject({ delivery_state: "dispatched" });
      expect(await stateOf(queuedNoExpiry)).toMatchObject({ delivery_state: "queued" }); // 만료 시각이 없으면 만료되지 않는다
    });

    it("사용자 경계 없이 전체를 본다 (cron용). taskforce 대화 메시지(전달 열 null)는 건드리지 않는다. 시각이 null이면 22023", async () => {
      await drain();
      const [a, b] = [await f.agentWorld(), await f.agentWorld()];
      const past = new Date(Date.now() - DAY_MS).toISOString();
      const [aliceMessage, bobMessage] = [await seed(a.user, a.conversation, 10, "queued", past), await seed(b.user, b.conversation, 10, "not_sent", past)];
      const taskforce = await f.conversation(a.user);
      const plain = await f.message(a.user, taskforce);
      const queuedBefore = await stateOf(a.message); // agentWorld의 새 메시지: 만료가 24시간 뒤
      expect(await f.expire(new Date())).toBe(2);
      expect(await stateOf(aliceMessage)).toMatchObject({ delivery_state: "expired" });
      expect(await stateOf(bobMessage)).toMatchObject({ delivery_state: "expired" });
      expect(await stateOf(plain)).toEqual({ delivery_state: null, delivery_reason: null, delivery_expires_at: null });
      expect(await stateOf(a.message)).toEqual(queuedBefore);
      await rejects(q(`select public.conversation_expire_agent_messages(null)`), /conversation_expire_agent_messages: .*now/);
    });

    it("한 번에 최대 1,000행: 1,005행이면 1,000 → 5 → 0 (가장 오래된 만료부터)", async () => {
      await drain();
      const w = await f.agentWorld();
      await q(
        `insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text, delivery_state, delivery_expires_at)
         select $1, $2, 100 + g, 'user', gen_random_uuid(), 'x', 'queued', timestamptz '2020-01-01 00:00:00+00' + make_interval(secs => g)
           from generate_series(1, 1005) g`,
        [w.user, w.conversation],
      );
      expect(await f.expire(new Date())).toBe(1000);
      // 가장 늦게 만료되는 5행이 남는다
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1 and delivery_state = 'queued' and seq > 1100`, [w.conversation])).toBe(5);
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1 and delivery_state = 'expired'`, [w.conversation])).toBe(1000);
      expect(await f.expire(new Date())).toBe(5);
      expect(await f.expire(new Date())).toBe(0);
    });
  });

  // ───────────────────────── T12) 코디네이터 회수 ─────────────────────────
  describe("T12 coordinator_recover_missing — agent 대화의 사용자 메시지는 회수 cron이 user_message 사건으로 다시 쌓지 않는다", () => {
    const recover = async (limit = 1000) => Number((await f.one(`select public.coordinator_recover_missing(7200, $1) as n`, [limit])).n);
    const events = (userId: string) => q(`select type, dedup_key, refs from public.inbox_events where user_id = $1 order by dedup_key`, [userId]);

    it("삼킨 적재를 메우는 회수에서 agent 대화의 메시지는 빠지고, taskforce 대화의 메시지는 그대로 회수된다. 다시 돌려도 늘지 않는다", async () => {
      await recover(); // 다른 시험이 남긴 빠진 사건을 먼저 메워 이 시험의 반환 수가 시험 DB 전체의 상태에 기대지 않게 한다
      const w = await f.agentWorld(); // agent 대화의 사용자 메시지 하나
      const second = await f.post(w.user, w.conversation, randomUUID(), "둘째");
      const taskforce = await f.conversation(w.user);
      const plain = await f.post(w.user, taskforce, randomUUID(), "taskforce 글");
      expect(second.status).toBe("created");
      // 사용자 메시지가 아닌 행(모델 답)은 회수 대상이 아니다 (옮긴 본문이 role 조건을 그대로 둔다)
      await f.insertRow("conversation_messages", { user_id: w.user, conversation_id: taskforce, seq: 2, role: "assistant", text: "답", reply_to: plain.message_id });
      // 생산자 트리거는 taskforce 메시지만 적재했다. 그 사건을 지워 삼킨 적재를 흉내 낸다
      expect(await f.userMessageEvents(w.user)).toBe(1);
      await q(`delete from public.inbox_events where user_id = $1`, [w.user]);

      expect(await recover()).toBe(1);
      expect(await events(w.user)).toEqual([
        { type: "user_message", dedup_key: `message:${plain.message_id}`, refs: { conversation_id: taskforce, message_id: plain.message_id } },
      ]);
      expect(await recover()).toBe(0);
      expect(await events(w.user)).toHaveLength(1);
      // agent 대화의 메시지는 적재된 적이 없다
      expect(await f.count(`select 1 from public.inbox_events where user_id = $1 and dedup_key = any ($2)`, [w.user, [`message:${w.message}`, `message:${second.message_id}`]])).toBe(0);
    });

    it("회수의 limit은 agent 대화를 뺀 뒤의 메시지를 센다: 더 오래된 agent 메시지가 limit 자리를 차지해 taskforce 메시지가 회수되지 않는 일이 없다", async () => {
      await recover();
      const w = await f.agentWorld();
      for (let i = 0; i < 3; i++) await f.post(w.user, w.conversation, randomUUID(), `agent ${i}`); // taskforce 메시지보다 오래된 agent 메시지 넷
      const taskforce = await f.conversation(w.user);
      const plain = await f.post(w.user, taskforce, randomUUID(), "taskforce 글");
      await q(`delete from public.inbox_events where user_id = $1`, [w.user]);
      expect(await recover(1)).toBe(1);
      expect(await events(w.user)).toEqual([expect.objectContaining({ type: "user_message", dedup_key: `message:${plain.message_id}` })]);
      expect(await recover(1)).toBe(0);
    });
  });

  // ───────────────────────── T11) 삭제 전파 ─────────────────────────
  describe("T11 삭제 전파", () => {
    it("세션 삭제: 대화의 agent_session_id만 비고 대화 · 메시지는 남는다 (연결도 그대로)", async () => {
      const w = await f.agentWorld();
      await f.append(w.user, w.conversation, w.task, 1, "evt-keep", "남는 글");
      await q(`delete from public.agent_sessions where id = $1`, [w.session]);
      expect(await f.one(`select target_kind, agent_connection_id, agent_session_id from public.conversations where id = $1`, [w.conversation])).toEqual({
        target_kind: "agent",
        agent_connection_id: w.connection,
        agent_session_id: null,
      });
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [w.conversation])).toBe(2);
      expect(await f.count(`select 1 from public.agent_connections where id = $1`, [w.connection])).toBe(1);
      // 세션 없는 agent 대화는 다음 메시지도 받는다 (세션은 첫 전달 때 다시 묶인다)
      expect(await f.post(w.user, w.conversation, randomUUID(), "다시")).toMatchObject({ status: "created", seq: 3 });
    });

    it("연결 삭제는 그 연결의 대화가 있으면 거절된다 (연결 · 세션 · 작업 · 대화 모두 그대로). 대화를 지우면 연결을 지울 수 있다", async () => {
      const w = await f.agentWorld();
      await rejects(q(`delete from public.agent_connections where id = $1`, [w.connection]), /conversations_agent_connection_fkey/);
      expect(await f.count(`select 1 from public.agent_connections where id = $1`, [w.connection])).toBe(1);
      expect(await f.count(`select 1 from public.agent_sessions where id = $1`, [w.session])).toBe(1);
      expect(await f.count(`select 1 from public.agent_tasks where id = $1`, [w.task])).toBe(1);
      expect(await f.one(`select agent_session_id from public.conversations where id = $1`, [w.conversation])).toEqual({ agent_session_id: w.session });
      // 대화를 지우면 메시지도 함께 지워지고, 그제야 연결을 지울 수 있다 (세션 · 작업은 연결을 따라 지워진다)
      await q(`delete from public.conversations where id = $1`, [w.conversation]);
      expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [w.conversation])).toBe(0);
      await q(`delete from public.agent_connections where id = $1`, [w.connection]);
      expect(await f.count(`select 1 from public.agent_sessions where id = $1`, [w.session])).toBe(0);
      expect(await f.count(`select 1 from public.agent_tasks where id = $1`, [w.task])).toBe(0);
    });

    it("taskforce 대화는 연결 삭제에 영향이 없다", async () => {
      const w = await f.agentWorld();
      const taskforce = await f.conversation(w.user);
      await q(`delete from public.conversations where id = $1`, [w.conversation]);
      await q(`delete from public.agent_connections where id = $1`, [w.connection]);
      expect(await f.count(`select 1 from public.conversations where id = $1`, [taskforce])).toBe(1);
    });

    it("계정 삭제(auth.users): 대화 · 메시지 · 연결 · 세션 · 작업이 모두 사라진다 (restrict 외래키가 막지 않는다). 다른 사용자의 것은 그대로", async () => {
      const [alice, bob] = [await f.agentWorld(), await f.agentWorld()];
      await f.append(alice.user, alice.conversation, alice.task, 1, "evt-a", "글");
      await f.agentConversation(alice.user, alice.connection); // 세션이 안 묶인 대화
      await f.conversation(alice.user); // taskforce 대화
      const tables = ["conversations", "conversation_messages", "agent_connections", "agent_sessions", "agent_tasks", "bridges"];
      for (const table of tables) expect(await f.count(`select 1 from public.${table} where user_id = $1`, [alice.user]), table).toBeGreaterThan(0);
      await q(`delete from auth.users where id = $1`, [alice.user]);
      for (const table of tables) expect(await f.count(`select 1 from public.${table} where user_id = $1`, [alice.user]), table).toBe(0);
      expect(await f.count(`select 1 from public.conversations where user_id = $1`, [bob.user])).toBe(1);
      expect(await f.count(`select 1 from public.conversation_messages where user_id = $1`, [bob.user])).toBe(1);
      expect(await f.count(`select 1 from public.agent_connections where user_id = $1`, [bob.user])).toBe(1);
    });
  });
}
