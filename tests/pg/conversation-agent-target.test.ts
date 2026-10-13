import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import { D1B_MIGRATION, conversationAgentFixtures, conversationAgentTargetTests, type ConversationAgentDb } from "../db/conversation-agent-target.scenarios";
import { supabaseSchemaScripts } from "../db/local-supabase";

// 0.2.0 대화 대상과 에이전트 글 (20261114000000_conversation_agent_target, 구현 계획 D1b) — 실제 Postgres. PGlite와 같은 시나리오 +
// 연결이 겹치는 경합(T10): 같은 agent 대화에 사용자 post와 에이전트 글 append가 동시에 와도 seq에 빈틈 · 중복이 없고, 같은 event id의 append는 한 줄만 남으며,
// 만료 sweep은 다른 트랜잭션이 잡고 있는 행을 기다리지 않고 건너뛴다.
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const SUFFIX = `${process.pid}_${Date.now()}`;
const DB_NAME = `taskforce_conversation_agent_target_${SUFFIX}`;

let admin: pg.Client;
let setup: pg.Client;
let a: pg.Client;
let b: pg.Client;
let aPid: number;
let bPid: number;
const extraClients: pg.Client[] = [];

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
  aPid = (await a.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
  bPid = (await b.query<{ pid: number }>("select pg_backend_pid() as pid")).rows[0].pid;
}, 120_000);

afterAll(async () => {
  await Promise.allSettled([a?.end(), b?.end(), setup?.end(), ...extraClients.map((client) => client.end())]);
  if (admin) {
    await admin.query(`drop database if exists ${DB_NAME} with (force)`);
    await admin.end();
  }
});

afterEach(async () => {
  await a.query("rollback").catch(() => {});
  await b.query("rollback").catch(() => {});
});

// 한 연결(setup)에 쿼리를 차례로 보낸다: 시나리오가 Promise.all로 동시에 읽어도 pg 클라이언트에 겹쳐 보내지 않게
let chain: Promise<unknown> = Promise.resolve();
const serial = <T,>(run: () => Promise<T>): Promise<T> => {
  const next = chain.then(run, run);
  chain = next.catch(() => undefined);
  return next;
};

