import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { createLocalSupabase } from "./local-supabase";

// 계정 삭제 (DELETE /api/v1/account → auth.admin.deleteUser): auth.users 행을 지우면
// 사용자 테이블의 행이 모두 on delete cascade로 지워지고, 다른 사용자의 행은 그대로여야 한다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

/** user_id 열이 있는 사용자 테이블 전부. 새 테이블을 만들면 여기와 seed()에 더한다 (아래 첫 테스트가 알려 준다). */
const USER_TABLES = [
  "action_events",
  "action_links",
  "actions",
  "ai_spend_attempts",
  "claims",
  "connection_requests",
  "connections",
  "credit_accounts",
  "credit_ledger",
  "devices",
  "evidence",
  "execution_actors",
  "execution_approvals",
  "execution_artifacts",
  "execution_events",
  "execution_intents",
  "execution_policies",
  "execution_runs",
  "execution_steps",
  "execution_usage",
  "judge_logs",
  "metric_events",
  "missing_reports",
  "oauth_handoffs",
  "oauth_nonces",
  "profiles",
  "rate_limit_events",
  "slack_messages",
  "slack_people",
  "slack_threads",
  "sources",
  "weekly_checks",
];

let db: PGlite;

/** 서버(service role)가 쓰듯 모든 사용자 테이블에 한 사용자의 행을 넣는다. 연결된 원문 · 이벤트의 set null 경로도 거치게 한다. */
async function seed(userId: string, tokenHex: string) {
  const one = async (sql: string, params: unknown[]) => (await db.query<{ id: string }>(sql, params)).rows[0].id;

  await db.query("select reserve_ai_spend($1,$2,'chat','m',0.1)", [userId, randomUUID()]);
  const connectionId = await one(
    `insert into public.connections (user_id, provider, external_account_id) values ($1, 'notion', 'ws') returning id`,
    [userId],
  );
  await db.query(`insert into public.connection_secrets (connection_id, sealed_token) values ($1, 'v1.x.y.z')`, [connectionId]);
  const sourceId = await one(
    `insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id, external_id, external_version)
     values ($1, 'meeting', '원문', now(), $2, 'page-1', 'v1') returning id`,
    [userId, connectionId],
  );
  const actionId = await one(`insert into public.actions (user_id, title) values ($1, '할 일') returning id`, [userId]);
  await db.query(
    `insert into public.claims (user_id, action_id, source_id, field, value, quote, occurred_at,
                                speaker_role, certainty, directness, audience)
     values ($1, $2, $3, 'due', '2026-10-02', '금요일까지', now(), 'me', 'firm', 'first_hand', 'shared')`,
    [userId, actionId, sourceId],
  );
  await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '금요일까지', 'created')`, [
    userId,
    actionId,
    sourceId,
  ]);
  await db.query(`insert into public.action_events (user_id, action_id, type, source_id, actor) values ($1, $2, 'created', $3, 'ai')`, [
    userId,
    actionId,
    sourceId,
  ]);
  await db.query(
    `insert into public.judge_logs (user_id, source_id, candidate, jev_answers, decision, model_version)
     values ($1, $2, '{}', '{}', 'auto', 'typesafe/jev-1.13')`,
    [userId, sourceId],
  );
  await db.query(`insert into public.metric_events (user_id, type, action_id) values ($1, 'action_started', $2)`, [userId, actionId]);
  await db.query(`insert into public.profiles (user_id, display_name) values ($1, '이름')`, [userId]);
  await db.query(`insert into public.devices (user_id, token, platform) values ($1, $2, 'ios')`, [userId, tokenHex]);
  await db.query(`insert into public.action_links (user_id, connection_id, external_id, action_id) values ($1, $2, 'page-1', $3)`, [
    userId,
    connectionId,
    actionId,
  ]);
  await db.query(`insert into public.weekly_checks (user_id, week_start, answer) values ($1, '2026-09-21', 'no')`, [userId]);
  await db.query(`insert into public.missing_reports (user_id) values ($1)`, [userId]);
  await db.query(`insert into public.rate_limit_events (user_id, kind) values ($1, 'ask')`, [userId]);
  await db.query(`insert into public.connection_requests (user_id, provider) values ($1, 'zoom')`, [userId]);
  await db.query(`insert into public.oauth_nonces (nonce, user_id, provider, expires_at) values ($1, $2, 'notion', now())`, [
    `nonce-${userId}`,
    userId,
  ]);
  await db.query(
    `insert into public.oauth_handoffs (id, user_id, provider, sealed_code, expires_at) values ($1, $2, 'notion', 'v1.x.y.z', now())`,
    [`handoff-${userId}`, userId],
  );
  const slack = await one(
    `insert into public.connections (user_id, provider, external_account_id) values ($1, 'slack', 'T1:U1') returning id`,
    [userId],
  );
  await db.query(
    `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text) values ($1, $2, 'D1', 'im', '1.0', 'U2', 'x')`,
    [userId, slack],
  );
  await db.query(`insert into public.slack_threads (connection_id, user_id, channel_id, thread_ts) values ($1, $2, 'C1', '1.0')`, [slack, userId]);
  await db.query(`insert into public.slack_people (connection_id, user_id, slack_id, kind, name) values ($1, $2, 'U2', 'user', 'x')`, [slack, userId]);
  // 실행 코어: run(정책 · 첫 단계 · 이벤트가 함께 생긴다), 연결을 쓰는 끝난 · 준비된 외부 단계(연결 삭제의 set null 경로,
  // 준비된 단계는 다시 계획되며 이벤트를 남긴다), 승인 · intent, 실행 주체
  await db.query(`insert into public.execution_actors (user_id) values ($1)`, [userId]);
  const runId = await one(`select public.create_run($1, $2, 'draft', '초안') as id`, [userId, actionId]);
  const stepId = await one(
    `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, connection_id, state, policy_version)
     values ($1, $2, 2, 'external', 'gmail', 'send', 'send', $3, 'called', 1) returning id`,
    [userId, runId, connectionId],
  );
  await db.query(
    `insert into public.execution_steps (user_id, run_id, seq, kind, provider, tool, purpose, connection_id, state, policy_version)
     values ($1, $2, 3, 'external', 'gmail', 'send', 'send-2', $3, 'prepared', 1)`,
    [userId, runId, connectionId],
  );
  await db.query(`insert into public.execution_approvals (user_id, step_id, hash, expires_at) values ($1, $2, 'h', now())`, [userId, stepId]);
  await db.query(`insert into public.execution_intents (intent_key, user_id, step_id) values ($1, $2, $3)`, [`key-${userId}`, userId, stepId]);
  // 크레딧 · 산출물 · 원가: 운영자 지급, 다른 run에서 계획 단계 → 초안 단계를 실행기처럼 끝까지 (예약 · 정산 · 해제 · 산출물 · 원가 행).
  // 원장 · 원가의 run · step 외래키는 지울 때 막는다(no action): 계정 삭제는 같은 문장 안에서 원장도 함께 지워 막히지 않아야 한다
  await db.query(`select public.grant_credits($1, 100, gen_random_uuid())`, [userId]);
  await db.query(`update public.execution_controls set blocked = false where scope = 'global'`);
  try {
    const draftRun = await one(`select public.create_run($1, $2, 'draft', '초안') as id`, [userId, actionId]);
    const call = async (step: string) => {
      const { version } = (await db.query<{ version: number }>(`select version from public.execution_steps where id = $1`, [step])).rows[0];
      await db.query(`select public.prepare_step($1, $2)`, [step, version]);
      const gate = await db.query<{ g: { gate: string } }>(`select public.begin_call($1, 'fn', $2) as g`, [step, version + 1]);
      expect(gate.rows[0].g.gate).toBe("ok");
    };
    const plan = await one(`select id from public.execution_steps where run_id = $1 and seq = 1`, [draftRun]);
    await call(plan);
    const attempts = (id: string) => JSON.stringify([{ generationId: id, model: "m", usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.0042 } }]);
    await db.query(`select public.complete_internal_step($1, 'fn', '{}', $2::jsonb)`, [plan, attempts(`gen-plan-${userId}`)]);
    const draft = await one(
      `select public.append_step($1, 2, '{"kind": "draft", "provider": "taskforce", "tool": "draft", "purpose": "draft", "estimate_credits": 10}') as id`,
      [draftRun],
    );
    await call(draft);
    await db.query(`select public.complete_internal_step($1, 'fn', '{}', $2::jsonb, '{"title": "제안서", "body": "초안 본문", "model": "m", "prompt_version": "draft-v1"}', 'draft_ready')`, [
      draft,
      attempts(`gen-draft-${userId}`),
    ]);
    // 실행 receipt (U2 PR7): receipt 원문(kind execution) · Claim(origin execution) · 근거(executed) · 이벤트(actor agent).
    // 원문은 클라이언트가 지우지 못하지만 계정 삭제(auth.users cascade)로는 함께 지워져야 한다
    const artifact = await one(`select id from public.execution_artifacts where step_id = $1`, [draft]);
    const receipt = {
      source: { title: "제안서", raw_text: "초안 저장: 제안서", external_url: `taskforce://artifacts/${artifact}` },
      claim: { id: randomUUID(), quote: "초안 저장: 제안서", speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "private" },
    };
    const written = await db.query<{ r: string }>(`select public.write_execution_receipt($1, a.version, $3::jsonb) as r from public.actions a where a.id = $2`, [
      draft,
      actionId,
      JSON.stringify(receipt),
    ]);
    expect(written.rows[0].r).toBe("written");
  } finally {
    await db.query(`update public.execution_controls set blocked = true where scope = 'global'`);
  }
  return connectionId;
}

