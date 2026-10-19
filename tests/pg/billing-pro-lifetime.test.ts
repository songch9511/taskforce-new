import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { supabaseSchemaScripts } from "../db/local-supabase";

// Billing v2 against a real Postgres: row locks and advisory locks must serialize the money paths the way PGlite (single
// session) cannot show. Two clients, a transaction held open on one, the other asked to do the conflicting thing.
const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error("DATABASE_URL is required for actual Postgres billing contention tests");
const database = `taskforce_billing_v2_${process.pid}_${Date.now()}`;
const DAY = 86_400_000;
const iso = (offset: number) => new Date(Date.now() + offset).toISOString();
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
  await a.query("update ai_budget_policy set global_daily_usd=100000,global_total_usd=100000,user_daily_usd=100000");
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
async function intent(userId: string, plan: "pro" | "lifetime" = "pro"): Promise<string> {
  const id = randomUUID();
  // as the checkout route leaves it: URL attached, trial and first month offered for Pro
  await a.query("insert into billing_checkout_intents(id,user_id,plan,accepted_terms_version,url,with_trial,with_discount) values($1,$2,$3,'2026-10-19','https://taskforce.lemonsqueezy.com/checkout/x',$4,$4)", [id, userId, plan, plan === "pro"]);
  return id;
}
const applySub = (client: pg.Client, userId: string, over: { event?: string; intent?: string | null; sub?: string; status?: string; ends?: string | null; updated: string; payment?: string | null; invoice?: string | null }) =>
  client.query("select billing_apply_subscription_v2($1,$2,$3,$4,'cus',$5,$6,$7,null,$8,$9,'1','monthly')", [userId, over.event ?? randomUUID(), over.intent ?? null, over.sub ?? `sub-${userId}`, over.status ?? "active", over.ends ?? null, over.updated, over.payment ?? null, over.invoice ?? null]);
const events = async (userId: string) => (await a.query<{ type: string }>("select type from metric_events where user_id=$1 order by type", [userId])).rows.map((r) => r.type);
/** Result of a query that must wait on a lock: "waiting" until released, then the outcome. */
const later = (promise: Promise<unknown>) => promise.then(() => "done", (error: Error) => error.message);
async function expectBlocked(promise: Promise<string>) {
  const early = await Promise.race([promise, new Promise<string>((resolve) => setTimeout(() => resolve("still waiting"), 400))]);
  expect(early).toBe("still waiting");
}

