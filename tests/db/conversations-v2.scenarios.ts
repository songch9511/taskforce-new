import { randomUUID } from "node:crypto";

import { describe, expect, it, vi } from "vitest";

import { postConversationMessageResponseSchema, type IntentKind } from "@/lib/api/contract";
import { handlePostConversationMessage } from "@/lib/api/conversations";
import { payloadHash } from "@/lib/conversation/proposal";
import { respondToMessage, type ConsultModelResponse } from "@/lib/conversation/respond";
import {
  createConversation,
  finishTurn,
  loadConsultContext,
  loadConversation,
  loadMessage,
  loadWindow,
  postUserMessage,
  releaseLease,
  userMessageExists,
  verifySelected,
} from "@/lib/conversation/store";
import { takeRateLimit } from "@/lib/api/rate-limit-store";
import { SLACK_DISCONNECTED_QUOTE } from "@/lib/retention";
import { ASK_LIMIT } from "@/lib/api/rate-limit";

import { fakeComplete, fakeDecide, materialOf, reply } from "../conversation/fakes";
import { sqlAdmin } from "../conversation/sql-admin";

// 대화 v2 (20261106000000_conversations_v2, 구현 계획 B2): 메시지 쓰기 · 한 번의 답 · 늦은 응답 · 기억 정정 · 채택 멱등 · 권한 · 계정 삭제,
// 그리고 운영 코드(handler → store → SQL)를 가짜 모델로 끝까지 돌리는 대화 흐름(ARCH01 · ARCH02 · A41).
// 같은 시나리오를 PGlite(tests/db/conversations-v2.test.ts)와 실제 Postgres(tests/pg/conversations-v2.test.ts)에서 돌린다. 동시성은 실제 Postgres 파일에만 있다.

export type Rows = Record<string, unknown>[];

export type ConversationsDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

export type Turn = {
  user?: { intent?: Record<string, unknown> | null; refs?: Record<string, unknown> };
  reply?: { text?: string; refs?: Record<string, unknown>; content?: Record<string, unknown> | null };
  memory?: { item: Record<string, unknown>; corrects?: string | null; expected_version?: number | null }[];
  adopt?: Record<string, unknown> | null;
};

const intent = (kind: IntentKind) => ({ kind, confidence: 0.95, judge_version: "intent-v1" });

/** 고른 대상 없음 (store.ts normalizeSelected(undefined)와 같은 모양) */
export const NO_SELECTION = { action_ids: [], run_ids: [], artifact_ids: [] };

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 · 호출 */
export function conversationFixtures(db: () => ConversationsDb) {
  const one = async (sql: string, params: unknown[] = []) => (await db().query(sql, params))[0];
  const count = async (sql: string, params: unknown[] = []) => Number((await one(sql, params)).n);

  const f = {
    one,
    count,
    async user(): Promise<string> {
      const userId = randomUUID();
      await db().query(`insert into auth.users (id, email) values ($1, $2)`, [userId, `${userId}@example.com`]);
      return userId;
    },
    /** 연결에서 온 원문 하나 */
    async connectionSource(userId: string, provider: string, text: string): Promise<string> {
      const connection = (await one(`insert into public.connections (user_id, provider, external_account_id) values ($1, $2, $3) returning id`, [userId, provider, randomUUID()])).id as string;
      return (await one(`insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id) values ($1, 'message', $2, now(), $3) returning id`, [userId, text, connection])).id as string;
    },
    async context(userId: string, name = "Shape 출시 준비"): Promise<string> {
      return (await one(`insert into public.work_contexts (user_id, name, kind) values ($1, $2, 'project') returning id`, [userId, name])).id as string;
    },
    async conversation(userId: string, contextId: string | null = null): Promise<string> {
      return (await one(`insert into public.conversations (user_id, context_id) values ($1, $2) returning id`, [userId, contextId])).id as string;
    },
    post: async (userId: string, conversationId: string, clientId: string, text: string, selected: Record<string, unknown> = NO_SELECTION) =>
      (await one(`select * from public.conversation_post_message($1, $2, $3, $4, $5::jsonb, 75)`, [userId, conversationId, clientId, text, JSON.stringify(selected)])) as {
        status: string;
        message_id: string | null;
        seq: number | null;
        reply_id: string | null;
      },
    release: (userId: string, messageId: string) => db().query(`select public.conversation_release_lease($1, $2)`, [userId, messageId]),
    finish: async (userId: string, messageId: string, turn: Turn = {}) =>
      (await one(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [
        userId,
        messageId,
        JSON.stringify({
          user: { intent: turn.user?.intent ?? intent("consult"), refs: turn.user?.refs ?? {} },
          reply: { text: turn.reply?.text ?? "답", refs: turn.reply?.refs ?? {}, content: turn.reply?.content ?? { segments: [{ text: "답", tier: "T5" }] } },
          memory: turn.memory ?? [],
          adopt: turn.adopt ?? null,
        }),
      ])) as { status: string; reply_id: string | null; reply_seq: number | null; memory_ids: string[]; action_id: string | null },
    message: async (id: string) =>
      (await one(`select id, seq, role, text, refs, intent, reply_to, reply_lease_until, content from public.conversation_messages where id = $1`, [id])) as {
        id: string;
        seq: number;
        role: string;
        text: string;
        refs: Record<string, unknown> & { proposal?: { state: string; id: string } | null; action_ids?: string[]; memory_item_ids?: string[] };
        intent: Record<string, unknown> | null;
        reply_to: string | null;
        reply_lease_until: Date | string | null;
        content: Record<string, unknown> | null;
      },
    memoryItem: (id: string) =>
      one(`select id, kind, statement, origin, subject, source_ref, superseded_by, superseded_at, version, scope_kind, context_id from public.memory_items where id = $1`, [id]),
    /** 한 사용자의 할 일 · Claim · 근거 · user_created 이벤트 · note 원문 · run 수 */
    async actionCounts(userId: string) {
      return {
        actions: await count(`select count(*)::int as n from public.actions where user_id = $1`, [userId]),
        notes: await count(`select count(*)::int as n from public.sources where user_id = $1 and kind = 'note'`, [userId]),
        userClaims: await count(`select count(*)::int as n from public.claims where user_id = $1 and origin = 'user'`, [userId]),
        evidence: await count(`select count(*)::int as n from public.evidence where user_id = $1 and role = 'created'`, [userId]),
        created: await count(`select count(*)::int as n from public.action_events where user_id = $1 and type = 'user_created'`, [userId]),
        runs: await count(`select count(*)::int as n from public.execution_runs where user_id = $1`, [userId]),
      };
    },
    /** 열린 제안을 낸 assistant 답 하나 (사용자 메시지 + 그 답) */
    async proposal(userId: string, conversationId: string, title = "Shape 출시 준비") {
      const posted = await f.post(userId, conversationId, randomUUID(), "Shape 출시 준비해야 해");
      const payload = { kind: "create_action", title };
      const proposalId = randomUUID();
      const done = await f.finish(userId, posted.message_id!, {
        reply: {
          text: `${title}을(를) 할 일로 추가할까요?`,
          refs: { proposal: { id: proposalId, kind: "create_action", payload_hash: payloadHash(payload as never), state: "open" } },
          content: { segments: [], citations: [], proposal: payload },
        },
      });
      return { messageId: done.reply_id!, proposalId, payloadHash: payloadHash(payload as never), userMessageId: posted.message_id! };
    },
  };
  return f;
}

