import { randomUUID } from "node:crypto";

import pg from "pg";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { MAX_LIVE_EXTERNAL_TASKS } from "../../src/lib/execution/limits";
import { confirmProposal, planConfirmation } from "../../src/lib/conversation/store";
import { supabaseSchemaScripts } from "../db/local-supabase";
import { bodyEqualityTests, organizeCardFixtures, organizeCardTests, organizeMoveTests } from "../db/issue-organize.scenarios";

// 서버 코드(src/lib/context/member-writes.ts)를 실제 SQL로 부르는 시나리오가 있다
vi.mock("server-only", () => ({}));

// 0.2.0 OA D4c-2 · D4c-3b (20261125000000_issue_organize) — 실제 Postgres. PGlite와 같은 시나리오 + 연결 둘이 겹치는 경합.
// DATABASE_URL의 서버에 일회용 데이터베이스를 만들어 마이그레이션을 그대로 적용하고, 끝나면 지운다. DATABASE_URL이 없으면 건너뛰지 않고 실패한다.

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  throw new Error(
    "npm run test:pg는 DATABASE_URL(실제 Postgres)이 필요합니다. 로컬: " +
      "docker run --rm -d --name taskforce-pg -p 54329:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17 && " +
      "DATABASE_URL=postgres://postgres:postgres@localhost:54329/postgres npm run test:pg",
  );
}

const DB_NAME = `taskforce_organize_${process.pid}_${Date.now()}`;

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

