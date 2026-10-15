import { randomUUID } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import type { SupabaseClient } from "@supabase/supabase-js";

import { createUserAction, deleteAction, editAction } from "@/lib/actions/service";
import { changeContextMembership } from "@/lib/context/member-writes";
import { cardAskText, cardWrites, deletePayload, mergePayload, type CardPayload } from "@/lib/conversation/organize";
import { newProposal } from "@/lib/conversation/proposal";
import { confirmProposal, dismissProposal, loadChangeTargets, organizeLookup, planConfirmation } from "@/lib/conversation/store";

import { sqlAdmin } from "../conversation/sql-admin";

import { conversationAgentFixtures, type ConversationAgentDb } from "./conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "./local-supabase";

// 0.2.0 OA D4c-2 · D4c-3b (20261125000000_issue_organize) — 이슈 이동 · 삭제 · 병합과 organize 의도의 DB 쪽.
// 같은 시나리오를 PGlite(tests/db/issue-organize.test.ts)와 실제 Postgres(tests/pg/issue-organize.test.ts)에서 돈다. 동시성은 실제 Postgres 파일에만 있다.
// 이 파일의 T번호는 계약(handoffs/oa-d4c2-contract.md 6.1)과 같다.

export type OrganizeDb = ConversationAgentDb;
export type Rows = Record<string, unknown>[];

export const ORGANIZE_MIGRATION = "20261125000000_issue_organize.sql";
const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");
const ON = { MEMORY_ENABLED: "true" };
const NO_SELECTION = { action_ids: [], run_ids: [], artifact_ids: [] };

type Finished = { status: string; reply_id: string | null; reply_seq: number | null; memory_ids: string[]; action_id: string | null };
type MoveItem = { action_id: string; add: { context_id: string; expected_version: number } | null; remove: { context_id: string; expected_version: number } | null };

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 · 호출 */
export function organizeFixtures(db: () => OrganizeDb) {
  const g = conversationAgentFixtures(db);
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);
  // sqlAdmin(tests/conversation/sql-admin.ts)이 아직 모르는 supabase-js 호출 .returns()를 더한다 (loadClaims가 쓴다): 같은 빌더를 돌려주는 타입 표시일 뿐이다
  const admin = () => {
    // 실제 Postgres의 pg 클라이언트는 JS 배열을 PG 배열 글자로 바꾼다: write_action의 jsonb 인자(p_claims · p_evidence · p_events)는 JSON 글로 보낸다 (PGlite는 인자 형을 보고 알아서 한다)
    // .not(path, "is", null)도 모른다 (service.ts mergedInto가 쓴다: after->>status가 있는 이벤트만): .is에 표시를 달아 보내고 SQL을 보내기 전에 `is not null`로 바꾼다
    const client = sqlAdmin((sql, params) =>
      db().query(sql.replace(/__not_null__(\w+)->>(\w+) is null/g, "($1->>'$2') is not null"), /public\.(write_action|set_action_progress)\(/.test(sql) ? params?.map((v) => (Array.isArray(v) ? JSON.stringify(v) : v)) : params),
    );
    const from = client.from.bind(client);
    client.from = ((table: string) => {
      const builder = from(table) as unknown as { returns?: () => unknown; is: (column: string, value: null) => unknown; not?: (column: string, operator: string, value: unknown) => unknown };
      builder.returns = () => builder;
      builder.not = (column, operator, value) => {
        if (operator !== "is" || value !== null) throw new Error(`가짜가 모르는 필터: ${column} ${operator}`);
        return builder.is(`__not_null__${column}`, null);
      };
      return builder;
    }) as unknown as typeof client.from;
    return client;
  };

  const f = {
    ...g,
    q,
    admin,
    /** 번호가 매겨진 Action (제목 · 상태) */
    async issue(userId: string, title = "Shape 디자인 확정", status = "open"): Promise<{ id: string; number: number }> {
      const row = (await q(`insert into public.actions (user_id, title, status) values ($1, $2, $3) returning id, number`, [userId, title, status]))[0];
      return { id: row.id as string, number: Number(row.number) };
    },
    /** 범위 (보관 가능) */
    async project(userId: string, name = "Launch", status: "active" | "archived" = "active"): Promise<string> {
      const id = (await q(`insert into public.work_contexts (user_id, name, kind, status) values ($1, $2, 'project', $3) returning id`, [userId, name, status]))[0].id as string;
      return id;
    },
    /** 멤버십 행 하나 (코드 규칙이 넣듯: auto · inferred · 사용자가 뺀 행) */
    async member(userId: string, contextId: string, actionId: string, origin: "user" | "auto" | "inferred" = "user", removed = false) {
      await q(
        `insert into public.context_members (user_id, context_id, member_kind, action_id, origin, confidence, removed_at)
         values ($1, $2, 'action', $3, $4, $5, $6)`,
        [userId, contextId, actionId, origin, origin === "inferred" ? 0.6 : null, removed ? new Date().toISOString() : null],
      );
    },
    async version(contextId: string): Promise<number> {
      return Number((await q(`select context_version from public.work_contexts where id = $1`, [contextId]))[0].context_version);
    },
    /** 지금 멤버 (removed_at 없음) */
    async current(actionId: string) {
      return (await q(`select context_id, origin from public.context_members where action_id = $1 and removed_at is null order by context_id`, [actionId])) as { context_id: string; origin: string }[];
    },
    async moved(userId: string) {
      return (await q(`select action_id, props from public.metric_events where user_id = $1 and type = 'issue_moved' order by at, id`, [userId])) as { action_id: string; props: Record<string, unknown> }[];
    },
    async conversationWith(userId: string): Promise<string> {
      return (await q(`insert into public.conversations (user_id) values ($1) returning id`, [userId]))[0].id as string;
    },
    /** 사용자 메시지 하나 (처리 중 표시 포함) */
    async userMessage(userId: string, conversationId: string, text = "#139 옮겨줘"): Promise<string> {
      return String((await g.post(userId, conversationId, randomUUID(), text)).message_id);
    },
    finish: async (userId: string, messageId: string, turn: Record<string, unknown>) =>
      (await g.one(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [userId, messageId, JSON.stringify(turn)])) as Finished,
    /** 답 한 번의 쓰기 모양: 말로 이동 */
    moveTurn(moves: MoveItem[], numbers: Record<string, number> = {}, extra: Record<string, unknown> = {}) {
      return {
        user: { intent: { kind: "organize", confidence: 0.95, judge_version: "intent-v2" }, refs: {} },
        reply: {
          text: "Moved",
          refs: { action_ids: moves.map((m) => m.action_id), context_ids: [...new Set(moves.flatMap((m) => [m.add?.context_id, m.remove?.context_id]).filter(Boolean))] },
          content: {
            segments: [{ text: "Moved", tier: "T1" }],
            organize: {
              state: "moved",
              results: moves.map((m) => ({ action_id: m.action_id, number: numbers[m.action_id] ?? 1, from_context_id: m.remove?.context_id ?? null, to_context_id: m.add?.context_id ?? null, change: null })),
            },
          },
        },
        memory: [],
        adopt: null,
        move: moves,
        ...extra,
      };
    },
    /** 한 사용자가 쓸 수 있는 world: 범위 A · B, A에 들어 있는 Action, 대화, 아직 답하지 않은 사용자 메시지 */
    async world() {
      const user = await g.user();
      const a = await f.project(user, "Taskforce 0.2.0");
      const b = await f.project(user, "Launch");
      const issue = await f.issue(user);
      await f.member(user, a, issue.id);
      const conversation = await f.conversationWith(user);
      const message = await f.userMessage(user, conversation);
      return { user, a, b, issue, conversation, message };
    },
    message: async (id: string) =>
      (await g.one(`select id, seq, role, text, refs, content, reply_to, reply_lease_until from public.conversation_messages where id = $1`, [id])) as {
        id: string;
        seq: number;
        role: string;
        text: string;
        refs: Record<string, unknown> & { proposal?: { state: string; id: string } | null; action_ids?: string[] };
        content: { organize?: { results?: { change: { added: { context_id: string; context_version: number }[]; removed: { context_id: string; context_version: number }[] } | null }[] } & Record<string, unknown> } | null;
        reply_to: string | null;
        reply_lease_until: unknown;
      },
    /** 열린 제안을 낸 assistant 답 하나 (kind: move · delete · merge · create_action) */
    async proposalMessage(userId: string, conversationId: string, kind: string, extra: { hash?: string; actionIds?: string[]; proposalId?: string } = {}) {
      const posted = await g.post(userId, conversationId, randomUUID(), "제안을 받을 메시지");
      const proposalId = extra.proposalId ?? randomUUID();
      const hash = extra.hash ?? `sha256:${"a".repeat(64)}`;
      const done = await f.finish(userId, String(posted.message_id), {
        reply: {
          text: "묻는 글",
          refs: { action_ids: extra.actionIds ?? [], proposal: { id: proposalId, kind, payload_hash: hash, state: "open" } },
          content: { segments: [{ text: "묻는 글", tier: "T5" }], citations: [], proposal: kind === "create_action" ? { kind, title: "Shape 출시 준비" } : { kind }, asks: kind === "move" ? "adopt" : "confirm" },
        },
      });
      return { messageId: done.reply_id!, proposalId, hash };
    },
  };
  return f;
}

