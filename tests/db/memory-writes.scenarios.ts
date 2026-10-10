import { randomUUID } from "node:crypto";

import { describe, expect, it } from "vitest";

import { apiErrorV2Schema, memoryItemResponseSchema, updateConversationResponseSchema, type MemoryItem } from "@/lib/api/contract";
import { handleUpdateConversation } from "@/lib/api/conversations";
import { handleConfirmMemory, handleEditMemory, handleForgetMemory, handleMoveMemory } from "@/lib/api/memory";
import { buildContextBundle } from "@/lib/context/bundle";
import type { MemoryWriteOutcome } from "@/lib/context/memory-edit";
import { confirmMemoryItem, editMemoryItem, forgetMemoryItem, loadMemoryItem, moveMemoryItem } from "@/lib/context/memory-writes";
import { ContextGateOffError, loadScopeMemory, loadSourceStates } from "@/lib/context/store";
import { loadConsultContext, setConversationContext } from "@/lib/conversation/store";

import { sqlAdmin } from "../conversation/sql-admin";

import { contextLayerFixtures } from "./context-layer.scenarios";
import { conversationFixtures } from "./conversations-v2.scenarios";

// 0.2.0 기억 쓰기 (20261107000000_memory_writes + B1 remember_memory_item, 구현 계획 B3 PR1): 확인 · 정정 · 잊기 · 범위 옮기기 · 대화 범위 바꾸기.
// 운영 코드(src/lib/context/memory-writes.ts · src/lib/conversation/store.ts → SQL)를 그대로 부른다. 같은 시나리오를 PGlite(tests/db/memory-writes.test.ts)와
// 실제 Postgres(tests/pg/memory-writes.test.ts)에서 돌린다. 동시성은 실제 Postgres 파일에만 있다.

export type Rows = Record<string, unknown>[];

export type MemoryWritesDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

export const ON = { MEMORY_ENABLED: "true" };

type Item = Record<string, unknown>;

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 · 호출 */
export function memoryWritesFixtures(db: () => MemoryWritesDb) {
  const base = contextLayerFixtures(db);
  const conversations = conversationFixtures(db);
  const admin = () => sqlAdmin((sql, params) => db().query(sql, params));

  const f = {
    ...base,
    conversations,
    admin,
    count: conversations.count,
    /** 후보 (inferred): 기본은 전체 범위. statement · subject · 범위 · 출처는 over로 */
    async candidate(userId: string, over: Item = {}): Promise<string> {
      const r = await base.remember(userId, { kind: "fact", scope_kind: "global", subject: "launch day", statement: "출시는 목요일인 듯", origin: "inferred", confidence: 0.6, ...over });
      return r.id!;
    },
    /** 사용자가 말한 기억 (explicit) */
    async explicit(userId: string, over: Item = {}): Promise<string> {
      const r = await base.remember(userId, { kind: "fact", scope_kind: "global", subject: "launch day", statement: "출시는 목요일", origin: "explicit", ...over });
      return r.id!;
    },
    /** 자료에서 읽은 기억 (observed): 출처 필수 */
    async observed(userId: string, sourceId: string, over: Item = {}): Promise<string> {
      const r = await base.remember(userId, {
        kind: "fact", scope_kind: "global", subject: "launch day", statement: "출시는 금요일", origin: "observed", source_ref: { source_id: sourceId, quote: "출시는 금요일" }, ...over,
      });
      return r.id!;
    },
    async row(id: string) {
      return (await base.one(`select * from public.memory_items where id = $1`, [id])) as Record<string, unknown> & {
        id: string; version: number; superseded_at: unknown; revoked_at: unknown; superseded_by: string | null; statement: string; value: Record<string, unknown>;
        source_ref: Record<string, unknown> | null; origin: string; scope_kind: string; context_id: string | null; subject: string | null; observed_at: Date; valid_from: unknown; valid_until: unknown;
      };
    },
    /** 한 사용자의 기억 표 전체 (바뀌지 않았는지 견주는 스냅샷) */
    async snapshot(userId: string) {
      return db().query(`select * from public.memory_items where user_id = $1 order by id`, [userId]);
    },
    /** 앱(RLS)이 보는 "지금 기억" (superseded_at · revoked_at이 모두 없음) */
    async current(userId: string, contextId?: string | null) {
      return (
        await db().query(
          `select id, statement, scope_kind, context_id from public.memory_items where user_id = $1 and superseded_at is null and revoked_at is null
              ${contextId === undefined ? "" : "and context_id is not distinct from $2"} order by statement`,
          contextId === undefined ? [userId] : [userId, contextId],
        )
      ).map((r) => ({ id: r.id as string, statement: r.statement as string, scope_kind: r.scope_kind as string, context_id: r.context_id as string | null }));
    },
    confirm: (userId: string, id: string, expectedVersion: number, env = ON) => confirmMemoryItem(admin(), userId, id, expectedVersion, env),
    edit: (userId: string, id: string, request: { expected_version: number; statement: string; value?: Record<string, unknown>; valid_from?: string | null; valid_until?: string | null }, env = ON) =>
      editMemoryItem(admin(), userId, id, request, env),
    forget: (userId: string, id: string, expectedVersion: number, env = ON) => forgetMemoryItem(admin(), userId, id, expectedVersion, env),
    move: (userId: string, id: string, expectedVersion: number, target: { scope_kind: "global" } | { scope_kind: "context"; context_id: string }, env = ON) =>
      moveMemoryItem(admin(), userId, id, { expected_version: expectedVersion, context_id: null, ...target }, env),
  };
  return f;
}

/** 성공 결과의 항목 */
export function itemOf(outcome: MemoryWriteOutcome): MemoryItem {
  expect(outcome.status).toBe("ok");
  return (outcome as Extract<MemoryWriteOutcome, { status: "ok" }>).item;
}

/** 실행·권한·Action 표 (기억 쓰기가 한 줄도 더하지 않아야 한다) */
const AUTHORITY_TABLES = [
  "actions", "claims", "evidence", "action_events", "execution_policies", "execution_runs", "execution_steps", "execution_approvals", "execution_intents",
  "execution_events", "execution_artifacts", "execution_usage", "credit_ledger", "conversation_messages", "context_members", "inbox_events",
];

