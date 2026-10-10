import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { payloadHash } from "@/lib/conversation/proposal";

import { conversationFixtures, conversationsTests } from "../db/conversations-v2.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 시나리오가 서버 코드(src/lib/conversation/store.ts)를 실제 SQL로 부른다
vi.mock("server-only", () => ({}));

// 0.2.0 대화 v2 (20261106000000_conversations_v2) — 실제 Postgres. PGlite와 같은 시나리오 + 연결 둘이 겹치는 경합:
// 같은 제출 두 번(같은 client_message_id) · 같은 메시지의 답 두 번 · 같은 제안 채택 두 번 · 같은 기억 동시 정정 · 늦은 응답.
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const DB_NAME = `taskforce_conversations_${process.pid}_${Date.now()}`;

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

describe("대화 v2 (실제 Postgres)", () => {
  conversationsTests(db);
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

const post = (client: pg.Client, userId: string, conversationId: string, clientId: string, text: string) =>
  client.query(`select * from public.conversation_post_message($1, $2, $3, $4, 75)`, [userId, conversationId, clientId, text]).then((r) => r.rows[0]);
const finish = (client: pg.Client, userId: string, messageId: string, turn: Record<string, unknown>) =>
  client
    .query(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [
      userId,
      messageId,
      JSON.stringify({ user: { intent: null, refs: {} }, reply: { text: "답", refs: {}, content: null }, memory: [], adopt: null, ...turn }),
    ])
    .then((r) => r.rows[0]);

describe("대화 v2 경합 (실제 Postgres, 연결 둘)", () => {
  const f = conversationFixtures(db);

  it("같은 client_message_id를 동시에 보내면 하나만 쓰이고 다른 쪽은 처리 중(in_progress)을 본다. 다른 제출은 seq가 겹치지 않는다", async () => {
    const me = await f.user();
    const conversation = await f.conversation(me);
    const client = randomUUID();
    await a.query("begin");
    const first = await post(a, me, conversation, client, "오늘 뭐 하지?");
    const second = post(b, me, conversation, client, "오늘 뭐 하지?");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(first.status).toBe("created");
    expect(await second).toMatchObject({ status: "in_progress", message_id: first.message_id });

    await a.query("begin");
    const x = await post(a, me, conversation, randomUUID(), "둘");
    const y = post(b, me, conversation, randomUUID(), "셋");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect([x.seq, (await y).seq]).toEqual([2, 3]);
    expect(await f.count(`select count(*)::int as n from public.conversation_messages where conversation_id = $1`, [conversation])).toBe(3);
  });

  it("같은 메시지의 답을 동시에 쓰면 하나만 written이고 다른 쪽은 그 답을 answered로 받는다 (채택도 Action 1)", async () => {
    const me = await f.user();
    const conversation = await f.conversation(me);
    const proposal = await f.proposal(me, conversation);
    const message = await f.post(me, conversation, randomUUID(), "그렇게 해");
    const adopt = (title: string) => {
      const actionId = randomUUID();
      const noteId = randomUUID();
      const now = new Date().toISOString();
      const claim = (field: string, value: string) => ({
        id: randomUUID(), user_id: me, action_id: actionId, source_id: noteId, field, value, quote: title, occurred_at: now,
        speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "shared", origin: "user", channel: "note", state: "active",
      });
      return {
        proposal_message_id: proposal.messageId, proposal_id: proposal.proposalId, payload_hash: payloadHash({ kind: "create_action", title }), action_id: actionId,
        note: { id: noteId, title: "Taskforce 대화", raw_text: title, external_url: "taskforce://conversations/x#y" },
        action: { title, owner: "me", status: "open", due_date: null, due_at: null, needs_confirmation: false, confirm_reasons: [], resolution: null, counterpart: null, embedding: null },
        claims: [claim("scope", title), claim("owner", "me"), claim("status", "open")],
        evidence: [{ source_id: noteId, quote: title, role: "created" }],
        events: [{ type: "user_created", before: null, after: { title }, rule: "user", actor: "user", source_id: noteId }],
      };
    };
    await a.query("begin");
    const first = await finish(a, me, message.message_id!, { adopt: adopt("Shape 출시 준비") });
    const second = finish(b, me, message.message_id!, { adopt: adopt("Shape 출시 준비") });
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(first.status).toBe("written");
    expect(await second).toMatchObject({ status: "answered", reply_id: first.reply_id });
    expect(await f.actionCounts(me)).toMatchObject({ actions: 1, notes: 1, userClaims: 3 });
  });

  it("두 대화에서 같은 기억을 같은 version으로 동시에 정정하면 하나만 쓰이고 다른 turn은 conflict (지금 행은 하나)", async () => {
    const me = await f.user();
    const target = (await f.one(`select * from public.remember_memory_item($1, $2::jsonb)`, [
      me,
      JSON.stringify({ kind: "plan", scope_kind: "global", subject: "개발 에이전트", statement: "개발은 Opus 5.5로", origin: "explicit" }),
    ])).id as string;
    const c1 = await f.conversation(me);
    const c2 = await f.conversation(me);
    const m1 = await f.post(me, c1, randomUUID(), "Sonnet으로 바꿔");
    const m2 = await f.post(me, c2, randomUUID(), "Haiku로 바꿔");
    const correction = (statement: string) => ({
      memory: [{ item: { kind: "plan", scope_kind: "global", subject: null, statement, origin: "explicit", value: {} }, corrects: target, expected_version: 1 }],
    });
    await a.query("begin");
    expect((await finish(a, me, m1.message_id!, correction("개발은 Sonnet 5.5로"))).status).toBe("written");
    const late = finish(b, me, m2.message_id!, correction("개발은 Haiku로"));
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await late).status).toBe("conflict");
    const current = await db().query(`select statement from public.memory_items where user_id = $1 and superseded_at is null`, [me]);
    expect(current.map((r) => r.statement)).toEqual(["개발은 Sonnet 5.5로"]);
    expect(await f.message(m2.message_id!)).toMatchObject({ reply_lease_until: null });
  });

  it("늦은 응답: 새 메시지의 답이 먼저 커밋되면 옛 메시지의 답은 stale (기억 0). 옛 답이 먼저면 새 메시지는 그 답 뒤 seq로 쓰인다", async () => {
    const me = await f.user();
    const conversation = await f.conversation(me);
    const old = await f.post(me, conversation, randomUUID(), "개발은 Opus 5.5로 할 거야");
    const newer = await f.post(me, conversation, randomUUID(), "아니 Sonnet 5.5로 할 거야");
    const item = (statement: string) => ({ memory: [{ item: { kind: "plan", scope_kind: "global", subject: "개발 에이전트", statement, origin: "explicit", value: {} } }] });
    await a.query("begin");
    expect((await finish(a, me, newer.message_id!, item("개발은 Sonnet 5.5로"))).status).toBe("written");
    const late = finish(b, me, old.message_id!, item("개발은 Opus 5.5로"));
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await late).status).toBe("stale");
    expect((await db().query(`select statement from public.memory_items where user_id = $1 and superseded_at is null`, [me])).map((r) => r.statement)).toEqual(["개발은 Sonnet 5.5로"]);

    const other = await f.conversation(me);
    const first = await f.post(me, other, randomUUID(), "첫 메시지");
    await a.query("begin");
    const answered = await finish(a, me, first.message_id!, {});
    const next = post(b, me, other, randomUUID(), "다음 메시지");
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(answered).toMatchObject({ status: "written", reply_seq: 2 });
    expect(await next).toMatchObject({ status: "created", seq: 3 });
  });
});