/** 답 내용의 인용 하나 (기본: Slack 채널 글) */
export const slackCitation = (sourceId: string, quote = "견적서 금요일까지 보내주세요", title = "#sales") => ({
  action_id: null,
  source_id: sourceId,
  source_title: title,
  source_kind: "message",
  occurred_at: null,
  external_url: null,
  quote,
});

/** 답 메시지의 인용 [원문 id, 인용, 제목] */
export const citationsOf = (message: { content: Record<string, unknown> | null }) =>
  ((message.content?.citations ?? []) as { source_id: string; quote: string; source_title: string | null }[]).map((c) => [c.source_id, c.quote, c.source_title]);

/** 채택 쓰기 계획 (proposal.ts adoptPlan과 같은 모양을 SQL에 직접) */
function adoptTurn(userId: string, proposal: { messageId: string; proposalId: string; payloadHash: string }, title = "Shape 출시 준비", conversationId = "x") {
  const actionId = randomUUID();
  const noteId = randomUUID();
  const now = new Date().toISOString();
  const claim = (field: string, value: string) => ({
    id: randomUUID(), user_id: userId, action_id: actionId, source_id: noteId, field, value, quote: title, occurred_at: now,
    speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "shared", origin: "user", channel: "note", state: "active",
  });
  return {
    actionId,
    noteId,
    adopt: {
      proposal_message_id: proposal.messageId,
      proposal_id: proposal.proposalId,
      payload_hash: proposal.payloadHash,
      action_id: actionId,
      note: { id: noteId, title: "Taskforce 대화", raw_text: title, external_url: `taskforce://conversations/${conversationId}#m` },
      action: { title, owner: "me", status: "open", due_date: null, due_at: null, needs_confirmation: false, confirm_reasons: [], resolution: null, counterpart: null, embedding: null },
      claims: [claim("scope", title), claim("owner", "me"), claim("status", "open")],
      evidence: [{ source_id: noteId, quote: title, role: "created" }],
      events: [{ type: "user_created", before: null, after: { title, source_id: noteId }, rule: "user", actor: "user", source_id: noteId }],
    },
  };
}

const explicitItem = (overrides: Record<string, unknown> = {}) => ({
  kind: "plan",
  scope_kind: "global",
  context_id: null,
  action_id: null,
  person_id: null,
  agent_adapter: null,
  subject: "개발 에이전트",
  statement: "개발은 Opus 5.5로",
  value: {},
  origin: "explicit",
  source_ref: null,
  observed_at: null,
  valid_from: null,
  valid_until: null,
  confidence: null,
  ...overrides,
});

type Models = { decide: ReturnType<typeof fakeDecide>; complete: ReturnType<typeof fakeComplete> };

/** 운영 handler → store → SQL로 메시지를 보낸다 (가짜 모델). 본문은 요청 그대로 */
function sender(admin: ReturnType<typeof sqlAdmin>, me: string, conversationId: string, models: () => Models) {
  return async (body: Record<string, unknown>) => {
    const response = await handlePostConversationMessage(
      new Request(`http://localhost/api/v2/conversations/${conversationId}/messages`, { method: "POST", body: JSON.stringify(body) }),
      conversationId,
      {
        enabled: () => true,
        memoryEnabled: () => true,
        authenticate: async () => ({ user: { id: me } }),
        hasConsent: async () => true,
        rateLimit: () => takeRateLimit(admin, me, "ask", ASK_LIMIT),
        loadConversation: (_u, id) => loadConversation(admin, me, id),
        verifySelected: (_u, refs) => verifySelected(admin, me, refs),
        messageExists: (_u, id, client) => userMessageExists(admin, me, id, client),
        post: (_u, id, client, text, selected) => postUserMessage(admin, me, id, client, text, selected),
        loadMessage: (_u, id) => loadMessage(admin, me, id),
        loadWindow: (_u, id, upto) => loadWindow(admin, me, id, upto),
        respond: (_u, input) =>
          respondToMessage(input, {
            decide: models().decide,
            complete: models().complete,
            retrieve: (q) => loadConsultContext(admin, me, { contextId: input.conversation.contextId, query: q.text, chunks: q.chunks, deadline: Date.now() + 60_000, now: input.now }),
            newId: randomUUID,
          }),
        finish: (_u, id, plan) => finishTurn(admin, me, id, plan),
        release: (_u, id) => releaseLease(admin, me, id),
      },
    );
    return { status: response.status, body: await response.json() };
  };
}

