import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { supabaseSchemaScripts } from "../db/local-supabase";

// BYOK key store (20261130000000) against a real Postgres: the account row lock that orders a key save against a Lifetime refund, the
// unique key row under concurrent saves, the exact-sealed-value guard of the revoke, and the hourly attempt limit under concurrency.
// Sealed values are made-up strings; no real key and no real ciphertext appear here.
const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error("DATABASE_URL is required for actual Postgres key store contention tests");
const database = `taskforce_user_ai_keys_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let a: pg.Client;
let b: pg.Client;
let c: pg.Client;

beforeAll(async () => {
  admin = new pg.Client({ connectionString });
  await admin.connect();
  await admin.query(`create database ${database}`);
  const url = new URL(connectionString!);
  url.pathname = `/${database}`;
  a = new pg.Client({ connectionString: url.toString() });
  b = new pg.Client({ connectionString: url.toString() });
  c = new pg.Client({ connectionString: url.toString() });
  await Promise.all([a.connect(), b.connect(), c.connect()]);
  for (const sql of await supabaseSchemaScripts()) await a.query(sql);
});
afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), c?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${database} with (force)`);
    await admin.end();
  }
});

async function user(): Promise<string> {
  const id = randomUUID();
  await a.query("insert into auth.users(id) values($1)", [id]);
  return id;
}
/** A Lifetime owner bought through an issued checkout intent, exactly as the webhook leaves it. */
async function owner(): Promise<{ id: string; intent: string }> {
  const id = await user();
  const intent = randomUUID();
  await a.query("insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,url,with_trial,with_discount) values($1,$2,'lifetime','2026-10-19','https://taskforce.lemonsqueezy.com/checkout/x',false,false)", [intent, id]);
  await a.query("select billing_apply_lifetime($1,$2,$3,$4,'cus','active',now(),'2026-10-19T00:00:00Z')", [id, randomUUID(), intent, `ord-${id}`]);
  return { id, intent };
}
const refund = (client: pg.Client, o: { id: string; intent: string }, updated = "2026-10-19T00:00:10Z") =>
  client.query("select billing_apply_lifetime($1,$2,$3,$4,'cus','refunded',now(),$5) r", [o.id, randomUUID(), o.intent, `ord-${o.id}`, updated]);
const put = (client: pg.Client, userId: string, sealed = "k1.a.b.c") => client.query<{ r: boolean }>("select ai_key_put($1,$2,1::smallint) r", [userId, sealed]).then((result) => result.rows[0].r);
const keyRows = async (userId: string) => (await a.query<{ sealed_key: string; status: string }>("select sealed_key,status from user_ai_keys where user_id=$1", [userId])).rows;
const events = async (userId: string) => (await a.query<{ type: string; props: unknown }>("select type,props from metric_events where user_id=$1 and type like 'ai\\_key\\_%' order by at", [userId])).rows.map((r) => `${r.type} ${JSON.stringify(r.props)}`);
const later = <T>(promise: Promise<T>) => promise.then((value) => ({ value }), (error: Error) => ({ error: error.message }));
async function expectBlocked(promise: Promise<unknown>) {
  const early = await Promise.race([promise, new Promise<string>((resolve) => setTimeout(() => resolve("still waiting"), 400))]);
  expect(early).toBe("still waiting");
}

