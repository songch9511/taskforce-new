import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { supabaseSchemaScripts } from "../db/local-supabase";
import { contextMembersFixtures, contextMembersTests, okOf } from "../db/context-members.scenarios";

// 시나리오가 서버 코드(src/lib/context/member-writes.ts · src/lib/context/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 S3b 멤버십 쓰기 (20261108000000_context_member_user_writes) — 실제 Postgres. PGlite와 같은 시나리오 + 연결 둘이 겹치는 경합:
// 반대 방향 옮기기(교착 없음, 조건부라 나중 요청은 conflict) · 자동 규칙의 멤버 추가 ↔ 사용자 빼기/넣기 · 같은 요청 둘 · 서로 다른 할 일 둘(응답 version이 정확) · 범위/할 일 삭제 ↔ 넣기 · 보관 ↔ 넣기(알려진 한계).
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const DB_NAME = `taskforce_context_members_${process.pid}_${Date.now()}`;

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


describe("멤버십 쓰기 (실제 Postgres)", () => {
  contextMembersTests(db);
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

type Result = {
  status: string;
  added_member: { id: string } | null;
  removed_member: { id: string } | null;
  added_changed: boolean;
  removed_changed: boolean;
  added_version: number | null;
  removed_version: number | null;
};
type Target = [contextId: string, expectedVersion: number];
/** 서버 함수 하나 (옮기기 = 둘 다) */
const change = (client: pg.Client, userId: string, actionId: string, add: Target | null, remove: Target | null) =>
  client
    .query(
      `select status, added_member, removed_member, added_changed, removed_changed, added_version, removed_version
         from public.change_context_membership_by_user($1, $2, $3, $4, $5, $6)`,
      [userId, actionId, add?.[0] ?? null, add?.[1] ?? null, remove?.[0] ?? null, remove?.[1] ?? null],
    )
    .then((r) => r.rows[0] as Result);
/** 자동 규칙의 멤버 추가 (store.ts addContextMember와 같은 문장: 이미 있으면 그대로) */
const autoInsert = (client: pg.Client, userId: string, contextId: string, actionId: string) =>
  client.query(
    `insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'auto') on conflict (context_id, action_id) do nothing`,
    [userId, contextId, actionId],
  );

describe("멤버십 쓰기 경합 (실제 Postgres, 연결 둘)", () => {
  const f = contextMembersFixtures(db);
  const target = async (contextId: string): Promise<Target> => [contextId, await f.seen(contextId)];

  it("반대 방향의 옮기기 둘이 겹쳐도 교착하지 않는다: 매번 에러 없이 ok 또는 conflict(나중 요청은 낡은 version이라 거절)이고 끝 상태는 같다 (잠금 순서가 고정이라 40P01이 없다)", async () => {
    const me = await f.user();
    const [x, y] = [await f.context(me, "X"), await f.context(me, "Y")];
    const action = await f.action(me);
    okOf(await f.add(me, x, action));
    okOf(await f.add(me, y, action)); // 두 행이 모두 있어야 서로의 행을 잠그려 한다
    let from = x;
    let to = y;
    for (let i = 0; i < 40; i++) {
      // from → to 와 to → from 이 같은 version을 보고 동시에 온다
      const [seenFrom, seenTo] = [await f.seen(from), await f.seen(to)];
      const results = await Promise.all([change(a, me, action, [to, seenTo], [from, seenFrom]), change(b, me, action, [from, seenFrom], [to, seenTo])]);
      const statuses = results.map((r) => r.status);
      expect(statuses.every((status) => status === "ok" || status === "conflict"), `반복 ${i}: ${statuses}`).toBe(true);
      expect(statuses, `반복 ${i}`).toContain("ok");
      // 어느 쪽이 먼저 도착했든 끝 상태는 하나다: 지금 멤버는 정확히 한 범위, 행은 둘
      const current = await f.current(action);
      expect(current, `반복 ${i}`).toHaveLength(1);
      expect(await f.rowsOf(action)).toHaveLength(2);
      [from, to] = [current[0].context_id, current[0].context_id === from ? to : from];
    }
  }, 60_000);

  it("서로 다른 할 일의 반대 방향 옮기기도 교착하지 않는다 (범위 version 올림은 범위 id 순): 에러 없이 ok 또는 conflict, ok였던 쪽은 옮겨졌다", async () => {
    const me = await f.user();
    const [x, y] = [await f.context(me, "X"), await f.context(me, "Y")];
    const [one, two] = [await f.action(me, "하나"), await f.action(me, "둘")];
    okOf(await f.add(me, x, one));
    okOf(await f.add(me, y, two));
    for (let i = 0; i < 30; i++) {
      const [seenX, seenY] = [await f.seen(x), await f.seen(y)];
      const [r1, r2] = await Promise.all([change(a, me, one, [y, seenY], [x, seenX]), change(b, me, two, [x, seenX], [y, seenY])]);
      for (const r of [r1, r2]) expect(["ok", "conflict"], `반복 ${i}`).toContain(r.status);
      // 다음 반복을 위해 두 할 일을 원래 자리로 되돌린다
      const [nowX, nowY] = [await f.seen(x), await f.seen(y)];
      const oneIn = (await f.current(one))[0].context_id;
      const twoIn = (await f.current(two))[0].context_id;
      if (oneIn !== x) okOf(await f.move(me, one, y, x, { expectedFrom: nowY, expectedTo: nowX }));
      if (twoIn !== y) okOf(await f.move(me, two, x, y, { expectedFrom: await f.seen(x), expectedTo: await f.seen(y) }));
    }
  }, 60_000);

  it("옮기기가 열려 있는 동안 같은 할 일의 반대 방향 옮기기는 기다렸다가 낡은 version이라 conflict다: 나중 요청이 앞 결정을 덮지 못한다 (직렬 + 조건부)", async () => {
    const me = await f.user();
    const [x, y] = [await f.context(me, "X"), await f.context(me, "Y")];
    const action = await f.action(me);
    okOf(await f.add(me, x, action));
    const [seenX, seenY] = [await f.seen(x), await f.seen(y)];
    await a.query("begin");
    expect((await change(a, me, action, [y, seenY], [x, seenX])).status).toBe("ok"); // X → Y
    const second = change(b, me, action, [x, seenX], [y, seenY]); // 같은 version을 본 Y → X
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await second).status).toBe("conflict");
    expect(await f.current(action)).toEqual([{ context_id: y, origin: "user" }]);
  });

  it("자동 규칙의 멤버 추가와 사용자 빼기가 겹쳐도 사용자의 선택이 이긴다: 어느 쪽이 먼저든 행은 하나, 끝 상태는 user + removed_at (자동 규칙이 되살리지 못한다)", async () => {
    const me = await f.user();
    const ctx = await f.context(me);
    // 자동 추가가 먼저 잠그고(미커밋) 사용자 빼기가 뒤따른다: 빼기는 자동 행이 커밋되길 기다렸다가 같은 행을 user 뺀 행으로 바꾼다
    // (이 요청의 version 조건은 자동 행이 커밋되기 전에 확인된다: 사용자 쓰기끼리의 조건이고 자동 규칙은 사용자의 뺀 선택을 덮지 못한다)
    const first = await f.action(me, "자동 먼저");
    const seen = await target(ctx);
    await a.query("begin");
    await autoInsert(a, me, ctx, first);
    const removal = change(b, me, first, null, seen);
    await waitForLockWait(bPid);
    await a.query("commit");
    const removed = await removal;
    expect(removed.status).toBe("ok");
    expect(removed.removed_changed).toBe(true); // 커밋된 자동 행(확인된 멤버)을 뺐다
    expect(await f.rowsOf(first)).toMatchObject([{ origin: "user", confidence: null }]);
    expect((await f.rowsOf(first))[0].removed_at).not.toBeNull();
    expect(await f.current(first)).toEqual([]);

    // 사용자 빼기가 먼저 잠그고(미커밋) 자동 추가가 뒤따른다: 자동 추가는 기다렸다가 아무것도 하지 않는다
    const second = await f.action(me, "빼기 먼저");
    await a.query("begin");
    expect((await change(a, me, second, null, await target(ctx))).status).toBe("ok");
    const auto = autoInsert(b, me, ctx, second);
    await waitForLockWait(bPid);
    await a.query("commit");
    await auto;
    expect(await f.rowsOf(second)).toMatchObject([{ origin: "user" }]);
    expect(await f.current(second)).toEqual([]);
  });

  it("자동 규칙이 먼저 넣은 멤버를 사용자가 넣기로 승격하는 것과 겹쳐도 행은 하나이고 끝은 user 멤버", async () => {
    const me = await f.user();
    const ctx = await f.context(me);
    const action = await f.action(me);
    const seen = await target(ctx);
    await a.query("begin");
    await autoInsert(a, me, ctx, action);
    const add = change(b, me, action, seen, null);
    await waitForLockWait(bPid);
    await a.query("commit");
    const added = await add;
    expect(added.status).toBe("ok");
    expect(added.added_changed).toBe(false); // 승격이지 새 멤버가 아니다: 자동 행이 이미 확인된 멤버였다
    expect(await f.rowsOf(action)).toMatchObject([{ origin: "user", confidence: null, removed_at: null }]);
  });

  it("같은 요청 둘이 동시에 와도 행은 하나이고 하나만 ok, 나머지는 conflict, 범위 version은 한 번만 오른다 (새 멱등성 저장소가 없다: 둘 다 ok가 되지 않는다)", async () => {
    const me = await f.user();
    const ctx = await f.context(me);
    for (let i = 0; i < 10; i++) {
      const action = await f.action(me, `할 일 ${i}`);
      const seen = await target(ctx);
      const [one, two] = await Promise.all([change(a, me, action, seen, null), change(b, me, action, seen, null)]);
      expect([one.status, two.status].sort(), `반복 ${i}`).toEqual(["conflict", "ok"]);
      expect(await f.rowsOf(action)).toHaveLength(1);
      expect(await f.version(ctx)).toBe(seen[1] + 1);
    }
  });

  it("서로 다른 할 일 둘을 같은 범위에 넣으면 둘 다 들어가고 범위 version은 + 2이며 각 응답의 version은 그 쓰기 직후의 정확한 값이다 (앞 쓰기가 범위 행을 잡고 있으면 뒤 쓰기는 거기서 기다린다)", async () => {
    const me = await f.user();
    const ctx = await f.context(me);
    const [one, two] = [await f.action(me, "하나"), await f.action(me, "둘")];
    const seen = await target(ctx);
    await a.query("begin");
    const first = await change(a, me, one, seen, null);
    const secondPending = change(b, me, two, seen, null); // 같은 version을 봤다: 서로 다른 할 일이라 충돌이 아니다
    await waitForLockWait(bPid); // 범위 행의 version 올림에서 기다린다
    await a.query("commit");
    const second = await secondPending;
    expect([first.status, second.status]).toEqual(["ok", "ok"]);
    expect([first.added_version, second.added_version]).toEqual([seen[1] + 1, seen[1] + 2]);
    expect(await f.version(ctx)).toBe(seen[1] + 2);
    expect(await f.current(one)).toHaveLength(1);
    expect(await f.current(two)).toHaveLength(1);
  });

  it("할 일 삭제와 넣기가 겹쳐도 고아 멤버십이 남지 않는다: 넣기가 열려 있으면 삭제가 기다렸다가 cascade로 지우고, 삭제가 먼저면 넣기는 action_not_found", async () => {
    const me = await f.user();
    const ctx = await f.context(me);
    const first = await f.action(me, "넣기 먼저");
    await a.query("begin");
    expect((await change(a, me, first, await target(ctx), null)).status).toBe("ok");
    const deletion = b.query(`delete from public.actions where id = $1`, [first]);
    await waitForLockWait(bPid);
    await a.query("commit");
    await deletion;
    expect(await f.rowsOf(first)).toEqual([]);

    const second = await f.action(me, "삭제 먼저");
    const seen = await target(ctx);
    await a.query("begin");
    await a.query(`delete from public.actions where id = $1`, [second]);
    const add = change(b, me, second, seen, null);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await add).status).toBe("action_not_found");
    expect(await f.rowsOf(second)).toEqual([]);
  });

  it("범위 삭제와 넣기가 겹쳐도 같다: 넣기가 열려 있으면 삭제가 기다렸다가 cascade, 삭제가 먼저면 context_not_found", async () => {
    const me = await f.user();
    const [first, second] = [await f.context(me, "넣기 먼저"), await f.context(me, "삭제 먼저")];
    const action = await f.action(me);
    await a.query("begin");
    expect((await change(a, me, action, await target(first), null)).status).toBe("ok");
    const deletion = b.query(`delete from public.work_contexts where id = $1`, [first]);
    await waitForLockWait(bPid);
    await a.query("commit");
    await deletion;
    expect(await f.rowsOf(action)).toEqual([]);

    const seen = await target(second);
    await a.query("begin");
    await a.query(`delete from public.work_contexts where id = $1`, [second]);
    const add = change(b, me, action, seen, null);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await add).status).toBe("context_not_found");
    expect(await f.rowsOf(action)).toEqual([]);
  });

  it("알려진 한계: 보관(archive)이 먼저 범위 행을 잡고 있으면 그 직전에 active를 확인한 넣기는 보관이 커밋된 뒤 이어서 쓴다 — 보관 쪽 잠금(for no key update)이 넣기의 for key share와 충돌하지 않는다 (멤버십은 보관과 무관하게 남고 이후 요청은 404). 넣기가 먼저면 보관이 기다린다", async () => {
    const me = await f.user();
    const [first, second] = [await f.context(me, "보관 먼저"), await f.context(me, "넣기 먼저")];
    const action = await f.action(me);
    const seen = await target(first);
    await a.query("begin");
    await a.query(`update public.work_contexts set status = 'archived' where id = $1`, [first]);
    const add = change(b, me, action, seen, null);
    await waitForLockWait(bPid); // 범위 version 올림에서 기다린다 (active 확인은 이미 지나갔다)
    await a.query("commit");
    expect((await add).status).toBe("ok");
    expect(await f.current(action)).toEqual([{ context_id: first, origin: "user" }]);
    expect((await change(b, me, await f.action(me, "다른 일"), await target(first), null)).status).toBe("context_not_found");

    // 반대 순서: 넣기가 범위 행을 잡고 있으면 보관(update)이 기다린다
    const third = await f.action(me, "셋");
    await a.query("begin");
    expect((await change(a, me, third, await target(second), null)).status).toBe("ok");
    const archive = b.query(`update public.work_contexts set status = 'archived' where id = $1`, [second]);
    await waitForLockWait(bPid);
    await a.query("commit");
    await archive;
    expect(await f.current(third)).toEqual([{ context_id: second, origin: "user" }]);
  });
});
