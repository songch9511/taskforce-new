import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;
let aliceConnection: string;
let bobConnection: string;
let aliceAction: string;
let taskSource: string;

const insertClaim = (origin: string, sourceId: string | null, quote: string | null) =>
  db.query(
    `insert into public.claims (user_id, action_id, source_id, field, value, quote, occurred_at, speaker_role, certainty, directness, audience, origin, channel)
     values ($1, $2, $3, 'status', 'done', $4, now(), 'me', 'firm', 'first_hand', 'shared', $5, 'task')`,
    [ALICE, aliceAction, sourceId, quote, origin],
  );

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  const connect = async (user: string, ws: string) =>
    (await db.query<{ id: string }>(`insert into public.connections (user_id, provider, external_account_id) values ($1, 'notion', $2) returning id`, [user, ws])).rows[0].id;
  aliceConnection = await connect(ALICE, "ws-a");
  bobConnection = await connect(BOB, "ws-b");
  aliceAction = (await db.query<{ id: string }>(`insert into public.actions (user_id, title) values ($1, 'UI 레이아웃 이미지 보내기') returning id`, [ALICE])).rows[0].id;
  taskSource = (
    await db.query<{ id: string }>(
      `insert into public.sources (user_id, kind, raw_text, structured, occurred_at, connection_id, external_id, external_version)
       values ($1, 'task', '# UI 레이아웃 이미지 보내기\n상태: Done', '{"status": "done"}', now(), $2, 'page-1', 'v1') returning id`,
      [ALICE, aliceConnection],
    )
  ).rows[0].id;
}, 60_000);

describe("구조화된 할 일 (20260930000000_structured_tasks)", () => {
  it("원문 종류 task와 속성 스냅샷을 저장한다", async () => {
    const { rows } = await db.query<{ kind: string; structured: { status: string } }>(`select kind, structured from public.sources where id = $1`, [taskSource]);
    expect(rows[0]).toEqual({ kind: "task", structured: { status: "done" } });
  });

  it("tracker Claim은 채널 task로 저장되고, 원문 · 인용이 있어야 한다", async () => {
    await insertClaim("tracker", taskSource, "상태: Done");
    await expect(insertClaim("tracker", null, null)).rejects.toThrow(/claims_source_origin/);
    await expect(insertClaim("robot", taskSource, "q")).rejects.toThrow(/claims_origin_check/);
  });

  it("같은 외부 할 일은 한 Action에만 이어진다", async () => {
    const link = () =>
      db.query(`insert into public.action_links (user_id, connection_id, external_id, action_id) values ($1, $2, 'page-1', $3)`, [ALICE, aliceConnection, aliceAction]);
    await link();
    await expect(link()).rejects.toThrow(/duplicate key/);
  });

  it("다른 사용자의 연결이나 Action으로는 이을 수 없다", async () => {
    await expect(
      db.query(`insert into public.action_links (user_id, connection_id, external_id, action_id) values ($1, $2, 'page-2', $3)`, [BOB, bobConnection, aliceAction]),
    ).rejects.toThrow(/foreign key/);
    await expect(
      db.query(`insert into public.action_links (user_id, connection_id, external_id, action_id) values ($1, $2, 'page-3', $3)`, [ALICE, bobConnection, aliceAction]),
    ).rejects.toThrow(/foreign key/);
  });

  it("사용자는 자기 연결 표를 읽기만 한다", async () => {
    await asUser(db, ALICE, async () => {
      expect((await db.query(`select external_id from public.action_links`)).rows).toEqual([{ external_id: "page-1" }]);
      await expect(db.query(`delete from public.action_links`)).rejects.toThrow(/permission denied/);
      await expect(
        db.query(`insert into public.action_links (connection_id, external_id, action_id) values ($1, 'page-9', $2)`, [aliceConnection, aliceAction]),
      ).rejects.toThrow(/permission denied/);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select 1 from public.action_links`)).rows).toHaveLength(0);
    });
  });

  it("할 일마다 마지막으로 처리를 마친 버전과 처리를 마치지 못한 최근 버전을 돌려준다", async () => {
    const insert = (id: string, version: string, status: string, at: string) =>
      db.query(
        `insert into public.sources (user_id, kind, raw_text, structured, occurred_at, connection_id, external_id, external_version, processing_status)
         values ($1, 'task', 'x', '{}', $2, $3, $4, $5, $6)`,
        [ALICE, at, aliceConnection, id, version, status],
      );
    await db.query(`update public.sources set processing_status = 'done', occurred_at = '2026-09-22T00:00:00Z' where id = $1`, [taskSource]);
    await insert("page-1", "v2", "done", "2026-09-23T00:00:00Z");
    await insert("page-1", "v3", "failed", "2026-09-24T00:00:00Z");
    await insert("page-4", "v1", "failed", "2026-09-24T00:00:00Z");

    const { rows } = await db.query<{ external_id: string; external_version: string; processing_status: string; linked: boolean }>(
      `select external_id, external_version, processing_status, linked from public.task_source_states($1, $2, array['page-1', 'page-4', 'page-x'])
        order by external_id, processing_status`,
      [ALICE, aliceConnection],
    );
    expect(rows).toEqual([
      { external_id: "page-1", external_version: "v2", processing_status: "done", linked: true },
      { external_id: "page-1", external_version: "v3", processing_status: "failed", linked: true },
      { external_id: "page-4", external_version: "v1", processing_status: "failed", linked: false },
    ]);
    // 다른 사용자 범위로는 아무것도 보이지 않는다
    expect((await db.query(`select 1 from public.task_source_states($1, $2, array['page-1'])`, [BOB, aliceConnection])).rows).toHaveLength(0);
  });

  it("상태 함수는 클라이언트가 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select * from public.task_source_states($1, $2, array['page-1'])`, [ALICE, aliceConnection])).rejects.toThrow(/permission denied/);
    });
  });

  it("연결을 끊으면 연결 표도 지워지고 Action은 남는다", async () => {
    await db.query(`delete from public.connections where id = $1`, [aliceConnection]);
    expect((await db.query(`select 1 from public.action_links`)).rows).toHaveLength(0);
    expect((await db.query(`select 1 from public.actions where id = $1`, [aliceAction])).rows).toHaveLength(1);
  });
});

it("nonretryable task versions stay blocked in the sync state RPC", async () => {
  const connection = (await db.query<{ id: string }>(
    "insert into public.connections (user_id, provider, external_account_id) values ($1, 'notion', 'budget-test') returning id", [ALICE],
  )).rows[0].id;
  const id = (await db.query<{ id: string }>(
    `insert into public.sources (user_id, kind, raw_text, structured, occurred_at, connection_id, external_id, external_version, processing_status, processing_summary, processing_error_code)
     values ($1, 'task', 'x', '{}', now(), $2, 'budget-blocked', 'v1', 'failed', '{"retryable":false}', 'ai_budget_exhausted') returning id`,
    [ALICE, connection],
  )).rows[0].id;
  const { rows } = await db.query<{ source_id: string; processing_status: string }>(
    "select source_id, processing_status from task_source_states($1,$2,$3)", [ALICE, connection, ["budget-blocked"]],
  );
  expect(rows).toEqual([{ source_id: id, processing_status: "blocked" }]);
});
