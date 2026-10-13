import { randomUUID } from "node:crypto";
import { readdir } from "node:fs/promises";
import path from "node:path";

import { beforeAll, describe, expect, it } from "vitest";

import { CHANGE_EVENT_TYPES } from "../../src/lib/actions/changed";
import { supabaseSchemaScripts } from "./local-supabase";

// 0.2.0 C3 (20261111000000_review_summary + 후속 20261112000000_review_summary_baseline) — 제안 · 복귀 요약 · Clear · 첫 정상 표시 기준점 저장 계약.
// suggestions 표(dedup · 상한 · snooze · topic 억제 · 증거 있는 stale) · return_summary_reads(Clear가 읽음으로 표시한 사건 id) · return_summary_state(마지막 Clear 시각) · 서비스 롤 전용 RPC.
// 읽음은 시각(워터마크)이 아니라 사건 id다: created_at은 트랜잭션 시작 시각이라 commit 순서와 다르다 (P2-A: Clear 뒤 commit되는 사건이 숨지 않는다).
// 같은 시나리오를 PGlite(tests/db/review-summary.test.ts)와 실제 Postgres(tests/pg/review-summary.test.ts)에서 돈다.
// 연결이 둘 이상 필요한 경합(같은 하루 묶음 동시 노출 · 동시 Clear · 동시 전이)은 실제 Postgres 파일에만 있다.
// 표기: [실제 연결] = 지금 코드의 실제 표(action_events · execution_events · conversation_messages · inbox_events 결과)에서 읽는 것.

export type Rows = Record<string, unknown>[];

export type ReviewDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

export const CHANGE_TYPES = [...CHANGE_EVENT_TYPES];

/** 운영의 db_now()는 now()뿐이다. 마이그레이션을 적용한 뒤 테스트 안에서만 app.now 판으로 바꾼다 (tests/coordinator/support.ts와 같은 판) */
export const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;

/** 마이크로초까지 있는 UTC 시각 글자: 같은 시각 + n µs */
export const at = (base: string, micros = 0): string => {
  const [head, frac = ""] = base.replace("Z", "").split(".");
  const padded = (frac + "000000").slice(0, 6);
  const total = Number(padded) + micros;
  const seconds = Math.floor(total / 1_000_000);
  const rest = String(((total % 1_000_000) + 1_000_000) % 1_000_000).padStart(6, "0");
  const date = new Date(`${head}Z`);
  date.setUTCSeconds(date.getUTCSeconds() + seconds);
  return `${date.toISOString().slice(0, 19)}.${rest}Z`;
};

