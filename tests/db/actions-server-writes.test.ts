import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const vector = (hot: number) => `[${Array.from({ length: 1536 }, (_, i) => (i === hot ? 1 : 0)).join(",")}]`;

let db: PGlite;
let action: string;
let source: string;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  source = (await db.query<{ id: string }>(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'meeting', 'x', now()) returning id`, [ALICE])).rows[0].id;
  action = (await db.query<{ id: string }>(`insert into public.actions (user_id, title, embedding) values ($1, '제안서 발송', $2) returning id`, [ALICE, vector(0)])).rows[0].id;
  await db.query(`insert into public.actions (user_id, title, embedding, status) values ($1, '끝난 일', $2, 'done'), ($3, '남의 일', $2, 'open')`, [ALICE, vector(0), BOB]);
  await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, 'q', 'created')`, [ALICE, action, source]);
  await db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'created', 'ai')`, [ALICE, action]);
}, 60_000);

describe("Action은 서버만 쓴다 (20260929000000_actions_server_writes)", () => {
  it("본인 Action · 근거 · 이벤트는 읽을 수 있다", async () => {
    await asUser(db, ALICE, async () => {
      expect((await db.query(`select id from public.actions`)).rows).toHaveLength(2);
      expect((await db.query(`select id from public.evidence`)).rows).toHaveLength(1);
      expect((await db.query(`select id from public.action_events`)).rows).toHaveLength(1);
    });
  });

  it.each([
    ["actions 추가", `insert into public.actions (title) values ('직접 만든 일')`],
    ["actions 수정", `update public.actions set title = '몰래 고침'`],
    ["actions 삭제", `delete from public.actions`],
    ["claims 추가", `insert into public.claims (action_id, field, value, occurred_at, speaker_role, certainty, directness, audience, origin) values ('${"00000000-0000-0000-0000-000000000000"}', 'due', '2026-01-01', now(), 'me', 'firm', 'first_hand', 'shared', 'user')`],
    ["evidence 삭제", `delete from public.evidence`],
    ["action_events 추가", `insert into public.action_events (action_id, type, actor) values ('${"00000000-0000-0000-0000-000000000000"}', 'user_edited', 'user')`],
  ])("클라이언트는 %s을(를) 할 수 없다", async (_label, sql) => {
    await asUser(db, ALICE, async () => {
      const result = await db.query(sql).then(
        (r) => r.affectedRows ?? 0,
        () => "blocked",
      );
      // 정책이 없어 막히거나(오류) 한 행도 바뀌지 않는다.
      expect(result === "blocked" || result === 0).toBe(true);
    });
    expect((await db.query(`select title from public.actions where id = $1`, [action])).rows).toEqual([{ title: "제안서 발송" }]);
  });

  it("사용자가 직접 고친 Claim은 원문 없이 남길 수 있고, 원문 Claim은 원문이 있어야 한다", async () => {
    await db.query(
      `insert into public.claims (user_id, action_id, field, value, occurred_at, speaker_role, certainty, directness, audience, origin)
       values ($1, $2, 'due', '2026-10-01', now(), 'me', 'firm', 'first_hand', 'shared', 'user')`,
      [ALICE, action],
    );
    await expect(
      db.query(
        `insert into public.claims (user_id, action_id, field, value, occurred_at, speaker_role, certainty, directness, audience)
         values ($1, $2, 'due', '2026-10-01', now(), 'me', 'firm', 'first_hand', 'shared')`,
        [ALICE, action],
      ),
    ).rejects.toThrow(/claims_source_origin/);
  });

  it("매칭 함수는 그 사용자의 열린 Action만 가까운 순으로 돌려준다", async () => {
    const { rows } = await db.query<{ id: string; similarity: number }>(`select * from public.match_open_actions($1, $2, 5)`, [ALICE, vector(0)]);
    expect(rows).toEqual([{ id: action, similarity: 1 }]);
  });

  it("매칭 함수는 클라이언트가 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select * from public.match_open_actions($1, $2, 5)`, [BOB, vector(0)])).rejects.toThrow(/permission denied/);
    });
  });

  it("기기 토큰은 본인 것만 보이고, 클라이언트가 직접 넣을 수 없다", async () => {
    await db.query(`insert into public.devices (user_id, token, platform) values ($1, 'tok-a', 'ios'), ($2, 'tok-b', 'macos')`, [ALICE, BOB]);
    await asUser(db, ALICE, async () => {
      expect((await db.query<{ token: string }>(`select token from public.devices`)).rows).toEqual([{ token: "tok-a" }]);
      const inserted = await db.query(`insert into public.devices (token, platform) values ('x', 'ios')`).then(() => "ok", () => "blocked");
      expect(inserted).toBe("blocked");
    });
  });
});