describe("entitlement writes serialize per account", () => {
  it("the same delivery sent by two requests at once is counted once", async () => {
    const u = await user();
    const i = await intent(u);
    const event = randomUUID();
    await a.query("begin");
    await applySub(a, u, { event, intent: i, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-1", updated: "2026-10-19T00:00:01Z" });
    const second = later(applySub(b, u, { event, intent: i, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-1", updated: "2026-10-19T00:00:01Z" }));
    await expectBlocked(second);
    await a.query("commit");
    expect(await second).toBe("done");
    expect(await events(u)).toEqual(["billing_subscription_activated"]);
    expect((await a.query("select count(*)::int n from billing_webhook_events where user_id=$1", [u])).rows[0]).toEqual({ n: 1 });
  });

  it("two different events of one subscription apply one after the other, each event once, newest state wins", async () => {
    const u = await user();
    const i = await intent(u);
    await a.query("begin");
    await applySub(a, u, { intent: i, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-1", updated: "2026-10-19T00:00:01Z" });
    const failed = later(applySub(b, u, { status: "past_due", updated: "2026-10-19T00:00:02Z" }));
    await expectBlocked(failed);
    await a.query("commit");
    expect(await failed).toBe("done");
    expect((await a.query("select status from billing_accounts where user_id=$1", [u])).rows[0]).toEqual({ status: "past_due" });
    expect(await events(u)).toEqual(["billing_payment_failed", "billing_subscription_activated"]);
  });

  it("an older snapshot that arrives second cannot undo the newer one", async () => {
    const u = await user();
    const i = await intent(u);
    await a.query("begin");
    await applySub(a, u, { intent: i, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-1", updated: "2026-10-19T00:00:09Z" });
    const stale = later(applySub(b, u, { status: "expired", updated: "2026-10-19T00:00:01Z" }));
    await expectBlocked(stale);
    await a.query("commit");
    expect(await stale).toBe("done");
    expect((await a.query("select status from billing_accounts where user_id=$1", [u])).rows[0]).toEqual({ status: "active" });
  });

  it("two subscriptions racing for one account: exactly one is applied, the other is refused as a duplicate", async () => {
    const u = await user();
    const first = await intent(u);
    await a.query("begin");
    await applySub(a, u, { intent: first, sub: `one-${u}`, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-1", updated: "2026-10-19T00:00:01Z" });
    const rival = later(applySub(b, u, { intent: first, sub: `two-${u}`, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-2", updated: "2026-10-19T00:00:02Z" }));
    await expectBlocked(rival);
    await a.query("commit");
    expect(await rival).toMatch(/billing_duplicate_subscription/);
    expect((await a.query("select subscription_id from billing_accounts where user_id=$1", [u])).rows[0]).toEqual({ subscription_id: `one-${u}` });
  });

  it("two Lifetime orders arriving together keep one entitlement and flag the second", async () => {
    const u = await user();
    const i = await intent(u, "lifetime");
    const j = await intent(u, "lifetime").catch(() => null);
    expect(j).toBeNull(); // only one open intent per account
    await a.query("begin");
    await a.query("select billing_apply_lifetime($1,$2,$3,$4,'cus','active',now(),'2026-10-19T00:00:01Z')", [u, randomUUID(), i, `o1-${u}`]);
    const second = b.query<{ r: string }>("select billing_apply_lifetime($1,$2,$3,$4,'cus','active',now(),'2026-10-19T00:00:02Z') r", [u, randomUUID(), i, `o2-${u}`]).then((result) => result.rows[0].r, (error: Error) => error.message);
    await expectBlocked(second as Promise<string>);
    await a.query("commit");
    expect(await second).toBe("duplicate");
    expect((await a.query("select lifetime_order_id from billing_accounts where user_id=$1", [u])).rows[0]).toEqual({ lifetime_order_id: `o1-${u}` });
    expect(await events(u)).toEqual(["billing_duplicate_purchase", "billing_lifetime_purchased"]);
  });
});

describe("checkout claims", () => {
  it("one open checkout per account across Pro and Lifetime", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id) values($1)", [u]);
    await a.query("begin");
    await a.query("select billing_claim_checkout_v2($1,'pro','2026-10-19')", [u]);
    const lifetime = later(b.query("select billing_claim_checkout_v2($1,'lifetime','2026-10-19')", [u]));
    const again = later(c.query("select billing_claim_checkout_v2($1,'pro','2026-10-19')", [u]));
    await expectBlocked(lifetime);
    await a.query("commit");
    expect(await lifetime).toMatch(/billing_checkout_pending/);
    expect(await again).toMatch(/billing_checkout_pending/); // the Pro URL is not attached yet
    expect((await a.query("select count(*)::int n from billing_checkout_intents where user_id=$1", [u])).rows[0]).toEqual({ n: 1 });
  });
});

describe("refund claim", () => {
  it("two requests at once: exactly one gets through the lock", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,subscription_id,status,plan,last_invoice_id,last_payment_at) values($1,$2,'active','monthly','inv-9',now()-interval '1 hour')", [u, `sub-${u}`]);
    await a.query("begin");
    const first = await a.query<{ c: Record<string, unknown> }>("select billing_claim_refund($1) c", [u]);
    expect(first.rows[0].c).toMatchObject({ kind: "subscription", invoice_id: "inv-9" });
    const second = later(b.query("select billing_claim_refund($1)", [u]));
    const third = later(c.query("select billing_claim_refund($1)", [u]));
    await expectBlocked(second);
    await a.query("commit");
    expect(await second).toMatch(/billing_refund_pending/);
    expect(await third).toMatch(/billing_refund_pending/);
  });

  it("a released claim can be taken again exactly once", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,lifetime_status,lifetime_order_id,lifetime_paid_at) values($1,'active',$2,now()-interval '1 hour')", [u, `o-${u}`]);
    await a.query("select billing_claim_refund($1)", [u]);
    await a.query("select billing_release_refund($1,true)", [u]);
    const outcomes = await Promise.all([b, c].map((client) => later(client.query("select billing_claim_refund($1)", [u]))));
    expect(outcomes.filter((o) => o === "done")).toHaveLength(1);
    expect(outcomes.filter((o) => o !== "done")[0]).toMatch(/billing_refund_pending/);
  });
});

describe("managed-cost reservations", () => {
  const reserve = (client: pg.Client, userId: string, usd: number, endpoint = "chat") =>
    client.query("select reserve_billing_ai_spend_v2($1,$2,$3,'m',$4,10,2)", [userId, randomUUID(), endpoint, usd]);

  it("concurrent reservations of one paid account share the hidden cap across endpoints", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,status,plan,current_period_ends_at,last_payment_at) values($1,'active','monthly',now()+interval '1 month',now())", [u]);
    await a.query("begin");
    await reserve(a, u, 6);
    const other = later(reserve(b, u, 6, "embeddings"));
    await expectBlocked(other);
    await a.query("commit");
    expect(await other).toMatch(/ai_budget_exhausted/);
    expect(Number((await a.query("select coalesce(sum(coalesce(cost_usd,reserved_usd)),0)::text s from ai_spend_attempts where user_id=$1", [u])).rows[0].s)).toBe(6);
  });

  it("a reservation that races a Lifetime purchase waits for it and is then refused: no managed cost after the entitlement changed", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,status,plan,current_period_ends_at,last_payment_at,first_subscription_at) values($1,'cancelled','monthly',now()+interval '10 days',now(),now())", [u]);
    const i = await intent(u, "lifetime");
    await a.query("begin");
    await a.query("select billing_apply_lifetime($1,$2,$3,$4,'cus','active',now(),'2026-10-19T00:00:01Z')", [u, randomUUID(), i, `o-${u}`]);
    const racing = later(reserve(b, u, 0.5));
    await expectBlocked(racing);
    await a.query("commit");
    expect(await racing).toMatch(/byok_required/);
    expect((await a.query("select count(*)::int n from ai_spend_attempts where user_id=$1", [u])).rows[0]).toEqual({ n: 0 });
  });

  it("a reservation admitted before the purchase stays on the ledger; every later one is refused", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,status,plan,current_period_ends_at,last_payment_at,first_subscription_at) values($1,'cancelled','monthly',now()+interval '10 days',now(),now())", [u]);
    await reserve(a, u, 0.5);
    const i = await intent(u, "lifetime");
    await a.query("select billing_apply_lifetime($1,$2,$3,$4,'cus','active',now(),'2026-10-19T00:00:01Z')", [u, randomUUID(), i, `o-${u}`]);
    await expect(reserve(b, u, 0.01)).rejects.toThrow(/byok_required/);
    expect((await a.query("select count(*)::int n from ai_spend_attempts where user_id=$1", [u])).rows[0]).toEqual({ n: 1 });
  });

  it("paid and grandfathered-beta reservations serialize on the same global daily limit", async () => {
    const paid = await user(), legacy = await user();
    await a.query("insert into billing_accounts(user_id,status,plan,current_period_ends_at,last_payment_at) values($1,'active','monthly',now()+interval '1 month',now())", [paid]);
    await a.query("insert into billing_accounts(user_id,legacy_beta) values($1,true)", [legacy]);
    await a.query("update ai_budget_policy set global_daily_usd=(select coalesce(sum(coalesce(cost_usd,reserved_usd)),0)+3 from ai_spend_attempts where cost_usd is null or created_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC')");
    try {
      await a.query("begin");
      await reserve(a, paid, 2);
      const beta = later(b.query("select reserve_ai_spend($1,$2,'chat','m',2)", [legacy, randomUUID()]));
      await expectBlocked(beta);
      await a.query("commit");
      expect(await beta).toMatch(/ai_global_daily_budget_exhausted/);
    } finally {
      await a.query("update ai_budget_policy set global_daily_usd=100000");
    }
  });
});

describe("missed-event sweep", () => {
  it("two cron runs claim disjoint batches (skip locked) and never the same account twice", async () => {
    const ids: string[] = [];
    for (let n = 0; n < 6; n++) {
      const u = await user();
      ids.push(u);
      await a.query("insert into billing_accounts(user_id,subscription_id,status,trial_ends_at) values($1,$2,'on_trial',now()+interval '1 day')", [u, `trial-${u}`]);
    }
    await a.query("begin");
    const firstRows = (await a.query<{ user_id: string }>("select user_id from billing_sweep_claim(3) where user_id = any($1)", [ids])).rows.map((r) => r.user_id);
    const secondRows = (await b.query<{ user_id: string }>("select user_id from billing_sweep_claim(3) where user_id = any($1)", [ids])).rows.map((r) => r.user_id);
    await a.query("commit");
    expect(firstRows.length + secondRows.length).toBeLessThanOrEqual(6);
    expect(new Set([...firstRows, ...secondRows]).size).toBe(firstRows.length + secondRows.length);
    const rest = (await c.query<{ user_id: string }>("select user_id from billing_sweep_claim(100) where user_id = any($1)", [ids])).rows.map((r) => r.user_id);
    expect(new Set([...firstRows, ...secondRows, ...rest]).size).toBe(6);
  });

  it("a claimed account is leased: a concurrent run does not take it again, and 'done' keeps it out for a day", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,subscription_id,status,trial_ends_at) values($1,$2,'on_trial',now()+interval '1 day')", [u, `lease-${u}`]);
    const mine = (client: pg.Client) => client.query<{ user_id: string }>("select user_id from billing_sweep_claim(100) where user_id=$1", [u]).then((r) => r.rows.length);
    expect(await mine(a)).toBe(1);
    expect(await mine(b)).toBe(0);
    await a.query("select billing_sweep_done($1,true)", [u]);
    expect(await mine(b)).toBe(0);
  });

  it("an account the run never got to (deadline) is a candidate again once the lease runs out, even at the edge of the 72-hour window", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,lifetime_status,lifetime_order_id,lifetime_paid_at) values($1,'active',$2,now()-interval '71 hours 58 minutes')", [u, `edge-${u}`]);
    const claim = () => a.query("select user_id from billing_sweep_claim(100) where user_id=$1", [u]).then((r) => r.rows.length);
    expect(await claim()).toBe(1);
    expect(await claim()).toBe(0);
    // the run was cut off before it got here: the lease expires, the window has meanwhile passed the claim time but not the stamp
    await a.query("update billing_accounts set sweep_claimed_at=now()-interval '6 minutes' where user_id=$1", [u]);
    expect(await claim()).toBe(1);
  });

  it("an unfinished claim is retried after its lease even though the 72-hour window has closed and the daily stamp is fresh", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,lifetime_status,lifetime_order_id,lifetime_paid_at,last_swept_at) values($1,'active',$2,now()-interval '71 hours 58 minutes',now()-interval '2 hours')", [u, `unfinished-${u}`]);
    const claim = () => a.query("select user_id from billing_sweep_claim(100) where user_id=$1", [u]).then((r) => r.rows.length);
    expect(await claim()).toBe(0); // swept two hours ago: nothing is due
    await a.query("update billing_accounts set sweep_claimed_at=now()-interval '6 minutes',lifetime_paid_at=now()-interval '73 hours' where user_id=$1", [u]);
    expect(await claim()).toBe(1); // claimed, cut off by the deadline, window over: still retryable
    expect(await claim()).toBe(0); // leased again
    await a.query("select billing_sweep_done($1,true)", [u]);
    await a.query("update billing_accounts set sweep_claimed_at=null where user_id=$1", [u]);
    expect(await claim()).toBe(0); // done is done
  });

  it("a failed account backs off for the rest of the hour", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,subscription_id,status,trial_ends_at) values($1,$2,'on_trial',now()+interval '1 day')", [u, `fail-${u}`]);
    await a.query("select user_id from billing_sweep_claim(100) where user_id=$1", [u]);
    await a.query("select billing_sweep_done($1,false)", [u]);
    expect((await a.query("select user_id from billing_sweep_claim(100) where user_id=$1", [u])).rows).toHaveLength(0);
    // the back-off is a lease about an hour long: nowhere near expiry for the next hour, expired once it has run out
    expect((await a.query<{ minutes: number }>("select (extract(epoch from sweep_claimed_at-now())/60)::int minutes from billing_accounts where user_id=$1", [u])).rows[0].minutes).toBeGreaterThanOrEqual(54);
    await a.query("update billing_accounts set sweep_claimed_at=now()-interval '6 minutes' where user_id=$1", [u]);
    expect((await a.query("select user_id from billing_sweep_claim(100) where user_id=$1", [u])).rows).toHaveLength(1);
  });
});

