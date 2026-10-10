import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";
import { memoryWritesFixtures, memoryWritesTests } from "../db/memory-writes.scenarios";

// 시나리오가 서버 코드(src/lib/context/memory-writes.ts · src/lib/conversation/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 기억 쓰기 (20261107000000_memory_writes) — 실제 Postgres. PGlite와 같은 시나리오 + 연결 둘이 겹치는 경합:
// 잊기 ↔ 정정 · 같은 요청 둘 · 확인 둘 · 옮기기 ↔ 정정 · 옮기기 ↔ 같은 사실 다시 말함 · 반대 방향 옮기기(교착 없음) · 옮기기 ↔ Slack 끊기 · 범위 version.
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const DB_NAME = `taskforce_memory_writes_${process.pid}_${Date.now()}`;

let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
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
  a = await connect(urlFor(DB_NAME));
  b = await connect(urlFor(DB_NAME));
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
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

// 한 연결(setup)에 쿼리를 차례로 보낸다: 서버 코드가 Promise.all로 동시에 읽어도 pg 클라이언트에 겹쳐 보내지 않게
let chain: Promise<unknown> = Promise.resolve();
const serial = <T,>(run: () => Promise<T>): Promise<T> => {
  const next = chain.then(run, run);
  chain = next.catch(() => undefined);
  return next;
};

const db = () => ({
  query: (sql: string, params?: unknown[]) => serial(async () => (await setup.query(sql, params)).rows),
  asUser: async <T,>(userId: string, fn: () => Promise<T>) => {
    await setup.query(`set role authenticated`);
    await setup.query(`select set_config('request.jwt.claim.sub', $1, false)`, [userId]);
    try {
      return await fn();
    } finally {
      await setup.query(`reset role`);
      await setup.query(`select set_config('request.jwt.claim.sub', '', false)`);
    }
  },
});

