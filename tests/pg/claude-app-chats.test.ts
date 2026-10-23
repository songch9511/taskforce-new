// OA PR-D3s (tests/db/claude-app-chats.scenarios.ts): 실제 Postgres에서 같은 시나리오 + 연결 둘이 겹치는 경합.
// PGlite는 연결이 하나라 "동시에 온 두 요청"을 증명하지 못한다. 코디네이터의 일회용 Postgres(DATABASE_URL)에서 돌린다.
import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { asstMsg, claudeAppChatsTests, ref, userMsg, type ClaudeAppChatsDb, type Msg, type SaveResult } from "../db/claude-app-chats.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) throw new Error("npm run test:pg는 DATABASE_URL(일회용 데이터베이스를 만들 수 있는 실제 Postgres)이 필요합니다.");
const DB_NAME = `taskforce_claude_app_chats_${process.pid}_${Date.now()}`;
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

const db = (): ClaudeAppChatsDb => ({
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

describe("Claude 데스크톱 대화 저장 (실제 Postgres)", () => {
  claudeAppChatsTests(db);
});

const q = async (sql: string, params?: unknown[]) => (await setup.query(sql, params)).rows;
async function world() {
  const owner = randomUUID();
  await q("insert into auth.users (id, email) values ($1, $2)", [owner, `${owner}@example.com`]);
  const bridge = randomUUID();
  await q("insert into public.bridges (id, user_id, device_ref) values ($1, $2, $3)", [bridge, owner, `dev-${bridge}`]);
  return { owner, bridge };
}
const saveOn = async (client: pg.Client, w: { owner: string; bridge: string }, sessionRef: string, messages: Msg[], title: string | null = "제목") =>
  (await client.query<{ result: SaveResult }>("select public.save_claude_app_chat($1, $2, $3, $4, $5::jsonb) as result", [w.owner, w.bridge, sessionRef, title, JSON.stringify(messages)])).rows[0].result;
const count = async (sql: string, params?: unknown[]) => Number((await q(`select count(*)::int as n from (${sql}) t`, params))[0].n);
const chats = (w: { owner: string }) => count("select 1 from public.claude_app_chats where user_id = $1", [w.owner]);
const messages = (w: { owner: string }) => count("select 1 from public.claude_app_chat_messages where user_id = $1", [w.owner]);
const sentEvents = (w: { owner: string }) => count("select 1 from public.metric_events where user_id = $1 and type = 'claude_app_message_sent'", [w.owner]);

async function waitForLockWait() {
  for (let i = 0; i < 100; i++) {
    const { rows } = await setup.query<{ wait_event_type: string | null }>("select wait_event_type from pg_stat_activity where pid = $1", [bPid]);
    if (rows[0]?.wait_event_type === "Lock") return;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error("둘째 연결이 잠금을 기다리지 않는다");
}

describe("같은 (bridge, session_ref) 동시 PUT (연결 둘)", () => {
  it("먼저 온 쪽이 commit하면 뒤 쪽은 기다렸다가 같은 채팅에 붙는다: 채팅 1, 겹친 행은 existing, 지표는 새 사용자 글마다 1", async () => {
    const w = await world();
    await a.query("begin");
    await b.query("begin");
    const first = await saveOn(a, w, ref(1), [userMsg(1), asstMsg(2, 1)]);
    const waiting = saveOn(b, w, ref(1), [userMsg(1), asstMsg(2, 1), asstMsg(3, 1)]);
    await waitForLockWait();
    await a.query("commit");
    const second = await waiting;
    await b.query("commit");
    expect(first).toMatchObject({ status: "ok", saved: 2, existing: 0, orphan: 0 });
    expect(second).toEqual({ status: "ok", chat_id: first.chat_id, saved: 1, existing: 2, orphan: 0 });
    expect(await chats(w)).toBe(1);
    expect(await messages(w)).toBe(3);
    expect(await sentEvents(w)).toBe(1);
  });

  it("먼저 온 쪽이 rollback하면 뒤 쪽이 채팅을 만든다 (남는 채팅은 하나, 지표도 하나)", async () => {
    const w = await world();
    await a.query("begin");
    await b.query("begin");
    await saveOn(a, w, ref(1), [userMsg(1)]);
    const waiting = saveOn(b, w, ref(1), [userMsg(1)]);
    await waitForLockWait();
    await a.query("rollback");
    const second = await waiting;
    await b.query("commit");
    expect(second).toMatchObject({ saved: 1, existing: 0 });
    expect(await chats(w)).toBe(1);
    expect(await messages(w)).toBe(1);
    expect(await sentEvents(w)).toBe(1);
  });

  it("뒤 쪽의 답 글은 앞 쪽의 (아직 commit 전) 사용자 글을 기다렸다가 풀린다 — orphan이 되지 않는다", async () => {
    const w = await world();
    await a.query("begin");
    await b.query("begin");
    await saveOn(a, w, ref(1), [userMsg(1)]);
    const waiting = saveOn(b, w, ref(1), [asstMsg(2, 1)]);
    await waitForLockWait();
    await a.query("commit");
    expect(await waiting).toMatchObject({ saved: 1, orphan: 0 });
    await b.query("commit");
    expect(await messages(w)).toBe(2);
  });

  it("두 연결이 번갈아 같은 묶음을 자동 commit으로 20번 동시에 던져도 채팅 1 · 행 3 · 지표 1 · saved 합계 3", async () => {
    const w = await world();
    const batch = [userMsg(1), asstMsg(2, 1, { tool_names: ["Read", "Edit"] }), asstMsg(3, 1)];
    const results: SaveResult[] = [];
    for (let round = 0; round < 10; round++) results.push(...(await Promise.all([saveOn(a, w, ref(1), batch), saveOn(b, w, ref(1), batch)])));
    expect(results.reduce((sum, r) => sum + (r.saved ?? 0), 0)).toBe(3);
    expect(results.reduce((sum, r) => sum + (r.existing ?? 0), 0)).toBe(57);
    expect(new Set(results.map((r) => r.chat_id)).size).toBe(1);
    expect(await chats(w)).toBe(1);
    expect(await messages(w)).toBe(3);
    expect(await sentEvents(w)).toBe(1);
  });

  it("서로 다른 행을 동시에 올리면 합집합이 되고 seq는 겹치지 않는다", async () => {
    const w = await world();
    await saveOn(setup, w, ref(1), [userMsg(1)]);
    // 한 연결에는 한 번에 한 질의만 보낸다(pg 클라이언트 규칙). 연결 둘이 서로 동시에 올린다
    await Promise.all([
      (async () => {
        for (let n = 0; n < 5; n++) await saveOn(a, w, ref(1), [asstMsg(10 + n, 1)]);
      })(),
      (async () => {
        for (let n = 0; n < 5; n++) await saveOn(b, w, ref(1), [asstMsg(20 + n, 1)]);
      })(),
    ]);
    expect(await chats(w)).toBe(1);
    expect(await messages(w)).toBe(11);
    expect(await count("select distinct seq from public.claude_app_chat_messages where user_id = $1", [w.owner])).toBe(11);
  });
});

describe("저장과 겹치는 지우기 · bridge 해제 (연결 둘)", () => {
  it("지우기가 저장 뒤에 줄을 서면: 저장이 끝난 뒤 채팅 전체가 지워진다 (반쯤 지워진 채팅 0)", async () => {
    const w = await world();
    const made = await saveOn(setup, w, ref(1), [userMsg(1)]);
    await a.query("begin");
    await saveOn(a, w, ref(1), [asstMsg(2, 1), asstMsg(3, 1)]);
    await b.query("begin");
    const deleting = b.query("select public.delete_claude_app_chat($1, $2) as result", [w.owner, String(made.chat_id)]);
    await waitForLockWait();
    await a.query("commit");
    expect((await deleting).rows[0].result).toEqual({ status: "deleted" });
    await b.query("commit");
    expect(await chats(w)).toBe(0);
    expect(await messages(w)).toBe(0);
  });

  it("지우기가 먼저 잡으면: 뒤따르는 답 글은 기다렸다가 채팅이 없어 orphan(되살리지 않음), 새 사용자 글이면 새 채팅", async () => {
    const w = await world();
    const made = await saveOn(setup, w, ref(1), [userMsg(1)]);
    await a.query("begin");
    await a.query("select public.delete_claude_app_chat($1, $2)", [w.owner, String(made.chat_id)]);
    await b.query("begin");
    const lateReply = saveOn(b, w, ref(1), [asstMsg(2, 1)]);
    await waitForLockWait();
    await a.query("commit");
    expect(await lateReply).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 1 });
    await b.query("commit");
    expect(await chats(w)).toBe(0);
    const fresh = await saveOn(setup, w, ref(1), [userMsg(5)]);
    expect(fresh.chat_id).not.toBe(made.chat_id);
    expect(await chats(w)).toBe(1);
  });

  it("bridge 해제와 겹치면: 해제가 먼저 잠그면 저장은 기다렸다가 not_found, 저장이 먼저면 해제가 기다렸다가 끝나고 대화는 남는다", async () => {
    const w1 = await world();
    await a.query("begin");
    await a.query("select public.revoke_bridge($1, $2)", [w1.owner, w1.bridge]);
    await b.query("begin");
    const waiting = saveOn(b, w1, ref(1), [userMsg(1)]);
    await waitForLockWait();
    await a.query("commit");
    expect(await waiting).toEqual({ status: "not_found" });
    await b.query("commit");
    expect(await chats(w1)).toBe(0);

    const w2 = await world();
    await a.query("begin");
    const saved = await saveOn(a, w2, ref(1), [userMsg(1), asstMsg(2, 1)]);
    await b.query("begin");
    const revoking = b.query("select public.revoke_bridge($1, $2)", [w2.owner, w2.bridge]);
    await waitForLockWait();
    await a.query("commit");
    await revoking;
    await b.query("commit");
    expect(saved).toMatchObject({ status: "ok", saved: 2 });
    expect(await chats(w2)).toBe(1);
    expect(await messages(w2)).toBe(2);
    expect(await count("select 1 from public.bridges where id = $1 and status = 'revoked'", [w2.bridge])).toBe(1);
  });
});

// 모두 지우기 (OA D3v-s, 계약 27장): delete_all_claude_app_chats는 저장 · 하나 지우기와 같은 사용자별 잠금 아래 한 트랜잭션으로 지운다.
// 겹치는 저장은 줄을 선다 — 지우기 전에 끝난 저장은 지워지고, 지운 뒤에 온 저장은 묘비 때문에 되살리지 못하며, 고아 행(채팅 없는 메시지)이나 되살림이 남지 않는다.
const deleteAllOn = async (client: pg.Client, w: { owner: string }) =>
  (await client.query<{ result: { deleted: number } }>("select public.delete_all_claude_app_chats($1) as result", [w.owner])).rows[0].result;
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
/** 되살림 0: 묘비에 든 사용자 글이 그 (bridge, session_ref)의 채팅에 다시 들어 있지 않다 · 채팅 없는 메시지 0 · 답 글의 사용자 글은 같은 채팅 */
async function expectConsistent(w: { owner: string }) {
  expect(
    await count(
      `select 1 from public.claude_app_chat_messages m
         join public.claude_app_chats c on c.id = m.chat_id and c.user_id = m.user_id
         join public.claude_app_chat_tombstones t on t.bridge_id = c.bridge_id and t.session_ref = c.session_ref and t.mac_ref = m.mac_ref
        where m.user_id = $1 and m.role = 'user'`,
      [w.owner],
    ),
    "묘비에 든 글이 되살아남",
  ).toBe(0);
  expect(await count("select 1 from public.claude_app_chat_messages m left join public.claude_app_chats c on c.id = m.chat_id where m.user_id = $1 and c.id is null", [w.owner]), "채팅 없는 메시지").toBe(0);
  expect(
    await count("select 1 from public.claude_app_chat_messages a left join public.claude_app_chat_messages u on u.id = a.reply_to and u.chat_id = a.chat_id where a.user_id = $1 and a.role = 'assistant' and u.id is null", [w.owner]),
    "사용자 글 없는 답 글",
  ).toBe(0);
}

describe("모두 지우기와 겹치는 저장 (연결 둘)", () => {
  it("지우기가 먼저 잡으면: 뒤따르는 저장은 기다렸다가 — 지운 묶음의 재시도는 모두 orphan(되살리지 않음, 지표 0), 새 사용자 글이면 새 채팅 하나", async () => {
    const w = await world();
    const batch = [userMsg(1), asstMsg(2, 1)];
    await saveOn(setup, w, ref(1), batch);
    await saveOn(setup, w, ref(2), [userMsg(3)]);
    expect(await sentEvents(w)).toBe(2);
    await a.query("begin");
    expect(await deleteAllOn(a, w)).toEqual({ deleted: 2 });
    await b.query("begin");
    const replay = saveOn(b, w, ref(1), batch);
    await waitForLockWait();
    await a.query("commit");
    expect(await replay).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 2 });
    await b.query("commit");
    expect(await chats(w)).toBe(0);
    expect(await messages(w)).toBe(0);
    expect(await sentEvents(w)).toBe(2);
    await expectConsistent(w);
    // 새 글(새 ref)은 새 채팅 하나
    expect(await saveOn(setup, w, ref(1), [userMsg(9)])).toMatchObject({ status: "ok", saved: 1 });
    expect(await chats(w)).toBe(1);
    expect(await sentEvents(w)).toBe(3);
  });

  it("저장이 먼저 잡고 있으면: 모두 지우기는 기다렸다가 그 저장의 새 행 · 새 채팅까지 함께 지운다 (일부만 남지 않는다). 그 뒤 같은 묶음의 재시도는 막힌다", async () => {
    const w = await world();
    await saveOn(setup, w, ref(1), [userMsg(1)]);
    await a.query("begin");
    await saveOn(a, w, ref(1), [asstMsg(2, 1), asstMsg(3, 1)]);
    await saveOn(a, w, ref(5), [userMsg(10)]);
    await b.query("begin");
    const deleting = deleteAllOn(b, w);
    await waitForLockWait();
    await a.query("commit");
    expect(await deleting).toEqual({ deleted: 2 });
    await b.query("commit");
    expect(await chats(w)).toBe(0);
    expect(await messages(w)).toBe(0);
    expect(await saveOn(setup, w, ref(1), [userMsg(1), asstMsg(2, 1), asstMsg(3, 1)])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 3 });
    expect(await saveOn(setup, w, ref(5), [userMsg(10)])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 1 });
    await expectConsistent(w);
  });

  it("잠금은 사용자별이다: 한 사용자의 모두 지우기가 열려 있어도 다른 사용자의 저장 · 지우기는 기다리지 않는다", async () => {
    const w1 = await world();
    const w2 = await world();
    await saveOn(setup, w1, ref(1), [userMsg(1)]);
    await saveOn(setup, w2, ref(1), [userMsg(1)]);
    await a.query("begin");
    expect(await deleteAllOn(a, w1)).toEqual({ deleted: 1 });
    // 기다렸다면 statement_timeout(15초)에 걸려 실패한다
    expect(await saveOn(b, w2, ref(2), [userMsg(2)])).toMatchObject({ status: "ok", saved: 1 });
    expect(await deleteAllOn(b, w2)).toEqual({ deleted: 2 });
    await a.query("commit");
    expect(await chats(w1)).toBe(0);
    expect(await chats(w2)).toBe(0);
  });

  it("두 모두 지우기가 겹쳐도 한 번씩 순서대로다: 먼저 온 쪽이 모두 지우고 뒤 쪽은 {deleted: 0} (지표는 한 번)", async () => {
    const w = await world();
    for (let n = 1; n <= 3; n++) await saveOn(setup, w, ref(n), [userMsg(1)]);
    await a.query("begin");
    await b.query("begin");
    const first = await deleteAllOn(a, w);
    const waiting = deleteAllOn(b, w);
    await waitForLockWait();
    await a.query("commit");
    const second = await waiting;
    await b.query("commit");
    expect([first, second]).toEqual([{ deleted: 3 }, { deleted: 0 }]);
    expect(await count("select 1 from public.metric_events where user_id = $1 and type = 'claude_app_chats_deleted_all'", [w.owner])).toBe(1);
    expect(await count("select 1 from public.claude_app_chat_tombstones where user_id = $1", [w.owner])).toBe(3);
  });

  it("자동 commit으로 저장 서른 번과 모두 지우기 여섯 번을 동시에 던져도 (연결 둘, 세 판): 고아 행 0 · 되살림 0 — 마지막에 한 번 더 지운 뒤 보낸 글을 모두 다시 보내도 채팅 · 행이 하나도 생기지 않는다", async () => {
    for (let round = 0; round < 3; round++) {
      const w = await world();
      const sent: { session: number; n: number }[] = [];
      await Promise.all([
        (async () => {
          for (let n = 1; n <= 30; n++) {
            const session = 1 + (n % 3);
            sent.push({ session, n });
            const result = await saveOn(a, w, ref(session), [userMsg(n)]);
            expect(result.status).toBe("ok");
          }
        })(),
        (async () => {
          for (let i = 0; i < 6; i++) {
            await sleep(3);
            await deleteAllOn(b, w);
          }
        })(),
      ]);
      await expectConsistent(w);
      // 마지막으로 모두 지운다. 지운 모든 글은 (이번 판의 앞선 지우기 + 이 지우기가) 묘비에 남겼다
      await deleteAllOn(b, w);
      expect(await chats(w)).toBe(0);
      expect(await messages(w)).toBe(0);
      const eventsBefore = await sentEvents(w);
      for (const { session, n } of sent) {
        expect(await saveOn(setup, w, ref(session), [userMsg(n), asstMsg(1000 + n, n)]), `${session}:${n}`).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 2 });
      }
      expect(await chats(w)).toBe(0);
      expect(await messages(w)).toBe(0);
      expect(await sentEvents(w)).toBe(eventsBefore);
      await expectConsistent(w);
      // 새 글(새 ref)은 막히지 않는다
      expect(await saveOn(setup, w, ref(1), [userMsg(500)])).toMatchObject({ status: "ok", saved: 1 });
    }
  });
});

