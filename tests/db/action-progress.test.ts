import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { changeEvents, projectAction } from "@/lib/actions/project";
import { actionRowValues, claimToRow } from "@/lib/actions/rows";
import { userClaims, userCreatedAction } from "@/lib/actions/user-claims";
import type { Claim } from "@/lib/pipeline/resolve";

import { asUser, createLocalSupabase } from "./local-supabase";

// 작업 상태 (20261010000000_action_progress): set_action_progress가 상태 쓰기(write_action)와 착수 시각 바꾸기를
// 한 트랜잭션으로 한다. 서버(setActionProgress)가 넘기는 것과 같은 모양으로 부른다 (lib/actions/db-store.ts writeProgress).

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const ACTION = "77777777-7777-4777-8777-777777777777";

let db: PGlite;
let n = 0;
const newId = () => `88888888-8888-4888-8888-${String(++n).padStart(12, "0")}`;
/** 지금까지 쓴 사용자 Claim (서버는 DB에서 읽는다) */
let claims: Claim[] = [];
const NO_EVIDENCE = { sourceId: null, quote: null };

type Row = { status: string; started_at: Date | null; version: number };
const actionRow = async () =>
  (await db.query<Row>(`select status, started_at, version from public.actions where id = $1`, [ACTION])).rows[0];
const eventTypes = async () =>
  (await db.query<{ type: string }>(`select type from public.action_events where action_id = $1 order by created_at, type`, [ACTION])).rows.map((r) => r.type);
const metricCount = async () =>
  (await db.query<{ n: number }>(`select count(*)::int n from public.metric_events where action_id = $1 and type = 'action_started'`, [ACTION])).rows[0].n;

/** 상태를 바꾸는 쓰기 (lib/actions/service.ts userChangeWrite와 같다: 사용자 Claim + user_edited) */
function statusWrite(value: "open" | "done") {
  const before = projectAction("견적서 보내기", claims);
  const added = userClaims([{ field: "status", value }], new Date(), newId);
  const after = projectAction("견적서 보내기", [...claims, ...added]);
  const events = changeEvents(before, after, "updated").map((e) => ({ ...e, type: "user_edited", rule: "user", actor: "user", source_id: null }));
  return { added, action: actionRowValues(after), claims: added.map((c) => claimToRow(c, ALICE, ACTION, NO_EVIDENCE)), events };
}

async function progress(options: { version: number; status?: "open" | "done"; started: boolean | null; userId?: string; actionOverride?: Record<string, unknown> }) {
  const write = options.status ? statusWrite(options.status) : null;
  const { rows } = await db.query<{ set_action_progress: boolean }>(
    `select public.set_action_progress($1, $2, $3, $4::jsonb, $5::jsonb, '[]'::jsonb, $6::jsonb, $7)`,
    [
      options.userId ?? ALICE,
      ACTION,
      options.version,
      write ? JSON.stringify({ ...write.action, ...options.actionOverride }) : null,
      JSON.stringify(write?.claims ?? []),
      JSON.stringify(write?.events ?? []),
      options.started,
    ],
  );
  if (rows[0].set_action_progress && write) claims = [...claims, ...write.added];
  return rows[0].set_action_progress;
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  // 직접 추가한 할 일 하나 (열림, 착수 전)
  const created = userCreatedAction({ title: "견적서 보내기", dueDate: null, sourceId: null }, new Date("2026-09-28T10:00:00+09:00"), newId);
  claims = created.claims;
  await db.query(`select public.write_action($1, $2, null, $3::jsonb, $4::jsonb, '[]'::jsonb, $5::jsonb)`, [
    ALICE,
    ACTION,
    JSON.stringify({ ...actionRowValues(created.projected), counterpart: null, embedding: null }),
    JSON.stringify(created.claims.map((c) => claimToRow(c, ALICE, ACTION, NO_EVIDENCE))),
    JSON.stringify([{ ...created.event, actor: "user", source_id: null }]),
  ]);
}, 60_000);

