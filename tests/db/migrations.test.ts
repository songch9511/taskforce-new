import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [
    ALICE,
    BOB,
  ]);
}, 60_000);

async function insertSource(): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.sources (kind, raw_text, occurred_at)
     values ('meeting', '금요일까지 제안서 보내드릴게요', '2026-09-22T10:00:00+09:00') returning id`,
  );
  return rows[0].id;
}

// Action은 서버(service role)만 만든다 (20260929000000_actions_server_writes).
async function insertAction(userId: string): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.actions (user_id, title, due_at) values ($1, '제안서 발송', '2026-09-26T18:00:00+09:00') returning id`,
    [userId],
  );
  return rows[0].id;
}

describe("초기 마이그레이션", () => {
  it("모든 테이블을 만든다", async () => {
    const { rows } = await db.query<{ table_name: string }>(
      `select table_name from information_schema.tables where table_schema = 'public' order by table_name`,
    );
    expect(rows.map((r) => r.table_name)).toEqual([
      "action_events",
      "action_links",
      "actions",
      "ai_budget_policy",
      "ai_spend_attempts",
      "claims",
      "connection_requests",
      "connection_secrets",
      "connections",
      "credit_accounts",
      "credit_ledger",
      "credit_rates",
      "devices",
      "evidence",
      "execution_actors",
      "execution_approvals",
      "execution_artifacts",
      "execution_controls",
      "execution_events",
      "execution_intents",
      "execution_policies",
      "execution_recipient_allowlist",
      "execution_runs",
      "execution_steps",
      "execution_tools",
      "execution_usage",
      "judge_logs",
      "metric_events",
      "missing_reports",
      "oauth_handoffs",
      "oauth_nonces",
      "profiles",
      "rate_limit_events",
      "review_accounts",
      "slack_messages",
      "slack_people",
      "slack_threads",
      "sources",
      "weekly_checks",
    ]);
  });

  it("모든 테이블에 RLS가 켜져 있다", async () => {
    const { rows } = await db.query<{ relname: string; relrowsecurity: boolean }>(
      `select c.relname, c.relrowsecurity from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind = 'r'`,
    );
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) expect(row, row.relname).toMatchObject({ relrowsecurity: true });
  });

  it("로그인한 사용자의 id가 user_id 기본값으로 들어간다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ user_id: string }>(
        `insert into public.sources (kind, raw_text, occurred_at)
         values ('note', '메모', now()) returning user_id`,
      );
      expect(rows[0].user_id).toBe(ALICE);
    });
  });

  it("다른 사용자의 행은 보이지 않는다", async () => {
    await asUser(db, ALICE, insertSource);
    await insertAction(ALICE);

    await asUser(db, BOB, async () => {
      const sources = await db.query("select * from public.sources");
      const actions = await db.query("select * from public.actions");
      expect(sources.rows).toHaveLength(0);
      expect(actions.rows).toHaveLength(0);
    });
  });

  it("다른 사용자 명의로는 행을 만들 수 없다", async () => {
    await asUser(db, BOB, async () => {
      await expect(
        db.query(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'note', 'x', now())`, [ALICE]),
      ).rejects.toThrow(/row-level security/);
    });
  });

  it("Claim은 다른 사용자의 Action을 가리킬 수 없다", async () => {
    const aliceAction = await insertAction(ALICE);
    const bobSource = await asUser(db, BOB, insertSource);
    // 서버 코드가 실수로 섞어도 복합 외래키가 막는다.
    await expect(
      db.query(
        `insert into public.claims
           (user_id, action_id, source_id, field, value, quote, occurred_at,
            speaker_role, certainty, directness, audience)
         values ($3, $1, $2, 'due', '2026-09-29', '월요일에 받아도 괜찮아요', now(),
                 'counterpart', 'firm', 'first_hand', 'shared')`,
        [aliceAction, bobSource, BOB],
      ),
    ).rejects.toThrow(/foreign key/);
  });

  it("같은 사용자의 Action과 원문으로는 Claim을 만들 수 있다", async () => {
    const actionId = await insertAction(ALICE);
    const sourceId = await asUser(db, ALICE, insertSource);
    const { rows } = await db.query<{ state: string }>(
      `insert into public.claims
         (user_id, action_id, source_id, field, value, value_text, quote, occurred_at,
          speaker_role, certainty, directness, audience)
       values ($3, $1, $2, 'due', '2026-09-26', '금요일까지', '금요일까지 제안서 보내드릴게요',
               '2026-09-22T10:00:00+09:00', 'me', 'firm', 'first_hand', 'shared')
       returning state`,
      [actionId, sourceId, ALICE],
    );
    expect(rows[0].state).toBe("active");
  });

  it("허용되지 않은 값은 거부한다", async () => {
    await expect(
      db.query(`insert into public.actions (user_id, title, status) values ($1, 'x', 'archived')`, [ALICE]),
    ).rejects.toThrow(/check constraint/);
  });

  it("Action을 고치면 updated_at이 갱신된다", async () => {
    const id = await insertAction(ALICE);
    await db.query(`update public.actions set updated_at = '2000-01-01' where id = $1`, [id]);
    await db.query(`update public.actions set title = '제안서 발송 (수정)' where id = $1`, [id]);
    const { rows } = await db.query<{ updated_at: Date }>(`select updated_at from public.actions where id = $1`, [id]);
    expect(rows[0].updated_at.getFullYear()).toBeGreaterThan(2000);
  });

  it("임베딩으로 가까운 Action을 찾을 수 있다", async () => {
    const near = `[${Array.from({ length: 1536 }, (_, i) => (i === 0 ? 1 : 0)).join(",")}]`;
    const far = `[${Array.from({ length: 1536 }, (_, i) => (i === 1 ? 1 : 0)).join(",")}]`;
    await db.query(`insert into public.actions (user_id, title, embedding) values ($3, '가까운 일', $1), ($3, '먼 일', $2)`, [
      near,
      far,
      ALICE,
    ]);
    const { rows } = await db.query<{ title: string }>(
      `select title from public.actions where embedding is not null
       order by embedding operator(extensions.<=>) $1::extensions.vector limit 1`,
      [near],
    );
    expect(rows[0].title).toBe("가까운 일");
  });
});

// sources.meeting (20261016000000_sources_meeting): 새 표 없이 열만 더한다. 자세한 검사는 sources-meeting.test.ts
describe("sources.meeting (회의 원문에 붙인 Calendar 일정)", () => {
  it("열이 있고, 사용자는 자기 원문의 일정만 본다", async () => {
    const { rows: columns } = await db.query<{ data_type: string }>(
      `select data_type from information_schema.columns where table_schema = 'public' and table_name = 'sources' and column_name = 'meeting'`,
    );
    expect(columns).toEqual([{ data_type: "jsonb" }]);

    const { rows } = await db.query<{ id: string }>(
      `insert into public.sources (user_id, kind, raw_text, occurred_at, meeting)
       values ($1, 'meeting', '회의 전사', now(), '{"calendar_event_id":"evt-1","title":"주간 회의","start":"2026-09-30T01:00:00Z","end":"2026-09-30T02:00:00Z"}') returning id`,
      [ALICE],
    );
    await asUser(db, ALICE, async () => {
      const mine = await db.query<{ meeting: { title: string } }>(`select meeting from public.sources where id = $1`, [rows[0].id]);
      expect(mine.rows[0].meeting.title).toBe("주간 회의");
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select meeting from public.sources where id = $1`, [rows[0].id])).rows).toHaveLength(0);
    });
  });
});