describe("사용자별 한도 · 묘비와 겹치는 요청 (연결 둘)", () => {
  /** 한도가 세는 값: 모든 행의 (본문 바이트 + 행 몫 512)의 합 */
  const charged = async (owner: string) =>
    Number((await q("select coalesce(sum(octet_length(body) + 512), 0)::bigint as n from public.claude_app_chat_messages where user_id = $1", [owner]))[0].n);
  /** 사용자의 저장 본문을 한도 직전까지 채운다 (SQL): 채팅 하나의 답 글 793 × (65,536바이트 + 행 몫 512). 남는 자리 = 한도 − 합계 */
  async function fillNearCap(w: { owner: string; bridge: string }, sessionRef: string) {
    const made = await saveOn(setup, w, sessionRef, [userMsg(1)]);
    const userRow = String((await q("select id from public.claude_app_chat_messages where chat_id = $1", [String(made.chat_id)]))[0].id);
    await q("set statement_timeout = '240s'");
    try {
      await q(
        `insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, reply_to, body, truncated, said_at)
         select $1, $2, 'assistant', lpad(to_hex(g), 64, '0'), $3, repeat('a', 65536), false, now() from generate_series(100000, 100792) g`,
        [w.owner, String(made.chat_id), userRow],
      );
    } finally {
      await q("set statement_timeout = '15s'");
    }
    return 52_428_800 - (await charged(w.owner));
  }
  /** 사용자 글 12바이트 + 답 글 40,000바이트: 행 몫을 더해 41,036 */
  const big = (n: number) => [userMsg(10 + n), asstMsg(20 + n, 10 + n, { body: "a".repeat(40_000) })];

  it("남은 자리가 하나뿐일 때 서로 다른 세션 둘이 동시에 올리면: 먼저 잡은 쪽만 저장되고 뒤 쪽은 기다렸다가 quota_exceeded (사용자 단위 잠금으로 한도를 넘지 못한다)", { timeout: 300_000 }, async () => {
    const w = await world();
    const remaining = await fillNearCap(w, ref(1));
    expect(remaining).toBeGreaterThan(41_100);
    expect(remaining).toBeLessThan(80_000);
    await a.query("begin");
    await b.query("begin");
    const first = await saveOn(a, w, ref(2), big(1));
    const waiting = saveOn(b, w, ref(3), big(2));
    await waitForLockWait();
    await a.query("commit");
    const second = await waiting;
    await b.query("commit");
    expect(first).toMatchObject({ status: "ok", saved: 2 });
    expect(second).toEqual({ status: "quota_exceeded" });
    expect(await chats(w)).toBe(2);
    expect(await charged(w.owner)).toBeLessThanOrEqual(52_428_800);
  });

  it("자동 commit으로 동시에 던져도 한도를 넘지 못한다 (남은 자리에 하나만 들어간다)", { timeout: 300_000 }, async () => {
    const w = await world();
    await fillNearCap(w, ref(1));
    const results = await Promise.all([saveOn(a, w, ref(2), big(1)), saveOn(b, w, ref(3), big(2))]);
    expect(results.map((r) => r.status).sort()).toEqual(["ok", "quota_exceeded"]);
    expect(await charged(w.owner)).toBeLessThanOrEqual(52_428_800);
  });

  it("지우기가 먼저 잡으면: 같은 묶음의 재시도는 기다렸다가 묘비를 보고 orphan — 대화도 지표도 되살아나지 않는다", async () => {
    const w = await world();
    const batch = [userMsg(1), asstMsg(2, 1)];
    const made = await saveOn(setup, w, ref(1), batch);
    expect(await sentEvents(w)).toBe(1);
    await a.query("begin");
    await a.query("select public.delete_claude_app_chat($1, $2)", [w.owner, String(made.chat_id)]);
    await b.query("begin");
    const replay = saveOn(b, w, ref(1), batch);
    await waitForLockWait();
    await a.query("commit");
    expect(await replay).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 2 });
    await b.query("commit");
    expect(await chats(w)).toBe(0);
    expect(await messages(w)).toBe(0);
    expect(await sentEvents(w)).toBe(1);
  });

  it("재시도가 먼저 잡고 있으면: 지우기는 기다렸다가 지우고, 그 뒤 재시도는 묘비에 막힌다 (반쯤 지워진 채팅 0)", async () => {
    const w = await world();
    const batch = [userMsg(1), asstMsg(2, 1)];
    const made = await saveOn(setup, w, ref(1), batch);
    await a.query("begin");
    await saveOn(a, w, ref(1), [asstMsg(3, 1)]);
    await b.query("begin");
    const deleting = b.query("select public.delete_claude_app_chat($1, $2) as result", [w.owner, String(made.chat_id)]);
    await waitForLockWait();
    await a.query("commit");
    expect((await deleting).rows[0].result).toEqual({ status: "deleted" });
    await b.query("commit");
    expect(await chats(w)).toBe(0);
    expect(await saveOn(setup, w, ref(1), batch)).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 2 });
  });
});

