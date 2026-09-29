import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// Slack 원문 넣기 · 연결 끊기(D3) · 대기 데이터 정리 (20261013000000_slack_sync)

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

const blocked = (sql: string, params: unknown[] = []) =>
  db.query(sql, params).then(
    () => false,
    () => true,
  );

async function connect(userId: string, provider: "slack" | "notion", external: string): Promise<string> {
  const id = (
    await db.query<{ id: string }>(
      `insert into public.connections (user_id, provider, external_account_id, connected_at) values ($1, $2, $3, '2026-10-01T00:00:00Z') returning id`,
      [userId, provider, external],
    )
  ).rows[0].id;
  await db.query(`insert into public.connection_secrets (connection_id, sealed_token) values ($1, 'v1.x.y.z')`, [id]);
  return id;
}

async function pending(userId: string, connectionId: string, ts: string, text = "제안서는 월요일에 받아도 괜찮아요") {
  await db.query(
    `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text) values ($1, $2, 'D1', 'im', $3, 'U2', $4)`,
    [userId, connectionId, ts, text],
  );
}

const ingest = (userId: string, connectionId: string, externalId: string, version: string, ts: string[]) =>
  db.query<{ source_id: string; created: boolean }>(`select * from public.slack_ingest_source($1, $2, $3, $4, $5)`, [
    userId,
    connectionId,
    JSON.stringify({
      external_id: externalId,
      external_version: version,
      kind: "message",
      title: "Slack · DM with 김대표",
      raw_text: "[DM · 김대표]\n김대표: 제안서는 월요일에 받아도 괜찮아요",
      occurred_at: "2026-10-07T05:30:00Z",
      external_url: "https://acme.slack.com/archives/D1/p100000100",
      participants: { attendees: [{ name: "김대표" }, { name: "윤지호" }] },
    }),
    ts.map(() => "D1"),
    ts,
  ]);