/** 삭제 · 병합 카드 쪽 시드: 실제 경로(createUserAction)로 만든 이슈 + 카드(제안 delete · merge) 메시지 */
export function organizeCardFixtures(db: () => OrganizeDb) {
  const f = organizeFixtures(db);
  const c = {
    ...f,
    /** 실제 직접 추가 경로로 만든 이슈: 사용자 Claim(제목 · 담당 · 열림), user_created 이벤트가 있고 번호는 트리거가 정한다 */
    async realIssue(userId: string, title = "견적서 보내기"): Promise<{ id: string; number: number }> {
      const summary = await createUserAction(f.admin(), userId, { title, dueDate: null, source: null, embedding: null });
      const number = Number((await f.one(`select number from public.actions where id = $1`, [summary.id])).number);
      return { id: summary.id, number };
    },
    /** 한 이슈의 값 · Claim · 근거 · 이벤트 수와 실행 run (병합이 아무것도 옮기지 않는지 견주는 스냅샷) */
    async snapshot(actionId: string) {
      return {
        action: await f.one(`select title, status, owner, version, needs_confirmation, confirm_reasons from public.actions where id = $1`, [actionId]),
        claims: await f.q(`select id, field, value, origin, action_id from public.claims where action_id = $1 order by id`, [actionId]),
        evidence: await f.q(`select id, action_id from public.evidence where action_id = $1 order by id`, [actionId]),
        runs: await f.q(`select id, action_id, state from public.execution_runs where action_id = $1 order by id`, [actionId]),
      };
    },
    events: (actionId: string) => f.q(`select type, actor, before, after, rule from public.action_events where action_id = $1 order by created_at, id`, [actionId]),
    /** 카드 한 장: 이슈 id들의 지금 기록으로 카드 내용을 만들고(organize_lookup), 열린 제안을 낸 assistant 답을 쓴다 */
    async card(userId: string, conversationId: string, kind: "delete" | "merge", ids: string[]) {
      const lookup = await organizeLookup(f.admin(), userId, { numbers: [], actionIds: ids });
      const find = (id: string) => lookup.actions.find((a) => a.id === id)!;
      const payload: CardPayload = kind === "delete" ? deletePayload(ids.map(find)) : mergePayload(find(ids[0]), find(ids[1]));
      const made = newProposal(payload, randomUUID);
      const message = await f.userMessage(userId, conversationId, kind === "delete" ? "지워줘" : "합쳐줘");
      const done = await f.finish(userId, message, {
        reply: {
          text: cardAskText("ko", payload),
          refs: { action_ids: ids, proposal: made.ref },
          content: { segments: [{ text: cardAskText("ko", payload), tier: "T5" }], citations: [], proposal: payload, asks: "confirm" },
        },
      });
      return { messageId: done.reply_id!, proposalId: made.ref.id, hash: made.ref.payload_hash, payload };
    },
    confirm: (userId: string, conversationId: string, proposalId: string) => confirmProposal(f.admin(), userId, conversationId, proposalId),
    dismiss: (userId: string, conversationId: string, proposalId: string) => dismissProposal(f.admin(), userId, conversationId, proposalId),
    async eventRows(conversationId: string) {
      return f.q(`select id, seq, role, text, refs, content, reply_to from public.conversation_messages where conversation_id = $1 and role = 'event' order by seq`, [conversationId]);
    },
    async cards(conversationId: string) {
      return f.q(
        `select id, seq, refs, content, reply_to from public.conversation_messages where conversation_id = $1 and role = 'assistant' and refs -> 'proposal' is not null order by seq`,
        [conversationId],
      );
    },
  };
  return c;
}

/** 함수 하나의 정의 문장 (create [or replace] function … $$;) — 파일 안에서 이름으로 찾는다 */
export function functionText(sql: string, name: string): string {
  const start = sql.search(new RegExp(`create (?:or replace )?function public\\.${name}\\(`));
  expect(start, `${name} 정의를 찾는다`).toBeGreaterThanOrEqual(0);
  const end = sql.indexOf("\n$$;", start);
  expect(end).toBeGreaterThan(start);
  return sql.slice(start, end + 4);
}

const squash = (text: string) => text.replace(/create or replace function/, "create function").replace(/\s+/g, " ").trim();
/** 표시한 블록(`-- D4c-2 시작` … `-- D4c-2 끝`)을 뺀다 */
const withoutMarked = (text: string) => text.replace(/^[ \t]*-- D4c-2 시작[^\n]*\n[\s\S]*?^[ \t]*-- D4c-2 끝[^\n]*\n/gm, "");
/** 바뀐 한 줄: 표시 줄을 빼고 바뀐 글자를 원래 글자로 되돌린다 ([바뀐 글자, 원래 글자], 바뀐 글자는 정확히 한 번 있어야 한다) */
const withoutChange = (text: string, [changed, original]: [string, string]) => {
  const stripped = text.replace(/^[ \t]*-- D4c-2 변경[^\n]*\n/gm, "");
  expect(stripped.split(changed).length - 1, `바뀐 글자 ${changed}는 정확히 한 번`).toBe(1);
  return stripped.replace(changed, original);
};

async function sqlOf(file: string) {
  return readFile(path.join(MIGRATIONS_DIR, file), "utf8");
}

/** T4 본문 동일성: 통째로 교체한 함수는 원본과 (표시한 블록 · 바뀐 한 줄을 빼면) 글자 그대로 같다 */
export function bodyEqualityTests() {
  describe("T4 본문 동일성 (통째 교체한 함수)", () => {
    it("conversation_finish_turn: 표시한 D4c-2 블록을 빼면 B2 원본(20261106000000)과 같다", async () => {
      const original = functionText(await sqlOf("20261106000000_conversations_v2.sql"), "conversation_finish_turn");
      const replaced = functionText(await sqlOf(ORGANIZE_MIGRATION), "conversation_finish_turn");
      expect(replaced).toContain("-- D4c-2 시작");
      expect(squash(withoutMarked(replaced))).toBe(squash(original));
    });

    it("coordinator_recover_missing: 결정 회수 목록의 user_merged 한 줄만 다르다 (D1b 20261114000000 원본과)", async () => {
      const original = functionText(await sqlOf("20261114000000_conversation_agent_target.sql"), "coordinator_recover_missing");
      const replaced = functionText(await sqlOf(ORGANIZE_MIGRATION), "coordinator_recover_missing");
      expect(replaced).toContain("-- D4c-2 변경");
      expect(squash(withoutChange(replaced, [", 'user_merged')", ")"]))).toBe(squash(original));
    });

    it("match_actions_for_ask: 지운 것을 빼는 조건 한 줄만 user_merged까지 넓었다 (ASK 20261004000000 원본과)", async () => {
      const original = functionText(await sqlOf("20261004000000_ask.sql"), "match_actions_for_ask");
      const replaced = functionText(await sqlOf(ORGANIZE_MIGRATION), "match_actions_for_ask");
      expect(replaced).toContain("-- D4c-2 변경");
      expect(squash(withoutChange(replaced, ["e.type in ('user_deleted', 'user_merged')", "e.type = 'user_deleted'"]))).toBe(squash(original));
    });
  });
}

