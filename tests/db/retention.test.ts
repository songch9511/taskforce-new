import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 원문 보관 기간 (20261006000000_source_text_retention): 90일이 지난 원문은 글 · structured(kind='task'의 할 일 스냅샷)만 비우고,
// 판정 기록(그 원문의 것이거나 90일이 지난 것)은 지운다. 근거 인용 · Claim · 행 · 제목 · 링크는 남는다.
// 하루 지난 시도 기록(rate_limit_events · missing_reports, 한도 창은 최대 10분)도 함께 지운다.

const ALICE = "00000000-0000-0000-0000-00000000000a";

let db: PGlite;
const ids: Record<string, string> = {};

async function seedSource(key: string, createdDaysAgo: number) {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.sources (user_id, kind, title, raw_text, occurred_at, external_url, created_at)
     values ($1, 'meeting', $2, '김대표: 금요일까지 제안서 부탁해요.', now(), 'https://notion.so/p', now() - make_interval(days => $3)) returning id`,
    [ALICE, key, createdDaysAgo],
  );
  ids[key] = rows[0].id;
  const action = await db.query<{ id: string }>(`insert into public.actions (user_id, title) values ($1, '제안서') returning id`, [ALICE]);
  await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '금요일까지 제안서', 'created')`, [
    ALICE,
    action.rows[0].id,
    rows[0].id,
  ]);
  await db.query(
    `insert into public.judge_logs (user_id, source_id, candidate, jev_answers, decision, model_version, created_at)
     values ($1, $2, '{"quote":"금요일까지 제안서"}', '{}', 'auto', 'jev', now() - make_interval(days => $3))`,
    [ALICE, rows[0].id, createdDaysAgo],
  );
}

type PurgeCounts = { sources_purged: number; judge_logs_deleted: number; rate_limit_events_deleted: number; missing_reports_deleted: number };

const purge = async (before = "now() - interval '90 days'", limit = 5000) =>
  (await db.query<PurgeCounts>(`select * from public.purge_expired_source_text(${before}, $1)`, [limit])).rows[0];

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com')", [ALICE]);
  await seedSource("old", 91);
  await seedSource("old2", 120);
  await seedSource("recent", 10);
}, 60_000);

describe("purge_expired_source_text", () => {
  it("90일이 지난 원문의 글만 비우고 지운 시각을 남긴다. 한 번에 p_limit개씩", async () => {
    expect(await purge(undefined, 1)).toEqual({ sources_purged: 1, judge_logs_deleted: 1, rate_limit_events_deleted: 0, missing_reports_deleted: 0 });
    expect(await purge(undefined, 1)).toEqual({ sources_purged: 1, judge_logs_deleted: 1, rate_limit_events_deleted: 0, missing_reports_deleted: 0 });
    // 이미 비운 원문은 다시 세지 않는다
    expect(await purge()).toEqual({ sources_purged: 0, judge_logs_deleted: 0, rate_limit_events_deleted: 0, missing_reports_deleted: 0 });

    const { rows } = await db.query<{ title: string; raw_text: string; purged: boolean; external_url: string }>(
      `select title, raw_text, raw_text_purged_at is not null as purged, external_url from public.sources order by title`,
    );
    expect(rows).toEqual([
      { title: "old", raw_text: "", purged: true, external_url: "https://notion.so/p" },
      { title: "old2", raw_text: "", purged: true, external_url: "https://notion.so/p" },
      { title: "recent", raw_text: "김대표: 금요일까지 제안서 부탁해요.", purged: false, external_url: "https://notion.so/p" },
    ]);
  });

  it("근거 인용은 남고, 90일이 지난 판정 기록만 지운다", async () => {
    expect((await db.query(`select 1 from public.evidence`)).rows).toHaveLength(3);
    const { rows } = await db.query<{ source_id: string }>(`select source_id from public.judge_logs`);
    expect(rows).toEqual([{ source_id: ids.recent }]);
  });

  it("kind가 task면 structured(할 일 스냅샷)도 비운다", async () => {
    const { rows } = await db.query<{ id: string }>(
      `insert into public.sources (user_id, kind, title, raw_text, structured, occurred_at, created_at)
       values ($1, 'task', '할 일', '# 할 일\n상태: Done', '{"snapshot":{"title":"할 일"},"editedByUser":false}', now(), now() - interval '91 days')
       returning id`,
      [ALICE],
    );
    const taskId = rows[0].id;
    expect(await purge()).toMatchObject({ sources_purged: 1 });
    const { rows: after } = await db.query<{ raw_text: string; structured: unknown }>(`select raw_text, structured from public.sources where id = $1`, [taskId]);
    expect(after[0]).toEqual({ raw_text: "", structured: null });
  });

  it("task가 아니면 structured는 그대로 둔다", async () => {
    const { rows } = await db.query<{ id: string }>(
      `insert into public.sources (user_id, kind, title, raw_text, structured, occurred_at, created_at)
       values ($1, 'note', '메모', '메모 내용', '{"keep":true}', now(), now() - interval '91 days')
       returning id`,
      [ALICE],
    );
    const noteId = rows[0].id;
    expect(await purge()).toMatchObject({ sources_purged: 1 });
    const { rows: after } = await db.query<{ raw_text: string; structured: unknown }>(`select raw_text, structured from public.sources where id = $1`, [noteId]);
    expect(after[0]).toEqual({ raw_text: "", structured: { keep: true } });
  });

  it("원문이 이미 비워진 판정 기록은 나이와 상관없이 지운다", async () => {
    // ids.old는 첫 테스트에서 이미 비워졌다 (raw_text_purged_at is not null). 그 뒤에 남은 후보(예: 지연 처리)도 함께 지운다.
    await db.query(
      `insert into public.judge_logs (user_id, source_id, candidate, jev_answers, decision, model_version, created_at)
       values ($1, $2, '{"quote":"새 후보"}', '{}', 'auto', 'jev', now())`,
      [ALICE, ids.old],
    );
    expect(await purge()).toMatchObject({ judge_logs_deleted: 1 });
    expect((await db.query(`select 1 from public.judge_logs where source_id = $1`, [ids.old])).rows).toHaveLength(0);
  });

  it("하루 지난 시도 기록(rate_limit_events · missing_reports)을 지운다", async () => {
    await db.query(`insert into public.rate_limit_events (user_id, kind, created_at) values ($1, 'ask', now() - interval '2 days'), ($1, 'ask', now())`, [ALICE]);
    await db.query(`insert into public.missing_reports (user_id, created_at) values ($1, now() - interval '2 days'), ($1, now())`, [ALICE]);
    expect(await purge()).toMatchObject({ rate_limit_events_deleted: 1, missing_reports_deleted: 1 });
    const remainingEvents = await db.query<{ n: number }>(`select count(*)::int as n from public.rate_limit_events where user_id = $1`, [ALICE]);
    const remainingReports = await db.query<{ n: number }>(`select count(*)::int as n from public.missing_reports where user_id = $1`, [ALICE]);
    expect(remainingEvents.rows[0].n).toBe(1);
    expect(remainingReports.rows[0].n).toBe(1);
  });

  it("클라이언트는 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select * from public.purge_expired_source_text(now())`)).rejects.toThrow(/permission denied/);
    });
  });
});
