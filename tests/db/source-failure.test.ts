import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { SOURCE_FAILURE_CODES } from "@/lib/api/contract";

import { asUser, createLocalSupabase } from "./local-supabase";

// 원문 처리 실패 가시화 (20261020000000_source_failure_visibility, docs/HANDOFF.md W4):
// sources.processing_error_code(실패 까닭)와 서버 전용 지표 이벤트 source_failed.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

/** 클라이언트가 막혔으면 "blocked", 아니면 바뀐 행 수 */
const attempt = (sql: string, params: unknown[] = []) =>
  db.query(sql, params).then(
    (r) => r.affectedRows ?? 0,
    () => "blocked" as const,
  );

async function insertSource(userId: string, status = "pending", code: string | null = null): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.sources (user_id, kind, raw_text, occurred_at, processing_status, processed_at, processing_error_code)
     values ($1, 'message', '금요일까지 보낼게요', now(), $2, case when $2 = 'failed' then now() end, $3) returning id`,
    [userId, status, code],
  );
  return rows[0].id;
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("sources.processing_error_code", () => {
  it("정해진 까닭 코드(계약 SOURCE_FAILURE_CODES와 같은 목록)와 null만 받는다. 옛 행 · 새 원문은 null이다", async () => {
    for (const code of SOURCE_FAILURE_CODES) await insertSource(ALICE, "failed", code);
    const fresh = await insertSource(ALICE);
    expect((await db.query(`select processing_error_code from public.sources where id = $1`, [fresh])).rows).toEqual([{ processing_error_code: null }]);
    await expect(insertSource(ALICE, "failed", "rate_limited")).rejects.toThrow(/check/);
    await expect(db.query(`update public.sources set processing_error_code = 'unknown' where id = $1`, [fresh])).rejects.toThrow(/check/);
  });

  it("앱은 자기 실패 원문의 까닭만 읽는다 (다른 사용자의 실패는 안 보인다)", async () => {
    const bobs = await insertSource(BOB, "failed", "ai_quota");
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ id: string; processing_error_code: string | null }>(
        `select id, processing_error_code from public.sources where processing_status = 'failed'`,
      );
      expect(rows.length).toBeGreaterThan(0);
      expect(rows.map((r) => r.id)).not.toContain(bobs);
      expect(rows.every((r) => r.processing_error_code !== null)).toBe(true);
      expect(await attempt(`update public.sources set processing_error_code = 'internal' where id = $1`, [bobs])).toBe(0);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select processing_error_code from public.sources where processing_status = 'failed'`)).rows).toEqual([{ processing_error_code: "ai_quota" }]);
    });
  });

  it("GET /api/v1/now가 쓰는 실패 원문 부분 인덱스가 있다", async () => {
    const { rows } = await db.query<{ indexdef: string }>(`select indexdef from pg_indexes where indexname = 'sources_failed_idx'`);
    expect(rows).toHaveLength(1);
    expect(rows[0].indexdef).toMatch(/WHERE \(processing_status = 'failed'::text\)/);
  });
});

describe("지표 이벤트 source_failed", () => {
  it("서버는 서비스와 함께(직접 넣은 원문은 서비스 없이) 남길 수 있고, 모르는 서비스는 막는다", async () => {
    await db.query(`insert into public.metric_events (user_id, type, provider) values ($1, 'source_failed', 'notion'), ($1, 'source_failed', null)`, [ALICE]);
    const { rows } = await db.query<{ provider: string | null }>(`select provider from public.metric_events where user_id = $1 and type = 'source_failed' order by provider nulls last`, [ALICE]);
    expect(rows).toEqual([{ provider: "notion" }, { provider: null }]);
    await expect(db.query(`insert into public.metric_events (user_id, type, provider) values ($1, 'source_failed', 'zoom')`, [ALICE])).rejects.toThrow(/check/);
    // 이전 종류는 그대로 받는다
    for (const type of ["app_opened", "action_started", "handoff_used", "connection_created", "connection_reauth", "reconnect_notified"]) {
      await db.query(`insert into public.metric_events (user_id, type) values ($1, $2)`, [ALICE, type]);
    }
  });

  it("앱은 source_failed를 남길 수 없다 (app_opened는 그대로). 자기 이벤트만 보인다", async () => {
    await asUser(db, ALICE, async () => {
      expect(await attempt(`insert into public.metric_events (type) values ('source_failed')`)).toBe("blocked");
      expect(await attempt(`insert into public.metric_events (type) values ('app_opened')`)).toBe(1);
      expect((await db.query(`select 1 from public.metric_events where type = 'source_failed'`)).rows).toHaveLength(2);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select 1 from public.metric_events where type = 'source_failed'`)).rows).toEqual([]);
    });
  });
});
