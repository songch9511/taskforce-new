import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";

// 실행 receipt 쓰기의 잠금 경합 (20261023000000_execution_receipts, docs/EXECUTION.md 9장). PGlite는 연결이 하나라 겹침을 볼 수 없다.
// write_execution_receipt는 Action 행을 먼저 잠근다: 같은 단계를 함께 쓰는 실행기 · sweep은 줄을 서고 뒤의 것은 이미 붙은 것을 보며(exists),
// 그 사이 사용자가 고친 Action에는 옛 버전으로 쓰지 않는다(conflict).
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 운영 마이그레이션을 그대로 적용하고, 끝나면 지운다. 없으면 실패한다 (execution-locks.test.ts).

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다 (tests/pg/execution-locks.test.ts의 안내).");

const DB_NAME = `taskforce_receipts_${process.pid}_${Date.now()}`;

let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let aPid: number;
let bPid: number;

function urlFor(database: string) {
  const url = new URL(DATABASE_URL!);
  url.pathname = `/${database}`;
  return url.toString();
}

async function connect(url: string) {
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  return client;
}

beforeAll(async () => {
  admin = await connect(DATABASE_URL!);
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(urlFor(DB_NAME));
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  await setup.query("update public.execution_controls set blocked = false where scope = 'global'");
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
  const pidOf = async (client: pg.Client) => (await client.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
  [aPid, bPid] = [await pidOf(a), await pidOf(b)];
});

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

afterEach(async () => {
  await a.query("rollback").catch(() => {});
  await b.query("rollback").catch(() => {});
});

/** 그 연결이 잠금을 기다리는 중인지 (pg_stat_activity). 5초 안에 기다리지 않으면 실패 */
async function waitForLockWait(pid: number) {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [pid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`연결 ${pid}가 잠금을 기다리지 않는다`);
}

/** 실행기 흐름으로 끝낸 초안 단계 하나 (Action · run · 계획 단계 · 초안 단계 + 산출물) */
async function finishedDraft() {
  const userId = randomUUID();
  const actionId = randomUUID();
  await setup.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await setup.query("insert into public.actions (id, user_id, title) values ($1, $2, '제안서 보내기')", [actionId, userId]);
  await setup.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  await setup.query("select public.grant_credits($1, 100, gen_random_uuid())", [userId]);
  const one = async <T>(sql: string, params: unknown[]) => (await setup.query<T & pg.QueryResultRow>(sql, params)).rows[0];
  const runId = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '초안') as id", [userId, actionId])).id;
  const call = async (stepId: string) => {
    const { version } = await one<{ version: number }>("select version from public.execution_steps where id = $1", [stepId]);
    await setup.query("select public.prepare_step($1, $2)", [stepId, version]);
    expect((await one<{ g: { gate: string } }>("select public.begin_call($1, 'fn', $2) as g", [stepId, version + 1])).g.gate).toBe("ok");
  };
  const attempts = JSON.stringify([{ generationId: `gen-${randomUUID()}`, model: "m", usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.004 } }]);
  const planId = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1", [runId])).id;
  await call(planId);
  const stepId = (await one<{ id: string }>(
    `select public.append_step($1, 2, '{"kind": "draft", "provider": "taskforce", "tool": "draft", "purpose": "draft", "estimate_credits": 10}') as id`,
    [runId],
  )).id;
  await setup.query("select public.complete_internal_step($1, 'fn', '{}', $2::jsonb)", [planId, attempts]);
  await call(stepId);
  await setup.query(
    `select public.complete_internal_step($1, 'fn', '{}', $2::jsonb, '{"title": "제안서 초안", "body": "본문", "model": "m", "prompt_version": "draft-v1"}', 'draft_ready')`,
    [stepId, attempts],
  );
  const { version } = await one<{ version: number }>("select version from public.actions where id = $1", [actionId]);
  return { userId, actionId, stepId, version };
}

/** 실행기가 넘기는 것과 같은 모양: Action 값(지금 행 그대로) + receipt */
const writeReceipt = async (client: pg.Client, stepId: string, actionId: string, version: number) => {
  const receipt = {
    source: { title: "제안서 초안", raw_text: "초안 저장: 제안서 초안", external_url: "taskforce://artifacts/x" },
    claim: { id: randomUUID(), quote: "초안 저장: 제안서 초안", speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "private" },
  };
  const { rows } = await client.query<{ r: string }>(
    `select public.write_execution_receipt($1, $2, jsonb_build_object('title', a.title, 'owner', a.owner, 'due_date', a.due_date, 'due_at', a.due_at,
       'status', a.status, 'needs_confirmation', a.needs_confirmation, 'confirm_reasons', to_jsonb(a.confirm_reasons), 'resolution', a.resolution), $4::jsonb) as r
     from public.actions a where a.id = $3`,
    [stepId, version, actionId, JSON.stringify(receipt)],
  );
  return rows[0].r;
};

const receiptRows = async (actionId: string) =>
  (
    await setup.query<{ sources: number; claims: number; evidence: number; events: number }>(
      `select (select count(*)::int from public.sources s join public.claims c on c.source_id = s.id where c.action_id = $1 and s.kind = 'execution') as sources,
              (select count(*)::int from public.claims where action_id = $1 and origin = 'execution') as claims,
              (select count(*)::int from public.evidence where action_id = $1 and role = 'executed') as evidence,
              (select count(*)::int from public.action_events where action_id = $1 and type = 'artifact_created') as events`,
      [actionId],
    )
  ).rows[0];

describe("실행 receipt 잠금 경합 (실제 Postgres, 연결 둘)", () => {
  it("같은 단계의 receipt를 두 연결(실행기 · sweep)이 함께 쓰면 하나만 붙고, 기다린 쪽은 exists", async () => {
    const draft = await finishedDraft();
    await a.query("begin");
    expect(await writeReceipt(a, draft.stepId, draft.actionId, draft.version)).toBe("written");
    const late = writeReceipt(b, draft.stepId, draft.actionId, draft.version); // Action 행 잠금을 기다린다
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await late).toBe("exists");
    expect(await receiptRows(draft.actionId)).toEqual({ sources: 1, claims: 1, evidence: 1, events: 1 });
  });

  it("사용자가 Action을 고치는 중이면 기다렸다가, 옛 버전의 receipt는 쓰지 않는다 (conflict, 아무것도 남지 않음)", async () => {
    const draft = await finishedDraft();
    await b.query("begin");
    await b.query("update public.actions set version = version + 1 where id = $1", [draft.actionId]); // 사용자의 write_action
    const receipt = writeReceipt(a, draft.stepId, draft.actionId, draft.version);
    await waitForLockWait(aPid);
    await b.query("commit");
    expect(await receipt).toBe("conflict");
    expect(await receiptRows(draft.actionId)).toEqual({ sources: 0, claims: 0, evidence: 0, events: 0 });
    expect(await writeReceipt(a, draft.stepId, draft.actionId, draft.version + 1)).toBe("written");
  });
});