export function reviewFixtures(db: () => ReviewDb) {
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);
  const one = async (sql: string, params: unknown[] = []) => (await q(sql, params))[0];
  const id = async (sql: string, params: unknown[] = []) => (await one(sql, params)).id as string;
  const count = async (sql: string, params: unknown[] = []) => Number((await one(`select count(*)::int as n from (${sql}) x`, params)).n);
  const setClock = (when: string) => q(`select set_config('app.now', $1, false)`, [when]);

  const fx = {
    q,
    one,
    id,
    count,
    setClock,
    async user(): Promise<string> {
      const userId = randomUUID();
      await q(`insert into auth.users (id, email) values ($1, $2)`, [userId, `${userId}@example.com`]);
      return userId;
    },
    action: (userId: string, extra: { title?: string; dueAt?: string | null; status?: string; owner?: string; startedAt?: string | null } = {}) =>
      id(`insert into public.actions (user_id, title, due_at, status, owner, started_at) values ($1, $2, $3, $4, $5, $6) returning id`, [
        userId, extra.title ?? "제안서 보내기", extra.dueAt ?? null, extra.status ?? "open", extra.owner ?? "me", extra.startedAt ?? null,
      ]),
    source: (userId: string, extra: { lost?: boolean; purged?: boolean } = {}) =>
      id(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, access_lost_at, raw_text_purged_at) values ($1, 'meeting', '원문 본문 — 회의에서 나온 말', now(), $2, $3) returning id`,
        [userId, extra.lost ? "2026-10-01T00:00:00Z" : null, extra.purged ? "2026-10-01T00:00:00Z" : null],
      ),
    /** action_events 한 줄 (시각을 정한다) */
    event: (userId: string, actionId: string, type: string, actor: string, createdAt: string, sourceId: string | null = null) =>
      id(`insert into public.action_events (user_id, action_id, type, actor, created_at, source_id) values ($1, $2, $3, $4, $5, $6) returning id`, [
        userId, actionId, type, actor, createdAt, sourceId,
      ]),
    run: (userId: string, actionId: string) => id(`select public.create_run($1, $2, 'draft', '제안서 초안 써 줘') as id`, [userId, actionId]),
    /** run 상태를 바꾼다: 트리거가 db_now() 시각으로 execution_events를 남긴다 (setClock으로 정한다) */
    setRun: (runId: string, state: string, outcome: string | null = null) => q(`update public.execution_runs set state = $2, outcome = $3 where id = $1`, [runId, state, outcome]),
    conversation: (userId: string, lastReadAt: string | null = null) =>
      id(`insert into public.conversations (user_id, last_read_at) values ($1, $2) returning id`, [userId, lastReadAt]),
    message: (userId: string, conversationId: string, seq: number, role: string, refs: unknown, createdAt: string) =>
      id(
        `insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text, refs, created_at) values ($1, $2, $3, $4, $5, '안녕', $6, $7) returning id`,
        [userId, conversationId, seq, role, role === "user" ? randomUUID() : null, JSON.stringify(refs), createdAt],
      ),
    /** 서버가 쓰는 제안 (생산자 없이 직접. 상한 · 노출 시험용) */
    suggestion: (
      userId: string,
      actionId: string,
      extra: { kind?: string; urgent?: boolean; revision?: string; createdAt?: string; runId?: string | null; subjectKey?: string } = {},
    ) => {
      const revision = extra.revision ?? randomUUID();
      // 기본 kind는 주제 유효성 규칙이 없는 시험용 토큰이다 (알려진 kind는 주제가 그대로인지 노출 때 확인한다)
      const kind = extra.kind ?? "test_kind";
      const subjectKey = extra.subjectKey ?? `action:${actionId}`;
      return id(
        `insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key, urgent, created_at)
         values ($1, $2, $3, $4, $5, $6, $7, $8, coalesce($9::timestamptz, now())) returning id`,
        [userId, kind, actionId, extra.runId ?? null, subjectKey, revision, `${kind}:${subjectKey}:${revision}`, extra.urgent ?? false, extra.createdAt ?? null],
      );
    },
    produce: async (userId: string, now: string, withCoordinator = false, windowHours = 24): Promise<number> =>
      Number((await one(`select public.suggestions_produce($1, $2::timestamptz, $3, $4) as n`, [userId, now, windowHours, withCoordinator])).n),
    /** batch_day는 드라이버마다 시간대가 끼는 date라 글자로 받는다 */
    expose: (userId: string, day: string | null, now: string | null = null, size = 3) =>
      q(`select s.*, s.batch_day::text as batch_day_text from public.suggestions_expose($1, $2::date, $3, $4::timestamptz) s`, [userId, day, size, now]),
    transition: async (
      userId: string,
      suggestionId: string,
      version: number,
      op: "snooze" | "dismiss",
      extra: { until?: string | null; scope?: string | null; now?: string | null } = {},
    ) =>
      (
        await one(`select public.suggestion_transition($1, $2, $3, $4, $5::timestamptz, $6, $7::timestamptz) as r`, [
          userId, suggestionId, version, op, extra.until ?? null, extra.scope ?? null, extra.now ?? null,
        ])
      ).r as { status: string; suggestion?: Record<string, unknown> },
    suggestionRow: (suggestionId: string) => one(`select * from public.suggestions where id = $1`, [suggestionId]),
    scan: async (userId: string, now: string | null, limit = 300) =>
      (await one(`select public.return_summary_scan($1, $2::text[], $3::timestamptz, $4) as r`, [userId, CHANGE_TYPES, now, limit])).r as ScanResult,
    /** 커서는 조회 결과(scan) 그대로 넘기면 된다: 잘렸으면 page(보인 작업)와 baseline도 같이 간다 */
    clear: async (userId: string, cursor: { horizon: string; digest: string; page?: string[] | null; baseline?: boolean }, now: string | null = null) =>
      (
        await one(`select public.return_summary_clear($1, $2::text[], $3::timestamptz, $4, $5::timestamptz, $6::uuid[], $7) as r`, [
          userId, CHANGE_TYPES, cursor.horizon, cursor.digest, now, cursor.page ?? null, cursor.baseline ?? false,
        ])
      ).r as ClearResult,
    /** 첫 정상 표시 기준점 확정: 토큰 = 조회가 준 지평 + init_digest */
    init: async (userId: string, token: { horizon: string; init_digest: string | null }, now: string | null = null) =>
      (
        await one(`select public.return_summary_baseline_init($1, $2::text[], $3::timestamptz, $4, $5::timestamptz) as r`, [
          userId, CHANGE_TYPES, token.horizon, token.init_digest, now,
        ])
      ).r as BaselineInitResult,
    baselineRows: (userId: string) => count(`select 1 from public.return_summary_baseline where user_id = $1`, [userId]),
    /** 기준점 행의 지평 (글자로) */
    baselineHorizon: async (userId: string) =>
      (await one(`select to_char(horizon at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as h from public.return_summary_baseline where user_id = $1`, [userId]))?.h as string | undefined,
    reads: (userId: string) => count(`select 1 from public.return_summary_reads where user_id = $1`, [userId]),
    state: (userId: string) => one(`select cleared_through, version::int as version from public.return_summary_state where user_id = $1`, [userId]),
    /** 쓰기가 Clear · 노출 · 제안 처리 안에서 다른 곳에 닿지 않았음을 보는 지문: 업무 · 실행 · 사건 표의 행 수와 Action 내용 */
    async fingerprint(userId: string): Promise<string> {
      const parts = await Promise.all(
        ["actions", "action_events", "claims", "evidence", "sources", "execution_runs", "execution_steps", "execution_approvals", "execution_intents", "execution_events", "inbox_events", "conversations", "conversation_messages", "work_contexts", "context_members", "memory_items"].map(
          async (t) => `${t}=${await count(`select 1 from public.${t} where user_id = $1`, [userId])}`,
        ),
      );
      const actions = await q(`select id, title, status, due_at, owner, version, needs_confirmation, started_at from public.actions where user_id = $1 order by id`, [userId]);
      return `${parts.join(",")}|${JSON.stringify(actions)}`;
    },
  };
  return fx;
}

type ScanChange = { source: "action_event" | "run" | "message"; kind: string; at: string; detail: string | null; source_state: string | null };
export type ScanWork = { action_id: string; title: string; status: string; started: boolean; last_user_at: string | null; changes: ScanChange[] };
export type ScanResult = {
  since: string | null;
  horizon: string;
  digest: string;
  truncated: boolean;
  page: string[] | null;
  baseline: boolean;
  /** 응답의 baseline 값: Clear했다 / 기준점이 확정됐다 / 둘 다 아니다 */
  baseline_state: "cleared" | "initialized" | "never_cleared";
  /** 기준점 범위의 관찰 digest. 기준점이 아직 없을 때만 (빈 첫 화면 포함) */
  init_digest: string | null;
  works: ScanWork[];
};
export type BaselineInitResult = { status: "initialized" | "already_initialized" | "stale" | "invalid" };
export type ClearResult = { status: "cleared" | "stale" | "invalid"; applied?: boolean; cleared_through?: string };

const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);

const T0 = "2026-10-12T00:00:00.000000Z";
const NOW = "2026-10-12T09:00:00Z";

export function reviewSummaryTests(db: () => ReviewDb) {
  const f = reviewFixtures(db);
  const q = f.q;

  beforeAll(async () => {
    await q(TEST_CLOCK);
    await f.setClock("2026-10-12T00:00:00Z");
  });

  // ───────────────────────── 1) 저장 모양 · 권한 ─────────────────────────
  describe("suggestions · return_summary_state: 열 · 제약 · RLS · 권한 (additive)", () => {
    it("suggestions는 id만 담는다: 글 · 원문 열이 없고(kind · 토큰 · uuid · 숫자 · 시각), 런타임 계약 8장 열을 갖는다", async () => {
      const columns = await q(
        `select column_name, data_type from information_schema.columns where table_schema = 'public' and table_name = 'suggestions' order by column_name`,
      );
      const names = columns.map((c) => c.column_name as string);
      for (const name of [
        "id", "user_id", "kind", "action_id", "run_id", "subject_key", "revision", "dedup_key", "reason_refs", "state", "snooze_until",
        "dismiss_scope", "urgent", "batch_day", "version", "created_at", "shown_at", "decided_at", "stale_evidence",
      ]) expect(names, name).toContain(name);
      const textual = columns.filter((c) => c.data_type === "text").map((c) => c.column_name as string);
      expect(textual.sort()).toEqual(["dedup_key", "dismiss_scope", "kind", "revision", "stale_evidence", "state", "subject_key"]);
    });

    it("앱은 자기 제안 · 자기 Clear 위치만 읽고(owner_all + select), 쓰기 · RPC 호출은 모두 거절 (서버 전용)", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [aa, ba] = [await f.action(alice), await f.action(bob)];
      await f.suggestion(alice, aa);
      await f.suggestion(bob, ba);
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, now()), ($2, now())`, [alice, bob]);
      const shared = randomUUID();
      await q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'message', $3, $4), ($2, 'message', $3, $5)`, [alice, bob, shared, aa, ba]);
      expect((await db().asUser(alice, () => q(`select user_id from public.return_summary_reads`))).map((r) => r.user_id)).toEqual([alice]);
      expect((await db().asUser(alice, () => q(`select user_id from public.suggestions`))).map((r) => r.user_id)).toEqual([alice]);
      expect((await db().asUser(alice, () => q(`select user_id from public.return_summary_state`))).map((r) => r.user_id)).toEqual([alice]);
      await db().asUser(alice, async () => {
        await rejects(q(`insert into public.suggestions (user_id, kind, action_id, subject_key, revision, dedup_key) values ($1, 'due_window', $2, 'x', 'y', 'z')`, [alice, aa]), /permission denied/);
        await rejects(q(`update public.suggestions set state = 'dismissed'`), /permission denied/);
        await rejects(q(`delete from public.suggestions`), /permission denied/);
        await rejects(q(`update public.return_summary_state set cleared_through = now()`), /permission denied/);
        await rejects(q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, now())`, [randomUUID()]), /permission denied/);
        await rejects(q(`select public.suggestions_produce($1, now(), 24, false)`, [alice]), /permission denied/);
        await rejects(q(`select * from public.suggestions_expose($1, current_date, 3, null)`, [alice]), /permission denied/);
        await rejects(q(`select public.suggestion_transition($1, $2, 1, 'dismiss', null, 'this', null)`, [alice, randomUUID()]), /permission denied/);
        await rejects(q(`select public.return_summary_scan($1, '{completed}'::text[], null, 10)`, [alice]), /permission denied/);
        await rejects(q(`select public.return_summary_clear($1, '{completed}'::text[], now(), 'x', null)`, [alice]), /permission denied/);
        await rejects(q(`select public.return_summary_digest($1, '{completed}'::text[], now())`, [alice]), /permission denied/);
        await rejects(q(`select * from public.return_summary_candidates($1, '{completed}'::text[], now())`, [alice]), /permission denied/);
        await rejects(q(`select * from public.return_summary_scope($1, '{completed}'::text[], now(), null, false)`, [alice]), /permission denied/);
        await rejects(q(`select public.return_summary_baseline_init($1, '{completed}'::text[], now(), 'x', null)`, [alice]), /permission denied/);
        await rejects(q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'message', gen_random_uuid()::text, $2)`, [alice, aa]), /permission denied/);
        await rejects(q(`delete from public.return_summary_reads`), /permission denied/);
      });
    });

    it("새 함수는 모두 search_path = '' 이고 service_role만 실행한다 (public · anon · authenticated 실행 권한 없음)", async () => {
      const rpcs = [
        "suggestions_produce(uuid,timestamp with time zone,integer,boolean)",
        "suggestions_expose(uuid,date,integer,timestamp with time zone)",
        "suggestion_transition(uuid,uuid,integer,text,timestamp with time zone,text,timestamp with time zone)",
        "suggestion_stale_evidence(public.suggestions)",
        "return_summary_scan(uuid,text[],timestamp with time zone,integer)",
        "return_summary_clear(uuid,text[],timestamp with time zone,text,timestamp with time zone,uuid[],boolean)",
        "return_summary_digest(uuid,text[],timestamp with time zone,uuid[],boolean)",
        "return_summary_scope(uuid,text[],timestamp with time zone,uuid[],boolean)",
        "return_summary_candidates(uuid,text[],timestamp with time zone)",
        "return_summary_baseline_init(uuid,text[],timestamp with time zone,text,timestamp with time zone)",
      ];
      for (const fn of rpcs) {
        const row = await f.one(
          `select has_function_privilege('anon', $1, 'execute') as anon, has_function_privilege('authenticated', $1, 'execute') as authenticated,
                  has_function_privilege('service_role', $1, 'execute') as service_role`,
          [`public.${fn}`],
        );
        expect({ fn, ...row }).toEqual({ fn, anon: false, authenticated: false, service_role: true });
      }
      const all = await q(
        `select p.proname, p.proconfig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and (p.proname like 'suggestion%' or p.proname like 'return\\_summary\\_%')`,
      );
      expect(all.length).toBeGreaterThanOrEqual(rpcs.length + 2);
      for (const row of all) expect({ fn: row.proname, config: row.proconfig }).toEqual({ fn: row.proname, config: expect.arrayContaining(["search_path=\"\""]) });
    });

    it("부모와 (id, user_id) 복합 외래키로 묶인다: 남의 Action · 남의 run을 가리키는 제안은 만들 수 없다, Action을 지우면 제안도 함께 사라진다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [aa, ba] = [await f.action(alice), await f.action(bob)];
      const bobRun = await f.run(bob, ba);
      await rejects(f.suggestion(alice, ba), /foreign key|suggestions_action_id_user_id_fkey/);
      await rejects(f.suggestion(alice, aa, { runId: bobRun }), /foreign key|suggestions_run_id_user_id_fkey/);
      const s = await f.suggestion(alice, aa);
      await q(`delete from public.actions where id = $1`, [aa]);
      expect(await f.count(`select 1 from public.suggestions where id = $1`, [s])).toBe(0);
    });

    it("(user_id, dedup_key)는 유일하다: 같은 계기는 한 행, 다른 사용자는 같은 키를 쓸 수 있다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [aa, ba] = [await f.action(alice), await f.action(bob)];
      await f.suggestion(alice, aa, { revision: "r1" });
      await rejects(f.suggestion(alice, aa, { revision: "r1" }), /suggestions_user_id_dedup_key_key|duplicate key/);
      await f.suggestion(bob, ba, { revision: "r1", subjectKey: `action:${aa}` });
    });

    it("상태 모양 CHECK: snoozed만 snooze_until, dismissed만 dismiss_scope, 끝난 상태만 decided_at, expired만 stale_evidence. 모르는 상태 · 범위 · 증거는 거절", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const s = await f.suggestion(user, action);
      await rejects(q(`update public.suggestions set state = 'snoozed' where id = $1`, [s]), /suggestions_shape/);
      await rejects(q(`update public.suggestions set snooze_until = now() where id = $1`, [s]), /suggestions_shape/);
      await rejects(q(`update public.suggestions set state = 'dismissed' where id = $1`, [s]), /suggestions_shape/);
      await rejects(q(`update public.suggestions set state = 'dismissed', dismiss_scope = 'forever', decided_at = now() where id = $1`, [s]), /suggestions_dismiss_scope_check/);
      await rejects(q(`update public.suggestions set state = 'expired', decided_at = now() where id = $1`, [s]), /suggestions_shape/);
      await rejects(q(`update public.suggestions set state = 'expired', decided_at = now(), stale_evidence = 'old' where id = $1`, [s]), /suggestions_stale_evidence_check/);
      await rejects(q(`update public.suggestions set state = 'gone' where id = $1`, [s]), /suggestions_state_check/);
      await q(`update public.suggestions set state = 'snoozed', snooze_until = now() + interval '1 hour' where id = $1`, [s]);
      await q(`update public.suggestions set state = 'dismissed', snooze_until = null, dismiss_scope = 'this', decided_at = now() where id = $1`, [s]);
    });

    it("reason_refs는 id · 종류 · 숫자만 담는다 (C2 inbox_refs_valid와 같은 모양): 문장 · 중첩 객체는 거절", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const bad = [{ note: "회의에서 김대리가 말함" }, { nested: { a: randomUUID() } }, { quote: "금요일까지" }];
      for (const refs of bad) {
        await rejects(
          q(`insert into public.suggestions (user_id, kind, action_id, subject_key, revision, dedup_key, reason_refs) values ($1, 'due_window', $2, 'a', 'r', $3, $4)`, [
            user, action, randomUUID(), JSON.stringify(refs),
          ]),
          /suggestions_reason_refs/,
        );
      }
    });

    it("제안의 사실(user_id · kind · action_id · run_id · subject_key · revision · dedup_key · urgent · created_at)은 바뀌지 않고, version은 줄지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const s = await f.suggestion(user, action);
      for (const [column, value] of [
        ["kind", "'run_failed'"], ["subject_key", "'x'"], ["revision", "'x'"], ["dedup_key", "'x'"], ["urgent", "true"], ["created_at", "now() - interval '1 day'"],
      ] as const) {
        await rejects(q(`update public.suggestions set ${column} = ${value} where id = $1`, [s]), /immutable/);
      }
      await q(`update public.suggestions set version = 3 where id = $1`, [s]);
      await rejects(q(`update public.suggestions set version = 2 where id = $1`, [s]), /version/);
    });

    it("Clear 위치는 사용자당 한 행이고 되돌아가지 않는다 (DB 트리거도 막는다)", async () => {
      const user = await f.user();
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0)]);
      await rejects(q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, now())`, [user]), /duplicate key|pkey/);
      await rejects(q(`update public.return_summary_state set cleared_through = $2 where user_id = $1`, [user, at(T0, -1)]), /cleared_through/);
      await q(`update public.return_summary_state set cleared_through = $2 where user_id = $1`, [user, at(T0, 1)]);
    });

    it("읽음 표시는 (사용자, 원천, 사건 id, 작업 id)뿐이다: 글 열이 없고, 모르는 원천 · 사건 id가 아닌 글자는 거절, 같은 쌍은 한 번만, 같은 사건도 작업이 다르면 따로, 남의 작업은 못 가리킨다, 작업이 지워지면 함께 지워진다", async () => {
      const [user, other] = [await f.user(), await f.user()];
      const [action, action2, foreign] = [await f.action(user), await f.action(user), await f.action(other)];
      const columns = (await q(`select column_name from information_schema.columns where table_schema = 'public' and table_name = 'return_summary_reads' order by column_name`)).map((r) => r.column_name);
      expect(columns).toEqual(["action_id", "event_ref", "read_at", "source", "user_id"]);
      const ref = randomUUID();
      await q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'action_event', $2, $3)`, [user, ref, action]);
      await q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'run_event', '12345', $2)`, [user, action]);
      await q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'action_event', $2, $3)`, [user, ref, action2]); // 같은 사건, 다른 작업
      await rejects(q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'action_event', $2, $3)`, [user, ref, action]), /duplicate key|pkey/);
      await rejects(q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'inbox_event', $2, $3)`, [user, randomUUID(), action]), /return_summary_reads_source_check/);
      await rejects(q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'message', '회의에서 나온 말', $2)`, [user, action]), /return_summary_reads_event_ref_check/);
      await rejects(q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'message', $2, $3)`, [user, randomUUID(), foreign]), /foreign key|return_summary_reads_action_id_user_id_fkey/);
      await q(`delete from public.actions where id = $1`, [action2]);
      expect(await f.count(`select 1 from public.return_summary_reads where user_id = $1`, [user])).toBe(2);
    });

    it("계정을 지우면 제안 · Clear 위치도 함께 지워진다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await f.suggestion(user, action);
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, now())`, [user]);
      await q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'message', $2, $3)`, [user, randomUUID(), action]);
      await q(`delete from auth.users where id = $1`, [user]);
      expect(await f.count(`select 1 from public.suggestions where user_id = $1`, [user])).toBe(0);
      expect(await f.count(`select 1 from public.return_summary_state where user_id = $1`, [user])).toBe(0);
      expect(await f.count(`select 1 from public.return_summary_reads where user_id = $1`, [user])).toBe(0);
    });
  });

  // ───────────────────────── 2) 생산자 · dedup (A08) ─────────────────────────
  describe("[실제 연결] 제안 생산자: kind + subject + 계기 revision이 dedup (날짜 아님)", () => {
    it("due_window: 기한이 긴급 창(24시간) 안인 내 열린 Action만, 긴급 제안으로. 지난 기한 · 창 밖 · 닫힘 · 남의 일 · 기한 없음은 만들지 않는다", async () => {
      const user = await f.user();
      const due = (hours: number) => new Date(Date.parse(NOW) + hours * 3_600_000).toISOString();
      const inWindow = await f.action(user, { dueAt: due(20) });
      await f.action(user, { dueAt: due(-2) });
      await f.action(user, { dueAt: due(30) });
      await f.action(user, { dueAt: due(5), status: "done" });
      await f.action(user, { dueAt: due(5), owner: "other" });
      await f.action(user);
      expect(await f.produce(user, NOW)).toBe(1);
      const rows = await q(`select kind, action_id, run_id, urgent, state, subject_key, revision, version from public.suggestions where user_id = $1`, [user]);
      expect(rows).toEqual([
        {
          kind: "due_window", action_id: inWindow, run_id: null, urgent: true, state: "open", subject_key: `action:${inWindow}`,
          revision: String(Math.floor(Date.parse(due(20)) / 1000)), version: 1,
        },
      ]);
    });

    it("A08: 같은 계기를 다시 받아도(재수신 · 재시작 · 두 번째 worker · 다음 날) 새 제안은 0이다. 날짜가 dedup이 아니다", async () => {
      const user = await f.user();
      const dueAt = new Date(Date.parse(NOW) + 20 * 3_600_000).toISOString();
      await f.action(user, { dueAt });
      expect(await f.produce(user, NOW)).toBe(1);
      expect(await f.produce(user, NOW)).toBe(0);
      // 하루가 지나지 않았어도 창 안에 남아 있는 한 날짜가 바뀌어도 새 제안이 아니다 (12시간 뒤, 다음 날 같은 시각 기준)
      expect(await f.produce(user, new Date(Date.parse(NOW) + 12 * 3_600_000).toISOString())).toBe(0);
      expect(await f.count(`select 1 from public.suggestions where user_id = $1`, [user])).toBe(1);
    });

    it("A08: snooze · 거절 뒤에 다시 시작해도(같은 계기) 새 제안이 없고, 기한이 바뀌어 계기 revision이 달라지면 새 제안이 하나 생긴다", async () => {
      const user = await f.user();
      const dueAt = new Date(Date.parse(NOW) + 20 * 3_600_000).toISOString();
      const action = await f.action(user, { dueAt });
      await f.produce(user, NOW);
      const s = await f.id(`select id from public.suggestions where user_id = $1`, [user]);
      expect((await f.transition(user, s, 1, "dismiss", { scope: "this" })).status).toBe("ok");
      expect(await f.produce(user, NOW)).toBe(0);
      // 같은 Action의 기한이 바뀜 = 새 계기 (this 거절은 새 계기를 막지 않는다)
      await q(`update public.actions set due_at = $2 where id = $1`, [action, new Date(Date.parse(NOW) + 22 * 3_600_000).toISOString()]);
      expect(await f.produce(user, NOW)).toBe(1);
      expect(await f.count(`select 1 from public.suggestions where user_id = $1`, [user])).toBe(2);
    });

    it("dismiss_scope = topic: 같은 kind + subject의 새 계기도 다시 제안하지 않는다. 다른 kind · 다른 subject는 막지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user, { dueAt: new Date(Date.parse(NOW) + 20 * 3_600_000).toISOString() });
      const other = await f.action(user, { dueAt: new Date(Date.parse(NOW) + 20 * 3_600_000).toISOString() });
      await f.produce(user, NOW);
      const s = await f.id(`select id from public.suggestions where action_id = $1`, [action]);
      expect((await f.transition(user, s, 1, "dismiss", { scope: "topic" })).status).toBe("ok");
      await q(`update public.actions set due_at = $2 where id = $1`, [action, new Date(Date.parse(NOW) + 21 * 3_600_000).toISOString()]);
      expect(await f.produce(user, NOW)).toBe(0);
      expect(await f.count(`select 1 from public.suggestions where action_id = $1`, [action])).toBe(1);
      // 같은 Action의 다른 kind(run_failed)는 막지 않는다
      const run = await f.run(user, action);
      await f.setRun(run, "failed");
      expect(await f.produce(user, NOW)).toBe(1);
      expect(await f.id(`select id from public.suggestions where action_id = $1 and kind = 'run_failed'`, [action])).toBeTruthy();
      // 다른 Action의 due_window는 이미 있었고 막히지 않았다
      expect(await f.count(`select 1 from public.suggestions where action_id = $1 and kind = 'due_window'`, [other])).toBe(1);
    });

    it("run_failed: 그 Action의 가장 최근 run이 failed일 때만 (긴급 제안). 뒤에 새 run이 있으면 옛 실패는 제안이 아니고, 새 run이 또 실패하면 새 계기", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const first = await f.run(user, action);
      await f.setRun(first, "failed");
      expect(await f.produce(user, NOW)).toBe(1);
      expect(await f.produce(user, NOW)).toBe(0);
      const row = await f.one(`select kind, run_id, urgent, subject_key, revision from public.suggestions where user_id = $1`, [user]);
      expect(row).toEqual({ kind: "run_failed", run_id: first, urgent: true, subject_key: `action:${action}`, revision: first });
      const second = await f.run(user, action);
      await f.setRun(second, "failed");
      expect(await f.produce(user, NOW)).toBe(1);
      // 닫힌 Action의 실패는 제안이 아니다
      const closed = await f.action(user);
      const closedRun = await f.run(user, closed);
      await f.setRun(closedRun, "failed");
      await q(`update public.actions set status = 'done' where id = $1`, [closed]);
      expect(await f.produce(user, NOW)).toBe(0);
    });

    it("source_revised_run [C2 처리 결과 소비]: 처리된 source_revised(impact_recorded) 결과가 가리키는 살아 있는 run마다 비긴급 제안. COORDINATOR 쪽이 꺼져 있으면(인자 false) 읽지도 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const live = await f.run(user, action);
      const ended = await f.run(user, await f.action(user));
      await f.setRun(ended, "done", "draft_ready");
      const source = await f.source(user);
      const event = async (key: string, kind: string, ids: Record<string, unknown>, processed = true, type = "source_revised") => {
        const e = await f.id(`insert into public.inbox_events (user_id, type, dedup_key, refs) values ($1, $2, $3, $4) returning id`, [user, type, key, JSON.stringify({ source_id: source })]);
        if (processed) await q(`update public.inbox_events set processed_at = now(), result_kind = $2, result_ids = $3 where id = $1`, [e, kind, JSON.stringify(ids)]);
        return e;
      };
      await event(`source:${randomUUID()}`, "impact_recorded", { run_ids: [live, ended] });
      await event(`source:${randomUUID()}`, "no_impact", { run_ids: [live] });
      await event(`source:${randomUUID()}`, "impact_recorded", { run_ids: [live] }, false);
      await event(`source:${randomUUID()}`, "impact_recorded", { run_ids: [live] }, true, "source_processed");
      expect(await f.produce(user, NOW, false)).toBe(0);
      expect(await f.produce(user, NOW, true)).toBe(1);
      expect(await f.produce(user, NOW, true)).toBe(0);
      const row = await f.one(`select kind, action_id, run_id, urgent, subject_key from public.suggestions where user_id = $1`, [user]);
      expect(row).toEqual({ kind: "source_revised_run", action_id: action, run_id: live, urgent: false, subject_key: `run:${live}` });
    });

    it("남의 사건 · 남의 run으로는 만들지 않는다: 생산은 호출한 사용자 한 명의 행만 본다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const dueAt = new Date(Date.parse(NOW) + 20 * 3_600_000).toISOString();
      await f.action(alice, { dueAt });
      const ba = await f.action(bob, { dueAt });
      await f.setRun(await f.run(bob, ba), "failed");
      expect(await f.produce(alice, NOW, true)).toBe(1);
      expect(await f.count(`select 1 from public.suggestions where user_id = $1`, [bob])).toBe(0);
      expect(await f.produce(bob, NOW, true)).toBe(2);
    });

    it("제안을 만드는 것은 Action · run · Claim · 정책 · 승인을 건드리지 않는다 (제안은 Action이 아니다, R5)", async () => {
      const user = await f.user();
      const action = await f.action(user, { dueAt: new Date(Date.parse(NOW) + 20 * 3_600_000).toISOString() });
      await f.setRun(await f.run(user, action), "failed");
      const before = await f.fingerprint(user);
      await f.produce(user, NOW, true);
      await f.expose(user, "2026-10-12", NOW);
      expect(await f.fingerprint(user)).toBe(before);
    });
  });

  // ───────────────────────── 3) 노출 · 하루 상한 · 긴급 우회 (A09) ─────────────────────────
  describe("노출 (suggestions_expose): 비긴급 하루 1묶음 · 3개, 긴급은 상한 밖", () => {
    it("처음 노출하는 비긴급은 그날 3개까지다: 같은 날 다시 불러도 같은 묶음이고 더 늘지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const ids: string[] = [];
      for (let i = 0; i < 5; i++) ids.push(await f.suggestion(user, action, { createdAt: at(T0, i * 1000) }));
      const first = await f.expose(user, "2026-10-12");
      expect(first.map((r) => r.id)).toEqual(ids.slice(0, 3));
      expect(first.every((r) => r.batch_day !== null && r.shown_at !== null)).toBe(true);
      const again = await f.expose(user, "2026-10-12");
      expect(again.map((r) => r.id)).toEqual(first.map((r) => r.id));
      expect(await f.count(`select 1 from public.suggestions where user_id = $1 and batch_day is not null`, [user])).toBe(3);
    });

    it("다음 날에는 아직 노출 안 한 것 중 3개까지 새로 내고, 어제 묶음은 처리하기 전까지 그대로 남는다 (새 알림 위주, 같은 것 반복 노출 없음)", async () => {
      const user = await f.user();
      const action = await f.action(user);
      for (let i = 0; i < 5; i++) await f.suggestion(user, action, { createdAt: at(T0, i * 1000) });
      const day1 = await f.expose(user, "2026-10-12");
      const day2 = await f.expose(user, "2026-10-13");
      expect(day2).toHaveLength(5);
      expect(day2.map((r) => r.id).sort()).toEqual(expect.arrayContaining(day1.map((r) => r.id)));
      // 새로 낸 것은 둘뿐이다 (남은 2개): 어제 낸 것의 batch_day는 어제 그대로
      expect(day2.filter((r) => r.batch_day_text === "2026-10-13")).toHaveLength(2);
      expect(day2.filter((r) => r.batch_day_text === "2026-10-12")).toHaveLength(3);
      // 사흘째는 새로 낼 것이 없다
      expect(await f.expose(user, "2026-10-14")).toHaveLength(5);
    });

    it("그날의 묶음을 전부 처리해도(dismiss · snooze) 같은 날 비긴급이 더 나오지 않는다 (하루 1묶음)", async () => {
      const user = await f.user();
      const action = await f.action(user);
      for (let i = 0; i < 5; i++) await f.suggestion(user, action, { createdAt: at(T0, i * 1000) });
      const batch = await f.expose(user, "2026-10-12");
      for (const row of batch) expect((await f.transition(user, row.id as string, row.version as number, "dismiss", { scope: "this" })).status).toBe("ok");
      expect(await f.expose(user, "2026-10-12")).toHaveLength(0);
      expect(await f.expose(user, "2026-10-13")).toHaveLength(2);
    });

    it("긴급(urgent)은 상한 밖이다: 비긴급 묶음이 이미 찬 날에도, 시간대를 몰라도(날짜 없음) 보인다. 날짜가 없으면 비긴급은 새로 내지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      for (let i = 0; i < 4; i++) await f.suggestion(user, action, { createdAt: at(T0, i * 1000) });
      const urgent = [await f.suggestion(user, action, { urgent: true }), await f.suggestion(user, action, { urgent: true }), await f.suggestion(user, action, { urgent: true }), await f.suggestion(user, action, { urgent: true })];
      // 시간대를 모르면(날짜 null) 비긴급 0 · 긴급은 전부
      const unknownZone = await f.expose(user, null);
      expect(unknownZone.map((r) => r.id).sort()).toEqual([...urgent].sort());
      expect(await f.count(`select 1 from public.suggestions where user_id = $1 and batch_day is not null`, [user])).toBe(0);
      const withDay = await f.expose(user, "2026-10-12");
      expect(withDay.filter((r) => r.urgent)).toHaveLength(4);
      expect(withDay.filter((r) => !r.urgent)).toHaveLength(3);
      // 긴급은 맨 앞
      expect(withDay.slice(0, 4).every((r) => r.urgent)).toBe(true);
    });

    it("snooze가 끝나면 다시 열리고(state open, version 증가) 하루 상한에 걸리지 않는다: 사용자가 고른 시점이다. 끝나기 전에는 보이지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const s = await f.suggestion(user, action);
      const [shown] = await f.expose(user, "2026-10-12", T0);
      expect(shown.id).toBe(s);
      const result = await f.transition(user, s, 1, "snooze", { until: at("2026-10-12T05:00:00Z"), now: "2026-10-12T03:00:00Z" });
      expect(result.status).toBe("ok");
      expect(await f.expose(user, "2026-10-12", "2026-10-12T04:00:00Z")).toHaveLength(0);
      const back = await f.expose(user, "2026-10-12", "2026-10-12T05:00:00Z");
      expect(back).toHaveLength(1);
      expect(back[0]).toMatchObject({ id: s, state: "open", snooze_until: null, version: 3 });
    });

    it("증거 있는 stale만 expired가 된다: 기한이 바뀜 · Action이 닫힘 · run이 끝남 · 새 run으로 바뀜. 단순히 오래됐다고 만료하지 않는다 (자동 만료 없음)", async () => {
      const user = await f.user();
      const dueAt = new Date(Date.parse(NOW) + 20 * 3_600_000).toISOString();
      const [due, closed] = [await f.action(user, { dueAt }), await f.action(user, { dueAt })];
      const failedAction = await f.action(user);
      const failedRun = await f.run(user, failedAction);
      await f.setRun(failedRun, "failed");
      const liveAction = await f.action(user);
      const liveRun = await f.run(user, liveAction);
      const source = await f.source(user);
      const e = await f.id(`insert into public.inbox_events (user_id, type, dedup_key, refs) values ($1, 'source_revised', $2, $3) returning id`, [user, `source:${source}`, JSON.stringify({ source_id: source })]);
      await q(`update public.inbox_events set processed_at = now(), result_kind = 'impact_recorded', result_ids = $2 where id = $1`, [e, JSON.stringify({ run_ids: [liveRun] })]);
      await f.produce(user, NOW, true);
      expect(await f.count(`select 1 from public.suggestions where user_id = $1 and state = 'open'`, [user])).toBe(4);
      // 아주 오래된 제안(예: 200일 전 생성)도 증거가 없으면 그대로 열려 있다
      await q(`alter table public.suggestions disable trigger suggestions_guard`);
      await q(`update public.suggestions set created_at = created_at - interval '200 days' where user_id = $1`, [user]);
      await q(`alter table public.suggestions enable trigger suggestions_guard`);
      expect(await f.expose(user, "2026-10-12", NOW)).toHaveLength(4);
      expect(await f.count(`select 1 from public.suggestions where user_id = $1 and state = 'expired'`, [user])).toBe(0);
      // 증거가 생긴다
      await q(`update public.actions set due_at = $2 where id = $1`, [due, new Date(Date.parse(NOW) + 22 * 3_600_000).toISOString()]);
      await q(`update public.actions set status = 'done' where id = $1`, [closed]);
      await f.setRun(await f.run(user, failedAction), "running");
      await f.setRun(liveRun, "done", "draft_ready");
      await f.expose(user, "2026-10-12", NOW);
      const rows = await q(`select subject_key, kind, state, stale_evidence, decided_at is not null as decided from public.suggestions where user_id = $1 order by kind, subject_key`, [user]);
      expect(rows.map((r) => `${r.kind}:${r.state}:${r.stale_evidence}`).sort()).toEqual(
        ["due_window:expired:action_closed", "due_window:expired:revision_changed", "run_failed:expired:run_superseded", "source_revised_run:expired:run_ended"].sort(),
      );
      expect(rows.every((r) => r.decided)).toBe(true);
      expect(await f.expose(user, "2026-10-12", NOW)).toHaveLength(0);
    });

    it("노출은 어떤 업무 · 실행 표도 건드리지 않는다 (제안을 보는 것만으로 Action · run 생성 0)", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await f.suggestion(user, action);
      await f.suggestion(user, action, { urgent: true });
      const before = await f.fingerprint(user);
      await f.expose(user, "2026-10-12");
      await f.expose(user, "2026-10-12");
      expect(await f.fingerprint(user)).toBe(before);
    });

    it("남의 제안은 보이지 않고 남의 상한을 쓰지 않는다", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [aa, ba] = [await f.action(alice), await f.action(bob)];
      for (let i = 0; i < 4; i++) await f.suggestion(alice, aa, { createdAt: at(T0, i) });
      for (let i = 0; i < 4; i++) await f.suggestion(bob, ba, { createdAt: at(T0, i) });
      expect(await f.expose(alice, "2026-10-12")).toHaveLength(3);
      expect(await f.expose(bob, "2026-10-12")).toHaveLength(3);
      expect(new Set((await f.expose(alice, "2026-10-12")).map((r) => r.user_id))).toEqual(new Set([alice]));
    });
  });

  // ───────────────────────── 4) 상태 전이 ─────────────────────────
  describe("전이 (suggestion_transition): 상태 + version 조건부 쓰기", () => {
    it("snooze는 사용자가 고른 미래 시점만 받는다: 과거 · 지금 · 없음은 invalid", async () => {
      const user = await f.user();
      const s = await f.suggestion(user, await f.action(user));
      const now = "2026-10-12T03:00:00Z";
      expect((await f.transition(user, s, 1, "snooze", { until: null, now })).status).toBe("invalid");
      expect((await f.transition(user, s, 1, "snooze", { until: "2026-10-12T03:00:00Z", now })).status).toBe("invalid");
      expect((await f.transition(user, s, 1, "snooze", { until: "2026-10-12T02:59:59Z", now })).status).toBe("invalid");
      expect((await f.suggestionRow(s)).state).toBe("open");
      const ok = await f.transition(user, s, 1, "snooze", { until: "2026-10-13T00:00:00Z", now });
      expect(ok.status).toBe("ok");
      expect(ok.suggestion).toMatchObject({ state: "snoozed", version: 2 });
    });

    it("dismiss는 범위(this · topic)가 있어야 하고, 처리하면 version이 오르고 decided_at이 찍힌다", async () => {
      const user = await f.user();
      const s = await f.suggestion(user, await f.action(user));
      expect((await f.transition(user, s, 1, "dismiss", { scope: null })).status).toBe("invalid");
      expect((await f.transition(user, s, 1, "dismiss", { scope: "forever" })).status).toBe("invalid");
      const ok = await f.transition(user, s, 1, "dismiss", { scope: "topic" });
      expect(ok).toMatchObject({ status: "ok", suggestion: { state: "dismissed", dismiss_scope: "topic", version: 2 } });
      expect((await f.suggestionRow(s)).decided_at).not.toBeNull();
    });

    it("옛 version · 이미 끝난 상태는 409 conflict이고 아무것도 쓰지 않는다 (자동 재시도 없음): 다른 기기에서 먼저 처리된 경우", async () => {
      const user = await f.user();
      const s = await f.suggestion(user, await f.action(user));
      expect((await f.transition(user, s, 1, "dismiss", { scope: "this" })).status).toBe("ok");
      const before = await f.suggestionRow(s);
      expect((await f.transition(user, s, 1, "snooze", { until: "2999-01-01T00:00:00Z" })).status).toBe("conflict");
      expect((await f.transition(user, s, 2, "snooze", { until: "2999-01-01T00:00:00Z" })).status).toBe("conflict");
      expect(await f.suggestionRow(s)).toEqual(before);
      // 한 번 처리했던 요청을 응답 유실 뒤 다시 보내도 같은 결과(conflict)다: 새 쓰기 없음
      expect((await f.transition(user, s, 1, "dismiss", { scope: "this" })).status).toBe("conflict");
      expect((await f.suggestionRow(s)).version).toBe(2);
    });

    it("남의 제안 · 없는 제안은 not_found로 같다 (남의 것이 있는지 알려 주지 않는다)", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const s = await f.suggestion(alice, await f.action(alice));
      expect((await f.transition(bob, s, 1, "dismiss", { scope: "this" })).status).toBe("not_found");
      expect((await f.transition(alice, randomUUID(), 1, "dismiss", { scope: "this" })).status).toBe("not_found");
      expect((await f.suggestionRow(s)).state).toBe("open");
    });

    it("전이는 다른 표를 건드리지 않는다 (제안 처리 ≠ Action 완료 · 승인 · 정책: 새 결정 outcome · Undo 없음)", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const s = await f.suggestion(user, action);
      const before = await f.fingerprint(user);
      await f.transition(user, s, 1, "snooze", { until: "2999-01-01T00:00:00Z" });
      expect(await f.fingerprint(user)).toBe(before);
    });
  });

  // ───────────────────────── 5) 복귀 요약 읽기 ─────────────────────────
  describe("복귀 요약 읽기 (return_summary_scan): 실제 원천에서 계산, 새 저장소 없음", () => {
    it("[action_events] AI · 실행기 변화(changed.ts 종류)만 후보다: 사용자 이벤트 · created · 사용자 종류는 아니고, 사용자가 같은 밀리초 이후에 손댄 작업의 변화는 본 것이라 빠진다. 한 번도 Clear하지 않은 사용자는 처음부터 본다", async () => {
      const user = await f.user();
      const action = await f.action(user, { title: "제안서 보내기" });
      const ms = (n: number) => at(T0, n * 1000); // 밀리초 단위 간격
      await f.event(user, action, "created", "ai", ms(1));
      await f.event(user, action, "due_changed", "ai", ms(5));
      await f.event(user, action, "user_edited", "user", ms(10));
      await f.event(user, action, "merged", "ai", ms(20));
      await f.event(user, action, "user_seen", "user", ms(25));
      await f.event(user, action, "artifact_created", "agent", ms(30));
      const scan = await f.scan(user, at(T0, 1_000_000));
      expect(scan.since).toBeNull();
      expect(scan.truncated).toBe(false);
      expect(scan.page).toBeNull();
      expect(scan.baseline).toBe(true);
      expect(scan.works).toHaveLength(1);
      expect(scan.works[0]).toMatchObject({ action_id: action, title: "제안서 보내기", status: "open", started: false });
      // 사용자가 마지막으로 손댄 시각(25ms) 뒤의 agent 변화만 남는다 (본 것 이전의 AI 변화 · created · 사용자 이벤트는 제외)
      expect(scan.works[0].changes.map((c) => `${c.source}:${c.kind}`)).toEqual(["action_event:artifact_created"]);
      expect(scan.works[0].last_user_at).toBe(ms(25));
    });

    it("같은 밀리초 안의 AI 변화와 사용자 이벤트는 본 것이다 (changed.ts: 시각이 같으면 본 것). 1ms 뒤의 변화는 안 읽은 변화", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await f.event(user, action, "user_seen", "user", "2026-10-12T00:00:00.005100Z");
      await f.event(user, action, "due_changed", "ai", "2026-10-12T00:00:00.005900Z"); // 같은 5ms
      expect((await f.scan(user, "2026-10-12T00:00:01Z")).works).toEqual([]);
      await f.event(user, action, "merged", "ai", "2026-10-12T00:00:00.006000Z"); // 6ms
      expect((await f.scan(user, "2026-10-12T00:00:01Z")).works[0].changes.map((c) => c.kind)).toEqual(["merged"]);
    });

    it("범위는 지평(horizon)까지다: 지평과 같은 시각은 이번 조회, 그 뒤는 다음 번이다 (같은 시각 tie). 읽음으로 표시한 사건은 시각과 상관없이 빠진다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      const read = await f.event(user, action, "due_changed", "ai", at(T0, 100));
      await f.event(user, action, "scope_changed", "ai", at(T0, 101));
      await f.event(user, action, "owner_changed", "ai", at(T0, 200));
      await f.event(user, action, "reopened", "ai", at(T0, 201));
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0, 100)]);
      await q(`insert into public.return_summary_reads (user_id, source, event_ref, action_id) values ($1, 'action_event', $2, $3)`, [user, read, action]);
      const scan = await f.scan(user, at(T0, 200));
      expect(scan.since).toBe(at(T0, 100)); // 표시용 (마지막 Clear의 지평)
      expect(scan.horizon).toBe(at(T0, 200));
      expect(scan.works[0].changes.map((c) => c.kind)).toEqual(["scope_changed", "owner_changed"]);
      // 읽음 표시가 없는 사건은 Clear 위치(시각)보다 이른 시각이어도 보인다: 시각은 읽음의 근거가 아니다
      await q(`update public.return_summary_state set cleared_through = $2 where user_id = $1`, [user, at(T0, 150)]);
      expect((await f.scan(user, at(T0, 200))).works[0].changes.map((c) => c.kind)).toEqual(["scope_changed", "owner_changed"]);
    });

    it("원문 상태는 토큰이다: 지운 원문 · 접근 상실 · 보관 만료 · 정상. 원문 글 · 과거 값(before · after)은 절대 내려가지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user, { title: "지금 제목" });
      const [ok, lost, purged] = [await f.source(user), await f.source(user, { lost: true }), await f.source(user, { purged: true })];
      const gone = await f.source(user);
      await f.event(user, action, "due_changed", "ai", at(T0, 1), ok);
      await f.event(user, action, "scope_changed", "ai", at(T0, 2), lost);
      await f.event(user, action, "owner_changed", "ai", at(T0, 3), purged);
      await f.event(user, action, "merged", "ai", at(T0, 4), gone);
      await q(`update public.action_events set before = '{"title":"옛 제목 — 삭제된 원문의 글"}', after = '{"title":"새 글"}' where action_id = $1`, [action]);
      await q(`delete from public.sources where id = $1`, [gone]);
      const scan = await f.scan(user, at(T0, 10));
      expect(scan.works[0].changes.map((c) => [c.kind, c.source_state])).toEqual([
        ["due_changed", "available"], ["scope_changed", "access_lost"], ["owner_changed", "text_expired"], ["merged", "deleted"],
      ]);
      const serialized = JSON.stringify(scan);
      for (const leaked of ["원문 본문", "옛 제목", "삭제된 원문의 글", "새 글", "before", "after", "raw_text", "quote"]) expect(serialized).not.toContain(leaked);
      // 제목은 지금 값이다 (옛 제목을 부활시키지 않는다)
      await q(`update public.actions set title = '바뀐 제목' where id = $1`, [action]);
      expect((await f.scan(user, at(T0, 10))).works[0].title).toBe("바뀐 제목");
    });

    it("[execution_events] run 결과는 한 번이라도 Clear한 뒤에만 후보다: done(결과 outcome 포함) · failed 전이. 멈춤 · 대기 전이는 후보가 아니다. 한 번도 Clear하지 않았으면 이력을 변화로 올리지 않는다", async () => {
      const user = await f.user();
      const [done, failed, stopped] = [await f.action(user), await f.action(user), await f.action(user)];
      await f.setClock("2026-10-12T00:00:10Z");
      const [r1, r2, r3, r4] = [await f.run(user, done), await f.run(user, failed), await f.run(user, stopped), await f.run(user, done)];
      await f.setClock("2026-10-12T00:00:20Z");
      await f.setRun(r1, "running");
      await f.setRun(r1, "done", "draft_ready");
      await f.setRun(r2, "failed");
      await f.setRun(r3, "stopped");
      await f.setRun(r4, "waiting_approval");
      expect((await f.scan(user, "2026-10-12T00:01:00Z")).works).toEqual([]);
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, '2026-10-12T00:00:15Z')`, [user]);
      const scan = await f.scan(user, "2026-10-12T00:01:00Z");
      const byAction = Object.fromEntries(scan.works.map((w) => [w.action_id, w.changes.map((c) => `${c.source}:${c.kind}:${c.detail}`)]));
      expect(byAction).toEqual({ [done]: ["run:done:draft_ready"], [failed]: ["run:failed:null"] });
    });

    it("[conversation_messages] 읽지 않은 assistant · event 메시지 중 Action을 가리키는 것만 후보다. 사용자 메시지 · refs 없음 · 깨진 refs는 후보가 아니고 오류도 아니다. last_read_at 이후만 보인다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0)]);
      const read = await f.conversation(user, at(T0, 500));
      await f.message(user, read, 1, "assistant", { action_ids: [action] }, at(T0, 400));
      await f.message(user, read, 2, "event", { action_ids: [action] }, at(T0, 600));
      await f.message(user, read, 3, "user", { action_ids: [action] }, at(T0, 700));
      await f.message(user, read, 4, "assistant", {}, at(T0, 800));
      await f.message(user, read, 5, "assistant", { action_ids: "not-a-list" }, at(T0, 810));
      await f.message(user, read, 6, "assistant", { action_ids: ["not-a-uuid", randomUUID()] }, at(T0, 820));
      const unread = await f.conversation(user, null);
      await f.message(user, unread, 1, "assistant", { action_ids: [action] }, at(T0, 900));
      const scan = await f.scan(user, at(T0, 1000));
      expect(scan.works).toHaveLength(1);
      expect(scan.works[0].changes.map((c) => `${c.source}:${c.kind}:${c.at}`)).toEqual([`message:event:${at(T0, 600)}`, `message:assistant:${at(T0, 900)}`]);
    });

    it("다른 사용자의 사건 · 남의 Action을 가리키는 메시지는 보이지 않는다 (service role에서도 user_id로 좁힌다)", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      const [aa, ba] = [await f.action(alice), await f.action(bob)];
      await f.event(bob, ba, "completed", "ai", at(T0, 1));
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [alice, at(T0)]);
      const conversation = await f.conversation(alice, null);
      await f.message(alice, conversation, 1, "assistant", { action_ids: [ba] }, at(T0, 2));
      const scan = await f.scan(alice, at(T0, 10));
      expect(scan.works).toEqual([]);
      expect((await f.scan(bob, at(T0, 10))).works.map((w) => w.action_id)).toEqual([ba]);
      expect(aa).toBeTruthy();
    });

    it("작업이 너무 많으면 잘렸다고 알린다 (truncated): 일부를 전체처럼 내지 않는다", async () => {
      const user = await f.user();
      for (let i = 0; i < 4; i++) await f.event(user, await f.action(user), "completed", "ai", at(T0, i + 1));
      const scan = await f.scan(user, at(T0, 100), 3);
      expect(scan.works).toHaveLength(3);
      expect(scan.truncated).toBe(true);
      expect((await f.scan(user, at(T0, 100), 4)).truncated).toBe(false);
    });

    it("읽기는 아무것도 쓰지 않는다 (같은 조회를 몇 번 해도 어떤 표도 달라지지 않고 Clear 위치도 만들지 않는다)", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await f.event(user, action, "completed", "ai", at(T0, 1));
      const before = await f.fingerprint(user);
      await f.scan(user, at(T0, 10));
      await f.scan(user, at(T0, 10));
      expect(await f.fingerprint(user)).toBe(before);
      expect(await f.state(user)).toBeUndefined();
    });
  });

  // ───────────────────────── 6) Clear ─────────────────────────
  describe("Clear (return_summary_clear): 조회가 본 사건 집합의 id만 읽음 처리한다 (시각이 근거가 아니다)", () => {
    async function seed() {
      const user = await f.user();
      const action = await f.action(user);
      await f.event(user, action, "due_changed", "ai", at(T0, 10));
      await f.event(user, action, "merged", "ai", at(T0, 20));
      return { user, action };
    }

    it("조회한 사건을 읽음 처리한다: Clear 뒤 같은 범위는 비어 있고 since(표시용)가 지평으로 옮겨 간다. 읽음은 사건 id로 남는다", async () => {
      const { user } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect(scan.works).toHaveLength(1);
      const result = await f.clear(user, scan, at(T0, 200));
      expect(result).toEqual({ status: "cleared", applied: true, cleared_through: at(T0, 100) });
      expect(await f.reads(user)).toBe(2);
      expect(await f.state(user)).toMatchObject({ version: 1 });
      const after = await f.scan(user, at(T0, 300));
      expect(after.since).toBe(at(T0, 100));
      expect(after.works).toEqual([]);
    });

    it("조회와 Clear 사이에 생긴 새 사건(지평 뒤)은 읽음이 아니다: 다음 조회에 보인다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      await f.event(user, action, "owner_changed", "ai", at(T0, 150));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      const after = await f.scan(user, at(T0, 300));
      expect(after.works[0].changes.map((c) => c.kind)).toEqual(["owner_changed"]);
    });

    it("P2-A: Clear 뒤에 commit되는 사건은 시각이 지평 이전이어도(트랜잭션 시작 시각) 숨지 않는다 — 읽음은 조회가 본 id만이다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      // 조회 때 아직 commit되지 않았다가 Clear 뒤에 commit된 행: created_at(트랜잭션 시작)이 지평 이전이다
      await f.event(user, action, "reopened", "ai", at(T0, 15));
      await f.event(user, action, "completed", "ai", at(T0, 100)); // 지평과 같은 시각의 늦은 행
      const after = await f.scan(user, at(T0, 300));
      expect(after.works[0].changes.map((c) => c.kind)).toEqual(["reopened", "completed"]);
      // 이제 조회한 것이므로 다시 Clear하면 읽음이 된다 (영구히 잠기지 않는다)
      expect((await f.clear(user, after, at(T0, 400))).status).toBe("cleared");
      expect((await f.scan(user, at(T0, 500))).works).toEqual([]);
      expect(await f.reads(user)).toBe(4);
    });

    it("P2-A: run 결과 · 대화 메시지도 같다 — 늦게 commit된 행(지평 이전 시각)은 Clear 뒤에도 보인다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0)]);
      const conversation = await f.conversation(user, null);
      await f.message(user, conversation, 1, "assistant", { action_ids: [action] }, at(T0, 10));
      const scan = await f.scan(user, at(T0, 100));
      expect(scan.works).toHaveLength(1);
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      await f.message(user, conversation, 2, "event", { action_ids: [action] }, at(T0, 50)); // 늦은 메시지
      await q(`insert into public.execution_events (user_id, run_id, type, from_state, to_state, at) select $1, r.id, 'run', 'running', 'done', $3 from public.execution_runs r where r.id = $2`, [user, await f.run(user, action), at(T0, 60)]);
      await q(`update public.execution_runs set state = 'done', outcome = 'draft_ready' where action_id = $1`, [action]);
      const after = await f.scan(user, at(T0, 300));
      expect(after.works[0].changes.map((c) => `${c.source}:${c.kind}`).sort()).toEqual(["message:event", "run:done"]);
    });

    it("같은 시각 tie: 지평과 정확히 같은 시각의 사건이 조회 뒤 Clear 전에 commit되면 digest가 달라 stale이고 아무것도 읽음 처리하지 않는다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      await f.event(user, action, "scope_changed", "ai", at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("stale");
      expect(await f.state(user)).toBeUndefined();
      expect(await f.reads(user)).toBe(0);
      expect((await f.scan(user, at(T0, 300))).works[0].changes.map((c) => c.kind)).toEqual(["due_changed", "merged", "scope_changed"]);
    });

    it("늦게 commit된 사건(트랜잭션 시작 시각이 지평 이전)이 조회 뒤 Clear 전에 보이면 stale. 다시 조회하면 보이고 그 뒤 Clear하면 읽음이 된다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      await f.event(user, action, "reopened", "ai", at(T0, 15));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("stale");
      expect(await f.reads(user)).toBe(0);
      const again = await f.scan(user, at(T0, 300));
      expect(again.works[0].changes.map((c) => c.kind)).toEqual(["due_changed", "reopened", "merged"]);
      expect((await f.clear(user, again, at(T0, 400))).status).toBe("cleared");
      expect((await f.scan(user, at(T0, 500))).works).toEqual([]);
    });

    it("범위 안 사건이 지워져도(Action 삭제) digest가 달라 stale이다: 다시 조회하게 하고, 지운 사건은 읽음 표시와 상관없이 되살아나지 않는다", async () => {
      const { user } = await seed();
      const other = await f.action(user);
      await f.event(user, other, "completed", "ai", at(T0, 30));
      const scan = await f.scan(user, at(T0, 100));
      await q(`delete from public.actions where id = $1`, [other]);
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("stale");
      const again = await f.scan(user, at(T0, 300));
      expect((await f.clear(user, again, at(T0, 400))).status).toBe("cleared");
      expect((await f.scan(user, at(T0, 500))).works).toEqual([]);
    });

    it("DB 정밀도: 마이크로초 1 차이도 집합을 가른다. 밀리초로 잘린 지평으로 Clear하려 하면 그 사이 사건 때문에 stale", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await f.event(user, action, "due_changed", "ai", "2026-10-12T00:00:00.123400Z");
      await f.event(user, action, "merged", "ai", "2026-10-12T00:00:00.123700Z");
      const scan = await f.scan(user, "2026-10-12T00:00:00.123700Z");
      expect(scan.works[0].changes).toHaveLength(2);
      expect(scan.horizon).toBe("2026-10-12T00:00:00.123700Z");
      const truncatedToMillis = { ...scan, horizon: "2026-10-12T00:00:00.123Z" };
      expect((await f.clear(user, truncatedToMillis, "2026-10-12T00:00:01Z")).status).toBe("stale");
      expect(await f.state(user)).toBeUndefined();
      expect(await f.reads(user)).toBe(0);
      // 1µs 뒤의 사건은 같은 지평의 집합이 아니다
      await f.event(user, action, "completed", "ai", "2026-10-12T00:00:00.123701Z");
      expect((await f.clear(user, scan, "2026-10-12T00:00:01Z")).status).toBe("cleared");
      expect((await f.scan(user, "2026-10-12T00:00:02Z")).works[0].changes.map((c) => c.kind)).toEqual(["completed"]);
    });

    it("두 기기 · 겹친 읽기 · 늦은 Clear · 재시도(응답 유실): 읽음은 줄지 않고, 같은 커서를 다시 보내도 성공이지만 새 쓰기는 없다", async () => {
      const { user, action } = await seed();
      const early = await f.scan(user, at(T0, 100));
      await f.event(user, action, "owner_changed", "ai", at(T0, 150));
      const late = await f.scan(user, at(T0, 200));
      expect(await f.clear(user, late, at(T0, 300))).toMatchObject({ status: "cleared", applied: true, cleared_through: at(T0, 200) });
      const stale = await f.clear(user, early, at(T0, 300));
      expect(stale).toEqual({ status: "cleared", applied: false, cleared_through: at(T0, 200) });
      const retry = await f.clear(user, late, at(T0, 300));
      expect(retry).toEqual({ status: "cleared", applied: false, cleared_through: at(T0, 200) });
      expect(await f.state(user)).toMatchObject({ version: 1 });
      expect(await f.reads(user)).toBe(3);
    });

    it("두 기기가 서로 다른 시점에 본 집합을 각각 Clear해도 합쳐서 본 것까지만, 그 뒤 사건은 남는다", async () => {
      const { user, action } = await seed();
      const deviceA = await f.scan(user, at(T0, 100));
      await f.event(user, action, "owner_changed", "ai", at(T0, 150));
      const deviceB = await f.scan(user, at(T0, 200));
      await f.event(user, action, "completed", "ai", at(T0, 250));
      expect((await f.clear(user, deviceB, at(T0, 300))).status).toBe("cleared");
      expect((await f.clear(user, deviceA, at(T0, 300))).status).toBe("cleared");
      const after = await f.scan(user, at(T0, 400));
      expect(after.since).toBe(at(T0, 200));
      expect(after.works[0].changes.map((c) => c.kind)).toEqual(["completed"]);
    });

    it("미래 지평은 받지 않는다 (invalid): 서버 시각 기준으로 아직 오지 않은 시각을 읽음으로 만들 수 없다", async () => {
      const { user } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(user, { ...scan, horizon: at(T0, 100) }, at(T0, 99))).status).toBe("invalid");
      expect((await f.clear(user, { ...scan, horizon: "2999-01-01T00:00:00Z" }, at(T0, 99))).status).toBe("invalid");
      expect(await f.state(user)).toBeUndefined();
      expect(await f.reads(user)).toBe(0);
    });

    it("잘못된 digest는 stale이다 (아무것도 쓰지 않는다)", async () => {
      const { user } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(user, { ...scan, digest: "a:0:0|r:0:0|m:0:0" }, at(T0, 300))).status).toBe("stale");
      expect(await f.reads(user)).toBe(0);
      expect((await f.clear(user, scan, at(T0, 300))).status).toBe("cleared");
    });

    it("남의 커서로는 아무것도 지우지 못한다: 사용자마다 집합을 다시 세므로 digest가 맞지 않으면 stale, 읽음은 사용자별이다", async () => {
      const { user } = await seed();
      const other = await f.user();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(other, scan, at(T0, 200))).status).toBe("stale");
      expect(await f.state(other)).toBeUndefined();
      expect(await f.reads(other)).toBe(0);
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      expect(await f.reads(other)).toBe(0);
    });

    it("처음 Clear하면 그때 보이던 이력 전부(run · 대화 포함)가 기준이다: 이후에 생긴 결과만 새 변화다. 한 번도 Clear하지 않았다면 이력은 변화로 올리지 않는다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await f.setClock("2026-10-12T00:00:10Z");
      const oldRun = await f.run(user, action);
      await f.setRun(oldRun, "failed");
      const conversation = await f.conversation(user, null);
      await f.message(user, conversation, 1, "assistant", { action_ids: [action] }, at(T0, 5));
      const first = await f.scan(user, "2026-10-12T00:01:00Z");
      expect(first.since).toBeNull();
      expect(first.works).toEqual([]); // 읽음 기준이 없다
      expect((await f.clear(user, first, "2026-10-12T00:02:00Z")).status).toBe("cleared");
      expect(await f.reads(user)).toBe(2); // 보이지 않던 이력도 기준으로 읽음 처리됐다
      expect((await f.scan(user, "2026-10-12T00:03:00Z")).works).toEqual([]);
      // 이후에 도착한 결과 · 메시지는 새 변화다
      await f.setClock("2026-10-12T00:02:30Z");
      const newRun = await f.run(user, action);
      await f.setRun(newRun, "done", "draft_ready");
      await f.message(user, conversation, 2, "event", { action_ids: [action] }, "2026-10-12T00:02:31Z");
      const later = await f.scan(user, "2026-10-12T00:05:00Z");
      expect(later.works[0].changes.map((c) => `${c.source}:${c.kind}`).sort()).toEqual(["message:event", "run:done"]);
    });

    it("Clear는 읽음 처리일 뿐이다: Action · Claim · 근거 · run · 단계 · 승인 · intent · 사건함 · 제안 어느 것도 바뀌지 않는다 (해결 · 승인 · 완료 · 거절 아님)", async () => {
      const { user, action } = await seed();
      await f.setRun(await f.run(user, action), "running");
      const s = await f.suggestion(user, action);
      const before = await f.fingerprint(user);
      const suggestionBefore = await f.suggestionRow(s);
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      expect(await f.fingerprint(user)).toBe(before);
      expect(await f.suggestionRow(s)).toEqual(suggestionBefore);
      // action_events에 user_seen도 만들지 않는다 (기존 seen 함수를 쓰지 않는다)
      expect(await f.count(`select 1 from public.action_events where user_id = $1 and type = 'user_seen'`, [user])).toBe(0);
    });

    it("재로그인 · 같은 UUID: 읽음은 계정에 붙는다 (세션이 아니다). 같은 커서는 새 세션에서도 그대로 통한다", async () => {
      const { user } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      expect((await f.scan(user, at(T0, 300))).since).toBe(at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 400)))).toMatchObject({ status: "cleared", applied: false });
    });

  // ───────────────────────── 7) 잘린 조회 (P2-C) ─────────────────────────
  describe("잘린 조회: 커서가 보인 작업만 가리킨다 — Clear는 그 작업의 사건만 읽음 처리하고 나머지는 다음 조회에 나온다", () => {
    /** 작업 5개, 변화가 하나씩 (A1이 가장 이르고 A5가 가장 최근) */
    async function five() {
      const user = await f.user();
      const actions: string[] = [];
      const events: string[] = [];
      for (let i = 1; i <= 5; i++) {
        const action = await f.action(user, { title: `일 ${i}` });
        actions.push(action);
        events.push(await f.event(user, action, "merged", "ai", at(T0, i * 1000)));
      }
      return { user, actions, events, [Symbol.iterator]: undefined };
    }
    const HZ = at(T0, 100_000);
    const readRefs = async (user: string) => new Set((await q(`select event_ref from public.return_summary_reads where user_id = $1`, [user])).map((r) => r.event_ref as string));
    /** (사건, 작업) 쌍 */
    const readPairs = async (user: string) => new Set((await q(`select event_ref || ':' || action_id as pair from public.return_summary_reads where user_id = $1`, [user])).map((r) => r.pair as string));

    it("limit을 넘으면 truncated + page(보인 작업, 가장 최근 변화 순)를 싣는다. 잘리지 않으면 page는 null", async () => {
      const { user, actions } = await five();
      const scan = await f.scan(user, HZ, 3);
      expect(scan.truncated).toBe(true);
      expect(scan.page).toEqual([actions[4], actions[3], actions[2]]);
      expect(scan.works.map((w) => w.action_id)).toEqual(scan.page);
      expect(scan.baseline).toBe(true);
      const full = await f.scan(user, HZ, 5);
      expect(full).toMatchObject({ truncated: false, page: null });
      expect(full.works).toHaveLength(5);
    });

    it("Clear는 보인 작업의 사건만 읽음 처리한다: 보이지 않은 작업은 읽음이 아니고 다음 조회에 나온다. 마지막 페이지(잘리지 않음)는 남은 것을 모두", async () => {
      const { user, actions, events } = await five();
      const first = await f.scan(user, HZ, 3);
      expect(await f.clear(user, first, at(T0, 200_000))).toMatchObject({ status: "cleared", applied: true });
      expect(await readRefs(user)).toEqual(new Set([events[4], events[3], events[2]]));
      const second = await f.scan(user, at(T0, 300_000), 3);
      expect(second).toMatchObject({ truncated: false, page: null, since: HZ });
      expect(second.works.map((w) => w.action_id)).toEqual([actions[1], actions[0]]);
      expect(await f.clear(user, second, at(T0, 400_000))).toMatchObject({ status: "cleared", applied: true });
      expect(await readRefs(user)).toEqual(new Set(events));
      expect((await f.scan(user, at(T0, 500_000), 3)).works).toEqual([]);
    });

    it("재시도(응답 유실) · 두 기기: 같은 커서를 다시 보내도 성공이지만 쓰기는 없다. 다른 기기가 다음 페이지를 읽은 뒤 옛 커서를 보내도 마찬가지", async () => {
      const { user, events } = await five();
      const cursor = await f.scan(user, HZ, 3);
      const other = await f.scan(user, HZ, 3); // 두 번째 기기가 같은 페이지를 받았다
      expect((await f.clear(user, cursor, at(T0, 200_000))).applied).toBe(true);
      expect(await f.clear(user, cursor, at(T0, 200_000))).toMatchObject({ status: "cleared", applied: false }); // 재시도
      expect(await f.clear(user, other, at(T0, 200_000))).toMatchObject({ status: "cleared", applied: false }); // 두 번째 기기
      const next = await f.scan(user, at(T0, 300_000), 3); // 다음 페이지
      expect((await f.clear(user, next, at(T0, 400_000))).applied).toBe(true);
      expect(await f.clear(user, cursor, at(T0, 400_000))).toMatchObject({ status: "cleared", applied: false }); // 옛 페이지 커서를 한참 뒤에
      expect((await readRefs(user)).size).toBe(events.length);
    });

    it("보인 작업에 늦게 commit된 사건(지평 이전 시각)이 조회 뒤 Clear 전에 보이면 stale (아무것도 쓰지 않는다). 보이지 않은 작업의 늦은 사건은 영향이 없다 — 읽음도 안 되고 stale도 아니다", async () => {
      const { user, actions } = await five();
      const cursor = await f.scan(user, HZ, 3);
      await f.event(user, actions[4], "reopened", "ai", at(T0, 500)); // 보인 작업(일 5)에 늦게 들어옴
      expect(await f.clear(user, cursor, at(T0, 200_000))).toEqual({ status: "stale" });
      expect((await readRefs(user)).size).toBe(0);
      const again = await f.scan(user, HZ, 3);
      expect(again.works[0].changes.map((c) => c.kind)).toEqual(["reopened", "merged"]);
      // 이제 보이지 않은 작업(일 1)에 늦은 사건: 범위 밖이라 stale이 아니고, 읽음도 되지 않아 다음 조회에 나온다
      await f.event(user, actions[0], "scope_changed", "ai", at(T0, 600));
      expect((await f.clear(user, again, at(T0, 200_000))).status).toBe("cleared");
      const next = await f.scan(user, at(T0, 300_000), 3);
      expect(next.works.find((w) => w.action_id === actions[0])!.changes.map((c) => c.kind)).toEqual(["scope_changed", "merged"]);
    });

    it("보인 작업이 조회 뒤 지워지면 stale이고, 다시 조회하면 Clear할 수 있다 (영구히 잠기지 않는다)", async () => {
      const { user, actions } = await five();
      const cursor = await f.scan(user, HZ, 3);
      await q(`delete from public.actions where id = $1`, [actions[3]]);
      expect(await f.clear(user, cursor, at(T0, 200_000))).toEqual({ status: "stale" });
      const again = await f.scan(user, at(T0, 300_000), 3);
      expect(again.page).toEqual([actions[4], actions[2], actions[1]]);
      expect((await f.clear(user, again, at(T0, 400_000))).status).toBe("cleared");
    });

    it("첫 Clear(baseline)가 잘린 조회여도 보이지 않은 작업의 run · 대화 이력은 기준으로 삼는다 — 이력이 새 변화로 되살아나지 않는다. 그 뒤에 생긴 결과는 새 변화", async () => {
      const { user, actions } = await five();
      await f.setClock("2026-10-12T00:00:00.000500Z");
      const oldRun = await f.run(user, actions[0]); // 일 1: 보이지 않는 작업
      await f.setRun(oldRun, "failed");
      const conversation = await f.conversation(user, null);
      await f.message(user, conversation, 1, "assistant", { action_ids: [actions[1]] }, at(T0, 700));
      const first = await f.scan(user, HZ, 3);
      expect(first.truncated).toBe(true);
      expect(first.baseline).toBe(true);
      expect((await f.clear(user, first, at(T0, 200_000))).status).toBe("cleared");
      const second = await f.scan(user, at(T0, 300_000), 3);
      // 보이지 않던 작업(일 1 · 일 2)은 변화 하나씩(AI 변화)만 나온다: 옛 run 결과 · 옛 메시지는 기준이다
      expect(second.works.map((w) => [w.action_id, w.changes.map((c) => `${c.source}:${c.kind}`)])).toEqual([
        [actions[1], ["action_event:merged"]],
        [actions[0], ["action_event:merged"]],
      ]);
      // 기준 뒤에 도착한 run 결과는 새 변화다
      await f.setClock("2026-10-12T00:03:00Z");
      await f.setRun(await f.run(user, actions[0]), "done", "draft_ready");
      const third = await f.scan(user, "2026-10-12T00:04:00Z", 3);
      expect(third.works.find((w) => w.action_id === actions[0])!.changes.map((c) => `${c.source}:${c.kind}`)).toEqual(["action_event:merged", "run:done"]);
    });

    it("한 메시지가 보인 작업과 보이지 않은 작업을 함께 가리키면 (사건, 작업) 쌍마다 따로 읽는다: 보인 작업의 쌍만 읽음이고, 보이지 않은 작업의 쌍은 안 읽음으로 남아 다음 페이지에 나온다", async () => {
      const { user, actions } = await five();
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0, 50)]);
      const conversation = await f.conversation(user, null);
      // 메시지 시각을 이르게 둬서 순위(가장 최근 변화 순)를 바꾸지 않는다: 보이는 작업 = 일 5 · 일 4 · 일 3
      const shared = await f.message(user, conversation, 1, "assistant", { action_ids: [actions[4], actions[0]] }, at(T0, 500));
      const solo = await f.message(user, conversation, 2, "assistant", { action_ids: [actions[3]] }, at(T0, 600));
      const cursor = await f.scan(user, HZ, 3);
      expect(cursor.page).toEqual([actions[4], actions[3], actions[2]]);
      expect((await f.clear(user, cursor, at(T0, 200_000))).status).toBe("cleared");
      const pairs = await readPairs(user);
      expect(pairs.has(`${solo}:${actions[3]}`)).toBe(true);
      expect(pairs.has(`${shared}:${actions[4]}`)).toBe(true); // 보인 작업에 대해서는 읽음
      expect(pairs.has(`${shared}:${actions[0]}`)).toBe(false); // 보이지 않은 작업에게는 안 읽음
      const next = await f.scan(user, at(T0, 300_000), 3);
      // 보이던 작업(일 5)에는 더 이상 그 메시지가 없고, 보이지 않던 작업(일 1)에는 AI 변화와 함께 메시지가 남아 있다
      expect(next.works.map((w) => w.action_id)).toEqual([actions[1], actions[0]]);
      expect(next.works[1].changes.map((c) => `${c.source}:${c.kind}`).sort()).toEqual(["action_event:merged", "message:assistant"]);
      expect((await f.clear(user, next, at(T0, 400_000))).status).toBe("cleared");
      expect((await f.scan(user, at(T0, 500_000), 3)).works).toEqual([]);
    });

    it("공유 사건으로 페이지가 멈추지 않는다: 허브 작업 하나를 모든 메시지가 가리키고 허브의 순위가 맨 뒤여도 조회 → Clear를 되풀이하면 정해진 횟수 안에 모두 읽음이 된다", async () => {
      const user = await f.user();
      const hub = "ffffffff-ffff-4fff-bfff-ffffffffffff"; // 순위 동률에서 작업 id 순으로 가장 뒤
      await q(`insert into public.actions (id, user_id, title) values ($1, $2, '허브')`, [hub, user]);
      const leaves: string[] = [];
      for (let i = 0; i < 7; i++) leaves.push(await f.action(user, { title: `잎 ${i}` }));
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0, 1)]);
      const conversation = await f.conversation(user, null);
      for (let i = 0; i < leaves.length; i++) await f.message(user, conversation, i + 1, "assistant", { action_ids: [hub, leaves[i]] }, at(T0, 1000));
      let rounds = 0;
      for (; rounds < 5; rounds++) {
        const scan = await f.scan(user, at(T0, 100_000 + rounds * 1000), 7); // 보이는 작업 7개 = 잎 7개, 허브는 8번째
        if (scan.works.length === 0) break;
        expect(scan.page === null || !scan.page.includes(hub) || scan.page.length <= 7).toBe(true);
        expect((await f.clear(user, scan, at(T0, 200_000 + rounds * 1000))).status).toBe("cleared");
        // 보이지 않은 작업의 쌍은 읽음이 아니다
        if (scan.truncated) expect((await readPairs(user)).size).toBeLessThan(leaves.length * 2);
      }
      expect(rounds).toBe(2); // 잎 한 번, 허브 한 번
      expect((await readPairs(user)).size).toBe(leaves.length * 2);
      // 대조: limit이 작업 수 이상이면 한 번에 모두 읽는다
      const control = await f.user();
      const hub2 = randomUUID();
      await q(`insert into public.actions (id, user_id, title) values ($1, $2, '허브')`, [hub2, control]);
      const leaves2: string[] = [];
      for (let i = 0; i < 7; i++) leaves2.push(await f.action(control, { title: `잎 ${i}` }));
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [control, at(T0, 1)]);
      const conversation2 = await f.conversation(control, null);
      for (let i = 0; i < leaves2.length; i++) await f.message(control, conversation2, i + 1, "assistant", { action_ids: [hub2, leaves2[i]] }, at(T0, 1000));
      const all = await f.scan(control, at(T0, 100_000), 8);
      expect(all).toMatchObject({ truncated: false, page: null });
      expect((await f.clear(control, all, at(T0, 200_000))).status).toBe("cleared");
      expect((await readPairs(control)).size).toBe(leaves2.length * 2);
      expect((await f.scan(control, at(T0, 300_000), 8)).works).toEqual([]);
    });

    it("꾸민 커서: 남의 작업 id · 너무 많은 id · 다른 작업 집합은 아무것도 읽음 처리하지 못한다 (stale · invalid)", async () => {
      const { user, actions } = await five();
      const other = await f.user();
      const cursor = await f.scan(user, HZ, 3);
      expect((await f.clear(other, cursor, at(T0, 200_000))).status).toBe("stale"); // 남이 쓴 커서: 그 사용자의 범위로 다시 세면 digest가 다르다
      const swapped = { ...cursor, page: [actions[0], actions[1], actions[2]] }; // 다른 작업 집합 (digest는 그대로)
      expect((await f.clear(user, swapped, at(T0, 200_000))).status).toBe("stale");
      const tooMany = Array.from({ length: 1001 }, () => randomUUID());
      expect((await f.clear(user, { ...cursor, page: tooMany }, at(T0, 200_000))).status).toBe("invalid");
      expect((await readRefs(user)).size).toBe(0);
      expect((await f.clear(user, cursor, at(T0, 200_000))).status).toBe("cleared");
    });

    it("순위는 결정적이다: 변화 시각이 같은 작업은 작업 id 순. 같은 조회를 두 번 해도 같은 페이지", async () => {
      const user = await f.user();
      const actions: string[] = [];
      for (let i = 0; i < 4; i++) {
        const action = await f.action(user);
        actions.push(action);
        await f.event(user, action, "merged", "ai", at(T0, 1000));
      }
      const [one, two] = [await f.scan(user, HZ, 2), await f.scan(user, HZ, 2)];
      expect(one.page).toEqual(two.page);
      expect(one.page).toEqual([...actions].sort().slice(0, 2));
    });

    it("본 작업(사용자가 같은 밀리초 이후에 손댄 작업)은 순위에 들지 않는다: 안 읽은 작업만으로 페이지가 찬다 (본 작업 때문에 빈 잘린 페이지가 생기지 않는다)", async () => {
      const user = await f.user();
      const seen: string[] = [];
      const unread: string[] = [];
      for (let i = 0; i < 4; i++) {
        const action = await f.action(user);
        await f.event(user, action, "merged", "ai", at(T0, 100_000 + i * 1000));
        await f.event(user, action, "user_seen", "user", at(T0, 200_000 + i * 1000)); // 변화보다 뒤에 봤다
        seen.push(action);
      }
      for (let i = 0; i < 3; i++) {
        const action = await f.action(user);
        await f.event(user, action, "merged", "ai", at(T0, 1000 + i * 1000));
        unread.push(action);
      }
      const scan = await f.scan(user, at(T0, 1_000_000), 2);
      expect(scan.truncated).toBe(true);
      expect(scan.page!.every((id) => unread.includes(id))).toBe(true);
      expect(scan.works).toHaveLength(2);
    });
  });
  });

  // ───────────────────────── 첫 정상 표시 기준점 (A–D 승인, C) ─────────────────────────
  describe("첫 정상 표시 기준점 (return_summary_baseline_init): 서버 토큰의 별도 확정 쓰기로만 생긴다 (GET은 읽기만)", () => {
    const HZ = at(T0, 500_000);
    const LATER = at(T0, 600_000);

    /** 첫 사용: 지평 전 run 결과 하나 + 읽은 시각이 없는 대화 메시지 하나(같은 작업), 미열람 Action 변화 하나(다른 작업). Clear한 적도 기준점도 없다 */
    async function first() {
      const user = await f.user();
      const action = await f.action(user, { title: "초안" });
      const other = await f.action(user, { title: "견적" });
      await f.setClock(at(T0, 10_000));
      const run = await f.run(user, action);
      await f.setClock(at(T0, 20_000));
      await f.setRun(run, "running");
      await f.setRun(run, "done", "draft_ready");
      await f.setClock("2026-10-12T00:00:00Z");
      const conversation = await f.conversation(user, null);
      await f.message(user, conversation, 1, "assistant", { action_ids: [action] }, at(T0, 30_000));
      await f.event(user, other, "due_changed", "ai", at(T0, 40_000));
      return { user, action, other, conversation, run };
    }
    const kinds = (scan: ScanResult, action: string) => scan.works.find((w) => w.action_id === action)?.changes.map((c) => `${c.source}:${c.kind}`).sort() ?? null;

    it("첫 조회: never_cleared + init_digest(기준점 범위의 digest). 읽기만이다 — 읽음 · 기준점이 쓰이지 않는다. 옛 run · 메시지는 변화가 아니고 Action 변화는 보인다", async () => {
      const { user, action, other } = await first();
      const scan = await f.scan(user, HZ);
      expect(scan).toMatchObject({ baseline: true, baseline_state: "never_cleared", since: null, truncated: false });
      expect(typeof scan.init_digest).toBe("string");
      expect(kinds(scan, other)).toEqual(["action_event:due_changed"]);
      expect(kinds(scan, action)).toBeNull();
      await f.scan(user, HZ); // 몇 번을 읽어도 같다
      expect(await f.reads(user)).toBe(0);
      expect(await f.baselineRows(user)).toBe(0);
      expect(await f.state(user)).toBeUndefined();
    });

    it("확정: initialized. 그때까지의 run · 메시지 쌍만 읽음이고(Action 변화 · 미결정은 그대로) 기준점 행이 토큰의 지평으로 한 줄 생긴다. 업무 · 실행 표는 그대로", async () => {
      const { user, other } = await first();
      const scan = await f.scan(user, HZ);
      const before = await f.fingerprint(user);
      expect(await f.init(user, scan, LATER)).toEqual({ status: "initialized" });
      expect(await f.fingerprint(user)).toBe(before);
      expect((await q(`select source from public.return_summary_reads where user_id = $1 order by 1`, [user])).map((r) => r.source)).toEqual(["message", "run_event"]);
      expect(await f.baselineRows(user)).toBe(1);
      expect(await f.baselineHorizon(user)).toBe(scan.horizon);
      expect(await f.state(user)).toBeUndefined(); // Clear 위치는 만들지 않는다
      const after = await f.scan(user, LATER);
      expect(after).toMatchObject({ baseline: false, baseline_state: "initialized", init_digest: null, since: null });
      expect(kinds(after, other)).toEqual(["action_event:due_changed"]);
    });

    it("기준점 뒤에는 Clear 없이도 새 run 결과 · 새 메시지가 변화로 오른다. 옛 이력은 계속 과거다", async () => {
      const { user, action, conversation, run } = await first();
      const scan = await f.scan(user, HZ);
      expect((await f.init(user, scan, LATER)).status).toBe("initialized");
      const second = await f.run(user, action);
      await f.setClock(at(T0, 700_000));
      await f.setRun(second, "running");
      await f.setRun(second, "done", "needs_input");
      await f.setClock("2026-10-12T00:00:00Z");
      await f.message(user, conversation, 2, "event", { action_ids: [action] }, at(T0, 710_000));
      const later = await f.scan(user, at(T0, 800_000));
      expect(kinds(later, action)).toEqual(["message:event", "run:done"]);
      expect(later.works.find((w) => w.action_id === action)!.changes.filter((c) => c.source === "run")).toHaveLength(1); // 옛 run(done)은 계속 읽음
      expect(run).not.toBe(second);
      expect(await f.state(user)).toBeUndefined();
    });

    it("빈 첫 화면도 init_digest가 있고 확정되면 기준점이 생긴다 (읽음 쌍은 0)", async () => {
      const user = await f.user();
      const scan = await f.scan(user, HZ);
      expect(scan).toMatchObject({ works: [], baseline_state: "never_cleared" });
      expect(typeof scan.init_digest).toBe("string");
      expect(await f.init(user, scan, LATER)).toEqual({ status: "initialized" });
      expect(await f.reads(user)).toBe(0);
      expect(await f.baselineRows(user)).toBe(1);
    });

    it("같은 토큰 재시도 · 두 기기: 두 번째는 already_initialized이고 아무것도 쓰지 않는다 (읽음 쌍 · 기준점 행 그대로)", async () => {
      const { user } = await first();
      const scan = await f.scan(user, HZ);
      expect(await f.init(user, scan, LATER)).toEqual({ status: "initialized" });
      const reads = await f.reads(user);
      const horizon = await f.baselineHorizon(user);
      expect(await f.init(user, scan, at(T0, 650_000))).toEqual({ status: "already_initialized" });
      expect(await f.init(user, { ...scan, init_digest: "a:0:0|r:9:9|m:9:9" }, at(T0, 650_000))).toEqual({ status: "already_initialized" }); // 다른 기기의 낡은 토큰도 같다
      expect(await f.reads(user)).toBe(reads);
      expect(await f.baselineHorizon(user)).toBe(horizon);
    });

    it("Clear한 적이 있는 사용자(업그레이드 이전 Clear 사용자 포함)는 cleared로 센다: 토큰이 없고, 확정은 already_initialized이며 아무것도 쓰지 않는다", async () => {
      const { user, action } = await first();
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0, 1)]);
      const scan = await f.scan(user, HZ);
      expect(scan).toMatchObject({ baseline: false, baseline_state: "cleared", init_digest: null, since: at(T0, 1) });
      expect(kinds(scan, action)).toEqual(["message:assistant", "run:done"]); // 이 사용자는 Clear 기준이 이미 있어 이력이 변화로 오른다 (기존 동작 그대로)
      expect(await f.init(user, { horizon: HZ, init_digest: "r:0:0" }, LATER)).toEqual({ status: "already_initialized" });
      expect(await f.reads(user)).toBe(0);
      expect(await f.baselineRows(user)).toBe(0);
    });

    it("기준점 전 Clear는 기준점이 아니라 Clear다: 그때의 읽음 처리는 기존 규칙(보인 작업 + 이력)이고, 그 뒤 확정은 already_initialized", async () => {
      const { user, action, other } = await first();
      const scan = await f.scan(user, HZ);
      expect((await f.clear(user, scan, LATER)).status).toBe("cleared");
      expect(await f.baselineRows(user)).toBe(0);
      expect((await f.init(user, scan, LATER)).status).toBe("already_initialized");
      const after = await f.scan(user, at(T0, 700_000));
      expect(after).toMatchObject({ baseline_state: "cleared", init_digest: null });
      expect(after.works).toEqual([]);
      expect(action).not.toBe(other);
    });

    it("기준점 뒤 Clear는 기준점 이력을 다시 다루지 않는다: 조회의 baseline 표시가 꺼져 있고, 잘린 페이지의 Clear는 보인 작업의 쌍만 읽음으로 더한다", async () => {
      const { user, action, conversation } = await first();
      const scan = await f.scan(user, HZ);
      expect((await f.init(user, scan, LATER)).status).toBe("initialized");
      const base = await f.reads(user);
      // 기준점 뒤 새 메시지 두 작업 (limit 1 → 잘림)
      const second = await f.action(user, { title: "둘째" });
      await f.message(user, conversation, 2, "assistant", { action_ids: [second] }, at(T0, 700_000));
      await f.message(user, conversation, 3, "assistant", { action_ids: [action] }, at(T0, 710_000));
      const page = await f.scan(user, at(T0, 800_000), 1);
      expect(page).toMatchObject({ truncated: true, baseline: false });
      expect(page.page).toHaveLength(1);
      expect((await f.clear(user, page, at(T0, 900_000))).status).toBe("cleared");
      expect(await f.reads(user)).toBe(base + 1); // 보인 작업의 새 메시지 한 쌍뿐 (run · 옛 이력을 다시 읽음 처리하지 않는다)
      const rest = await f.scan(user, at(T0, 1_000_000), 1);
      expect(rest.works).toHaveLength(1); // 보이지 않은 작업은 그대로 남아 있다
    });

    it("조회 뒤 확정 전에 범위 안 사건이 commit되면(트랜잭션 시작 시각이 지평 이전) stale: 아무것도 쓰지 않는다. 다시 조회하면 새 토큰으로 확정되고 그 사건도 읽음이다", async () => {
      const { user, action, conversation } = await first();
      const scan = await f.scan(user, HZ);
      await f.message(user, conversation, 2, "assistant", { action_ids: [action] }, at(T0, 25_000)); // 늦게 commit된 행
      expect(await f.init(user, scan, LATER)).toEqual({ status: "stale" });
      expect(await f.reads(user)).toBe(0);
      expect(await f.baselineRows(user)).toBe(0);
      const again = await f.scan(user, HZ);
      expect(again.init_digest).not.toBe(scan.init_digest);
      expect(await f.init(user, again, LATER)).toEqual({ status: "initialized" });
      expect(await f.reads(user)).toBe(3);
    });

    it("같은 시각 tie: 지평과 정확히 같은 시각의 범위 안 사건은 stale. 지평 +1µs는 범위 밖이라 확정은 되고 기준점 뒤 새 변화로 보인다", async () => {
      const { user, action, conversation } = await first();
      const scan = await f.scan(user, HZ);
      await f.message(user, conversation, 2, "assistant", { action_ids: [action] }, HZ);
      expect((await f.init(user, scan, LATER)).status).toBe("stale");
      const control = await first();
      const controlScan = await f.scan(control.user, HZ);
      await f.message(control.user, control.conversation, 2, "assistant", { action_ids: [control.action] }, at(HZ, 1));
      expect((await f.init(control.user, controlScan, LATER)).status).toBe("initialized");
      const after = await f.scan(control.user, at(T0, 700_000));
      expect(kinds(after, control.action)).toEqual(["message:assistant"]);
    });

    it("범위 안 사건이 지워져도(Action 삭제) stale이다. 다시 조회하면 확정되고 지운 쌍은 되살아나지 않는다", async () => {
      const { user, action } = await first();
      const scan = await f.scan(user, HZ);
      await q(`delete from public.actions where id = $1`, [action]);
      expect((await f.init(user, scan, LATER)).status).toBe("stale");
      const again = await f.scan(user, HZ);
      expect((await f.init(user, again, LATER)).status).toBe("initialized");
      expect(await f.reads(user)).toBe(0);
    });

    it("지평이 서버 시각보다 미래면 invalid, 꾸민 digest · 다른 사용자의 토큰은 stale이다: 어느 쪽도 아무것도 쓰지 않는다", async () => {
      const { user } = await first();
      const other = await f.user();
      const scan = await f.scan(user, HZ);
      expect((await f.init(user, { horizon: at(T0, 900_000), init_digest: scan.init_digest }, LATER)).status).toBe("invalid");
      expect((await f.init(user, { ...scan, init_digest: "a:0:0|r:9:9|m:9:9" }, LATER)).status).toBe("stale");
      expect((await f.init(other, scan, LATER)).status).toBe("stale"); // 남의 토큰: 그 사용자의 범위로 다시 세면 digest가 다르다
      expect(await f.reads(user)).toBe(0);
      expect(await f.reads(other)).toBe(0);
      expect(await f.baselineRows(user)).toBe(0);
      expect(await f.baselineRows(other)).toBe(0);
    });

    it("앱은 자기 기준점 행만 읽고(owner_all + select) 쓰지 못한다. 서버도 한 번 정한 기준점을 바꾸지 못한다 (트리거)", async () => {
      const [alice, bob] = [await f.user(), await f.user()];
      await q(`insert into public.return_summary_baseline (user_id, horizon) values ($1, now()), ($2, now())`, [alice, bob]);
      expect((await db().asUser(alice, () => q(`select user_id from public.return_summary_baseline`))).map((r) => r.user_id)).toEqual([alice]);
      await db().asUser(alice, async () => {
        await rejects(q(`insert into public.return_summary_baseline (user_id, horizon) values ($1, now())`, [randomUUID()]), /permission denied/);
        await rejects(q(`update public.return_summary_baseline set horizon = now()`), /permission denied/);
        await rejects(q(`delete from public.return_summary_baseline`), /permission denied/);
      });
      await rejects(q(`update public.return_summary_baseline set horizon = now() where user_id = $1`, [alice]), /한 번 정해지면|check_violation/);
      await q(`delete from auth.users where id = $1`, [alice]); // 계정 삭제는 cascade
      expect(await f.baselineRows(alice)).toBe(0);
      expect(await f.baselineRows(bob)).toBe(1);
    });
  });
}

