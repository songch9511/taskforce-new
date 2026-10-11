import { randomUUID } from "node:crypto";
import { readdir } from "node:fs/promises";
import path from "node:path";

import { beforeEach, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "./local-supabase";

// 0.2.0 코디네이터 1 (20261110000000_coordinator_core, 구현 계획 C2) — 사건 큐 DB 계약.
// inbox_events 확장(claim/lease · 시도 · 모델 호출 예산 · 처리 결과) · 서비스 롤 전용 RPC(적재 · 집기 · 끝내기 · 실패 · 예산 예약) ·
// 실제 성공 경로에 붙은 생산자 트리거 · 회수 · 기한 창 timer. 같은 시나리오를 PGlite(tests/db/coordinator-core.test.ts)와
// 실제 Postgres(tests/pg/coordinator-core.test.ts)에서 돌린다. 두 소비자 · 사용자별 직렬화 경합은 실제 Postgres 파일에만 있다.
// 표기: [실제 연결] = 지금 코드의 실제 성공 경로에 붙은 생산자, [미래 fixture] = 원천이 아직 없어 봉투 · 직접 적재로만 시험하는 것.

export type Rows = Record<string, unknown>[];

export type CoordinatorDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

/** 코디네이터가 아는 사건 종류 (아키텍처 7.1 입구). SQL coordinator_event_types()와 TS INBOX_EVENT_TYPES가 같아야 한다 */
export const EVENT_TYPES = [
  "user_message",
  "source_processed",
  "source_revised",
  "reply_observed",
  "agent_event",
  "dependency_changed",
  "memory_changed",
  "timer_due",
  "decision_made",
  "connection_changed",
  "bridge_unreachable",
];

export const RESULT_KINDS = ["no_impact", "impact_recorded", "stale", "rejected", "not_judged", "not_handled"];

export function coordinatorFixtures(db: () => CoordinatorDb) {
  const one = async (sql: string, params: unknown[] = []) => (await db().query(sql, params))[0];
  const id = async (sql: string, params: unknown[] = []) => (await one(sql, params)).id as string;
  const count = async (sql: string, params: unknown[] = []) => Number((await one(`select count(*)::int as n from (${sql}) x`, params)).n);
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);
  return {
    one,
    id,
    count,
    q,
    async user(): Promise<string> {
      const userId = randomUUID();
      await q(`insert into auth.users (id, email) values ($1, $2)`, [userId, `${userId}@example.com`]);
      return userId;
    },
    action: (userId: string, extra: { dueAt?: string | null; status?: string } = {}) =>
      id(`insert into public.actions (user_id, title, due_at, status) values ($1, '제안서 쓰기', $2, $3) returning id`, [userId, extra.dueAt ?? null, extra.status ?? "open"]),
    /** 아직 처리 전(pending) 원문. external이 같으면 같은 문서의 revision이다 */
    source: (userId: string, extra: { kind?: string; externalId?: string; version?: string; connection?: string } = {}) =>
      id(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, external_id, external_version, connection_id)
         values ($1, $2, '회의 원문 — 김대리가 금요일까지 보내기로 함', now(), $3, $4, $5) returning id`,
        [userId, extra.kind ?? "meeting", extra.externalId ?? null, extra.version ?? null, extra.connection ?? null],
      ),
    connection: (userId: string) =>
      id(`insert into public.connections (user_id, provider, external_account_id) values ($1, 'notion', $2) returning id`, [userId, randomUUID()]),
    setStatus: (sourceId: string, status: string) =>
      q(`update public.sources set processing_status = $2, processed_at = case when $2 in ('done', 'failed') then now() else processed_at end where id = $1`, [sourceId, status]),
    /** pending → processing → done (processSource가 하듯) */
    async finishSource(sourceId: string) {
      await q(`update public.sources set processing_status = 'processing' where id = $1`, [sourceId]);
      // processSource가 하듯 처리 요약을 남긴다 (처리 없이 INSERT로 바로 done인 행과 가르는 표시)
      await q(`update public.sources set processing_status = 'done', processed_at = now(), processing_summary = '{"attempt":1}' where id = $1`, [sourceId]);
    },
    conversation: (userId: string) => id(`insert into public.conversations (user_id) values ($1) returning id`, [userId]),
    message: (userId: string, conversationId: string, role = "user", seq = 1) =>
      id(
        `insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text) values ($1, $2, $3, $4, $5, '안녕') returning id`,
        [userId, conversationId, seq, role, role === "user" ? randomUUID() : null],
      ),
    context: (userId: string) => id(`insert into public.work_contexts (user_id, name, kind) values ($1, 'Shape 출시 준비', 'project') returning id`, [userId]),
    run: (userId: string, actionId: string) => id(`select public.create_run($1, $2, 'draft', '제안서 초안 써 줘') as id`, [userId, actionId]),
    /** 직접 적재 (원천이 아직 없는 사건 · 순서 시험). created_at을 정해 같은 시각 묶음을 만든다 */
    async event(userId: string, type: string, key: string, refs: Record<string, unknown> = {}, createdAt?: string): Promise<string> {
      return id(
        `insert into public.inbox_events (user_id, type, dedup_key, refs, created_at) values ($1, $2, $3, $4, coalesce($5::timestamptz, now())) returning id`,
        [userId, type, key, JSON.stringify(refs), createdAt ?? null],
      );
    },
    events: (userId: string) => q(`select id, type, dedup_key, refs, processed_at, result_kind from public.inbox_events where user_id = $1 order by created_at, seq`, [userId]),
    claim: (consumer = "fn-1", lease = 60, limit = 10, maxAttempts = 3) =>
      q(`select * from public.coordinator_claim($1, $2, $3, $4)`, [consumer, lease, limit, maxAttempts]),
    finish: async (eventId: string, token: string, kind = "no_impact", ids: Record<string, unknown> = {}, evidence: string | null = null) =>
      (await one(`select public.coordinator_finish($1, $2, $3, $4, $5) as status`, [eventId, token, kind, JSON.stringify(ids), evidence])).status as string,
    /** claim 만료를 앞당긴다 (시계를 움직이지 않고 같은 효과: 실제 Postgres에서도 쓴다) */
    expire: (eventId: string) => q(`update public.inbox_events set claim_expires_at = now() - interval '1 second' where id = $1`, [eventId]),
  };
}

const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);

export function coordinatorCoreTests(db: () => CoordinatorDb) {
  const f = coordinatorFixtures(db);
  const q = f.q;

  // ───────────────────────── 1) 저장 모양 · 권한 ─────────────────────────
  describe("inbox_events 확장: 열 · 제약 · 권한 (additive)", () => {
    it("A2 열은 그대로이고(type · dedup_key · refs · created_at · processed_at) 새 열만 더해졌다", async () => {
      const columns = (
        await q(`select column_name from information_schema.columns where table_schema = 'public' and table_name = 'inbox_events' order by column_name`)
      ).map((r) => r.column_name);
      for (const old of ["id", "user_id", "type", "dedup_key", "refs", "created_at", "processed_at"]) expect(columns).toContain(old);
      for (const added of [
        "seq", "claim_token", "claimed_by", "claimed_at", "claim_expires_at", "attempts", "last_error_kind", "dead_at",
        "model_calls", "jev_calls", "result_kind", "result_evidence", "result_ids",
      ]) expect(columns).toContain(added);
      // 원문 · 발화 글을 담을 열이 없다: 새 열은 모두 id · 종류 · 숫자 · 시각이다
      const textual = (
        await q(
          `select column_name from information_schema.columns where table_schema = 'public' and table_name = 'inbox_events' and data_type = 'text' order by column_name`,
        )
      ).map((r) => r.column_name);
      expect(textual).toEqual(["claimed_by", "dedup_key", "last_error_kind", "result_evidence", "result_kind", "type"]);
    });

    it("A2가 허용하던 직접 적재는 그대로 된다 (type은 이름 모양만, refs {source_id})", async () => {
      const user = await f.user();
      const e = await f.event(user, "timer", "same-key");
      expect(e).toBeTruthy();
      await rejects(q(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'Reply Observed', 'k2')`, [user]), /inbox_events_type_check/);
    });

    it("refs · result_ids는 id · 종류 · 숫자만 담는다: 문장 · 한글 · 대문자 · 중첩 객체 · 너무 긴 배열은 거절 (원문이 새지 않는다)", async () => {
      const user = await f.user();
      const bad: Record<string, unknown>[] = [
        { note: "회의에서 김대리가 금요일까지 보내겠다고 말함" },
        { note: "Hello World" },
        { quote: "금요일까지" },
        { nested: { a: randomUUID() } },
        { action_ids: Array.from({ length: 101 }, () => randomUUID()) },
        { action_ids: ["not-a-uuid"] },
        { flag: true },
        { "Bad Key": randomUUID() },
      ];
      for (const [i, refs] of bad.entries()) {
        await rejects(
          q(`insert into public.inbox_events (user_id, type, dedup_key, refs) values ($1, 'user_message', $2, $3)`, [user, `bad-${i}`, JSON.stringify(refs)]),
          /inbox_events_refs_ids_only/,
        );
      }
      await q(`insert into public.inbox_events (user_id, type, dedup_key, refs) values ($1, 'memory_changed', 'ok', $2)`, [
        user,
        JSON.stringify({ context_id: randomUUID(), context_version: 4, kind: "scope_bump", action_ids: [randomUUID(), randomUUID()] }),
      ]);
    });

    it("처리 결과 일관성: processed_at이면 result_kind가 있고, 아니면 없다. 죽은 사건은 처리된 사건이 아니다. 알 수 없는 result_kind는 거절", async () => {
      const user = await f.user();
      const e = await f.event(user, "user_message", "r1");
      await rejects(q(`update public.inbox_events set processed_at = now() where id = $1`, [e]), /inbox_events_result_consistency/);
      await rejects(q(`update public.inbox_events set result_kind = 'no_impact' where id = $1`, [e]), /inbox_events_result_consistency/);
      await rejects(q(`update public.inbox_events set processed_at = now(), result_kind = 'success' where id = $1`, [e]), /inbox_events_result_kind_check/);
      for (const kind of RESULT_KINDS) {
        const x = await f.event(user, "user_message", `kind-${kind}`);
        await q(`update public.inbox_events set processed_at = now(), result_kind = $2 where id = $1`, [x, kind]);
      }
      const y = await f.event(user, "user_message", "dead-and-processed");
      await rejects(q(`update public.inbox_events set dead_at = now(), processed_at = now(), result_kind = 'no_impact' where id = $1`, [y]), /inbox_events_dead_not_processed/);
    });

    it("사건은 사실이라 바뀌지 않는다: type · dedup_key · refs · user_id · created_at 수정 거절, 처리 표시를 되돌릴 수 없다", async () => {
      const user = await f.user();
      const e = await f.event(user, "user_message", "imm", { message_id: randomUUID() });
      await rejects(q(`update public.inbox_events set type = 'timer_due' where id = $1`, [e]), /immutable/);
      await rejects(q(`update public.inbox_events set dedup_key = 'other' where id = $1`, [e]), /immutable/);
      await rejects(q(`update public.inbox_events set refs = '{}' where id = $1`, [e]), /immutable/);
      await rejects(q(`update public.inbox_events set created_at = now() - interval '1 day' where id = $1`, [e]), /immutable/);
      await q(`update public.inbox_events set processed_at = now(), result_kind = 'no_impact' where id = $1`, [e]);
      await rejects(q(`update public.inbox_events set processed_at = null, result_kind = null where id = $1`, [e]), /processed/);
    });

    it("사건 종류 목록(coordinator_event_types)은 아키텍처 7.1의 입구와 같다", async () => {
      const row = await f.one(`select public.coordinator_event_types() as types`);
      expect([...(row.types as string[])].sort()).toEqual([...EVENT_TYPES].sort());
    });

    it("앱은 자기 사건을 읽기만 한다: 남의 사건은 안 보이고, 쓰기 · RPC 호출은 모두 거절 (서버 전용)", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      await f.event(alice, "user_message", "a");
      await f.event(bob, "user_message", "b");
      expect((await db().asUser(alice, () => q(`select user_id from public.inbox_events`))).map((r) => r.user_id)).toEqual([alice]);
      await db().asUser(alice, async () => {
        await rejects(q(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'user_message', 'x')`, [alice]), /permission denied/);
        await rejects(q(`update public.inbox_events set attempts = 9`), /permission denied/);
        await rejects(q(`delete from public.inbox_events`), /permission denied/);
        await rejects(q(`select public.coordinator_enqueue($1, 'user_message', 'z', '{}')`, [alice]), /permission denied/);
        await rejects(q(`select * from public.coordinator_claim('x', 60, 1, 3)`), /permission denied/);
        await rejects(q(`select public.coordinator_finish($1, $2, 'no_impact', '{}', null)`, [randomUUID(), randomUUID()]), /permission denied/);
        await rejects(q(`select public.coordinator_enqueue_due_timers(86400, 10)`), /permission denied/);
        await rejects(q(`select * from public.coordinator_pending_inputs($1)`, [alice]), /permission denied/);
      });
    });

    it("새 함수는 모두 search_path = '' 이고 service_role만 실행한다 (public · anon · authenticated 실행 권한 없음, 트리거 함수는 아무도 못 부름)", async () => {
      const rpcs = [
        "coordinator_enqueue(uuid,text,text,jsonb)",
        "coordinator_claim(text,integer,integer,integer)",
        "coordinator_finish(uuid,uuid,text,jsonb,text)",
        "coordinator_fail(uuid,uuid,text,integer)",
        "coordinator_reserve_model_call(uuid,uuid)",
        "coordinator_reserve_jev_calls(uuid,uuid,integer,integer)",
        "coordinator_enqueue_due_timers(integer,integer)",
        "coordinator_recover_missing(integer,integer)",
        "coordinator_pending_inputs(uuid)",
        "coordinator_event_types()",
      ];
      for (const fn of rpcs) {
        const row = await f.one(
          `select has_function_privilege('anon', $1, 'execute') as anon, has_function_privilege('authenticated', $1, 'execute') as authenticated,
                  has_function_privilege('service_role', $1, 'execute') as service_role`,
          [`public.${fn}`],
        );
        expect({ fn, ...row }).toEqual({ fn, anon: false, authenticated: false, service_role: true });
      }
      const triggers = (
        await q(
          `select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'coordinator\\_on\\_%' order by p.proname`,
        )
      ).map((r) => r.proname as string);
      expect(triggers.length).toBeGreaterThanOrEqual(6);
      for (const fn of triggers) {
        const row = await f.one(
          `select has_function_privilege('anon', p.oid, 'execute') as anon, has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
                  has_function_privilege('service_role', p.oid, 'execute') as service_role, p.prosecdef as definer
             from pg_proc p where p.proname = $1`,
          [fn],
        );
        expect({ fn, ...row }).toEqual({ fn, anon: false, authenticated: false, service_role: false, definer: true });
      }
      const all = await q(
        `select p.proname, p.proconfig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and (p.proname like 'coordinator\\_%' or p.proname = 'inbox_refs_valid' or p.proname = 'inbox_events_guard')`,
      );
      expect(all.length).toBeGreaterThanOrEqual(rpcs.length + 6);
      for (const row of all) expect({ fn: row.proname, config: row.proconfig }).toEqual({ fn: row.proname, config: expect.arrayContaining(["search_path=\"\""]) });
    });
  });

  // ───────────────────────── 2) 적재 ─────────────────────────
  describe("적재 (coordinator_enqueue): dedup_key 멱등", () => {
    it("같은 dedup_key는 한 번만 쌓이고(두 번째는 created false, 같은 id), 다른 사용자는 같은 키를 쓸 수 있다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const first = await f.one(`select * from public.coordinator_enqueue($1, 'user_message', 'k', $2)`, [alice, JSON.stringify({ message_id: randomUUID() })]);
      const again = await f.one(`select * from public.coordinator_enqueue($1, 'user_message', 'k', $2)`, [alice, JSON.stringify({ message_id: randomUUID() })]);
      const other = await f.one(`select * from public.coordinator_enqueue($1, 'user_message', 'k', '{}')`, [bob]);
      expect(first.created).toBe(true);
      expect(again).toEqual({ event_id: first.event_id, created: false });
      expect(other.created).toBe(true);
      expect(await f.count(`select 1 from public.inbox_events where dedup_key = 'k'`)).toBe(2);
      // 먼저 쌓인 사건의 refs를 나중 호출이 덮지 않는다
      expect((await f.one(`select refs from public.inbox_events where id = $1`, [first.event_id])).refs).toHaveProperty("message_id");
    });

    it("모르는 종류 · 글이 든 refs · 없는 사용자는 쌓지 않고 거절한다", async () => {
      const user = await f.user();
      await rejects(q(`select public.coordinator_enqueue($1, 'timer', 'x', '{}')`, [user]), /알 수 없는 사건 종류/);
      await rejects(q(`select public.coordinator_enqueue($1, 'user_message', 'x', $2)`, [user, JSON.stringify({ note: "회의에서 말한 문장" })]), /inbox_events_refs_ids_only/);
      await rejects(q(`select public.coordinator_enqueue($1, 'user_message', 'x', '{}')`, [randomUUID()]), /foreign key|inbox_events_user_id_fkey/);
      expect(await f.count(`select 1 from public.inbox_events where user_id = $1`, [user])).toBe(0);
    });

    it("created_at은 DB 시각이다 (호출자가 정하지 않는다)", async () => {
      const user = await f.user();
      const { event_id } = await f.one(`select * from public.coordinator_enqueue($1, 'user_message', 'now', '{}')`, [user]);
      const row = await f.one(`select created_at <= now() and created_at > now() - interval '1 minute' as fresh from public.inbox_events where id = $1`, [event_id]);
      expect(row.fresh).toBe(true);
    });
  });

  // ───────────────────────── 3) 실제 연결된 생산자 (트리거) ─────────────────────────
  describe("[실제 연결] 원문 처리 완료 → source_processed / source_revised", () => {
    it("처리가 done이 되는 같은 트랜잭션에서 사건이 하나 쌓인다. refs는 원문 id와 종류뿐이다", async () => {
      const user = await f.user();
      const source = await f.source(user);
      await f.setStatus(source, "processing");
      expect(await f.events(user)).toEqual([]);
      await f.finishSource(source);
      const events = await f.events(user);
      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({ type: "source_processed", dedup_key: `source:${source}`, refs: { source_id: source, kind: "meeting" }, processed_at: null });
    });

    it("실패한 처리는 사건이 되지 않는다: failed · 예산 대기(pending) · 처리 중(processing)은 0건, 재시도해서 done이 되면 그때 1건 (거짓 성공 없음)", async () => {
      const user = await f.user();
      const source = await f.source(user);
      await f.setStatus(source, "processing");
      await f.setStatus(source, "failed");
      await f.setStatus(source, "pending");
      await f.setStatus(source, "processing");
      await f.setStatus(source, "failed");
      expect(await f.events(user)).toEqual([]);
      await f.finishSource(source);
      expect(await f.events(user)).toHaveLength(1);
    });

    it("같은 원문을 다시 처리해 done이 돼도 사건은 늘지 않는다 (재시도 · 응답 유실 · 재처리 스크립트): dedup_key = source:<id>", async () => {
      const user = await f.user();
      const source = await f.source(user);
      await f.finishSource(source);
      await f.finishSource(source);
      await f.q(`update public.sources set processing_status = 'done', processed_at = now() where id = $1`, [source]);
      expect(await f.count(`select 1 from public.inbox_events where user_id = $1`, [user])).toBe(1);
    });

    it("INSERT로 바로 done인 원문(실행 receipt · 대화 채택 note)은 원문 처리 성공이 아니라 사건이 아니다", async () => {
      const user = await f.user();
      await q(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, external_id, processing_status, processed_at) values ($1, 'execution', 'receipt', now(), $2, 'done', now())`,
        [user, randomUUID()],
      );
      await q(`insert into public.sources (user_id, kind, raw_text, occurred_at, processing_status, processed_at) values ($1, 'note', '채택한 발화 한 줄', now(), 'done', now())`, [user]);
      expect(await f.events(user)).toEqual([]);
    });

    it("같은 문서의 새 revision이 처리되면 source_revised, 처음 문서는 source_processed", async () => {
      const user = await f.user();
      const connection = await f.connection(user);
      const v1 = await f.source(user, { kind: "doc", externalId: "page-1", version: "2026-10-01", connection });
      await f.finishSource(v1);
      const v2 = await f.source(user, { kind: "doc", externalId: "page-1", version: "2026-10-02", connection });
      await f.finishSource(v2);
      const other = await f.source(user, { kind: "doc", externalId: "page-2", version: "2026-10-02", connection });
      await f.finishSource(other);
      expect((await f.events(user)).map((e) => [e.type, (e.refs as { source_id: string }).source_id])).toEqual([
        ["source_processed", v1],
        ["source_revised", v2],
        ["source_processed", other],
      ]);
    });
  });

  describe("[실제 연결] 대화 v2 사용자 메시지 → user_message", () => {
    it("사용자 메시지가 저장되면 1건 (refs는 대화 · 메시지 id뿐, 글 없음). 답(assistant)은 사건이 아니다", async () => {
      const user = await f.user();
      const conversation = await f.conversation(user);
      const message = await f.message(user, conversation, "user", 1);
      await f.message(user, conversation, "assistant", 2);
      const events = await f.events(user);
      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({ type: "user_message", dedup_key: `message:${message}`, refs: { conversation_id: conversation, message_id: message } });
      expect(JSON.stringify(events[0].refs)).not.toContain("안녕");
    });
  });

  describe("[실제 연결] 실제 사용자 결정 → decision_made", () => {
    it("사용자가 한 Action 결정(확인 · 삭제 · 수정 · 완료 · 다시 열기)만 사건이다. AI가 쓴 이벤트 · 읽음(user_seen) · 착수 · 메모는 사건이 아니다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const ev = (type: string, actor: string) =>
        q(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, $3, $4)`, [user, action, type, actor]);
      for (const type of ["user_confirmed", "user_deleted", "user_edited"]) await ev(type, "user");
      await ev("completed", "user");
      await ev("dropped", "user");
      await ev("reopened", "user");
      await ev("completed", "ai");
      await ev("created", "ai");
      await ev("user_seen", "user");
      await ev("user_started", "user");
      await ev("user_notes_updated", "user");
      const events = await f.events(user);
      expect(events.map((e) => (e.refs as { kind: string }).kind).sort()).toEqual(["completed", "dropped", "reopened", "user_confirmed", "user_deleted", "user_edited"]);
      expect(new Set(events.map((e) => e.type))).toEqual(new Set(["decision_made"]));
      for (const e of events) expect((e.refs as { action_id: string }).action_id).toBe(action);
    });

    it("승인 · 승인 철회 · 멈춤 (실행). 읽기(조회)는 쓰기가 아니라 사건이 없다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const run = await f.run(user, action);
      const step = (await f.one(`select id from public.execution_steps where run_id = $1 and seq = 1`, [run])).id as string;
      const approval = await f.id(`insert into public.execution_approvals (user_id, step_id, hash, expires_at) values ($1, $2, 'h', now() + interval '1 hour') returning id`, [user, step]);
      await q(`update public.execution_approvals set revoked_at = now() where id = $1`, [approval]);
      await q(`select public.stop_run($1, $2)`, [user, run]);
      const events = await f.events(user);
      expect(events.map((e) => (e.refs as { kind: string }).kind)).toEqual(["approval", "approval_revoked", "stop"]);
      for (const e of events) expect(e.refs).toMatchObject({ run_id: run });
      expect(events.map((e) => e.dedup_key)).toEqual([`approval:${approval}`, `approval_revoked:${approval}`, `run_stop:${run}`]);
    });
  });

  describe("[실제 연결] 범위 version 변화(기억 · 멤버십 · 멤버 revision) → memory_changed", () => {
    it("범위 context_version이 오를 때마다 사건 1건 (같은 version은 한 번), 오르지 않는 갱신은 사건이 아니다", async () => {
      const user = await f.user();
      const context = await f.context(user);
      await q(`update public.work_contexts set name = '새 이름' where id = $1`, [context]);
      expect(await f.events(user)).toEqual([]);
      await q(`select public.bump_context_versions(array[$1::uuid])`, [context]);
      await q(`select public.bump_context_versions(array[$1::uuid])`, [context]);
      expect((await f.events(user)).map((e) => e.refs)).toEqual([
        { context_id: context, context_version: 2 },
        { context_id: context, context_version: 3 },
      ]);
    });
  });

  describe("[실제 연결] B3 기억 쓰기 · S3b 멤버십 쓰기가 올리는 범위 version → memory_changed (그 쓰기 경로 자체는 바뀌지 않았다)", () => {
    it("사용자 멤버 넣기(S3b) · 범위 기억 쓰기(B3)는 B1 트리거가 범위 version을 올리고, 코디네이터 트리거가 그 version마다 사건 한 건을 쌓는다. inferred 후보는 version을 올리지 않으니 사건도 없다", async () => {
      const user = await f.user();
      const context = await f.context(user);
      const action = await f.action(user);
      const memberCount = () => f.count(`select 1 from public.inbox_events where user_id = $1 and type = 'memory_changed'`, [user]);
      expect(await memberCount()).toBe(0);
      await q(`insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user')`, [user, context, action]);
      expect(await memberCount()).toBe(1);
      await q(
        `insert into public.memory_items (user_id, kind, scope_kind, context_id, statement, origin, source_ref) values ($1, 'fact', 'context', $2, '출시는 목요일', 'explicit', $3)`,
        [user, context, JSON.stringify({ message_id: randomUUID() })],
      );
      expect(await memberCount()).toBe(2);
      await q(
        `insert into public.memory_items (user_id, kind, scope_kind, context_id, statement, origin, confidence, source_ref) values ($1, 'fact', 'context', $2, '금요일일 수도', 'inferred', 0.5, $3)`,
        [user, context, JSON.stringify({ message_id: randomUUID() })],
      );
      expect(await memberCount()).toBe(2);
      expect((await f.events(user)).map((e) => e.refs)).toEqual([
        { context_id: context, context_version: 2 },
        { context_id: context, context_version: 3 },
      ]);
    });
  });

  describe("생산자는 성공 쓰기를 깨지 않는다 (적재 실패 격리) + 회수", () => {
    it("적재가 실패해도(여기서는 제약으로 강제) 원문 done · 메시지 저장 · 사용자 결정은 그대로 성공하고, 사건만 없다", async () => {
      const user = await f.user();
      const source = await f.source(user);
      const action = await f.action(user);
      const conversation = await f.conversation(user);
      await q(`alter table public.inbox_events add constraint force_fail check (false) not valid`);
      try {
        await f.finishSource(source);
        const message = await f.message(user, conversation, "user", 1);
        await q(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_confirmed', 'user')`, [user, action]);
        expect((await f.one(`select processing_status from public.sources where id = $1`, [source])).processing_status).toBe("done");
        expect(message).toBeTruthy();
        expect(await f.count(`select 1 from public.conversation_messages where user_id = $1`, [user])).toBe(1);
        expect(await f.count(`select 1 from public.action_events where user_id = $1`, [user])).toBe(1);
        expect(await f.events(user)).toEqual([]);
      } finally {
        await q(`alter table public.inbox_events drop constraint force_fail`);
      }
      // 회수: 빠진 사건만 다시 쌓고(원문 done · 사용자 메시지 · 사용자 결정), 다시 돌려도 늘지 않는다
      const first = await f.one(`select public.coordinator_recover_missing(7200, 100) as n`);
      expect(Number(first.n)).toBe(3);
      expect((await f.events(user)).map((e) => e.type).sort()).toEqual(["decision_made", "source_processed", "user_message"]);
      expect(Number((await f.one(`select public.coordinator_recover_missing(7200, 100) as n`)).n)).toBe(0);
      expect(await f.count(`select 1 from public.inbox_events where user_id = $1`, [user])).toBe(3);
    });

    it("회수는 실패한 원문 · 기간 밖 · assistant 답 · 읽음 이벤트 · 처리 요약 없는 done(note)을 만들지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const conversation = await f.conversation(user);
      await q(`alter table public.inbox_events add constraint force_fail check (false) not valid`);
      try {
        const failed = await f.source(user);
        await f.setStatus(failed, "processing");
        await f.setStatus(failed, "failed");
        const old = await f.source(user);
        await q(`update public.sources set processing_status = 'done', processed_at = now() - interval '3 hours', processing_summary = '{"attempt":1}' where id = $1`, [old]);
        await q(`insert into public.sources (user_id, kind, raw_text, occurred_at, processing_status, processed_at) values ($1, 'note', '채택한 발화 한 줄', now(), 'done', now())`, [user]);
        await f.message(user, conversation, "assistant", 1);
        await q(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_seen', 'user')`, [user, action]);
      } finally {
        await q(`alter table public.inbox_events drop constraint force_fail`);
      }
      expect(Number((await f.one(`select public.coordinator_recover_missing(7200, 100) as n`)).n)).toBe(0);
      expect(await f.events(user)).toEqual([]);
    });

    it("계정 삭제는 생산자 트리거에 막히지 않고 사건도 함께 지워진다", async () => {
      const user = await f.user();
      const context = await f.context(user);
      const source = await f.source(user);
      await f.finishSource(source);
      await q(`select public.bump_context_versions(array[$1::uuid])`, [context]);
      await f.message(user, await f.conversation(user), "user", 1);
      expect(await f.count(`select 1 from public.inbox_events where user_id = $1`, [user])).toBe(3);
      await q(`delete from auth.users where id = $1`, [user]);
      expect(await f.count(`select 1 from public.inbox_events where user_id = $1`, [user])).toBe(0);
    });
  });

  // ───────────────────────── 4) 집기 · 직렬화 · lease ─────────────────────────
  describe("집기 (coordinator_claim): 사용자별 순서 · lease · 시도", () => {
    // 집기는 모든 사용자를 훑는다: 앞 시나리오가 남긴 사건을 비워 이 시나리오의 사용자만 남긴다
    beforeEach(async () => {
      await q(`delete from public.inbox_events`);
    });

    it("사용자마다 머리 사건 하나만 집는다: 같은 사용자의 뒤 사건은 앞 사건이 끝나야 집힌다 (사용자별 순서 보존)", async () => {
      const user = await f.user();
      const [e1, e2, e3] = [await f.event(user, "user_message", "a"), await f.event(user, "user_message", "b"), await f.event(user, "user_message", "c")];
      const first = await f.claim();
      expect(first.map((r) => r.event_id)).toEqual([e1]);
      expect(first[0]).toMatchObject({ user_id: user, type: "user_message", attempts: 1, model_calls: 0, jev_calls: 0 });
      // lease가 살아 있는 동안 같은 사용자의 다른 소비자는 아무것도 못 집는다
      expect(await f.claim("fn-2")).toEqual([]);
      expect(await f.finish(e1, first[0].claim_token as string)).toBe("finished");
      const second = await f.claim("fn-2");
      expect(second.map((r) => r.event_id)).toEqual([e2]);
      await f.finish(e2, second[0].claim_token as string);
      expect((await f.claim()).map((r) => r.event_id)).toEqual([e3]);
    });

    it("같은 시각(created_at)에 쌓인 사건도 쌓인 순서(seq)로 집힌다 — 같은 시각 tie-break", async () => {
      const user = await f.user();
      const at = "2026-10-12T00:00:00Z";
      const ids: string[] = [];
      for (const key of ["z-first", "a-second", "m-third"]) ids.push(await f.event(user, "user_message", key, {}, at));
      const order: string[] = [];
      for (let i = 0; i < 3; i++) {
        const [row] = await f.claim("fn-1");
        order.push(row.event_id as string);
        expect(await f.finish(row.event_id as string, row.claim_token as string)).toBe("finished");
      }
      expect(order).toEqual(ids);
    });

    it("먼저 쌓인 사건이 먼저다: created_at이 이른 사건이 나중에 쌓여도(seq가 커도) 먼저 집힌다", async () => {
      const user = await f.user();
      const late = await f.event(user, "user_message", "late", {}, "2026-10-12T00:10:00Z");
      const early = await f.event(user, "user_message", "early", {}, "2026-10-12T00:00:00Z");
      expect((await f.claim()).map((r) => r.event_id)).toEqual([early]);
      expect(late).not.toBe(early);
    });

    it("다른 사용자는 서로 막지 않는다: A의 머리가 lease 중이어도 B의 머리는 집힌다, 오래 기다린 머리부터, 한 번에 limit개까지", async () => {
      const users = [await f.user(), await f.user(), await f.user()];
      const heads: string[] = [];
      for (const [i, user] of users.entries()) heads.push(await f.event(user, "user_message", "h", {}, `2026-10-12T00:0${i}:00Z`));
      for (const user of users) await f.event(user, "user_message", "tail", {}, "2026-10-12T01:00:00Z");
      const got = await f.claim("fn-1", 60, 2);
      expect(got.map((r) => r.event_id)).toEqual([heads[0], heads[1]]);
      const rest = await f.claim("fn-2", 60, 5);
      expect(rest.map((r) => r.event_id)).toEqual([heads[2]]);
      expect(await f.claim("fn-3")).toEqual([]);
    });

    it("lease가 끝난 사건은 다시 집힌다(시도 +1, 새 claim_token). 처리 안 된 채 그대로", async () => {
      const user = await f.user();
      const e = await f.event(user, "user_message", "a");
      const [first] = await f.claim("fn-1");
      await f.expire(e);
      const [second] = await f.claim("fn-2");
      expect(second.event_id).toBe(e);
      expect(second.attempts).toBe(2);
      expect(second.claim_token).not.toBe(first.claim_token);
      expect((await f.one(`select claimed_by, processed_at from public.inbox_events where id = $1`, [e]))).toEqual({ claimed_by: "fn-2", processed_at: null });
    });

    it("늦은(만료된) 소비자의 commit은 거절된다: 새 소비자가 집었으면 토큰 불일치, 아무도 안 집었어도 만료 뒤 commit은 거절. 처리는 한 번만 기록", async () => {
      const user = await f.user();
      const e = await f.event(user, "user_message", "a");
      const [old] = await f.claim("fn-1");
      await f.expire(e);
      // 아직 아무도 다시 집지 않았지만 lease가 끝났다
      expect(await f.finish(e, old.claim_token as string)).toBe("lost_claim");
      const [fresh] = await f.claim("fn-2");
      expect(await f.finish(e, old.claim_token as string)).toBe("lost_claim");
      expect(await f.finish(e, fresh.claim_token as string, "impact_recorded", { action_ids: [randomUUID()] }, "deterministic_only")).toBe("finished");
      // 응답을 잃어 같은 commit을 다시 보내도 같은 결과(멱등), 처리 기록은 하나
      expect(await f.finish(e, fresh.claim_token as string, "impact_recorded", {}, null)).toBe("already_finished");
      expect(await f.finish(e, old.claim_token as string)).toBe("lost_claim");
      const row = await f.one(`select result_kind, result_evidence, processed_at is not null as processed from public.inbox_events where id = $1`, [e]);
      expect(row).toEqual({ result_kind: "impact_recorded", result_evidence: "deterministic_only", processed: true });
    });

    it("처리 결과는 정해진 종류 · id만 받는다. 거절돼도 사건은 그대로 처리 전이다 (processed_at을 성공보다 먼저 쓰지 않는다)", async () => {
      const user = await f.user();
      const e = await f.event(user, "user_message", "a");
      const [row] = await f.claim();
      await rejects(f.finish(e, row.claim_token as string, "success"), /inbox_events_result_kind_check/);
      await rejects(q(`select public.coordinator_finish($1, $2, 'no_impact', $3, null)`, [e, row.claim_token, JSON.stringify({ note: "한글 문장" })]), /inbox_events_result_ids_ids_only/);
      await rejects(q(`select public.coordinator_finish($1, $2, 'no_impact', '{}', 'Bad Evidence')`, [e, row.claim_token]), /inbox_events_result_evidence_check/);
      expect((await f.one(`select processed_at, result_kind from public.inbox_events where id = $1`, [e]))).toEqual({ processed_at: null, result_kind: null });
      expect(await f.finish(e, row.claim_token as string)).toBe("finished");
    });

    it("시도를 다 쓴 사건은 죽은 사건(dead_at)이 된다: 처리된 것이 아니고, 그 사용자의 다음 사건을 막지 않는다", async () => {
      const user = await f.user();
      const [poison, next] = [await f.event(user, "user_message", "poison"), await f.event(user, "user_message", "next")];
      for (let attempt = 1; attempt <= 3; attempt++) {
        const [row] = await f.claim("fn-1", 60, 10, 3);
        expect(row.event_id).toBe(poison);
        expect(row.attempts).toBe(attempt);
        await f.expire(poison);
      }
      const after = await f.claim("fn-1", 60, 10, 3);
      expect(after.map((r) => r.event_id)).toEqual([next]);
      expect(await f.one(`select dead_at is not null as dead, processed_at, result_kind, attempts from public.inbox_events where id = $1`, [poison])).toEqual({
        dead: true, processed_at: null, result_kind: null, attempts: 3,
      });
    });

    it("실패 기록(coordinator_fail): 까닭 종류만 남기고 재시도를 늦춘다. 끝난 것으로 보지 않는다. 다른 사용자는 계속 진행", async () => {
      const [a, b] = [await f.user(), await f.user()];
      const ea = await f.event(a, "user_message", "a", {}, "2026-10-12T00:00:00Z");
      const eb = await f.event(b, "user_message", "b", {}, "2026-10-12T00:00:01Z");
      const [row] = await f.claim("fn-1", 60, 1);
      expect(row.event_id).toBe(ea);
      const status = (await f.one(`select public.coordinator_fail($1, $2, 'store_error', 30) as ok`, [ea, row.claim_token])).ok;
      expect(status).toBe(true);
      const state = await f.one(
        `select last_error_kind, processed_at, claim_expires_at <= now() + interval '31 seconds' as soon, claim_expires_at > now() + interval '20 seconds' as delayed from public.inbox_events where id = $1`,
        [ea],
      );
      expect(state).toEqual({ last_error_kind: "store_error", processed_at: null, soon: true, delayed: true });
      // 재시도 지연 동안 A는 다시 집히지 않고 B가 진행된다
      expect((await f.claim("fn-2")).map((r) => r.event_id)).toEqual([eb]);
      // 만료된 토큰으로는 기록하지 못한다
      await f.expire(ea);
      expect((await f.one(`select public.coordinator_fail($1, $2, 'late', 30) as ok`, [ea, row.claim_token])).ok).toBe(false);
    });

    it("사용자(계정)가 삭제되면 집은 사건의 commit은 거절되고 사건도 사라진다 (삭제 · 권한 상실)", async () => {
      const user = await f.user();
      const e = await f.event(user, "user_message", "a");
      const [row] = await f.claim();
      await q(`delete from auth.users where id = $1`, [user]);
      expect(await f.finish(e, row.claim_token as string)).toBe("lost_claim");
      expect(await f.count(`select 1 from public.inbox_events where id = $1`, [e])).toBe(0);
    });

    it("limit · lease · 시도 상한 값이 범위를 벗어나면 거절", async () => {
      await rejects(q(`select * from public.coordinator_claim('x', 0, 1, 3)`), /범위/);
      await rejects(q(`select * from public.coordinator_claim('x', 601, 1, 3)`), /범위/);
      await rejects(q(`select * from public.coordinator_claim('x', 60, 0, 3)`), /범위/);
      await rejects(q(`select * from public.coordinator_claim('x', 60, 101, 3)`), /범위/);
      await rejects(q(`select * from public.coordinator_claim('x', 60, 1, 0)`), /범위/);
      await rejects(q(`select * from public.coordinator_claim('', 60, 1, 3)`), /범위/);
    });
  });

  describe("서버 권한(service_role)으로 부른다: 실제 배포 역할의 권한만으로 RPC · 읽기 함수가 돈다", () => {
    it("service_role로 전환해 적재 → 집기 → 예산 예약 → 끝내기 → timer → 회수 → 결정 대기 읽기를 모두 부른다 (함수 · 표 권한 누락이 없다). 앱 역할(authenticated)로는 부르지 못한다", async () => {
      const user = await f.user();
      const action = await f.action(user, { dueAt: new Date(Date.now() + 3_600_000).toISOString() });
      await q(`delete from public.inbox_events`);
      await q(`set role service_role`);
      try {
        const { event_id } = await f.one(`select * from public.coordinator_enqueue($1, 'source_revised', 'svc-1', $2)`, [user, JSON.stringify({ source_id: randomUUID() })]);
        const [claimed] = await f.claim("svc", 60, 5, 3);
        expect(claimed.event_id).toBe(event_id);
        expect((await f.one(`select public.coordinator_reserve_model_call($1, $2) as ok`, [event_id, claimed.claim_token])).ok).toBe(true);
        expect((await f.one(`select public.coordinator_reserve_jev_calls($1, $2, 2, 8) as ok`, [event_id, claimed.claim_token])).ok).toBe(true);
        expect((await f.one(`select public.coordinator_fail($1, $2, 'store_error', 0) as ok`, [event_id, claimed.claim_token])).ok).toBe(true);
        await f.expire(event_id);
        const [again] = await f.claim("svc", 60, 5, 3);
        expect(await f.finish(event_id, again.claim_token as string, "impact_recorded", { action_ids: [action] }, "deterministic_only")).toBe("finished");
        expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 10) as n`)).n)).toBe(1);
        expect(Number((await f.one(`select public.coordinator_recover_missing(7200, 10) as n`)).n)).toBeGreaterThanOrEqual(0);
        expect(await q(`select * from public.coordinator_pending_inputs($1)`, [user])).toEqual([]);
        expect((await f.one(`select public.coordinator_event_types() is not null as ok`)).ok).toBe(true);
        // 사건 큐의 열 · 결과 일관성 CHECK도 서버 권한으로 평가된다 (CHECK가 부르는 함수의 실행 권한)
        expect((await f.one(`select result_kind, result_ids from public.inbox_events where id = $1`, [event_id]))).toEqual({ result_kind: "impact_recorded", result_ids: { action_ids: [action] } });
      } finally {
        await q(`reset role`);
      }
    });

    it("기한(due_at)에 소수 초가 있어도 timer 키는 초를 내림한 값이고 TS 규칙(timerDedupKey = floor)과 같다", async () => {
      const user = await f.user();
      const due = new Date(Math.floor(Date.now() / 1000) * 1000 + 3_600_000 + 900);
      const action = await f.action(user, { dueAt: due.toISOString() });
      await q(`delete from public.inbox_events where user_id = $1`, [user]);
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 1000) as n`)).n)).toBeGreaterThanOrEqual(1);
      const keys = (await f.events(user)).map((e) => e.dedup_key);
      expect(keys).toEqual([`timer:due_window:${action}:${Math.floor(due.getTime() / 1000)}`]);
    });
  });

  // ───────────────────────── 5) 모델 호출 예산 ─────────────────────────
  describe("모델 호출 예산 (호출 전에 DB에 먼저 잡는다)", () => {
    beforeEach(async () => {
      await q(`delete from public.inbox_events`);
    });

    it("관리(생성) 모델은 사건당 최대 1회: 첫 예약만 true, 이후 · 재시도 · 다시 집은 뒤에도 false (다시 부르지 않는다)", async () => {
      const user = await f.user();
      const e = await f.event(user, "source_revised", "a");
      const [row] = await f.claim();
      const reserve = (token: unknown) => f.one(`select public.coordinator_reserve_model_call($1, $2) as ok`, [e, token]);
      expect((await reserve(row.claim_token)).ok).toBe(true);
      expect((await reserve(row.claim_token)).ok).toBe(false);
      // 프로세스가 죽었다 가정: lease 만료 → 새 소비자가 집어도 예약은 남아 있다
      await f.expire(e);
      const [again] = await f.claim("fn-2");
      expect(again.model_calls).toBe(1);
      expect((await reserve(again.claim_token)).ok).toBe(false);
      expect((await f.one(`select model_calls, model_call_reserved_at is not null as reserved from public.inbox_events where id = $1`, [e]))).toEqual({ model_calls: 1, reserved: true });
    });

    it("lease를 잃은 소비자(옛 토큰 · 만료)는 예약하지 못한다 — 호출 권리가 없다", async () => {
      const user = await f.user();
      const e = await f.event(user, "source_revised", "a");
      const [old] = await f.claim("fn-1");
      await f.expire(e);
      expect((await f.one(`select public.coordinator_reserve_model_call($1, $2) as ok`, [e, old.claim_token])).ok).toBe(false);
      const [fresh] = await f.claim("fn-2");
      expect((await f.one(`select public.coordinator_reserve_model_call($1, $2) as ok`, [e, old.claim_token])).ok).toBe(false);
      expect((await f.one(`select public.coordinator_reserve_model_call($1, $2) as ok`, [e, fresh.claim_token])).ok).toBe(true);
      expect((await f.one(`select model_calls from public.inbox_events where id = $1`, [e])).model_calls).toBe(1);
    });

    it("Jev 호출은 따로 세고 상한을 넘기면 한 번도 늘리지 않는다 (예약은 전부 또는 0)", async () => {
      const user = await f.user();
      const e = await f.event(user, "source_revised", "a");
      const [row] = await f.claim();
      const reserve = (n: number, cap: number) => f.one(`select public.coordinator_reserve_jev_calls($1, $2, $3, $4) as ok`, [e, row.claim_token, n, cap]);
      expect((await reserve(3, 5)).ok).toBe(true);
      expect((await reserve(3, 5)).ok).toBe(false);
      expect((await reserve(2, 5)).ok).toBe(true);
      expect((await reserve(1, 5)).ok).toBe(false);
      expect((await f.one(`select jev_calls, model_calls from public.inbox_events where id = $1`, [e]))).toEqual({ jev_calls: 5, model_calls: 0 });
      await rejects(reserve(0, 5), /범위/);
      await rejects(reserve(1, 0), /범위/);
    });
  });

  // ───────────────────────── 6) timer ─────────────────────────
  describe("[실제 연결] 기한 창 timer (coordinator_enqueue_due_timers)", () => {
    // timer는 모든 사용자의 열린 Action을 훑는다: 앞 시나리오의 Action · 사건을 비운다
    beforeEach(async () => {
      await q(`delete from public.inbox_events`);
      await q(`delete from public.actions`);
    });

    it("열린 Action 중 기한이 지금~창(24시간) 안인 것만 한 번 쌓는다: 창 밖 · 지난 기한 · 기한 없음 · 닫힌 Action은 제외, 다시 돌려도 늘지 않는다", async () => {
      const user = await f.user();
      const soon = await f.action(user, { dueAt: new Date(Date.now() + 3 * 3_600_000).toISOString() });
      await f.action(user, { dueAt: new Date(Date.now() + 3 * 86_400_000).toISOString() });
      await f.action(user, { dueAt: new Date(Date.now() - 3_600_000).toISOString() });
      await f.action(user, { dueAt: null });
      await f.action(user, { dueAt: new Date(Date.now() + 3_600_000).toISOString(), status: "done" });
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 100) as n`)).n)).toBe(1);
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 100) as n`)).n)).toBe(0);
      const events = await f.events(user);
      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({ type: "timer_due", refs: { action_id: soon, kind: "due_window" } });
    });

    it("기한을 바꾸면(Claim으로 due_at이 달라지면) 새 사건이고, 한 번에 limit개까지만 새로 쌓는다 (이미 쌓인 것이 자리를 막지 않는다)", async () => {
      const user = await f.user();
      const soon = new Date(Date.now() + 2 * 3_600_000);
      const actions: string[] = [];
      for (let i = 0; i < 5; i++) actions.push(await f.action(user, { dueAt: new Date(soon.getTime() + i * 60_000).toISOString() }));
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 2) as n`)).n)).toBe(2);
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 2) as n`)).n)).toBe(2);
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 2) as n`)).n)).toBe(1);
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 2) as n`)).n)).toBe(0);
      await q(`update public.actions set due_at = due_at + interval '1 hour' where id = $1`, [actions[0]]);
      expect(Number((await f.one(`select public.coordinator_enqueue_due_timers(86400, 2) as n`)).n)).toBe(1);
      await rejects(q(`select public.coordinator_enqueue_due_timers(0, 2)`), /범위/);
      await rejects(q(`select public.coordinator_enqueue_due_timers(86400, 0)`), /범위/);
    });
  });
}