describe("속도 제한 claude_app_chat · claude_app_sent · claude_app_chat_day · claude_app_chat_delete_all (연결 여럿)", () => {
  it.each(["claude_app_chat", "claude_app_sent", "claude_app_chat_day", "claude_app_chat_delete_all"])("%s: 연결 여덟이 동시에 열 번씩 80번을 불러도 정확히 30번만 통과한다 (사용자 · 종류별 잠금)", async (kind) => {
    const owner = randomUUID();
    await q("insert into auth.users (id, email) values ($1, $2)", [owner, `${owner}@example.com`]);
    const clients = await Promise.all(Array.from({ length: 8 }, () => connect(DB_NAME)));
    try {
      const take = async (client: pg.Client) => (await client.query<{ at: string | null }>("select public.take_rate_limit($1, $2, 30, 600) as at", [owner, kind])).rows[0].at;
      const results = (
        await Promise.all(
          clients.map(async (client) => {
            const own: (string | null)[] = [];
            for (let i = 0; i < 10; i++) own.push(await take(client));
            return own;
          }),
        )
      ).flat();
      expect(results).toHaveLength(80);
      expect(results.filter((at) => at === null)).toHaveLength(30);
      expect(await count("select 1 from public.rate_limit_events where user_id = $1 and kind = $2", [owner, kind])).toBe(30);
    } finally {
      await Promise.allSettled(clients.map((client) => client.end()));
    }
  });
});
