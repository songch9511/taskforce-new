import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("원문 처리 상태 (20260926000000_source_processing)", () => {
  it("새 원문은 pending으로 시작하고 처리 결과를 기록할 수 있다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ id: string; processing_status: string }>(
        `insert into public.sources (kind, raw_text, occurred_at) values ('note', 'x', now()) returning id, processing_status`,
      );
      expect(rows[0].processing_status).toBe("pending");

      await db.query(
        `update public.sources set processing_status = 'done', processed_at = now(), processing_summary = '{"auto":1}' where id = $1`,
        [rows[0].id],
      );
      await db.query(
        `insert into public.judge_logs (source_id, candidate, jev_answers, decision, model_version)
         values ($1, '{}', '{}', 'auto', 'test')`,
        [rows[0].id],
      );
      const logs = await db.query(`select 1 from public.judge_logs where source_id = $1`, [rows[0].id]);
      expect(logs.rows).toHaveLength(1);
    });
  });

  it("정해진 상태 값만 받는다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(
        db.query(`insert into public.sources (kind, raw_text, occurred_at, processing_status) values ('note', 'x', now(), 'queued')`),
      ).rejects.toThrow(/check constraint/);
    });
  });

  it("다른 사용자의 원문 상태는 바꿀 수 없다", async () => {
    const { rows } = await asUser(db, ALICE, () =>
      db.query<{ id: string }>(`insert into public.sources (kind, raw_text, occurred_at) values ('note', 'x', now()) returning id`),
    );
    await asUser(db, BOB, async () => {
      const updated = await db.query(`update public.sources set processing_status = 'failed' where id = $1 returning id`, [rows[0].id]);
      expect(updated.rows).toHaveLength(0);
    });
  });
});
