import { randomUUID } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { changeContextMembership } from "@/lib/context/member-writes";

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
  const admin = () => sqlAdmin((sql, params) => db().query(sql, params));

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
/** 바뀐 한 줄: 표시 줄을 빼고 더한 글자만 되돌린다 (정확히 한 번 있어야 한다) */
const withoutChange = (text: string, added: string) => {
  const stripped = text.replace(/^[ \t]*-- D4c-2 변경[^\n]*\n/gm, "");
  expect(stripped.split(added).length - 1, `더한 글자 ${added}는 정확히 한 번`).toBe(1);
  return stripped.replace(added, "");
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
    const NAMES = ["change_context_membership_with_metric", "organize_lookup"];
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