// ───────────────────────── 업그레이드 · 롤백 ─────────────────────────
const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");
export const C2_MIGRATION = "20261110000000_coordinator_core.sql";

export type FreshDb = {
  exec: (sql: string) => Promise<unknown>;
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
};

/** Supabase 흉내 + C2 앞의 모든 마이그레이션 / C2 */
async function splitScripts() {
  const files = (await readdir(MIGRATIONS_DIR)).filter((file) => file.endsWith(".sql")).sort();
  const index = files.indexOf(C2_MIGRATION);
  expect(index, `${C2_MIGRATION}이 마이그레이션 목록에 있다`).toBeGreaterThan(0);
  const scripts = await supabaseSchemaScripts();
  return { before: scripts.slice(0, 2 + index), c2: scripts[2 + index], after: scripts.slice(3 + index) };
}

/**
 * 새 마이그레이션 전 상태(A2 inbox_events)에서 옛 행을 쌓고 전체를 적용한 뒤에도 옛 행이 그대로이고 새 열은 기본값인지, 옛 처리 전 행이 집히는지 본다.
 * 마지막 시나리오는 같은 이름의 객체가 이미 있으면 아무것도 바꾸지 않고 실패하는 것(한 트랜잭션 롤백)을 본다.
 */
export function coordinatorUpgradeTests(fresh: () => Promise<FreshDb>) {
  describe("업그레이드 회귀 (새 마이그레이션 전 상태 → 적용)", () => {
    it("옛 사건(처리 전 · 처리됨 · 모양이 다른 refs · 이름만 맞는 종류)이 그대로이고 새 열은 기본값이다. 새 행에는 새 제약이 적용된다. 옛 처리 전 사건은 집어 끝낼 수 있다", async () => {
      const { before, c2, after } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const alice = randomUUID();
      const bob = randomUUID();
      for (const u of [alice, bob]) await db.query(`insert into auth.users (id, email) values ($1, $2)`, [u, `${u}@example.com`]);
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'inbox_events' and column_name in ('seq', 'attempts', 'result_kind')`)).toEqual([]);

      const source = randomUUID();
      const legacy = [
        { user: alice, type: "source_processed", key: `source:${source}`, refs: { source_id: source }, processed: false },
        { user: alice, type: "timer", key: "tick-1", refs: {}, processed: true },
        // 이 표에 쓰던 코드는 없었지만 모양이 달라도(글이 든 refs) 적용이 실패하지 않아야 한다
        { user: alice, type: "user_message", key: "odd-refs", refs: { note: "옛 모양의 refs 입니다" }, processed: true },
        { user: bob, type: "source_processed", key: `source:${source}`, refs: { source_id: source }, processed: false },
      ];
      const ids: string[] = [];
      for (const [i, row] of legacy.entries()) {
        ids.push(
          (
            await db.query(
              `insert into public.inbox_events (user_id, type, dedup_key, refs, created_at, processed_at) values ($1, $2, $3, $4, $5, $6) returning id`,
              [row.user, row.type, row.key, JSON.stringify(row.refs), `2026-10-01T00:00:0${i}Z`, row.processed ? "2026-10-01T01:00:00Z" : null],
            )
          )[0].id as string,
        );
      }
      const snapshot = async () =>
        db.query(`select id, user_id, type, dedup_key, refs, created_at, processed_at from public.inbox_events order by created_at`);
      const legacyRows = await snapshot();

      await db.exec(c2);
      for (const sql of after) await db.exec(sql);

      expect(await snapshot()).toEqual(legacyRows);
      const added = await db.query(
        `select attempts, model_calls, jev_calls, claim_token, claim_expires_at, dead_at, last_error_kind, result_kind, result_evidence, result_ids, seq is not null as has_seq from public.inbox_events order by created_at`,
      );
      expect(added).toHaveLength(4);
      for (const row of added) expect(row).toMatchObject({ attempts: 0, model_calls: 0, jev_calls: 0, claim_token: null, claim_expires_at: null, dead_at: null, last_error_kind: null, result_kind: null, result_evidence: null, result_ids: {}, has_seq: true });
      // 쌓인 순서(seq)는 옛 행에도 하나씩 생겼고 서로 다르다
      expect(new Set((await db.query(`select seq from public.inbox_events`)).map((r) => String(r.seq))).size).toBe(4);

      // 새 행에는 새 제약이 적용된다
      await expect(db.query(`insert into public.inbox_events (user_id, type, dedup_key, refs) values ($1, 'user_message', 'new-odd', $2)`, [alice, JSON.stringify({ note: "글" })])).rejects.toThrow(/inbox_events_refs_ids_only/);
      await expect(db.query(`update public.inbox_events set processed_at = now() where id = $1`, [ids[0]])).rejects.toThrow(/inbox_events_result_consistency/);

      // 옛 처리 전 사건은 집어 끝낼 수 있다 (처리된 옛 행 · 다른 사용자 행과 서로 막지 않는다)
      const claimed = await db.query(`select * from public.coordinator_claim('upgrade', 60, 10, 3)`);
      expect(claimed.map((r) => r.event_id).sort()).toEqual([ids[0], ids[3]].sort());
      for (const row of claimed) {
        const done = await db.query(`select public.coordinator_finish($1, $2, 'no_impact', '{}', null) as s`, [row.event_id, row.claim_token]);
        expect(done[0].s).toBe("finished");
      }
      // 처리된 옛 행(processed_at은 있고 결과 종류가 없는 행)은 집히지 않고 그대로다
      expect(await db.query(`select * from public.coordinator_claim('upgrade', 60, 10, 3)`)).toEqual([]);
      expect(await db.query(`select id, processed_at from public.inbox_events where id = any ($1) order by created_at`, [[ids[1], ids[2]]])).toHaveLength(2);
    });

    it("같은 이름의 객체가 이미 있으면 마이그레이션은 아무것도 바꾸지 않고 실패한다 (한 트랜잭션 롤백)", async () => {
      const { before, c2 } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      // 파일의 맨 끝 함수와 같은 서명: 앞의 열 · 제약 · 함수 · 트리거를 다 만든 뒤에 실패한다 → 모두 되돌려져야 한다
      await db.exec(`create function public.coordinator_pending_inputs(p_user_id uuid) returns int language sql as 'select 1'`);
      await expect(db.exec(c2)).rejects.toThrow(/already exists|이미 있/);
      await db.exec("rollback");
      expect(await db.query(`select 1 from information_schema.columns where table_name = 'inbox_events' and column_name in ('seq', 'claim_token', 'attempts', 'result_kind')`)).toEqual([]);
      expect(await db.query(`select 1 from pg_trigger where tgname like 'coordinator\\_on\\_%' or tgname = 'inbox_events_guard'`)).toEqual([]);
      expect(await db.query(`select 1 from pg_proc where proname in ('coordinator_claim', 'coordinator_enqueue', 'inbox_refs_valid', 'coordinator_event_types')`)).toEqual([]);
      expect(await db.query(`select 1 from pg_constraint where conname in ('inbox_events_refs_ids_only', 'inbox_events_result_consistency')`)).toEqual([]);
      // 옛 동작이 그대로다
      const user = randomUUID();
      await db.query(`insert into auth.users (id, email) values ($1, 'x@example.com')`, [user]);
      await db.query(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'timer', 'still-ok')`, [user]);
    });
  });
}