export function organizeMoveTests(db: () => OrganizeDb) {
  const f = organizeFixtures(db);

  // ───────────────────────── T6 메뉴 이동 측정 래퍼 ─────────────────────────
  describe("T6 change_context_membership_with_metric: 실제 변화가 있을 때만 issue_moved 한 줄", () => {
    const call = (userId: string, actionId: string, add: [string, number] | null, remove: [string, number] | null, via = "menu") =>
      f.one(`select * from public.change_context_membership_with_metric($1, $2, $3, $4, $5, $6, $7)`, [userId, actionId, add?.[0] ?? null, add?.[1] ?? null, remove?.[0] ?? null, remove?.[1] ?? null, via]) as Promise<{
        status: string;
        added_changed: boolean;
        removed_changed: boolean;
        added_version: number | null;
        removed_version: number | null;
      }>;

    it("넣기: 지표 한 줄(via menu, from null · to 범위), 결과 행은 by_user와 같은 모양", async () => {
      const user = await f.user();
      const b = await f.project(user, "Launch");
      const issue = await f.issue(user);
      const result = await call(user, issue.id, [b, await f.version(b)], null);
      expect(result).toMatchObject({ status: "ok", added_changed: true, removed_changed: false, removed_version: null });
      expect(result.added_version).toBe(await f.version(b));
      expect(await f.moved(user)).toEqual([{ action_id: issue.id, props: { via: "menu", from_context: null, to_context: b } }]);
    });

    it("빼기는 to null, 옮기기는 둘 다. 이미 그 상태면 0행", async () => {
      const user = await f.user();
      const a = await f.project(user, "A");
      const b = await f.project(user, "B");
      const issue = await f.issue(user);
      await f.member(user, a, issue.id);
      expect(await call(user, issue.id, [b, await f.version(b)], [a, await f.version(a)], "talk")).toMatchObject({ status: "ok", added_changed: true, removed_changed: true });
      expect(await f.moved(user)).toEqual([{ action_id: issue.id, props: { via: "talk", from_context: a, to_context: b } }]);
      // 다시 같은 요청: 도착은 이미 멤버 · 출발은 이미 뺌 → 바뀐 것이 없다 (0행 늘어남)
      expect(await call(user, issue.id, [b, await f.version(b)], [a, await f.version(a)])).toMatchObject({ status: "ok", added_changed: false, removed_changed: false });
      expect(await f.moved(user)).toHaveLength(1);
      // 빼기만
      expect(await call(user, issue.id, null, [b, await f.version(b)])).toMatchObject({ status: "ok", removed_changed: true });
      expect((await f.moved(user))[1].props).toEqual({ via: "menu", from_context: b, to_context: null });
    });

    it("conflict · context_not_found · action_not_found는 0행, 모르는 via는 22023", async () => {
      const user = await f.user();
      const other = await f.user();
      const b = await f.project(user, "B");
      const theirs = await f.project(other, "Theirs");
      const issue = await f.issue(user);
      expect((await call(user, issue.id, [b, (await f.version(b)) + 3], null)).status).toBe("conflict");
      expect((await call(user, issue.id, [theirs, 1], null)).status).toBe("context_not_found");
      expect((await call(user, randomUUID(), [b, await f.version(b)], null)).status).toBe("action_not_found");
      expect(await f.moved(user)).toEqual([]);
      await expect(call(user, issue.id, [b, await f.version(b)], null, "voice")).rejects.toThrow(/via|22023|menu/i);
      await expect(f.q(`select * from public.change_context_membership_with_metric($1, $2, $3, $4, null, null, null)`, [user, issue.id, b, await f.version(b)])).rejects.toThrow();
      expect(await f.moved(user)).toEqual([]);
    });

    it("메뉴 route의 서버 쓰기(changeContextMembership)는 via menu로 센다. 응답 값은 by_user 그대로", async () => {
      const user = await f.user();
      const a = await f.project(user, "A");
      const b = await f.project(user, "B");
      const issue = await f.issue(user);
      await f.member(user, a, issue.id);
      const outcome = await changeContextMembership(
        f.admin(),
        user,
        { actionId: issue.id, remove: { contextId: a, expectedVersion: await f.version(a) }, add: { contextId: b, expectedVersion: await f.version(b) } },
        ON,
      );
      expect(outcome).toMatchObject({ status: "ok", added: { changed: true }, removed: { changed: true } });
      expect(await f.moved(user)).toEqual([{ action_id: issue.id, props: { via: "menu", from_context: a, to_context: b } }]);
      // conflict는 지표 0
      const stale = await changeContextMembership(f.admin(), user, { actionId: issue.id, add: { contextId: a, expectedVersion: 99 } }, ON);
      expect(stale.status).toBe("conflict");
      expect(await f.moved(user)).toHaveLength(1);
    });
  });

  // ───────────────────────── T5 말로 이동 (finish_turn p_turn.move) ─────────────────────────
  describe("T5 말로 이동: 멤버십 · 지표 · 답이 한 트랜잭션", () => {
    it("멤버십(origin user) · issue_moved {via talk} 한 줄 · 답 한 줄, 답의 change는 쓰기 직후 version", async () => {
      const w = await f.world();
      const move: MoveItem = { action_id: w.issue.id, add: { context_id: w.b, expected_version: await f.version(w.b) }, remove: { context_id: w.a, expected_version: await f.version(w.a) } };
      const done = await f.finish(w.user, w.message, f.moveTurn([move], { [w.issue.id]: w.issue.number }));
      expect(done.status).toBe("written");
      expect(await f.current(w.issue.id)).toEqual([{ context_id: w.b, origin: "user" }]);
      expect(await f.moved(w.user)).toEqual([{ action_id: w.issue.id, props: { via: "talk", from_context: w.a, to_context: w.b } }]);
      const reply = await f.message(done.reply_id!);
      expect(reply.reply_to).toBe(w.message);
      expect(reply.content!.organize!.results![0].change).toEqual({
        added: [{ context_id: w.b, context_version: await f.version(w.b) }],
        removed: [{ context_id: w.a, context_version: await f.version(w.a) }],
      });
    });

    it("범위 version이 다르면 conflict: 멤버십 · 지표 · 답이 모두 0, 처리 표시는 풀린다", async () => {
      const w = await f.world();
      const before = await f.q(`select * from public.context_members where user_id = $1 order by id`, [w.user]);
      const stale: MoveItem = { action_id: w.issue.id, add: { context_id: w.b, expected_version: (await f.version(w.b)) + 5 }, remove: null };
      const done = await f.finish(w.user, w.message, f.moveTurn([stale]));
      expect(done.status).toBe("conflict");
      expect(await f.q(`select * from public.context_members where user_id = $1 order by id`, [w.user])).toEqual(before);
      expect(await f.moved(w.user)).toEqual([]);
      expect(await f.q(`select 1 from public.conversation_messages where reply_to = $1`, [w.message])).toEqual([]);
      expect((await f.message(w.message)).reply_lease_until).toBeNull();
    });

    it("두 개 중 둘째가 conflict면 첫째도 되돌린다 (한 턴은 전부 아니면 전부)", async () => {
      const w = await f.world();
      const second = await f.issue(w.user, "두 번째 이슈");
      const c = await f.project(w.user, "Third");
      const ok: MoveItem = { action_id: w.issue.id, add: { context_id: w.b, expected_version: await f.version(w.b) }, remove: null };
      const bad: MoveItem = { action_id: second.id, add: { context_id: c, expected_version: 999 }, remove: null };
      expect((await f.finish(w.user, w.message, f.moveTurn([ok, bad]))).status).toBe("conflict");
      expect(await f.current(w.issue.id)).toEqual([{ context_id: w.a, origin: "user" }]);
      expect(await f.moved(w.user)).toEqual([]);
    });

    it("같은 범위로 둘을 옮겨도 같은 턴의 앞 쓰기가 올린 version 때문에 conflict가 되지 않는다 (처음 본 version 하나만 조건)", async () => {
      const w = await f.world();
      const second = await f.issue(w.user, "두 번째 이슈");
      const seen = await f.version(w.b);
      const moves: MoveItem[] = [
        { action_id: w.issue.id, add: { context_id: w.b, expected_version: seen }, remove: null },
        { action_id: second.id, add: { context_id: w.b, expected_version: seen }, remove: null },
      ];
      const done = await f.finish(w.user, w.message, f.moveTurn(moves));
      expect(done.status).toBe("written");
      expect((await f.moved(w.user)).map((r) => r.action_id).sort()).toEqual([w.issue.id, second.id].sort());
      const reply = await f.message(done.reply_id!);
      const versions = reply.content!.organize!.results!.map((r) => r.change!.added[0].context_version);
      expect(versions[0]).toBeLessThan(versions[1]);
      expect(versions[1]).toBe(await f.version(w.b));
    });

    it("뒤에 새 사용자 메시지가 있으면 stale: 쓰기 0", async () => {
      const w = await f.world();
      await f.userMessage(w.user, w.conversation, "또 다른 말");
      const move: MoveItem = { action_id: w.issue.id, add: { context_id: w.b, expected_version: await f.version(w.b) }, remove: null };
      expect((await f.finish(w.user, w.message, f.moveTurn([move]))).status).toBe("stale");
      expect(await f.current(w.issue.id)).toEqual([{ context_id: w.a, origin: "user" }]);
      expect(await f.moved(w.user)).toEqual([]);
    });

    it("이미 있는 범위에 넣기는 바뀐 것이 없어 지표 0, 도착만 이미 멤버이고 출발을 빼면 from만", async () => {
      const w = await f.world();
      await f.member(w.user, w.b, w.issue.id);
      const move: MoveItem = { action_id: w.issue.id, add: { context_id: w.b, expected_version: await f.version(w.b) }, remove: { context_id: w.a, expected_version: await f.version(w.a) } };
      expect((await f.finish(w.user, w.message, f.moveTurn([move]))).status).toBe("written");
      expect(await f.moved(w.user)).toEqual([{ action_id: w.issue.id, props: { via: "talk", from_context: w.a, to_context: null } }]);
    });

    it("남의 Action · 범위는 conflict로 끝난다 (쓰기 0)", async () => {
      const w = await f.world();
      const other = await f.user();
      const theirs = await f.issue(other, "남의 이슈");
      const theirsProject = await f.project(other, "남의 범위");
      expect((await f.finish(w.user, w.message, f.moveTurn([{ action_id: theirs.id, add: { context_id: w.b, expected_version: await f.version(w.b) }, remove: null }]))).status).toBe("conflict");
      expect((await f.finish(w.user, w.message, f.moveTurn([{ action_id: w.issue.id, add: { context_id: theirsProject, expected_version: 1 }, remove: null }]))).status).toBe("conflict");
      expect(await f.moved(w.user)).toEqual([]);
    });

    it("move는 3개까지, 배열이 아니면 22023", async () => {
      const w = await f.world();
      const extra = [await f.issue(w.user, "둘"), await f.issue(w.user, "셋"), await f.issue(w.user, "넷")];
      const seen = await f.version(w.b);
      const moves = [w.issue, ...extra].map((i): MoveItem => ({ action_id: i.id, add: { context_id: w.b, expected_version: seen }, remove: null }));
      await expect(f.finish(w.user, w.message, f.moveTurn(moves))).rejects.toThrow(/move|22023/i);
      await expect(f.finish(w.user, w.message, f.moveTurn([], {}, { move: { not: "array" } }))).rejects.toThrow(/move|22023/i);
      expect(await f.moved(w.user)).toEqual([]);
    });
  });

  // ───────────────────────── T11 글 채택 (adopt.kind = move) ─────────────────────────
  describe("T11 글 채택: adopt.kind move", () => {
    const adoptMove = (proposal: { messageId: string; proposalId: string; hash: string }, moves: MoveItem[], numbers: Record<string, number>) =>
      f.moveTurn(moves, numbers, {
        move: null,
        adopt: { kind: "move", proposal_message_id: proposal.messageId, proposal_id: proposal.proposalId, payload_hash: proposal.hash, moves },
      });

    it("열린 move 제안을 채택하면 제안이 adopted, 멤버십 · 지표 · 답의 change가 같은 트랜잭션", async () => {
      const w = await f.world();
      const proposal = await f.proposalMessage(w.user, w.conversation, "move", { actionIds: [w.issue.id] });
      const message = await f.userMessage(w.user, w.conversation, "응");
      const move: MoveItem = { action_id: w.issue.id, add: { context_id: w.b, expected_version: await f.version(w.b) }, remove: { context_id: w.a, expected_version: await f.version(w.a) } };
      const done = await f.finish(w.user, message, adoptMove(proposal, [move], { [w.issue.id]: w.issue.number }));
      expect(done.status).toBe("written");
      expect((await f.message(proposal.messageId)).refs.proposal!.state).toBe("adopted");
      expect(await f.current(w.issue.id)).toEqual([{ context_id: w.b, origin: "user" }]);
      expect(await f.moved(w.user)).toEqual([{ action_id: w.issue.id, props: { via: "talk", from_context: w.a, to_context: w.b } }]);
      expect((await f.message(done.reply_id!)).content!.organize!.results![0].change!.added).toEqual([{ context_id: w.b, context_version: await f.version(w.b) }]);
    });

    it("제안이 열려 있지 않거나 hash · 종류가 다르면 conflict (쓰기 0), 두 번째 채택도 conflict", async () => {
      const w = await f.world();
      const move = async () => ({ action_id: w.issue.id, add: { context_id: w.b, expected_version: await f.version(w.b) }, remove: null }) as MoveItem;
      const proposal = await f.proposalMessage(w.user, w.conversation, "move", { actionIds: [w.issue.id] });
      const wrongHash = await f.userMessage(w.user, w.conversation, "응");
      expect((await f.finish(w.user, wrongHash, adoptMove({ ...proposal, hash: "sha256:other" }, [await move()], {}))).status).toBe("conflict");
      const wrongKind = await f.proposalMessage(w.user, w.conversation, "create_action");
      const m2 = await f.userMessage(w.user, w.conversation, "응");
      expect((await f.finish(w.user, m2, adoptMove(wrongKind, [await move()], {}))).status).toBe("conflict");
      expect(await f.moved(w.user)).toEqual([]);

      const open = await f.proposalMessage(w.user, w.conversation, "move", { actionIds: [w.issue.id] });
      const m3 = await f.userMessage(w.user, w.conversation, "응");
      expect((await f.finish(w.user, m3, adoptMove(open, [await move()], {}))).status).toBe("written");
      const m4 = await f.userMessage(w.user, w.conversation, "응");
      expect((await f.finish(w.user, m4, adoptMove(open, [await move()], {}))).status).toBe("conflict");
      expect(await f.moved(w.user)).toHaveLength(1);
    });

    it("모르는 adopt.kind는 22023", async () => {
      const w = await f.world();
      const message = await f.userMessage(w.user, w.conversation, "응");
      await expect(f.finish(w.user, message, { adopt: { kind: "teleport", proposal_message_id: randomUUID(), proposal_id: randomUUID(), payload_hash: "x" } })).rejects.toThrow(/kind|22023/i);
    });
  });

  // ───────────────────────── T14 organize_lookup ─────────────────────────
  describe("T14 organize_lookup: 이 사용자의 확인된 사실만", () => {
    const lookup = (userId: string, numbers: number[], ids: string[]) =>
      f.one(`select public.organize_lookup($1, $2::integer[], $3::uuid[]) as result`, [userId, numbers, ids]).then(
        (row) =>
          (row as { result: { actions: { id: string; number: number; title: string; status: string; version: number; open_sessions: number; evidence_count: number; contexts: { id: string; name: string; status: string; context_version: number }[] }[]; contexts: { id: string; name: string; kind: string; status: string; context_version: number }[] } }).result,
      );

    it("번호로도 id로도 찾고, 남의 번호는 없다. 확인된 멤버십만(user · auto, 뺀 것 · inferred 제외)", async () => {
      const user = await f.user();
      const other = await f.user();
      const [a, b, c, d] = [await f.project(user, "Alpha"), await f.project(user, "Beta"), await f.project(user, "Gamma"), await f.project(user, "Delta")];
      const one = await f.issue(user, "하나");
      const two = await f.issue(user, "둘", "dropped");
      const theirs = await f.issue(other, "남의 것");
      await f.member(user, a, one.id, "user");
      await f.member(user, b, one.id, "auto");
      await f.member(user, c, one.id, "inferred");
      await f.member(user, d, one.id, "user", true);
      const byNumber = await lookup(user, [one.number, two.number, theirs.number + 100], []);
      expect(byNumber.actions.map((x) => x.number).sort()).toEqual([one.number, two.number].sort());
      const first = byNumber.actions.find((x) => x.id === one.id)!;
      expect(first).toMatchObject({ title: "하나", status: "open", version: 0, open_sessions: 0, evidence_count: 0 });
      expect(first.contexts.map((x) => x.name).sort()).toEqual(["Alpha", "Beta"]);
      expect(first.contexts[0]).toMatchObject({ status: "active", context_version: expect.any(Number) });
      expect(byNumber.actions.find((x) => x.id === two.id)!.status).toBe("dropped");
      // id로 찾기 + 합집합
      const byId = await lookup(user, [], [two.id, theirs.id]);
      expect(byId.actions.map((x) => x.id)).toEqual([two.id]);
    });

    it("contexts는 이 사용자의 범위 전부(active · archived), 이름순, 남의 범위 없음", async () => {
      const user = await f.user();
      const other = await f.user();
      await f.project(user, "Zeta");
      await f.project(user, "Alpha", "archived");
      await f.project(other, "남의 범위");
      const result = await lookup(user, [], []);
      expect(result.contexts.map((x) => [x.name, x.status])).toEqual([["Alpha", "archived"], ["Zeta", "active"]]);
      expect(result.contexts[0]).toMatchObject({ kind: "project", context_version: 1 });
    });

    it("open_sessions는 대화 run의 서로 다른 세션 중 닫히지 않은 수, evidence_count는 근거 행 수", async () => {
      const w = await f.agentWorld();
      const issue = (await f.q(`select number from public.actions where id = $1`, [w.action]))[0];
      const second = await f.session(w.user, w.connection, { bound_action_id: w.action });
      await f.agentRun(w.user, w.action, { agent_session_id: second });
      const closed = await f.session(w.user, w.connection, { bound_action_id: w.action });
      await f.agentRun(w.user, w.action, { agent_session_id: closed });
      await f.updateRow("agent_sessions", closed, { status: "closed" });
      // 같은 세션의 끝난 run이 더 있어도 한 세션이다
      await f.agentRun(w.user, w.action, { agent_session_id: second, state: "stopped" });
      const source = await f.q(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'note', '근거', now()) returning id`, [w.user]);
      await f.q(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '근거', 'created'), ($1, $2, $3, '근거', 'updated')`, [w.user, w.action, source[0].id]);
      const result = await lookup(w.user, [Number(issue.number)], []);
      expect(result.actions[0]).toMatchObject({ open_sessions: 2, evidence_count: 2 });
    });

    it("배열은 각각 10개까지 (넘으면 22023)", async () => {
      const user = await f.user();
      const many = Array.from({ length: 11 }, (_, i) => i + 1);
      await expect(lookup(user, many, [])).rejects.toThrow(/22023|too many|10/i);
      await expect(lookup(user, [], many.map(() => randomUUID()))).rejects.toThrow(/22023|too many|10/i);
    });
  });

  // ───────────────────────── T12 권한 (이동 몫) ─────────────────────────
  describe("T12 권한: 새 함수는 service_role 전용 · invoker · search_path 고정", () => {
    const NAMES = ["change_context_membership_with_metric", "organize_lookup", "apply_organize_moves", "apply_organize_change", "conversation_confirm_proposal", "conversation_dismiss_proposal"];
    it("앱(authenticated) · 익명은 부르지 못하고, 정의는 invoker에 search_path = ''", async () => {
      const rows = await f.q(
        `select p.proname, p.prosecdef, p.proconfig, has_function_privilege('authenticated', p.oid, 'execute') as app, has_function_privilege('anon', p.oid, 'execute') as anon,
                has_function_privilege('service_role', p.oid, 'execute') as server
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = any($1) order by p.proname`,
        [NAMES],
      );
      expect(rows).toHaveLength(NAMES.length);
      for (const row of rows) {
        expect(row, String(row.proname)).toMatchObject({ prosecdef: false, app: false, anon: false, server: true });
        expect(row.proconfig).toContain("search_path=\"\"");
      }
    });
  });
}

