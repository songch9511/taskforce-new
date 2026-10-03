import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 본 것 표시 (20261025000000_action_seen, U1 바뀜 점): action_events에 user_seen을 더한다.
// 서버(service role)만 쓰고(POST /api/v1/actions/:id/seen), 앱은 자기 이벤트를 읽기만 한다. actions 행은 바뀌지 않는다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;
let action: string;

const insertEvent = (type: string, actor = "user", userId = ALICE, actionId = action) =>
  db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, $3, $4)`, [userId, actionId, type, actor]);

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  const { rows } = await db.query<{ id: string }>(
    `insert into public.actions (user_id, title, last_activity_at) values ($1, '제안서 발송', '2026-10-01T01:00:00Z') returning id`,
    [ALICE],
  );
  action = rows[0].id;
  await insertEvent("created", "ai");
  await insertEvent("due_changed", "ai");
}, 60_000);

describe("user_seen 이벤트", () => {
  it("서버(service role)는 user_seen을 남길 수 있고, actions 행(버전 · 활동 시각 · 수정 시각)은 그대로다", async () => {
    const before = (await db.query<{ version: number; last_activity_at: Date; updated_at: Date }>(`select version, last_activity_at, updated_at from public.actions where id = $1`, [action])).rows[0];
    await insertEvent("user_seen");
    const after = (await db.query<{ version: number; last_activity_at: Date; updated_at: Date }>(`select version, last_activity_at, updated_at from public.actions where id = $1`, [action])).rows[0];
    expect(after).toEqual(before);
    const { rows } = await db.query<{ type: string; actor: string; before: unknown; after: unknown; source_id: string | null }>(
      `select type, actor, before, after, source_id from public.action_events where action_id = $1 and type = 'user_seen'`,
      [action],
    );
    expect(rows).toEqual([{ type: "user_seen", actor: "user", before: null, after: null, source_id: null }]);
  });

  it("기존 이벤트 종류 · 주체는 그대로 받고, 모르는 종류 · 주체는 여전히 거절한다", async () => {
    for (const type of [
      "created", "due_changed", "scope_changed", "owner_changed", "merged", "completed", "dropped", "reopened",
      "user_edited", "user_deleted", "user_confirmed", "user_started", "user_reported_missing", "user_created", "user_unstarted",
    ]) {
      await insertEvent(type, type.startsWith("user_") ? "user" : "ai");
    }
    await insertEvent("artifact_created", "agent");
    await expect(insertEvent("user_peeked")).rejects.toThrow(/action_events_type_check/);
    await expect(insertEvent("user_seen", "robot")).rejects.toThrow(/action_events_actor_check/);
  });

  it("앱(로그인한 사용자)은 user_seen을 직접 남길 수 없다: 클라이언트 쓰기 차단 그대로", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`insert into public.action_events (action_id, type, actor) values ($1, 'user_seen', 'user')`, [action])).rejects.toThrow(/permission denied/);
      await expect(db.query(`delete from public.action_events where action_id = $1 and type = 'user_seen'`, [action])).rejects.toThrow(/permission denied/);
    });
  });

  it("본인은 자기 user_seen을 읽고, 다른 사용자에게는 보이지 않는다 (RLS)", async () => {
    const seen = () => db.query<{ n: number }>(`select count(*)::int n from public.action_events where action_id = $1 and type = 'user_seen'`, [action]);
    expect((await asUser(db, ALICE, seen)).rows[0].n).toBe(1);
    expect((await asUser(db, BOB, seen)).rows[0].n).toBe(0);
    expect((await asUser(db, BOB, () => db.query(`select 1 from public.action_events where action_id = $1`, [action]))).rows).toEqual([]);
  });

  it("다른 사용자의 할 일에는 남길 수 없다 (Action과 같은 사용자, 복합 외래키)", async () => {
    await expect(insertEvent("user_seen", "user", BOB)).rejects.toThrow(/foreign key/);
  });
});