describe("self-service refund use", () => {
  it("a claim given back without clearing the use cannot be taken again; clearing the use (a refusal before the provider was asked) can", async () => {
    const u = await user();
    await a.query("insert into billing_accounts(user_id,lifetime_status,lifetime_order_id,lifetime_paid_at) values($1,'active',$2,now()-interval '1 hour')", [u, `ru-${u}`]);
    await a.query("select billing_claim_refund($1)", [u]);
    await a.query("select billing_release_refund($1,false)", [u]);
    expect(await later(b.query("select billing_claim_refund($1)", [u]))).toMatch(/billing_refund_used/);
    await a.query("update billing_accounts set self_refund_used_at=null where user_id=$1", [u]);
    await a.query("select billing_claim_refund($1)", [u]);
    await a.query("select billing_release_refund($1,true)", [u]);
    expect(await later(b.query("select billing_claim_refund($1)", [u]))).toBe("done");
  });
});

describe("intent binding under concurrency", () => {
  it("two purchases racing on one intent: one is attached, the other is refused and flagged exactly once", async () => {
    const u = await user();
    const i = await intent(u);
    const one = applySub(a, u, { intent: i, sub: `race-1-${u}`, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-1", updated: "2026-10-19T00:00:01Z" });
    const two = applySub(b, u, { intent: i, sub: `race-2-${u}`, status: "active", ends: iso(30 * DAY), payment: iso(0), invoice: "inv-2", updated: "2026-10-19T00:00:02Z" });
    const outcomes = await Promise.allSettled([one, two]);
    expect(outcomes.filter((o) => o.status === "fulfilled")).toHaveLength(1);
    const accepted = (await a.query<{ n: number }>("select count(*)::int n from billing_accounts where user_id=$1 and subscription_id is not null", [u])).rows[0].n;
    expect(accepted).toBe(1);
  });
});
