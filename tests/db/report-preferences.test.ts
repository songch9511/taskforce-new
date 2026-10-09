import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

import { dailyReportPayload, type ReportStatusCounts } from "@/lib/reports/payload";

import { asUser, createLocalSupabase } from "./local-supabase";

// 0.2.0 보고 (20261105000000_report_preferences): 표 2개의 RLS · 권한 · CHECK · 트리거, 서버 전용 함수 4개.
// 같은 claim 함수가 동시에 두 번 불릴 때는 tests/pg/report-deliveries.test.ts(실제 Postgres)가 본다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const CAROL = "00000000-0000-0000-0000-00000000000c";
const TABLES = ["report_preferences", "report_deliveries"] as const;
const FUNCTIONS = ["claim_report_delivery", "claim_report_retry", "finish_stale_report_deliveries", "report_status_counts"];

let db: PGlite;

/** 서울 10-10 일일 보고를 잡는다 (기본: 08:30 KST 예정, 2시간 창, 임대 300초). 잡힌 행 또는 null */
async function claim(userId: string, overrides: Partial<Record<"tz" | "date" | "dayStart" | "scheduled" | "expires" | "now", string>> = {}) {
  const a = {
    tz: "Asia/Seoul",
    date: "2026-10-10",
    dayStart: "2026-10-09T15:00:00Z",
    scheduled: "2026-10-09T23:30:00Z",
    expires: "2026-10-10T01:30:00Z",
    now: "2026-10-09T23:30:00Z",
    ...overrides,
  };
  const { rows } = await db.query<Record<string, unknown>>(
    `select * from public.claim_report_delivery($1, 'daily', $2, $3, $4, $5, $6, $7, 300)`,
    [userId, a.tz, a.date, a.dayStart, a.scheduled, a.expires, a.now],
  );
  return rows[0] ?? null;
}

async function retry(id: unknown, now: string, maxAttempts = 3) {
  const { rows } = await db.query<Record<string, unknown>>(`select * from public.claim_report_retry($1, $2, 300, $3)`, [id, now, maxAttempts]);
  return rows[0] ?? null;
}

async function asService<T>(fn: () => Promise<T>): Promise<T> {
  await db.exec("set role service_role");
  try {
    return await fn();
  } finally {
    await db.exec("reset role");
  }
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com'), ($3, 'carol@example.com')", [ALICE, BOB, CAROL]);
}, 60_000);

beforeEach(async () => {
  await db.exec("delete from public.report_preferences; delete from public.actions; delete from public.sources;");
  await db.query(`insert into public.report_preferences (user_id, time_zone) values ($1, 'Asia/Seoul'), ($2, 'Europe/London')`, [ALICE, BOB]);
});

