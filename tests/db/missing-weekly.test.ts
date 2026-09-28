import { readFile } from "node:fs/promises";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const ACTION = "11111111-1111-4111-8111-111111111111";

let db: PGlite;
let source: string;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  source = (await db.query<{ id: string }>(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'meeting', 'x', now()) returning id`, [ALICE])).rows[0].id;
  // 서버(service role)가 쓰는 주간 질문 응답
  await db.query(`insert into public.weekly_checks (user_id, week_start, answer) values ($1, '2026-09-21', 'yes'), ($2, '2026-09-21', 'no')`, [ALICE, BOB]);
}, 60_000);

describe("누락 신고 (20261002000000_a1_missing_weekly_realtime)", () => {
  it("write_action이 AI의 created와 사용자의 user_reported_missing을 한 번에 남긴다", async () => {
    const action = JSON.stringify({ title: "견적서 전달", counterpart: null, owner: "me", due_date: null, due_at: null, status: "open", needs_confirmation: false, confirm_reasons: [], resolution: {}, embedding: null });
    const evidence = JSON.stringify([{ source_id: source, quote: "견적서 드릴게요", role: "created" }]);
    const events = JSON.stringify([
      { type: "created", before: null, after: { title: "견적서 전달" }, source_id: source, actor: "ai", rule: null },
      { type: "user_reported_missing", before: null, after: { stage: "not_extracted", source_id: source }, source_id: source, actor: "user", rule: null },
    ]);
    await db.query(`select public.write_action($1, $2, null, $3::jsonb, '[]'::jsonb, $4::jsonb, $5::jsonb)`, [ALICE, ACTION, action, evidence, events]);

    const { rows } = await db.query<{ type: string; actor: string; stage: string }>(
      `select type, actor, after->>'stage' as stage from public.action_events where action_id = $1 order by type`,
      [ACTION],
    );
    expect(rows).toEqual([
      { type: "created", actor: "ai", stage: null },
      { type: "user_reported_missing", actor: "user", stage: "not_extracted" },
    ]);
  });
});

describe("주간 질문 (weekly_checks)", () => {
  it("본인 응답만 보인다", async () => {
    await asUser(db, ALICE, async () => {
      expect((await db.query(`select answer from public.weekly_checks`)).rows).toEqual([{ answer: "yes" }]);
    });
  });

  it.each([
    ["추가", `insert into public.weekly_checks (week_start, answer) values ('2026-09-28', 'yes')`],
    ["수정", `update public.weekly_checks set answer = 'no'`],
    ["삭제", `delete from public.weekly_checks`],
  ])("클라이언트는 직접 %s할 수 없다", async (_label, sql) => {
    await asUser(db, ALICE, async () => {
      const result = await db.query(sql).then(
        (r) => r.affectedRows ?? 0,
        () => "blocked",
      );
      expect(result === "blocked" || result === 0).toBe(true);
    });
    expect((await db.query(`select answer from public.weekly_checks where user_id = $1`, [ALICE])).rows).toEqual([{ answer: "yes" }]);
  });

  it("한 사용자 · 한 주에 하나이고, 다시 답하면 덮어쓴다", async () => {
    await expect(db.query(`insert into public.weekly_checks (user_id, week_start, answer) values ($1, '2026-09-21', 'no')`, [ALICE])).rejects.toThrow(/unique|duplicate/);
    await db.query(
      `insert into public.weekly_checks (user_id, week_start, answer) values ($1, '2026-09-14', 'yes')
       on conflict (user_id, week_start) do update set answer = excluded.answer`,
      [ALICE],
    );
    await db.query(
      `insert into public.weekly_checks (user_id, week_start, answer) values ($1, '2026-09-14', 'skipped')
       on conflict (user_id, week_start) do update set answer = excluded.answer`,
      [ALICE],
    );
    expect((await db.query(`select answer from public.weekly_checks where user_id = $1 and week_start = '2026-09-14'`, [ALICE])).rows).toEqual([{ answer: "skipped" }]);
  });

  it("다시 답하면 서버가 answered_at을 새로 적고, created_at은 첫 답 그대로 둔다", async () => {
    const first = await db.query<{ answered_at: Date; created_at: Date }>(
      `insert into public.weekly_checks (user_id, week_start, answer) values ($1, '2026-09-07', 'no') returning answered_at, created_at`,
      [BOB],
    );
    expect(first.rows[0].answered_at).toEqual(first.rows[0].created_at); // 기본값은 처음 넣은 시각
    const again = await db.query<{ answer: string; answered_at: Date; created_at: Date }>(
      `insert into public.weekly_checks (user_id, week_start, answer, answered_at) values ($1, '2026-09-07', 'yes', now() + interval '1 day')
       on conflict (user_id, week_start) do update set answer = excluded.answer, answered_at = excluded.answered_at
       returning answer, answered_at, created_at`,
      [BOB],
    );
    expect(again.rows[0].answer).toBe("yes");
    expect(again.rows[0].created_at).toEqual(first.rows[0].created_at);
    expect(again.rows[0].answered_at.getTime()).toBeGreaterThan(first.rows[0].answered_at.getTime());
  });

  it.each([
    ["월요일이 아닌 날", `insert into public.weekly_checks (user_id, week_start, answer) values ('${ALICE}', '2026-09-22', 'yes')`],
    ["모르는 답", `insert into public.weekly_checks (user_id, week_start, answer) values ('${ALICE}', '2026-09-07', 'maybe')`],
  ])("%s은(는) 거부한다", async (_label, sql) => {
    await expect(db.query(sql)).rejects.toThrow(/check/);
  });
});

describe("누락 신고 시도 (missing_reports)", () => {
  beforeAll(async () => {
    // 서버(service role)가 추출 전에 남기는 시도 기록
    await db.query(`insert into public.missing_reports (user_id) values ($1), ($1), ($2)`, [ALICE, BOB]);
  });

  it("본인 기록만 보인다", async () => {
    await asUser(db, ALICE, async () => {
      expect((await db.query<{ user_id: string }>(`select user_id from public.missing_reports`)).rows).toEqual([{ user_id: ALICE }, { user_id: ALICE }]);
    });
  });

  it.each([
    ["추가", `insert into public.missing_reports default values`],
    ["수정", `update public.missing_reports set created_at = now() - interval '1 day'`],
    ["삭제", `delete from public.missing_reports`],
  ])("클라이언트는 직접 %s할 수 없다 (횟수 제한을 피하지 못한다)", async (_label, sql) => {
    await asUser(db, ALICE, async () => {
      const result = await db.query(sql).then(
        (r) => r.affectedRows ?? 0,
        () => "blocked",
      );
      expect(result === "blocked" || result === 0).toBe(true);
    });
    const { rows } = await db.query<{ n: number }>(
      `select count(*)::int as n from public.missing_reports where user_id = $1 and created_at > now() - interval '1 hour'`,
      [ALICE],
    );
    expect(rows[0].n).toBe(2);
  });
});

describe("Realtime", () => {
  const realtimeBlock = async () => {
    const sql = await readFile(path.resolve(__dirname, "../../supabase/migrations/20261002000000_a1_missing_weekly_realtime.sql"), "utf8");
    return sql.slice(sql.lastIndexOf("do $$"));
  };
  const published = () =>
    db.query(`select tablename from pg_catalog.pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'`);

  it("supabase_realtime publication이 없는 Postgres에서도 마이그레이션이 통과한다", async () => {
    expect((await db.query(`select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime'`)).rows).toHaveLength(0);
  });

  it("publication이 있으면 actions를 한 번만 추가한다", async () => {
    await db.exec(`create publication supabase_realtime`);
    await db.exec(await realtimeBlock());
    await db.exec(await realtimeBlock());
    expect((await published()).rows).toEqual([{ tablename: "actions" }]);
  });
});