const markedWith = async (connectionId: string) =>
  Object.fromEntries(
    (
      await db.query<{ ts: string; source_id: string | null }>(`select ts, source_id from public.slack_messages where connection_id = $1 order by ts`, [connectionId])
    ).rows.map((r) => [r.ts, r.source_id]),
  );

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("slack_ingest_source: 원문 저장 + 대기 행 표시를 한 번에", () => {
  it("이번에 읽은 행만 그 원문으로 표시한다 (동기화 도중 온 행은 대기로 남는다)", async () => {
    const connection = await connect(ALICE, "slack", "T1:UA");
    await pending(ALICE, connection, "100.000100");
    await pending(ALICE, connection, "160.000100");
    await pending(ALICE, connection, "220.000100"); // 동기화가 읽은 뒤에 도착
    const { rows } = await ingest(ALICE, connection, "c:D1:100.000100", "160.000100", ["100.000100", "160.000100"]);
    expect(rows[0].created).toBe(true);
    const source = rows[0].source_id;
    expect(await markedWith(connection)).toEqual({ "100.000100": source, "160.000100": source, "220.000100": null });
    const { rows: saved } = await db.query(`select kind, title, external_id, external_version, participants from public.sources where id = $1`, [source]);
    expect(saved[0]).toMatchObject({ kind: "message", external_id: "c:D1:100.000100", external_version: "160.000100", participants: { attendees: [{ name: "김대표" }, { name: "윤지호" }] } });
  });

  it("같은 묶음을 이미 넣었으면(동시 동기화) 넣지도 표시하지도 않는다. 늦게 온 행은 다음 묶음이 된다", async () => {
    const connection = await connect(ALICE, "slack", "T1:UB");
    await pending(ALICE, connection, "100.000100");
    const first = (await ingest(ALICE, connection, "c:D1:100.000100", "100.000100", ["100.000100"])).rows[0];
    await pending(ALICE, connection, "150.000100");
    const again = (await ingest(ALICE, connection, "c:D1:100.000100", "150.000100", ["100.000100", "150.000100"])).rows[0];
    expect(again).toEqual({ source_id: null, created: false });
    expect(await markedWith(connection)).toEqual({ "100.000100": first.source_id, "150.000100": null });
    expect((await db.query(`select 1 from public.sources where connection_id = $1`, [connection])).rows).toHaveLength(1);
  });

  it("읽은 뒤 Slack에서 지운 메시지가 있으면 넣지 않는다 (다음 동기화가 지운 글 없이 다시 묶는다)", async () => {
    const connection = await connect(ALICE, "slack", "T1:UD");
    await pending(ALICE, connection, "100.000100");
    await pending(ALICE, connection, "110.000100", "지울 글");
    await db.query(`update public.slack_messages set text = '', deleted_at = now() where connection_id = $1 and ts = '110.000100'`, [connection]);
    const result = (await ingest(ALICE, connection, "c:D1:100.000100", "110.000100", ["100.000100", "110.000100"])).rows[0];
    expect(result).toEqual({ source_id: null, created: false });
    expect((await db.query(`select 1 from public.sources where connection_id = $1`, [connection])).rows).toHaveLength(0);
    expect(await markedWith(connection)).toEqual({ "100.000100": null, "110.000100": null });
  });

  it("끊긴 연결(revoked)에는 넣지 못한다 (앱 해제 뒤 동기화가 글을 다시 만들지 않게)", async () => {
    const connection = await connect(ALICE, "slack", "T1:UE");
    await pending(ALICE, connection, "100.000100");
    await db.query(`update public.connections set status = 'revoked' where id = $1`, [connection]);
    await expect(ingest(ALICE, connection, "c:D1:100.000100", "100.000100", ["100.000100"])).rejects.toThrow(/revoked/);
  });

  it("남의 연결 · Slack이 아닌 연결에는 넣지 못한다. 앱(authenticated)은 부를 수 없다", async () => {
    const slack = await connect(ALICE, "slack", "T1:UC");
    const notion = await connect(ALICE, "notion", "ws-1");
    await expect(ingest(BOB, slack, "c:D1:1.0", "1.0", [])).rejects.toThrow(/not found/);
    await expect(ingest(ALICE, notion, "c:D1:1.0", "1.0", [])).rejects.toThrow(/not found/);
    await expect(ingest(ALICE, "00000000-0000-0000-0000-0000000000ff", "c:D1:1.0", "1.0", [])).rejects.toThrow(/not found/);
    await asUser(db, ALICE, async () => {
      expect(await blocked(`select * from public.slack_ingest_source($1, $2, '{}'::jsonb, '{}', '{}')`, [ALICE, slack])).toBe(true);
    });
  });
});