export function organizeCardTests(db: () => OrganizeDb) {
  const f = organizeCardFixtures(db);
  const q = f.q;
  const count = async (sql: string, params: unknown[] = []) => Number((await f.one(sql, params)).n);

  // ───────────────────────── T1 CHECK ─────────────────────────
  describe("T1 action_events.type에 user_merged", () => {
    it("user_merged(actor user)를 받고 모르는 type은 거절한다. 기존 값은 그대로 받는다", async () => {
      const user = await f.user();
      const issue = await f.realIssue(user);
      const insert = (type: string, actor = "user") => q(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, $3, $4)`, [user, issue.id, type, actor]);
      await insert("user_merged");
      for (const type of ["created", "merged", "user_deleted", "user_edited", "user_seen", "user_notes_updated", "artifact_created", "user_unstarted"]) await insert(type, type === "artifact_created" ? "agent" : "user");
      await expect(insert("user_teleported")).rejects.toThrow(/action_events_type_check|check constraint/i);
      await expect(insert("user_merged", "robot")).rejects.toThrow();
    });
  });

  // ───────────────────────── T2 · T3 코디네이터 ─────────────────────────
  describe("T2 · T3 코디네이터 사건", () => {
    const decisions = (user: string) => q(`select refs from public.inbox_events where user_id = $1 and type = 'decision_made' order by created_at, id`, [user]);

    it("T2 사용자의 user_merged는 decision_made 한 건(refs.kind user_merged). AI가 쓴 merged(중복 근거)는 사건이 아니다", async () => {
      const user = await f.user();
      const issue = await f.realIssue(user);
      await q(`insert into public.action_events (user_id, action_id, type, actor, after) values ($1, $2, 'user_merged', 'user', $3::jsonb)`, [user, issue.id, JSON.stringify({ status: "dropped", into: randomUUID() })]);
      await q(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'merged', 'ai')`, [user, issue.id]);
      const events = (await decisions(user)).filter((e) => (e.refs as { kind: string }).kind !== "user_created");
      expect(events.map((e) => (e.refs as { kind: string }).kind)).toEqual(["user_merged"]);
      expect(events[0].refs).toMatchObject({ action_id: issue.id });
    });

    it("T3 트리거 적재를 삼킨 user_merged를 회수 sweep이 같은 dedup_key로 메운다. 두 번 돌려도 한 번. agent 대화의 사용자 메시지는 여전히 사건이 아니다 (D1b)", async () => {
      const user = await f.user();
      const issue = await f.realIssue(user);
      const eventId = (await f.one(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_merged', 'user') returning id`, [user, issue.id])).id as string;
      await q(`delete from public.inbox_events where user_id = $1 and dedup_key = $2`, [user, `action_event:${eventId}`]);
      expect(await count(`select count(*)::int as n from public.inbox_events where user_id = $1 and dedup_key = $2`, [user, `action_event:${eventId}`])).toBe(0);
      const first = Number((await f.one(`select public.coordinator_recover_missing(3600, 100) as n`)).n);
      expect(first).toBeGreaterThanOrEqual(1);
      expect(await f.one(`select refs from public.inbox_events where user_id = $1 and dedup_key = $2`, [user, `action_event:${eventId}`])).toMatchObject({ refs: { kind: "user_merged", action_event_id: eventId } });
      await f.one(`select public.coordinator_recover_missing(3600, 100)`);
      expect(await count(`select count(*)::int as n from public.inbox_events where user_id = $1 and dedup_key = $2`, [user, `action_event:${eventId}`])).toBe(1);

      const world = await f.agentWorld();
      await f.one(`select public.coordinator_recover_missing(3600, 100)`);
      expect(await f.userMessageEvents(world.user)).toBe(0);
    });
  });

  // ───────────────────────── T7 삭제 확인 ─────────────────────────
  describe("T7 삭제 확인 (카드 버튼)", () => {
    async function scene() {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const issue = await f.realIssue(user, "회의록 정리");
      return { user, conversation, issue };
    }

    it("확인 한 번: 사용자 Claim dropped + user_deleted(삭제 경로와 같은 before · after · rule) + 제안 adopted + 기록 줄(event) 하나", async () => {
      const w = await scene();
      const control = await f.realIssue(w.user, "비교용");
      await deleteAction(f.admin(), w.user, control.id);
      const card = await f.card(w.user, w.conversation, "delete", [w.issue.id]);
      const before = await f.snapshot(w.issue.id);

      const result = await f.confirm(w.user, w.conversation, card.proposalId);
      expect(result).toMatchObject({ status: "confirmed", op: "delete", actionIds: [w.issue.id], eventId: expect.any(String) });
      const after = await f.snapshot(w.issue.id);
      expect(after.action).toMatchObject({ status: "dropped", version: Number(before.action.version) + 1 });
      expect(after.claims).toHaveLength(before.claims.length + 1);
      expect(after.claims.filter((c) => c.origin === "user" && c.field === "status" && c.value === "dropped")).toHaveLength(1);
      expect(after.evidence).toEqual(before.evidence);
      const mine = (await f.events(w.issue.id)).filter((e) => e.type === "user_deleted");
      const theirs = (await f.events(control.id)).filter((e) => e.type === "user_deleted");
      expect(mine).toHaveLength(1);
      expect(mine[0]).toEqual(theirs[0]);

      const [stored] = await f.cards(w.conversation);
      expect(stored.refs).toMatchObject({ proposal: { id: card.proposalId, kind: "delete", state: "adopted" }, action_ids: [w.issue.id] });
      const events = await f.eventRows(w.conversation);
      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({
        id: result.status === "confirmed" ? result.eventId : null,
        role: "event",
        reply_to: null,
        refs: { proposal: { id: card.proposalId, kind: "delete", payload_hash: card.hash, state: "adopted" }, action_ids: [w.issue.id] },
        content: { organize: { state: "deleted", action_ids: [w.issue.id] } },
      });
      expect(String(events[0].text)).toMatch(/^지웠어요: #\d+$/);
      expect(Number(events[0].seq)).toBeGreaterThan(Number(stored.seq));
      expect((await f.one(`select last_message_at from public.conversations where id = $1`, [w.conversation])).last_message_at).not.toBeNull();
    });

    it("두 번 눌러도 쓰기 한 번: 둘째는 already (Claim · 이벤트 · 기록 줄 증가 0), 기록 줄 id는 첫째와 같다", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "delete", [w.issue.id]);
      const first = await f.confirm(w.user, w.conversation, card.proposalId);
      const counts = async () => ({ claims: await count(`select count(*)::int as n from public.claims where action_id = $1`, [w.issue.id]), events: await count(`select count(*)::int as n from public.action_events where action_id = $1`, [w.issue.id]), rows: await count(`select count(*)::int as n from public.conversation_messages where conversation_id = $1`, [w.conversation]) });
      const before = await counts();
      const again = await f.confirm(w.user, w.conversation, card.proposalId);
      expect(again).toMatchObject({ status: "already", op: "delete", actionIds: [w.issue.id], eventId: first.status === "confirmed" ? first.eventId : null });
      expect(await counts()).toEqual(before);
    });

    it("카드 뒤에 수정되면(version+1) 쓰기 0 · 409 superseded: 앞 카드는 superseded, 지금 기록으로 새 카드 한 장 (열림 · asks confirm · 새 version)", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "delete", [w.issue.id]);
      await editAction(f.admin(), w.user, w.issue.id, { title: "회의록 정리 (고침)" });
      const before = await f.snapshot(w.issue.id);
      const result = await f.confirm(w.user, w.conversation, card.proposalId);
      expect(result).toMatchObject({ status: "superseded", cardMessageId: expect.any(String) });
      expect(await f.snapshot(w.issue.id)).toEqual(before);
      expect(await f.eventRows(w.conversation)).toEqual([]);
      const cards = await f.cards(w.conversation);
      expect(cards).toHaveLength(2);
      expect(cards[0].refs).toMatchObject({ proposal: { id: card.proposalId, state: "superseded" } });
      expect(cards[1]).toMatchObject({ id: result.status === "superseded" ? result.cardMessageId : null, reply_to: null });
      expect(cards[1].refs).toMatchObject({ proposal: { kind: "delete", state: "open" } });
      expect(cards[1].content).toMatchObject({ asks: "confirm", proposal: { kind: "delete", targets: [{ action_id: w.issue.id, title: "회의록 정리 (고침)", version: Number(before.action.version) }] } });
      // 새 카드는 확인할 수 있다
      const next = (cards[1].refs as { proposal: { id: string } }).proposal.id;
      expect(await f.confirm(w.user, w.conversation, next)).toMatchObject({ status: "confirmed" });
      expect((await f.snapshot(w.issue.id)).action).toMatchObject({ status: "dropped" });
      // 앞 카드는 이제 열려 있지 않다
      expect(await f.confirm(w.user, w.conversation, card.proposalId)).toEqual({ status: "not_open" });
    });

    it("대상이 카드 뒤에 이미 지워졌으면 superseded이고 새 카드는 없다 (쓰기 0)", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "delete", [w.issue.id]);
      await deleteAction(f.admin(), w.user, w.issue.id);
      const before = await f.snapshot(w.issue.id);
      expect(await f.confirm(w.user, w.conversation, card.proposalId)).toEqual({ status: "superseded", cardMessageId: null });
      expect(await f.snapshot(w.issue.id)).toEqual(before);
      expect((await f.cards(w.conversation)).map((c) => (c.refs as { proposal: { state: string } }).proposal.state)).toEqual(["superseded"]);
    });

    it("취소 → dismissed, 그 뒤 확인은 not_open, 다시 취소는 already, 확인을 마친 카드의 취소는 not_open", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "delete", [w.issue.id]);
      const before = await f.snapshot(w.issue.id);
      expect(await f.dismiss(w.user, w.conversation, card.proposalId)).toBe("dismissed");
      expect(await f.confirm(w.user, w.conversation, card.proposalId)).toEqual({ status: "not_open" });
      expect(await f.dismiss(w.user, w.conversation, card.proposalId)).toBe("already");
      expect(await f.snapshot(w.issue.id)).toEqual(before);
      expect((await f.cards(w.conversation))[0].refs).toMatchObject({ proposal: { state: "dismissed" } });

      const second = await f.card(w.user, w.conversation, "delete", [w.issue.id]);
      expect(await f.confirm(w.user, w.conversation, second.proposalId)).toMatchObject({ status: "confirmed" });
      expect(await f.dismiss(w.user, w.conversation, second.proposalId)).toBe("not_open");
    });

    it("없는 · 남의 · 삭제 병합이 아닌 제안 · 에이전트 대화는 not_found (쓰기 0)", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "delete", [w.issue.id]);
      const other = await f.user();
      expect(await f.confirm(w.user, w.conversation, randomUUID())).toEqual({ status: "not_found" });
      expect(await f.dismiss(w.user, w.conversation, randomUUID())).toBe("not_found");
      expect(await f.confirm(other, w.conversation, card.proposalId)).toEqual({ status: "not_found" });
      expect(await f.dismiss(other, w.conversation, card.proposalId)).toBe("not_found");
      const create = await f.proposalMessage(w.user, w.conversation, "create_action");
      expect(await f.confirm(w.user, w.conversation, create.proposalId)).toEqual({ status: "not_found" });
      expect(await f.dismiss(w.user, w.conversation, create.proposalId)).toBe("not_found");
      const world = await f.agentWorld();
      expect(await f.confirm(world.user, world.conversation, randomUUID())).toEqual({ status: "not_found" });
      expect((await f.snapshot(w.issue.id)).action).toMatchObject({ status: "open" });
    });

    it("이슈 둘을 한 번에 지운다 (같은 트랜잭션). 하나가 카드 뒤에 바뀌면 둘 다 쓰지 않는다", async () => {
      const w = await scene();
      const second = await f.realIssue(w.user, "두 번째");
      const card = await f.card(w.user, w.conversation, "delete", [w.issue.id, second.id]);
      await editAction(f.admin(), w.user, second.id, { title: "두 번째 (고침)" });
      expect(await f.confirm(w.user, w.conversation, card.proposalId)).toMatchObject({ status: "superseded" });
      expect((await f.snapshot(w.issue.id)).action).toMatchObject({ status: "open" });
      const fresh = (await f.cards(w.conversation))[1];
      const next = (fresh.refs as { proposal: { id: string } }).proposal.id;
      const confirmed = await f.confirm(w.user, w.conversation, next);
      expect(confirmed.status === "confirmed" ? [...confirmed.actionIds].sort() : null).toEqual([w.issue.id, second.id].sort());
      expect((await f.snapshot(w.issue.id)).action).toMatchObject({ status: "dropped" });
      expect((await f.snapshot(second.id)).action).toMatchObject({ status: "dropped" });
    });
  });

  // ───────────────────────── T8 병합 ─────────────────────────
  describe("T8 병합 확인", () => {
    async function scene() {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const gone = await f.realIssue(user, "견적서 보내기 (중복)");
      const stays = await f.realIssue(user, "견적서 보내기");
      for (const issue of [gone, stays]) {
        const source = await f.one(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'note', '근거 글', now()) returning id`, [user]);
        await q(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '근거 글', 'created')`, [user, issue.id, source.id]);
        await f.run(user, issue.id);
      }
      return { user, conversation, gone, stays };
    }

    it("사라지는 쪽 dropped + user_merged{after.into}, 남는 쪽의 값 · version · Claim · 근거는 그대로, 두 이슈의 Claim · 근거 · run의 action_id는 하나도 옮겨지지 않는다", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "merge", [w.gone.id, w.stays.id]);
      const before = { gone: await f.snapshot(w.gone.id), stays: await f.snapshot(w.stays.id) };
      const staysEvents = (await f.events(w.stays.id)).length;

      const result = await f.confirm(w.user, w.conversation, card.proposalId);
      expect(result).toMatchObject({ status: "confirmed", op: "merge" });
      expect(result.status === "confirmed" ? [...result.actionIds].sort() : []).toEqual([w.gone.id, w.stays.id].sort());
      const after = { gone: await f.snapshot(w.gone.id), stays: await f.snapshot(w.stays.id) };
      expect(after.stays).toEqual(before.stays); // 남는 쪽: version · Claim 수 · 근거 · run 모두 그대로
      expect((await f.events(w.stays.id)).length).toBe(staysEvents);
      expect(after.gone.action).toMatchObject({ status: "dropped", version: Number(before.gone.action.version) + 1 });
      expect(after.gone.claims.map((c) => c.id)).toEqual(expect.arrayContaining(before.gone.claims.map((c) => c.id)));
      expect(after.gone.claims).toHaveLength(before.gone.claims.length + 1);
      expect(after.gone.evidence).toEqual(before.gone.evidence);
      expect(after.gone.runs.map((r) => r.id)).toEqual(before.gone.runs.map((r) => r.id));
      for (const rows of [after.gone.claims, after.gone.evidence, after.gone.runs, after.stays.claims, after.stays.evidence, after.stays.runs]) {
        for (const row of rows) expect([w.gone.id, w.stays.id]).toContain(row.action_id);
      }
      const merged = (await f.events(w.gone.id)).filter((e) => e.type === "user_merged");
      expect(merged).toEqual([expect.objectContaining({ actor: "user", before: { status: "open" }, after: { status: "dropped", into: w.stays.id }, rule: "user" })]);
      expect((await f.events(w.gone.id)).filter((e) => e.type === "user_deleted")).toEqual([]);
      const events = await f.eventRows(w.conversation);
      expect(events[0]).toMatchObject({ content: { organize: { state: "merged", from_action_id: w.gone.id, into_action_id: w.stays.id } } });
      expect(String(events[0].text)).toMatch(/^합쳤어요: #\d+ → #\d+$/);
    });

    it("병합 Undo: 기존 PATCH status open이 user_edited를 남기고 그 before에 into가 실린다 (다시 열린다). 병합이 아닌 삭제 Undo에는 into가 없다", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "merge", [w.gone.id, w.stays.id]);
      await f.confirm(w.user, w.conversation, card.proposalId);
      await editAction(f.admin(), w.user, w.gone.id, { status: "open" });
      expect((await f.snapshot(w.gone.id)).action).toMatchObject({ status: "open" });
      const undo = (await f.events(w.gone.id)).filter((e) => e.type === "user_edited");
      expect(undo).toEqual([expect.objectContaining({ before: { status: "dropped", into: w.stays.id }, after: { status: "open" } })]);

      const plain = await f.realIssue(w.user, "그냥 지움");
      await deleteAction(f.admin(), w.user, plain.id);
      await editAction(f.admin(), w.user, plain.id, { status: "open" });
      expect((await f.events(plain.id)).filter((e) => e.type === "user_edited")).toEqual([expect.objectContaining({ before: { status: "dropped" }, after: { status: "open" } })]);
    });

    it("남는 쪽이 카드 뒤에 지워졌거나 수정되면 superseded: 사라지는 쪽도 쓰지 않는다 (두 번째 시나리오는 새 카드가 있다)", async () => {
      const w = await scene();
      const card = await f.card(w.user, w.conversation, "merge", [w.gone.id, w.stays.id]);
      await deleteAction(f.admin(), w.user, w.stays.id);
      const goneBefore = await f.snapshot(w.gone.id);
      expect(await f.confirm(w.user, w.conversation, card.proposalId)).toEqual({ status: "superseded", cardMessageId: null });
      expect(await f.snapshot(w.gone.id)).toEqual(goneBefore);

      const v = await scene();
      const second = await f.card(v.user, v.conversation, "merge", [v.gone.id, v.stays.id]);
      await editAction(f.admin(), v.user, v.stays.id, { title: "견적서 보내기 (고침)" });
      const result = await f.confirm(v.user, v.conversation, second.proposalId);
      expect(result).toMatchObject({ status: "superseded", cardMessageId: expect.any(String) });
      expect((await f.snapshot(v.gone.id)).action).toMatchObject({ status: "open" });
      expect((await f.cards(v.conversation))[1].content).toMatchObject({ proposal: { kind: "merge", into: { title: "견적서 보내기 (고침)" } } });
    });
  });

  // ───────────────────────── T7b · T8b TS가 읽은 뒤 쓰기 전에 바뀐 경우 (낡은 쓰기 계획을 SQL이 막는다) ─────────────────────────
  describe("낡은 쓰기 계획: TS가 카드 그대로라고 읽은 뒤 쓰기 전에 대상이 바뀌어도 SQL이 막는다 (changed, 쓰기 0, 카드는 열린 채)", () => {
    const direct = async (userId: string, conversationId: string, proposalId: string, plan: Record<string, unknown>) =>
      (await f.q(`select * from public.conversation_confirm_proposal($1, $2, $3, $4::jsonb)`, [userId, conversationId, proposalId, JSON.stringify(plan)]))[0];

    it("삭제: 이슈를 읽은 뒤 고쳐졌다 (write_action의 version 조건)", async () => {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const issue = await f.realIssue(user, "회의록");
      const card = await f.card(user, conversation, "delete", [issue.id]);
      const planned = (await planConfirmation(f.admin(), user, conversation, card.proposalId))!;
      expect((planned.plan.writes as unknown[]).length).toBe(1);
      await editAction(f.admin(), user, issue.id, { title: "회의록 (고침)" });
      const before = await f.snapshot(issue.id);
      expect(await direct(user, conversation, card.proposalId, planned.plan)).toMatchObject({ status: "changed", event_id: null, card_id: null });
      expect(await f.snapshot(issue.id)).toEqual(before);
      expect((await f.cards(conversation))[0].refs).toMatchObject({ proposal: { state: "open" } });
      expect(await f.eventRows(conversation)).toEqual([]);
    });

    it("confirmProposal은 changed를 받으면 새로 읽어 계획한다: 쓰기 0 · 지금 기록(고친 제목 · 새 version)의 새 카드 한 장 · superseded (쓰기 직전에 끼어든 수정)", async () => {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const issue = await f.realIssue(user, "회의록");
      const card = await f.card(user, conversation, "delete", [issue.id]);
      const base = f.admin();
      let raced = false;
      // TS가 계획을 세운 직후, SQL이 돌기 전에 같은 이슈를 고친다 (v1 PATCH가 끼어듦)
      const racing = {
        from: base.from.bind(base),
        rpc: (fn: string, args: Record<string, unknown>) =>
          fn === "conversation_confirm_proposal" && !raced
            ? {
                single: () => ({
                  throwOnError: async () => {
                    raced = true;
                    await editAction(base, user, issue.id, { title: "회의록 (고침)" });
                    return base.rpc(fn, args).single().throwOnError();
                  },
                }),
              }
            : base.rpc(fn, args),
      } as unknown as SupabaseClient;
      const result = await confirmProposal(racing, user, conversation, card.proposalId);
      expect(raced).toBe(true);
      expect(result).toMatchObject({ status: "superseded", cardMessageId: expect.any(String) });
      expect((await f.snapshot(issue.id)).action).toMatchObject({ status: "open", title: "회의록 (고침)" });
      const cards = await f.cards(conversation);
      expect(cards).toHaveLength(2);
      expect(cards[1].content).toMatchObject({ proposal: { kind: "delete", targets: [{ title: "회의록 (고침)" }] } });
      expect(await f.eventRows(conversation)).toEqual([]);
    });

    it("병합: 남는 쪽이 읽은 뒤 고쳐졌다 (남는 쪽 확인의 version 조건) — 사라지는 쪽도 쓰지 않는다. 남는 쪽을 지웠어도 마찬가지", async () => {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const gone = await f.realIssue(user, "중복");
      const stays = await f.realIssue(user, "원본");
      const card = await f.card(user, conversation, "merge", [gone.id, stays.id]);
      const planned = (await planConfirmation(f.admin(), user, conversation, card.proposalId))!;
      expect((planned.plan.writes as { action: unknown }[]).map((w) => w.action === null)).toEqual([false, true]);
      await editAction(f.admin(), user, stays.id, { title: "원본 (고침)" });
      const goneBefore = await f.snapshot(gone.id);
      expect(await direct(user, conversation, card.proposalId, planned.plan)).toMatchObject({ status: "changed" });
      expect(await f.snapshot(gone.id)).toEqual(goneBefore);
      expect((await f.snapshot(stays.id)).action).toMatchObject({ status: "open", title: "원본 (고침)" });
      expect(await f.eventRows(conversation)).toEqual([]);
      expect((await f.cards(conversation))[0].refs).toMatchObject({ proposal: { state: "open" } });
    });
  });

  // ───────────────────────── T9 Done과 같은 규칙 ─────────────────────────
  describe("T9 열린 대화 run 정리 (Done과 같은 규칙)", () => {
    it("지운 이슈의 열린 대화 run은 stopped, 진행 중 턴에만 cancel 요청, 같은 세션의 다른 이슈 run은 그대로", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user);
      const connection = await f.agentConnection(user, bridge);
      const doomed = await f.realIssue(user, "지울 이슈");
      const other = await f.realIssue(user, "다른 이슈");
      const session = await f.session(user, connection, { bound_action_id: doomed.id });
      const doomedRun = await f.agentRun(user, doomed.id, { agent_session_id: session });
      const otherRun = await f.agentRun(user, other.id, { agent_session_id: session });
      const agentConversation = await f.agentConversation(user, connection, session);
      const sent = await f.post(user, agentConversation, randomUUID(), "이어서 해 줘");
      const task = await f.task(user, doomedRun, session, { message_id: sent.message_id, turn_seq: 1, state: "running" });
      const conversation = await f.conversationWith(user);
      const card = await f.card(user, conversation, "delete", [doomed.id]);

      expect(await f.confirm(user, conversation, card.proposalId)).toMatchObject({ status: "confirmed" });
      expect((await f.one(`select state from public.execution_runs where id = $1`, [doomedRun])).state).toBe("stopped");
      expect((await f.one(`select state from public.execution_runs where id = $1`, [otherRun])).state).not.toBe("stopped");
      expect((await f.one(`select cancel_requested_at from public.agent_tasks where id = $1`, [task])).cancel_requested_at).not.toBeNull();
      expect(await count(`select count(*)::int as n from public.execution_steps where run_id = $1 and kind = 'agent_cancel'`, [doomedRun])).toBe(1);
      expect(await count(`select count(*)::int as n from public.execution_steps where run_id = $1 and kind = 'agent_cancel'`, [otherRun])).toBe(0);
    });
  });

  // ───────────────────────── Q20 지운 이슈를 "현재 이슈"로 가진 세션의 다음 메시지 ─────────────────────────
  describe("Q20 삭제 뒤 같은 세션의 다음 메시지 (기록: 지금 동작 그대로, 이번 WP는 바꾸지 않는다)", () => {
    it("지운 이슈의 열린 대화 run은 멈추고, 이슈 칩 없는 다음 메시지는 새 이슈를 만든다 (D1c-1의 닫힌 이슈 규칙 그대로)", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user);
      const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
      const agentConversation = await f.agentConversation(user, connection);
      const start = async (message: string, actions: string[] = []) =>
        (await f.one(`select public.start_agent_turn($1, $2, $3::uuid[], '{}'::uuid[], 'read_only', 4) as result`, [user, message, actions])).result as {
          status: string;
          action_id: string;
          run_id: string;
          agent_task_id: string;
          created_action?: boolean;
        };
      const first = await start(String((await f.post(user, agentConversation, randomUUID(), "첫 이슈")).message_id));
      expect(first.status).toBe("started");
      await f.updateRow("agent_tasks", first.agent_task_id, { state: "idle" });

      const conversation = await f.conversationWith(user);
      const card = await f.card(user, conversation, "delete", [first.action_id]);
      expect(await f.confirm(user, conversation, card.proposalId)).toMatchObject({ status: "confirmed" });
      expect((await f.one(`select state from public.execution_runs where id = $1`, [first.run_id])).state).toBe("stopped");

      const next = await start(String((await f.post(user, agentConversation, randomUUID(), "새 일")).message_id));
      expect(next).toMatchObject({ status: "started", created_action: true });
      expect(next.action_id).not.toBe(first.action_id);
      expect((await f.one(`select status from public.actions where id = $1`, [first.action_id])).status).toBe("dropped");
    });
  });

  // ───────────────────────── T10 물어보기 제외 ─────────────────────────
  describe("T10 물어보기 검색에서 병합으로 닫은 중복도 뺀다", () => {
    const vector = `[${Array.from({ length: 1536 }, (_, i) => (i === 0 ? 1 : 0)).join(",")}]`;
    it("user_merged로 닫힌 Action은 결과에서 빠지고, 지운 것도 그대로 빠진다. 열린 것 · 이벤트 없이 취소된 것은 나온다", async () => {
      const user = await f.user();
      const make = async (title: string, status: string) =>
        (await f.one(`insert into public.actions (user_id, title, embedding, status) values ($1, $2, $3::extensions.vector, $4) returning id`, [user, title, vector, status])).id as string;
      const open = await make("열림", "open");
      const merged = await make("병합됨", "dropped");
      const deleted = await make("지움", "dropped");
      const dropped = await make("AI가 취소", "dropped");
      await q(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_merged', 'user'), ($1, $3, 'user_deleted', 'user')`, [user, merged, deleted]);
      const rows = await q(`select id from public.match_actions_for_ask($1, $2::extensions.vector, 10)`, [user, vector]);
      expect(rows.map((r) => r.id).sort()).toEqual([open, dropped].sort());
    });
  });

  // ───────────────────────── T11 글 채택 ─────────────────────────
  describe("T11 글 채택(adopt.kind delete · merge)이 버튼 경로와 같은 행을 만든다", () => {
    const adoptTurn = (card: { messageId: string; proposalId: string; hash: string }, kind: "delete" | "merge", writes: unknown[]) => ({
      user: { intent: { kind: "adopt", confidence: 0.95, judge_version: "intent-v2" }, refs: {} },
      reply: { text: "지웠어요", refs: {}, content: { segments: [{ text: "지웠어요", tier: "T1" }] } },
      adopt: { kind, proposal_message_id: card.messageId, proposal_id: card.proposalId, payload_hash: card.hash, writes },
    });
    const writesOf = async (userId: string, payload: CardPayload, ids: string[]) => cardWrites(userId, payload, await loadChangeTargets(f.admin(), userId, ids), new Date(), randomUUID);

    it("삭제: 같은 행 (Action 값 · Claim 모양 · 이벤트), 제안 adopted, 답 한 줄", async () => {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const viaButton = await f.realIssue(user, "버튼으로 지움");
      const viaText = await f.realIssue(user, "버튼으로 지움");
      const buttonCard = await f.card(user, conversation, "delete", [viaButton.id]);
      await f.confirm(user, conversation, buttonCard.proposalId);
      const textCard = await f.card(user, conversation, "delete", [viaText.id]);
      const message = await f.userMessage(user, conversation, "응 지워");
      const done = await f.finish(user, message, adoptTurn(textCard, "delete", await writesOf(user, textCard.payload, [viaText.id])));
      expect(done.status).toBe("written");

      const [a, b] = [await f.snapshot(viaButton.id), await f.snapshot(viaText.id)];
      expect(b.action).toEqual(a.action);
      const shape = (claims: Rows) => claims.map((c) => `${c.field}:${c.value}:${c.origin}`).sort();
      expect(shape(b.claims)).toEqual(shape(a.claims));
      expect(await f.events(viaText.id)).toEqual(await f.events(viaButton.id));
      const cards = await f.cards(conversation);
      expect(cards.find((c) => (c.refs as { proposal: { id: string } }).proposal.id === textCard.proposalId)!.refs).toMatchObject({ proposal: { state: "adopted" }, action_ids: [viaText.id] });
      expect((await f.message(done.reply_id!)).reply_to).toBe(message);
    });

    it("병합: 사라지는 쪽 dropped + user_merged, 남는 쪽은 그대로", async () => {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const gone = await f.realIssue(user, "중복");
      const stays = await f.realIssue(user, "원본");
      const card = await f.card(user, conversation, "merge", [gone.id, stays.id]);
      const staysBefore = await f.snapshot(stays.id);
      const message = await f.userMessage(user, conversation, "응 합쳐");
      expect((await f.finish(user, message, adoptTurn(card, "merge", await writesOf(user, card.payload, [gone.id, stays.id])))).status).toBe("written");
      expect((await f.snapshot(gone.id)).action).toMatchObject({ status: "dropped" });
      expect((await f.events(gone.id)).filter((e) => e.type === "user_merged")).toEqual([expect.objectContaining({ after: { status: "dropped", into: stays.id } })]);
      expect(await f.snapshot(stays.id)).toEqual(staysBefore);
    });

    it("카드 뒤에 대상이 바뀌었거나, 제안이 열려 있지 않거나, hash가 다르면 conflict (쓰기 0, 처리 표시는 풀림)", async () => {
      const user = await f.user();
      const conversation = await f.conversationWith(user);
      const issue = await f.realIssue(user, "회의록");
      const card = await f.card(user, conversation, "delete", [issue.id]);
      const stale = await writesOf(user, card.payload, [issue.id]);
      await editAction(f.admin(), user, issue.id, { title: "회의록 (고침)" });
      const before = await f.snapshot(issue.id);
      const m1 = await f.userMessage(user, conversation, "응 지워");
      expect((await f.finish(user, m1, adoptTurn(card, "delete", stale))).status).toBe("conflict");
      expect(await f.snapshot(issue.id)).toEqual(before);
      expect((await f.message(m1)).reply_lease_until).toBeNull();

      // 제안이 이미 쓰였으면(채택됨) 같은 쓰기를 다시 보내도 conflict다
      const fresh = await f.card(user, conversation, "delete", [issue.id]);
      const m2 = await f.userMessage(user, conversation, "응 지워");
      expect((await f.finish(user, m2, adoptTurn(fresh, "delete", await writesOf(user, fresh.payload, [issue.id])))).status).toBe("written");
      const m3 = await f.userMessage(user, conversation, "응 지워");
      expect((await f.finish(user, m3, adoptTurn(fresh, "delete", await writesOf(user, fresh.payload, [issue.id])))).status).toBe("conflict");
      const dismissed = await f.card(user, conversation, "delete", [issue.id]);
      await f.dismiss(user, conversation, dismissed.proposalId);
      const m4 = await f.userMessage(user, conversation, "응 지워");
      expect((await f.finish(user, m4, adoptTurn(dismissed, "delete", []))).status).toBe("conflict");
      expect((await f.finish(user, m4, adoptTurn({ ...dismissed, hash: "sha256:other" }, "delete", []))).status).toBe("conflict");
    });
  });

  // ───────────────────────── T12 권한 (카드 몫) ─────────────────────────
  describe("T12 권한: 앱(authenticated)은 새 함수를 부르지 못한다", () => {
    it("확인 · 취소 · 쓰기 함수 직접 실행은 거절 (service role 전용)", async () => {
      const user = await f.user();
      const calls = [
        `select * from public.conversation_confirm_proposal('${user}', '${randomUUID()}', '${randomUUID()}', '{}'::jsonb)`,
        `select public.conversation_dismiss_proposal('${user}', '${randomUUID()}', '${randomUUID()}')`,
        `select public.apply_organize_change('${user}', 'delete', '[]'::jsonb)`,
        `select public.organize_lookup('${user}', '{}'::integer[], '{}'::uuid[])`,
        `select * from public.change_context_membership_with_metric('${user}', '${randomUUID()}', null, null, null, null, 'menu')`,
      ];
      for (const sql of calls) await expect(db().asUser(user, () => db().query(sql)), sql).rejects.toThrow(/permission denied/i);
    });
  });
}