// ───────────────────────── 업그레이드 · 롤백 ─────────────────────────
const MIGRATIONS_DIR = path.resolve(__dirname, "../../supabase/migrations");
export const C3_MIGRATION = "20261111000000_review_summary.sql";
/** 후속(A–D 승인, C): 첫 정상 표시 기준점. C3 바로 다음 마이그레이션이다 (더 뒤의 마이그레이션이 있어도 이 시험은 C3 · 기준점만 적용한다) */
export const BASELINE_MIGRATION = "20261112000000_review_summary_baseline.sql";

export type FreshDb = {
  exec: (sql: string) => Promise<unknown>;
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
};

/** Supabase 흉내 + C3 앞의 모든 마이그레이션 / C3 / 기준점 마이그레이션 */
async function splitScripts() {
  const files = (await readdir(MIGRATIONS_DIR)).filter((file) => file.endsWith(".sql")).sort();
  const index = files.indexOf(C3_MIGRATION);
  expect(index, `${C3_MIGRATION}이 마이그레이션 목록에 있다`).toBeGreaterThan(0);
  expect(files.indexOf(BASELINE_MIGRATION), "기준점 마이그레이션은 C3 바로 다음이다").toBe(index + 1);
  const scripts = await supabaseSchemaScripts();
  return { before: scripts.slice(0, 2 + index), c3: scripts[2 + index], baseline: scripts[3 + index] };
}

