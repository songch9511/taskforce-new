import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// Slack 연동 표 (20261011000000_slack): 서버만 읽고 쓰고, 연결 · 계정을 지우면 함께 지워진다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;
let connection: string;

const blocked = (sql: string, params: unknown[] = []) =>
  db.query(sql, params).then(
    () => false,
    () => true,
  );

const insertMessage = (ts: string, extra = "") =>
  db.query(
    `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text${extra ? ", source_id" : ""})
     values ($1, $2, 'D1', 'im', $3, 'U2', '제안서는 월요일에 받아도 괜찮아요'${extra ? ", $4" : ""})`,
    extra ? [ALICE, connection, ts, extra] : [ALICE, connection, ts],
  );

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  connection = (
    await db.query<{ id: string }>(
      `insert into public.connections (user_id, provider, external_account_id, display_name) values ($1, 'slack', 'T1:U1', 'Acme') returning id`,
      [ALICE],
    )
  ).rows[0].id;
}, 60_000);

describe("Slack 표 (20261011000000_slack)", () => {
  it("대기 메시지는 연결 · 채널 · ts마다 하나다 (Slack 재전송이 행을 늘리지 않는다)", async () => {
    await insertMessage("1727678400.000100");
    await expect(insertMessage("1727678400.000100")).rejects.toThrow(/unique|duplicate/);
  });

  it("다른 사용자의 연결에 붙은 행은 만들 수 없다 (복합 외래키)", async () => {
    await expect(
      db.query(
        `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id) values ($1, $2, 'D1', 'im', '9.0', 'U2')`,
        [BOB, connection],
      ),
    ).rejects.toThrow(/foreign key/);
  });

  it("지움 표시가 남은 행은 늦게 온 원래 메시지로 다시 채워지지 않는다", async () => {
    await db.query(
      `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text, deleted_at) values ($1, $2, 'D1', 'im', '8.0', '', '', now())`,
      [ALICE, connection],
    );
    await db.query(
      `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text) values ($1, $2, 'D1', 'im', '8.0', 'U2', '지운 글')
       on conflict (connection_id, channel_id, ts) do nothing`,
      [ALICE, connection],
    );
    const { rows } = await db.query<{ text: string }>(`select text from public.slack_messages where ts = '8.0'`);
    expect(rows).toEqual([{ text: "" }]);
  });

  it("앱(authenticated)은 세 표를 읽지도 쓰지도 못한다", async () => {
    await db.query(
      `insert into public.slack_threads (connection_id, user_id, channel_id, thread_ts) values ($1, $2, 'C1', '1727678400.000200')`,
      [connection, ALICE],
    );
    await db.query(`insert into public.slack_people (connection_id, user_id, slack_id, kind, name) values ($1, $2, 'U2', 'user', '김대표')`, [
      connection,
      ALICE,
    ]);
    await asUser(db, ALICE, async () => {
      for (const table of ["slack_messages", "slack_threads", "slack_people"]) {
        expect(await blocked(`select * from public.${table}`), table).toBe(true);
      }
      expect(
        await blocked(
          `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id) values ($1, $2, 'D1', 'im', '1', 'U2')`,
          [ALICE, connection],
        ),
      ).toBe(true);
      expect(await blocked(`update public.slack_messages set text = 'x'`)).toBe(true);
      expect(await blocked(`delete from public.slack_threads`)).toBe(true);
    });
    await db.query("set role anon");
    try {
      expect(await blocked(`select * from public.slack_messages`)).toBe(true);
    } finally {
      await db.query("reset role");
    }
  });

  it("원문이 지워지면 대기 메시지의 표시가 풀린다 (다시 묶인다)", async () => {
    const source = (
      await db.query<{ id: string }>(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'message', 'x', now()) returning id`, [
        ALICE,
      ])
    ).rows[0].id;
    await insertMessage("1727678400.000300", source);
    await db.query(`delete from public.sources where id = $1`, [source]);
    const { rows } = await db.query<{ source_id: string | null }>(`select source_id from public.slack_messages where ts = '1727678400.000300'`);
    expect(rows).toEqual([{ source_id: null }]);
  });

  it("synthetic bot sender id는 기존 sender_id 칸에 그대로 저장되고 재전송 · 편집에도 유지된다", async () => {
    const ts = "1727678400.000900";
    await db.query(
      `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text)
       values ($1, $2, 'D1', 'im', $3, 'bot:B123', 'Deploy is Friday')
       on conflict (connection_id, channel_id, ts) do nothing`,
      [ALICE, connection, ts],
    );
    await db.query(
      `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text)
       values ($1, $2, 'D1', 'im', $3, 'U2', 'late retry')
       on conflict (connection_id, channel_id, ts) do nothing`,
      [ALICE, connection, ts],
    );
    await db.query(`update public.slack_messages set text = 'Deploy moved to Monday' where connection_id = $1 and channel_id = 'D1' and ts = $2`, [connection, ts]);
    const { rows } = await db.query<{ sender_id: string; text: string }>(`select sender_id, text from public.slack_messages where connection_id = $1 and ts = $2`, [connection, ts]);
    expect(rows).toEqual([{ sender_id: "bot:B123", text: "Deploy moved to Monday" }]);
  });

  it("연결을 지우면 대기 메시지 · 추적 스레드 · 이름 캐시가 함께 지워진다", async () => {
    await db.query(`delete from public.connections where id = $1`, [connection]);
    for (const table of ["slack_messages", "slack_threads", "slack_people"]) {
      expect((await db.query(`select 1 from public.${table}`)).rows, table).toHaveLength(0);
    }
  });
});

describe("connections.connected_at · sources.raw_text_purge_reason", () => {
  it("연결 시각은 기본으로 지금이고, 원문을 지운 이유는 정해진 값만 받는다", async () => {
    const { rows } = await db.query<{ connected_at: Date | null }>(
      `insert into public.connections (user_id, provider, external_account_id) values ($1, 'slack', 'T1:U9') returning connected_at`,
      [ALICE],
    );
    expect(rows[0].connected_at).not.toBeNull();
    await db.query(
      `insert into public.sources (user_id, kind, raw_text, occurred_at, raw_text_purge_reason) values ($1, 'message', '', now(), 'disconnected')`,
      [ALICE],
    );
    await expect(
      db.query(`insert into public.sources (user_id, kind, raw_text, occurred_at, raw_text_purge_reason) values ($1, 'message', '', now(), 'other')`, [ALICE]),
    ).rejects.toThrow(/check/);
  });
});

describe("revoke_slack_connections (20261012000000)", () => {
  const ids: Record<string, string> = {};
  const connect = async (key: string, userId: string, external: string, status = "active", connectedAt = "2026-10-01T00:00:00Z") => {
    ids[key] = (
      await db.query<{ id: string }>(
        `insert into public.connections (user_id, provider, external_account_id, status, connected_at) values ($1, 'slack', $2, $3, $4) returning id`,
        [userId, external, status, connectedAt],
      )
    ).rows[0].id;
    await db.query(`insert into public.connection_secrets (connection_id, sealed_token) values ($1, 'v1.x.y.z')`, [ids[key]]);
    await db.query(
      `insert into public.slack_messages (user_id, connection_id, channel_id, channel_type, ts, sender_id, text) values ($1, $2, 'D1', 'im', '1.0', 'U2', 'x')`,
      [userId, ids[key]],
    );
  };
  const state = async (key: string) => {
    const { rows } = await db.query<{ status: string; secrets: number; messages: number }>(
      `select c.status,
              (select count(*)::int from public.connection_secrets s where s.connection_id = c.id) as secrets,
              (select count(*)::int from public.slack_messages m where m.connection_id = c.id) as messages
       from public.connections c where c.id = $1`,
      [ids[key]],
    );
    return rows[0];
  };

  beforeAll(async () => {
    await connect("aliceT9", ALICE, "T9:UA");
    await connect("bobT9", BOB, "T9:UB", "reauth");
    await connect("bobT9later", BOB, "T9:UC", "active", "2026-10-10T00:00:00Z");
    await connect("aliceT8", ALICE, "T8:UA");
    // 팀 id가 앞부분만 같은 워크스페이스
    await connect("aliceT99", ALICE, "T99:UA");
  });

  it("tokens_revoked: 그 이용자의 연결만 한 번에 끊고 토큰 · 대기 메시지를 지운다", async () => {
    const { rows } = await db.query<{ n: number }>(`select public.revoke_slack_connections('T9', array['UB'], '2026-10-05T00:00:00Z') as n`);
    expect(rows[0].n).toBe(1);
    expect(await state("bobT9")).toEqual({ status: "revoked", secrets: 0, messages: 0 });
    expect(await state("aliceT9")).toEqual({ status: "active", secrets: 1, messages: 1 });
  });

  it("app_uninstalled: 그 워크스페이스 전체를 끊되, 이벤트 뒤에 다시 연결한 것과 다른 워크스페이스는 그대로", async () => {
    const { rows } = await db.query<{ n: number }>(`select public.revoke_slack_connections('T9', null, '2026-10-05T00:00:00Z') as n`);
    expect(rows[0].n).toBe(1);
    expect(await state("aliceT9")).toEqual({ status: "revoked", secrets: 0, messages: 0 });
    expect(await state("bobT9later")).toEqual({ status: "active", secrets: 1, messages: 1 });
    expect(await state("aliceT8")).toEqual({ status: "active", secrets: 1, messages: 1 });
    expect(await state("aliceT99")).toEqual({ status: "active", secrets: 1, messages: 1 });
  });

  it("앱(authenticated)은 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      expect(await blocked(`select public.revoke_slack_connections('T8', null, now())`)).toBe(true);
    });
    expect(await state("aliceT8")).toEqual({ status: "active", secrets: 1, messages: 1 });
  });
});