/** 업그레이드 시험이 여는 새 DB (tests/db/action-numbers.scenarios.ts FreshDb와 같다) */
export type FreshDb = {
  exec: (sql: string) => Promise<unknown>;
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
};

/** T13 업그레이드: 20261123까지 적용 → 옛 데이터 → 이 파일 적용. 기존 행 · 제안은 그대로이고 새 제약을 통과하며, 바뀐 것은 계약이 말한 객체뿐이다 */
export function organizeUpgradeTests(fresh: () => Promise<FreshDb>) {
  describe("T13 업그레이드 (20261123 전 상태 → 적용)", { timeout: 60_000 }, () => {
    async function seed(db: FreshDb) {
      const user = randomUUID();
      await db.query(`insert into auth.users (id, email) values ($1, $2)`, [user, `${user}@example.com`]);
      const action = (await db.query(`insert into public.actions (user_id, title) values ($1, '옛 이슈') returning id`, [user]))[0].id as string;
      await db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_deleted', 'user')`, [user, action]);
      const context = (await db.query(`insert into public.work_contexts (user_id, name, kind) values ($1, 'Launch', 'project') returning id`, [user]))[0].id as string;
      await db.query(`insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user')`, [user, context, action]);
      const conversation = (await db.query(`insert into public.conversations (user_id) values ($1) returning id`, [user]))[0].id as string;
      const userMessage = (await db.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, client_message_id) values ($1, $2, 1, 'user', '추가해줘', $3) returning id`, [user, conversation, randomUUID()]))[0].id as string;
      const proposal = { id: randomUUID(), kind: "create_action", payload_hash: `sha256:${"b".repeat(64)}`, state: "open" };
      await db.query(
        `insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, content, reply_to) values ($1, $2, 2, 'assistant', '추가할까요?', $3::jsonb, $4::jsonb, $5)`,
        [user, conversation, JSON.stringify({ proposal }), JSON.stringify({ proposal: { kind: "create_action", title: "옛 제안" }, asks: "adopt" }), userMessage],
      );
      return { user, action, context, conversation };
    }
    const rowsOf = async (db: FreshDb) => ({
      actions: JSON.stringify(await db.query(`select * from public.actions order by id`)),
      events: JSON.stringify(await db.query(`select * from public.action_events order by id`)),
      members: JSON.stringify(await db.query(`select * from public.context_members order by id`)),
      messages: JSON.stringify(await db.query(`select * from public.conversation_messages order by seq`)),
    });

    it("옛 행 · 열린 제안이 한 글자도 바뀌지 않고, 새 type과 새 함수가 쓸 수 있다", async () => {
      const { before, migration } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const w = await seed(db);
      const rows = await rowsOf(db);
      await expect(db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_merged', 'user')`, [w.user, w.action])).rejects.toThrow(/check constraint|action_events_type_check/i);
      await db.exec(migration);
      expect(await rowsOf(db)).toEqual(rows);
      await db.query(`insert into public.action_events (user_id, action_id, type, actor, after) values ($1, $2, 'user_merged', 'user', '{"into": "x"}'::jsonb)`, [w.user, w.action]);
      expect((await db.query(`select indexname from pg_indexes where indexname = 'action_events_user_merged_into_idx'`)).length).toBe(1);
      expect((await db.query(`select (public.organize_lookup($1, '{}'::integer[], array[$2]::uuid[])) -> 'actions' -> 0 ->> 'title' as title`, [w.user, w.action]))[0].title).toBe("옛 이슈");
      // 열린 제안(create_action)을 옛 모양 그대로 채택할 수 있다: 열린 제안 확인 쪽만 본다 (kind 없는 adopt는 B2 본문이 받는다)
      const message = (await db.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, client_message_id) values ($1, $2, 3, 'user', '응', $3) returning id`, [w.user, w.conversation, randomUUID()]))[0].id as string;
      const done = (await db.query(`select status from public.conversation_finish_turn($1, $2, '{"reply": {"text": "네"}, "adopt": null}'::jsonb)`, [w.user, message]))[0];
      expect(done.status).toBe("written");
    });

    it("바뀐 객체: 교체한 함수 셋 · 새 함수 여섯 · 트리거 목록 · type 제약 · 새 색인뿐이다 (다른 옛 함수 · 제약 · 트리거는 정의가 그대로)", async () => {
      const { before, migration } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const fingerprint = async () => ({
        functions: await db.query(`select p.oid::regprocedure::text as sig, md5(pg_get_functiondef(p.oid)) as def from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' order by 1`),
        triggers: await db.query(`select c.relname, t.tgname, md5(pg_get_triggerdef(t.oid)) as def from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal order by 1, 2`),
        constraints: await db.query(`select conrelid::regclass::text as tbl, conname, md5(pg_get_constraintdef(oid)) as def from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2`),
        columns: JSON.stringify(await db.query(`select table_name, column_name, data_type from information_schema.columns where table_schema = 'public' order by table_name, ordinal_position`)),
      });
      const old = await fingerprint();
      await db.exec(migration);
      const now = await fingerprint();
      const changed = (a: Rows, b: Rows, key: string) => b.filter((row) => !a.some((o) => JSON.stringify(o) === JSON.stringify(row))).map((row) => String(row[key]));
      expect(changed(old.functions, now.functions, "sig").sort()).toEqual(
        [
          "apply_organize_change(uuid,text,jsonb)",
          "apply_organize_moves(uuid,jsonb,jsonb)",
          "change_context_membership_with_metric(uuid,uuid,uuid,integer,uuid,integer,text)",
          "conversation_confirm_proposal(uuid,uuid,uuid,jsonb)",
          "conversation_dismiss_proposal(uuid,uuid,uuid)",
          "conversation_finish_turn(uuid,uuid,jsonb)",
          "coordinator_recover_missing(integer,integer)",
          "match_actions_for_ask(uuid,extensions.vector,integer,timestamp with time zone)",
          "organize_lookup(uuid,integer[],uuid[])",
        ].sort(),
      );
      expect(old.functions.every((o) => now.functions.some((n) => n.sig === o.sig))).toBe(true);
      expect(changed(old.triggers, now.triggers, "tgname")).toEqual(["coordinator_on_action_decision"]);
      expect(changed(old.constraints, now.constraints, "conname")).toEqual(["action_events_type_check"]);
      expect(now.columns).toBe(old.columns);
    });
  });
}

/** 마이그레이션 목록에서 자기 위치 앞까지 (upgrade 시험이 쓴다, 뒤에 마이그레이션이 더 생겨도 깨지지 않는다) */
export async function splitScripts() {
  const files = (await readdir(MIGRATIONS_DIR)).filter((file) => file.endsWith(".sql")).sort();
  const index = files.indexOf(ORGANIZE_MIGRATION);
  expect(index, `${ORGANIZE_MIGRATION}이 마이그레이션 목록에 있다`).toBeGreaterThan(0);
  const scripts = await supabaseSchemaScripts();
  // scripts[0..1]은 Supabase 흉내 두 개다
  return { before: scripts.slice(0, 2 + index), migration: scripts[2 + index] };
}

export { NO_SELECTION };
