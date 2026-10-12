import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { coordinatorPass } from "@/lib/coordinator/sweep";
import { runCoordinator } from "@/lib/coordinator/coordinate";
import { supabaseCoordinatorReads } from "@/lib/coordinator/reads";
import { supabaseCoordinatorStore, type CoordinatorStore } from "@/lib/coordinator/store";

import { sqlAdmin } from "../conversation/sql-admin";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 0.2.0 코디네이터 1 — 운영 TS 코드(store · reads · coordinate · sweep)를 실제 Postgres 연결 둘에서 동시에 돌린다 (ARCH12의 TS 쪽).
// 생산자는 실제 트리거다: 사용자 메시지를 저장하면 사건이 쌓인다. 두 소비자(연결 a · b)가 같은 큐를 동시에 처리한다.
// DATABASE_URL이 없으면 건너뛰지 않고 실패한다 (tests/pg/coordinator-core.test.ts와 같다).

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다.");

const DB_NAME = `taskforce_coordinator_runtime_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;

const urlFor = (database: string) => {
  const url = new URL(DATABASE_URL!);
  url.pathname = `/${database}`;
  return url.toString();
};
const connect = async (url: string) => {
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  return client;
};
/** 연결 하나에 쿼리를 차례로 보낸다 (한 연결에 겹쳐 보내지 않는다) */
const adminOver = (client: pg.Client) => {
  let chain: Promise<unknown> = Promise.resolve();
  return sqlAdmin((sql, params) => {
    const next = chain.then(async () => (await client.query(sql, params)).rows, async () => (await client.query(sql, params)).rows);
    chain = next.catch(() => undefined);
    return next;
  });
};

beforeAll(async () => {
  admin = await connect(DATABASE_URL!);
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(urlFor(DB_NAME));
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
}, 120_000);
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

const rows = async (sql: string, params?: unknown[]) => (await setup.query(sql, params)).rows;

describe("ARCH12 (운영 TS 코드): 사건 100건 · 두 소비자 동시 처리", () => {
  it("사용자 메시지 100건(실제 트리거가 쌓음)을 두 소비자가 runCoordinator로 동시에 처리: 사건당 처리 1회 · lost_claim 0 · 오류 0 · 사용자별 순서 보존 · 두 소비자 모두 일을 했다", async () => {
    const users: string[] = [];
    const messages = new Map<string, string[]>();
    for (let i = 0; i < 10; i++) {
      const user = randomUUID();
      users.push(user);
      await setup.query(`insert into auth.users (id, email) values ($1, $2)`, [user, `${user}@example.com`]);
      const conversation = (await setup.query(`insert into public.conversations (user_id) values ($1) returning id`, [user])).rows[0].id as string;
      const ids: string[] = [];
      for (let n = 1; n <= 10; n++) {
        ids.push((await setup.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text) values ($1, $2, $3, 'user', $4, '안녕') returning id`, [user, conversation, n, randomUUID()])).rows[0].id as string);
      }
      messages.set(user, ids);
    }
    expect((await rows(`select count(*)::int as n from public.inbox_events where type = 'user_message'`))[0].n).toBe(100);

    const finished: { consumer: string; user: string; message: string; status: string }[] = [];
    const wrap = (store: CoordinatorStore, consumer: string): CoordinatorStore => ({
      ...store,
      finish: async (event, outcome) => {
        const status = await store.finish(event, outcome);
        finished.push({ consumer, user: event.user_id, message: (event.refs as { message_id: string }).message_id, status });
        return status;
      },
    });
    const run = (client: pg.Client, consumer: string) => {
      const adminClient = adminOver(client);
      return runCoordinator({ store: wrap(supabaseCoordinatorStore(adminClient), consumer), reads: supabaseCoordinatorReads(adminClient) }, { consumer, maxEvents: 100, timeBudgetMs: 30_000 });
    };
    const [first, second] = await Promise.all([run(a, "fn-a"), run(b, "fn-b")]);

    expect(first.failed + second.failed).toBe(0);
    expect(first.lost_claim + second.lost_claim).toBe(0);
    expect(first.finished + second.finished).toBe(100);
    expect(finished).toHaveLength(100);
    expect(new Set(finished.map((f) => f.status))).toEqual(new Set(["finished"]));
    expect(new Set(finished.map((f) => f.message)).size).toBe(100);
    expect(new Set(finished.map((f) => f.consumer))).toEqual(new Set(["fn-a", "fn-b"]));
    for (const user of users) expect(finished.filter((f) => f.user === user).map((f) => f.message), user).toEqual(messages.get(user));
    expect((await rows(`select count(*)::int as n, count(*) filter (where attempts = 1)::int as once, count(*) filter (where result_kind = 'no_impact')::int as no_impact from public.inbox_events where processed_at is not null`))[0]).toEqual({ n: 100, once: 100, no_impact: 100 });
    expect((await rows(`select count(*)::int as n from public.inbox_events where processed_at is null`))[0].n).toBe(0);
  }, 60_000);
});

describe("동시에 도는 sweep 둘 (timer 적재 · 회수 · 처리): 겹쳐도 사건이 늘거나 오류가 나지 않는다", () => {
  it("같은 기한 창 Action에 대한 timer 적재를 두 pass가 동시에 해도 사건은 Action당 하나이고 둘 다 오류 0 · 처리는 한 번", async () => {
    await setup.query(`delete from public.inbox_events`);
    const user = randomUUID();
    await setup.query(`insert into auth.users (id, email) values ($1, $2)`, [user, `${user}@example.com`]);
    const due = new Date(Date.now() + 6 * 3_600_000).toISOString();
    for (let i = 0; i < 20; i++) await setup.query(`insert into public.actions (user_id, title, due_at) values ($1, '할 일', $2)`, [user, due]);
    const pass = (client: pg.Client, consumer: string) => {
      const adminClient = adminOver(client);
      return coordinatorPass({ store: supabaseCoordinatorStore(adminClient), reads: supabaseCoordinatorReads(adminClient), consumer });
    };
    const results = await Promise.all([pass(a, "fn-a"), pass(b, "fn-b")]);
    expect(results.map((r) => r.errors)).toEqual([0, 0]);
    // 두 pass가 같은 키를 동시에 쌓으려 해도 하나만 생긴다 (on conflict do nothing): 쌓은 수의 합은 20 이상 40 이하
    expect(results[0].timers + results[1].timers).toBeGreaterThanOrEqual(20);
    expect((await rows(`select count(*)::int as n from public.inbox_events where user_id = $1 and type = 'timer_due'`, [user]))[0].n).toBe(20);
    // 남은 처리는 다음 pass가 끝낸다: 사건당 처리 1회
    await pass(a, "fn-a");
    await pass(b, "fn-b");
    expect((await rows(`select count(*)::int as n, count(*) filter (where attempts = 1)::int as once from public.inbox_events where user_id = $1 and processed_at is not null`, [user]))[0]).toEqual({ n: 20, once: 20 });
  }, 60_000);
});
