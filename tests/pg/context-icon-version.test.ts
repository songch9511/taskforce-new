import pg from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";

// Same expected_version race as the production RPC. This file is for the coordinator's real-Postgres run only.
const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("tests/pg/context-icon-version.test.ts requires DATABASE_URL (run by the coordinator with a disposable Postgres database)");

const DB_NAME = `taskforce_context_icon_version_${process.pid}_${Date.now()}`;
const USER = "00000000-0000-0000-0000-00000000000a";
const CONTEXT = "00000000-0000-4000-8000-000000000001";
let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;

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
  await setup.query("insert into auth.users (id, email) values ($1, 'icon-race@example.com')", [USER]);
  await setup.query(`select public.create_work_context($1, 'Before race', 'project', 'compass')`, [USER]);
  await setup.query(`update public.work_contexts set id = $1 where user_id = $2`, [CONTEXT, USER]);
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
});

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end()]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

describe("프로젝트 편집 version 경합 (실제 Postgres)", () => {
  it("같은 expected_version의 PATCH 둘 중 하나만 쓰고 나머지는 conflict", async () => {
    const update = (client: pg.Client, name: string) =>
      client.query<{ status: string }>(`select public.update_work_context($1, $2, 1, $3, null, null) ->> 'status' as status`, [USER, CONTEXT, name]);
    const results = await Promise.all([update(a, "First"), update(b, "Second")]);
    expect(results.map(({ rows }) => rows[0].status).sort()).toEqual(["conflict", "ok"]);
    const { rows } = await setup.query<{ name: string; version: number }>(`select name, version from public.work_contexts where id = $1`, [CONTEXT]);
    expect(Number(rows[0].version)).toBe(2);
    expect(["First", "Second"]).toContain(rows[0].name);
    const event = await setup.query<{ count: string }>(`select count(*)::text as count from public.metric_events where user_id = $1 and type = 'project_renamed'`, [USER]);
    expect(Number(event.rows[0].count)).toBe(1);
  });
});
