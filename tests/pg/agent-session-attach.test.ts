// OA 외부 세션 PR2s (tests/db/agent-session-attach.scenarios.ts): 실제 Postgres에서 같은 시나리오 + 연결 둘이 겹치는 경합.
// PGlite는 연결이 하나라 "동시에 온 두 요청"을 증명하지 못한다. 코디네이터의 일회용 Postgres(DATABASE_URL)에서 돌린다.
import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { attachAgentSessionTests, attachFixtures, wsRef, type AttachResult } from "../db/agent-session-attach.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg는 DATABASE_URL(일회용 데이터베이스를 만들 수 있는 실제 Postgres)이 필요합니다.");
const DB_NAME = `taskforce_agent_session_attach_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let bPid: number;

async function connect(database?: string) {
  const url = new URL(DATABASE_URL!);
  if (database) url.pathname = `/${database}`;
  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  await client.query("set statement_timeout = '15s'");
  return client;
}

beforeAll(async () => {
  admin = await connect();
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(DB_NAME);
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(DB_NAME);
  b = await connect(DB_NAME);
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);

afterEach(async () => {
  // A를 먼저 놓아 B의 대기를 풀어 준 뒤 정리한다.
  await a?.query("rollback").catch(() => {});
  await b?.query("rollback").catch(() => {});
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

const db = (): ConversationAgentDb => ({
  query: async (sql, params) => (await setup.query(sql, params)).rows,
  asUser: async <T,>(user: string, fn: () => Promise<T>) => {
    await setup.query("set role authenticated");
    await setup.query("select set_config('request.jwt.claim.sub', $1, false)", [user]);
    try {
      return await fn();
    } finally {
      await setup.query("reset role");
      await setup.query("select set_config('request.jwt.claim.sub', '', false)");
    }
  },
});
const f = attachFixtures(db);

describe("외부 세션 이어받기 서버 (실제 Postgres)", () => {
  attachAgentSessionTests(db);
});

const attachOn = async (client: pg.Client, user: string, bridge: string, external: string, ref: string) =>
  (await client.query<{ result: AttachResult }>("select public.attach_agent_session($1, $2, 'agent:claude-code', $3, $4) as result", [user, bridge, external, ref])).rows[0].result;

async function waitForLockWait() {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [bPid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("둘째 연결이 잠금을 기다리지 않는다");
}

const counts = async (user: string) => ({
  sessions: await f.count("select 1 from public.agent_sessions where user_id = $1", [user]),
  conversations: await f.count("select 1 from public.conversations where user_id = $1", [user]),
  events: await f.count("select 1 from public.metric_events where user_id = $1 and type = 'session_attached'", [user]),
});

describe("동시에 온 두 요청 (연결 둘)", () => {
  it("같은 Claude id: 먼저 온 쪽이 commit하면 뒤 쪽은 기다렸다가 existing, 세션 · 대화 · 이벤트 각각 1", async () => {
    const w = await f.world();
    const external = randomUUID();
    const ref = wsRef();
    await a.query("begin");
    await b.query("begin");
    const first = await attachOn(a, w.user, w.bridge, external, ref);
    const waiting = attachOn(b, w.user, w.bridge, external, ref);
    await waitForLockWait();
    await a.query("commit");
    const second = await waiting;
    await b.query("commit");
    expect(first.status).toBe("created");
    expect(second).toEqual({ ...first, status: "existing" });
    expect(await counts(w.user)).toEqual({ sessions: 1, conversations: 1, events: 1 });
  });

  it("먼저 온 쪽이 rollback하면 뒤 쪽이 created가 된다 (남는 행은 하나)", async () => {
    const w = await f.world();
    const external = randomUUID();
    const ref = wsRef();
    await a.query("begin");
    await b.query("begin");
    await attachOn(a, w.user, w.bridge, external, ref);
    const waiting = attachOn(b, w.user, w.bridge, external, ref);
    await waitForLockWait();
    await a.query("rollback");
    const second = await waiting;
    await b.query("commit");
    expect(second.status).toBe("created");
    expect(await counts(w.user)).toEqual({ sessions: 1, conversations: 1, events: 1 });
  });

  it("두 연결이 번갈아 20번을 자동 commit으로 동시에 던져도 세션 1 · 대화 1 · 이벤트 1 · created 정확히 하나", async () => {
    const w = await f.world();
    const external = randomUUID();
    const ref = wsRef();
    // 한 연결에는 한 번에 한 질의만 보낸다(pg 클라이언트 규칙). 연결 둘이 서로 동시에 같은 요청을 던진다
    const results: AttachResult[] = [];
    for (let round = 0; round < 10; round++) results.push(...(await Promise.all([attachOn(a, w.user, w.bridge, external, ref), attachOn(b, w.user, w.bridge, external, ref)])));
    expect(results.filter((r) => r.status === "created")).toHaveLength(1);
    expect(results.filter((r) => r.status === "existing")).toHaveLength(19);
    expect(await counts(w.user)).toEqual({ sessions: 1, conversations: 1, events: 1 });
  });

  it("같은 Claude id를 서로 다른 Mac(bridge)에서 동시에: 하나는 created, 다른 하나는 session_in_use, 세션 1", async () => {
    const user = await f.user();
    const first = await f.bridge(user);
    await f.agentConnection(user, first);
    const second = await f.bridge(user);
    await f.agentConnection(user, second);
    const external = randomUUID();
    await a.query("begin");
    await b.query("begin");
    const created = await attachOn(a, user, first, external, wsRef());
    const waiting = attachOn(b, user, second, external, wsRef());
    await waitForLockWait();
    await a.query("commit");
    const refused = await waiting;
    await b.query("commit");
    expect(created.status).toBe("created");
    expect(refused).toEqual({ status: "session_in_use" });
    expect(await counts(user)).toEqual({ sessions: 1, conversations: 1, events: 1 });
  });

  it("bridge 해제와 겹치면: 해제가 먼저 잠그면 이어받기는 not_found, 이어받기가 먼저면 해제가 기다렸다가 그 세션을 닫는다", async () => {
    // 해제(revoke_bridge)가 bridge 행을 먼저 쥔다 → 이어받기는 기다렸다가 해제된 bridge라 not_found, 아무것도 쓰지 않는다
    const w1 = await f.world();
    await a.query("begin");
    await a.query("select public.revoke_bridge($1, $2)", [w1.user, w1.bridge]);
    await b.query("begin");
    const waiting = attachOn(b, w1.user, w1.bridge, randomUUID(), wsRef());
    await waitForLockWait();
    await a.query("commit");
    expect(await waiting).toEqual({ status: "not_found" });
    await b.query("commit");
    expect(await counts(w1.user)).toEqual({ sessions: 0, conversations: 0, events: 0 });

    // 연결은 그대로 두고 bridge의 상태만 바꾸는 갱신(예: 운영 도구)과 겹쳐도 같다: 이어받기가 bridge 행을 for share로 쥐므로 기다렸다가 not_found
    const w3 = await f.world();
    await a.query("begin");
    await a.query("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [w3.bridge]);
    await b.query("begin");
    const waiting3 = attachOn(b, w3.user, w3.bridge, randomUUID(), wsRef());
    await waitForLockWait();
    await a.query("commit");
    expect(await waiting3).toEqual({ status: "not_found" });
    await b.query("commit");
    expect(await counts(w3.user)).toEqual({ sessions: 0, conversations: 0, events: 0 });

    // 이어받기가 bridge 행을 먼저 쥔다(for share) → 해제는 기다렸다가 새로 이어받은 세션까지 닫는다
    const w2 = await f.world();
    await a.query("begin");
    const attached = await attachOn(a, w2.user, w2.bridge, randomUUID(), wsRef());
    await b.query("begin");
    const revoking = b.query("select public.revoke_bridge($1, $2)", [w2.user, w2.bridge]);
    await waitForLockWait();
    await a.query("commit");
    await revoking;
    await b.query("commit");
    expect(attached.status).toBe("created");
    expect(await f.one("select status from public.agent_sessions where id = $1", [attached.session_id])).toEqual({ status: "closed" });
  });
});