export function conversationsTests(db: () => ConversationsDb) {
  const f = conversationFixtures(db);

  describe("메시지 쓰기 (conversation_post_message)", () => {
    it("대화마다 seq를 1부터 매기고, 같은 client_message_id는 새로 쓰지 않는다: 처리 중 in_progress · 풀리면 retry · 글이 다르면 mismatch", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const client = randomUUID();
      const first = await f.post(me, conversation, client, "오늘 뭐 하지?");
      expect(first).toMatchObject({ status: "created", seq: 1, reply_id: null });
      expect((await f.post(me, conversation, randomUUID(), "두 번째")).seq).toBe(2);
      expect(await f.post(me, conversation, client, "오늘 뭐 하지?")).toMatchObject({ status: "stale", message_id: first.message_id }); // 뒤에 새 메시지가 있다
      expect(await f.count(`select count(*)::int as n from public.conversation_messages where conversation_id = $1`, [conversation])).toBe(2);

      const other = await f.conversation(me);
      const c2 = randomUUID();
      const posted = await f.post(me, other, c2, "안녕");
      expect(await f.post(me, other, c2, "안녕")).toMatchObject({ status: "in_progress", message_id: posted.message_id });
      expect(await f.post(me, other, c2, "다른 글")).toMatchObject({ status: "mismatch" });
      await f.release(me, posted.message_id!);
      expect(await f.post(me, other, c2, "안녕")).toMatchObject({ status: "retry", message_id: posted.message_id, seq: 1 });
      // 처리 표시가 시간으로 풀려도 retry
      await db().query(`update public.conversation_messages set reply_lease_until = now() - interval '1 second' where id = $1`, [posted.message_id]);
      expect((await f.post(me, other, c2, "안녕")).status).toBe("retry");
    });

    it("남의 대화 · 없는 대화는 not_found (쓰지 않는다)", async () => {
      const me = await f.user();
      const them = await f.user();
      const theirs = await f.conversation(them);
      expect((await f.post(me, theirs, randomUUID(), "끼어들기")).status).toBe("not_found");
      expect((await f.post(me, randomUUID(), randomUUID(), "x")).status).toBe("not_found");
      expect(await f.count(`select count(*)::int as n from public.conversation_messages where conversation_id = $1`, [theirs])).toBe(0);
    });
  });

  describe("한 번의 답 (conversation_finish_turn)", () => {
    it("written: 답(seq 다음 · reply_to) + 사용자 메시지의 의도 · refs, 처리 표시 풀림. 같은 메시지를 다시 쓰면 answered(답 하나) · 다시 보내면 answered", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const client = randomUUID();
      const posted = await f.post(me, conversation, client, "오늘 뭐 하지?");
      const done = await f.finish(me, posted.message_id!, { user: { intent: intent("consult"), refs: { action_ids: [] } }, reply: { text: "등록된 할 일은 없어요." } });
      expect(done).toMatchObject({ status: "written", reply_seq: 2 });
      expect(await f.message(done.reply_id!)).toMatchObject({ role: "assistant", reply_to: posted.message_id, text: "등록된 할 일은 없어요.", seq: 2 });
      expect(await f.message(posted.message_id!)).toMatchObject({ intent: intent("consult"), reply_lease_until: null });

      expect(await f.finish(me, posted.message_id!, { reply: { text: "두 번째 답" } })).toMatchObject({ status: "answered", reply_id: done.reply_id });
      expect(await f.post(me, conversation, client, "오늘 뭐 하지?")).toMatchObject({ status: "answered", reply_id: done.reply_id });
      expect(await f.post(me, conversation, client, "다른 글")).toMatchObject({ status: "mismatch", reply_id: null }); // 같은 id · 다른 글은 그 답을 받지 못한다
      expect(await f.count(`select count(*)::int as n from public.conversation_messages where reply_to = $1`, [posted.message_id])).toBe(1);
      // 사용자 메시지 하나에 답 하나 (unique reply_to): 직접 넣어도 막힌다
      await expect(
        db().query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, reply_to) values ($1, $2, 99, 'assistant', 'x', $3)`, [me, conversation, posted.message_id]),
      ).rejects.toThrow(/unique|duplicate/i);
    });

    it("JSON null은 SQL null로 읽는다: 의도 · 내용 · refs가 null이어도 CHECK에 걸리지 않는다", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const posted = await f.post(me, conversation, randomUUID(), "안녕");
      const raw = await f.one(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [
        me,
        posted.message_id,
        JSON.stringify({ user: { intent: null, refs: null }, reply: { text: "안녕하세요", refs: null, content: null }, memory: null, adopt: null }),
      ]);
      expect(raw.status).toBe("written");
      expect(await f.message(posted.message_id!)).toMatchObject({ intent: null, refs: { action_ids: [] } });
      expect(await f.message(raw.reply_id as string)).toMatchObject({ content: null, refs: { memory_item_ids: [], action_ids: [] } });
    });

    it("늦은 응답: 뒤에 새 사용자 메시지가 있으면 stale — 기억 · 답 0, 처리 표시 풀림 (옛 발화의 기억이 새 정정을 덮지 않는다)", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const old = await f.post(me, conversation, randomUUID(), "개발은 Opus 5.5로 할 거야");
      const newer = await f.post(me, conversation, randomUUID(), "아니 Sonnet 5.5로 할 거야");
      expect((await f.finish(me, newer.message_id!, { memory: [{ item: explicitItem({ statement: "개발은 Sonnet 5.5로" }) }] })).status).toBe("written");
      const late = await f.finish(me, old.message_id!, { memory: [{ item: explicitItem({ statement: "개발은 Opus 5.5로" }) }] });
      expect(late).toMatchObject({ status: "stale", reply_id: null });
      expect(await f.message(old.message_id!)).toMatchObject({ reply_lease_until: null, intent: null });
      const current = await db().query(`select statement from public.memory_items where user_id = $1 and superseded_at is null`, [me]);
      expect(current.map((r) => r.statement)).toEqual(["개발은 Sonnet 5.5로"]);
      expect(await f.count(`select count(*)::int as n from public.conversation_messages where reply_to = $1`, [old.message_id])).toBe(0);
    });

    it("기억 · 답은 한 트랜잭션: 정정 version이 어긋나면 같은 turn의 다른 기억까지 되돌리고 conflict (처리 표시 풀림)", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const target = (await f.one(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, JSON.stringify(explicitItem())])).id as string;
      const posted = await f.post(me, conversation, randomUUID(), "확정됐어. 그리고 Sonnet 5.5로 바뀌었어");
      const conflicted = await f.finish(me, posted.message_id!, {
        memory: [
          { item: explicitItem({ kind: "fact", subject: "디자인 확정 여부", statement: "디자인이 확정됨" }) },
          { item: explicitItem({ subject: null, statement: "개발은 Sonnet 5.5로" }), corrects: target, expected_version: 7 },
        ],
      });
      expect(conflicted).toMatchObject({ status: "conflict", reply_id: null });
      expect(await f.count(`select count(*)::int as n from public.memory_items where user_id = $1`, [me])).toBe(1);
      expect(await f.message(posted.message_id!)).toMatchObject({ reply_lease_until: null });

      // version이 맞으면 정정: 새 행 + 옛 행 superseded_by, 옛 행 삭제 0 (ARCH02)
      const written = await f.finish(me, posted.message_id!, {
        memory: [
          { item: explicitItem({ kind: "fact", subject: "디자인 확정 여부", statement: "디자인이 확정됨" }) },
          { item: explicitItem({ subject: null, statement: "개발은 Sonnet 5.5로" }), corrects: target, expected_version: 1 },
        ],
        reply: { refs: { memory_item_ids: [] } },
      });
      expect(written.status).toBe("written");
      expect(written.memory_ids).toHaveLength(2);
      const [fact, plan] = written.memory_ids;
      expect(await f.memoryItem(target)).toMatchObject({ superseded_by: plan, statement: "개발은 Opus 5.5로" });
      expect(await f.memoryItem(plan)).toMatchObject({ statement: "개발은 Sonnet 5.5로", subject: "개발 에이전트", kind: "plan", origin: "explicit" });
      expect(await f.memoryItem(fact)).toMatchObject({ kind: "fact", superseded_by: null });
      expect((await f.message(written.reply_id!)).refs.memory_item_ids).toEqual(written.memory_ids);
    });

    it("기억의 범위가 turn 도중 지워지면 500이 아니라 conflict (아무것도 쓰지 않고 처리 표시 풀림)", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const conversation = await f.conversation(me, context);
      const posted = await f.post(me, conversation, randomUUID(), "이 프로젝트 개발은 Opus 5.5로");
      await db().query(`delete from public.work_contexts where id = $1`, [context]);
      const done = await f.finish(me, posted.message_id!, { memory: [{ item: explicitItem({ scope_kind: "context", context_id: context }) }] });
      expect(done.status).toBe("conflict");
      expect(await f.count(`select count(*)::int as n from public.memory_items where user_id = $1`, [me])).toBe(0);
      expect(await f.message(posted.message_id!)).toMatchObject({ reply_lease_until: null });
    });

    it("새 제안이 나오면 같은 대화의 앞 열린 제안은 superseded (다른 대화의 제안은 그대로)", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const elsewhere = await f.conversation(me);
      const first = await f.proposal(me, conversation, "첫 제안");
      const other = await f.proposal(me, elsewhere, "다른 대화 제안");
      const second = await f.proposal(me, conversation, "두 번째 제안");
      expect((await f.message(first.messageId)).refs.proposal?.state).toBe("superseded");
      expect((await f.message(second.messageId)).refs.proposal?.state).toBe("open");
      expect((await f.message(other.messageId)).refs.proposal?.state).toBe("open");
    });
  });

  describe("채택 (A41): proposal id로 멱등, Action 1 + note 원문 + 사용자 Claim", () => {
    it("채택 → Action 1 · note 원문(처리 완료) · 사용자 Claim 3 · 근거 · user_created. 같은 제안을 다시 채택하면 conflict이고 Action은 1", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const proposal = await f.proposal(me, conversation);
      expect(await f.actionCounts(me)).toEqual({ actions: 0, notes: 0, userClaims: 0, evidence: 0, created: 0, runs: 0 }); // 채택 전 Action 0

      const adoptMessage = await f.post(me, conversation, randomUUID(), "그렇게 해");
      const { adopt, actionId, noteId } = adoptTurn(me, proposal, "Shape 출시 준비", conversation);
      const done = await f.finish(me, adoptMessage.message_id!, { adopt, user: { intent: intent("adopt"), refs: { proposal: { id: proposal.proposalId, kind: "create_action", payload_hash: proposal.payloadHash, state: "adopted" } } } });
      expect(done).toMatchObject({ status: "written", action_id: actionId });
      expect(await f.actionCounts(me)).toEqual({ actions: 1, notes: 1, userClaims: 3, evidence: 1, created: 1, runs: 0 });
      expect(await f.one(`select kind, raw_text, processing_status, external_url from public.sources where id = $1`, [noteId])).toEqual({
        kind: "note",
        raw_text: "Shape 출시 준비",
        processing_status: "done",
        external_url: `taskforce://conversations/${conversation}#m`,
      });
      expect(await f.one(`select title, owner, status, due_date from public.actions where id = $1`, [actionId])).toEqual({ title: "Shape 출시 준비", owner: "me", status: "open", due_date: null });
      const proposalRow = await f.message(proposal.messageId);
      expect(proposalRow.refs.proposal?.state).toBe("adopted");
      expect(proposalRow.refs.action_ids).toEqual([actionId]);
      expect((await f.message(done.reply_id!)).refs.action_ids).toEqual([actionId]);
      expect((await f.message(adoptMessage.message_id!)).refs.action_ids).toEqual([actionId]);

      // 같은 제안을 다른 메시지로 다시 채택: 열린 제안이 아니어서 아무것도 쓰지 않는다
      const again = await f.post(me, conversation, randomUUID(), "그렇게 해");
      expect((await f.finish(me, again.message_id!, { adopt: adoptTurn(me, proposal).adopt })).status).toBe("conflict");
      expect((await f.actionCounts(me)).actions).toBe(1);
    });

    it("payload_hash가 다르거나 다른 대화의 제안 메시지면 채택하지 않는다", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const elsewhere = await f.conversation(me);
      const proposal = await f.proposal(me, conversation);
      const foreign = await f.proposal(me, elsewhere);
      const message = await f.post(me, conversation, randomUUID(), "그렇게 해");
      expect((await f.finish(me, message.message_id!, { adopt: adoptTurn(me, { ...proposal, payloadHash: "sha256:other" }).adopt })).status).toBe("conflict");
      expect((await f.finish(me, message.message_id!, { adopt: adoptTurn(me, foreign).adopt })).status).toBe("conflict");
      expect((await f.actionCounts(me)).actions).toBe(0);
    });
  });

  describe("Slack 끊기 · 앱 제거 (D3)", () => {
    it("답 내용의 Slack 원문 인용 · 제목을 근거 인용과 같은 자리 표시로 바꾼다 (다른 원문 인용 · 답 글은 그대로, 다시 불러도 같다). 보관 기간 정리는 인용을 남긴다", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const slack = await f.connectionSource(me, "slack", "#sales\n김대표: 견적서 금요일까지 보내주세요");
      const doc = await f.connectionSource(me, "notion", "회의록: 디자인 확정 뒤 개발 시작");
      const expiring = await f.connectionSource(me, "notion", "오래된 문서: 예산 3천만 원");
      const citation = (sourceId: string, quote: string, title: string) => ({
        action_id: null, source_id: sourceId, source_title: title, source_kind: "message", occurred_at: null, external_url: null, quote,
      });
      const posted = await f.post(me, conversation, randomUUID(), "김대표 견적 건 어떻게 됐어?");
      const done = await f.finish(me, posted.message_id!, {
        reply: {
          text: "김대표가 금요일까지 보내 달라고 했어요.",
          content: {
            segments: [{ text: "김대표가 금요일까지 보내 달라고 했어요.", tier: "T1" }],
            citations: [citation(slack, "견적서 금요일까지 보내주세요", "#sales"), citation(doc, "디자인 확정 뒤 개발 시작", "회의록"), citation(expiring, "예산 3천만 원", "오래된 문서")],
          },
        },
      });
      await db().query(`select public.purge_slack_sources($1::uuid[])`, [[slack]]);
      await db().query(`select public.purge_slack_sources($1::uuid[])`, [[slack]]);
      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now(), raw_text_purge_reason = 'retention' where id = $1`, [expiring]);
      const reply = await f.message(done.reply_id!);
      const citations = (reply.content as { citations: { source_id: string; quote: string; source_title: string }[] }).citations;
      expect(citations.map((c) => [c.source_id, c.quote, c.source_title])).toEqual([
        [slack, SLACK_DISCONNECTED_QUOTE, "Slack"],
        [doc, "디자인 확정 뒤 개발 시작", "회의록"],
        [expiring, "예산 3천만 원", "오래된 문서"],
      ]);
      expect(reply.text).toBe("김대표가 금요일까지 보내 달라고 했어요.");
      expect((reply.content as { segments: unknown[] }).segments).toEqual([{ text: "김대표가 금요일까지 보내 달라고 했어요.", tier: "T1" }]);
    });

    it("이미 끊어 지운 Slack 원문을 인용한 답을 나중에 써도(모델이 도는 동안 끊김) 인용 · 제목은 자리 표시로 저장된다", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const slack = await f.connectionSource(me, "slack", "#sales\n김대표: 견적서 금요일까지 보내주세요");
      const posted = await f.post(me, conversation, randomUUID(), "김대표 견적 건 어떻게 됐어?");
      await db().query(`select public.purge_slack_sources($1::uuid[])`, [[slack]]);
      const done = await f.finish(me, posted.message_id!, { reply: { content: { segments: [{ text: "답", tier: "T1" }], citations: [slackCitation(slack)] } } });
      expect(done.status).toBe("written");
      expect(citationsOf(await f.message(done.reply_id!))).toEqual([[slack, SLACK_DISCONNECTED_QUOTE, "Slack"]]);
    });

    it("L7: 끊기 · 삭제 때 인용한 답을 원문 id 인덱스로 찾는다 (원문마다 사용자 메시지 전체를 훑지 않게)", async () => {
      const rows = await db().query(`select indexdef from pg_indexes where schemaname = 'public' and indexname = 'conversation_messages_citations_idx'`);
      expect(rows).toHaveLength(1);
      expect(String(rows[0].indexdef)).toMatch(/gin \(\(\(?content -> 'citations'::text\)?\) jsonb_path_ops\)/i);
    });

    it("Codex P1: 끊기 커밋 → 끊기 전 자료로 만든 늦은 답 → 끊기 다시 실행에도 그 원문 인용만 자리 표시 (다른 연결 · 일반 원문 · 다른 사용자는 그대로)", async () => {
      const me = await f.user();
      const them = await f.user();
      const mine = await f.conversation(me);
      const theirs = await f.conversation(them);
      const purged = await f.connectionSource(me, "slack", "private Slack quote");
      const otherSlack = await f.connectionSource(me, "slack", "다른 워크스페이스 글");
      const doc = await f.connectionSource(me, "notion", "회의록: 디자인 확정 뒤 개발 시작");
      const theirSlack = await f.connectionSource(them, "slack", "private Slack quote");
      const theirMessage = await f.post(them, theirs, randomUUID(), "question");
      const theirReply = await f.finish(them, theirMessage.message_id!, {
        reply: { content: { segments: [{ text: "답", tier: "T1" }], citations: [slackCitation(theirSlack, "private Slack quote", "private channel")] } },
      });
      const message = await f.post(me, mine, randomUUID(), "question");
      await db().query(`select public.purge_slack_sources($1::uuid[])`, [[purged]]);
      const late = await f.finish(me, message.message_id!, {
        reply: {
          text: "summary",
          content: {
            segments: [{ text: "summary", tier: "T1" }],
            citations: [
              slackCitation(purged, "private Slack quote", "private channel"),
              slackCitation(otherSlack, "다른 워크스페이스 글", "#general"),
              slackCitation(doc, "디자인 확정 뒤 개발 시작", "회의록"),
            ],
          },
        },
      });
      expect(late.status).toBe("written");
      await db().query(`select public.purge_slack_sources($1::uuid[])`, [[purged]]);
      expect(citationsOf(await f.message(late.reply_id!))).toEqual([
        [purged, SLACK_DISCONNECTED_QUOTE, "Slack"],
        [otherSlack, "다른 워크스페이스 글", "#general"],
        [doc, "디자인 확정 뒤 개발 시작", "회의록"],
      ]);
      expect(citationsOf(await f.message(theirReply.reply_id!))).toEqual([[theirSlack, "private Slack quote", "private channel"]]);
    });

    it("N4: 남의 원문 id를 인용한 답은 넣을 때 · 고칠 때 모두 인용 · 제목 · 링크를 비운다 (끊긴 남의 원문도 그 상태를 보지 않는다)", async () => {
      const me = await f.user();
      const them = await f.user();
      const conversation = await f.conversation(me);
      const theirs = await f.connectionSource(them, "notion", "그들의 문서: 계약 조건");
      const theirSlack = await f.connectionSource(them, "slack", "그들의 Slack 글");
      await db().query(`select public.purge_slack_sources($1::uuid[])`, [[theirSlack]]);
      const posted = await f.post(me, conversation, randomUUID(), "질문");
      const done = await f.finish(me, posted.message_id!, {
        reply: { content: { segments: [{ text: "답", tier: "T1" }], citations: [slackCitation(theirs, "계약 조건", "그들의 문서"), slackCitation(theirSlack, "그들의 Slack 글", "#theirs")] } },
      });
      expect(citationsOf(await f.message(done.reply_id!))).toEqual([
        [theirs, "", null],
        [theirSlack, "", null],
      ]);
      // 고칠 때도 같다 (가드는 UPDATE OF content에도 돈다)
      await db().query(`update public.conversation_messages set content = $2::jsonb where id = $1`, [
        done.reply_id,
        JSON.stringify({ segments: [], citations: [slackCitation(theirs, "계약 조건", "그들의 문서")] }),
      ]);
      expect(citationsOf(await f.message(done.reply_id!))).toEqual([[theirs, "", null]]);
    });

    it("원문 행이 지워지면 답 내용의 그 원문 인용 · 제목을 비운다 (A16)", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const doc = await f.connectionSource(me, "notion", "회의록: 디자인 확정 뒤 개발 시작");
      const keep = await f.connectionSource(me, "notion", "다른 문서: 예산 3천만 원");
      const posted = await f.post(me, conversation, randomUUID(), "디자인 언제 확정돼?");
      const done = await f.finish(me, posted.message_id!, {
        reply: { content: { segments: [{ text: "답", tier: "T1" }], citations: [slackCitation(doc, "디자인 확정 뒤 개발 시작", "회의록"), slackCitation(keep, "예산 3천만 원", "다른 문서")] } },
      });
      await db().query(`delete from public.sources where id = $1`, [doc]);
      expect(citationsOf(await f.message(done.reply_id!))).toEqual([
        [doc, "", null],
        [keep, "예산 3천만 원", "다른 문서"],
      ]);
    });
  });

  describe("다른 사용자 · 다른 대화의 권한 (주입)", () => {
    it("남의 메시지로 답 쓰기 · 남의 제안 채택 · 남의 기억 정정 · 남의 메시지에 답 달기는 모두 막힌다", async () => {
      const me = await f.user();
      const them = await f.user();
      const mine = await f.conversation(me);
      const theirs = await f.conversation(them);
      const theirMessage = await f.post(them, theirs, randomUUID(), "그들의 메시지");
      expect((await f.finish(me, theirMessage.message_id!)).status).toBe("not_found");

      const theirProposal = await f.proposal(them, theirs);
      const mineMessage = await f.post(me, mine, randomUUID(), "그렇게 해");
      expect((await f.finish(me, mineMessage.message_id!, { adopt: adoptTurn(me, theirProposal).adopt })).status).toBe("conflict");
      expect((await f.actionCounts(me)).actions).toBe(0);
      expect((await f.actionCounts(them)).actions).toBe(0);

      const theirMemory = (await f.one(`select * from public.remember_memory_item($1, $2::jsonb)`, [them, JSON.stringify(explicitItem())])).id as string;
      const injected = await f.finish(me, mineMessage.message_id!, { memory: [{ item: explicitItem({ subject: null, statement: "덮어쓰기" }), corrects: theirMemory, expected_version: 1 }] });
      expect(injected.status).toBe("conflict");
      expect(await f.memoryItem(theirMemory)).toMatchObject({ superseded_by: null, statement: "개발은 Opus 5.5로" });

      // 다른 대화(또는 남)의 메시지에 답을 달 수 없다: (reply_to, conversation_id, user_id) 복합 외래키
      await expect(
        db().query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, reply_to) values ($1, $2, 50, 'assistant', 'x', $3)`, [me, mine, theirMessage.message_id]),
      ).rejects.toThrow(/foreign key|violates/i);
    });
  });

  describe("RLS · 권한", () => {
    it("앱은 자기 대화 · 메시지(content · reply_to 포함)만 읽고, 쓰거나 서버 함수를 부르지 못한다", async () => {
      const me = await f.user();
      const them = await f.user();
      const conversation = await f.conversation(me);
      const posted = await f.post(me, conversation, randomUUID(), "안녕");
      const done = await f.finish(me, posted.message_id!, { reply: { content: { segments: [{ text: "안녕하세요", tier: "T5" }], citations: [] } } });

      const mineRows = await db().asUser(me, () => db().query(`select id, reply_to, content from public.conversation_messages order by seq`));
      expect(mineRows.map((r) => r.id)).toEqual([posted.message_id, done.reply_id]);
      expect(mineRows[1]).toMatchObject({ reply_to: posted.message_id, content: { segments: [{ text: "안녕하세요", tier: "T5" }], citations: [] } });
      expect(await db().asUser(them, () => db().query(`select id from public.conversation_messages where conversation_id = $1`, [conversation]))).toEqual([]);

      await expect(db().asUser(me, () => db().query(`update public.conversation_messages set text = '고침' where id = $1`, [posted.message_id]))).rejects.toThrow(/permission denied/i);
      await expect(db().asUser(me, () => db().query(`select * from public.conversation_post_message($1, $2, $3, 'x', '{}'::jsonb, 75)`, [me, conversation, randomUUID()]))).rejects.toThrow(/permission denied/i);
      await expect(db().asUser(me, () => db().query(`select * from public.conversation_finish_turn($1, $2, '{}'::jsonb)`, [me, posted.message_id]))).rejects.toThrow(/permission denied/i);
      await expect(db().asUser(me, () => db().query(`select public.conversation_release_lease($1, $2)`, [me, posted.message_id]))).rejects.toThrow(/permission denied/i);
      // 로그인하지 않은 역할(anon)도 서버 함수를 부르지 못한다
      await db().query(`set role anon`);
      try {
        for (const call of [
          `select * from public.conversation_post_message('${me}', '${conversation}', '${randomUUID()}', 'x', '{}'::jsonb, 75)`,
          `select * from public.conversation_finish_turn('${me}', '${posted.message_id}', '{}'::jsonb)`,
          `select public.conversation_release_lease('${me}', '${posted.message_id}')`,
        ]) {
          await expect(db().query(call)).rejects.toThrow(/permission denied/i);
        }
      } finally {
        await db().query(`reset role`);
      }
    });

    it("서버 역할(service_role)로 세 함수를 모두 부를 수 있다: 안에서 부르는 remember_memory_item · write_action 권한까지", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const proposal = await f.proposal(me, conversation);
      const { adopt } = adoptTurn(me, proposal);
      // Supabase에서 service_role은 extensions · auth 스키마를 쓸 수 있다 (테스트 흉내 local-supabase.ts에는 anon · authenticated만 있어 여기서 맞춘다)
      await db().query(`grant usage on schema extensions, auth to service_role`);
      await db().query(`set role service_role`);
      try {
        const posted = await f.post(me, conversation, randomUUID(), "그렇게 해");
        expect(posted.status).toBe("created");
        await f.release(me, posted.message_id!);
        const done = await f.finish(me, posted.message_id!, { adopt, memory: [{ item: explicitItem({ source_ref: { message_id: posted.message_id, quote: "그렇게 해" } }) }] });
        expect(done.status).toBe("written");
      } finally {
        await db().query(`reset role`);
      }
      expect((await f.actionCounts(me)).actions).toBe(1);
    });

    it("계정을 지우면 대화 · 메시지 · 대화에서 만든 기억 · 채택한 Action · note 원문이 함께 지워진다", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const proposal = await f.proposal(me, conversation);
      const message = await f.post(me, conversation, randomUUID(), "그렇게 해");
      await f.finish(me, message.message_id!, { adopt: adoptTurn(me, proposal).adopt, memory: [{ item: explicitItem({ source_ref: { message_id: message.message_id } }) }] });
      await db().query(`delete from auth.users where id = $1`, [me]);
      for (const table of ["conversations", "conversation_messages", "memory_items", "actions", "sources", "claims"]) {
        expect(await f.count(`select count(*)::int as n from public.${table} where user_id = $1`, [me]), table).toBe(0);
      }
    });
  });

  describe("대화 흐름: handler → store → SQL (가짜 모델, MEMORY_ENABLED 켬)", () => {
    it("ARCH01 · ARCH02 · A41: 기억 2건 → 상담(쓰기 0) → 정정(새 행 + superseded_by) → 제안 → 채택 Action 1 → 다시 채택 · 다시 보내기에도 Action 1", async () => {
      vi.stubEnv("MEMORY_ENABLED", "true");
      try {
        const me = await f.user();
        const admin = sqlAdmin((sql, params) => db().query(sql, params));
        const created = await createConversation(admin, me, {});
        expect(created.status).toBe("created");
        const conversationId = created.status === "created" ? created.conversation.id : "";
        let models: Models = { decide: fakeDecide({ intent: "consult" }), complete: fakeComplete(reply()) };
        const http = sender(admin, me, conversationId, () => models);
        const send = (text: string, clientId = randomUUID()) => http({ client_message_id: clientId, text });
        const currentMemory = () => db().query(`select id, kind, subject, statement, origin, source_ref, superseded_by from public.memory_items where user_id = $1 and superseded_at is null order by kind`, [me]);

        // (1) ARCH01: 기억 2건 (explicit, 출처 = 그 메시지, 범위 = All work)
        const first = "디자인 확정되면 개발 시작하고, 개발은 Opus 5.5로 할 거야.";
        models = {
          decide: fakeDecide({ intent: "inform" }),
          complete: fakeComplete(
            reply({
              segments: [{ text: "알겠어요.", tier: "T2" }],
              memory_candidates: [
                { kind: "condition", subject: "개발 착수 조건", statement: "디자인 확정 뒤 개발 시작", message: "U1", quote: "디자인 확정되면 개발 시작하고", corrects: null },
                { kind: "plan", subject: "개발 에이전트", statement: "개발은 Opus 5.5로", message: "U1", quote: "개발은 Opus 5.5로 할 거야", corrects: null },
              ],
            }),
          ),
        };
        const turn1 = await send(first);
        expect(turn1.status).toBe(200);
        expect(postConversationMessageResponseSchema.safeParse(turn1.body).success).toBe(true);
        const memory1 = await currentMemory();
        expect(memory1.map((m) => [m.kind, m.statement, m.origin])).toEqual([
          ["condition", "디자인 확정 뒤 개발 시작", "explicit"],
          ["plan", "개발은 Opus 5.5로", "explicit"],
        ]);
        expect(memory1.every((m) => (m.source_ref as { message_id: string }).message_id === turn1.body.message.id)).toBe(true);
        expect([...turn1.body.reply.refs.memory_item_ids].sort()).toEqual(memory1.map((m) => m.id).sort());
        expect(turn1.body.reply.text).toContain("(범위: All work)");
        expect(await f.actionCounts(me)).toMatchObject({ actions: 0, runs: 0 });

        // (2) ARCH01: 며칠 뒤 상담 — 기억을 모델에 넘기고(사용자 발화) 쓰기 0
        models = {
          decide: fakeDecide({ intent: "consult" }),
          complete: fakeComplete(reply({ segments: [{ text: "착수 조건은 디자인 확정이라고 하셨어요. ", tier: "T2" }, { text: "확정됐나요?", tier: "T5" }] })),
        };
        const turn2 = await send("이제 개발 어떻게 하지?");
        expect(turn2.status).toBe(200);
        expect(materialOf(models.complete.mock.calls[0][0]).memory.map((m) => m.statement).sort()).toEqual(["개발은 Opus 5.5로", "디자인 확정 뒤 개발 시작"]);
        expect(turn2.body.reply.segments.map((s: { tier: string }) => s.tier)).toEqual(["T2", "T5"]);
        expect((await currentMemory()).map((m) => m.id).sort()).toEqual(memory1.map((m) => m.id).sort());
        expect(await f.actionCounts(me)).toMatchObject({ actions: 0, runs: 0 });

        // (3) ARCH02: 사실 1건 + plan 정정 (새 행 + 옛 행 superseded_by, 옛 행 삭제 0)
        const planOld = memory1.find((m) => m.kind === "plan")!;
        models = {
          decide: fakeDecide({ intent: "correct", remember: 0.95 }),
          complete: fakeComplete((request): ConsultModelResponse => {
            const material = materialOf(request);
            const target = material.memory.find((m) => m.statement === "개발은 Opus 5.5로")!;
            return reply({
              memory_candidates: [
                { kind: "fact", subject: "디자인 확정 여부", statement: "디자인이 확정됨", message: material.conversation.current, quote: "확정됐어", corrects: null },
                { kind: "plan", subject: "개발 에이전트", statement: "개발은 Sonnet 5.5로", message: material.conversation.current, quote: "그건 바뀌었어, Sonnet 5.5로", corrects: target.id },
              ],
            });
          }),
        };
        const turn3 = await send("확정됐어. 그리고 그건 바뀌었어, Sonnet 5.5로.");
        expect(turn3.status).toBe(200);
        expect(turn3.body.reply.text).toContain("고쳤어요: 개발은 Opus 5.5로 → 개발은 Sonnet 5.5로 (범위: All work)");
        const memory3 = await currentMemory();
        expect(memory3.map((m) => [m.kind, m.statement])).toEqual([
          ["condition", "디자인 확정 뒤 개발 시작"],
          ["fact", "디자인이 확정됨"],
          ["plan", "개발은 Sonnet 5.5로"],
        ]);
        const planNew = memory3.find((m) => m.kind === "plan")!;
        expect(await f.memoryItem(planOld.id as string)).toMatchObject({ superseded_by: planNew.id, statement: "개발은 Opus 5.5로" });
        expect(turn3.body.message.refs.memory_item_ids).toEqual([planOld.id]); // 정한 대상은 사용자 메시지 refs에
        expect(await f.actionCounts(me)).toMatchObject({ actions: 0, runs: 0 });

        // (4) A41: 제안은 Action이 아니다
        models = { decide: fakeDecide({ intent: "consult" }), complete: fakeComplete(reply({ segments: [{ text: "할 일로 남겨 둘까요?", tier: "T5" }], proposal: { title: "Shape 출시 준비" } })) };
        const turn4 = await send("Shape 출시를 이번 달에 끝내고 싶은데 어떻게 할까?");
        expect(turn4.body.reply.refs.proposal).toMatchObject({ kind: "create_action", state: "open" });
        expect(await f.actionCounts(me)).toMatchObject({ actions: 0, runs: 0 });

        // (5) A41: 채택 → Action 1 + note 원문 + 사용자 Claim (모델은 Jev 한 번, LLM 0)
        models = { decide: fakeDecide({ intent: "adopt" }), complete: fakeComplete(reply()) };
        const adoptClient = randomUUID();
        const turn5 = await send("그렇게 해", adoptClient);
        expect(turn5.status).toBe(200);
        expect(models.complete).not.toHaveBeenCalled();
        expect(turn5.body.reply.text).toBe("할 일로 추가했어요: Shape 출시 준비");
        expect(await f.actionCounts(me)).toEqual({ actions: 1, notes: 1, userClaims: 3, evidence: 1, created: 1, runs: 0 });
        const actionId = turn5.body.reply.refs.action_ids[0];
        expect(await f.one(`select external_url from public.sources where user_id = $1 and kind = 'note'`, [me])).toEqual({ external_url: `taskforce://conversations/${conversationId}#${turn5.body.message.id}` });
        expect(await f.message(turn4.body.reply.id)).toMatchObject({ refs: expect.objectContaining({ proposal: expect.objectContaining({ state: "adopted" }), action_ids: [actionId] }) });

        // 같은 제출을 다시 보내면 저장된 답 그대로 (모델 호출 0)
        models = { decide: fakeDecide({ intent: "adopt" }), complete: fakeComplete(reply()) };
        const replay = await send("그렇게 해", adoptClient);
        expect(replay.status).toBe(200);
        expect(replay.body.reply.id).toBe(turn5.body.reply.id);
        expect(models.decide).not.toHaveBeenCalled();

        // 다시 채택 (다른 메시지): 새 Action 없이 그 Action을 가리킨다
        const turn6 = await send("그렇게 해");
        expect(turn6.body.reply.text).toBe("이미 추가한 할 일이에요: Shape 출시 준비");
        expect(turn6.body.reply.refs.action_ids).toEqual([actionId]);
        expect((await f.actionCounts(me)).actions).toBe(1);
      } finally {
        vi.unstubAllEnvs();
      }
    });

    it("기억 · 원문 읽기는 B1 정책대로: 이 범위 + 전체의 지금 explicit · observed만 (다른 범위 · 추정 · 잊음 · 정정됨 · 만료 · 접근 잃은 문서 제외), 범위 version을 함께 적는다 (ARCH05 대화 쪽)", async () => {
      vi.stubEnv("MEMORY_ENABLED", "true");
      try {
        const me = await f.user();
        const c1 = await f.context(me, "Shape");
        const c2 = await f.context(me, "다른 프로젝트");
        const okSource = (await f.one(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'doc', 'Shape 출시는 목요일. 디자인 확정 뒤 개발 시작.', now()) returning id`, [me])).id as string;
        const lostSource = (await f.one(`insert into public.sources (user_id, kind, raw_text, occurred_at, external_id) values ($1, 'doc', '비공개로 바뀐 문서: 예산은 3천만 원', now(), 'doc-lost') returning id`, [me])).id as string;
        const remember = async (item: Record<string, unknown>) => (await f.one(`select * from public.remember_memory_item($1, $2::jsonb)`, [me, JSON.stringify(item)])).id as string;
        await remember(explicitItem({ statement: "전체: 금요일엔 회의 없음", subject: "회의 규칙", kind: "working_rule" }));
        await remember(explicitItem({ scope_kind: "context", context_id: c1, statement: "Shape: 개발은 Sonnet 5.5로" }));
        await remember(explicitItem({ scope_kind: "context", context_id: c2, statement: "다른 프로젝트: 개발은 Opus" }));
        await remember(explicitItem({ scope_kind: "context", context_id: c1, subject: "추정", statement: "추정: 디자이너가 바쁨", origin: "inferred", confidence: 0.6 }));
        const revoked = await remember(explicitItem({ scope_kind: "context", context_id: c1, subject: "잊을 것", statement: "잊은 기억" }));
        await db().query(`update public.memory_items set revoked_at = now() where id = $1`, [revoked]);
        await remember(explicitItem({ scope_kind: "context", context_id: c1, subject: "만료", statement: "만료된 기억", valid_until: "2026-01-01T00:00:00Z" }));
        await remember(explicitItem({ scope_kind: "context", context_id: c1, kind: "fact", subject: "출시일", statement: "출시는 목요일", origin: "observed", source_ref: { source_id: okSource, quote: "Shape 출시는 목요일" } }));
        await remember(explicitItem({ scope_kind: "context", context_id: c1, kind: "fact", subject: "예산", statement: "예산은 3천만 원", origin: "observed", source_ref: { source_id: lostSource, quote: "예산은 3천만 원" } }));
        const action = (await f.one(`insert into public.actions (user_id, title) values ($1, 'Shape 출시') returning id`, [me])).id as string;
        await db().query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, 'Shape 출시는 목요일', 'created'), ($1, $2, $4, '예산은 3천만 원', 'updated')`, [me, action, okSource, lostSource]);
        await db().query(`select public.set_sources_access($1, $2::uuid[], true)`, [me, [lostSource]]);
        const version = Number((await f.one(`select context_version from public.work_contexts where id = $1`, [c1])).context_version);

        const admin = sqlAdmin((sql, params) => db().query(sql, params));
        const context = await loadConsultContext(admin, me, { contextId: c1, query: "출시", chunks: false, deadline: Date.now() + 60_000, now: new Date() });
        expect(context.memory.map((m) => m.statement).sort()).toEqual(["Shape: 개발은 Sonnet 5.5로", "전체: 금요일엔 회의 없음", "출시는 목요일"].sort());
        expect(context.memory.every((m) => m.origin !== ("inferred" as never))).toBe(true);
        expect(context.contextVersion).toBe(version);
        expect(context.sources.map((s) => s.id)).toEqual([okSource]); // 접근을 잃은 문서의 원문은 넣지 않는다
        expect(context.openActions[0].quotes).toEqual([{ sourceId: okSource, quote: "Shape 출시는 목요일" }]);
        expect(context.openActions[0].in_scope).toBe(false); // 이 범위의 멤버가 아니다 (멤버십은 S3b)
      } finally {
        vi.unstubAllEnvs();
      }
    });

    it("ARCH24 (대화 쪽): 메시지 글이 비워져도 그 메시지에서 저장한 explicit 기억은 남고, 창에는 글이 비었다고 표시된다", async () => {
      const me = await f.user();
      const conversation = await f.conversation(me);
      const posted = await f.post(me, conversation, randomUUID(), "개발은 Opus 5.5로 할 거야");
      const done = await f.finish(me, posted.message_id!, { memory: [{ item: explicitItem({ source_ref: { message_id: posted.message_id, quote: "개발은 Opus 5.5로 할 거야" } }) }] });
      await db().query(`update public.conversation_messages set text = '', content = null where conversation_id = $1`, [conversation]);
      expect(await f.memoryItem(done.memory_ids[0])).toMatchObject({ statement: "개발은 Opus 5.5로", source_ref: { message_id: posted.message_id, quote: "개발은 Opus 5.5로 할 거야" } });
      const window = await loadWindow(sqlAdmin((sql, params) => db().query(sql, params)), me, conversation, 99);
      expect(window.messages.map((m) => m.textExpired)).toEqual([true, true]);
    });

    it("Codex P2: 같은 client_message_id를 다시 보낼 때 고른 대상(refs)이 다르면 409 mismatch — 순서 · 중복만 다르면 같은 제출, 다시 처리할 때는 처음 고른 대상", async () => {
      const me = await f.user();
      const admin = sqlAdmin((sql, params) => db().query(sql, params));
      const created = await createConversation(admin, me, {});
      const conversationId = created.status === "created" ? created.conversation.id : "";
      const action = async (title: string) => (await f.one(`insert into public.actions (user_id, title) values ($1, $2) returning id`, [me, title])).id as string;
      const a = await action("견적서 보내기");
      const b = await action("회의록 정리");
      const failing = { decide: fakeDecide(() => { throw new Error("공급자 오류"); }), complete: fakeComplete(reply()) };
      const working = { decide: fakeDecide({ intent: "modify" }), complete: fakeComplete(reply()) };
      let models: Models = failing;
      const send = sender(admin, me, conversationId, () => models);
      const client = randomUUID();
      const text = "이거 마무리해줘";

      expect((await send({ client_message_id: client, text, refs: { action_ids: [a] } })).status).toBe(500); // 모델 실패: 메시지는 남고 처리 표시는 풀림
      models = working;
      const swapped = await send({ client_message_id: client, text, refs: { action_ids: [b] } });
      expect(swapped.status).toBe(409);
      expect(swapped.body.error.message).toBe("같은 client_message_id로 다른 대상을 보냈습니다."); // 글 불일치와 구분
      expect(working.decide).not.toHaveBeenCalled();

      const same = await send({ client_message_id: client, text, refs: { action_ids: [a, a] } }); // 중복만 다름 = 같은 제출
      expect(same.status).toBe(200);
      expect(same.body.message.refs.action_ids).toEqual([a]);
      expect((await send({ client_message_id: client, text, refs: { action_ids: [b] } })).status).toBe(409); // 완료 뒤에도 다른 대상은 그 답을 받지 못한다
      expect((await send({ client_message_id: client, text, refs: { action_ids: [a] } })).body.reply.id).toBe(same.body.reply.id);

      const other = randomUUID();
      models = failing;
      expect((await send({ client_message_id: other, text: "둘 다 해줘", refs: { action_ids: [a, b] } })).status).toBe(500);
      models = working;
      expect((await send({ client_message_id: other, text: "둘 다 해줘", refs: { action_ids: [b, a] } })).status).toBe(200); // 순서만 다름 = 같은 제출
      const noRefs = randomUUID();
      models = failing;
      expect((await send({ client_message_id: noRefs, text: "이건?" })).status).toBe(500);
      models = working;
      expect((await send({ client_message_id: noRefs, text: "이건?", refs: { action_ids: [a] } })).status).toBe(409); // 처음엔 대상 없음 → 대상 추가도 다른 제출
    });

    it("Codex 최종 delta P2: 대소문자만 다른 같은 id를 함께 보내도 유효한 대상 1개 (404 아님) — 재시도는 같은 제출, 내 다른 대상은 409, 남의 · 없는 대상은 404 · 저장 0", async () => {
      // 이 어댑터(sqlAdmin)의 .in은 id::text 견주기라 실제 uuid 열의 대소문자 무시와 다르다. 그래서 여기서는 소유 확인에 정규화한(소문자) 선택이 가는지를 보이고,
      // uuid 열 비교 자체(대문자도 한 행)는 tests/conversation/refs-canonical.test.ts의 작은 PGlite(id = any($::uuid[]))로 본다
      const me = await f.user();
      const them = await f.user();
      const admin = sqlAdmin((sql, params) => db().query(sql, params));
      const created = await createConversation(admin, me, {});
      const conversationId = created.status === "created" ? created.conversation.id : "";
      const action = async (owner: string, title: string) => (await f.one(`insert into public.actions (user_id, title) values ($1, $2) returning id`, [owner, title])).id as string;
      const a = await action(me, "견적서 보내기");
      const b = await action(me, "회의록 정리");
      const theirs = await action(them, "남의 할 일");
      const send = sender(admin, me, conversationId, () => ({ decide: fakeDecide({ intent: "modify" }), complete: fakeComplete(reply()) }));
      const messages = () => f.count(`select count(*)::int as n from public.conversation_messages where conversation_id = $1`, [conversationId]);
      const client = randomUUID();
      const text = "이거 마무리해줘";

      const first = await send({ client_message_id: client, text, refs: { action_ids: [a, a.toUpperCase()] } });
      expect(first.status).toBe(200);
      expect(first.body.message.refs.action_ids).toEqual([a]);
      expect(await messages()).toBe(2);

      const retry = await send({ client_message_id: client, text, refs: { action_ids: [a.toUpperCase()] } }); // 대문자만 다름 = 같은 제출
      expect(retry.status).toBe(200);
      expect(retry.body.reply.id).toBe(first.body.reply.id);

      const other = await send({ client_message_id: client, text, refs: { action_ids: [b, b.toUpperCase()] } }); // 내 다른 대상
      expect(other.status).toBe(409);
      expect(other.body.error.message).toBe("같은 client_message_id로 다른 대상을 보냈습니다.");

      for (const ids of [[theirs], [theirs.toUpperCase()], [a, theirs], [randomUUID()], [a, a.toUpperCase(), randomUUID()]]) {
        const rejected = await send({ client_message_id: randomUUID(), text, refs: { action_ids: ids } });
        expect(rejected.status, ids.join()).toBe(404);
      }
      expect(await messages()).toBe(2);
    });

    it("A04: 열린 할 일이 많아도 조건 조회로 전체 수를 센다 (top-k 검색이 아님) · 남의 할 일 id를 대상으로 보내면 404 · 저장 0", async () => {
      const me = await f.user();
      const them = await f.user();
      for (let i = 0; i < 12; i++) await db().query(`insert into public.actions (user_id, title) values ($1, $2)`, [me, `할 일 ${i + 1}`]);
      await db().query(`insert into public.actions (user_id, title, status, last_activity_at) values ($1, '주간 보고서 보내기', 'done', now())`, [me]);
      await db().query(`insert into public.actions (user_id, title) values ($1, '남의 할 일')`, [them]);
      const theirAction = (await f.one(`select id from public.actions where user_id = $1`, [them])).id as string;
      const admin = sqlAdmin((sql, params) => db().query(sql, params));
      const context = await loadConsultContext(admin, me, { contextId: null, query: "오늘 남은 일", chunks: true, deadline: Date.now() + 60_000, now: new Date() });
      expect(context.openTotal).toBe(12);
      expect(context.openActions).toHaveLength(12);
      expect(context.doneRecent.map((a) => a.title)).toEqual(["주간 보고서 보내기"]);
      expect(context.memory).toEqual([]); // MEMORY_ENABLED 꺼짐: 기억을 읽지 않는다

      expect(await verifySelected(admin, me, { action_ids: [theirAction] })).toEqual({ missing: true });
      const mine = (await f.one(`select id from public.actions where user_id = $1 and status = 'open' limit 1`, [me])).id as string;
      expect(await verifySelected(admin, me, { action_ids: [mine] })).toEqual({ targets: [{ kind: "action", id: mine, title: expect.any(String) }] });
    });
  });
}