describe("disconnect_connection · purge_slack_data: 연결 끊기 (D3)", () => {
  // 원문 하나에서 만든 할 일 + 근거 · Claim · 판정 기록
  async function seedSource(userId: string, connectionId: string, text: string) {
    const source = (
      await db.query<{ id: string }>(
        `insert into public.sources (user_id, kind, title, raw_text, occurred_at, connection_id, external_id, external_version, external_url, participants)
         values ($1, 'message', 'Slack · DM with 김대표', $2, now(), $3, $4, 'v', 'https://acme.slack.com/archives/D1/p1', '{"attendees":[{"name":"김대표"}]}')
         returning id`,
        [userId, text, connectionId, `c:D1:${Math.random()}`],
      )
    ).rows[0].id;
    const action = (
      await db.query<{ id: string }>(`insert into public.actions (user_id, title, due_at) values ($1, '김대표에게 제안서 발송', '2026-10-12T09:00:00Z') returning id`, [userId])
    ).rows[0].id;
    await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '제안서는 월요일에 받아도 괜찮아요', 'updated')`, [
      userId,
      action,
      source,
    ]);
    await db.query(
      `insert into public.claims (user_id, action_id, source_id, field, value, value_text, quote, occurred_at, speaker, speaker_role, certainty, directness, audience, channel)
       values ($1, $2, $3, 'due', '2026-10-12', '월요일', '제안서는 월요일에 받아도 괜찮아요', now(), '김대표', 'counterpart', 'firm', 'first_hand', 'shared', 'message')`,
      [userId, action, source],
    );
    await db.query(
      `insert into public.judge_logs (user_id, source_id, candidate, jev_answers, decision, model_version) values ($1, $2, '{"quote":"제안서는 월요일에"}', '{}', 'auto', 'jev@judge-v5')`,
      [userId, source],
    );
    return { source, action };
  }

  const snapshot = async (source: string, action: string) => ({
    source: (
      await db.query<Record<string, unknown>>(
        `select raw_text, title, participants, raw_text_purge_reason, raw_text_purged_at is not null as purged, external_url, connection_id is not null as linked from public.sources where id = $1`,
        [source],
      )
    ).rows[0],
    action: (await db.query(`select title, due_at, status from public.actions where id = $1`, [action])).rows[0],
    evidence: (await db.query(`select quote from public.evidence where source_id = $1`, [source])).rows,
    claims: (await db.query(`select quote, value, value_text, speaker, speaker_role from public.claims where source_id = $1`, [source])).rows,
    judgeLogs: (await db.query(`select 1 from public.judge_logs where source_id = $1`, [source])).rows.length,
  });

  it("Slack: 글자(본문 · 관련자 · 인용 · Claim 글자 · 판정 기록 · 대기 데이터)를 지우고 할 일 · 판정 값은 남긴 뒤 연결을 지운다", async () => {
    const connection = await connect(ALICE, "slack", "T2:UA");
    const { source, action } = await seedSource(ALICE, connection, "[DM · 김대표]\n김대표: 제안서는 월요일에 받아도 괜찮아요");
    await pending(ALICE, connection, "1.000100");
    await db.query(`insert into public.slack_threads (connection_id, user_id, channel_id, thread_ts) values ($1, $2, 'C1', '1.0')`, [connection, ALICE]);
    await db.query(`insert into public.slack_people (connection_id, user_id, slack_id, kind, name) values ($1, $2, 'U2', 'user', '김대표')`, [connection, ALICE]);
    const before = await snapshot(source, action);

    const { rows } = await db.query<{ ok: boolean }>(`select public.disconnect_connection($1, $2) as ok`, [ALICE, connection]);
    expect(rows[0].ok).toBe(true);

    const after = await snapshot(source, action);
    expect(after.source).toEqual({
      raw_text: "",
      title: "Slack",
      participants: null,
      raw_text_purge_reason: "disconnected",
      purged: true,
      external_url: "https://acme.slack.com/archives/D1/p1",
      linked: false, // 연결 행을 지워 connection_id는 비었다 (on delete set null)
    });
    expect(after.action).toEqual(before.action);
    expect(after.evidence).toEqual([{ quote: "Slack 연결을 끊어 지웠어요" }]);
    expect(after.claims).toEqual([{ quote: "", value: "2026-10-12", value_text: null, speaker: null, speaker_role: "counterpart" }]);
    expect(after.judgeLogs).toBe(0);
    for (const table of ["slack_messages", "slack_threads", "slack_people", "connection_secrets"]) {
      expect((await db.query(`select 1 from public.${table} where connection_id = $1`, [connection])).rows, table).toHaveLength(0);
    }
    expect((await db.query(`select 1 from public.connections where id = $1`, [connection])).rows).toHaveLength(0);
  });

  it("Notion 연결을 끊으면 원문 · 인용은 남는다. 다른 Slack 연결의 원문은 건드리지 않는다", async () => {
    const notion = await connect(ALICE, "notion", "ws-2");
    const other = await connect(ALICE, "slack", "T2:UB");
    const fromNotion = await seedSource(ALICE, notion, "회의록: 금요일까지 제안서");
    const fromOther = await seedSource(ALICE, other, "[DM · 김대표]\n김대표: 다른 워크스페이스");
    const notionBefore = await snapshot(fromNotion.source, fromNotion.action);
    const otherBefore = await snapshot(fromOther.source, fromOther.action);

    await db.query(`select public.disconnect_connection($1, $2)`, [ALICE, notion]);
    expect(await snapshot(fromNotion.source, fromNotion.action)).toEqual({ ...notionBefore, source: { ...notionBefore.source, linked: false } });
    expect(await snapshot(fromOther.source, fromOther.action)).toEqual(otherBefore);
  });

  it("남의 연결은 끊지 못한다(false). 앱은 연결을 직접 지울 수도, 함수를 부를 수도 없다", async () => {
    const connection = await connect(ALICE, "slack", "T2:UC");
    expect((await db.query<{ ok: boolean }>(`select public.disconnect_connection($1, $2) as ok`, [BOB, connection])).rows[0].ok).toBe(false);
    await asUser(db, ALICE, async () => {
      const deleted = await db.query(`delete from public.connections where id = $1 returning id`, [connection]);
      expect(deleted.rows).toHaveLength(0);
      for (const fn of [
        `select public.disconnect_connection('${ALICE}', '${connection}')`,
        `select public.purge_slack_data(array['${connection}']::uuid[])`,
        `select public.purge_slack_sources(array['${connection}']::uuid[])`,
        `select public.slack_repurge_if_disconnected('${ALICE}', '${connection}')`,
        `select * from public.purge_slack_buffers(now(), now())`,
      ]) {
        expect(await blocked(fn), fn).toBe(true);
      }
    });
    expect((await db.query(`select 1 from public.connections where id = $1`, [connection])).rows).toHaveLength(1);
  });

  it("처리 도중에 끊겼으면, 처리가 그 뒤에 쓴 인용 · Claim 글자 · 판정 기록도 지운다 (slack_repurge_if_disconnected)", async () => {
    const connection = await connect(ALICE, "slack", "T2:UD");
    const { source, action } = await seedSource(ALICE, connection, "[DM · 김대표]\n김대표: 제안서는 월요일에 받아도 괜찮아요");
    await db.query(`select public.disconnect_connection($1, $2)`, [ALICE, connection]);
    // 끊은 뒤에 끝난 처리가 새로 쓴 것
    await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '월요일에 받아도 괜찮아요', 'updated')`, [ALICE, action, source]);
    await db.query(
      `insert into public.judge_logs (user_id, source_id, candidate, jev_answers, decision, model_version) values ($1, $2, '{"quote":"월요일"}', '{}', 'auto', 'x')`,
      [ALICE, source],
    );
    const repurged = await db.query<{ done: boolean }>(`select public.slack_repurge_if_disconnected($1, $2) as done`, [ALICE, source]);
    expect(repurged.rows[0].done).toBe(true);
    const after = await snapshot(source, action);
    expect(after.evidence).toEqual([{ quote: "Slack 연결을 끊어 지웠어요" }, { quote: "Slack 연결을 끊어 지웠어요" }]);
    expect(after.judgeLogs).toBe(0);

    // 끊지 않은 원문은 건드리지 않는다
    const live = await connect(ALICE, "slack", "T2:UE");
    const kept = await seedSource(ALICE, live, "[DM · 김대표]\n김대표: 그대로");
    expect((await db.query<{ done: boolean }>(`select public.slack_repurge_if_disconnected($1, $2) as done`, [ALICE, kept.source])).rows[0].done).toBe(false);
    expect((await snapshot(kept.source, kept.action)).judgeLogs).toBe(1);
  });

  it("Slack에서 앱을 지워도(revoke_slack_connections) 같은 글자를 지우고, 연결 행은 revoked로 남긴다", async () => {
    const connection = await connect(ALICE, "slack", "T3:UA");
    const { source, action } = await seedSource(ALICE, connection, "[DM · 김대표]\n김대표: 제안서는 월요일에 받아도 괜찮아요");
    await db.query(`select public.revoke_slack_connections('T3', null, '2026-10-05T00:00:00Z')`);
    const after = await snapshot(source, action);
    expect(after.source).toMatchObject({ raw_text: "", title: "Slack", participants: null, raw_text_purge_reason: "disconnected", linked: true });
    expect(after.evidence).toEqual([{ quote: "Slack 연결을 끊어 지웠어요" }]);
    expect(after.judgeLogs).toBe(0);
    expect((await db.query(`select status from public.connections where id = $1`, [connection])).rows).toEqual([{ status: "revoked" }]);
  });
});

