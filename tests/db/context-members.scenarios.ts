import { randomUUID } from "node:crypto";

import { describe, expect, it } from "vitest";

import { apiErrorV2Schema, contextMemberMoveResponseSchema, contextMemberSchema, contextMembershipResponseSchema } from "@/lib/api/contract";
import { handleChangeContextMember, handleMoveContextMember } from "@/lib/api/context-members";
import { changeContextMembership, type ContextMemberOutcome } from "@/lib/context/member-writes";
import { addContextMember, ContextGateOffError } from "@/lib/context/store";

import { sqlAdmin } from "../conversation/sql-admin";

import { contextLayerFixtures } from "./context-layer.scenarios";

// 0.2.0 S3b 멤버십 쓰기 (20261108000000_context_member_user_writes): 사용자가 할 일을 범위에 넣고 · 빼고 · 옮긴다 (origin user). 조건부 쓰기:
// 요청이 본 범위 version이 지금과 다르면 쓰기 0 + conflict (옛 요청 · 응답을 잃은 재전송 · 늦은 Undo가 더 새 결정을 덮지 못한다). 응답의 실제 변화(change)는 Undo의 입력이다.
// 운영 코드(src/lib/context/member-writes.ts → SQL change_context_membership_by_user)를 그대로 부른다. 같은 시나리오를 PGlite(tests/db/context-members.test.ts)와
// 실제 Postgres(tests/pg/context-members.test.ts)에서 돌린다. 동시성은 실제 Postgres 파일에만 있다.

export type Rows = Record<string, unknown>[];

export type ContextMembersDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

export const ON = { MEMORY_ENABLED: "true" };

type MemberRow = {
  id: string;
  user_id: string;
  context_id: string;
  member_kind: string;
  action_id: string | null;
  origin: "user" | "auto" | "inferred";
  confidence: string | number | null;
  removed_at: Date | null;
  created_at: Date;
  updated_at: Date;
};

type Ok = Extract<ContextMemberOutcome, { status: "ok" }>;

/** Undo가 보낼 요청: 응답의 change(실제 바뀐 멤버)의 역연산만 — Mac이 하는 일과 같다. 되돌릴 것이 없으면 null */
export function undoPlan(ok: Ok) {
  const added = ok.added?.changed ? ok.added : null;
  const removed = ok.removed?.changed ? ok.removed : null;
  if (added && removed) return { kind: "move" as const, from: added.member.context_id, to: removed.member.context_id, expectedFrom: added.contextVersion, expectedTo: removed.contextVersion };
  if (added) return { kind: "remove" as const, context: added.member.context_id, expected: added.contextVersion };
  if (removed) return { kind: "add" as const, context: removed.member.context_id, expected: removed.contextVersion };
  return null;
}

/** Undo를 보낸다 (되돌릴 것이 없으면 null) */
export function undoOf(f: ReturnType<typeof contextMembersFixtures>, userId: string, actionId: string, ok: Ok) {
  const plan = undoPlan(ok);
  if (!plan) return null;
  if (plan.kind === "move") return f.move(userId, actionId, plan.from, plan.to, { expectedFrom: plan.expectedFrom, expectedTo: plan.expectedTo });
  if (plan.kind === "remove") return f.remove(userId, plan.context, actionId, { expected: plan.expected });
  return f.add(userId, plan.context, actionId, { expected: plan.expected });
}

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 · 호출 */
export function contextMembersFixtures(db: () => ContextMembersDb) {
  const base = contextLayerFixtures(db);
  const admin = () => sqlAdmin((sql, params) => db().query(sql, params));
  const count = async (sql: string, params: unknown[] = []) => Number((await base.one(sql, params)).n);

  const f = {
    ...base,
    admin,
    count,
    action: (userId: string, title = "Shape 디자인 확정") => base.id(`insert into public.actions (user_id, title) values ($1, $2) returning id`, [userId, title]),
    /** 자동 규칙 · 모델 후보가 넣은 멤버 (코드 규칙: 서버 store의 addContextMember와 같은 행) */
    seed: (userId: string, contextId: string, actionId: string, origin: "auto" | "inferred" = "auto") =>
      base.id(
        `insert into public.context_members (user_id, context_id, member_kind, action_id, origin, confidence) values ($1, $2, 'action', $3, $4, $5) returning id`,
        [userId, contextId, actionId, origin, origin === "inferred" ? 0.6 : null],
      ),
    async row(contextId: string, actionId: string) {
      return (await db().query(`select * from public.context_members where context_id = $1 and action_id = $2`, [contextId, actionId]))[0] as MemberRow | undefined;
    },
    /** 한 할 일의 멤버십 전부 (뺀 행 포함) */
    rowsOf: async (actionId: string) => (await db().query(`select * from public.context_members where action_id = $1 order by context_id`, [actionId])) as MemberRow[],
    /** 지금 멤버 = removed_at이 없는 행 */
    async current(actionId: string) {
      return (await db().query(`select context_id, origin from public.context_members where action_id = $1 and removed_at is null order by context_id`, [actionId])) as {
        context_id: string;
        origin: string;
      }[];
    },
    /** 두 사용자의 멤버십 표 전체 (바뀌지 않았는지 견주는 스냅샷) */
    snapshot: (...userIds: string[]) => db().query(`select * from public.context_members where user_id = any($1::uuid[]) order by id`, [userIds]),
    /** 요청이 본 version (없는 범위는 1: 남의 · 없는 범위가 conflict가 아니라 not_found임을 보려고) */
    async seen(contextId: string) {
      const rows = await db().query(`select context_version from public.work_contexts where id = $1`, [contextId]);
      return rows[0] ? Number(rows[0].context_version) : 1;
    },
    /** 넣기 · 빼기 · 옮기기: expected를 주지 않으면 앱이 방금 읽은 지금 version을 보낸 것과 같다 */
    async add(userId: string, contextId: string, actionId: string, opts: { expected?: number } = {}) {
      return changeContextMembership(admin(), userId, { actionId, add: { contextId, expectedVersion: opts.expected ?? (await f.seen(contextId)) } }, ON);
    },
    async remove(userId: string, contextId: string, actionId: string, opts: { expected?: number } = {}) {
      return changeContextMembership(admin(), userId, { actionId, remove: { contextId, expectedVersion: opts.expected ?? (await f.seen(contextId)) } }, ON);
    },
    async move(userId: string, actionId: string, from: string, to: string, opts: { expectedFrom?: number; expectedTo?: number } = {}) {
      return changeContextMembership(
        admin(),
        userId,
        {
          actionId,
          remove: { contextId: from, expectedVersion: opts.expectedFrom ?? (await f.seen(from)) },
          add: { contextId: to, expectedVersion: opts.expectedTo ?? (await f.seen(to)) },
        },
        ON,
      );
    },
    archive: (contextId: string) => db().query(`update public.work_contexts set status = 'archived' where id = $1`, [contextId]),
  };
  return f;
}

/** 성공 결과 */
export function okOf(outcome: ContextMemberOutcome): Ok {
  expect(outcome.status).toBe("ok");
  return outcome as Ok;
}