export function memoryWritesTests(db: () => MemoryWritesDb) {
  const f = memoryWritesFixtures(db);
  const { conversations: cf } = f;

  async function authorityCounts() {
    const counts: Record<string, number> = {};
    for (const table of AUTHORITY_TABLES) counts[table] = await f.count(`select count(*)::int as n from public.${table}`);
    return counts;
  }

  describe("확인 (confirm): 후보를 사용자가 확인하면 새 explicit 행이 후보를 정정한다", () => {
    it("같은 범위 · kind · subject · 글 · 값 · 유효 구간 · 출처를 이어받은 새 행이 지금 행이 되고, 후보는 정정된 이력이 된다 (범위 version은 정확히 + 1)", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const source = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const candidate = await f.candidate(me, {
        scope_kind: "context", context_id: context, subject: "launch day", statement: "출시는 목요일인 듯", value: { day: "thu" },
        valid_from: "2026-10-01T00:00:00Z", valid_until: "2026-12-31T00:00:00Z", source_ref: { source_id: source, quote: "Shape 출시는 목요일" },
      });
      const before = await f.version(context);

      const item = itemOf(await f.confirm(me, candidate, 1));
      expect(item).toMatchObject({
        origin: "explicit", kind: "fact", scope_kind: "context", context_id: context, subject: "launch day", statement: "출시는 목요일인 듯", value: { day: "thu" },
        source_ref: { source_id: source, quote: "Shape 출시는 목요일" }, confidence: null, version: 1, superseded_at: null, revoked_at: null, source_purged: false,
      });
      expect(Date.parse(item.valid_from!)).toBe(Date.parse("2026-10-01T00:00:00Z"));
      expect(Date.parse(item.valid_until!)).toBe(Date.parse("2026-12-31T00:00:00Z"));
      const old = await f.row(candidate);
      expect(old).toMatchObject({ origin: "inferred", superseded_by: item.id, version: 2, revoked_at: null });
      expect(old.superseded_at).not.toBeNull();
      expect(await f.version(context)).toBe(before + 1);
      expect(await f.current(me)).toEqual([{ id: item.id, statement: "출시는 목요일인 듯", scope_kind: "context", context_id: context }]);
      // 후보는 읽기에 쓰이지 않았고, 확인한 행은 쓰인다 (B1 읽기 조건 그대로)
      const loaded = await loadScopeMemory(f.admin(), me, { contextId: context }, ON);
      expect(loaded.map((m) => m.id)).toEqual([item.id]);
    });

    it("프로젝트 예외가 전역 · 다른 프로젝트의 같은 사실을 지우지 않고, 무관한 같은 kind 사실(다른 subject · 주제 없음)도 그대로다. 같은 범위의 같은 사실만 정정된다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const b = await f.context(me, "B");
      const global = await f.explicit(me, { statement: "전체: 출시는 금요일" });
      const inB = await f.explicit(me, { scope_kind: "context", context_id: b, statement: "B: 출시는 수요일" });
      const sameFactInA = await f.explicit(me, { scope_kind: "context", context_id: a, statement: "A: 출시는 월요일" });
      const otherSubject = await f.explicit(me, { scope_kind: "context", context_id: a, subject: "office", statement: "A: 사무실은 판교" });
      const noSubject = (await f.remember(me, { kind: "fact", scope_kind: "context", context_id: a, subject: null, statement: "A: 주제 없는 사실", origin: "explicit" })).id!;
      const candidate = await f.candidate(me, { scope_kind: "context", context_id: a, statement: "A: 출시는 목요일인 듯" });
      const snapshot = Object.fromEntries(await Promise.all([global, inB, otherSubject, noSubject].map(async (id) => [id, await f.row(id)])));

      const item = itemOf(await f.confirm(me, candidate, 1));
      for (const id of [global, inB, otherSubject, noSubject]) expect(await f.row(id), id).toEqual(snapshot[id]); // 한 글자도 바뀌지 않았다 (version 포함)
      // 같은 범위의 같은 사실(explicit 다시 말함 규칙, B1)만 정정됐다
      expect(await f.row(sameFactInA)).toMatchObject({ superseded_by: item.id, version: 2 });
      expect((await f.current(me)).map((r) => r.statement).sort()).toEqual(
        ["A: 사무실은 판교", "A: 주제 없는 사실", "A: 출시는 목요일인 듯", "B: 출시는 수요일", "전체: 출시는 금요일"].sort(),
      );
    });

    it("두 번 보내거나(재시도) 낡은 version이면 conflict, 이미 정정 · 잊은 후보도 conflict: 쓰기 없음, 지금 행은 하나", async () => {
      const me = await f.user();
      const candidate = await f.candidate(me);
      expect(await f.confirm(me, candidate, 2)).toEqual({ status: "conflict" }); // 낡은(틀린) version
      const first = itemOf(await f.confirm(me, candidate, 1));
      const snapshot = await f.snapshot(me);
      expect(await f.confirm(me, candidate, 1)).toEqual({ status: "conflict" }); // 같은 요청의 재전송: 이미 정정됐다
      expect(await f.confirm(me, candidate, 2)).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect((await f.current(me)).map((r) => r.id)).toEqual([first.id]);

      const forgotten = await f.candidate(me, { subject: "x", statement: "잊을 후보" });
      itemOf(await f.forget(me, forgotten, 1));
      expect(await f.confirm(me, forgotten, 2)).toEqual({ status: "conflict" });
      expect((await f.row(forgotten)).superseded_at).toBeNull();
    });

    it("추정이 아닌 항목(explicit · observed · 글이 지워진 observed)은 확인할 수 없다: confirm_unavailable 쪽 거절, 쓰기 없음", async () => {
      const me = await f.user();
      const source = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const explicit = await f.explicit(me);
      const observed = await f.observed(me, source, { subject: "obs" });
      const purgedSource = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const purged = await f.observed(me, purgedSource, { subject: "obs2" });
      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now(), raw_text_purge_reason = 'retention' where id = $1`, [purgedSource]);
      expect(await f.row(purged)).toMatchObject({ statement: "", source_purged: true });
      const snapshot = await f.snapshot(me);
      for (const id of [explicit, observed, purged]) expect(await f.confirm(me, id, (await f.row(id)).version), id).toEqual({ status: "unavailable" });
      expect(await f.snapshot(me)).toEqual(snapshot);
    });

    it("주제 없는 후보도 확인된다: 새 행은 'memory:<후보 id>' 주제를 갖고(그 항목 자체가 사실의 열쇠), 다른 주제 없는 항목은 덮이지 않는다", async () => {
      const me = await f.user();
      const candidate = (await f.remember(me, { kind: "fact", scope_kind: "global", subject: null, statement: "주제 없는 후보", origin: "inferred", confidence: 0.5 })).id!;
      const bystander = (await f.remember(me, { kind: "fact", scope_kind: "global", subject: null, statement: "주제 없는 다른 사실", origin: "explicit" })).id!;
      const item = itemOf(await f.confirm(me, candidate, 1));
      expect(item).toMatchObject({ origin: "explicit", subject: `memory:${candidate}`, statement: "주제 없는 후보" });
      expect(await f.row(bystander)).toMatchObject({ superseded_at: null, version: 1 });
      expect((await f.current(me)).map((r) => r.statement).sort()).toEqual(["주제 없는 다른 사실", "주제 없는 후보"]);
    });

    it("정책 보류 (a): Slack 원문에서 온 후보는 확인할 수 없다 — D3를 우회하지 않는다 (쓰기 없음). Slack을 끊으면 그 후보는 지워진다 (404)", async () => {
      const me = await f.user();
      const slack = await cf.connectionSource(me, "slack", "#sales\n김대표: 출시는 목요일입니다");
      const gmail = await cf.connectionSource(me, "gmail", "출시는 목요일입니다");
      const fromSlack = await f.candidate(me, { subject: "slack fact", statement: "출시는 목요일인 듯", source_ref: { source_id: slack, quote: "출시는 목요일" } });
      const fromGmail = await f.candidate(me, { subject: "mail fact", statement: "출시는 목요일인 듯", source_ref: { source_id: gmail, quote: "출시는 목요일" } });
      const counts = await authorityCounts();
      const snapshot = await f.snapshot(me);
      expect(await f.confirm(me, fromSlack, 1)).toEqual({ status: "unavailable" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect((await f.row(fromSlack)).superseded_at).toBeNull();
      // 같은 모양의 다른 provider(gmail) 후보는 확인된다: 막는 기준은 출처가 Slack이라는 것뿐이다
      expect(itemOf(await f.confirm(me, fromGmail, 1))).toMatchObject({ origin: "explicit", statement: "출시는 목요일인 듯" });

      // 링크가 Slack인 원문 (연결 행이 지워져 provider가 비어도): 같은 기준
      const linked = (await f.one(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, external_url) values ($1, 'message', 'x', now(), 'https://acme.slack.com/archives/C1/p1') returning id`,
        [me],
      )).id as string;
      const fromLink = await f.candidate(me, { subject: "linked", statement: "링크가 Slack", source_ref: { source_id: linked, quote: "x" } });
      expect(await f.confirm(me, fromLink, 1)).toEqual({ status: "unavailable" });

      // Slack을 끊으면(D3) Slack 후보는 지워져 확인할 것이 없다
      await db().query(`select public.purge_slack_sources(array[$1]::uuid[])`, [slack]);
      expect(await f.row(fromSlack)).toBeUndefined();
      expect(await f.confirm(me, fromSlack, 1)).toEqual({ status: "not_found" });
      expect(await authorityCounts()).toEqual(counts);
    });

    it("보관 기간으로 원문이 지워지면 그 후보는 지워져 404, 지워지기 전에 확인한 explicit은 정리 뒤에도 글 · 인용이 남는다", async () => {
      const me = await f.user();
      const source = await f.source(me, { connectionId: await f.connection(me, "gmail"), externalId: "m-1", version: "1" });
      const stays = await f.candidate(me, { subject: "stays", statement: "남는 후보", source_ref: { source_id: source, quote: "원문 구절" } });
      const confirmed = itemOf(await f.confirm(me, stays, 1));
      const pending = await f.candidate(me, { subject: "pending", statement: "지워질 후보", source_ref: { source_id: source, quote: "다른 구절" } });
      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now(), raw_text_purge_reason = 'retention' where id = $1`, [source]);
      expect(await f.row(pending)).toBeUndefined();
      expect(await f.confirm(me, pending, 1)).toEqual({ status: "not_found" });
      expect(await f.row(confirmed.id)).toMatchObject({ statement: "남는 후보", source_ref: { source_id: source, quote: "원문 구절" } });

    });
  });

  describe("정책 보류 (d): 접근을 잃은 원문(access_lost_at, 문서 단위)에서 온 후보는 확인할 수 없다 (Codex 출처 경계 검토)", () => {
    const lose = (userId: string, sourceId: string) => db().query(`select public.set_sources_access($1, array[$2]::uuid[], true)`, [userId, sourceId]);
    const restore = (userId: string, sourceId: string) => db().query(`select public.set_sources_access($1, array[$2]::uuid[], false)`, [userId, sourceId]);
    /** 새 묶음이 담는 기억 (production loadScopeMemory · loadSourceStates · buildContextBundle) */
    async function bundleMemory(userId: string, sourceIds: string[]) {
      const bundle = buildContextBundle({
        context: null,
        me: { display_name: "Synthetic", emails: [] },
        memory: await loadScopeMemory(f.admin(), userId, {}, ON),
        people: [],
        chunks: [],
        sources: await loadSourceStates(f.admin(), userId, sourceIds),
        now: new Date(),
      }).bundle;
      return bundle.memory.map((m) => m.id);
    }
    const documentSource = async (userId: string, externalId: string, version = "1", connectionId?: string) =>
      f.source(userId, { connectionId: connectionId ?? (await f.connection(userId, "gmail")), externalId, version });

    it("접근을 잃은 문서의 후보는 확인할 수 없다: 쓰기 없음 · 묶음 memory 0 유지. 접근이 있는 후보는 확인되고 묶음에 들어간다", async () => {
      const me = await f.user();
      const lost = await documentSource(me, "lost-doc");
      const healthy = await documentSource(me, "healthy-doc");
      const lostCandidate = await f.candidate(me, { subject: "lost fact", statement: "접근 잃은 문서의 후보", source_ref: { source_id: lost, quote: "구절" } });
      const healthyCandidate = await f.candidate(me, { subject: "healthy fact", statement: "접근 있는 문서의 후보", source_ref: { source_id: healthy, quote: "구절" } });
      await lose(me, lost);
      expect((await loadSourceStates(f.admin(), me, [lost]))[0].accessLost).toBe(true);
      expect(await bundleMemory(me, [lost, healthy])).toEqual([]);

      const snapshot = await f.snapshot(me);
      expect(await f.confirm(me, lostCandidate, 1)).toEqual({ status: "unavailable" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect(await bundleMemory(me, [lost, healthy])).toEqual([]);

      const confirmed = itemOf(await f.confirm(me, healthyCandidate, 1));
      expect(confirmed).toMatchObject({ origin: "explicit", statement: "접근 있는 문서의 후보" });
      expect(await bundleMemory(me, [lost, healthy])).toEqual([confirmed.id]);
    });

    it("문서 단위: 같은 문서의 다른 revision 후보도 막히고, 잃은 뒤 들어온 새 revision은 되찾음이 아니다. 명시 복원(access_lost null) 뒤에는 다시 확인된다", async () => {
      const me = await f.user();
      const connection = await f.connection(me, "gmail");
      const r1 = await documentSource(me, "doc-1", "1", connection);
      const r2 = await documentSource(me, "doc-1", "2", connection);
      const c1 = await f.candidate(me, { subject: "r1", statement: "revision 1의 후보", source_ref: { source_id: r1, quote: "구절" } });
      const c2 = await f.candidate(me, { subject: "r2", statement: "revision 2의 후보", source_ref: { source_id: r2, quote: "구절" } });
      await lose(me, r2); // 문서 전체(모든 revision)를 잃는다
      const r3 = await documentSource(me, "doc-1", "3", connection); // 잃은 뒤에 들어온 새 revision: access_lost_at은 비어 있지만 문서는 여전히 잃은 상태
      const c3 = await f.candidate(me, { subject: "r3", statement: "새 revision의 후보", source_ref: { source_id: r3, quote: "구절" } });
      expect((await f.one(`select access_lost_at from public.sources where id = $1`, [r3])).access_lost_at).toBeNull();
      for (const candidate of [c1, c2, c3]) expect(await f.confirm(me, candidate, 1), candidate).toEqual({ status: "unavailable" });

      await restore(me, r1);
      expect((await loadSourceStates(f.admin(), me, [r1, r2, r3])).map((state) => state.accessLost)).toEqual([false, false, false]);
      for (const candidate of [c1, c2, c3]) expect(itemOf(await f.confirm(me, candidate, 1)).origin, candidate).toBe("explicit");
    });

    it("다른 문서 · 다른 계정은 영향이 없다: 같은 사용자의 다른 문서 후보 · 같은 외부 id를 가진 다른 계정의 후보는 확인된다", async () => {
      const me = await f.user();
      const them = await f.user();
      const lost = await documentSource(me, "shared-external-id");
      const other = await documentSource(me, "other-doc");
      const theirs = await documentSource(them, "shared-external-id");
      const lostCandidate = await f.candidate(me, { subject: "a", statement: "잃은 문서", source_ref: { source_id: lost, quote: "구절" } });
      const otherCandidate = await f.candidate(me, { subject: "b", statement: "다른 문서", source_ref: { source_id: other, quote: "구절" } });
      const theirCandidate = await f.candidate(them, { subject: "c", statement: "남의 문서", source_ref: { source_id: theirs, quote: "구절" } });
      await lose(me, lost);
      expect(await f.confirm(me, lostCandidate, 1)).toEqual({ status: "unavailable" });
      expect(itemOf(await f.confirm(me, otherCandidate, 1)).origin).toBe("explicit");
      expect(itemOf(await f.confirm(them, theirCandidate, 1)).origin).toBe("explicit");
      expect((await loadSourceStates(f.admin(), them, [theirs]))[0].accessLost).toBe(false);
    });

    it("원래 explicit 사용자 기억은 그대로다(B1 보존): 잃기 전에 확인한 explicit은 묶음에 남고, 잃은 원문을 인용한 explicit도 같은 글로 고치고 잊을 수 있다", async () => {
      const me = await f.user();
      const source = await documentSource(me, "doc-then-lost");
      const candidate = await f.candidate(me, { subject: "kept", statement: "잃기 전에 확인", source_ref: { source_id: source, quote: "구절" } });
      const confirmed = itemOf(await f.confirm(me, candidate, 1));
      const own = await f.explicit(me, { subject: "own", statement: "내가 말한 사실", source_ref: { source_id: source, quote: "구절" } });
      await lose(me, source);
      expect((await bundleMemory(me, [source])).sort()).toEqual([confirmed.id, own].sort()); // B1 기존 동작: 확인된 explicit은 접근을 잃은 뒤에도 묶음에 든다
      const edited = itemOf(await f.edit(me, own, { expected_version: (await f.row(own)).version, statement: "내가 말한 사실" })); // 글자 그대로여도 explicit은 가드 대상이 아니다
      expect(edited).toMatchObject({ origin: "explicit", statement: "내가 말한 사실" });
      expect(itemOf(await f.forget(me, confirmed.id, confirmed.version)).revoked_at).not.toBeNull();
    });

    it("출처 상태를 읽지 못하면 쓰지 않는다 (fail-closed): 읽기 오류는 그대로 던지고, 상태가 비어 돌아와도 확인 · 글자 그대로 정정은 보류다. 쓰기 0", async () => {
      const me = await f.user();
      const source = await documentSource(me, "unreadable-doc");
      const candidate = await f.candidate(me, { subject: "x", statement: "상태를 못 읽는 후보", source_ref: { source_id: source, quote: "구절" } });
      const snapshot = await f.snapshot(me);
      const failing = sqlAdmin(async (sql, params) => {
        if (sql.includes("context_source_states")) throw new Error("source state unavailable");
        return db().query(sql, params);
      });
      await expect(confirmMemoryItem(failing, me, candidate, 1, ON)).rejects.toThrow(/source state unavailable/);
      await expect(editMemoryItem(failing, me, candidate, { expected_version: 1, statement: "다른 글" }, ON)).rejects.toThrow(/source state unavailable/);
      expect(await f.snapshot(me)).toEqual(snapshot);

      const empty = sqlAdmin(async (sql, params) => (sql.includes("context_source_states") ? [] : db().query(sql, params)));
      expect(await confirmMemoryItem(empty, me, candidate, 1, ON)).toEqual({ status: "unavailable" });
      expect(await editMemoryItem(empty, me, candidate, { expected_version: 1, statement: "상태를 못 읽는 후보" }, ON)).toEqual({ status: "unavailable" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect(itemOf(await f.confirm(me, candidate, 1)).origin).toBe("explicit"); // 읽을 수 있으면 확인된다
    });

    it("확인과 접근 상실이 겹칠 때의 보장 범위: 상실이 먼저 커밋되면 보류, 확인이 먼저 끝나면 확인된 explicit은 B1대로 보존된다. 출처 상태 읽기(트랜잭션 밖)와 쓰기 사이에 상실이 커밋되면 확인이 통과한다 — 알려진 한계", async () => {
      const me = await f.user();
      const first = await documentSource(me, "race-before");
      const second = await documentSource(me, "race-after");
      const third = await documentSource(me, "race-window");
      const candidate = (source: string, subject: string) => f.candidate(me, { subject, statement: `후보 ${subject}`, source_ref: { source_id: source, quote: "구절" } });
      const [c1, c2, c3] = [await candidate(first, "before"), await candidate(second, "after"), await candidate(third, "window")];

      await lose(me, first); // 상실이 먼저 → 보류
      expect(await f.confirm(me, c1, 1)).toEqual({ status: "unavailable" });

      const confirmed = itemOf(await f.confirm(me, c2, 1)); // 확인이 먼저 → 이후 상실에도 explicit은 보존 (B1)
      await lose(me, second);
      expect(await f.row(confirmed.id)).toMatchObject({ origin: "explicit", superseded_at: null, revoked_at: null });

      // 알려진 한계: 읽기와 쓰기가 한 트랜잭션이 아니다. 읽은 직후 상실이 커밋되면 "상실 직전에 끝난 확인"과 같은 결과가 된다 (창은 두 문장 사이)
      const racing = sqlAdmin(async (sql, params) => {
        const rows = await db().query(sql, params);
        if (sql.includes("context_source_states")) await lose(me, third);
        return rows;
      });
      expect(itemOf(await confirmMemoryItem(racing, me, c3, 1, ON)).origin).toBe("explicit");
      expect((await loadSourceStates(f.admin(), me, [third]))[0].accessLost).toBe(true);
    });

    it("글자 그대로 Edit하는 승격 우회도 막는다(대소문자 · 공백만 달라도). 새 글 Edit는 허용하고 옛 값 · 유효 구간 · 출처를 잇지 않는다. 잃은 원문의 observed도 같다", async () => {
      const me = await f.user();
      const source = await documentSource(me, "bypass-doc");
      const candidate = await f.candidate(me, {
        subject: "bypass", statement: "Lost Source Statement", value: { k: 1 }, valid_from: "2026-10-01T00:00:00Z", source_ref: { source_id: source, quote: "구절" },
      });
      const observed = await f.observed(me, source, { subject: "bypass obs", statement: "Observed Statement" });
      await lose(me, source);
      const snapshot = await f.snapshot(me);
      for (const statement of ["Lost Source Statement", "  lost   SOURCE statement "]) {
        expect(await f.edit(me, candidate, { expected_version: 1, statement }), statement).toEqual({ status: "unavailable" });
      }
      expect(await f.edit(me, observed, { expected_version: 1, statement: "observed statement" })).toEqual({ status: "unavailable" });
      expect(await f.snapshot(me)).toEqual(snapshot);

      const written = itemOf(await f.edit(me, candidate, { expected_version: 1, statement: "내가 새로 쓴 글" }));
      expect(written).toMatchObject({ origin: "explicit", statement: "내가 새로 쓴 글", value: {}, valid_from: null, source_ref: null });
      expect(itemOf(await f.edit(me, observed, { expected_version: 1, statement: "내가 새로 쓴 observed 대체 글" })).origin).toBe("explicit");
    });
  });

  describe("정정 (edit): 같은 사실 · 같은 범위의 새 explicit 행 + 옛 행 정정된 이력", () => {
    it("explicit을 고치면 새 글의 새 행이 지금 행이고 옛 행은 이력이다. 요청에 없는 값은 이어받고 null은 비운다, 범위는 그대로", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const old = await f.explicit(me, {
        scope_kind: "context", context_id: context, statement: "출시는 목요일", value: { day: "thu" }, valid_from: "2026-10-01T00:00:00Z", valid_until: "2026-12-31T00:00:00Z",
      });
      const before = await f.version(context);
      const edited = itemOf(await f.edit(me, old, { expected_version: 1, statement: " 출시는 금요일 ", valid_until: null }));
      expect(edited).toMatchObject({
        origin: "explicit", scope_kind: "context", context_id: context, subject: "launch day", statement: "출시는 금요일", value: { day: "thu" }, source_ref: null, valid_until: null, version: 1,
      });
      expect(Date.parse(edited.valid_from!)).toBe(Date.parse("2026-10-01T00:00:00Z"));
      expect(await f.row(old)).toMatchObject({ superseded_by: edited.id, version: 2, revoked_at: null, statement: "출시는 목요일" });
      expect(await f.version(context)).toBe(before + 1);
      const replaced = itemOf(await f.edit(me, edited.id, { expected_version: 1, statement: "출시는 토요일", value: { day: "sat" }, valid_from: "2026-10-05T00:00:00Z" }));
      expect(replaced).toMatchObject({ value: { day: "sat" }, valid_until: null });
      expect(Date.parse(replaced.valid_from!)).toBe(Date.parse("2026-10-05T00:00:00Z"));
    });

    it("무관한 같은 kind 사실 · 다른 범위의 같은 사실은 그대로, observed 항목을 고치면 explicit이 이기고 출처는 잇지 않는다 (옛 행이 출처를 이력으로 남긴다)", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const source = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const global = await f.explicit(me, { statement: "전체: 목요일" });
      const other = await f.explicit(me, { subject: "office", statement: "전체: 사무실은 판교" });
      const observed = await f.observed(me, source, { scope_kind: "context", context_id: a, statement: "A: 금요일" });
      const snapshot = { global: await f.row(global), other: await f.row(other) };
      const edited = itemOf(await f.edit(me, observed, { expected_version: 1, statement: "A: 수요일" }));
      expect(edited).toMatchObject({ origin: "explicit", scope_kind: "context", context_id: a, source_ref: null });
      expect(await f.row(global)).toEqual(snapshot.global);
      expect(await f.row(other)).toEqual(snapshot.other);
      expect(await f.row(observed)).toMatchObject({ origin: "observed", superseded_by: edited.id, source_ref: { source_id: source, quote: "출시는 금요일" } });
    });

    it("주제 없는 항목을 고치면 새 행은 'memory:<옛 id>' 주제를 갖고, 다른 주제 없는 항목은 덮이지 않는다", async () => {
      const me = await f.user();
      const mine = (await f.remember(me, { kind: "fact", scope_kind: "global", subject: null, statement: "주제 없음 1", origin: "explicit" })).id!;
      const other = (await f.remember(me, { kind: "fact", scope_kind: "global", subject: null, statement: "주제 없음 2", origin: "explicit" })).id!;
      const edited = itemOf(await f.edit(me, mine, { expected_version: 1, statement: "주제 없음 1 (고침)" }));
      expect(edited.subject).toBe(`memory:${mine}`);
      expect(await f.row(other)).toMatchObject({ superseded_at: null, version: 1 });
      // 다시 고쳐도 같은 사실의 열쇠를 이어받는다 ('memory:' 예약 주제를 요청에서 받지 않는다)
      const again = itemOf(await f.edit(me, edited.id, { expected_version: 1, statement: "주제 없음 1 (또 고침)" }));
      expect(again).toMatchObject({ subject: `memory:${mine}`, origin: "explicit" });
      expect((await f.current(me)).map((r) => r.statement).sort()).toEqual(["주제 없음 1 (또 고침)", "주제 없음 2"]);
    });

    it("정책 허용 (c): 글이 지워진(source_purged) 항목도 사용자가 새 글을 쓰면 고칠 수 있다 (옛 행은 비어 있는 채 이력)", async () => {
      const me = await f.user();
      const source = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const observed = await f.observed(me, source);
      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now(), raw_text_purge_reason = 'retention' where id = $1`, [source]);
      expect(await f.row(observed)).toMatchObject({ statement: "", source_purged: true, subject: null });
      const edited = itemOf(await f.edit(me, observed, { expected_version: 2, statement: "내가 다시 쓴 사실" }));
      expect(edited).toMatchObject({ origin: "explicit", statement: "내가 다시 쓴 사실", source_ref: null, subject: `memory:${observed}` });
      expect(await f.row(observed)).toMatchObject({ statement: "", source_purged: true, superseded_by: edited.id });
    });

    it("낡은 version · 이미 정정 · 잊은 항목은 conflict, 유효 구간이 거꾸로면 invalid: 쓰기 없음", async () => {
      const me = await f.user();
      const id = await f.explicit(me, { valid_from: "2026-10-10T00:00:00Z" });
      const snapshot = await f.snapshot(me);
      expect(await f.edit(me, id, { expected_version: 5, statement: "x" })).toEqual({ status: "conflict" });
      expect(await f.edit(me, id, { expected_version: 1, statement: "x", valid_until: "2026-10-01T00:00:00Z" })).toEqual({ status: "invalid" }); // 이어받은 valid_from보다 이르다
      expect(await f.snapshot(me)).toEqual(snapshot);
      const edited = itemOf(await f.edit(me, id, { expected_version: 1, statement: "새 글" }));
      expect(await f.edit(me, id, { expected_version: 1, statement: "다시" })).toEqual({ status: "conflict" }); // 재전송: 이미 정정됨
      expect(await f.edit(me, id, { expected_version: 2, statement: "다시" })).toEqual({ status: "conflict" });
      itemOf(await f.forget(me, edited.id, 1));
      expect(await f.edit(me, edited.id, { expected_version: 2, statement: "잊은 뒤" })).toEqual({ status: "conflict" });
      expect((await f.current(me)).length).toBe(0);
    });

    it("원문 삭제 · 접근 상실 뒤에도 쓸 수 있다: 글이 지워진 observed는 잊을 수 있고(정책 허용), 접근을 잃은 원문의 observed는 고치고 잊을 수 있다. 읽기에서는 계속 빠진다", async () => {
      const me = await f.user();
      const gone = await f.source(me, { connectionId: await f.connection(me, "gmail"), externalId: "g-1", version: "1" });
      const lost = await f.source(me, { connectionId: await f.connection(me, "gmail"), externalId: "g-2", version: "1" });
      const purged = await f.observed(me, gone, { subject: "p1", statement: "지워질 사실" });
      const lostOne = await f.observed(me, lost, { subject: "p2", statement: "접근 잃을 사실" });
      const lostTwo = await f.observed(me, lost, { subject: "p3", statement: "접근 잃을 사실 2" });
      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now(), raw_text_purge_reason = 'retention' where id = $1`, [gone]);
      await db().query(`select public.set_sources_access($1, array[$2]::uuid[], true)`, [me, lost]);

      const forgottenPurged = itemOf(await f.forget(me, purged, (await f.row(purged)).version));
      expect(forgottenPurged).toMatchObject({ statement: "", source_purged: true });
      expect(forgottenPurged.revoked_at).not.toBeNull();
      expect(itemOf(await f.edit(me, lostOne, { expected_version: 1, statement: "내가 확인한 사실" }))).toMatchObject({ origin: "explicit", source_ref: null });
      expect(itemOf(await f.forget(me, lostTwo, 1)).revoked_at).not.toBeNull();
      expect((await f.current(me)).map((r) => r.statement)).toEqual(["내가 확인한 사실"]);
    });

    it("계정을 지운 뒤에는(cascade) 모든 쓰기가 not_found다", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const id = await f.explicit(me);
      const candidate = await f.candidate(me, { subject: "c" });
      await db().query(`delete from auth.users where id = $1`, [me]);
      expect(await f.confirm(me, candidate, 1)).toEqual({ status: "not_found" });
      expect(await f.edit(me, id, { expected_version: 1, statement: "x" })).toEqual({ status: "not_found" });
      expect(await f.forget(me, id, 1)).toEqual({ status: "not_found" });
      expect(await f.move(me, id, 1, { scope_kind: "context", context_id: context })).toEqual({ status: "not_found" });
      expect(await setConversationContext(f.admin(), me, randomUUID(), null, ON)).toEqual({ status: "not_found" });
    });

    it("정정한 새 행을 지워도 옛 행은 지금 기억으로 돌아오지 않는다 (superseded_at 불변, 읽기에도 안 나온다)", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const old = await f.explicit(me, { scope_kind: "context", context_id: context });
      const edited = itemOf(await f.edit(me, old, { expected_version: 1, statement: "고친 글" }));
      await db().query(`delete from public.memory_items where id = $1`, [edited.id]);
      expect(await f.row(old)).toMatchObject({ superseded_by: null });
      expect((await f.row(old)).superseded_at).not.toBeNull();
      expect(await f.current(me)).toEqual([]);
      expect(await loadScopeMemory(f.admin(), me, { contextId: context }, ON)).toEqual([]);
      await expect(db().query(`update public.memory_items set superseded_at = null where id = $1`, [old])).rejects.toThrow(/superseded_at is permanent/);
    });

    it("정책 보류 (a): Slack에서 온 후보는 글자 그대로(대소문자 · 공백만 다르게) 고칠 수 없고, 새 글이면 구조화 값 · 유효 구간 · 출처를 잇지 않는 새 explicit 행이 된다. Slack에서 온 observed도 같다", async () => {
      const me = await f.user();
      const slack = await cf.connectionSource(me, "slack", "#sales\n김대표: 출시는 목요일입니다");
      const candidate = await f.candidate(me, {
        subject: "slack fact", statement: "Launch is Thursday", value: { day: "thu" }, valid_from: "2026-10-01T00:00:00Z", source_ref: { source_id: slack, quote: "출시는 목요일" },
      });
      const snapshot = await f.snapshot(me);
      for (const statement of ["Launch is Thursday", "  launch   IS thursday ", "ＬＡＵＮＣＨ is Thursday"]) {
        expect(await f.edit(me, candidate, { expected_version: 1, statement }), statement).toEqual({ status: "unavailable" });
      }
      expect(await f.snapshot(me)).toEqual(snapshot);
      const written = itemOf(await f.edit(me, candidate, { expected_version: 1, statement: "출시는 이번 주 목요일" }));
      expect(written).toMatchObject({ origin: "explicit", statement: "출시는 이번 주 목요일", value: {}, valid_from: null, valid_until: null, source_ref: null, subject: "slack fact" });
      expect(await f.row(candidate)).toMatchObject({ superseded_by: written.id });

      const observed = await f.observed(me, slack, { subject: "slack obs", statement: "금요일 마감", source_ref: { source_id: slack, quote: "마감" } });
      expect(await f.edit(me, observed, { expected_version: 1, statement: "금요일 마감" })).toEqual({ status: "unavailable" });
      expect(itemOf(await f.edit(me, observed, { expected_version: 1, statement: "금요일 오후 마감" }))).toMatchObject({ origin: "explicit", source_ref: null, value: {} });
    });

    it("Slack이 아닌 후보는 글자 그대로 고쳐도 된다 (사용자가 직접 한 요청). explicit은 출처와 상관없이 늘 고칠 수 있다", async () => {
      const me = await f.user();
      const gmail = await cf.connectionSource(me, "gmail", "메일 본문");
      const candidate = await f.candidate(me, { statement: "그대로 둔다", value: { k: 1 }, source_ref: { source_id: gmail, quote: "메일" } });
      expect(itemOf(await f.edit(me, candidate, { expected_version: 1, statement: "그대로 둔다" }))).toMatchObject({ origin: "explicit", value: { k: 1 }, source_ref: null });
    });
  });

  describe("잊기 (forget): revoked_at은 되돌릴 수 없다", () => {
    it("잊으면 revoked_at이 서고 version + 1이며 정정 이력(superseded)이 아니다. 범위 기억이면 범위 version이 정확히 + 1, 전체 기억은 어떤 범위 version도 올리지 않는다", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const other = await f.context(me, "다른 범위");
      const scoped = await f.explicit(me, { scope_kind: "context", context_id: context });
      const global = await f.explicit(me, { subject: "global fact", statement: "전체 기억" });
      const [v1, v2] = [await f.version(context), await f.version(other)];

      const forgotten = itemOf(await f.forget(me, scoped, 1));
      expect(forgotten).toMatchObject({ id: scoped, version: 2, superseded_at: null, superseded_by: null });
      expect(forgotten.revoked_at).not.toBeNull();
      expect(await f.version(context)).toBe(v1 + 1);
      itemOf(await f.forget(me, global, 1));
      expect([await f.version(context), await f.version(other)]).toEqual([v1 + 1, v2]);
    });

    it("잊은 기억은 지금 기억 · 읽기 · 묶음 · 상담 근거에 다시 나오지 않고, 같은 사실을 다시 말하면 새 행이며 옛 행은 잊은 채 그대로다", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const scoped = await f.explicit(me, { scope_kind: "context", context_id: context, statement: "Shape: 개발은 Opus로" });
      const keep = await f.explicit(me, { subject: "keep", statement: "전체: 금요일엔 회의 없음" });
      const consult = async () =>
        (await loadConsultContext(f.admin(), me, { contextId: context, query: "개발", chunks: false, deadline: Date.now() + 60_000, now: new Date() }, ON)).memory.map((m) => m.statement).sort();
      expect(await consult()).toEqual(["Shape: 개발은 Opus로", "전체: 금요일엔 회의 없음"]);

      const forgotten = itemOf(await f.forget(me, scoped, 1));
      expect(await consult()).toEqual(["전체: 금요일엔 회의 없음"]);
      expect((await loadScopeMemory(f.admin(), me, { contextId: context }, ON)).map((m) => m.id)).toEqual([keep]);
      expect((await f.current(me)).map((r) => r.id)).toEqual([keep]);

      const restated = await f.explicit(me, { scope_kind: "context", context_id: context, statement: "Shape: 개발은 Sonnet으로" });
      expect(await consult()).toEqual(["Shape: 개발은 Sonnet으로", "전체: 금요일엔 회의 없음"]);
      expect(await f.row(scoped)).toMatchObject({ revoked_at: expect.anything(), superseded_by: null, version: forgotten.version });
      expect(restated).not.toBe(scoped);
      await expect(db().query(`update public.memory_items set revoked_at = null where id = $1`, [scoped])).rejects.toThrow(/revoked_at is permanent/);
    });

    it("같은 요청의 재전송은 200 성공(멱등: 행 변화 없음). 그 사이 version이 더 올랐어도 같고, 행보다 큰 version은 conflict", async () => {
      const me = await f.user();
      const id = await f.explicit(me);
      const first = itemOf(await f.forget(me, id, 1));
      const snapshot = await f.snapshot(me);
      const again = itemOf(await f.forget(me, id, 1));
      expect(again).toEqual(first);
      expect(await f.snapshot(me)).toEqual(snapshot);
      await db().query(`update public.memory_items set version = version + 3 where id = $1`, [id]); // 잊은 뒤 원문 삭제 전파가 version을 더 올린 경우
      expect(itemOf(await f.forget(me, id, 1)).version).toBe(5);
      expect(await f.forget(me, id, 99)).toEqual({ status: "conflict" });
    });

    it("낡은 version · 정정된 항목은 conflict (쓰기 없음). 후보(inferred)도 잊을 수 있다 (폐기)", async () => {
      const me = await f.user();
      const id = await f.explicit(me);
      const snapshot = await f.snapshot(me);
      expect(await f.forget(me, id, 2)).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      const edited = itemOf(await f.edit(me, id, { expected_version: 1, statement: "고침" }));
      expect(await f.forget(me, id, 2)).toEqual({ status: "conflict" }); // 정정된 옛 행은 잊지 않는다: 지금 행을 가리켜야 한다
      expect((await f.row(id)).revoked_at).toBeNull();
      expect(itemOf(await f.forget(me, edited.id, 1)).revoked_at).not.toBeNull();
      const candidate = await f.candidate(me, { subject: "c", statement: "후보" });
      expect(itemOf(await f.forget(me, candidate, 1)).revoked_at).not.toBeNull();
      expect(await f.current(me)).toEqual([]);
    });

    it("늦은 응답: B2 대화의 늦은 정정은 잊은 기억을 살리지 못한다 (conflict, 지금 행 0)", async () => {
      const me = await f.user();
      const id = await f.explicit(me, { kind: "plan", subject: "개발 에이전트", statement: "개발은 Opus 5.5로" });
      const conversation = await cf.conversation(me);
      const message = await cf.post(me, conversation, randomUUID(), "Sonnet으로 바꿔");
      itemOf(await f.forget(me, id, 1)); // 앱에서 잊음 (대화의 답이 아직 만들어지는 중)
      const done = await cf.finish(me, message.message_id!, {
        memory: [{ item: { kind: "plan", scope_kind: "global", subject: null, statement: "개발은 Sonnet 5.5로", origin: "explicit", value: {} }, corrects: id, expected_version: 1 }],
      });
      expect(done.status).toBe("conflict");
      expect(await f.current(me)).toEqual([]);
      expect((await f.row(id)).superseded_at).toBeNull();
    });
  });

  describe("범위 옮기기 (scope): 정정과 다른 '옮김' — 새 explicit 행 + 옛 행 잊음, 한 트랜잭션", () => {
    it("전체 → 범위: 같은 kind · subject · 글 · 값 · 말한 시각의 새 explicit 행(value.moved_from)이 그 범위의 지금 행, 옛 행은 잊음(정정이 아님). 대상 범위 version만 + 1", async () => {
      const me = await f.user();
      const project = await f.context(me, "Shape");
      const other = await f.context(me, "다른 프로젝트");
      const old = await f.explicit(me, { statement: "출시는 목요일", value: { day: "thu" }, valid_from: "2026-10-01T00:00:00Z" });
      const oldRow = await f.row(old);
      const [vp, vo] = [await f.version(project), await f.version(other)];

      const moved = itemOf(await f.move(me, old, 1, { scope_kind: "context", context_id: project }));
      expect(moved).toMatchObject({
        origin: "explicit", kind: "fact", scope_kind: "context", context_id: project, subject: "launch day", statement: "출시는 목요일", value: { day: "thu", moved_from: old },
        superseded_at: null, revoked_at: null, version: 1,
      });
      expect(Date.parse(moved.observed_at)).toBe(new Date(oldRow.observed_at).getTime());
      expect(Date.parse(moved.valid_from!)).toBe(Date.parse("2026-10-01T00:00:00Z"));
      const after = await f.row(old);
      expect(after).toMatchObject({ superseded_at: null, superseded_by: null, version: 2 });
      expect(after.revoked_at).not.toBeNull();
      expect(await f.current(me)).toEqual([{ id: moved.id, statement: "출시는 목요일", scope_kind: "context", context_id: project }]);
      expect([await f.version(project), await f.version(other)]).toEqual([vp + 1, vo]);
    });

    it("범위 → 전체 · 범위 → 다른 범위: 옛 범위와 새 범위의 version이 각각 + 1. 옮긴 행은 다시 옮길 수 있다 (moved_from은 직전 출처)", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const b = await f.context(me, "B");
      const id = await f.explicit(me, { scope_kind: "context", context_id: a });
      const [va, vb] = [await f.version(a), await f.version(b)];
      const inB = itemOf(await f.move(me, id, 1, { scope_kind: "context", context_id: b }));
      expect([await f.version(a), await f.version(b)]).toEqual([va + 1, vb + 1]);
      const global = itemOf(await f.move(me, inB.id, 1, { scope_kind: "global" }));
      expect(global).toMatchObject({ scope_kind: "global", context_id: null, value: { moved_from: inB.id } });
      expect([await f.version(a), await f.version(b)]).toEqual([va + 1, vb + 2]);
      expect((await f.current(me)).map((r) => r.id)).toEqual([global.id]);
    });

    it("대상 범위에 같은 사실의 지금 행이 있으면 그 범위 안에서만 정정되고, 전체 기본값 · 다른 범위의 같은 사실은 그대로다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const b = await f.context(me, "B");
      const moving = await f.explicit(me, { scope_kind: "context", context_id: b, statement: "B에서 옮기는 글" });
      const inA = await f.explicit(me, { scope_kind: "context", context_id: a, statement: "A에 있던 글" });
      const global = await f.explicit(me, { statement: "전체 기본값" });
      const unrelated = await f.explicit(me, { scope_kind: "context", context_id: a, subject: "office", statement: "A: 사무실은 판교" });
      const snapshot = { global: await f.row(global), unrelated: await f.row(unrelated) };
      const moved = itemOf(await f.move(me, moving, 1, { scope_kind: "context", context_id: a }));
      expect(await f.row(inA)).toMatchObject({ superseded_by: moved.id, version: 2, revoked_at: null });
      expect(await f.row(global)).toEqual(snapshot.global);
      expect(await f.row(unrelated)).toEqual(snapshot.unrelated);
      expect((await f.current(me)).map((r) => r.statement).sort()).toEqual(["A: 사무실은 판교", "B에서 옮기는 글", "전체 기본값"].sort());
    });

    it("이미 그 범위면 쓰지 않는다 (같은 행을 돌려준다). 주제 없는 기억도 옮겨진다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const id = await f.explicit(me, { scope_kind: "context", context_id: a });
      const snapshot = await f.snapshot(me);
      expect(itemOf(await f.move(me, id, 1, { scope_kind: "context", context_id: a })).id).toBe(id);
      expect(await f.snapshot(me)).toEqual(snapshot);
      const noSubject = (await f.remember(me, { kind: "fact", scope_kind: "global", subject: null, statement: "주제 없는 사실", origin: "explicit" })).id!;
      expect(itemOf(await f.move(me, noSubject, 1, { scope_kind: "context", context_id: a }))).toMatchObject({ subject: null, statement: "주제 없는 사실", scope_kind: "context" });
    });

    it("정책 보류 (b): observed · inferred와 할 일 · 에이전트 범위의 기억은 범위를 바꿀 수 없다 (scope_unavailable 쪽 거절, 쓰기 없음)", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const source = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const action = (await f.one(`insert into public.actions (user_id, title) values ($1, '할 일') returning id`, [me])).id as string;
      const observed = await f.observed(me, source);
      const candidate = await f.candidate(me, { subject: "c" });
      const actionScoped = await f.explicit(me, { scope_kind: "action", action_id: action, subject: "act", statement: "할 일 범위" });
      const agentScoped = await f.explicit(me, { kind: "working_rule", scope_kind: "agent", agent_adapter: "agent:claude-code", subject: "rule", statement: "에이전트 규칙" });
      const snapshot = await f.snapshot(me);
      for (const id of [observed, candidate, actionScoped, agentScoped]) {
        expect(await f.move(me, id, 1, { scope_kind: "context", context_id: a }), id).toEqual({ status: "unavailable" });
        expect(await f.move(me, id, 1, { scope_kind: "global" }), id).toEqual({ status: "unavailable" });
      }
      expect(await f.snapshot(me)).toEqual(snapshot);
    });

    it("남의 범위 · 없는 범위 · 보관된 범위로는 옮길 수 없고(404, 쓰기 없음), 낡은 version · 정정 · 잊은 항목은 conflict", async () => {
      const me = await f.user();
      const them = await f.user();
      const mine = await f.context(me, "내 범위");
      const archived = await f.context(me, "보관");
      await db().query(`update public.work_contexts set status = 'archived' where id = $1`, [archived]);
      const theirs = await f.context(them, "남의 범위");
      const id = await f.explicit(me);
      const snapshot = await f.snapshot(me);
      for (const target of [theirs, randomUUID(), archived]) expect(await f.move(me, id, 1, { scope_kind: "context", context_id: target }), target).toEqual({ status: "not_found" });
      expect(await f.move(me, id, 7, { scope_kind: "context", context_id: mine })).toEqual({ status: "conflict" });
      expect(await f.snapshot(me)).toEqual(snapshot);
      expect(await f.version(theirs)).toBe(1);

      const moved = itemOf(await f.move(me, id, 1, { scope_kind: "context", context_id: mine }));
      expect(await f.move(me, id, 1, { scope_kind: "context", context_id: mine })).toEqual({ status: "conflict" }); // 재전송: 옛 행은 이미 잊었다
      itemOf(await f.forget(me, moved.id, 1));
      expect(await f.move(me, moved.id, 2, { scope_kind: "global" })).toEqual({ status: "conflict" });
    });

    it("옮긴 새 행을 지워도 옛 행은 지금 기억으로 돌아오지 않는다 (revoked_at 불변). 옮김은 정정 이력과 구별된다 (superseded 없음)", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const id = await f.explicit(me);
      const moved = itemOf(await f.move(me, id, 1, { scope_kind: "context", context_id: a }));
      await db().query(`delete from public.memory_items where id = $1`, [moved.id]);
      expect(await f.current(me)).toEqual([]);
      expect(await loadScopeMemory(f.admin(), me, { contextId: a }, ON)).toEqual([]);
      expect(await f.row(id)).toMatchObject({ superseded_at: null, superseded_by: null });
      expect((await f.row(id)).revoked_at).not.toBeNull();
    });

    it("출처 원문이 지워졌거나 Slack 끊기로 인용이 빠진 explicit 행도 옮겨진다: 새 행은 지운 원문의 id · 인용을 잇지 않는다 (가드), 남은 원문은 그대로 잇는다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const gone = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const kept = await f.source(me, { connectionId: await f.connection(me, "gmail") });
      const slack = await cf.connectionSource(me, "slack", "#sales\n김대표: 목요일");
      const ofGone = await f.explicit(me, { subject: "s1", statement: "지운 원문", source_ref: { source_id: gone, quote: "구절" } });
      const ofKept = await f.explicit(me, { subject: "s2", statement: "남은 원문", source_ref: { source_id: kept, quote: "구절" } });
      const ofSlack = await f.explicit(me, { subject: "s3", statement: "슬랙 끊김", source_ref: { source_id: slack, quote: "목요일" } });
      const ofMessage = await f.explicit(me, { subject: "s4", statement: "대화에서", source_ref: { message_id: randomUUID(), quote: "말한 구절" } });
      await db().query(`delete from public.sources where id = $1`, [gone]); // 원문 행 삭제: explicit은 인용만 뺀다 (source_id는 남는다)
      await db().query(`select public.purge_slack_sources(array[$1]::uuid[])`, [slack]);
      expect((await f.row(ofSlack)).source_ref).toEqual({ source_id: slack });

      // 원문 삭제 전파가 인용을 빼며 version을 올렸다: 앱은 읽은 version을 보낸다
      const version = async (id: string) => (await f.row(id)).version;
      expect(itemOf(await f.move(me, ofGone, await version(ofGone), { scope_kind: "context", context_id: a })).source_ref).toBeNull();
      expect(itemOf(await f.move(me, ofKept, await version(ofKept), { scope_kind: "context", context_id: a })).source_ref).toEqual({ source_id: kept, quote: "구절" });
      expect(itemOf(await f.move(me, ofSlack, await version(ofSlack), { scope_kind: "context", context_id: a })).source_ref).toEqual({ source_id: slack });
      const message = (await f.row(ofMessage)).source_ref;
      expect(itemOf(await f.move(me, ofMessage, 1, { scope_kind: "context", context_id: a })).source_ref).toEqual(message);
    });
  });

  describe("409는 성공의 증거가 아니다 (Codex 첫 독립 검토): 다른 기기의 Edit · Move · Forget도 같은 표시를 남긴다", () => {
    it("다른 기기의 Edit가 먼저 성공하면 내 Edit는 409다: 옛 행의 superseded_by는 서 있지만 후속 행의 글은 내 것이 아니다 (내 글은 어디에도 저장되지 않는다)", async () => {
      const me = await f.user();
      const id = await f.explicit(me, { statement: "Original date" });
      const other = itemOf(await f.edit(me, id, { expected_version: 1, statement: "Other device edit" }));
      expect(await f.edit(me, id, { expected_version: 1, statement: "This device edit" })).toEqual({ status: "conflict" });
      const old = await f.row(id);
      expect(old.superseded_by).toBe(other.id); // 내 요청이 성공했다는 표시와 구별되지 않는다
      expect((await f.row(old.superseded_by!)).statement).toBe("Other device edit");
      expect(await f.count(`select count(*)::int as n from public.memory_items where user_id = $1 and statement = 'This device edit'`, [me])).toBe(0);
      expect((await f.current(me)).map((r) => r.statement)).toEqual(["Other device edit"]);
    });

    it("다른 기기의 확인(또는 정정)이 먼저 성공하면 내 확인도 409다: 후보의 superseded_by는 다른 요청이 만든 행이다", async () => {
      const me = await f.user();
      const candidate = await f.candidate(me, { statement: "출시는 목요일인 듯" });
      const other = itemOf(await f.edit(me, candidate, { expected_version: 1, statement: "다른 기기에서 고쳐 쓴 글" }));
      expect(await f.confirm(me, candidate, 1)).toEqual({ status: "conflict" });
      expect((await f.row(candidate)).superseded_by).toBe(other.id);
      expect((await f.current(me)).map((r) => r.statement)).toEqual(["다른 기기에서 고쳐 쓴 글"]);
    });

    it("다른 기기가 범위 B로 먼저 옮기면 내 범위 A로의 옮기기는 409다: revoked_at과 moved_from 후속 행은 서 있지만 그 범위는 B다", async () => {
      const me = await f.user();
      const a = await f.context(me, "Synthetic A");
      const b = await f.context(me, "Synthetic B");
      const id = await f.explicit(me);
      const other = itemOf(await f.move(me, id, 1, { scope_kind: "context", context_id: b }));
      expect(await f.move(me, id, 1, { scope_kind: "context", context_id: a })).toEqual({ status: "conflict" });
      expect((await f.row(id)).revoked_at).not.toBeNull();
      const successors = await db().query(
        `select id, context_id from public.memory_items where user_id = $1 and value ->> 'moved_from' = $2 and superseded_at is null and revoked_at is null`,
        [me, id],
      );
      expect(successors).toEqual([{ id: other.id, context_id: b }]); // A에는 후속 행이 없다
      expect(await f.current(me, a)).toEqual([]);
    });

    it("forget의 200은 '이 항목은 지금 기억이 아니다'만 뜻한다: 다른 기기가 옮겨서 잊힌 항목에 보낸 forget도 200이고, 옮긴 후속 행은 여전히 지금 기억이다", async () => {
      const me = await f.user();
      const b = await f.context(me, "Synthetic B");
      const id = await f.explicit(me);
      const moved = itemOf(await f.move(me, id, 1, { scope_kind: "context", context_id: b }));
      const retry = itemOf(await f.forget(me, id, 1));
      expect(retry.revoked_at).not.toBeNull();
      expect((await f.current(me)).map((r) => r.id)).toEqual([moved.id]); // 내가 잊으려던 사실은 B에 그대로 살아 있다
      expect(await f.row(moved.id)).toMatchObject({ revoked_at: null, superseded_at: null });
    });

    it("Edit 비우기: value는 생략 = 상속, {} = 비움 (null은 400이라 서버까지 오지 않는다). valid_from · valid_until만 null = 비움", async () => {
      const me = await f.user();
      const id = await f.explicit(me, { value: { day: "thu" }, valid_from: "2026-10-01T00:00:00Z", valid_until: "2026-12-31T00:00:00Z" });
      const kept = itemOf(await f.edit(me, id, { expected_version: 1, statement: "상속" }));
      expect(kept.value).toEqual({ day: "thu" });
      expect(kept.valid_from).not.toBeNull();
      const cleared = itemOf(await f.edit(me, kept.id, { expected_version: 1, statement: "비움", value: {}, valid_from: null }));
      expect(cleared.value).toEqual({});
      expect(cleared.valid_from).toBeNull();
      expect(cleared.valid_until).not.toBeNull(); // 생략한 valid_until은 이어받는다
    });
  });

  describe("권한 · 격리 · gate", () => {
    it("기억·범위 쓰기는 Action · run · 정책 · 승인 · 사건 · 크레딧 · 대화 메시지 · 멤버를 한 줄도 만들지 않는다 (I04 · I14)", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const b = await f.context(me, "B");
      const candidate = await f.candidate(me, { scope_kind: "context", context_id: a });
      const explicit = await f.explicit(me, { subject: "e", statement: "e" });
      const forgettable = await f.explicit(me, { subject: "g", statement: "g" });
      const conversation = await cf.conversation(me);
      const before = await authorityCounts();
      const confirmed = itemOf(await f.confirm(me, candidate, 1));
      const edited = itemOf(await f.edit(me, explicit, { expected_version: 1, statement: "e2" }));
      const moved = itemOf(await f.move(me, edited.id, 1, { scope_kind: "context", context_id: b }));
      itemOf(await f.move(me, moved.id, 1, { scope_kind: "global" }));
      itemOf(await f.forget(me, forgettable, 1));
      itemOf(await f.forget(me, confirmed.id, 1));
      expect((await setConversationContext(f.admin(), me, conversation, a, ON)).status).toBe("updated");
      expect((await setConversationContext(f.admin(), me, conversation, null, ON)).status).toBe("updated");
      expect(await authorityCounts()).toEqual(before);
    });

    it("새 SQL 함수는 서버(service role)만 부른다: 앱 · 익명 불가, search_path 고정, 소유자 권한 아님", async () => {
      const rows = await db().query(
        `select p.proname as name, has_function_privilege('anon', p.oid, 'execute') as anon, has_function_privilege('authenticated', p.oid, 'execute') as auth,
                has_function_privilege('service_role', p.oid, 'execute') as service, p.prosecdef as definer, p.proconfig as config
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname in ('forget_memory_item', 'move_memory_item') order by p.proname`,
      );
      expect(rows.map((r) => r.name)).toEqual(["forget_memory_item", "move_memory_item"]);
      for (const row of rows) {
        expect(row, String(row.name)).toMatchObject({ anon: false, auth: false, service: true, definer: false });
        expect(row.config, String(row.name)).toContain('search_path=""');
      }
      const me = await f.user();
      const id = await f.explicit(me);
      await expect(db().asUser(me, () => db().query(`select * from public.forget_memory_item($1, $2, 1)`, [me, id]))).rejects.toThrow(/permission denied/);
      await expect(db().asUser(me, () => db().query(`select * from public.move_memory_item($1, $2, 1, 'global', null)`, [me, id]))).rejects.toThrow(/permission denied/);
      // 앱은 RLS로 자기 기억만 읽고 직접 쓰지 못한다 (쓰기는 서버 API만)
      await expect(db().asUser(me, () => db().query(`update public.memory_items set revoked_at = now() where id = $1`, [id]))).rejects.toThrow(/permission denied/);
    });

    it("다른 계정 · 다른 계정의 범위 · 없는 id는 모두 not_found이고 아무것도 바뀌지 않는다 (존재를 드러내지 않는다). 앱(RLS)도 남의 기억을 보지 못한다", async () => {
      const alice = await f.user();
      const bob = await f.user();
      const aliceContext = await f.context(alice, "Alice 프로젝트");
      const bobContext = await f.context(bob, "Bob 프로젝트");
      const candidate = await f.candidate(alice, { subject: "a1" });
      const explicit = await f.explicit(alice, { subject: "a2", statement: "Alice 기억" });
      const bobs = await f.explicit(bob, { subject: "b1", statement: "Bob 기억" });
      const snapshots = [await f.snapshot(alice), await f.snapshot(bob)];
      const versions = [await f.version(aliceContext), await f.version(bobContext)];
      const missing = randomUUID();
      for (const id of [candidate, explicit, missing]) {
        expect(await f.confirm(bob, id, 1), id).toEqual({ status: "not_found" });
        expect(await f.edit(bob, id, { expected_version: 1, statement: "해킹" }), id).toEqual({ status: "not_found" });
        expect(await f.forget(bob, id, 1), id).toEqual({ status: "not_found" });
        expect(await f.move(bob, id, 1, { scope_kind: "global" }), id).toEqual({ status: "not_found" });
        expect(await f.move(bob, id, 1, { scope_kind: "context", context_id: bobContext }), id).toEqual({ status: "not_found" });
        expect(await loadMemoryItem(f.admin(), bob, id), id).toBeNull();
      }
      // Bob이 자기 기억을 Alice의 범위로 옮길 수도 없다
      expect(await f.move(bob, bobs, 1, { scope_kind: "context", context_id: aliceContext })).toEqual({ status: "not_found" });
      expect([await f.snapshot(alice), await f.snapshot(bob)]).toEqual(snapshots);
      expect([await f.version(aliceContext), await f.version(bobContext)]).toEqual(versions);
      expect(await db().asUser(bob, () => db().query(`select id from public.memory_items where id = any($1::uuid[])`, [[candidate, explicit]]))).toEqual([]);
    });

    it("gate(MEMORY_ENABLED) 꺼짐: 모든 쓰기가 DB를 부르기 전에 막힌다 (쓰기 0)", async () => {
      const me = await f.user();
      const id = await f.explicit(me);
      const snapshot = await f.snapshot(me);
      let queries = 0;
      const counting = sqlAdmin(async (sql, params) => {
        queries++;
        return db().query(sql, params);
      });
      for (const env of [{}, { MEMORY_ENABLED: "TRUE" }, { MEMORY_ENABLED: "1" }, { MEMORY_ENABLED: " true" }]) {
        await expect(confirmMemoryItem(counting, me, id, 1, env)).rejects.toBeInstanceOf(ContextGateOffError);
        await expect(editMemoryItem(counting, me, id, { expected_version: 1, statement: "x" }, env)).rejects.toBeInstanceOf(ContextGateOffError);
        await expect(forgetMemoryItem(counting, me, id, 1, env)).rejects.toBeInstanceOf(ContextGateOffError);
        await expect(moveMemoryItem(counting, me, id, { expected_version: 1, scope_kind: "global", context_id: null }, env)).rejects.toBeInstanceOf(ContextGateOffError);
      }
      expect(queries).toBe(0);
      expect(await f.snapshot(me)).toEqual(snapshot);
    });
  });

  describe("대화 범위 바꾸기 (PATCH conversation): 명시적 선택만 — 멤버십 · 기억 · 범위 version 쓰기 없음", () => {
    it("내 active 범위로 바꾸고 null로 되돌린다. 같은 범위면 쓰지 않는다 (unchanged). 자동 범위 추정 · 멤버십 쓰기는 없다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const conversation = await cf.conversation(me);
      const version = await f.version(a);
      const set = await setConversationContext(f.admin(), me, conversation, a.toUpperCase(), ON);
      expect(set).toMatchObject({ status: "updated", conversation: { id: conversation, context_id: a } });
      expect(await setConversationContext(f.admin(), me, conversation, a, ON)).toMatchObject({ status: "unchanged", conversation: { context_id: a } });
      expect(await setConversationContext(f.admin(), me, conversation, null, ON)).toMatchObject({ status: "updated", conversation: { context_id: null } });
      expect(await f.version(a)).toBe(version);
      expect(await f.count(`select count(*)::int as n from public.context_members where user_id = $1`, [me])).toBe(0);
      expect(await f.count(`select count(*)::int as n from public.memory_items where user_id = $1`, [me])).toBe(0);
    });

    it("남의 대화 · 없는 대화는 not_found, 남의 · 없는 · 보관된 범위는 context_not_found: 대화는 바뀌지 않는다", async () => {
      const me = await f.user();
      const them = await f.user();
      const mine = await f.context(me, "A");
      const archived = await f.context(me, "보관");
      await db().query(`update public.work_contexts set status = 'archived' where id = $1`, [archived]);
      const theirContext = await f.context(them, "B");
      const conversation = await cf.conversation(me, mine);
      const theirConversation = await cf.conversation(them);
      const snapshot = await db().query(`select id, context_id, last_message_at from public.conversations where user_id = any($1::uuid[]) order by id`, [[me, them]]);
      for (const target of [theirContext, randomUUID(), archived]) expect(await setConversationContext(f.admin(), me, conversation, target, ON), target).toEqual({ status: "context_not_found" });
      expect(await setConversationContext(f.admin(), me, theirConversation, mine, ON)).toEqual({ status: "not_found" });
      expect(await setConversationContext(f.admin(), me, randomUUID(), null, ON)).toEqual({ status: "not_found" });
      expect(await setConversationContext(f.admin(), them, conversation, null, ON)).toEqual({ status: "not_found" });
      expect(await db().query(`select id, context_id, last_message_at from public.conversations where user_id = any($1::uuid[]) order by id`, [[me, them]])).toEqual(snapshot);
    });

    it("범위 기능(MEMORY_ENABLED)이 꺼져 있으면 범위를 고를 수 없고(context_off, 쓰기 0) All work로 되돌리는 것은 된다. 범위를 지우면 대화의 범위는 비워진다", async () => {
      const me = await f.user();
      const a = await f.context(me, "A");
      const conversation = await cf.conversation(me, a);
      expect(await setConversationContext(f.admin(), me, conversation, a, {})).toEqual({ status: "context_off" });
      expect(await setConversationContext(f.admin(), me, conversation, null, {})).toMatchObject({ status: "updated", conversation: { context_id: null } });
      const b = await f.context(me, "B");
      const other = await cf.conversation(me, b);
      await db().query(`delete from public.work_contexts where id = $1`, [b]);
      expect((await f.one(`select context_id from public.conversations where id = $1`, [other])).context_id).toBeNull();
    });
  });

  describe("handler → store → SQL: Mac이 받는 JSON (정확한 계약)", () => {
    const request = (method: string, body: unknown) => new Request("https://api.example.dev/api/v2/x", { method, body: JSON.stringify(body) });
    const authed = (userId: string) => async () => ({ user: { id: userId } });
    const base = (userId: string) => ({ enabled: () => true, authenticate: authed(userId) });
    const run = async (response: Response) => ({ status: response.status, body: (await response.json()) as Record<string, unknown> });

    it("확인 → 200 { item } (스키마를 지킨다), 재시도 409 conflict, Slack 후보 409 confirm_unavailable, 남의 id 404", async () => {
      const me = await f.user();
      const them = await f.user();
      const slack = await cf.connectionSource(me, "slack", "#sales\n김대표: 목요일");
      const candidate = await f.candidate(me, { subject: "a" });
      const fromSlack = await f.candidate(me, { subject: "b", source_ref: { source_id: slack, quote: "목요일" } });
      const deps = (userId: string) => ({ ...base(userId), confirm: (_u: unknown, id: string, body: { expected_version: number }) => confirmMemoryItem(f.admin(), userId, id, body.expected_version, ON) });
      const ok = await run(await handleConfirmMemory(request("POST", { expected_version: 1 }), candidate, deps(me)));
      expect(ok.status).toBe(200);
      const parsed = memoryItemResponseSchema.parse(ok.body);
      expect(parsed.item).toMatchObject({ origin: "explicit", scope_kind: "global", version: 1, superseded_at: null, revoked_at: null });
      expect((await run(await handleConfirmMemory(request("POST", { expected_version: 1 }), candidate, deps(me)))).status).toBe(409);
      const again = apiErrorV2Schema.parse((await run(await handleConfirmMemory(request("POST", { expected_version: 1 }), candidate, deps(me)))).body);
      expect(again.error.code).toBe("conflict");
      const held = await run(await handleConfirmMemory(request("POST", { expected_version: 1 }), fromSlack, deps(me)));
      expect(held.status).toBe(409);
      expect(apiErrorV2Schema.parse(held.body).error.code).toBe("confirm_unavailable");
      expect((await run(await handleConfirmMemory(request("POST", { expected_version: 1 }), candidate, deps(them)))).status).toBe(404);
    });

    it("정정 → 200 { item } 새 지금 행. 잊기 → 200 { item } (revoked_at), 같은 요청 재전송도 같은 200. 범위 옮기기 → 200 { item } (value.moved_from)", async () => {
      const me = await f.user();
      const project = await f.context(me, "Shape");
      const id = await f.explicit(me);
      const edit = await run(
        await handleEditMemory(request("PATCH", { expected_version: 1, statement: "출시는 금요일" }), id, {
          ...base(me),
          edit: (_u, memoryId, body) => editMemoryItem(f.admin(), me, memoryId, body, ON),
        }),
      );
      expect(edit.status).toBe(200);
      const edited = memoryItemResponseSchema.parse(edit.body).item;
      expect(edited).toMatchObject({ statement: "출시는 금요일", origin: "explicit", version: 1 });

      const moveDeps = { ...base(me), move: (_u: unknown, memoryId: string, body: Parameters<typeof moveMemoryItem>[3]) => moveMemoryItem(f.admin(), me, memoryId, body, ON) };
      const move = await run(await handleMoveMemory(request("POST", { expected_version: 1, scope_kind: "context", context_id: project }), edited.id, moveDeps));
      expect(move.status).toBe(200);
      const moved = memoryItemResponseSchema.parse(move.body).item;
      expect(moved).toMatchObject({ scope_kind: "context", context_id: project, value: { moved_from: edited.id } });
      expect((await run(await handleMoveMemory(request("POST", { expected_version: 1, scope_kind: "context", context_id: project }), edited.id, moveDeps))).status).toBe(409);
      const unavailable = await run(await handleMoveMemory(request("POST", { expected_version: 1, scope_kind: "global" }), (await f.candidate(me, { subject: "z" })), moveDeps));
      expect(unavailable.status).toBe(409);
      expect(apiErrorV2Schema.parse(unavailable.body).error.code).toBe("scope_unavailable");
      expect((await run(await handleMoveMemory(request("POST", { expected_version: 1, scope_kind: "context", context_id: randomUUID() }), moved.id, moveDeps))).status).toBe(404);

      const forgetDeps = { ...base(me), forget: (_u: unknown, memoryId: string, body: { expected_version: number }) => forgetMemoryItem(f.admin(), me, memoryId, body.expected_version, ON) };
      const forgot = await run(await handleForgetMemory(request("POST", { expected_version: 1 }), moved.id, forgetDeps));
      expect(forgot.status).toBe(200);
      const forgotten = memoryItemResponseSchema.parse(forgot.body).item;
      expect(forgotten).toMatchObject({ id: moved.id, version: 2, superseded_at: null });
      expect(forgotten.revoked_at).not.toBeNull();
      const retry = await run(await handleForgetMemory(request("POST", { expected_version: 1 }), moved.id, forgetDeps));
      expect(retry).toEqual({ status: 200, body: forgot.body });
    });

    it("대화 범위 바꾸기 → 200 { conversation }, 보관된 범위 404, 범위 기능 꺼짐 400", async () => {
      const me = await f.user();
      const project = await f.context(me, "Shape");
      const conversation = await cf.conversation(me);
      const deps = (env: Record<string, string>) => ({ ...base(me), update: (_u: unknown, id: string, contextId: string | null) => setConversationContext(f.admin(), me, id, contextId, env) });
      const ok = await run(await handleUpdateConversation(request("PATCH", { context_id: project }), conversation, deps(ON)));
      expect(ok.status).toBe(200);
      expect(updateConversationResponseSchema.parse(ok.body).conversation).toMatchObject({ id: conversation, context_id: project });
      expect((await run(await handleUpdateConversation(request("PATCH", { context_id: randomUUID() }), conversation, deps(ON)))).status).toBe(404);
      expect((await run(await handleUpdateConversation(request("PATCH", { context_id: project }), conversation, deps({})))).status).toBe(400);
      expect((await run(await handleUpdateConversation(request("PATCH", { context_id: null }), conversation, deps({})))).body).toMatchObject({ conversation: { context_id: null } });
    });
  });
}