describe("report_preferences", () => {
  it("D06 기본값: Both · 08:30 · 조용한 시간 22:00–08:00 · Respect Focus 켬. 시간대는 기본값이 없다", async () => {
    const { rows } = await db.query(`select mode, daily_time, quiet_start, quiet_end, respect_focus, time_zone, schedule_changed_at = created_at as same from public.report_preferences where user_id = $1`, [ALICE]);
    expect(rows).toEqual([{ mode: "both", daily_time: "08:30", quiet_start: "22:00", quiet_end: "08:00", respect_focus: true, time_zone: "Asia/Seoul", same: true }]);
    await expect(db.query(`insert into public.report_preferences (user_id) values ($1)`, [CAROL])).rejects.toThrow(/null value in column "time_zone"/);
  });

  it.each<[string, string]>([
    ["모르는 모드", `mode = 'weekly'`],
    ["시각 모양 8:30", `daily_time = '8:30'`],
    ["24:00", `daily_time = '24:00'`],
    ["초 단위", `daily_time = '08:30:00'`],
    ["고정 오프셋 시간대", `time_zone = '+09:00'`],
    ["빈 시간대", `time_zone = ''`],
    ["경로 같은 시간대", `time_zone = '../etc/passwd'`],
    ["조용한 시간 한쪽만", `quiet_end = null`],
    ["조용한 시간 시작 == 끝", `quiet_start = '03:00', quiet_end = '03:00'`],
  ])("CHECK가 막는다: %s", async (_name, set) => {
    await expect(db.query(`update public.report_preferences set ${set} where user_id = $1`, [ALICE])).rejects.toThrow(/check constraint|violates/);
  });

  it("조용한 시간 끄기 = 둘 다 null", async () => {
    await db.query(`update public.report_preferences set quiet_start = null, quiet_end = null where user_id = $1`, [ALICE]);
    expect((await db.query(`select quiet_start, quiet_end from public.report_preferences where user_id = $1`, [ALICE])).rows).toEqual([{ quiet_start: null, quiet_end: null }]);
  });

  it("schedule_changed_at은 일정에 닿는 값(모드 · 시각 · 조용한 시간 · 시간대)이 바뀔 때만 트리거가 지금으로 바꾸고, 직접 쓰지 못한다", async () => {
    await db.query(`insert into public.report_preferences (user_id, time_zone, created_at, schedule_changed_at) values ($1, 'Asia/Seoul', '2026-01-01Z', '2026-01-01Z')`, [CAROL]);
    const changedAt = async () => (await db.query<{ t: Date }>(`select schedule_changed_at as t from public.report_preferences where user_id = $1`, [CAROL])).rows[0].t.toISOString();

    await db.query(`update public.report_preferences set respect_focus = false where user_id = $1`, [CAROL]);
    await db.query(`update public.report_preferences set schedule_changed_at = '2030-01-01Z' where user_id = $1`, [CAROL]);
    expect(await changedAt()).toBe("2026-01-01T00:00:00.000Z");

    for (const set of [`daily_time = '09:00'`, `mode = 'daily'`, `quiet_start = '23:00'`, `time_zone = 'Asia/Tokyo'`]) {
      await db.query(`update public.report_preferences set schedule_changed_at = '2026-01-01Z' where user_id = $1`, [CAROL]); // 트리거가 지킨다
      await db.query(`update public.report_preferences set ${set} where user_id = $1`, [CAROL]);
      expect(Date.parse(await changedAt()), set).toBeGreaterThan(Date.parse("2026-06-01Z"));
      // 다음 확인을 위해 과거로 되돌릴 수 없으니 새 행으로 다시 시작한다
      await db.query(`delete from public.report_preferences where user_id = $1`, [CAROL]);
      await db.query(`insert into public.report_preferences (user_id, time_zone, created_at, schedule_changed_at) values ($1, 'Asia/Seoul', '2026-01-01Z', '2026-01-01Z')`, [CAROL]);
    }
  });
});

