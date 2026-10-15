import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { bridgeDeviceNameFixtures, bridgeDeviceNameTests } from "../db/bridge-device-name.scenarios";
import type { ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// OA F1s: 실제 Postgres에서 같은 시나리오 + 이름 쓰기 경합(P1–P3). 코디네이터의 일회용 Postgres(DATABASE_URL)에서 돌린다.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg requires DATABASE_URL for disposable PostgreSQL.");
const DB_NAME = `taskforce_bridge_device_name_${process.pid}_${Date.now()}`;
let admin: pg.Client, setup: pg.Client, a: pg.Client, b: pg.Client;
let aPid: number, bPid: number;
async function connect(database?: string) {
  const url = new URL(DATABASE_URL!);
  if (database) url.pathname = `/${database}`;
  const client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  await client.query("set statement_timeout = '10s'");
  return client;
}
beforeAll(async () => {
  admin = await connect();
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(DB_NAME);
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  a = await connect(DB_NAME);
  b = await connect(DB_NAME);
  aPid = (await a.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);
afterEach(async () => {
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
const db = (client: () => pg.Client): (() => ConversationAgentDb) => () => ({
  query: async (sql, params) => (await client().query(sql, params)).rows,
  asUser: async (user, fn) => {
    await client().query("set role authenticated");
    await client().query("select set_config('request.jwt.claim.sub',$1,false)", [user]);
    try {
      return await fn();
    } finally {
      await client().query("reset role");
      await client().query("select set_config('request.jwt.claim.sub','',false)");
    }
  },
});
const f = bridgeDeviceNameFixtures(db(() => setup));
const pending = <T,>(promise: Promise<T>) => promise.then((value) => ({ value }), (error) => ({ error }));
async function resolved<T>(promise: ReturnType<typeof pending<T>>) {
  const result = await promise;
  if ("error" in result) throw result.error;
  return result.value;
}
/** waiter가 holder를 기다리고, holder는 아무도 기다리지 않는다 (교착 아님) */
async function expectWaits(waiterPid: number, holderPid: number) {
  for (let i = 0; i < 200; i++) {
    const blockers = (await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [waiterPid])).rows[0].blockers;
    if (blockers.includes(holderPid)) {
      expect((await setup.query<{ blockers: number[] }>("select pg_blocking_pids($1) as blockers", [holderPid])).rows[0].blockers).toEqual([]);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("Expected the waiter to wait for the holder without reciprocal blocking");
}
const setName = (client: pg.Client, user: string, bridge: string, name: string) =>
  client.query<{ result: { status: string } }>("select public.set_bridge_device_name($1,$2,$3) as result", [user, bridge, name]).then((r) => r.rows[0].result);

describe("bridge 기기 이름 (실제 Postgres)", () => {
  bridgeDeviceNameTests(db(() => setup));
});

describe("이름 쓰기 경합", () => {
  it("P1 폐기가 먼저 쥐면 이름 쓰기는 기다렸다가 not_found이고, 이름이 폐기를 살아남지 않는다", async () => {
    const user = await f.user();
    const bridge = await f.bridge(user, { device_name: "Studio" });
    await a.query("begin");
    await a.query("select public.revoke_bridge($1,$2)", [user, bridge]);
    const write = pending(setName(b, user, bridge, "Test Mac"));
    await expectWaits(bPid, aPid);
    await a.query("commit");
    expect(await resolved(write)).toEqual({ status: "not_found" });
    expect(await f.one("select status, device_name from public.bridges where id=$1", [bridge])).toEqual({ status: "revoked", device_name: null });
  });

  it("P1 이름 쓰기가 먼저 쥐면 폐기는 기다렸다가 이름을 비운다", async () => {
    const user = await f.user();
    const bridge = await f.bridge(user);
    await b.query("begin");
    expect(await setName(b, user, bridge, "Studio")).toEqual({ status: "updated" });
    const revoke = pending(a.query("select public.revoke_bridge($1,$2)", [user, bridge]));
    await expectWaits(aPid, bPid);
    await b.query("commit");
    await resolved(revoke);
    expect(await f.one("select status, device_name from public.bridges where id=$1", [bridge])).toEqual({ status: "revoked", device_name: null });
  });

  it.each([false, true])("P2 같은 bridge의 heartbeat와 이름 쓰기는 교착 없이 둘 다 끝난다 (heartbeat가 먼저=%s)", async (heartbeatFirst) => {
    const user = await f.user();
    const bridge = await f.bridge(user);
    const heartbeat = (client: pg.Client) => client.query("select public.bridge_heartbeat($1,$2,'[]'::jsonb) as result", [user, bridge]);
    const [holder, waiter] = heartbeatFirst ? [a, b] : [b, a];
    await holder.query("begin");
    const first = heartbeatFirst ? await heartbeat(holder) : await setName(holder, user, bridge, "Studio");
    expect(first).toBeDefined();
    const second = pending<unknown>(heartbeatFirst ? setName(waiter, user, bridge, "Studio") : heartbeat(waiter));
    await expectWaits(heartbeatFirst ? bPid : aPid, heartbeatFirst ? aPid : bPid);
    await holder.query("commit");
    await resolved(second);
    expect(await f.one("select device_name, last_heartbeat_at is not null as beat from public.bridges where id=$1", [bridge])).toEqual({ device_name: "Studio", beat: true });
  });

  it("P3 같은 이름 쓰기는 행을 잡지 않는다: 다른 요청이 행 잠금을 쥐고 있어도 기다리지 않고 unchanged", async () => {
    const user = await f.user();
    const bridge = await f.bridge(user, { device_name: "Studio" });
    await a.query("begin");
    await a.query("select 1 from public.bridges where id=$1 for no key update", [bridge]);
    // 대조: 다른 이름은 A의 잠금을 기다린다
    const different = pending(setName(b, user, bridge, "Test Mac"));
    await expectWaits(bPid, aPid);
    // 같은 이름은 (다른 연결에서) 기다리지 않고 바로 끝난다
    const c = await connect(DB_NAME);
    try {
      const started = Date.now();
      const same = await Promise.race([setName(c, user, bridge, "Studio"), new Promise<never>((_, reject) => setTimeout(() => reject(new Error("same-name write waited for the row lock")), 3000))]);
      expect(same).toEqual({ status: "unchanged" });
      expect(Date.now() - started).toBeLessThan(3000);
    } finally {
      await c.end();
    }
    await a.query("rollback");
    expect(await resolved(different)).toEqual({ status: "updated" });
    expect(await f.one("select device_name from public.bridges where id=$1", [bridge])).toEqual({ device_name: "Test Mac" });
  });
});