// 실행 receipt (20261023000000_execution_receipts): 새 표 없이 값 · 제약 · 함수만 더한다. 자세한 검사는 execution-receipts.test.ts
describe("실행 receipt 값 (원문 execution · Claim origin execution, field artifact · 근거 executed · 이벤트 artifact_created, agent)", () => {
  it("서버는 새 값으로 쓸 수 있고, 사용자는 receipt 원문을 직접 만들지 못한다", async () => {
    const actionId = await insertAction(ALICE);
    const { rows } = await db.query<{ id: string }>(
      `insert into public.sources (user_id, kind, raw_text, occurred_at, external_id, processing_status)
       values ($1, 'execution', '초안 저장: 제안서', now(), 'step-1', 'done') returning id`,
      [ALICE],
    );
    const sourceId = rows[0].id;
    await db.query(
      `insert into public.claims (user_id, action_id, source_id, field, value, quote, occurred_at, speaker_role, certainty, directness, audience, origin)
       values ($1, $2, $3, 'artifact', 'artifact-1', '초안 저장: 제안서', now(), 'me', 'firm', 'first_hand', 'private', 'execution')`,
      [ALICE, actionId, sourceId],
    );
    await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '초안 저장: 제안서', 'executed')`, [ALICE, actionId, sourceId]);
    await db.query(`insert into public.action_events (user_id, action_id, type, actor, source_id) values ($1, $2, 'artifact_created', 'agent', $3)`, [ALICE, actionId, sourceId]);

    await asUser(db, ALICE, async () => {
      expect((await db.query(`select kind from public.sources where id = $1`, [sourceId])).rows).toEqual([{ kind: "execution" }]);
      await expect(
        db.query(`insert into public.sources (kind, raw_text, occurred_at, external_id, processing_status) values ('execution', 'x', now(), 'step-2', 'done')`),
      ).rejects.toThrow(/row-level security/);
    });
  });
});

// 실행의 글 보관 (20261024000000_execution_text_retention): 새 표 없이 열 · 색인 · 함수만 더하고 계획 동결 트리거를 바꾼다.
// 자세한 검사는 execution-text-retention.test.ts
describe("실행의 글 보관 (execution_runs.text_purged_at · purge_expired_execution_text)", () => {
  it("열은 처음에 비어 있고 사용자는 자기 run의 값만 본다. 정리 함수는 서버만 부른다", async () => {
    const { rows: columns } = await db.query<{ data_type: string }>(
      `select data_type from information_schema.columns where table_schema = 'public' and table_name = 'execution_runs' and column_name = 'text_purged_at'`,
    );
    expect(columns).toEqual([{ data_type: "timestamp with time zone" }]);

    const actionId = await insertAction(ALICE);
    const { rows } = await db.query<{ id: string }>(`select public.create_run($1, $2, 'draft', '초안 써 줘') as id`, [ALICE, actionId]);
    expect(await db.query(`select public.purge_expired_execution_text(now() + interval '1 day') as n`).then((r) => r.rows)).toEqual([{ n: 0 }]);
    await asUser(db, ALICE, async () => {
      const mine = await db.query(`select request, text_purged_at from public.execution_runs where id = $1`, [rows[0].id]);
      expect(mine.rows).toEqual([{ request: "초안 써 줘", text_purged_at: null }]);
      await expect(db.query(`select public.purge_expired_execution_text(now())`)).rejects.toThrow(/permission denied/);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select text_purged_at from public.execution_runs where id = $1`, [rows[0].id])).rows).toHaveLength(0);
    });
  });
});