describe("기억 쓰기 (실제 Postgres)", () => {
  memoryWritesTests(db);
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

const forget = (client: pg.Client, userId: string, id: string, version: number) =>
  client.query(`select status from public.forget_memory_item($1, $2, $3)`, [userId, id, version]).then((r) => r.rows[0].status as string);
const move = (client: pg.Client, userId: string, id: string, version: number, contextId: string | null) =>
  client
    .query(`select status, id from public.move_memory_item($1, $2, $3, $4, $5)`, [userId, id, version, contextId ? "context" : "global", contextId])
    .then((r) => r.rows[0] as { status: string; id: string | null });
/** 정정(B1 remember_memory_item p_corrects): 확인 · Edit가 쓰는 SQL */
const correct = (client: pg.Client, userId: string, id: string, version: number, statement: string) =>
  client
    .query(`select status, id from public.remember_memory_item($1, $2::jsonb, $3, $4)`, [
      userId,
      JSON.stringify({ kind: "fact", scope_kind: "global", subject: null, statement, origin: "explicit", value: {} }),
      id,
      version,
    ])
    .then((r) => r.rows[0] as { status: string; id: string | null });
const restate = (client: pg.Client, userId: string, contextId: string | null, statement: string) =>
  client
    .query(`select status, id from public.remember_memory_item($1, $2::jsonb)`, [
      userId,
      JSON.stringify({ kind: "fact", scope_kind: contextId ? "context" : "global", context_id: contextId, subject: "launch day", statement, origin: "explicit" }),
    ])
    .then((r) => r.rows[0] as { status: string; id: string | null });

describe("기억 쓰기 경합 (실제 Postgres, 연결 둘)", () => {
  const f = memoryWritesFixtures(db);
  const currentOf = async (userId: string) => (await f.current(userId)).map((r) => r.statement).sort();

  it("잊기가 먼저 잠그면 같은 version의 정정은 기다렸다가 conflict (새 행 0, 잊은 채 그대로). 정정이 먼저면 잊기가 conflict (정정된 항목은 잊지 않는다)", async () => {
    const me = await f.user();
    const forgotten = await f.explicit(me, { subject: "s1", statement: "잊을 사실" });
    await a.query("begin");
    expect(await forget(a, me, forgotten, 1)).toBe("forgotten");
    const edit = correct(b, me, forgotten, 1, "고친 사실");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await edit).status).toBe("conflict");
    expect(await currentOf(me)).toEqual([]);
    expect((await f.row(forgotten)).superseded_at).toBeNull();

    const edited = await f.explicit(me, { subject: "s2", statement: "고칠 사실" });
    await a.query("begin");
    const written = await correct(a, me, edited, 1, "고친 사실");
    expect(written.status).toBe("written");
    const late = forget(b, me, edited, 1);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await late).toBe("conflict");
    expect(await currentOf(me)).toEqual(["고친 사실"]);
    expect((await f.row(edited)).revoked_at).toBeNull();
  });

  it("같은 잊기를 동시에 두 번 보내면 하나만 쓰고 다른 쪽은 멱등 성공이다 (version은 한 번만 오른다)", async () => {
    const me = await f.user();
    const id = await f.explicit(me);
    await a.query("begin");
    expect(await forget(a, me, id, 1)).toBe("forgotten");
    const second = forget(b, me, id, 1);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await second).toBe("already_forgotten");
    expect((await f.row(id)).version).toBe(2);
  });

  it("같은 후보를 두 곳에서 동시에 확인하면 하나만 쓰이고 다른 쪽은 conflict (지금 행은 하나)", async () => {
    const me = await f.user();
    const candidate = await f.candidate(me);
    await a.query("begin");
    const first = await correct(a, me, candidate, 1, "출시는 목요일인 듯");
    expect(first.status).toBe("written");
    const second = correct(b, me, candidate, 1, "출시는 목요일인 듯");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await second).status).toBe("conflict");
    expect(await f.count(`select count(*)::int as n from public.memory_items where user_id = $1 and origin = 'explicit' and superseded_at is null`, [me])).toBe(1);
  });

  it("옮기기가 먼저 잠그면 같은 version의 정정은 기다렸다가 conflict, 새 지금 행은 옮긴 것 하나뿐이다 (같은 사실의 잠금이 한 줄로 세운다)", async () => {
    const me = await f.user();
    const context = await f.context(me);
    const id = await f.explicit(me);
    await a.query("begin");
    const moved = await move(a, me, id, 1, context);
    expect(moved.status).toBe("moved");
    const edit = correct(b, me, id, 1, "옮기는 동안 고침");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await edit).status).toBe("conflict");
    expect(await f.current(me)).toEqual([{ id: moved.id, statement: "출시는 목요일", scope_kind: "context", context_id: context }]);
  });

  it("옮기는 동안 대상 범위에서 같은 사실을 다시 말하면 한 줄로 서서, 지금 행은 다시 말한 것 하나뿐이다 (옮긴 행은 정정된 이력)", async () => {
    const me = await f.user();
    const context = await f.context(me);
    const id = await f.explicit(me, { statement: "옮길 글" });
    await a.query("begin");
    const moved = await move(a, me, id, 1, context);
    expect(moved.status).toBe("moved");
    const restated = restate(b, me, context, "그 범위에서 다시 말함");
    await waitForLockWait(bPid);
    await a.query("commit");
    const written = await restated;
    expect(written.status).toBe("written");
    expect(await currentOf(me)).toEqual(["그 범위에서 다시 말함"]);
    expect(await f.row(moved.id!)).toMatchObject({ superseded_by: written.id });
  });

  it("반대 방향의 옮기기 둘은 교착하지 않는다: 같은 사실의 잠금을 키 순서로 잡아 하나가 끝난 뒤 다른 쪽은 conflict (정정된 행은 옮기지 않는다)", async () => {
    const me = await f.user();
    const context = await f.context(me);
    const global = await f.explicit(me, { statement: "전체의 글" });
    const scoped = await f.explicit(me, { scope_kind: "context", context_id: context, statement: "범위의 글" });
    await a.query("begin");
    const toContext = await move(a, me, global, 1, context); // 전체 → 범위: 범위의 같은 사실(scoped)을 정정한다
    expect(toContext.status).toBe("moved");
    const toGlobal = move(b, me, scoped, 1, null); // 범위 → 전체
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await toGlobal).status).toBe("conflict");
    expect(await currentOf(me)).toEqual(["전체의 글"]);
    // 반대 순서도 같다
    const g2 = await f.explicit(me, { subject: "other", statement: "전체 2" });
    const c2 = await f.explicit(me, { scope_kind: "context", context_id: context, subject: "other", statement: "범위 2" });
    await a.query("begin");
    expect((await move(a, me, c2, 1, null)).status).toBe("moved");
    const back = move(b, me, g2, 1, context);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await back).status).toBe("conflict");
  });

  it("Slack 끊기(D3)와 옮기기가 겹쳐도 새 행에 Slack 인용이 남지 않는다: 끊기가 먼저면 옮기기는 conflict(version이 올랐다), 옮기기가 먼저면 끊기가 새 행의 인용도 뺀다", async () => {
    const me = await f.user();
    const context = await f.context(me);
    const cf = f.conversations;
    const first = await cf.connectionSource(me, "slack", "#sales\n김대표: 목요일");
    const second = await cf.connectionSource(me, "slack", "#sales\n김대표: 금요일");
    const early = await f.explicit(me, { subject: "d1", statement: "끊기가 먼저", source_ref: { source_id: first, quote: "목요일" } });
    const late = await f.explicit(me, { subject: "d2", statement: "옮기기가 먼저", source_ref: { source_id: second, quote: "금요일" } });

    await a.query("begin");
    await a.query(`select public.purge_slack_sources(array[$1]::uuid[])`, [first]);
    const blocked = move(b, me, early, 1, context);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await blocked).status).toBe("conflict");
    expect((await f.row(early)).source_ref).toEqual({ source_id: first });

    await b.query("begin");
    const moved = await move(b, me, late, 1, context);
    expect(moved.status).toBe("moved");
    expect((await b.query(`select source_ref from public.memory_items where id = $1`, [moved.id])).rows[0].source_ref).toEqual({ source_id: second, quote: "금요일" }); // 아직 끊기 전 (커밋 전이라 b가 본다)
    const purging = a.query(`select public.purge_slack_sources(array[$1]::uuid[])`, [second]);
    await new Promise((resolve) => setTimeout(resolve, 200));
    await b.query("commit");
    await purging;
    expect((await f.row(moved.id!)).source_ref).toEqual({ source_id: second });
    expect((await f.row(late)).source_ref).toEqual({ source_id: second });
  });

  it("같은 범위의 기억 둘을 동시에 잊으면 둘 다 쓰이고 범위 version은 잃지 않고 + 2 (트랜잭션마다 하나씩)", async () => {
    const me = await f.user();
    const context = await f.context(me);
    const x = await f.explicit(me, { scope_kind: "context", context_id: context, subject: "x", statement: "X" });
    const y = await f.explicit(me, { scope_kind: "context", context_id: context, subject: "y", statement: "Y" });
    const before = await f.version(context);
    await a.query("begin");
    await b.query("begin");
    expect(await forget(a, me, x, 1)).toBe("forgotten");
    expect(await forget(b, me, y, 1)).toBe("forgotten");
    await a.query("commit");
    await b.query("commit");
    expect(await f.version(context)).toBe(before + 2);
    expect(await f.current(me)).toEqual([]);
  });

  it("범위 안의 같은 사실을 옮기기 둘이 같은 대상으로 동시에 정정해도 지금 행은 하나다 (옮긴 쪽끼리 한 줄)", async () => {
    const me = await f.user();
    const context = await f.context(me);
    const one = await f.explicit(me, { statement: "첫째" });
    const two = await f.explicit(me, { scope_kind: "context", context_id: await f.context(me, "다른"), statement: "둘째" });
    await a.query("begin");
    expect((await move(a, me, one, 1, context)).status).toBe("moved");
    const second = move(b, me, two, 1, context);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await second).status).toBe("moved");
    expect((await f.current(me)).filter((r) => r.context_id === context)).toHaveLength(1);
    expect(await f.count(`select count(*)::int as n from public.memory_items where user_id = $1 and context_id = $2 and superseded_at is null and revoked_at is null`, [me, context])).toBe(1);
  });
});