describe("purge_slack_buffers: 대기 메시지 3일 · 추적 스레드 14일", () => {
  it("기준보다 오래된 대기 행(넣은 행 · 못 넣은 행 · 지움 표시)과 활동이 끊긴 스레드만 지운다", async () => {
    const connection = await connect(BOB, "slack", "T4:UA");
    // 다른 테스트의 대기 행(방금 받음)은 기준보다 새것이라 남는다
    for (const [ts, daysAgo] of [
      ["1.0", 5],
      ["2.0", 5],
      ["3.0", 1],
    ] as const) {
      await db.query(
        `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text, received_at, deleted_at)
         values ($1, $2, 'D1', 'im', $3, 'U2', 'x', now() - make_interval(days => $4), case when $3 = '2.0' then now() end)`,
        [BOB, connection, ts, daysAgo],
      );
    }
    await db.query(
      `insert into public.slack_threads (connection_id, user_id, channel_id, thread_ts, last_activity_at)
       values ($1, $2, 'C1', 'old', now() - interval '20 days'), ($1, $2, 'C1', 'new', now() - interval '1 day')`,
      [connection, BOB],
    );
    const { rows } = await db.query<{ messages_deleted: number; threads_deleted: number; sources_repurged: number }>(
      `select * from public.purge_slack_buffers(now() - interval '3 days', now() - interval '14 days')`,
    );
    expect(rows[0]).toMatchObject({ messages_deleted: 2, threads_deleted: 1 });
    expect((await db.query(`select ts from public.slack_messages where connection_id = $1`, [connection])).rows).toEqual([{ ts: "3.0" }]);
    expect((await db.query(`select thread_ts from public.slack_threads where connection_id = $1`, [connection])).rows).toEqual([{ thread_ts: "new" }]);
  });

  it("안전망: 연결을 끊어 지운 원문에 글자가 남아 있으면 다시 지운다", async () => {
    const source = (
      await db.query<{ id: string }>(
        `insert into public.sources (user_id, kind, title, raw_text, occurred_at, raw_text_purged_at, raw_text_purge_reason) values ($1, 'message', 'Slack', '', now(), now(), 'disconnected') returning id`,
        [BOB],
      )
    ).rows[0].id;
    const action = (await db.query<{ id: string }>(`insert into public.actions (user_id, title) values ($1, '견적서 발송') returning id`, [BOB])).rows[0].id;
    await db.query(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '남은 Slack 글', 'created')`, [BOB, action, source]);
    const { rows } = await db.query<{ sources_repurged: number }>(`select * from public.purge_slack_buffers(now() - interval '3 days', now() - interval '14 days')`);
    expect(rows[0].sources_repurged).toBe(1);
    expect((await db.query(`select quote from public.evidence where source_id = $1`, [source])).rows).toEqual([{ quote: "Slack 연결을 끊어 지웠어요" }]);
    expect((await db.query<{ sources_repurged: number }>(`select * from public.purge_slack_buffers(now() - interval '3 days', now() - interval '14 days')`)).rows[0].sources_repurged).toBe(0);
  });
});