// 중단 시각 · 열린 Action에서만 다음 단계 (20261026000000_execution_stopped_at): 새 표 없이 열 하나를 더하고 begin_call · stop_run을 바꾼다.
// 자세한 검사는 execution-core.test.ts · execution-executor.test.ts · tests/pg/execution-locks.test.ts
describe("중단 시각 (execution_runs.stopped_at)", () => {
  it("열은 처음에 비어 있고, 멈추면 사용자는 자기 run의 값만 읽는다(owner_select). 고치지는 못한다", async () => {
    const { rows: columns } = await db.query<{ data_type: string; is_nullable: string }>(
      `select data_type, is_nullable from information_schema.columns where table_schema = 'public' and table_name = 'execution_runs' and column_name = 'stopped_at'`,
    );
    expect(columns).toEqual([{ data_type: "timestamp with time zone", is_nullable: "YES" }]);

    const actionId = await insertAction(ALICE);
    const { rows } = await db.query<{ id: string }>(`select public.create_run($1, $2, 'draft', '초안 써 줘') as id`, [ALICE, actionId]);
    const runId = rows[0].id;
    expect((await db.query(`select stopped_at from public.execution_runs where id = $1`, [runId])).rows).toEqual([{ stopped_at: null }]);
    await db.query(`select public.stop_run($1, $2)`, [ALICE, runId]);
    await asUser(db, ALICE, async () => {
      const mine = await db.query<{ stopped_at: Date | null }>(`select stopped_at from public.execution_runs where id = $1`, [runId]);
      expect(mine.rows[0].stopped_at).toBeInstanceOf(Date);
      await expect(db.query(`update public.execution_runs set stopped_at = null where id = $1`, [runId])).rejects.toThrow(/permission denied/);
      await expect(db.query(`select public.stop_run($1, $2)`, [ALICE, runId])).rejects.toThrow(/permission denied/);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select stopped_at from public.execution_runs where id = $1`, [runId])).rows).toHaveLength(0);
    });
  });
});
