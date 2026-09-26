import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const ACTION = "11111111-1111-4111-8111-111111111111";
const CLAIM1 = "22222222-2222-4222-8222-222222222222";
const CLAIM2 = "33333333-3333-4333-8333-333333333333";

let db: PGlite;
let source: string;

const row = (over: Record<string, unknown> = {}) =>
  JSON.stringify({
    title: "제안서 발송",
    counterpart: "김대표",
    owner: "me",
    due_date: "2026-09-26",
    due_at: "2026-09-26T23:59:59+09:00",
    status: "open",
    needs_confirmation: false,
    confirm_reasons: [],
    resolution: { due: { reason: "처음 합의된 값" } },
    embedding: null,
    ...over,
  });
const claim = (id: string, value: string) =>
  JSON.stringify([{ id, source_id: source, field: "due", value, quote: "금요일까지", occurred_at: "2026-09-22T10:00:00+09:00", speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "shared", channel: "meeting" }]);
const evidence = () => JSON.stringify([{ source_id: source, quote: "금요일까지", role: "created" }]);
const events = (type: string) => JSON.stringify([{ type, before: null, after: { due: "2026-09-26" }, source_id: source, actor: "ai", rule: null }]);

const write = (expected: number | null, action: string, claims: string, ev: string) =>
  db.query<{ write_action: boolean }>(`select public.write_action($1, $2, $3, $4::jsonb, $5::jsonb, $6::jsonb, $7::jsonb)`, [
    ALICE,
    ACTION,
    expected,
    action,
    claims,
    evidence(),
    ev,
  ]);

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  source = (await db.query<{ id: string }>(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'meeting', 'x', now()) returning id`, [ALICE])).rows[0].id;
}, 60_000);

describe("write_action: Action 쓰기를 한 트랜잭션으로", () => {
  it("새 Action과 Claim · 근거 · 이벤트를 함께 만든다", async () => {
    expect((await write(null, row(), claim(CLAIM1, "2026-09-26"), events("created"))).rows[0].write_action).toBe(true);
    const counts = await db.query<{ a: number; c: number; e: number; v: number; version: number }>(
      `select (select count(*)::int from public.actions where id = $1) a, (select count(*)::int from public.claims where action_id = $1) c,
              (select count(*)::int from public.evidence where action_id = $1) e, (select count(*)::int from public.action_events where action_id = $1) v,
              (select version from public.actions where id = $1) version`,
      [ACTION],
    );
    expect(counts.rows[0]).toEqual({ a: 1, c: 1, e: 1, v: 1, version: 0 });
  });

  it("버전이 맞으면 갱신하고 버전을 올린다", async () => {
    expect((await write(0, row({ due_date: "2026-09-29", due_at: "2026-09-29T23:59:59+09:00" }), claim(CLAIM2, "2026-09-29"), events("due_changed"))).rows[0].write_action).toBe(true);
    const { rows } = await db.query<{ due_date: string; version: number }>(`select due_date::text, version from public.actions where id = $1`, [ACTION]);
    expect(rows[0]).toEqual({ due_date: "2026-09-29", version: 1 });
  });

  it("그 사이 누가 먼저 썼으면(버전 불일치) 아무것도 쓰지 않는다", async () => {
    const before = (await db.query<{ n: number }>(`select count(*)::int n from public.claims where action_id = $1`, [ACTION])).rows[0].n;
    expect((await write(0, row({ title: "늦게 온 쓰기" }), claim("44444444-4444-4444-8444-444444444444", "2026-10-01"), events("due_changed"))).rows[0].write_action).toBe(false);
    expect((await db.query<{ n: number }>(`select count(*)::int n from public.claims where action_id = $1`, [ACTION])).rows[0].n).toBe(before);
    expect((await db.query<{ title: string }>(`select title from public.actions where id = $1`, [ACTION])).rows[0].title).toBe("제안서 발송");
  });

  it("다른 사용자의 Action은 없는 것으로 본다", async () => {
    await expect(
      db.query(`select public.write_action($1, $2, 1, $3::jsonb)`, [BOB, ACTION, row()]),
    ).rejects.toThrow(/action not found/);
  });

  it("클라이언트는 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.write_action($1, $2, 1, $3::jsonb)`, [ALICE, ACTION, row()])).rejects.toThrow(/permission denied/);
    });
  });
});

describe("start_action: 착수를 한 트랜잭션으로", () => {
  it("처음 착수 시각을 지키고, 이벤트와 지표를 함께 남긴다", async () => {
    const first = (await db.query<{ start_action: Date }>(`select public.start_action($1, $2)`, [ALICE, ACTION])).rows[0].start_action;
    const again = (await db.query<{ start_action: Date }>(`select public.start_action($1, $2)`, [ALICE, ACTION])).rows[0].start_action;
    expect(again).toEqual(first);
    const counts = await db.query<{ e: number; m: number }>(
      `select (select count(*)::int from public.action_events where action_id = $1 and type = 'user_started') e,
              (select count(*)::int from public.metric_events where action_id = $1 and type = 'action_started') m`,
      [ACTION],
    );
    expect(counts.rows[0]).toEqual({ e: 2, m: 2 });
  });

  it("다른 사용자의 Action이나 닫힌 Action은 착수할 수 없다", async () => {
    await expect(db.query(`select public.start_action($1, $2)`, [BOB, ACTION])).rejects.toThrow(/open action not found/);
  });

  it("클라이언트는 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.start_action($1, $2)`, [ALICE, ACTION])).rejects.toThrow(/permission denied/);
    });
  });
});

describe("지표 이벤트 (클라이언트 쓰기 제한)", () => {
  it("시각 · 사용자는 클라이언트가 정할 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`insert into public.metric_events (type, at) values ('app_opened', '2020-01-01')`)).rejects.toThrow(/permission denied/);
    });
  });

  it("app_opened는 남길 수 있고 action_started는 서버만", async () => {
    await asUser(db, ALICE, async () => {
      await db.query(`insert into public.metric_events (type) values ('app_opened')`);
      await expect(db.query(`insert into public.metric_events (type) values ('action_started')`)).rejects.toThrow(/row-level security/);
      const deleted = await db.query(`delete from public.metric_events`).then((r) => r.affectedRows ?? 0, () => "blocked");
      expect(deleted === "blocked" || deleted === 0).toBe(true);
    });
  });
});

describe("기기 토큰", () => {
  it("같은 토큰은 한 계정에만 있다", async () => {
    await db.query(`insert into public.devices (user_id, token, platform) values ($1, 'abcd', 'ios')`, [ALICE]);
    await expect(db.query(`insert into public.devices (user_id, token, platform) values ($1, 'abcd', 'ios')`, [BOB])).rejects.toThrow(/duplicate key/);
  });
});