const db = (): ConversationAgentDb => ({
  query: (sql, params) => serial(async () => (await setup.query(sql, params)).rows),
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

describe("대화 대상과 에이전트 글 (실제 Postgres)", () => {
  conversationAgentTargetTests(db);
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

const SELECTED = JSON.stringify({ action_ids: [], run_ids: [], artifact_ids: [] });
const post = (client: pg.Client, userId: string, conversationId: string, clientId: string, text: string) =>
  client.query<{ status: string; message_id: string | null; seq: number | null }>(`select * from public.conversation_post_message($1, $2, $3, $4, $5::jsonb, 75)`, [userId, conversationId, clientId, text, SELECTED]);
const append = (client: pg.Client, userId: string, conversationId: string, taskId: string, eventId: string, text: string, kind = "reply") =>
  client.query<{ status: string; message_id: string | null; seq: number | null }>(`select * from public.conversation_append_agent_message($1, $2, $3, 1, $4, $5, $6)`, [
    userId,
    conversationId,
    taskId,
    eventId,
    text,
    kind,
  ]);

describe("T10 대화 대상 경합 (실제 Postgres, 연결 둘 이상)", () => {
  const f = conversationAgentFixtures(db);
  const seqs = async (conversationId: string) => (await f.messages(conversationId)).map((m) => Number(m.seq));

  it("같은 agent 대화에 사용자 post와 에이전트 글 append를 번갈아 겹치면 대화 잠금이 한 줄로 세운다: seq 1..5, 빈틈 · 중복 0", async () => {
    const w = await f.agentWorld(); // seq 1 = 사용자 메시지(queued)
    await a.query("begin");
    await b.query("begin");
    const first = (await post(a, w.user, w.conversation, randomUUID(), "둘째 메시지")).rows[0]; // a가 대화 잠금을 쥔다
    const blocked = append(b, w.user, w.conversation, w.task, "evt-1", "에이전트 답", "reply");
    await waitForLockWait(bPid);
    await a.query("commit");
    const reply = (await blocked).rows[0]; // b가 이어받고 commit 전까지 쥔다
    await a.query("begin");
    const secondPost = post(a, w.user, w.conversation, randomUUID(), "넷째 메시지");
    await waitForLockWait(aPid);
    const event = (await append(b, w.user, w.conversation, w.task, "evt-2", "알림", "event")).rows[0]; // 같은 트랜잭션 안이라 b가 이미 쥔 잠금으로 바로 간다
    await b.query("commit");
    const second = (await secondPost).rows[0];
    await a.query("commit");
    expect([first.status, reply.status, event.status, second.status]).toEqual(["created", "created", "created", "created"]);
    expect([first.seq, reply.seq, event.seq, second.seq]).toEqual([2, 3, 4, 5]);
    expect(await seqs(w.conversation)).toEqual([1, 2, 3, 4, 5]);
    expect((await f.messages(w.conversation)).map((m) => m.role)).toEqual(["user", "user", "assistant", "event", "user"]);
  });

  it("연결 여덟이 한꺼번에: 사용자 post 셋(같은 client_message_id 둘 포함) + append 셋(같은 event id 둘 포함) → 새 줄 6개, seq 연속 · 중복 0, 중복 제출은 exists · duplicate", async () => {
    const w = await f.agentWorld();
    const clients: pg.Client[] = [];
    for (let i = 0; i < 8; i++) {
      const client = await connect(urlFor(DB_NAME));
      clients.push(client);
      extraClients.push(client);
    }
    const sameClient = randomUUID();
    const results = await Promise.all([
      post(clients[0], w.user, w.conversation, sameClient, "같은 제출"),
      post(clients[1], w.user, w.conversation, sameClient, "같은 제출"),
      post(clients[2], w.user, w.conversation, randomUUID(), "다른 제출"),
      append(clients[3], w.user, w.conversation, w.task, "evt-same", "같은 사건"),
      append(clients[4], w.user, w.conversation, w.task, "evt-same", "같은 사건"),
      append(clients[5], w.user, w.conversation, w.task, "evt-other", "다른 사건", "question"),
      post(clients[6], w.user, w.conversation, randomUUID(), "또 다른 제출"),
      append(clients[7], w.user, w.conversation, w.task, "evt-third", "또 다른 사건", "event"),
    ]);
    const rows = results.map((result) => result.rows[0]);
    const statuses = rows.map((row) => row.status).sort();
    expect(statuses).toEqual(["created", "created", "created", "created", "created", "created", "duplicate", "exists"]);
    // 같은 제출 · 같은 사건은 한 줄만 만들고, 기다린 쪽은 같은 id를 돌려받는다
    const [p0, p1, a3, a4] = [rows[0], rows[1], rows[3], rows[4]];
    expect(p0.message_id).toBe(p1.message_id);
    expect(a3.message_id).toBe(a4.message_id);
    expect(await seqs(w.conversation)).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1 and external_event_id = 'evt-same'`, [w.conversation])).toBe(1);
    expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1 and client_message_id = $2`, [w.conversation, sameClient])).toBe(1);
    // 에이전트 대화라 코디네이터 사건은 한 줄도 없다
    expect(await f.userMessageEvents(w.user)).toBe(0);
  });

  it("같은 event id를 두 연결이 동시에 append하면 한 줄만 남는다: 먼저 commit하면 뒤 쪽은 duplicate, 먼저가 rollback하면 뒤 쪽이 만든다", async () => {
    const w = await f.agentWorld();
    await a.query("begin");
    await b.query("begin");
    const created = (await append(a, w.user, w.conversation, w.task, "evt-race", "하나")).rows[0];
    const waiting = append(b, w.user, w.conversation, w.task, "evt-race", "하나");
    await waitForLockWait(bPid);
    await a.query("commit");
    const duplicate = (await waiting).rows[0];
    await b.query("commit");
    expect(created).toMatchObject({ status: "created", seq: 2 });
    expect(duplicate).toEqual({ status: "duplicate", message_id: created.message_id, seq: 2 });
    expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1 and external_event_id = 'evt-race'`, [w.conversation])).toBe(1);

    // 앞 쪽이 rollback하면 뒤 쪽이 만든다 (같은 seq를 이어받는다: 빈틈 없음)
    await a.query("begin");
    await b.query("begin");
    await append(a, w.user, w.conversation, w.task, "evt-rollback", "하나");
    const second = append(b, w.user, w.conversation, w.task, "evt-rollback", "하나");
    await waitForLockWait(bPid);
    await a.query("rollback");
    expect((await second).rows[0]).toMatchObject({ status: "created", seq: 3 });
    await b.query("commit");
    expect(await seqs(w.conversation)).toEqual([1, 2, 3]);
  });

  it("같은 client_message_id를 두 연결이 동시에 post하면 한 줄만 남는다 (agent 대화: created → exists)", async () => {
    const w = await f.agentWorld();
    const clientId = randomUUID();
    await a.query("begin");
    await b.query("begin");
    const created = (await post(a, w.user, w.conversation, clientId, "같은 제출")).rows[0];
    const waiting = post(b, w.user, w.conversation, clientId, "같은 제출");
    await waitForLockWait(bPid);
    await a.query("commit");
    const exists = (await waiting).rows[0];
    await b.query("commit");
    expect(created).toMatchObject({ status: "created", seq: 2 });
    expect(exists).toMatchObject({ status: "exists", message_id: created.message_id, seq: 2 });
    expect(await seqs(w.conversation)).toEqual([1, 2]);
  });

  it("만료 sweep은 다른 트랜잭션이 잡은 행을 기다리지 않고 건너뛴다: 전달 상태로 바꾸는 중인 행은 덮어쓰지 않고, 놓은 뒤 다음 sweep이 본다", async () => {
    const w = await f.agentWorld();
    const past = new Date(Date.now() - 3600_000).toISOString();
    await f.q(`update public.conversation_messages set delivery_expires_at = $2 where id = $1`, [w.message, past]);
    await a.query("begin");
    await a.query(`update public.conversation_messages set delivery_state = 'dispatched' where id = $1`, [w.message]); // 전달 단계가 dispatched로 바꾸는 중
    const swept = await b.query<{ n: number }>(`select public.conversation_expire_agent_messages(now()) as n`); // 기다리지 않고 돌아온다
    expect(swept.rows[0].n).toBe(0);
    await a.query("commit");
    expect((await f.one(`select delivery_state from public.conversation_messages where id = $1`, [w.message])).delivery_state).toBe("dispatched");
    // dispatched는 만료되지 않는다
    expect(Number((await f.one(`select public.conversation_expire_agent_messages(now()) as n`)).n)).toBe(0);

    // 놓은 뒤에는 지난 queued를 expired로 바꾼다
    const second = await f.post(w.user, w.conversation, randomUUID(), "둘째");
    await f.q(`update public.conversation_messages set delivery_expires_at = $2 where id = $1`, [second.message_id, past]);
    expect(Number((await f.one(`select public.conversation_expire_agent_messages(now()) as n`)).n)).toBe(1);
    expect((await f.one(`select delivery_state from public.conversation_messages where id = $1`, [second.message_id])).delivery_state).toBe("expired");
  });
});

// 독립 검토(Codex) P2: 마이그레이션의 LOCK TABLE(대화 → 메시지)이 진행 중인 B2 답 저장(conversation_finish_turn: 메시지를 먼저 읽고 대화를 잠금)과 순환 대기를 만들 수 있다.
// lock_timeout은 교착을 막지 않는다(교착 감지가 먼저, 사용자 트랜잭션이 40P01로 중단될 수 있다). 그래서 잠금문은 NOWAIT이다: 경합이면 기다리지 않고 바로 실패(롤백)한다.
describe("T13 마이그레이션의 표 잠금은 진행 중인 B2 답 저장과 교착하지 않는다 (실제 Postgres)", () => {
  const f = conversationAgentFixtures(db);
  /** 마이그레이션 파일의 실제 잠금문 (주석 제외). 문구를 시험에 베끼지 않고 파일에서 읽어, 파일의 잠금문이 바뀌면 이 시험이 그것을 돌린다 */
  const lockStatement = () => {
    const sql = readFileSync(path.resolve(__dirname, "../../supabase/migrations", D1B_MIGRATION), "utf8")
      .split("\n")
      .filter((line) => !line.trim().startsWith("--"))
      .join("\n");
    return sql.match(/^lock table [^;]+;/m)![0];
  };

  it("답 저장이 메시지를 읽은 채 대화 잠금으로 가는 순간 마이그레이션의 잠금문은 기다리지 않고 55P03으로 실패하고, 답 저장은 성공한다", async () => {
    const user = await f.user();
    const conversation = await f.conversation(user);
    const sent = await f.post(user, conversation, randomUUID(), "질문"); // 대상 taskforce의 사용자 메시지 (B2 경로)

    // A = conversation_finish_turn의 순서: 메시지를 먼저 읽어 ACCESS SHARE를 쥐고(트랜잭션 끝까지), 그 다음에 대화 행을 잠근다
    await a.query("begin");
    await a.query(`select id from public.conversation_messages where id = $1`, [sent.message_id]);

    // B = 마이그레이션의 앞부분 (begin; set local lock_timeout; lock table …)
    await b.query("begin");
    await b.query("set local lock_timeout = '5s'");
    const migration = b.query(lockStatement()).then(
      () => ({ ok: true as const }),
      (error: { code?: string }) => ({ ok: false as const, code: error.code }),
    );
    // NOWAIT이면 바로 실패한다. 아니면 B가 대화 표의 ACCESS EXCLUSIVE를 쥔 채 메시지 표를 기다리고(여기서 'waiting'), A의 다음 문장과 순환 대기가 된다
    const early = await Promise.race([migration, new Promise<"waiting">((resolve) => setTimeout(() => resolve("waiting"), 1500))]);
    expect(early).toEqual({ ok: false, code: "55P03" });
    await b.query("rollback");

    // A가 이어서 대화를 잠그고 답을 쓴다: 막히지 않고 성공 (교착 40P01 없음)
    const finished = await a.query<{ status: string }>(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [user, sent.message_id, JSON.stringify({ reply: { text: "답" } })]);
    expect(finished.rows[0].status).toBe("written");
    await a.query("commit");
    expect(await f.count(`select 1 from public.conversation_messages where conversation_id = $1`, [conversation])).toBe(2);
  });

  it("경합이 없으면 같은 잠금문이 바로 잡힌다 (NOWAIT이 정상 적용을 막지 않는다)", async () => {
    await b.query("begin");
    await b.query("set local lock_timeout = '5s'");
    await b.query(lockStatement());
    await b.query("rollback");
  });
});
