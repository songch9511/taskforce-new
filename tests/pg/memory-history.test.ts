import pg from "pg";
import { afterAll, beforeAll, describe } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";
import { memoryHistoryTests } from "../db/memory-history.scenarios";

// 기억의 정정 · 잊기 이력을 실제 Postgres(CI: pgvector/pgvector:pg17)에서: on delete set null (열 목록) · 트리거 · 부분 인덱스 · RLS가 PGlite와 같게 도는지.
const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error("DATABASE_URL is required for actual Postgres memory history tests");

const database = `taskforce_memory_${process.pid}_${Date.now()}`;
let admin: pg.Client;
let client: pg.Client;

beforeAll(async () => {
  admin = new pg.Client({ connectionString });
  await admin.connect();
  await admin.query(`create database ${database}`);
  const url = new URL(connectionString!);
  url.pathname = `/${database}`;
  client = new pg.Client({ connectionString: url.toString() });
  await client.connect();
  for (const sql of await supabaseSchemaScripts()) await client.query(sql);
});

afterAll(async () => {
  await client?.end();
  if (admin) {
    await admin.query(`drop database if exists ${database} with (force)`);
    await admin.end();
  }
});

describe("memory_items 정정 · 잊기 이력 (실제 Postgres)", () => {
  memoryHistoryTests(() => ({
    query: async (sql, params) => (await client.query(sql, params)).rows,
    asUser: async (userId, fn) => {
      await client.query(`set role authenticated`);
      await client.query(`select set_config('request.jwt.claim.sub', $1, false)`, [userId]);
      try {
        return await fn();
      } finally {
        await client.query(`reset role`);
        await client.query(`select set_config('request.jwt.claim.sub', '', false)`);
      }
    },
  }));
});