describe("RLS · 권한 (앱은 자기 행을 읽기만, 쓰기는 서버만)", () => {
  beforeEach(async () => {
    await claim(ALICE);
    await claim(BOB, { tz: "Europe/London", dayStart: "2026-10-09T23:00:00Z", scheduled: "2026-10-10T07:30:00Z", expires: "2026-10-10T09:30:00Z", now: "2026-10-10T07:30:00Z" });
  });

  it("두 표 모두 RLS가 켜져 있고 정책은 owner_all 하나, authenticated는 select만, anon은 없음", async () => {
    const { rows } = await db.query<{ tablename: string; policyname: string; cmd: string; roles: string[] }>(
      `select tablename, policyname, cmd, roles from pg_policies where schemaname = 'public' and tablename = any($1) order by tablename`,
      [[...TABLES]],
    );
    expect(rows).toEqual([
      { tablename: "report_deliveries", policyname: "owner_all", cmd: "ALL", roles: ["authenticated"] },
      { tablename: "report_preferences", policyname: "owner_all", cmd: "ALL", roles: ["authenticated"] },
    ]);
    const privileges = await db.query<{ relname: string; p: Record<string, boolean> }>(
      `select c.relname, jsonb_build_object(
          'auth_select', has_table_privilege('authenticated', c.oid, 'select'),
          'auth_insert', has_table_privilege('authenticated', c.oid, 'insert'),
          'auth_update', has_table_privilege('authenticated', c.oid, 'update'),
          'auth_delete', has_table_privilege('authenticated', c.oid, 'delete'),
          'anon_select', has_table_privilege('anon', c.oid, 'select'),
          'service_insert', has_table_privilege('service_role', c.oid, 'insert')) as p
       from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = any($1)`,
      [[...TABLES]],
    );
    for (const row of privileges.rows) {
      expect(row.p, row.relname).toEqual({ auth_select: true, auth_insert: false, auth_update: false, auth_delete: false, anon_select: false, service_insert: true });
    }
  });

  it.each(TABLES)("%s: 자기 행만 보이고 다른 사용자의 행은 0행", async (table) => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ user_id: string }>(`select user_id from public.${table}`);
      expect(rows.map((r) => r.user_id)).toEqual([ALICE]);
      expect((await db.query(`select 1 from public.${table} where user_id = $1`, [BOB])).rows).toHaveLength(0);
    });
  });

  it.each(TABLES)("%s: 앱은 만들거나 고치거나 지울 수 없다", async (table) => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`insert into public.${table} (user_id) values ($1)`, [ALICE])).rejects.toThrow(/permission denied/);
      await expect(db.query(`update public.${table} set user_id = user_id where user_id = $1`, [ALICE])).rejects.toThrow(/permission denied/);
      await expect(db.query(`delete from public.${table} where user_id = $1`, [ALICE])).rejects.toThrow(/permission denied/);
    });
  });

  it("서버 함수는 service_role만 실행한다 (호출자 권한 · search_path 비움). 앱 · anon은 부르지 못한다", async () => {
    const { rows } = await db.query<{ name: string; anon: boolean; authenticated: boolean; service_role: boolean; definer: boolean; config: string[] | null }>(
      `select p.proname as name,
              has_function_privilege('anon', p.oid, 'execute') as anon,
              has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
              has_function_privilege('service_role', p.oid, 'execute') as service_role,
              p.prosecdef as definer, p.proconfig as config
       from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = any($1) order by p.proname`,
      [FUNCTIONS],
    );
    expect(rows.map((r) => r.name)).toEqual([...FUNCTIONS].sort());
    for (const row of rows) {
      expect(row, row.name).toMatchObject({ anon: false, authenticated: false, service_role: true, definer: false });
      expect(row.config, row.name).toContain('search_path=""');
    }
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select * from public.report_status_counts($1, '2026-10-10')`, [ALICE])).rejects.toThrow(/permission denied/);
      await expect(db.query(`select * from public.claim_report_delivery($1, 'daily', 'Asia/Seoul', '2026-10-11', now(), now(), now(), now(), 300)`, [ALICE])).rejects.toThrow(/permission denied/);
    });
    // service_role은 RLS를 우회해 잡을 수 있다
    expect(await asService(() => claim(ALICE, { date: "2026-10-11", dayStart: "2026-10-10T15:00:00Z", scheduled: "2026-10-10T23:30:00Z", expires: "2026-10-11T01:30:00Z", now: "2026-10-10T23:30:00Z" }))).not.toBeNull();
  });
});

describe("claim_report_delivery: 하루 한 번", () => {
  it("처음 잡으면 pending · attempts 1 · 임대 300초, 같은 날 다시 잡으면 없다", async () => {
    const row = await claim(ALICE);
    expect(row).toMatchObject({ user_id: ALICE, kind: "daily", time_zone: "Asia/Seoul", status: "pending", attempts: 1, last_error: null, sent_at: null });
    expect((row!.report_date as Date).toISOString().slice(0, 10)).toBe("2026-10-10");
    expect((row!.claimed_at as Date).toISOString()).toBe("2026-10-09T23:30:00.000Z");
    expect((row!.next_attempt_at as Date).toISOString()).toBe("2026-10-09T23:35:00.000Z");
    expect(await claim(ALICE)).toBeNull();
    expect(await claim(ALICE, { now: "2026-10-10T00:30:00Z" })).toBeNull();
  });

  it("그 현지 날짜(지금 시간대 기준)에 예정된 보고가 이미 있으면 다른 시간대로도 다시 잡지 않는다", async () => {
    await claim(ALICE); // 서울 10-10 08:30 = 런던 10-10 00:30
    expect(await claim(ALICE, { tz: "Europe/London", dayStart: "2026-10-09T23:00:00Z", scheduled: "2026-10-10T07:30:00Z", expires: "2026-10-10T09:30:00Z", now: "2026-10-10T07:30:00Z" })).toBeNull();
    // 런던 다음 날은 잡는다
    expect(await claim(ALICE, { tz: "Europe/London", date: "2026-10-11", dayStart: "2026-10-10T23:00:00Z", scheduled: "2026-10-11T07:30:00Z", expires: "2026-10-11T09:30:00Z", now: "2026-10-11T07:30:00Z" })).not.toBeNull();
  });

  it("서쪽으로 옮겨 같은 report_date(10-11)가 다시 와도 다른 시간대면 잡는다 (유일 키는 시간대를 포함)", async () => {
    // 서울 10-11 08:30 = 10-10 23:30Z (LA 10-10). LA 10-11 08:30 = 10-11 15:30Z
    expect(await claim(ALICE, { date: "2026-10-11", dayStart: "2026-10-10T15:00:00Z", scheduled: "2026-10-10T23:30:00Z", expires: "2026-10-11T01:30:00Z", now: "2026-10-10T23:30:00Z" })).not.toBeNull();
    expect(await claim(ALICE, { tz: "America/Los_Angeles", date: "2026-10-11", dayStart: "2026-10-11T07:00:00Z", scheduled: "2026-10-11T15:30:00Z", expires: "2026-10-11T17:30:00Z", now: "2026-10-11T15:30:00Z" })).not.toBeNull();
  });

  it("더 늦은 날의 보고가 있으면 앞 날짜를 잡지 않는다", async () => {
    await claim(ALICE, { date: "2026-10-11", dayStart: "2026-10-10T15:00:00Z", scheduled: "2026-10-10T23:30:00Z", expires: "2026-10-11T01:30:00Z", now: "2026-10-10T23:30:00Z" });
    expect(await claim(ALICE)).toBeNull();
  });

  it("설정 행이 없는 사용자는 잡지 않는다", async () => {
    expect(await claim(CAROL)).toBeNull();
  });

  it("유일 키 (user_id, kind, time_zone, report_date)와 원장 CHECK", async () => {
    const row = await claim(ALICE);
    await expect(
      db.query(
        `insert into public.report_deliveries (user_id, kind, time_zone, report_date, scheduled_at, expires_at, status, attempts, next_attempt_at) values ($1, 'daily', 'Asia/Seoul', '2026-10-10', now(), now(), 'pending', 1, now())`,
        [ALICE],
      ),
    ).rejects.toThrow(/duplicate key/);
    for (const set of [
      `last_error = 'Bad Device Token'`,
      `last_error = 'apns_410: Unregistered by user@example.com'`,
      `status = 'sent'`, // sent_at 없음
      `next_attempt_at = null`, // pending인데 다음 시도 없음
      `expires_at = scheduled_at - interval '1 minute'`,
      `kind = 'weekly'`,
    ]) {
      await expect(db.query(`update public.report_deliveries set ${set} where id = $1`, [row!.id]), set).rejects.toThrow(/check constraint|violates/);
    }
  });
});

describe("claim_report_retry · finish_stale_report_deliveries", () => {
  it("차례가 되기 전 · 시도를 다 쓴 뒤 · 창이 닫힌 뒤 · 더 늦은 보고가 생긴 뒤에는 다시 잡지 않는다", async () => {
    const row = await claim(ALICE);
    expect(await retry(row!.id, "2026-10-09T23:34:00Z")).toBeNull(); // 임대 중
    const again = await retry(row!.id, "2026-10-09T23:35:00Z");
    expect(again).toMatchObject({ attempts: 2 });
    expect((again!.next_attempt_at as Date).toISOString()).toBe("2026-10-09T23:40:00.000Z");
    expect(await retry(row!.id, "2026-10-09T23:40:00Z", 2)).toBeNull(); // 시도 상한
    expect(await retry(row!.id, "2026-10-10T01:31:00Z")).toBeNull(); // 창 밖
    await claim(ALICE, { date: "2026-10-11", dayStart: "2026-10-10T15:00:00Z", scheduled: "2026-10-10T23:30:00Z", expires: "2026-10-11T01:30:00Z", now: "2026-10-10T23:30:00Z" });
    expect(await retry(row!.id, "2026-10-09T23:45:00Z")).toBeNull(); // 더 늦은 보고가 있다
  });

  it("끝난 행(sent)은 다시 잡지 않는다", async () => {
    const row = await claim(ALICE);
    await db.query(`update public.report_deliveries set status = 'sent', sent_at = now(), next_attempt_at = null where id = $1`, [row!.id]);
    expect(await retry(row!.id, "2026-10-10T00:00:00Z")).toBeNull();
  });

  it("늦었거나 시도를 다 쓴 대기 행을 닫는다. 보내는 중(임대 중)인 행과 남은 실패 코드는 건드리지 않는다", async () => {
    const stale = await claim(ALICE);
    const exhausted = await claim(BOB, { tz: "Europe/London", dayStart: "2026-10-09T23:00:00Z", scheduled: "2026-10-10T07:30:00Z", expires: "2026-10-10T09:30:00Z", now: "2026-10-10T07:30:00Z" });
    await db.query(`update public.report_deliveries set attempts = 3, last_error = 'apns_503', next_attempt_at = '2026-10-10T07:40:00Z' where id = $1`, [exhausted!.id]);
    await db.query(`insert into public.report_preferences (user_id, time_zone) values ($1, 'Asia/Seoul')`, [CAROL]);
    const inFlight = await claim(CAROL, { now: "2026-10-10T07:39:00Z", expires: "2026-10-10T07:00:00Z" }); // 창은 닫혔지만 임대 중

    const { rows } = await db.query<{ n: number }>(`select public.finish_stale_report_deliveries('2026-10-10T07:40:00Z', 3) as n`);
    expect(rows[0].n).toBe(2);
    const states = await db.query<{ id: string; status: string; last_error: string | null; next_attempt_at: Date | null }>(
      `select id, status, last_error, next_attempt_at from public.report_deliveries order by user_id`,
    );
    expect(states.rows.map((r) => [r.id, r.status, r.last_error])).toEqual([
      [stale!.id, "failed", "stale"],
      [exhausted!.id, "failed", "apns_503"],
      [inFlight!.id, "pending", null],
    ]);
  });
});

describe("report_status_counts: 숫자만 (알림에 사용자 글이 실리지 않는다)", () => {
  /** 알림에 실리면 안 되는 글: 원문 · 제목 · 인용 · 메모 · 상대 이름 · 이메일 */
  const SECRETS = ["ZEBRA-원문-회의록", "QUOKKA-할일-제목", "AXOLOTL-인용", "NARWHAL-메모", "PANGOLIN-상대", "okapi@secret.example", "TAPIR-범위", "IBIS-별칭"];

  async function seed(userId: string) {
    const source = (await db.query<{ id: string }>(
      `insert into public.sources (user_id, kind, title, raw_text, occurred_at) values ($1, 'meeting', $2, $3, now()) returning id`,
      [userId, `${SECRETS[0]} 제목`, `${SECRETS[0]} 금요일까지 ${SECRETS[4]}에게 보내드릴게요 ${SECRETS[5]}`],
    )).rows[0].id;
    const action = async (fields: { needs_confirmation?: boolean; owner?: string; due_date?: string | null; started?: boolean; status?: string }) => {
      const id = (await db.query<{ id: string }>(
        `insert into public.actions (user_id, title, scope_summary, counterpart, owner, status, needs_confirmation, due_date, started_at, notes_markdown)
         values ($1, $2, $3, $4, $5, $6, $7, $8, case when $9 then now() end, $10) returning id`,
        [userId, SECRETS[1], SECRETS[6], SECRETS[4], fields.owner ?? "me", fields.status ?? "open", fields.needs_confirmation ?? false, fields.due_date ?? null, fields.started ?? false, SECRETS[3]],
      )).rows[0].id;
      await db.query(
        `insert into public.claims (user_id, action_id, source_id, field, value, quote, occurred_at, speaker_role, certainty, directness, audience)
         values ($1, $2, $3, 'due', '2026-10-10', $4, now(), 'me', 'firm', 'first_hand', 'shared')`,
        [userId, id, source, SECRETS[2]],
      );
      await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, $4, 'created')`, [userId, id, source, SECRETS[2]]);
    };
    await action({ needs_confirmation: true, owner: "unknown" }); // review
    await action({ needs_confirmation: true, due_date: "2026-10-01" }); // review (확인 요청은 기한과 상관없이 review만)
    await action({ due_date: "2026-10-09" }); // overdue
    await action({ due_date: "2026-10-10", started: true }); // due today (착수했어도 겹치지 않는다)
    await action({ due_date: "2026-10-10" }); // due today
    await action({ started: true }); // in progress
    await action({ started: true, due_date: "2026-10-12" }); // in progress
    await action({ owner: "other", due_date: "2026-10-10" }); // 남의 일: 세지 않는다
    await action({ status: "done", due_date: "2026-10-10" }); // 끝난 일: 세지 않는다
    await action({}); // 기한 없음 · 착수 전: 세지 않는다
    await db.query(`insert into public.profiles (user_id, display_name, aliases, emails) values ($1, $2, $3, $4) on conflict (user_id) do nothing`, [userId, SECRETS[4].slice(0, 40), [SECRETS[7]], [SECRETS[5]]]);
    await db.query(`insert into public.people (user_id, display_name, emails, origin) values ($1, $2, $3, 'source')`, [userId, SECRETS[4], [SECRETS[5]]]);
  }

  it("열린 할 일의 숫자 네 개만 돌려주고, 그 숫자로 만든 알림 JSON에는 원문 · 인용 · 제목 · 메모 · 이름 · 이메일이 없다", async () => {
    await seed(ALICE);
    await seed(BOB); // 다른 사용자의 할 일은 세지 않는다 (같은 수지만 합쳐지지 않는지 본다)
    const result = await asService(() => db.query<ReportStatusCounts>(`select * from public.report_status_counts($1, '2026-10-10')`, [ALICE]));
    expect(result.fields.map((f) => f.name)).toEqual(["review", "overdue", "due_today", "in_progress"]);
    expect(result.rows).toEqual([{ review: 2, overdue: 1, due_today: 2, in_progress: 2 }]);

    for (const respectFocus of [true, false]) {
      const json = JSON.stringify(dailyReportPayload(result.rows[0], { respectFocus }));
      for (const secret of SECRETS) expect(json, secret).not.toContain(secret);
      for (const fragment of ["ZEBRA", "QUOKKA", "AXOLOTL", "NARWHAL", "PANGOLIN", "okapi", "TAPIR", "IBIS", "@"]) expect(json, fragment).not.toContain(fragment);
      expect(JSON.parse(json).aps.alert.body).toBe("2 to review · 1 overdue · 2 due today · 2 in progress");
    }
  });

  it("할 일이 없으면 모두 0 (보낼 것이 없다)", async () => {
    const { rows } = await asService(() => db.query(`select * from public.report_status_counts($1, '2026-10-10')`, [CAROL]));
    expect(rows).toEqual([{ review: 0, overdue: 0, due_today: 0, in_progress: 0 }]);
  });
});
