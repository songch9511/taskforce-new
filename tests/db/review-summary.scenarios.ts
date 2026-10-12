import { randomUUID } from "node:crypto";

import { beforeAll, describe, expect, it } from "vitest";

import { CHANGE_EVENT_TYPES } from "../../src/lib/actions/changed";

// 0.2.0 C3 (20261111000000_review_summary) — 제안 · 복귀 요약 · Clear 저장 계약.
// suggestions 표(dedup · 상한 · snooze · topic 억제 · 증거 있는 stale) · return_summary_state(Clear watermark) · 서비스 롤 전용 RPC.
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
    clear: async (userId: string, cursor: { since: string | null; horizon: string; digest: string }, now: string | null = null) =>
      (
        await one(`select public.return_summary_clear($1, $2::text[], $3::timestamptz, $4::timestamptz, $5, $6::timestamptz) as r`, [
          userId, CHANGE_TYPES, cursor.since, cursor.horizon, cursor.digest, now,
        ])
      ).r as ClearResult,
    state: (userId: string) => one(`select cleared_through, version from public.return_summary_state where user_id = $1`, [userId]),
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
export type ScanResult = { since: string | null; horizon: string; digest: string; truncated: boolean; works: ScanWork[] };
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
        await rejects(q(`select public.return_summary_clear($1, '{completed}'::text[], null, now(), 'x', null)`, [alice]), /permission denied/);
        await rejects(q(`select public.return_summary_digest($1, '{completed}'::text[], null, now())`, [alice]), /permission denied/);
      });
    });

    it("새 함수는 모두 search_path = '' 이고 service_role만 실행한다 (public · anon · authenticated 실행 권한 없음)", async () => {
      const rpcs = [
        "suggestions_produce(uuid,timestamp with time zone,integer,boolean)",
        "suggestions_expose(uuid,date,integer,timestamp with time zone)",
        "suggestion_transition(uuid,uuid,integer,text,timestamp with time zone,text,timestamp with time zone)",
        "suggestion_stale_evidence(public.suggestions)",
        "return_summary_scan(uuid,text[],timestamp with time zone,integer)",
        "return_summary_clear(uuid,text[],timestamp with time zone,timestamp with time zone,text,timestamp with time zone)",
        "return_summary_digest(uuid,text[],timestamp with time zone,timestamp with time zone)",
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

    it("계정을 지우면 제안 · Clear 위치도 함께 지워진다", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await f.suggestion(user, action);
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, now())`, [user]);
      await q(`delete from auth.users where id = $1`, [user]);
      expect(await f.count(`select 1 from public.suggestions where user_id = $1`, [user])).toBe(0);
      expect(await f.count(`select 1 from public.return_summary_state where user_id = $1`, [user])).toBe(0);
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
    it("[action_events] AI · 실행기 변화(changed.ts 종류)만 후보다: 사용자 이벤트 · created · 사용자 종류는 아니다. 한 번도 Clear하지 않은 사용자는 처음부터 본다", async () => {
      const user = await f.user();
      const action = await f.action(user, { title: "제안서 보내기" });
      await f.event(user, action, "due_changed", "ai", at(T0, 10));
      await f.event(user, action, "merged", "ai", at(T0, 20));
      await f.event(user, action, "artifact_created", "agent", at(T0, 30));
      await f.event(user, action, "created", "ai", at(T0, 5));
      await f.event(user, action, "user_edited", "user", at(T0, 40));
      await f.event(user, action, "user_seen", "user", at(T0, 50));
      const scan = await f.scan(user, at(T0, 1_000_000));
      expect(scan.since).toBeNull();
      expect(scan.truncated).toBe(false);
      expect(scan.works).toHaveLength(1);
      expect(scan.works[0]).toMatchObject({ action_id: action, title: "제안서 보내기", status: "open", started: false });
      expect(scan.works[0].changes.map((c) => `${c.source}:${c.kind}`)).toEqual(["action_event:due_changed", "action_event:merged", "action_event:artifact_created"]);
      // 사용자가 마지막으로 손댄 시각은 TS가 changed.ts 의미로 비교하도록 그대로 준다 (마이크로초 글자)
      expect(scan.works[0].last_user_at).toBe(at(T0, 50));
      expect(scan.works[0].changes.map((c) => c.at)).toEqual([at(T0, 10), at(T0, 20), at(T0, 30)]);
    });

    it("범위는 (since, horizon] 이다: since와 같은 시각은 이미 지난 범위이고, horizon과 같은 시각은 이번 범위, 그 뒤는 다음 번이다 (같은 시각 tie)", async () => {
      const user = await f.user();
      const action = await f.action(user);
      await q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [user, at(T0, 100)]);
      await f.event(user, action, "due_changed", "ai", at(T0, 100));
      await f.event(user, action, "scope_changed", "ai", at(T0, 101));
      await f.event(user, action, "owner_changed", "ai", at(T0, 200));
      await f.event(user, action, "reopened", "ai", at(T0, 201));
      const scan = await f.scan(user, at(T0, 200));
      expect(scan.since).toBe(at(T0, 100));
      expect(scan.horizon).toBe(at(T0, 200));
      expect(scan.works[0].changes.map((c) => c.kind)).toEqual(["scope_changed", "owner_changed"]);
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
  describe("Clear (return_summary_clear): 조회가 본 범위까지만, 단조 증가", () => {
    async function seed() {
      const user = await f.user();
      const action = await f.action(user);
      await f.event(user, action, "due_changed", "ai", at(T0, 10));
      await f.event(user, action, "merged", "ai", at(T0, 20));
      return { user, action };
    }

    it("조회한 범위를 읽음 처리한다: Clear 뒤 같은 범위는 비어 있고 since가 horizon으로 옮겨 간다", async () => {
      const { user } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect(scan.works).toHaveLength(1);
      const result = await f.clear(user, { since: scan.since, horizon: scan.horizon, digest: scan.digest }, at(T0, 200));
      expect(result).toEqual({ status: "cleared", applied: true, cleared_through: at(T0, 100) });
      expect(await f.state(user)).toMatchObject({ version: 1 });
      const after = await f.scan(user, at(T0, 300));
      expect(after.since).toBe(at(T0, 100));
      expect(after.works).toEqual([]);
    });

    it("조회와 Clear 사이에 생긴 새 사건은 남는다 (horizon 뒤): 읽음으로 삼키지 않는다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      await f.event(user, action, "owner_changed", "ai", at(T0, 150));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      const after = await f.scan(user, at(T0, 300));
      expect(after.works[0].changes.map((c) => c.kind)).toEqual(["owner_changed"]);
    });

    it("같은 시각 tie: horizon과 정확히 같은 시각의 사건이 조회 뒤에 늦게 commit되면 digest가 달라 409(stale)이고 아무것도 지우지 않는다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      await f.event(user, action, "scope_changed", "ai", at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("stale");
      expect(await f.state(user)).toBeUndefined();
      expect((await f.scan(user, at(T0, 300))).works[0].changes.map((c) => c.kind)).toEqual(["due_changed", "merged", "scope_changed"]);
    });

    it("늦게 commit된 사건(트랜잭션 시작 시각이 horizon 이전): digest가 달라 stale. 다시 조회하면 보이고 그 뒤 Clear하면 읽음이 된다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      await f.event(user, action, "reopened", "ai", at(T0, 15));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("stale");
      const again = await f.scan(user, at(T0, 300));
      expect(again.works[0].changes.map((c) => c.kind)).toEqual(["due_changed", "reopened", "merged"]);
      expect((await f.clear(user, again, at(T0, 400))).status).toBe("cleared");
      expect((await f.scan(user, at(T0, 500))).works).toEqual([]);
    });

    it("범위 안 사건이 지워져도(Action 삭제) digest가 달라 stale이다: 보이지 않은 것을 읽음으로 삼키는 쪽이 아니라 다시 조회하게 한다", async () => {
      const { user } = await seed();
      const other = await f.action(user);
      await f.event(user, other, "completed", "ai", at(T0, 30));
      const scan = await f.scan(user, at(T0, 100));
      await q(`delete from public.actions where id = $1`, [other]);
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("stale");
    });

    it("DB 정밀도: 마이크로초 1 차이도 범위를 가른다. 밀리초로 잘린 horizon으로 Clear하려 하면(JS Date 변환) 그 사이 사건 때문에 stale", async () => {
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
      // 1µs 뒤의 사건은 같은 horizon의 범위가 아니다
      await f.event(user, action, "completed", "ai", "2026-10-12T00:00:00.123701Z");
      expect((await f.clear(user, scan, "2026-10-12T00:00:01Z")).status).toBe("cleared");
      expect((await f.scan(user, "2026-10-12T00:00:02Z")).works[0].changes.map((c) => c.kind)).toEqual(["completed"]);
    });

    it("단조 증가: 더 이른 커서로 늦게 Clear해도(겹친 읽기 · 두 기기) 위치가 뒤로 가지 않는다. 같은 커서를 다시 보내면(응답 유실 뒤 재시도) 성공이지만 새 쓰기는 없다", async () => {
      const { user, action } = await seed();
      const early = await f.scan(user, at(T0, 100));
      await f.event(user, action, "owner_changed", "ai", at(T0, 150));
      const late = await f.scan(user, at(T0, 200));
      expect((await f.clear(user, late, at(T0, 300)))).toMatchObject({ status: "cleared", applied: true, cleared_through: at(T0, 200) });
      const stale = await f.clear(user, early, at(T0, 300));
      expect(stale).toEqual({ status: "cleared", applied: false, cleared_through: at(T0, 200) });
      const retry = await f.clear(user, late, at(T0, 300));
      expect(retry).toEqual({ status: "cleared", applied: false, cleared_through: at(T0, 200) });
      expect(await f.state(user)).toMatchObject({ version: 1 });
    });

    it("두 기기가 서로 다른 시점에 본 범위를 각각 Clear해도 합쳐서 가장 늦은 것까지만, 그 뒤 사건은 남는다", async () => {
      const { user, action } = await seed();
      const deviceA = await f.scan(user, at(T0, 100));
      await f.event(user, action, "owner_changed", "ai", at(T0, 150));
      const deviceB = await f.scan(user, at(T0, 200));
      await f.event(user, action, "completed", "ai", at(T0, 250));
      expect((await f.clear(user, deviceB, at(T0, 300))).status).toBe("cleared");
      expect((await f.clear(user, deviceA, at(T0, 300))).status).toBe("cleared");
      expect((await f.state(user))?.cleared_through).toBeDefined();
      const after = await f.scan(user, at(T0, 400));
      expect(after.since).toBe(at(T0, 200));
      expect(after.works[0].changes.map((c) => c.kind)).toEqual(["completed"]);
    });

    it("미래 horizon은 받지 않는다 (invalid): 서버 시각 기준으로 아직 오지 않은 시각을 읽음으로 만들 수 없다", async () => {
      const { user } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(user, { ...scan, horizon: at(T0, 100) }, at(T0, 99))).status).toBe("invalid");
      expect((await f.clear(user, { ...scan, horizon: "2999-01-01T00:00:00Z" }, at(T0, 99))).status).toBe("invalid");
      expect(await f.state(user)).toBeUndefined();
    });

    it("현재 위치보다 앞선 since(꾸민 커서)는 invalid, 잘못된 digest는 stale이다", async () => {
      const { user, action } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      await f.clear(user, scan, at(T0, 150));
      await f.event(user, action, "completed", "ai", at(T0, 160));
      const next = await f.scan(user, at(T0, 200));
      expect((await f.clear(user, { ...next, since: at(T0, 500) }, at(T0, 300))).status).toBe("invalid");
      expect((await f.clear(user, { ...next, digest: "a:0:0|r:0:0|m:0:0" }, at(T0, 300))).status).toBe("stale");
      expect((await f.clear(user, next, at(T0, 300))).status).toBe("cleared");
    });

    it("남의 커서로는 아무것도 지우지 못한다: 사용자마다 범위를 다시 세므로 digest가 맞지 않으면 stale, Clear 위치는 사용자별이다", async () => {
      const { user } = await seed();
      const other = await f.user();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(other, scan, at(T0, 200))).status).toBe("stale");
      expect(await f.state(other)).toBeUndefined();
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      expect(await f.state(other)).toBeUndefined();
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

    it("재로그인 · 같은 UUID: 위치는 계정에 붙는다 (세션이 아니다). 같은 커서는 새 세션에서도 그대로 통한다", async () => {
      const { user } = await seed();
      const scan = await f.scan(user, at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 200))).status).toBe("cleared");
      // 새 세션이어도 같은 user_id면 같은 위치를 읽는다
      expect((await f.scan(user, at(T0, 300))).since).toBe(at(T0, 100));
      expect((await f.clear(user, scan, at(T0, 400)))).toMatchObject({ status: "cleared", applied: false });
    });
  });
}
