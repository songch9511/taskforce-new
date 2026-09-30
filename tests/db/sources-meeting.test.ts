import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// sources.meeting (20261016000000_sources_meeting, docs/go-live/google-integration.md 2-7): 회의 원문(Notion 회의록 · Meet 전사)에 붙인 Calendar 일정.
// 새 표가 없으므로 기존 sources의 RLS(owner_all)를 그대로 따른다. 원문 행과 함께 지워지고, 90일 본문 삭제 · 연결 끊기에는 남는다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const MEETING = { calendar_event_id: "evt-1", title: "Proposal review — Acme", start: "2026-09-30T01:00:00.000Z", end: "2026-09-30T02:00:00.000Z" };

let db: PGlite;
let aliceSource: string;
let connection: string;

async function insertSource(userId: string, meeting: unknown, extra: { connectionId?: string; externalId?: string; createdDaysAgo?: number } = {}) {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.sources (user_id, kind, raw_text, occurred_at, meeting, connection_id, external_id, external_version, created_at)
     values ($1, 'meeting', '[Google Meet · Proposal review — Acme]\nJordan Lee: 금요일까지 부탁해요.', now(), $2::jsonb, $3, $4, '1', now() - make_interval(days => $5))
     returning id`,
    [userId, meeting === null ? null : JSON.stringify(meeting), extra.connectionId ?? null, extra.externalId ?? null, extra.createdDaysAgo ?? 0],
  );
  return rows[0].id;
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  const { rows } = await db.query<{ id: string }>(
    `insert into public.connections (user_id, provider, external_account_id, display_name) values ($1, 'google', 'sub-1', 'alice@example.com') returning id`,
    [ALICE],
  );
  connection = rows[0].id;
  aliceSource = await insertSource(ALICE, MEETING, { connectionId: connection, externalId: "conferenceRecords/c1/transcripts/t1" });
}, 60_000);

describe("sources.meeting 열", () => {
  it("jsonb이고 비어 있을 수 있다 (일정이 없는 원문이 대부분이다)", async () => {
    const { rows } = await db.query<{ data_type: string; is_nullable: string }>(
      `select data_type, is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'sources' and column_name = 'meeting'`,
    );
    expect(rows).toEqual([{ data_type: "jsonb", is_nullable: "YES" }]);
    const bare = await insertSource(ALICE, null);
    expect((await db.query(`select meeting from public.sources where id = $1`, [bare])).rows).toEqual([{ meeting: null }]);
  });

  it("{ calendar_event_id, title, start, end }를 그대로 저장한다 (제목은 null일 수 있다)", async () => {
    const { rows } = await db.query<{ meeting: unknown }>(`select meeting from public.sources where id = $1`, [aliceSource]);
    expect(rows[0].meeting).toEqual(MEETING);
    const untitled = await insertSource(ALICE, { ...MEETING, title: null, calendar_event_id: "evt-2" });
    expect((await db.query<{ t: string | null }>(`select meeting->>'title' as t from public.sources where id = $1`, [untitled])).rows[0].t).toBeNull();
  });

  it.each([
    ["객체가 아님", [MEETING]],
    ["문자열", "evt-1"],
    ["calendar_event_id가 없음", { title: "x", start: MEETING.start, end: MEETING.end }],
    ["calendar_event_id가 숫자", { ...MEETING, calendar_event_id: 7 }],
    ["start가 없음", { calendar_event_id: "evt-1", title: "x", end: MEETING.end }],
    ["end가 문자열이 아님", { ...MEETING, end: 1 }],
    ["title이 숫자", { ...MEETING, title: 3 }],
  ])("모양이 다르면 거부한다: %s", async (_name, meeting) => {
    await expect(insertSource(ALICE, meeting)).rejects.toThrow(/sources_meeting_shape/);
  });
});

describe("sources.meeting RLS (기존 sources owner_all)", () => {
  it("사용자는 자기 원문의 일정만 본다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ meeting: { calendar_event_id: string } }>(`select meeting from public.sources where id = $1`, [aliceSource]);
      expect(rows[0].meeting.calendar_event_id).toBe("evt-1");
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select meeting from public.sources where id = $1`, [aliceSource])).rows).toHaveLength(0);
    });
  });

  it("다른 사용자의 원문에 일정을 쓸 수 없다", async () => {
    await asUser(db, BOB, async () => {
      const updated = await db.query(`update public.sources set meeting = null where id = $1 returning id`, [aliceSource]);
      expect(updated.rows).toHaveLength(0);
      await expect(
        db.query(`insert into public.sources (user_id, kind, raw_text, occurred_at, meeting) values ($1, 'meeting', 'x', now(), $2::jsonb)`, [ALICE, JSON.stringify(MEETING)]),
      ).rejects.toThrow(/row-level security/);
    });
    const { rows } = await db.query<{ meeting: unknown }>(`select meeting from public.sources where id = $1`, [aliceSource]);
    expect(rows[0].meeting).toEqual(MEETING);
  });
});

describe("sources.meeting가 남는 때 · 지워지는 때", () => {
  it("90일 본문 삭제(purge_expired_source_text)는 raw_text만 비우고 일정은 남긴다 (제목 · 관련자와 같은 취급)", async () => {
    const old = await insertSource(ALICE, { ...MEETING, calendar_event_id: "evt-old" }, { createdDaysAgo: 100 });
    await db.query(`select * from public.purge_expired_source_text(now() - interval '90 days', 5000)`);
    const { rows } = await db.query<{ raw_text: string; purged: boolean; meeting: { calendar_event_id: string } }>(
      `select raw_text, raw_text_purged_at is not null as purged, meeting from public.sources where id = $1`,
      [old],
    );
    expect(rows[0]).toMatchObject({ raw_text: "", purged: true, meeting: { calendar_event_id: "evt-old" } });
  });

  it("연결을 끊어도(G11) 원문과 일정은 남는다: connection_id만 비워진다", async () => {
    const { rows: before } = await db.query<{ ok: boolean }>(`select public.disconnect_connection($1, $2) as ok`, [ALICE, connection]);
    expect(before[0].ok).toBe(true);
    const { rows } = await db.query<{ raw_text: string; connection_id: string | null; meeting: unknown }>(
      `select raw_text, connection_id, meeting from public.sources where id = $1`,
      [aliceSource],
    );
    expect(rows[0].connection_id).toBeNull();
    expect(rows[0].raw_text).toContain("Jordan Lee");
    expect(rows[0].meeting).toEqual(MEETING);
  });

  it("계정을 지우면 원문 행과 함께 지워진다", async () => {
    await db.query(`delete from auth.users where id = $1`, [ALICE]);
    expect((await db.query(`select 1 from public.sources where user_id = $1`, [ALICE])).rows).toHaveLength(0);
  });
});