/** 실행·정책·승인·Claim·Action 표 (멤버십 쓰기가 한 줄도 더하지 않아야 한다). context_members는 일부러 뺀다 — 이 쓰기가 바꾸는 표다 */
const AUTHORITY_TABLES = [
  "actions", "claims", "evidence", "action_events", "execution_policies", "execution_runs", "execution_steps", "execution_approvals", "execution_intents",
  "execution_events", "execution_artifacts", "execution_usage", "execution_controls", "execution_tools", "execution_actors", "execution_recipient_allowlist",
  "credit_accounts", "credit_ledger", "memory_items", "conversations", "conversation_messages", "sources",
];

export function contextMembersTests(db: () => ContextMembersDb) {
  const f = contextMembersFixtures(db);

  async function authorityCounts() {
    const counts: Record<string, number> = {};
    for (const table of AUTHORITY_TABLES) counts[table] = await f.count(`select count(*)::int as n from public.${table}`);
    // C2(20261110000000_coordinator_core): 범위 version이 오르는 쓰기는 사건함에 memory_changed 한 줄(id만)을 더한다 — 코디네이터가 읽는 사건이다.
    // 그 밖의 종류의 사건은 이 쓰기가 한 줄도 더하지 않는다 (사건함은 권한 표가 아니라 읽는 큐라서 memory_changed만 예외로 둔다)
    counts["inbox_events (memory_changed 제외)"] = await f.count(`select count(*)::int as n from public.inbox_events where type <> 'memory_changed'`);
    return counts;
  }

  describe("넣기 (add): 그 범위에 origin user 멤버", () => {
    it("새 멤버: origin user · confidence 없음 · 지금 멤버. 범위 version은 정확히 + 1이고 응답의 version은 그 값이다 (스키마를 지킨다). 실제 변화는 added", async () => {
      const me = await f.user();
      const ctx = await f.context(me, "Shape");
      const action = await f.action(me);
      const before = await f.version(ctx);
      const added = okOf(await f.add(me, ctx, action)).added!;
      expect(contextMemberSchema.parse(added.member)).toMatchObject({
        context_id: ctx, member_kind: "action", action_id: action, source_id: null, person_id: null, origin: "user", confidence: null, removed_at: null,
      });
      expect(await f.version(ctx)).toBe(before + 1);
      expect(added).toMatchObject({ contextVersion: before + 1, changed: true });
      expect(await f.current(action)).toEqual([{ context_id: ctx, origin: "user" }]);
      expect(await f.count(`select count(*)::int as n from public.context_members where user_id = $1`, [me])).toBe(1);
    });

    it("이미 user 멤버인 범위에 지금 version으로 다시 넣으면 행을 쓰지 않는다: 같은 행 · 같은 updated_at, version 불변, 바뀐 것 없음 (changed false)", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      const first = okOf(await f.add(me, ctx, action)).added!;
      const rowBefore = await f.row(ctx, action);
      const version = await f.version(ctx);
      const again = okOf(await f.add(me, ctx, action)).added!;
      expect(again.member).toEqual(first.member);
      expect(again).toMatchObject({ contextVersion: version, changed: false });
      expect(await f.row(ctx, action)).toEqual(rowBefore);
      expect(await f.version(ctx)).toBe(version);
    });

    it("auto · inferred 행은 같은 행이 user로 승격되고(confidence 비움) 사용자가 뺀 행은 되살아난다 (removed_at 비움). 행 수는 그대로. 실제 변화: auto는 이미 멤버라 false, inferred 후보 확인 · 뺀 행 되살림은 true", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const [auto, inferred, removed] = [await f.action(me, "auto"), await f.action(me, "inferred"), await f.action(me, "removed")];
      const autoId = await f.seed(me, ctx, auto, "auto");
      const inferredId = await f.seed(me, ctx, inferred, "inferred");
      okOf(await f.add(me, ctx, removed));
      okOf(await f.remove(me, ctx, removed));
      expect((await f.row(ctx, removed))?.removed_at).not.toBeNull();
      const removedId = (await f.row(ctx, removed))!.id;
      const count = await f.count(`select count(*)::int as n from public.context_members where user_id = $1`, [me]);

      const results = [okOf(await f.add(me, ctx, auto)).added!, okOf(await f.add(me, ctx, inferred)).added!, okOf(await f.add(me, ctx, removed)).added!];
      expect(results.map((r) => r.member.id)).toEqual([autoId, inferredId, removedId]);
      for (const { member } of results) expect(member).toMatchObject({ origin: "user", confidence: null, removed_at: null });
      expect(results.map((r) => r.changed)).toEqual([false, true, true]);
      expect(await f.count(`select count(*)::int as n from public.context_members where user_id = $1`, [me])).toBe(count);
      expect((await f.current(auto)).concat(await f.current(inferred), await f.current(removed))).toEqual([ctx, ctx, ctx].map((context_id) => ({ context_id, origin: "user" })));
    });

    it("승격 · 되살림도 범위 version을 한 번 올린다 (B1 트리거: origin · removed_at 변경). 이미 user 멤버면 올리지 않는다", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      await f.seed(me, ctx, action, "inferred");
      const before = await f.version(ctx);
      okOf(await f.add(me, ctx, action));
      expect(await f.version(ctx)).toBe(before + 1);
      okOf(await f.add(me, ctx, action));
      expect(await f.version(ctx)).toBe(before + 1);
    });
  });

  describe("빼기 (remove): 행을 남기고 removed_at — 자동 규칙이 다시 넣지 못한다", () => {
    it("user 멤버를 빼면 행은 남고 removed_at이 선다 (origin user). 범위 version + 1, 지금 멤버에서 빠진다, 실제 변화는 removed. 지금 version으로 다시 빼면 쓰지 않는다 (같은 removed_at, version 불변)", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      okOf(await f.add(me, ctx, action));
      const before = await f.version(ctx);
      const removed = okOf(await f.remove(me, ctx, action)).removed!;
      expect(contextMemberSchema.parse(removed.member)).toMatchObject({ context_id: ctx, action_id: action, origin: "user", confidence: null });
      expect(removed.member.removed_at).not.toBeNull();
      expect(removed).toMatchObject({ contextVersion: before + 1, changed: true });
      expect(await f.version(ctx)).toBe(before + 1);
      expect(await f.current(action)).toEqual([]);
      expect(await f.rowsOf(action)).toHaveLength(1);

      const rowBefore = await f.row(ctx, action);
      const again = okOf(await f.remove(me, ctx, action)).removed!;
      expect(again.member).toEqual(removed.member);
      expect(again).toMatchObject({ contextVersion: before + 1, changed: false });
      expect(await f.row(ctx, action)).toEqual(rowBefore);
      expect(await f.version(ctx)).toBe(before + 1);
    });

    it("auto 멤버를 빼면 같은 행이 origin user + removed_at이 되고 (실제 변화 true), inferred 후보를 빼면 같은 행이 뺀 표시가 되지만 멤버가 바뀐 것은 아니다 (changed false). 둘 다 지금 멤버가 아니다", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const [auto, inferred] = [await f.action(me, "auto"), await f.action(me, "inferred")];
      const autoId = await f.seed(me, ctx, auto, "auto");
      const inferredId = await f.seed(me, ctx, inferred, "inferred");
      const a = okOf(await f.remove(me, ctx, auto)).removed!;
      const i = okOf(await f.remove(me, ctx, inferred)).removed!;
      expect([a.member.id, i.member.id]).toEqual([autoId, inferredId]);
      for (const { member } of [a, i]) {
        expect(member).toMatchObject({ origin: "user", confidence: null });
        expect(member.removed_at).not.toBeNull();
      }
      expect([a.changed, i.changed]).toEqual([true, false]);
      expect((await f.current(auto)).concat(await f.current(inferred))).toEqual([]);
    });

    it("멤버가 아니던 할 일을 빼도 뺀 표시 행을 남긴다 (\"여기 아님\"도 사용자의 선택, 실제 변화는 없음): 자동 규칙이 나중에 넣지 못한다", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      expect(await f.rowsOf(action)).toEqual([]);
      const removed = okOf(await f.remove(me, ctx, action)).removed!;
      expect(removed.member).toMatchObject({ origin: "user", confidence: null });
      expect(removed.member.removed_at).not.toBeNull();
      expect(removed.changed).toBe(false);
      expect(await f.current(action)).toEqual([]);
      await addContextMember(f.admin(), me, ctx, { kind: "action", actionId: action }, { kind: "auto" }, ON);
      expect(await f.rowsOf(action)).toHaveLength(1);
      expect(await f.current(action)).toEqual([]);
    });

    it("사용자가 뺀 멤버를 auto · inferred 쓰기가 되살리지 못한다 (행 · removed_at 유지, 범위 version 불변). 사용자가 다시 넣으면 된다", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      const other = await f.action(me, "다른 일");
      await f.seed(me, ctx, action, "auto");
      okOf(await f.remove(me, ctx, action));
      const rowBefore = await f.row(ctx, action);
      const version = await f.version(ctx);
      await addContextMember(f.admin(), me, ctx, { kind: "action", actionId: action }, { kind: "auto" }, ON);
      await addContextMember(f.admin(), me, ctx, { kind: "action", actionId: action }, { kind: "inferred", confidence: 0.9 }, ON);
      expect(await f.row(ctx, action)).toEqual(rowBefore);
      expect(await f.rowsOf(action)).toHaveLength(1);
      expect(await f.current(action)).toEqual([]);
      expect(await f.version(ctx)).toBe(version);
      // 다른 할 일에는 자동 쓰기가 그대로 된다 (막는 것은 사용자가 뺀 그 멤버뿐)
      await addContextMember(f.admin(), me, ctx, { kind: "action", actionId: other }, { kind: "auto" }, ON);
      expect(await f.current(other)).toEqual([{ context_id: ctx, origin: "auto" }]);
      // 사용자가 다시 넣으면 된다
      expect(okOf(await f.add(me, ctx, action)).added!.member).toMatchObject({ origin: "user", removed_at: null });
    });

    it("사용자가 정한 멤버(user)는 자동 규칙이 덮지 않는다: 같은 멤버의 auto · inferred 쓰기는 그대로 둔다", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      okOf(await f.add(me, ctx, action));
      const rowBefore = await f.row(ctx, action);
      await addContextMember(f.admin(), me, ctx, { kind: "action", actionId: action }, { kind: "auto" }, ON);
      await addContextMember(f.admin(), me, ctx, { kind: "action", actionId: action }, { kind: "inferred", confidence: 0.5 }, ON);
      expect(await f.row(ctx, action)).toEqual(rowBefore);
    });
  });

  describe("조건부 쓰기: 요청이 본 범위 version이 지금과 다르면 쓰기 0 + conflict — 옛 요청이 더 새 사용자 결정을 덮지 못한다 (Codex P2-A)", () => {
    it("응답을 잃은 add A → 다른 기기 remove A → 옛 add A 재전송: conflict, A는 뺀 채 그대로 (반례 1)", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const action = await f.action(me);
      const seen = await f.seen(a); // 기기 1이 본 version
      okOf(await f.add(me, a, action, { expected: seen })); // 응답 유실
      okOf(await f.remove(me, a, action)); // 기기 2 (지금 version을 읽고 보냈다)
      expect(await f.current(action)).toEqual([]);
      const snapshot = await f.snapshot(me);
      const version = await f.version(a);
      expect(await f.add(me, a, action, { expected: seen })).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect(await f.version(a)).toBe(version);
      expect(await f.current(action)).toEqual([]);
    });

    it("응답을 잃은 A → B → 다른 기기 B → C → 옛 A → B 재전송: conflict, 지금 멤버는 C뿐 (B가 되살아나지 않는다) (반례 2)", async () => {
      const me = await f.user();
      const [a, b, c] = [await f.context(me, "A"), await f.context(me, "B"), await f.context(me, "C")];
      const action = await f.action(me);
      okOf(await f.add(me, a, action));
      const seen = { expectedFrom: await f.seen(a), expectedTo: await f.seen(b) };
      okOf(await f.move(me, action, a, b, seen)); // 기기 1: 응답 유실
      okOf(await f.move(me, action, b, c)); // 기기 2
      expect(await f.current(action)).toEqual([{ context_id: c, origin: "user" }]);
      const snapshot = await f.snapshot(me);
      const versions = [await f.seen(a), await f.seen(b), await f.seen(c)];
      expect(await f.move(me, action, a, b, seen)).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect([await f.seen(a), await f.seen(b), await f.seen(c)]).toEqual(versions);
      expect(await f.current(action)).toEqual([{ context_id: c, origin: "user" }]);
    });

    it("응답을 잃은 성공 요청의 재전송은 다른 기기가 없어도 conflict다 (새 멱등성 저장소가 없다): 상태는 이미 첫 요청이 바꾼 그대로, 앱은 409를 성공으로 보지 않는다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const action = await f.action(me);
      const seen = await f.seen(a);
      okOf(await f.add(me, a, action, { expected: seen }));
      const snapshot = await f.snapshot(me);
      expect(await f.add(me, a, action, { expected: seen })).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }]);
    });

    it("즉시 중복(같은 version을 두 번 보냄, 더블 탭): 두 번째는 conflict, 쓰기 0, 범위 version은 한 번만 오른다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const action = await f.action(me);
      const seen = await f.seen(a);
      okOf(await f.add(me, a, action, { expected: seen }));
      expect(await f.add(me, a, action, { expected: seen })).toEqual({ status: "conflict" });
      expect(await f.version(a)).toBe(seen + 1);
      expect(await f.rowsOf(action)).toHaveLength(1);
    });

    it("앞 요청이 아무것도 쓰지 않았다면(이미 그 상태) version이 오르지 않아 같은 version의 다음 요청은 통과한다. 지금보다 큰 version도 conflict다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const action = await f.action(me);
      okOf(await f.add(me, a, action));
      const seen = await f.seen(a);
      expect(okOf(await f.add(me, a, action, { expected: seen })).added).toMatchObject({ changed: false, contextVersion: seen });
      expect(okOf(await f.add(me, a, action, { expected: seen })).added).toMatchObject({ changed: false, contextVersion: seen });
      expect(await f.add(me, a, action, { expected: seen + 1 })).toEqual({ status: "conflict" });
      expect(await f.remove(me, a, action, { expected: seen + 5 })).toEqual({ status: "conflict" });
      expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }]);
    });

    it("무관한 변경으로도 conflict가 날 수 있다 (거짓 conflict: version은 범위 전체의 신호): 같은 범위에 다른 할 일이 들어오면 낡은 version의 요청은 거절된다. 다른 범위의 변화는 영향이 없다", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const [mine, other] = [await f.action(me, "내 일"), await f.action(me, "다른 일")];
      const seenA = await f.seen(a);
      const seenB = await f.seen(b);
      okOf(await f.add(me, a, other)); // 같은 범위 A의 무관한 변경
      expect(await f.add(me, a, mine, { expected: seenA })).toEqual({ status: "conflict" });
      expect(await f.current(mine)).toEqual([]);
      expect(okOf(await f.add(me, b, mine, { expected: seenB })).added).toMatchObject({ changed: true }); // 다른 범위 B는 그대로 통과
      // 다시 읽은 version으로 다시 하면 된다
      expect(okOf(await f.add(me, a, mine)).added).toMatchObject({ changed: true });
    });

    it("옮기기는 두 범위 version 중 하나라도 낡으면 conflict이고 어느 쪽도 쓰지 않는다 (원자적)", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const [action, other] = [await f.action(me), await f.action(me, "다른 일")];
      okOf(await f.add(me, a, action));
      const [seenA, seenB] = [await f.seen(a), await f.seen(b)];
      okOf(await f.add(me, b, other)); // B만 바뀜
      const snapshot = await f.snapshot(me);
      expect(await f.move(me, action, a, b, { expectedFrom: seenA, expectedTo: seenB })).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      okOf(await f.add(me, a, other)); // 이번엔 A만 바뀜
      const snapshot2 = await f.snapshot(me);
      expect(await f.move(me, action, a, b, { expectedFrom: seenA, expectedTo: await f.seen(b) })).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot2);
      expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }]);
    });

    it("다른 계정 대조: 남의 쓰기는 내 범위 version을 올리지 않고(내 요청이 거절되지 않는다), 내가 남의 범위에 보낸 요청은 version이 맞아도 틀려도 not_found다 (conflict보다 먼저)", async () => {
      const me = await f.user();
      const them = await f.user();
      const mine = await f.context(me, "내 범위");
      const theirs = await f.context(them, "남의 범위");
      const [myAction, theirAction] = [await f.action(me), await f.action(them)];
      const seen = await f.seen(mine);
      okOf(await f.add(them, theirs, theirAction)); // 남의 쓰기
      expect(await f.version(mine)).toBe(seen);
      expect(okOf(await f.add(me, mine, myAction, { expected: seen })).added).toMatchObject({ changed: true });
      const snapshot = await f.snapshot(me, them);
      expect(await f.add(me, theirs, myAction, { expected: await f.seen(theirs) })).toEqual({ status: "context_not_found" });
      expect(await f.add(me, theirs, myAction, { expected: 999 })).toEqual({ status: "context_not_found" });
      expect(await f.add(me, mine, theirAction, { expected: 999 })).toEqual({ status: "action_not_found" });
      expect(await f.snapshot(me, them)).toEqual(snapshot);
    });
  });

  describe("실제 변화 · Undo: 바뀐 것만 되돌리고 원래 있던 멤버십은 보존한다 (Codex P2-B)", () => {
    it("처음 A만: A → B 의 실제 변화는 added B · removed A. Undo(옮기기 B → A)로 A가 돌아오고 B는 뺀 행이 된다 (행은 지워지지 않는다)", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me);
      await f.seed(me, a, action, "auto");
      const moved = okOf(await f.move(me, action, a, b));
      expect(moved.added).toMatchObject({ changed: true });
      expect(moved.removed).toMatchObject({ changed: true });
      expect(await f.current(action)).toEqual([{ context_id: b, origin: "user" }]);

      const undone = okOf((await undoOf(f, me, action, moved))!);
      expect(undone.added).toMatchObject({ changed: true });
      expect(undone.added!.member).toMatchObject({ context_id: a, origin: "user", removed_at: null }); // Auto-linked가 아니라 사용자가 고른 것
      expect(undone.removed!.member).toMatchObject({ context_id: b, origin: "user" });
      expect(undone.removed!.member.removed_at).not.toBeNull();
      expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }]);
      expect(await f.rowsOf(action)).toHaveLength(2);
    });

    it("처음 A+B: A → B 의 실제 변화는 removed A뿐 (B는 이미 멤버). Undo는 A만 다시 넣고 원래 있던 B를 지우지 않는다 (반례 3). B가 auto였어도 같다", async () => {
      for (const bOrigin of ["user", "auto"] as const) {
        const me = await f.user();
        const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
        const action = await f.action(me);
        okOf(await f.add(me, a, action));
        if (bOrigin === "user") okOf(await f.add(me, b, action));
        else await f.seed(me, b, action, "auto");
        const bRowBefore = await f.row(b, action);
        const moved = okOf(await f.move(me, action, a, b));
        expect(moved.added).toMatchObject({ changed: false });
        expect(moved.removed).toMatchObject({ changed: true });
        expect(await f.current(action)).toEqual([{ context_id: b, origin: "user" }]);

        const undone = okOf((await undoOf(f, me, action, moved))!);
        expect(undone.removed).toBeNull(); // Undo는 넣기 하나다
        expect(undone.added).toMatchObject({ changed: true });
        expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }, { context_id: b, origin: "user" }].sort((x, y) => (x.context_id < y.context_id ? -1 : 1)));
        // 원래 있던 B는 (auto였다면 user로 승격된 것 말고는) 지워지지 않았다
        expect((await f.row(b, action))!.removed_at).toBeNull();
        if (bOrigin === "user") expect(await f.row(b, action)).toEqual(bRowBefore);
      }
    });

    it("맹목적 역이동은 원래 있던 B를 지운다 — 서버는 요청받은 대로 하므로 앱은 Undo를 change(실제 변화)로 만들어야 한다 (Codex 반례 3의 원인을 고정)", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me);
      okOf(await f.add(me, a, action));
      okOf(await f.add(me, b, action));
      okOf(await f.move(me, action, a, b));
      okOf(await f.move(me, action, b, a)); // 요청받은 대로: B를 빼고 A를 넣는다
      expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }]);
    });

    it("처음 A도 B도 아님: A → B 의 실제 변화는 added B뿐 (A는 멤버가 아니었다, 뺀 표시만 남는다). Undo는 B만 뺀다", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me);
      const moved = okOf(await f.move(me, action, a, b));
      expect(moved.added).toMatchObject({ changed: true });
      expect(moved.removed).toMatchObject({ changed: false });
      const undone = okOf((await undoOf(f, me, action, moved))!);
      expect(undone.removed).toMatchObject({ changed: true });
      expect(await f.current(action)).toEqual([]);
      expect(await f.rowsOf(action)).toHaveLength(2);
    });

    it("바뀐 것이 없는 요청에는 되돌릴 것이 없다: 이미 그 상태의 넣기 · 멤버가 아닌 범위 빼기 · 후보(inferred) 빼기 · 이미 둘 다 그 상태인 옮기기", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const [action, candidate] = [await f.action(me), await f.action(me, "후보")];
      okOf(await f.add(me, a, action));
      okOf(await f.add(me, b, action));
      expect(undoPlan(okOf(await f.add(me, a, action)))).toBeNull();
      expect(undoPlan(okOf(await f.move(me, action, b, a)))).toMatchObject({ kind: "add", context: b }); // 처음 한 번은 b를 뺀다: 되돌릴 것은 b 넣기
      expect(undoPlan(okOf(await f.move(me, action, b, a)))).toBeNull(); // 이제 b는 뺀 상태, a는 멤버
      await f.seed(me, a, candidate, "inferred");
      expect(undoPlan(okOf(await f.remove(me, a, candidate)))).toBeNull();
    });

    it("후보(inferred)를 넣기로 확인하면 실제 변화는 added다. Undo는 후보를 되살리는 것이 아니라 그 범위에서 빼는 것이다 (후보는 돌아오지 않는다)", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const action = await f.action(me);
      await f.seed(me, a, action, "inferred");
      const confirmed = okOf(await f.add(me, a, action));
      expect(confirmed.added).toMatchObject({ changed: true });
      okOf((await undoOf(f, me, action, confirmed))!);
      expect(await f.current(action)).toEqual([]);
      expect(await f.row(a, action)).toMatchObject({ origin: "user", confidence: null });
    });

    it("늦은 Undo: 그 사이 다른 기기가 바꿨으면 conflict이고 아무것도 바뀌지 않는다. 다른 기기가 원래 있던 B를 지운 뒤의 Undo는 그 결정을 덮지 않고 A만 돌려놓는다", async () => {
      const me = await f.user();
      const [a, b, c] = [await f.context(me, "A"), await f.context(me, "B"), await f.context(me, "C")];
      const action = await f.action(me);
      okOf(await f.add(me, a, action));
      okOf(await f.add(me, b, action));
      const moved = okOf(await f.move(me, action, a, b)); // removed A
      // 다른 기기가 B(원래 있던 대상)를 지운다 — Undo(A 넣기)는 A의 version만 조건으로 삼으므로 이 결정을 덮지 않는다
      okOf(await f.remove(me, b, action));
      const undone = okOf((await undoOf(f, me, action, moved))!);
      expect(undone.added).toMatchObject({ changed: true });
      expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }]);

      // 이번엔 다른 기기가 A 자체를 다시 바꾼다: 늦은 Undo는 conflict
      const again = okOf(await f.move(me, action, a, c)); // removed A, added C
      okOf(await f.add(me, a, action)); // 다른 기기: A를 다시 넣음 (A version 올라감)
      okOf(await f.remove(me, a, action)); // ... 그리고 다시 뺌
      const snapshot = await f.snapshot(me);
      expect(await undoOf(f, me, action, again)).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect(await f.current(action)).toEqual([{ context_id: c, origin: "user" }]);
    });

    it("Undo의 응답 version은 쓰기 직후의 정확한 값이다: 그 값으로 보낸 Undo만 통과하고 한 번 더 보낸 Undo는 conflict (Undo의 재전송은 성공의 증거가 아니다)", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me);
      okOf(await f.add(me, a, action));
      const moved = okOf(await f.move(me, action, a, b));
      expect(moved.added!.contextVersion).toBe(await f.version(b));
      expect(moved.removed!.contextVersion).toBe(await f.version(a));
      okOf((await undoOf(f, me, action, moved))!);
      expect(await undoOf(f, me, action, moved)).toEqual({ status: "conflict" });
    });
  });

  describe("여러 범위: 하나로 합치지 않는다", () => {
    it("한 할 일이 범위 A · B의 멤버이면 A에서 빼도 B는 그대로이고(행 · version 불변), 범위마다 origin이 따로다", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me);
      await f.seed(me, a, action, "auto");
      okOf(await f.add(me, b, action));
      expect(await f.current(action)).toEqual(expect.arrayContaining([{ context_id: a, origin: "auto" }, { context_id: b, origin: "user" }]));
      const bRow = await f.row(b, action);
      const bVersion = await f.version(b);
      okOf(await f.remove(me, a, action));
      expect(await f.current(action)).toEqual([{ context_id: b, origin: "user" }]);
      expect(await f.row(b, action)).toEqual(bRow);
      expect(await f.version(b)).toBe(bVersion);
    });
  });

  describe("옮기기 (move): 한 트랜잭션에서 빼고 넣는다 — 전체 교체가 아니다", () => {
    it("A → B: A는 사용자가 뺀 행, B는 user 멤버. 두 범위 version이 각각 + 1이고 응답이 그 값을 준다. 지금 version으로 다시 보내면 쓰지 않는다 (changed false, version 불변)", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me);
      await f.seed(me, a, action, "auto");
      const [aBefore, bBefore] = [await f.version(a), await f.version(b)];
      const moved = okOf(await f.move(me, action, a, b));
      expect(moved.added!.member).toMatchObject({ context_id: b, origin: "user", removed_at: null });
      expect(moved.removed!.member).toMatchObject({ context_id: a, origin: "user", confidence: null });
      expect(moved.removed!.member.removed_at).not.toBeNull();
      expect([moved.removed!.contextVersion, moved.added!.contextVersion]).toEqual([aBefore + 1, bBefore + 1]);
      expect([await f.version(a), await f.version(b)]).toEqual([aBefore + 1, bBefore + 1]);
      expect(await f.current(action)).toEqual([{ context_id: b, origin: "user" }]);
      expect(await f.rowsOf(action)).toHaveLength(2);

      const snapshot = await f.snapshot(me);
      const again = okOf(await f.move(me, action, a, b));
      expect([again.added!.member, again.removed!.member]).toEqual([moved.added!.member, moved.removed!.member]);
      expect([again.added!.changed, again.removed!.changed]).toEqual([false, false]);
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect([await f.version(a), await f.version(b)]).toEqual([aBefore + 1, bBefore + 1]);
    });

    it("B가 이미 auto 멤버여도 같은 규칙: B는 user로 승격, A에는 뺀 표시가 남는다. 다른 범위 C의 멤버십은 건드리지 않는다 (전체 교체가 아니다)", async () => {
      const me = await f.user();
      const [a, b, c] = [await f.context(me, "A"), await f.context(me, "B"), await f.context(me, "C")];
      const action = await f.action(me);
      await f.seed(me, b, action, "auto");
      await f.seed(me, c, action, "auto");
      const cRow = await f.row(c, action);
      const cVersion = await f.version(c);
      const moved = okOf(await f.move(me, action, a, b));
      expect(moved.added!.member).toMatchObject({ context_id: b, origin: "user", removed_at: null });
      expect(moved.removed!.member.removed_at).not.toBeNull();
      expect(await f.current(action)).toEqual(expect.arrayContaining([{ context_id: b, origin: "user" }, { context_id: c, origin: "auto" }]));
      expect(await f.row(c, action)).toEqual(cRow);
      expect(await f.version(c)).toBe(cVersion);
    });

    it("원자적이다: 도착 범위가 보관됐거나 남의 · 없는 범위이면 아무것도 쓰지 않는다 (A 멤버십 그대로). 출발 범위가 남의 · 없는 · 보관된 범위여도 같다", async () => {
      const me = await f.user();
      const them = await f.user();
      const [a, b, archived] = [await f.context(me, "A"), await f.context(me, "B"), await f.context(me, "보관")];
      const theirs = await f.context(them, "남의 범위");
      await f.archive(archived);
      const action = await f.action(me);
      okOf(await f.add(me, a, action));
      const snapshot = await f.snapshot(me, them);
      const versions = [await f.version(a), await f.version(b), await f.version(archived), await f.version(theirs)];
      for (const to of [archived, theirs, randomUUID()]) expect(await f.move(me, action, a, to), `to ${to}`).toEqual({ status: "context_not_found" });
      for (const from of [archived, theirs, randomUUID()]) expect(await f.move(me, action, from, b), `from ${from}`).toEqual({ status: "context_not_found" });
      expect(await f.snapshot(me, them)).toEqual(snapshot);
      expect([await f.version(a), await f.version(b), await f.version(archived), await f.version(theirs)]).toEqual(versions);
    });

    it("DB 함수는 같은 범위로 옮기기 · 범위 둘 다 없음 · version 없는 범위를 거절한다 (22023, 쓰기 0)", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      const call = (add: string | null, addVersion: number | null, remove: string | null, removeVersion: number | null) =>
        db().query(`select * from public.change_context_membership_by_user($1, $2, $3, $4, $5, $6)`, [me, action, add, addVersion, remove, removeVersion]);
      await expect(call(ctx, 1, ctx, 1)).rejects.toThrow(/give a context/);
      await expect(call(null, null, null, null)).rejects.toThrow(/give a context/);
      await expect(call(ctx, null, null, null)).rejects.toThrow(/give a context/);
      await expect(call(null, 1, ctx, null)).rejects.toThrow(/give a context/);
      expect(await f.rowsOf(action)).toEqual([]);
    });
  });

  describe("격리 · 보관 · 삭제", () => {
    it("남의 범위 · 남의 할 일 · 없는 id는 not_found이고 아무것도 바뀌지 않는다 (남의 행 · 범위 version 포함). 존재를 드러내지 않는다", async () => {
      const alice = await f.user();
      const bob = await f.user();
      const aliceContext = await f.context(alice, "Alice 프로젝트");
      const bobContext = await f.context(bob, "Bob 프로젝트");
      const bobContext2 = await f.context(bob, "Bob 프로젝트 2");
      const aliceAction = await f.action(alice);
      const bobAction = await f.action(bob);
      okOf(await f.add(alice, aliceContext, aliceAction));
      const snapshot = await f.snapshot(alice, bob);
      const versions = [await f.version(aliceContext), await f.version(bobContext), await f.version(bobContext2)];
      const missing = randomUUID();

      // Bob이 Alice의 범위 · 할 일을 건드린다
      expect(await f.add(bob, aliceContext, bobAction)).toEqual({ status: "context_not_found" });
      expect(await f.remove(bob, aliceContext, aliceAction)).toEqual({ status: "context_not_found" });
      expect(await f.add(bob, bobContext, aliceAction)).toEqual({ status: "action_not_found" });
      expect(await f.remove(bob, bobContext, aliceAction)).toEqual({ status: "action_not_found" });
      expect(await f.move(bob, bobAction, aliceContext, bobContext)).toEqual({ status: "context_not_found" });
      expect(await f.move(bob, bobAction, bobContext, aliceContext)).toEqual({ status: "context_not_found" });
      expect(await f.move(bob, aliceAction, bobContext, bobContext2)).toEqual({ status: "action_not_found" });
      // 없는 id
      expect(await f.add(alice, missing, aliceAction)).toEqual({ status: "context_not_found" });
      expect(await f.add(alice, aliceContext, missing)).toEqual({ status: "action_not_found" });
      expect(await f.remove(alice, aliceContext, missing)).toEqual({ status: "action_not_found" });

      expect(await f.snapshot(alice, bob)).toEqual(snapshot);
      expect([await f.version(aliceContext), await f.version(bobContext), await f.version(bobContext2)]).toEqual(versions);
    });

    it("보관된 범위에는 넣기 · 빼기 모두 not_found이고(쓰기 0), 보관해도 이미 있는 멤버십은 그대로다 (범위는 동결, 보관 해제는 이 묶음에 없다)", async () => {
      const me = await f.user();
      const archived = await f.context(me, "보관");
      const kept = await f.action(me, "남은 일");
      const other = await f.action(me, "다른 일");
      okOf(await f.add(me, archived, kept));
      await f.archive(archived);
      const snapshot = await f.snapshot(me);
      const version = await f.version(archived);
      expect(await f.add(me, archived, other)).toEqual({ status: "context_not_found" });
      expect(await f.remove(me, archived, kept)).toEqual({ status: "context_not_found" });
      expect(await f.remove(me, archived, other)).toEqual({ status: "context_not_found" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect(await f.version(archived)).toBe(version);
      expect(await f.current(kept)).toEqual([{ context_id: archived, origin: "user" }]);
    });

    it("앱(RLS)은 자기 멤버십 행과 범위 version만 읽고 남의 것은 못 본다. 직접 쓰거나 함수를 부르지 못한다 (쓰기는 서버 API만)", async () => {
      const alice = await f.user();
      const bob = await f.user();
      const [aliceContext, bobContext] = [await f.context(alice), await f.context(bob)];
      const [aliceAction, bobAction] = [await f.action(alice), await f.action(bob)];
      okOf(await f.add(alice, aliceContext, aliceAction));
      okOf(await f.add(bob, bobContext, bobAction));
      const own = await db().asUser(alice, () => db().query(`select context_id, action_id, origin, confidence, removed_at from public.context_members order by created_at`));
      expect(own).toEqual([{ context_id: aliceContext, action_id: aliceAction, origin: "user", confidence: null, removed_at: null }]);
      // 앱은 version도 RLS로 읽는다 (요청의 expected_context_version의 출처)
      expect(await db().asUser(alice, () => db().query(`select id, context_version, status from public.work_contexts`))).toEqual([
        { id: aliceContext, context_version: await f.version(aliceContext), status: "active" },
      ]);
      expect(await db().asUser(alice, () => db().query(`select id from public.context_members where context_id = $1`, [bobContext]))).toEqual([]);

      await expect(
        db().asUser(alice, () =>
          db().query(`insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user')`, [alice, aliceContext, aliceAction]),
        ),
      ).rejects.toThrow(/permission denied/);
      await expect(db().asUser(alice, () => db().query(`update public.context_members set removed_at = now()`))).rejects.toThrow(/permission denied/);
      await expect(db().asUser(alice, () => db().query(`delete from public.context_members`))).rejects.toThrow(/permission denied/);
      await expect(
        db().asUser(alice, () => db().query(`select * from public.change_context_membership_by_user($1, $2, $3, 1, null, null)`, [alice, aliceAction, aliceContext])),
      ).rejects.toThrow(/permission denied/);
    });

    it("범위를 지우면 그 범위의 멤버십(뺀 행 포함)이 지워지고 다른 범위의 것은 그대로, 할 일을 지우면 그 할 일의 멤버십이 모두 지워진다 (복합 외래키 cascade)", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const [gone, kept] = [await f.action(me, "지울 일"), await f.action(me, "남길 일")];
      okOf(await f.add(me, a, gone));
      okOf(await f.add(me, b, gone));
      okOf(await f.add(me, a, kept));
      okOf(await f.remove(me, b, kept));
      expect(await f.count(`select count(*)::int as n from public.context_members where user_id = $1`, [me])).toBe(4);

      await db().query(`delete from public.work_contexts where id = $1`, [b]);
      expect((await f.rowsOf(gone)).map((r) => r.context_id)).toEqual([a]);
      expect((await f.rowsOf(kept)).map((r) => r.context_id)).toEqual([a]);
      expect(await f.add(me, b, kept)).toEqual({ status: "context_not_found" });

      await db().query(`delete from public.actions where id = $1`, [gone]);
      expect(await f.rowsOf(gone)).toEqual([]);
      expect((await f.rowsOf(kept)).map((r) => r.context_id)).toEqual([a]);
      expect(await f.add(me, a, gone)).toEqual({ status: "action_not_found" });
    });
  });

  describe("권한 · gate (I04 · I14 · D13)", () => {
    it("멤버십 쓰기(넣기 · 빼기 · 옮기기 · 승격 · 되살림 · Undo · 거절된 conflict)와 범위 보관은 Action · Claim · 근거 · 사건 · 정책 · 승인 · run · 크레딧 · 기억 · 대화 · 사건함 표에 한 줄도 더하지 않고, Action · Claim 행도 한 글자 바뀌지 않는다", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me, "Shape 디자인 확정");
      const second = await f.action(me, "개발 시작");
      const source = await f.source(me);
      await db().query(
        `insert into public.claims (user_id, action_id, source_id, field, value, quote, occurred_at, speaker_role, certainty, directness, audience)
         values ($1, $2, $3, 'owner', 'me', '제가 할게요', now(), 'me', 'firm', 'first_hand', 'shared')`,
        [me, action, source],
      );
      await db().query(`insert into public.conversations (user_id, context_id) values ($1, $2)`, [me, a]);
      const counts = await authorityCounts();
      const actions = await db().query(`select * from public.actions where user_id = $1 order by id`, [me]);
      const claims = await db().query(`select * from public.claims where user_id = $1 order by id`, [me]);
      const contexts = await db().query(`select id, name, kind, status from public.work_contexts where user_id = $1 order by id`, [me]);

      await f.seed(me, a, second, "inferred");
      const added = okOf(await f.add(me, a, action));
      okOf(await f.add(me, a, second)); // 승격
      const moved = okOf(await f.move(me, action, a, b));
      okOf((await undoOf(f, me, action, moved))!); // Undo
      expect(await f.add(me, a, action, { expected: 1 })).toEqual({ status: "conflict" }); // 낡은 요청 거절
      expect(undoPlan(added)).not.toBeNull();
      okOf(await f.remove(me, a, second));
      okOf(await f.add(me, a, second)); // 되살림
      await f.archive(b);
      expect(await f.add(me, b, action)).toEqual({ status: "context_not_found" });

      expect(await authorityCounts()).toEqual(counts);
      expect(await db().query(`select * from public.actions where user_id = $1 order by id`, [me])).toEqual(actions);
      expect(await db().query(`select * from public.claims where user_id = $1 order by id`, [me])).toEqual(claims);
      // 범위는 version · 활동 시각만 바뀐다 (이름 · 종류는 그대로, 보관은 우리가 직접 한 것)
      expect(await db().query(`select id, name, kind, status from public.work_contexts where user_id = $1 order by id`, [me])).toEqual(
        contexts.map((row) => (row.id === b ? { ...row, status: "archived" } : row)),
      );
    });

    it("함수는 서버(service role)만 부른다: 앱 · 익명 불가, search_path 고정, 소유자 권한 아님", async () => {
      const rows = await db().query(
        `select p.proname as name, has_function_privilege('anon', p.oid, 'execute') as anon, has_function_privilege('authenticated', p.oid, 'execute') as auth,
                has_function_privilege('service_role', p.oid, 'execute') as service, p.prosecdef as definer, p.proconfig as config, p.prosrc as body
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'change_context_membership_by_user'`,
      );
      expect(rows).toHaveLength(1);
      expect(rows[0]).toMatchObject({ anon: false, auth: false, service: true, definer: false });
      expect(rows[0].config).toContain('search_path=""');
      expect(String(rows[0].body)).not.toMatch(/execution_|credit_|approval|public\.claims|public\.evidence/);
    });

    it("gate(MEMORY_ENABLED) 꺼짐: DB를 부르기 전에 막힌다 (쿼리 0, 쓰기 0)", async () => {
      const me = await f.user();
      const ctx = await f.context(me);
      const action = await f.action(me);
      const snapshot = await f.snapshot(me);
      let queries = 0;
      const counting = sqlAdmin(async (sql, params) => {
        queries++;
        return db().query(sql, params);
      });
      const target = { contextId: ctx, expectedVersion: 1 };
      for (const env of [{}, { MEMORY_ENABLED: "TRUE" }, { MEMORY_ENABLED: "1" }, { MEMORY_ENABLED: " true" }]) {
        await expect(changeContextMembership(counting, me, { actionId: action, add: target }, env)).rejects.toBeInstanceOf(ContextGateOffError);
        await expect(changeContextMembership(counting, me, { actionId: action, remove: target }, env)).rejects.toBeInstanceOf(ContextGateOffError);
        await expect(changeContextMembership(counting, me, { actionId: action, remove: target, add: { contextId: randomUUID(), expectedVersion: 1 } }, env)).rejects.toBeInstanceOf(
          ContextGateOffError,
        );
      }
      expect(queries).toBe(0);
      expect(await f.snapshot(me)).toEqual(snapshot);
    });
  });

  describe("handler → store → SQL: Mac이 받는 JSON (정확한 계약)", () => {
    const request = (body: unknown) => new Request("https://api.example.dev/api/v2/contexts/x/members", { method: "POST", body: JSON.stringify(body) });
    const authed = (userId: string) => async () => ({ user: { id: userId } });
    const deps = (userId: string, env: Record<string, string> = ON) => ({
      enabled: () => env.MEMORY_ENABLED === "true",
      authenticate: authed(userId),
      change: (_user: unknown, change: Parameters<typeof changeContextMembership>[2]) => changeContextMembership(f.admin(), userId, change, env),
    });
    const run = async (response: Response) => ({ status: response.status, body: (await response.json()) as Record<string, unknown> });
    const conflictBody = { error: { code: "conflict", message: "그 사이 범위가 바뀌었습니다. 다시 불러온 뒤 시도해 주세요." } };

    it("넣기 → 200 { member, context_version, change } (스키마를 지킨다), 같은 version의 재전송은 409 conflict, 지금 version으로 빼기 → 200 (removed_at), 다시 넣기 → 200 (되살림)", async () => {
      const me = await f.user();
      const ctx = await f.context(me, "Shape");
      const action = await f.action(me);
      const seen = await f.seen(ctx);
      const add = (expected: number) => ({ op: "add", member_kind: "action", member_id: action, expected_context_version: expected });
      const first = await run(await handleChangeContextMember(request(add(seen)), ctx, deps(me)));
      expect(first.status).toBe(200);
      const parsed = contextMembershipResponseSchema.parse(first.body);
      expect(parsed.member).toMatchObject({ context_id: ctx, action_id: action, origin: "user", confidence: null, removed_at: null });
      expect(parsed.context_version).toBe(await f.version(ctx));
      expect(parsed.context_version).toBe(seen + 1);
      expect(parsed.change).toEqual({ added: [{ context_id: ctx, context_version: seen + 1 }], removed: [] });
      // 응답을 잃은 재전송 (대소문자만 다른 경로 id도 같은 범위): 409, 앱은 성공으로 보지 않는다
      expect(await run(await handleChangeContextMember(request(add(seen)), ctx.toUpperCase(), deps(me)))).toEqual({ status: 409, body: conflictBody });

      const removed = await run(await handleChangeContextMember(request({ ...add(parsed.context_version), op: "remove" }), ctx, deps(me)));
      expect(removed.status).toBe(200);
      const removedBody = contextMembershipResponseSchema.parse(removed.body);
      expect(removedBody.member).toMatchObject({ id: parsed.member.id, origin: "user" });
      expect(removedBody.member.removed_at).not.toBeNull();
      expect(removedBody.context_version).toBe(parsed.context_version + 1);
      expect(removedBody.change).toEqual({ added: [], removed: [{ context_id: ctx, context_version: removedBody.context_version }] });
      expect((await run(await handleChangeContextMember(request({ ...add(parsed.context_version), op: "remove" }), ctx, deps(me)))).status).toBe(409);

      const back = contextMembershipResponseSchema.parse((await run(await handleChangeContextMember(request(add(removedBody.context_version)), ctx, deps(me)))).body);
      expect(back.member).toMatchObject({ id: parsed.member.id, removed_at: null });
      expect(back.context_version).toBe(removedBody.context_version + 1);
    });

    it("남의 · 없는 · 보관된 범위 404, 남의 · 없는 할 일 404 (version이 틀려도 404가 먼저), source · person 종류 400, 조건 필드 없음 400, gate 꺼짐 404", async () => {
      const me = await f.user();
      const them = await f.user();
      const ctx = await f.context(me);
      const archived = await f.context(me, "보관");
      await f.archive(archived);
      const [mine, theirs] = [await f.action(me), await f.action(them)];
      const add = (memberId: string) => ({ op: "add", member_kind: "action", member_id: memberId, expected_context_version: 999 });
      for (const contextId of [await f.context(them), randomUUID(), archived]) {
        const response = await run(await handleChangeContextMember(request(add(mine)), contextId, deps(me)));
        expect(response.status, contextId).toBe(404);
        expect(apiErrorV2Schema.parse(response.body).error).toMatchObject({ code: "not_found", message: "범위가 없습니다." });
      }
      for (const memberId of [theirs, randomUUID()]) {
        const response = await run(await handleChangeContextMember(request(add(memberId)), ctx, deps(me)));
        expect(response.status, memberId).toBe(404);
        expect(apiErrorV2Schema.parse(response.body).error).toMatchObject({ code: "not_found", message: "할 일이 없습니다." });
      }
      for (const kind of ["source", "person"]) {
        const response = await run(await handleChangeContextMember(request({ ...add(mine), member_kind: kind }), ctx, deps(me)));
        expect(response.status, kind).toBe(400);
        expect(apiErrorV2Schema.parse(response.body).error.code).toBe("invalid_request");
      }
      const unconditional = await run(await handleChangeContextMember(request({ op: "add", member_kind: "action", member_id: mine }), ctx, deps(me)));
      expect(unconditional.status).toBe(400);
      expect((await run(await handleChangeContextMember(request({ ...add(mine), expected_context_version: await f.seen(ctx) }), ctx, deps(me, {})))).status).toBe(404);
      expect(await f.snapshot(me, them)).toEqual([]);
    });

    it("옮기기 → 200 { member, from_member, context_version, from_context_version, change }, 같은 요청 재전송은 409, 같은 범위 400, 도착 범위가 보관됐으면 404 (A 그대로). 실제 변화로 Undo가 이어진다", async () => {
      const me = await f.user();
      const [a, b, archived] = [await f.context(me, "A"), await f.context(me, "B"), await f.context(me, "보관")];
      await f.archive(archived);
      const action = await f.action(me);
      await f.seed(me, a, action, "auto");
      const move = { member_kind: "action", member_id: action, from_context_id: a, expected_context_version: await f.seen(b), expected_from_context_version: await f.seen(a) };
      const first = await run(await handleMoveContextMember(request(move), b, deps(me)));
      expect(first.status).toBe(200);
      const parsed = contextMemberMoveResponseSchema.parse(first.body);
      expect(parsed.member).toMatchObject({ context_id: b, origin: "user", removed_at: null });
      expect(parsed.from_member).toMatchObject({ context_id: a, origin: "user" });
      expect(parsed.from_member.removed_at).not.toBeNull();
      expect([parsed.from_context_version, parsed.context_version]).toEqual([await f.version(a), await f.version(b)]);
      expect(parsed.change).toEqual({
        added: [{ context_id: b, context_version: parsed.context_version }],
        removed: [{ context_id: a, context_version: parsed.from_context_version }],
      });
      expect(await run(await handleMoveContextMember(request(move), b, deps(me)))).toEqual({ status: 409, body: conflictBody });

      // Undo = 실제 변화의 역연산 (옮기기 b → a), 그 version으로
      const undoBody = { member_kind: "action", member_id: action, from_context_id: b, expected_context_version: parsed.from_context_version, expected_from_context_version: parsed.context_version };
      const undone = contextMemberMoveResponseSchema.parse((await run(await handleMoveContextMember(request(undoBody), a, deps(me)))).body);
      expect(undone.member).toMatchObject({ context_id: a, removed_at: null });
      expect(await f.current(action)).toEqual([{ context_id: a, origin: "user" }]);

      const same = await run(await handleMoveContextMember(request({ ...move, from_context_id: b.toUpperCase() }), b, deps(me)));
      expect(same.status).toBe(400);
      expect(apiErrorV2Schema.parse(same.body).error.code).toBe("invalid_request");
      expect((await run(await handleMoveContextMember(request({ ...move, member_kind: "source" }), b, deps(me)))).status).toBe(400);
      expect((await run(await handleMoveContextMember(request({ ...move, expected_from_context_version: undefined }), b, deps(me)))).status).toBe(400); // JSON에서 키가 빠진다

      const snapshot = await f.snapshot(me);
      const toArchived = await run(await handleMoveContextMember(request({ ...move, from_context_id: a, expected_context_version: 1 }), archived, deps(me)));
      expect(toArchived.status).toBe(404);
      expect(await f.snapshot(me)).toEqual(snapshot);
    });

    it("처음 A+B에서 A → B 의 JSON은 change.removed만 있고(added 빈 배열), Undo(add A)는 B를 지우지 않는다", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const action = await f.action(me);
      okOf(await f.add(me, a, action));
      okOf(await f.add(me, b, action));
      const move = { member_kind: "action", member_id: action, from_context_id: a, expected_context_version: await f.seen(b), expected_from_context_version: await f.seen(a) };
      const response = contextMemberMoveResponseSchema.parse((await run(await handleMoveContextMember(request(move), b, deps(me)))).body);
      expect(response.change.added).toEqual([]);
      expect(response.change.removed).toEqual([{ context_id: a, context_version: response.from_context_version }]);
      const undo = { op: "add", member_kind: "action", member_id: action, expected_context_version: response.change.removed[0].context_version };
      expect((await run(await handleChangeContextMember(request(undo), a, deps(me)))).status).toBe(200);
      expect((await f.current(action)).map((row) => row.context_id).sort()).toEqual([a, b].sort());
    });
  });
}