describe("이슈 정리 (실제 Postgres)", () => {
  bodyEqualityTests();
  organizeMoveTests(db);
  organizeCardTests(db);
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

const finish = (client: pg.Client, userId: string, messageId: string, turn: Record<string, unknown>) =>
  client.query(`select * from public.conversation_finish_turn($1, $2, $3::jsonb)`, [userId, messageId, JSON.stringify(turn)]).then((r) => r.rows[0] as { status: string; reply_id: string | null });
const menuMove = (client: pg.Client, userId: string, actionId: string, addContext: string, addVersion: number) =>
  client
    .query(`select * from public.change_context_membership_with_metric($1, $2, $3, $4, null, null, 'menu')`, [userId, actionId, addContext, addVersion])
    .then((r) => r.rows[0] as { status: string; added_changed: boolean });

describe("이슈 정리 경합 (실제 Postgres, 연결 둘)", () => {
  const f = organizeCardFixtures(db);

  it("P3 말로 이동 ↔ 메뉴 이동(같은 Action · 같은 범위 · 같은 version) 동시: (사용자 × Action) advisory 잠금으로 한 줄로 서고, 먼저 쓴 쪽만 이기고 다른 쪽은 conflict, 지표는 한 줄", async () => {
    const w = await f.world();
    const seen = await f.version(w.b);
    const move = { action_id: w.issue.id, add: { context_id: w.b, expected_version: seen }, remove: null };

    await a.query("begin");
    const talk = await finish(a, w.user, w.message, f.moveTurn([move]));
    const menu = menuMove(b, w.user, w.issue.id, w.b, seen);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(talk.status).toBe("written");
    expect(await menu).toMatchObject({ status: "conflict", added_changed: false });
    expect(await f.moved(w.user)).toEqual([{ action_id: w.issue.id, props: { via: "talk", from_context: null, to_context: w.b } }]);
    expect((await f.current(w.issue.id)).map((m) => m.context_id).sort()).toEqual([w.a, w.b].sort());

    // 반대 순서: 메뉴가 먼저 쓰면 말로 이동 한 턴이 conflict로 끝나고 답 · 지표가 늘지 않는다
    const second = await f.world();
    const v = await f.version(second.b);
    const turnMove = { action_id: second.issue.id, add: { context_id: second.b, expected_version: v }, remove: null };
    await a.query("begin");
    expect((await menuMove(a, second.user, second.issue.id, second.b, v)).status).toBe("ok");
    const late = finish(b, second.user, second.message, f.moveTurn([turnMove]));
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await late).status).toBe("conflict");
    expect(await f.moved(second.user)).toEqual([{ action_id: second.issue.id, props: { via: "menu", from_context: null, to_context: second.b } }]);
    expect(await f.q(`select 1 from public.conversation_messages where reply_to = $1`, [second.message])).toEqual([]);
  });

  // ───────────────────────── 카드 확인의 경합 (P1–P6) ─────────────────────────
  const confirmSql = (client: pg.Client, userId: string, conversationId: string, proposalId: string, plan: Record<string, unknown>) =>
    client
      .query(`select * from public.conversation_confirm_proposal($1, $2, $3, $4::jsonb)`, [userId, conversationId, proposalId, JSON.stringify(plan)])
      .then((r) => r.rows[0] as { status: string; event_id: string | null; card_id: string | null });
  const planOf = async (userId: string, conversationId: string, proposalId: string) => (await planConfirmation(f.admin(), userId, conversationId, proposalId))!.plan;
  const status = async (id: string) => (await f.one(`select status, version from public.actions where id = $1`, [id])) as { status: string; version: number };
  const userClaims = (id: string) => f.count(`select 1 from public.claims where action_id = $1 and origin = 'user' and field = 'status' and value = 'dropped'`, [id]);

  it("P1 같은 카드 확인 둘 동시: 쓰기는 한 번, 다른 하나는 already (같은 기록 줄 id). Claim · 이벤트 한 번씩", async () => {
    const user = await f.user();
    const conversation = await f.conversationWith(user);
    const issue = await f.realIssue(user);
    const card = await f.card(user, conversation, "delete", [issue.id]);
    const plan = await planOf(user, conversation, card.proposalId);
    await a.query("begin");
    const first = await confirmSql(a, user, conversation, card.proposalId, plan);
    const second = confirmSql(b, user, conversation, card.proposalId, plan);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(first.status).toBe("confirmed");
    expect(await second).toMatchObject({ status: "already", event_id: first.event_id });
    expect(await userClaims(issue.id)).toBe(1);
    expect(await f.count(`select 1 from public.action_events where action_id = $1 and type = 'user_deleted'`, [issue.id])).toBe(1);
    expect(await f.eventRows(conversation)).toHaveLength(1);
  });

  it("P2 확인 ↔ 같은 이슈의 v1 PATCH(write_action) 동시: 하나만 이긴다. 확인이 먼저면 PATCH가 false, PATCH가 먼저면 확인은 changed(쓰기 0) → 다시 읽으면 superseded + 새 카드", async () => {
    const user = await f.user();
    const conversation = await f.conversationWith(user);
    const issue = await f.realIssue(user, "수정할 이슈");
    const patch = (client: pg.Client, version: number) =>
      client
        .query(`select public.write_action($1, id, $2, to_jsonb(actions) || '{"title": "고침"}'::jsonb, '[]', '[]', '[]') as written from public.actions where id = $3`, [user, version, issue.id])
        .then((r) => r.rows[0].written as boolean);

    // 확인이 먼저
    const card = await f.card(user, conversation, "delete", [issue.id]);
    const plan = await planOf(user, conversation, card.proposalId);
    const version = (await status(issue.id)).version;
    await a.query("begin");
    expect((await confirmSql(a, user, conversation, card.proposalId, plan)).status).toBe("confirmed");
    const lost = patch(b, version);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await lost).toBe(false);
    expect((await f.one(`select title, status from public.actions where id = $1`, [issue.id]))).toMatchObject({ title: "수정할 이슈", status: "dropped" });

    // PATCH가 먼저 (다른 이슈)
    const other = await f.realIssue(user, "수정할 이슈 2");
    const second = await f.card(user, conversation, "delete", [other.id]);
    const stale = await planOf(user, conversation, second.proposalId);
    const v2 = (await status(other.id)).version;
    await a.query("begin");
    expect(await a.query(`select public.write_action($1, id, $2, to_jsonb(actions) || '{"title": "고침"}'::jsonb, '[]', '[]', '[]') as written from public.actions where id = $3`, [user, v2, other.id]).then((r) => r.rows[0].written)).toBe(true);
    const late = confirmSql(b, user, conversation, second.proposalId, stale);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect(await late).toEqual({ status: "changed", event_id: null, card_id: null });
    expect(await status(other.id)).toMatchObject({ status: "open" });
    expect(await userClaims(other.id)).toBe(0);
    // TS가 다시 읽으면: 쓰기 없이 새 카드 (고친 제목 · 새 version)
    const redo = await confirmProposal(f.admin(), user, conversation, second.proposalId);
    expect(redo).toMatchObject({ status: "superseded", cardMessageId: expect.any(String) });
    expect((await f.cards(conversation)).at(-1)!.content).toMatchObject({ proposal: { targets: [{ title: "고침", version: v2 + 1 }] } });
  });

  it("P4 지울 이슈의 대화 run이 진행 중이고 다른 연결이 그 메시지 행을 쥐고 있으면 55P03 → busy (쓰기 0, 교착 0). 풀린 뒤 다시 하면 confirmed", async () => {
    const user = await f.user();
    const bridge = await f.bridge(user);
    const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
    const agentConversation = await f.agentConversation(user, connection);
    const message = String((await f.post(user, agentConversation, randomUUID(), "First turn")).message_id);
    const turn = (await setup.query<{ result: { status: string; action_id: string; run_id: string; agent_task_id: string } }>(
      "select public.start_agent_turn($1, $2, '{}'::uuid[], '{}'::uuid[], 'read_only', $3) as result",
      [user, message, MAX_LIVE_EXTERNAL_TASKS],
    )).rows[0].result;
    expect(turn.status).toBe("started");
    const conversation = await f.conversationWith(user);
    const card = await f.card(user, conversation, "delete", [turn.action_id]);
    const before = await status(turn.action_id);

    await a.query("begin");
    await a.query("select id from public.conversation_messages where id = $1 for update", [message]);
    // SQL 한 번: busy
    const plan = await planOf(user, conversation, card.proposalId);
    expect(await confirmSql(b, user, conversation, card.proposalId, plan)).toEqual({ status: "busy", event_id: null, card_id: null });
    // TS: 두 번 다시 시도해도 같으면 busy
    expect(await confirmProposal(f.admin(), user, conversation, card.proposalId)).toEqual({ status: "busy" });
    expect(await status(turn.action_id)).toEqual(before);
    expect(await userClaims(turn.action_id)).toBe(0);
    expect((await f.one(`select state from public.execution_runs where id = $1`, [turn.run_id])).state).not.toBe("stopped");
    expect((await f.cards(conversation))[0].refs).toMatchObject({ proposal: { state: "open" } });
    await a.query("commit");

    expect(await confirmProposal(f.admin(), user, conversation, card.proposalId)).toMatchObject({ status: "confirmed" });
    expect((await status(turn.action_id)).status).toBe("dropped");
    expect((await f.one(`select state from public.execution_runs where id = $1`, [turn.run_id])).state).toBe("stopped");
  });

  it("P4c 잠금이 곧 풀리면 확인은 다시 시도해 성공한다 (busy를 바로 돌려주지 않는다: 새로 읽어 두 번까지 다시)", async () => {
    const user = await f.user();
    const bridge = await f.bridge(user);
    const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
    const agentConversation = await f.agentConversation(user, connection);
    const message = String((await f.post(user, agentConversation, randomUUID(), "First turn")).message_id);
    const turn = (await setup.query<{ result: { action_id: string } }>(
      "select public.start_agent_turn($1, $2, '{}'::uuid[], '{}'::uuid[], 'read_only', $3) as result",
      [user, message, MAX_LIVE_EXTERNAL_TASKS],
    )).rows[0].result;
    const conversation = await f.conversationWith(user);
    const card = await f.card(user, conversation, "delete", [turn.action_id]);

    await a.query("begin");
    await a.query("select id from public.conversation_messages where id = $1 for update", [message]);
    const confirming = confirmProposal(f.admin(), user, conversation, card.proposalId);
    await new Promise((resolve) => setTimeout(resolve, 100));
    await a.query("commit");
    expect(await confirming).toMatchObject({ status: "confirmed" });
    expect((await status(turn.action_id)).status).toBe("dropped");
  });

  it("P4b 같은 일을 글 채택(finish_turn adopt.kind delete)으로 하면 55P03은 conflict로 끝나고 쓰기 0 (제안은 열린 채), 풀린 뒤 다시 하면 written", async () => {
    const user = await f.user();
    const bridge = await f.bridge(user);
    const connection = await f.agentConnection(user, bridge, { adapter: "agent:codex" });
    const agentConversation = await f.agentConversation(user, connection);
    const message = String((await f.post(user, agentConversation, randomUUID(), "First turn")).message_id);
    const turn = (await setup.query<{ result: { status: string; action_id: string; run_id: string } }>(
      "select public.start_agent_turn($1, $2, '{}'::uuid[], '{}'::uuid[], 'read_only', $3) as result",
      [user, message, MAX_LIVE_EXTERNAL_TASKS],
    )).rows[0].result;
    const conversation = await f.conversationWith(user);
    const card = await f.card(user, conversation, "delete", [turn.action_id]);
    const writes = (await planOf(user, conversation, card.proposalId)).writes;
    const adoptTurn = {
      user: { intent: null, refs: {} },
      reply: { text: "지웠어요", refs: {}, content: null },
      memory: [],
      adopt: { kind: "delete", proposal_message_id: card.messageId, proposal_id: card.proposalId, payload_hash: card.hash, writes },
    };
    const reply = await f.userMessage(user, conversation, "응 지워");
    const before = await status(turn.action_id);

    await a.query("begin");
    await a.query("select id from public.conversation_messages where id = $1 for update", [message]);
    expect((await finish(b, user, reply, adoptTurn)).status).toBe("conflict");
    expect(await status(turn.action_id)).toEqual(before);
    expect(await userClaims(turn.action_id)).toBe(0);
    expect((await f.cards(conversation))[0].refs).toMatchObject({ proposal: { state: "open" } });
    expect((await f.one(`select reply_lease_until from public.conversation_messages where id = $1`, [reply])).reply_lease_until).toBeNull();
    await a.query("commit");

    expect((await finish(b, user, reply, adoptTurn)).status).toBe("written");
    expect((await status(turn.action_id)).status).toBe("dropped");
    expect((await f.cards(conversation))[0].refs).toMatchObject({ proposal: { state: "adopted" } });
  });

  it("P5 #A를 #B에 · #B를 #A에 동시 병합: 하나만 성공하고 다른 하나는 쓰지 않는다 (사슬 · 순환 0, 교착 0)", async () => {
    const user = await f.user();
    const c1 = await f.conversationWith(user);
    const c2 = await f.conversationWith(user);
    const x = await f.realIssue(user, "X");
    const y = await f.realIssue(user, "Y");
    const xIntoY = await f.card(user, c1, "merge", [x.id, y.id]);
    const yIntoX = await f.card(user, c2, "merge", [y.id, x.id]);
    const plan1 = await planOf(user, c1, xIntoY.proposalId);
    const plan2 = await planOf(user, c2, yIntoX.proposalId);
    await a.query("begin");
    expect((await confirmSql(a, user, c1, xIntoY.proposalId, plan1)).status).toBe("confirmed");
    const second = confirmSql(b, user, c2, yIntoX.proposalId, plan2);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await second).status).toBe("changed");
    expect(await status(x.id)).toMatchObject({ status: "dropped" });
    expect(await status(y.id)).toMatchObject({ status: "open" });
    expect(await f.count(`select 1 from public.action_events where user_id = $1 and type = 'user_merged'`, [user])).toBe(1);
    // 다시 읽으면 쓰지 않고, 남는 쪽이 이미 닫혔으니 새 카드도 없다
    expect(await confirmProposal(f.admin(), user, c2, yIntoX.proposalId)).toEqual({ status: "superseded", cardMessageId: null });
    expect(await status(y.id)).toMatchObject({ status: "open" });
  });

  it("P6 확인 ↔ 같은 대화 새 사용자 메시지의 finish_turn 동시: 대화 → 메시지 순서라 교착이 없고 둘 다 끝난다 (양쪽 순서)", async () => {
    const user = await f.user();
    const conversation = await f.conversationWith(user);
    const issue = await f.realIssue(user);
    const card = await f.card(user, conversation, "delete", [issue.id]);
    const plan = await planOf(user, conversation, card.proposalId);
    const message = await f.userMessage(user, conversation, "그건 두고 이건 뭐야?");
    const turn = { user: { intent: null, refs: {} }, reply: { text: "답", refs: {}, content: null }, memory: [], adopt: null };

    await a.query("begin");
    expect((await confirmSql(a, user, conversation, card.proposalId, plan)).status).toBe("confirmed");
    const reply = finish(b, user, message, turn);
    await waitForLockWait(bPid);
    await a.query("commit");
    expect((await reply).status).toBe("written");

    const next = await f.realIssue(user, "다음");
    const second = await f.card(user, conversation, "delete", [next.id]);
    const plan2 = await planOf(user, conversation, second.proposalId);
    const message2 = await f.userMessage(user, conversation, "또 뭐야?");
    await a.query("begin");
    expect((await finish(a, user, message2, turn)).status).toBe("written");
    const confirmed = confirmSql(b, user, conversation, second.proposalId, plan2);
    await waitForLockWait(bPid);
    await a.query("commit");
    // 새 사용자 메시지의 답에는 제안이 없어 앞 카드는 열린 채다
    expect((await confirmed).status).toBe("confirmed");
    expect(await userClaims(next.id)).toBe(1);
  });
});