async function rowCounts(userId: string): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const table of USER_TABLES) {
    const { rows } = await db.query<{ n: number }>(`select count(*)::int as n from public.${table} where user_id = $1`, [userId]);
    counts[table] = rows[0].n;
  }
  return counts;
}

async function secretCount(connectionId: string): Promise<number> {
  const { rows } = await db.query<{ n: number }>(`select count(*)::int as n from public.connection_secrets where connection_id = $1`, [
    connectionId,
  ]);
  return rows[0].n;
}

let aliceConnection: string;
let bobConnection: string;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  aliceConnection = await seed(ALICE, "a".repeat(64));
  bobConnection = await seed(BOB, "b".repeat(64));
  // 실행의 글 보관 (20261024000000): 끝난 초안 run(사용자마다 하나)의 글을 지운 뒤에도 계정 삭제가 그대로 돈다.
  // 끝나지 않은 run(외부 단계가 있는 첫 run)은 건드리지 않는다
  const { rows } = await db.query<{ n: number }>(`select public.purge_expired_execution_text(now() + interval '1 day') as n`);
  expect(rows[0].n).toBe(2);
}, 60_000);

describe("계정 삭제 (auth.users on delete cascade)", () => {
  it("user_id가 있는 테이블을 빠짐없이 확인한다", async () => {
    const { rows } = await db.query<{ table_name: string }>(
      `select table_name from information_schema.columns
       where table_schema = 'public' and column_name = 'user_id' order by table_name`,
    );
    expect(rows.map((r) => r.table_name)).toEqual(USER_TABLES);
  });

  it("삭제 전에는 두 사용자 모두 모든 테이블에 행이 있다", async () => {
    for (const userId of [ALICE, BOB]) {
      expect(Object.values(await rowCounts(userId)).every((n) => n > 0)).toBe(true);
      // 실행 receipt도 있다 (원문 · Claim · 근거 · 이벤트)
      const { rows } = await db.query<{ n: number }>(
        `select (select count(*) from public.sources where user_id = $1 and kind = 'execution')
              + (select count(*) from public.claims where user_id = $1 and origin = 'execution')
              + (select count(*) from public.evidence where user_id = $1 and role = 'executed')
              + (select count(*) from public.action_events where user_id = $1 and actor = 'agent') as n`,
        [userId],
      );
      expect(Number(rows[0].n)).toBe(4);
      // 끝난 run은 글을 지웠고(지운 시각 있음), 끝나지 않은 run은 요청이 그대로다
      const runs = await db.query<{ state: string; request: string; purged: boolean }>(
        `select state, request, text_purged_at is not null as purged from public.execution_runs where user_id = $1 order by state`,
        [userId],
      );
      expect(runs.rows).toEqual([
        { state: "done", request: "", purged: true },
        { state: "queued", request: "초안", purged: false },
      ]);
    }
    expect(await secretCount(aliceConnection)).toBe(1);
  });

  it("auth 사용자를 지우면 그 사용자의 행은 모두 지워지고, 다른 사용자의 행은 그대로다", async () => {
    const bobBefore = await rowCounts(BOB);

    await db.query(`delete from auth.users where id = $1`, [ALICE]);

    const aliceAfter = await rowCounts(ALICE);
    expect(aliceAfter).toEqual(Object.fromEntries(USER_TABLES.map((t) => [t, 0])));
    expect(await secretCount(aliceConnection)).toBe(0);

    expect(await rowCounts(BOB)).toEqual(bobBefore);
    expect(await secretCount(bobConnection)).toBe(1);
    const { rows } = await db.query<{ id: string }>(`select id from auth.users`);
    expect(rows.map((r) => r.id)).toEqual([BOB]);
  });
});