/** 이 마이그레이션 앞의 객체 지문: public 표 · 열 · 함수 정의 · 트리거 · 제약 */
async function schemaFingerprint(db: FreshDb): Promise<Record<string, string>> {
  const one = async (sql: string) => JSON.stringify(await db.query(sql));
  return {
    tables: await one(`select table_name from information_schema.tables where table_schema = 'public' order by table_name`),
    columns: await one(`select table_name, column_name, data_type, is_nullable, column_default from information_schema.columns where table_schema = 'public' order by table_name, ordinal_position`),
    functions: await one(`select p.oid::regprocedure::text as sig, md5(pg_get_functiondef(p.oid)) as def from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' order by 1`),
    triggers: await one(`select c.relname, t.tgname, md5(pg_get_triggerdef(t.oid)) as def from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and not t.tgisinternal order by 1, 2`),
    constraints: await one(`select conrelid::regclass::text as tbl, conname, md5(pg_get_constraintdef(oid)) as def from pg_constraint where connamespace = 'public'::regnamespace order by 1, 2`),
  };
}

/**
 * 새 마이그레이션 전 상태에서 옛 행을 쌓고 적용한 뒤에도 옛 행 · 옛 객체가 그대로인지(additive), 헤더의 되돌리기 문장을 그대로 실행하면 적용 전 객체 지문으로 돌아가는지,
 * 같은 이름의 객체가 이미 있으면 아무것도 바꾸지 않고 실패하는지(한 트랜잭션 롤백)를 본다.
 */
