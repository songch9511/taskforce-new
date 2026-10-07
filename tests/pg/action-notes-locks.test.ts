import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";

// A real row-lock race proves two same-revision note saves cannot both commit. PGlite runs on one connection.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error("npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg");
}

const DB_NAME = `taskforce_notes_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let bPid: number;
let userId: string;
let actionId: string;

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

async function waitForLockWait(pid: number) {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [pid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`connection ${pid} did not wait for the Action notes row lock`);
}

beforeAll(async () => {
  admin = await connect(DATABASE_URL!);
  await admin.query(`create database ${DB_NAME}`);
  setup = await connect(urlFor(DB_NAME));
  for (const sql of await supabaseSchemaScripts()) await setup.query(sql);
  userId = randomUUID();
  actionId = randomUUID();
  await setup.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await setup.query("insert into public.actions (id, user_id, title) values ($1, $2, 'Notes race')", [actionId, userId]);
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);

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

describe("Action notes compare-and-set race (real Postgres)", () => {
  it("serializes same-revision saves and commits one note plus one event", async () => {
    await a.query("begin");
    const first = await a.query<{ status: string; revision: number }>("select status, revision from public.save_action_notes($1, $2, 'first save', 0)", [userId, actionId]);
    expect(first.rows[0]).toEqual({ status: "saved", revision: 1 });

    const secondPromise = b.query<{ status: string; revision: number }>("select status, revision from public.save_action_notes($1, $2, 'stale save', 0)", [userId, actionId]);
    await waitForLockWait(bPid);
    expect((await setup.query<{ notes_markdown: string; notes_revision: number }>("select notes_markdown, notes_revision from public.actions where id = $1", [actionId])).rows[0])
      .toEqual({ notes_markdown: "", notes_revision: 0 });

    await a.query("commit");
    expect((await secondPromise).rows[0]).toEqual({ status: "conflict", revision: 1 });
    expect((await setup.query<{ notes_markdown: string; notes_revision: number }>("select notes_markdown, notes_revision from public.actions where id = $1", [actionId])).rows[0])
      .toEqual({ notes_markdown: "first save", notes_revision: 1 });
    expect((await setup.query<{ n: number }>("select count(*)::int n from public.action_events where action_id = $1 and type = 'user_notes_updated'", [actionId])).rows[0].n).toBe(1);
  });
});