describe("saving a key and the Lifetime refund are ordered by the account row", () => {
  it("a refund that holds the account makes a save wait, and the save is then refused: no key survives the refund", async () => {
    const o = await owner();
    await a.query("begin");
    await refund(a, o);
    const save = later(put(b, o.id));
    await expectBlocked(save);
    await a.query("commit");
    expect(await save).toEqual({ error: expect.stringMatching(/byok_not_entitled/) });
    expect(await keyRows(o.id)).toEqual([]);
    expect(await events(o.id)).toEqual([]);
  });

  it("a save that holds the account makes the refund wait, and the refund then removes that very key", async () => {
    const o = await owner();
    await a.query("begin");
    expect(await put(a, o.id, "k1.first.first.first")).toBe(false);
    const done = later(refund(b, o));
    await expectBlocked(done);
    await a.query("commit");
    expect(await done).toEqual({ value: expect.anything() });
    expect(await keyRows(o.id)).toEqual([]);
    expect((await a.query("select lifetime_status from billing_accounts where user_id=$1", [o.id])).rows[0]).toEqual({ lifetime_status: "refunded" });
    expect(await events(o.id)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_deleted {"by":"refund"}']);
  });

  it("the owner's DELETE and the refund at the same moment remove the key once and count it once", async () => {
    const o = await owner();
    await put(a, o.id);
    await a.query("begin");
    expect((await a.query<{ r: boolean }>("select ai_key_delete($1) r", [o.id])).rows[0].r).toBe(true);
    const done = later(refund(b, o));
    await expectBlocked(done);
    await a.query("commit");
    expect(await done).toEqual({ value: expect.anything() });
    expect(await keyRows(o.id)).toEqual([]);
    // the refund waited for the delete's row lock and then found nothing left to remove: one event, labelled as the owner's removal
    expect(await events(o.id)).toEqual(['ai_key_saved {"replaced":false}', "ai_key_deleted {}"]);
  });

  it("a second save waits only for the first one's key row (the account lock is shared), then replaces it: one row", async () => {
    const o = await owner();
    await a.query("begin");
    await put(a, o.id, "k1.one.one.one");
    // both hold the account lock in shared mode; the second waits for the first's uncommitted key row only
    const second = later(put(b, o.id, "k1.two.two.two"));
    await expectBlocked(second);
    await a.query("commit");
    expect(await second).toEqual({ value: true });
    expect(await keyRows(o.id)).toEqual([{ sealed_key: "k1.two.two.two", status: "connected" }]);
    expect(await events(o.id)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_saved {"replaced":true}']);
  });

  it("many concurrent first saves leave exactly one row, one fresh insert and the others replacing", async () => {
    const o = await owner();
    const results = await Promise.all([a, b, c].flatMap((client, i) => [0, 1].map((j) => later(put(client, o.id, `k1.c${i}${j}.x.y`)))));
    // one connection runs its queries one after another: all six settle
    expect(results.every((r) => "value" in r)).toBe(true);
    expect((results as { value: boolean }[]).filter((r) => r.value === false)).toHaveLength(1);
    expect(await keyRows(o.id)).toHaveLength(1);
    expect((await events(o.id)).sort()).toEqual(['ai_key_saved {"replaced":false}', ...Array(5).fill('ai_key_saved {"replaced":true}')].sort());
  });
});

describe("the revoke is bound to the sealed value that made the call", () => {
  it("a replace that is in flight wins over a late 401 of the old key", async () => {
    const o = await owner();
    await put(a, o.id, "k1.old.old.old");
    await a.query("begin");
    await put(a, o.id, "k1.new.new.new");
    const revoke = later(b.query<{ r: boolean }>("select ai_key_mark_revoked($1,'k1.old.old.old') r", [o.id]).then((result) => result.rows[0].r));
    await expectBlocked(revoke);
    await a.query("commit");
    // after waiting, the row is re-checked: it now carries the new value, so the old one's revoke matches nothing
    expect(await revoke).toEqual({ value: false });
    expect(await keyRows(o.id)).toEqual([{ sealed_key: "k1.new.new.new", status: "connected" }]);
    expect(await events(o.id)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_saved {"replaced":true}']);
  });

  it("two 401s at once revoke once and leave one event", async () => {
    const o = await owner();
    await put(a, o.id, "k1.used.used.used");
    const results = await Promise.all([a, b, c].map((client) => client.query<{ r: boolean }>("select ai_key_mark_revoked($1,'k1.used.used.used') r", [o.id]).then((result) => result.rows[0].r)));
    expect(results.filter(Boolean)).toHaveLength(1);
    expect(await events(o.id)).toEqual(['ai_key_saved {"replaced":false}', 'ai_key_revoked {"by":"provider"}']);
  });

  it("two removals at once remove once and leave one event", async () => {
    const o = await owner();
    await put(a, o.id);
    const results = await Promise.all([a, b].map((client) => client.query<{ r: boolean }>("select ai_key_delete($1) r", [o.id]).then((result) => result.rows[0].r)));
    expect(results.filter(Boolean)).toHaveLength(1);
    expect(await events(o.id)).toEqual(['ai_key_saved {"replaced":false}', "ai_key_deleted {}"]);
  });
});

describe("hourly attempt limit under concurrency", () => {
  it("twelve attempts from three connections let exactly ten through", async () => {
    const u = await user();
    const take = (client: pg.Client) => client.query<{ r: Date | null }>("select take_rate_limit($1,'ai_key',10,3600) r", [u]).then((result) => result.rows[0].r);
    const results = (await Promise.all([a, b, c].map(async (client) => { const out: (Date | null)[] = []; for (let i = 0; i < 4; i++) out.push(await take(client)); return out; }))).flat();
    expect(results.filter((r) => r === null)).toHaveLength(10);
    expect(results.filter((r) => r instanceof Date)).toHaveLength(2);
    expect((await a.query("select count(*)::int n from rate_limit_events where user_id=$1 and kind='ai_key'", [u])).rows[0]).toEqual({ n: 10 });
  });
});

describe("the table and the functions in a real Postgres", () => {
  it("the API roles have no privilege on the table or the functions", async () => {
    const o = await owner();
    await put(a, o.id, "k1.real.pg.value");
    for (const role of ["authenticated", "anon"]) {
      await a.query(`set role ${role}`);
      try {
        for (const sql of ["select * from user_ai_keys", "update user_ai_keys set status='connected'", "delete from user_ai_keys", `select ai_key_put('${o.id}','k1.x.y.z',1::smallint)`, `select ai_key_delete('${o.id}')`])
          await expect(a.query(sql), `${role}: ${sql}`).rejects.toThrow(/permission denied/);
      } finally { await a.query("reset role"); }
    }
    expect(await keyRows(o.id)).toEqual([{ sealed_key: "k1.real.pg.value", status: "connected" }]);
  });

  it("deleting the user removes the key", async () => {
    const o = await owner();
    await put(a, o.id);
    await a.query("delete from auth.users where id=$1", [o.id]);
    expect(await keyRows(o.id)).toEqual([]);
  });
});