export function reviewSummaryUpgradeTests(fresh: () => Promise<FreshDb>) {
  // 새 데이터베이스에 마이그레이션 수십 개를 적용하는 시험이라 느린 머신에서도 5초 기본 제한에 걸리지 않게 한다
  describe("업그레이드 · 되돌리기 회귀 (C3 전 상태 → 적용 → 되돌리기)", { timeout: 60_000 }, () => {
    async function seedLegacy(db: FreshDb) {
      const alice = randomUUID();
      await db.query(`insert into auth.users (id, email) values ($1, $2)`, [alice, `${alice}@example.com`]);
      const action = (await db.query(`insert into public.actions (user_id, title, due_at) values ($1, '제안서', now() + interval '3 hours') returning id`, [alice]))[0].id as string;
      await db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'due_changed', 'ai'), ($1, $2, 'user_seen', 'user')`, [alice, action]);
      const run = (await db.query(`select public.create_run($1, $2, 'draft', '초안') as id`, [alice, action]))[0].id as string;
      await db.query(`update public.execution_runs set state = 'failed' where id = $1`, [run]);
      const conversation = (await db.query(`insert into public.conversations (user_id) values ($1) returning id`, [alice]))[0].id as string;
      await db.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs) values ($1, $2, 1, 'assistant', '답', $3)`, [alice, conversation, JSON.stringify({ action_ids: [action] })]);
      await db.query(`insert into public.inbox_events (user_id, type, dedup_key, refs) values ($1, 'source_revised', 'source:x', $2)`, [alice, JSON.stringify({ run_id: run })]);
      return { alice, action, run };
    }
    const legacySnapshot = async (db: FreshDb) =>
      JSON.stringify(
        await Promise.all(
          ["actions", "action_events", "execution_runs", "execution_events", "conversations", "conversation_messages", "inbox_events"].map((t) =>
            db.query(`select to_jsonb(x) as row from public.${t} x order by 1`),
          ),
        ),
      );

    it("옛 행이 그대로이고 옛 객체(표 · 열 · 함수 정의 · 트리거 · 제약)는 한 글자도 안 바뀌며, 새 표는 비어 있다", async () => {
      const { before, c3 } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      const { alice } = await seedLegacy(db);
      const rows = await legacySnapshot(db);
      const objects = await schemaFingerprint(db);
      await db.exec(c3);
      expect(await legacySnapshot(db)).toBe(rows);
      const after = await schemaFingerprint(db);
      // 옛 객체는 모두 그대로 남아 있다: 새 객체만 늘었다
      const old = <T>(json: string) => JSON.parse(json) as T[];
      expect(old<{ table_name: string }>(after.tables).map((r) => r.table_name)).toEqual(
        expect.arrayContaining(old<{ table_name: string }>(objects.tables).map((r) => r.table_name)),
      );
      for (const key of ["functions", "triggers", "constraints"] as const) {
        const kept = new Set(old<Record<string, string>>(after[key]).map((r) => JSON.stringify(r)));
        for (const row of old<Record<string, string>>(objects[key])) expect(kept.has(JSON.stringify(row)), `${key}: ${JSON.stringify(row)}`).toBe(true);
      }
      const addedTables = old<{ table_name: string }>(after.tables).map((r) => r.table_name).filter((t) => !old<{ table_name: string }>(objects.tables).map((r) => r.table_name).includes(t));
      expect(addedTables).toEqual(["return_summary_reads", "return_summary_state", "suggestions"]);
      // 옛 열은 하나도 바뀌지 않았다 (새 표의 열만 늘었다)
      const oldColumns = new Set(old<Record<string, string>>(objects.columns).map((r) => JSON.stringify(r)));
      const oldTables = new Set(old<{ table_name: string }>(objects.tables).map((r) => r.table_name));
      const keptColumns = old<Record<string, string>>(after.columns).filter((r) => oldTables.has(r.table_name)).map((r) => JSON.stringify(r));
      expect(keptColumns.sort()).toEqual([...oldColumns].sort());
      for (const t of addedTables) expect(await db.query(`select 1 from public.${t}`)).toEqual([]);
      // 옛 데이터로 새 기능이 돈다: 읽기와 Clear
      const scan = (await db.query(`select public.return_summary_scan($1, $2::text[], null, 300) as r`, [alice, CHANGE_TYPES]))[0].r as ScanResult;
      // 같은 트랜잭션에서 쓴 AI 변화와 user_seen: 시각이 같으면 본 것이다 (changed.ts)
      expect(scan.works).toHaveLength(0);
      expect((await db.query(`select public.suggestions_produce($1, now(), 24, false) as n`, [alice]))[0].n).toBe(2); // 기한 임박 · 실패한 run
    });

    it("헤더에 적힌 되돌리기 문장을 그대로 실행하면 적용 전 객체 지문으로 돌아가고 옛 행은 그대로다", async () => {
      const { before, c3 } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      await seedLegacy(db);
      const objects = await schemaFingerprint(db);
      const rows = await legacySnapshot(db);
      await db.exec(c3);
      const header = c3.split("\nbegin;")[0];
      const drops = header.split("\n").filter((l) => /^--\s+drop /.test(l)).map((l) => l.replace(/^--\s+/, ""));
      expect(drops).toHaveLength(3);
      for (const sql of drops) await db.exec(sql);
      expect(await schemaFingerprint(db)).toEqual(objects);
      expect(await legacySnapshot(db)).toBe(rows);
    });

    it("같은 이름의 객체가 이미 있으면 마이그레이션은 아무것도 바꾸지 않고 실패한다 (한 트랜잭션 롤백)", async () => {
      const { before, c3 } = await splitScripts();
      const db = await fresh();
      for (const sql of before) await db.exec(sql);
      // 파일 끝쪽 함수와 같은 서명: 앞의 표 · 제약 · 함수를 다 만든 뒤에 실패한다 → 모두 되돌려져야 한다
      await db.exec(`create function public.return_summary_clear(p_user_id uuid, p_types text[], p_horizon timestamptz, p_digest text, p_now timestamptz, p_ids uuid[], p_b boolean) returns int language sql as 'select 1'`);
      const objects = await schemaFingerprint(db);
      await expect(db.exec(c3)).rejects.toThrow(/already exists|이미 있/);
      await db.exec("rollback");
      expect(await schemaFingerprint(db)).toEqual(objects);
      expect(await db.query(`select 1 from information_schema.tables where table_name in ('suggestions', 'return_summary_state', 'return_summary_reads')`)).toEqual([]);
    });
  });

  // ─── 기준점 마이그레이션 (C3 뒤): 11까지 쌓인 행(이미 Clear한 사용자 포함)과 옛 객체는 그대로, 되돌리면 11 상태로 ───
  describe("업그레이드 · 되돌리기 회귀 (기준점 마이그레이션: C3 적용 후 상태 → 적용 → 되돌리기)", { timeout: 60_000 }, () => {
    const scanOf = async (db: FreshDb, user: string, horizon: string) =>
      (await db.query(`select public.return_summary_scan($1, $2::text[], $3::timestamptz, 300) as r`, [user, CHANGE_TYPES, horizon]))[0].r as Record<string, unknown>;

    /** 11까지 적용한 상태: 한 번도 Clear하지 않은 사용자(alice)와 업그레이드 이전에 Clear한 사용자(bob) */
    async function seedAfterC3(db: FreshDb) {
      const mk = async (title: string) => {
        const user = randomUUID();
        await db.query(`insert into auth.users (id, email) values ($1, $2)`, [user, `${user}@example.com`]);
        const action = (await db.query(`insert into public.actions (user_id, title) values ($1, $2) returning id`, [user, title]))[0].id as string;
        await db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'due_changed', 'ai')`, [user, action]);
        const run = (await db.query(`select public.create_run($1, $2, 'draft', '초안') as id`, [user, action]))[0].id as string;
        await db.query(`update public.execution_runs set state = 'running' where id = $1`, [run]);
        await db.query(`update public.execution_runs set state = 'done', outcome = 'draft_ready' where id = $1`, [run]);
        const conversation = (await db.query(`insert into public.conversations (user_id) values ($1) returning id`, [user]))[0].id as string;
        await db.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs) values ($1, $2, 1, 'assistant', '답', $3)`, [user, conversation, JSON.stringify({ action_ids: [action] })]);
        return { user, action };
      };
      const alice = await mk("미확인");
      const bob = await mk("확인함");
      await new Promise((resolve) => setTimeout(resolve, 20));
      const horizon = new Date().toISOString(); // 모든 옛 행(트랜잭션 시작 시각)보다 뒤이고 서버 시각보다 앞이다
      // bob은 11의 Clear를 한 번 했다 (상태 + 읽음 쌍)
      const scan = await scanOf(db, bob.user, horizon);
      const cleared = (
        await db.query(`select public.return_summary_clear($1, $2::text[], $3::timestamptz, $4, null, $5::uuid[], $6) as r`, [
          bob.user, CHANGE_TYPES, scan.horizon, scan.digest, scan.page ?? null, scan.baseline ?? false,
        ])
      )[0].r as { status: string };
      expect(cleared.status).toBe("cleared");
      return { alice, bob, horizon };
    }
    const dataSnapshot = async (db: FreshDb) =>
      JSON.stringify(
        await Promise.all(
          ["actions", "action_events", "execution_runs", "execution_events", "conversations", "conversation_messages", "return_summary_state", "return_summary_reads", "suggestions"].map((t) =>
            db.query(`select to_jsonb(x) as row from public.${t} x order by 1`),
          ),
        ),
      );
    const omit = (value: Record<string, unknown>, keys: string[]) => Object.fromEntries(Object.entries(value).filter(([key]) => !keys.includes(key)));

    it("옛 행(Clear한 사용자의 상태 · 읽음 포함)이 그대로이고 return_summary_scan 외의 옛 객체는 한 글자도 안 바뀌며, 새 표는 비어 있다. Clear한 사용자는 계속 cleared, 안 한 사용자는 never_cleared + 토큰", async () => {
      const { before, c3, baseline } = await splitScripts();
      const db = await fresh();
      for (const sql of [...before, c3]) await db.exec(sql);
      const { alice, bob, horizon } = await seedAfterC3(db);
      const rows = await dataSnapshot(db);
      const objects = await schemaFingerprint(db);
      const aliceBefore = await scanOf(db, alice.user, horizon);
      const bobBefore = await scanOf(db, bob.user, horizon);
      await db.exec(baseline);
      expect(await dataSnapshot(db)).toBe(rows);
      const after = await schemaFingerprint(db);
      const old = <T>(json: string) => JSON.parse(json) as T[];
      const tables = (json: string) => old<{ table_name: string }>(json).map((r) => r.table_name);
      expect(tables(after.tables).filter((t) => !tables(objects.tables).includes(t))).toEqual(["return_summary_baseline"]);
      // 함수: 기준점 마이그레이션이 만든 것과 return_summary_scan(본문 갱신)만 다르다
      const fnAfter = new Map(old<{ sig: string; def: string }>(after.functions).map((r) => [r.sig, r.def]));
      const fnBefore = new Map(old<{ sig: string; def: string }>(objects.functions).map((r) => [r.sig, r.def]));
      const changed = [...fnBefore].filter(([sig, def]) => fnAfter.get(sig) !== def).map(([sig]) => sig);
      expect(changed).toEqual(["return_summary_scan(uuid,text[],timestamp with time zone,integer)"]);
      expect([...fnAfter.keys()].filter((sig) => !fnBefore.has(sig)).sort()).toEqual([
        "return_summary_baseline_guard()",
        "return_summary_baseline_init(uuid,text[],timestamp with time zone,text,timestamp with time zone)",
      ]);
      for (const key of ["triggers", "constraints"] as const) {
        const kept = new Set(old<Record<string, string>>(after[key]).map((r) => JSON.stringify(r)));
        for (const row of old<Record<string, string>>(objects[key])) expect(kept.has(JSON.stringify(row)), `${key}: ${JSON.stringify(row)}`).toBe(true);
      }
      // 옛 열은 하나도 바뀌지 않았다
      const oldTables = new Set(tables(objects.tables));
      expect(old<Record<string, string>>(after.columns).filter((r) => oldTables.has(r.table_name)).map((r) => JSON.stringify(r)).sort()).toEqual(
        old<Record<string, string>>(objects.columns).map((r) => JSON.stringify(r)).sort(),
      );
      expect(await db.query(`select 1 from public.return_summary_baseline`)).toEqual([]);
      // 새 키 외에는 11의 조회 결과와 같다 (읽기 규칙은 기준점이 없는 사용자에게 바뀌지 않는다)
      const aliceAfter = await scanOf(db, alice.user, horizon);
      const bobAfter = await scanOf(db, bob.user, horizon);
      expect(omit(aliceAfter, ["baseline_state", "init_digest"])).toEqual(aliceBefore);
      expect(omit(bobAfter, ["baseline_state", "init_digest"])).toEqual(bobBefore);
      expect(aliceAfter).toMatchObject({ baseline: true, baseline_state: "never_cleared" });
      expect(typeof aliceAfter.init_digest).toBe("string");
      expect(bobAfter).toMatchObject({ baseline: false, baseline_state: "cleared", init_digest: null });
      // 업그레이드 이전 Clear 사용자는 다시 초기화되지 않는다: 확정은 already_initialized이고 아무것도 쓰지 않는다
      const confirm = async (user: string, scan: Record<string, unknown>) =>
        (await db.query(`select public.return_summary_baseline_init($1, $2::text[], $3::timestamptz, $4, null) as r`, [user, CHANGE_TYPES, scan.horizon, scan.init_digest ?? "x"]))[0].r as { status: string };
      expect(await confirm(bob.user, bobAfter)).toEqual({ status: "already_initialized" });
      expect(await dataSnapshot(db)).toBe(rows);
      // 안 한 사용자는 확정할 수 있고, 그 뒤에는 Clear 없이 새 변화가 보인다
      expect(await confirm(alice.user, aliceAfter)).toEqual({ status: "initialized" });
      expect(await db.query(`select 1 from public.return_summary_baseline`)).toHaveLength(1);
    });

    it("헤더에 적힌 되돌리기 문장(+ 11의 return_summary_scan 정의)을 그대로 실행하면 11 적용 후 객체 지문 · 권한으로 돌아가고 옛 행은 그대로다. 되돌려도 읽음 표시는 남는다", async () => {
      const { before, c3, baseline } = await splitScripts();
      const db = await fresh();
      for (const sql of [...before, c3]) await db.exec(sql);
      const { alice, horizon } = await seedAfterC3(db);
      const objects = await schemaFingerprint(db);
      await db.exec(baseline);
      // 기준점을 확정해 읽음 쌍을 만들어 둔다 (되돌린 뒤에도 남아야 한다)
      const scan = await scanOf(db, alice.user, horizon);
      expect((await db.query(`select public.return_summary_baseline_init($1, $2::text[], $3::timestamptz, $4, null) as r`, [alice.user, CHANGE_TYPES, scan.horizon, scan.init_digest]))[0].r).toEqual({ status: "initialized" });
      const rows = await dataSnapshot(db);
      // 헤더의 되돌리기 문장을 순서대로: drop / revoke / grant 문장은 그대로, "(…create function public.return_summary_scan(…) …)" 줄은 11의 정의를 실행한다
      const header = baseline.split("\nbegin;")[0];
      const steps = header.split("\n").filter((line) => /^--\s+(drop |revoke |grant |\(20261111000000_review_summary\.sql)/.test(line));
      expect(steps.map((line) => line.replace(/^--\s+/, "").split(" ")[0])).toEqual(["drop", "drop", "(20261111000000_review_summary.sql의", "revoke", "grant", "drop", "drop"]);
      const a = c3.indexOf("create function public.return_summary_scan(");
      const scanDefinition = c3.slice(a, c3.indexOf("$$;", c3.indexOf("as $$", a)) + 3);
      expect(scanDefinition).toContain("return_summary_scan");
      for (const line of steps) await db.exec(line.startsWith("-- ") && line.includes("(20261111000000") ? scanDefinition : line.replace(/^--\s+/, ""));
      expect(await schemaFingerprint(db)).toEqual(objects);
      expect(await dataSnapshot(db)).toBe(rows);
      expect(await db.query(`select count(*)::int as n from public.return_summary_reads where user_id = $1`, [alice.user])).toEqual([{ n: 2 }]);
      const priv = await db.query(
        `select has_function_privilege('anon', f, 'execute') as anon, has_function_privilege('authenticated', f, 'execute') as authenticated, has_function_privilege('service_role', f, 'execute') as service_role
           from (select 'public.return_summary_scan(uuid,text[],timestamptz,integer)'::text as f) x`,
      );
      expect(priv).toEqual([{ anon: false, authenticated: false, service_role: true }]);
      // 되돌린 11의 조회는 기준점 모르는 옛 모양이다 (baseline_state · init_digest 없음)
      expect(Object.keys(await scanOf(db, alice.user, horizon))).not.toContain("baseline_state");
    });

    it("같은 이름의 객체가 이미 있으면 기준점 마이그레이션은 아무것도 바꾸지 않고 실패한다 (한 트랜잭션 롤백): 표 · 갱신한 조회 함수 모두 그대로", async () => {
      const { before, c3, baseline } = await splitScripts();
      const db = await fresh();
      for (const sql of [...before, c3]) await db.exec(sql);
      // 파일 끝쪽 함수와 같은 서명: 앞의 표 · 트리거 · 조회 갱신을 다 한 뒤에 실패한다 → 모두 되돌려져야 한다
      await db.exec(`create function public.return_summary_baseline_init(p_user_id uuid, p_types text[], p_horizon timestamptz, p_digest text, p_now timestamptz) returns int language sql as 'select 1'`);
      const objects = await schemaFingerprint(db);
      await expect(db.exec(baseline)).rejects.toThrow(/already exists|이미 있/);
      await db.exec("rollback");
      expect(await schemaFingerprint(db)).toEqual(objects);
      expect(await db.query(`select 1 from information_schema.tables where table_name = 'return_summary_baseline'`)).toEqual([]);
    });
  });
}