describe("set_action_progress: 작업 상태를 한 트랜잭션으로", () => {
  it("할 일 → 진행 중: start_action과 같다 (user_started · action_started), 버전은 그대로", async () => {
    expect(await progress({ version: 0, started: true })).toBe(true);
    const row = await actionRow();
    expect(row).toMatchObject({ status: "open", version: 0 });
    expect(row.started_at).not.toBeNull();
    expect(await eventTypes()).toEqual(["user_created", "user_started"]);
    expect(await metricCount()).toBe(1);
  });

  it("이미 진행 중이면 이벤트 · 지표를 남기지 않는다", async () => {
    const before = await actionRow();
    expect(await progress({ version: 0, started: true })).toBe(true);
    expect(await actionRow()).toEqual(before);
    expect(await eventTypes()).toEqual(["user_created", "user_started"]);
    expect(await metricCount()).toBe(1);
  });

  it("진행 중 → 할 일: 착수 시각을 지우고 user_unstarted(이전 시각)를 남긴다. 첫 착수 이벤트 · 지표는 남는다", async () => {
    const { started_at } = await actionRow();
    expect(await progress({ version: 0, started: false })).toBe(true);
    expect(await actionRow()).toMatchObject({ status: "open", started_at: null, version: 0 });
    const { rows } = await db.query<{ before: { started_at: string }; after: { started_at: null }; actor: string; rule: string | null }>(
      `select before, after, actor, rule from public.action_events where action_id = $1 and type = 'user_unstarted'`,
      [ACTION],
    );
    expect(rows).toHaveLength(1);
    expect(new Date(rows[0].before.started_at)).toEqual(started_at);
    expect(rows[0]).toMatchObject({ after: { started_at: null }, actor: "user", rule: null });
    expect(await eventTypes()).toEqual(["user_created", "user_started", "user_unstarted"]);
    expect(await metricCount()).toBe(1);
    // 이미 할 일이면 아무것도 남기지 않는다
    expect(await progress({ version: 0, started: false })).toBe(true);
    expect(await eventTypes()).toEqual(["user_created", "user_started", "user_unstarted"]);
  });

  it("할 일 → 완료: 사용자 Claim · user_edited (PATCH status done과 같다), 버전을 올린다", async () => {
    expect(await progress({ version: 0, status: "done", started: null })).toBe(true);
    expect(await actionRow()).toMatchObject({ status: "done", started_at: null, version: 1 });
    const { rows } = await db.query(`select before, after, actor, rule from public.action_events where action_id = $1 and type = 'user_edited'`, [ACTION]);
    expect(rows).toEqual([{ before: { status: "open" }, after: { status: "done" }, actor: "user", rule: "user" }]);
  });

  it("버전이 어긋나면(그 사이 누가 썼으면) 착수 시각만 바꾸는 것도 쓰지 않는다", async () => {
    expect(await progress({ version: 0, started: true })).toBe(false);
    expect(await actionRow()).toMatchObject({ status: "done", started_at: null, version: 1 });
  });

  it("중간에 실패하면 다시 열기까지 모두 되돌린다 (반쪽 상태가 남지 않는다)", async () => {
    // 상태 쓰기는 되지만 열린 Action이 아니라 착수(start_action)가 실패하는 쓰기
    const claimCount = async () => (await db.query<{ n: number }>(`select count(*)::int n from public.claims where action_id = $1`, [ACTION])).rows[0].n;
    const before = await claimCount();
    await expect(progress({ version: 1, status: "open", started: true, actionOverride: { status: "done" } })).rejects.toThrow(/open action not found/);
    expect(await actionRow()).toMatchObject({ status: "done", started_at: null, version: 1 });
    expect(await claimCount()).toBe(before);
    expect(await eventTypes()).toEqual(["user_created", "user_started", "user_unstarted", "user_edited"]);
  });

  it("완료 → 진행 중: 다시 열기(user_edited)와 착수(user_started · action_started)를 함께 쓴다", async () => {
    expect(await progress({ version: 1, status: "open", started: true })).toBe(true);
    const row = await actionRow();
    expect(row).toMatchObject({ status: "open", version: 2 });
    expect(row.started_at).not.toBeNull();
    expect(await eventTypes()).toEqual(["user_created", "user_started", "user_unstarted", "user_edited", "user_edited", "user_started"]);
    expect(await metricCount()).toBe(2);
  });

  it("진행 중 → 완료 → 할 일: 착수 시각은 완료해도 남고, 할 일로 다시 열 때 함께 지운다", async () => {
    expect(await progress({ version: 2, status: "done", started: null })).toBe(true);
    expect((await actionRow()).started_at).not.toBeNull();
    expect(await progress({ version: 3, status: "open", started: false })).toBe(true);
    expect(await actionRow()).toMatchObject({ status: "open", started_at: null, version: 4 });
    const { rows } = await db.query<{ type: string }>(
      `select type from public.action_events where action_id = $1 and created_at = (select max(created_at) from public.action_events where action_id = $1) order by type`,
      [ACTION],
    );
    expect(rows.map((r) => r.type)).toEqual(["user_edited", "user_unstarted"]);
  });

  it("다른 사용자의 Action은 없는 것으로 본다", async () => {
    await expect(progress({ version: 4, started: true, userId: BOB })).rejects.toThrow(/action not found/);
  });

  it("클라이언트는 부를 수 없고, user_unstarted를 직접 남길 수도 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.set_action_progress($1, $2, 4, null, '[]', '[]', '[]', true)`, [ALICE, ACTION])).rejects.toThrow(/permission denied/);
      await expect(db.query(`insert into public.action_events (action_id, type, actor) values ($1, 'user_unstarted', 'user')`, [ACTION])).rejects.toThrow();
    });
  });

  it("모르는 이벤트 종류는 여전히 거절한다", async () => {
    await expect(
      db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_paused', 'user')`, [ALICE, ACTION]),
    ).rejects.toThrow(/action_events_type_check/);
  });
});
