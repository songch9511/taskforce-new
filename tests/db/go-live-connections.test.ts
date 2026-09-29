import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

let db: PGlite;

/** 클라이언트가 막혔으면 "blocked", 아니면 바뀐 행 수 */
const attempt = (sql: string, params: unknown[] = []) =>
  db.query(sql, params).then(
    (r) => r.affectedRows ?? 0,
    () => "blocked" as const,
  );

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("연결 (20261003000000_go_live_connections_consent)", () => {
  it("Google · Gmail 연결과 reauth 상태를 받는다", async () => {
    await db.query(
      `insert into public.connections (user_id, provider, external_account_id, status)
       values ($1, 'google', 'g-1', 'active'), ($1, 'gmail', 'g-1', 'reauth')`,
      [ALICE],
    );
    await expect(
      db.query(`insert into public.connections (user_id, provider, external_account_id) values ($1, 'zoom', 'z')`, [ALICE]),
    ).rejects.toThrow(/check/);
    await expect(
      db.query(`insert into public.connections (user_id, provider, external_account_id, status) values ($1, 'notion', 'n', 'paused')`, [ALICE]),
    ).rejects.toThrow(/check/);
  });

  it("앱은 자기 연결의 목록 열을 읽을 수 있다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ provider: string; status: string }>(
        `select id, provider, display_name, status, last_synced_at, last_error, settings from public.connections order by provider`,
      );
      expect(rows.map((r) => [r.provider, r.status])).toEqual([
        ["gmail", "reauth"],
        ["google", "active"],
      ]);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query(`select id from public.connections`)).rows).toHaveLength(0);
    });
  });
});

describe("OAuth nonce (oauth_nonces)", () => {
  beforeAll(async () => {
    await db.query(
      `insert into public.oauth_nonces (nonce, user_id, provider, expires_at) values ('n-alice', $1, 'notion', now() + interval '10 minutes')`,
      [ALICE],
    );
  });

  it("클라이언트는 본인 것도 읽거나 쓸 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select * from public.oauth_nonces`)).rejects.toThrow(/permission denied/);
      expect(
        await attempt(`insert into public.oauth_nonces (nonce, user_id, provider, expires_at) values ('x', $1, 'notion', now())`, [ALICE]),
      ).toBe("blocked");
      expect(await attempt(`delete from public.oauth_nonces`)).toBe("blocked");
    });
  });

  it("같은 nonce는 한 번만 지울 수 있다 (callback의 한 번 쓰기)", async () => {
    const consume = () =>
      db.query(
        `delete from public.oauth_nonces where nonce = 'n-alice' and user_id = $1 and provider = 'notion' and expires_at > now() returning nonce`,
        [ALICE],
      );
    expect((await consume()).rows).toEqual([{ nonce: "n-alice" }]);
    expect((await consume()).rows).toEqual([]);
  });

  it("다른 사용자 · 다른 서비스 · 만료된 nonce는 쓸 수 없다", async () => {
    await db.query(
      `insert into public.oauth_nonces (nonce, user_id, provider, expires_at)
       values ('n-bob', $1, 'notion', now() + interval '10 minutes'), ('n-old', $2, 'notion', now() - interval '1 minute')`,
      [BOB, ALICE],
    );
    const consume = (nonce: string, userId: string, provider: string) =>
      db.query(
        `delete from public.oauth_nonces where nonce = $1 and user_id = $2 and provider = $3 and expires_at > now() returning nonce`,
        [nonce, userId, provider],
      );
    expect((await consume("n-bob", ALICE, "notion")).rows).toEqual([]);
    expect((await consume("n-bob", BOB, "slack")).rows).toEqual([]);
    expect((await consume("n-old", ALICE, "notion")).rows).toEqual([]);
    expect((await consume("n-bob", BOB, "notion")).rows).toEqual([{ nonce: "n-bob" }]);
  });

  it("모르는 서비스의 nonce는 만들 수 없다", async () => {
    await expect(
      db.query(`insert into public.oauth_nonces (nonce, user_id, provider, expires_at) values ('n-x', $1, 'github', now())`, [ALICE]),
    ).rejects.toThrow(/check/);
  });
});

describe("2단계 연동 요청 (connection_requests)", () => {
  // 서버(service role)가 쓰는 방식 그대로: 이미 있으면 아무것도 하지 않는다.
  const request = (userId: string, provider: string) =>
    db.query(`insert into public.connection_requests (user_id, provider) values ($1, $2) on conflict (user_id, provider) do nothing`, [
      userId,
      provider,
    ]);

  it("같은 사용자가 같은 서비스를 다시 요청해도 하나만 남는다", async () => {
    await request(ALICE, "zoom");
    await request(ALICE, "zoom");
    await request(ALICE, "linear");
    await request(BOB, "zoom");
    const { rows } = await db.query<{ provider: string; n: number }>(
      `select provider, count(*)::int as n from public.connection_requests group by provider order by provider`,
    );
    expect(rows).toEqual([
      { provider: "linear", n: 1 },
      { provider: "zoom", n: 2 },
    ]);
  });

  it("2단계 서비스가 아니면 거부한다", async () => {
    await expect(request(ALICE, "notion")).rejects.toThrow(/check/);
  });

  it("본인 요청만 보이고, 클라이언트는 직접 쓸 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ provider: string }>(`select provider from public.connection_requests order by provider`);
      expect(rows.map((r) => r.provider)).toEqual(["linear", "zoom"]);
      expect(await attempt(`insert into public.connection_requests (provider) values ('jira')`)).toBe("blocked");
      expect([0, "blocked"]).toContain(await attempt(`delete from public.connection_requests`));
      expect([0, "blocked"]).toContain(await attempt(`update public.connection_requests set provider = 'jira'`));
    });
    expect((await db.query(`select 1 from public.connection_requests where user_id = $1`, [ALICE])).rows).toHaveLength(2);
  });
});

describe("지표 이벤트 connection_created", () => {
  it("서버는 남길 수 있고, 클라이언트는 남길 수 없다", async () => {
    await db.query(`insert into public.metric_events (user_id, type) values ($1, 'connection_created')`, [ALICE]);
    await asUser(db, ALICE, async () => {
      expect(await attempt(`insert into public.metric_events (type) values ('connection_created')`)).toBe("blocked");
      // 앱이 남기는 app_opened는 그대로 된다
      expect(await attempt(`insert into public.metric_events (type) values ('app_opened')`)).toBe(1);
    });
  });
});

describe("지표 이벤트 reconnect_notified (20261015000000_metric_events_reconnect_notified)", () => {
  it("서버는 남길 수 있고, 클라이언트는 남길 수 없다. 모르는 종류는 여전히 막는다", async () => {
    await db.query(`insert into public.metric_events (user_id, type) values ($1, 'reconnect_notified')`, [ALICE]);
    await expect(db.query(`insert into public.metric_events (user_id, type) values ($1, 'reconnect_sent')`, [ALICE])).rejects.toThrow(/check/);
    await asUser(db, ALICE, async () => {
      expect(await attempt(`insert into public.metric_events (type) values ('reconnect_notified')`)).toBe("blocked");
    });
    // 이전 종류는 그대로 받는다
    await db.query(`insert into public.metric_events (user_id, type) values ($1, 'connection_created')`, [ALICE]);
  });
});

describe("외부 AI 처리 동의 (profiles.ai_consent_at)", () => {
  it("클라이언트는 프로필은 고칠 수 있지만 동의 시각은 쓸 수 없다", async () => {
    await asUser(db, BOB, async () => {
      await db.query(
        `insert into public.profiles (display_name, aliases) values ('밥', '{}')
         on conflict (user_id) do update set display_name = excluded.display_name`,
      );
      expect(await attempt(`update public.profiles set ai_consent_at = now()`)).toBe("blocked");
      expect(await attempt(`insert into public.profiles (user_id, ai_consent_at) values ($1, now())`, [BOB])).toBe("blocked");
      const { rows } = await db.query<{ display_name: string; ai_consent_at: Date | null }>(`select display_name, ai_consent_at from public.profiles`);
      expect(rows).toEqual([{ display_name: "밥", ai_consent_at: null }]);
    });
  });

  it("서버가 동의 · 철회를 쓰고, 사용자는 자기 동의 시각을 읽는다", async () => {
    await db.query(
      `insert into public.profiles (user_id, ai_consent_at) values ($1, now())
       on conflict (user_id) do update set ai_consent_at = excluded.ai_consent_at`,
      [BOB],
    );
    await asUser(db, BOB, async () => {
      const { rows } = await db.query<{ ai_consent_at: Date | null }>(`select ai_consent_at from public.profiles`);
      expect(rows[0].ai_consent_at).toBeInstanceOf(Date);
    });
    await db.query(`update public.profiles set ai_consent_at = null where user_id = $1`, [BOB]);
    expect((await db.query(`select ai_consent_at from public.profiles where user_id = $1`, [BOB])).rows).toEqual([{ ai_consent_at: null }]);
  });
});

describe("OAuth 완료 대기 (oauth_handoffs)", () => {
  // 서버(POST /connections/{provider}/complete)가 쓰는 방식 그대로: id · 로그인한 사용자 · 서비스가 모두 맞고 만료 전이면 지우며 꺼낸다.
  const complete = (id: string, userId: string, provider = "notion") =>
    db.query<{ sealed_code: string }>(
      `delete from public.oauth_handoffs where id = $1 and user_id = $2 and provider = $3 and expires_at > now() returning sealed_code`,
      [id, userId, provider],
    );
  const handoff = (id: string, userId: string, expires = "now() + interval '2 minutes'") =>
    db.query(`insert into public.oauth_handoffs (id, user_id, provider, sealed_code, expires_at) values ($1, $2, 'notion', 'v1.sealed', ${expires})`, [
      id,
      userId,
    ]);
  const id = (label: string) => label.padEnd(43, "x");

  it("공격자가 시작한 연결의 handoff를 다른 사용자가 완료할 수 없고, 남은 handoff도 그대로다", async () => {
    await handoff(id("attacker"), BOB);
    expect((await complete(id("attacker"), ALICE)).rows).toEqual([]);
    // 시작한 사용자 본인만 꺼낼 수 있다
    expect((await complete(id("attacker"), BOB)).rows).toEqual([{ sealed_code: "v1.sealed" }]);
  });

  it("한 번만 쓴다", async () => {
    await handoff(id("once"), ALICE);
    expect((await complete(id("once"), ALICE)).rows).toHaveLength(1);
    expect((await complete(id("once"), ALICE)).rows).toEqual([]);
  });

  it("만료됐거나 다른 서비스면 꺼낼 수 없다", async () => {
    await handoff(id("late"), ALICE, "now() - interval '1 second'");
    await handoff(id("other"), ALICE);
    expect((await complete(id("late"), ALICE)).rows).toEqual([]);
    expect((await complete(id("other"), ALICE, "google")).rows).toEqual([]);
  });

  it("짧은 id는 받지 않는다", async () => {
    await expect(handoff("short", ALICE)).rejects.toThrow(/check/);
  });

  it("클라이언트는 본인 것도 읽거나 쓸 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select * from public.oauth_handoffs`)).rejects.toThrow(/permission denied/);
      expect(
        await attempt(`insert into public.oauth_handoffs (id, user_id, provider, sealed_code, expires_at) values ($1, $2, 'notion', 'x', now())`, [
          id("client"),
          ALICE,
        ]),
      ).toBe("blocked");
      expect(await attempt(`delete from public.oauth_handoffs`)).toBe("blocked");
    });
  });
});

describe("동기화할 연결 (syncable_connections)", () => {
  const CAROL = "00000000-0000-0000-0000-00000000000c";

  beforeAll(async () => {
    await db.query("insert into auth.users (id, email) values ($1, 'carol@example.com')", [CAROL]);
    await db.query(
      `insert into public.connections (user_id, provider, external_account_id, status, last_synced_at)
       values ($1, 'notion', 'c-active', 'active', now() - interval '1 hour'),
              ($1, 'notion', 'c-error', 'error', null),
              ($1, 'notion', 'c-revoked', 'revoked', null),
              ($1, 'notion', 'c-reauth', 'reauth', null),
              ($1, 'slack', 'c-slack', 'active', null)`,
      [CAROL],
    );
  });

  const syncable = (userId: string | null = CAROL) =>
    db.query<{ external_account_id: string }>(
      `select c.external_account_id from public.syncable_connections(array['notion'], $1) s join public.connections c on c.id = s.id`,
      [userId],
    );

  it("동의하지 않은 사용자의 연결은 고르지 않는다", async () => {
    await db.query(`insert into public.profiles (user_id, display_name) values ($1, '캐롤') on conflict (user_id) do nothing`, [CAROL]);
    expect((await syncable()).rows).toEqual([]);
  });

  it("동의하면 active · error 연결을 오래 안 한 순서로 고른다 (revoked · reauth · 다른 서비스는 빼고)", async () => {
    await db.query(`update public.profiles set ai_consent_at = now() where user_id = $1`, [CAROL]);
    expect((await syncable()).rows.map((r) => r.external_account_id)).toEqual(["c-error", "c-active"]);
    // 사용자를 주지 않으면(cron) 동의한 모든 사용자
    expect((await syncable(null)).rows.map((r) => r.external_account_id)).toEqual(["c-error", "c-active"]);
  });

  it("철회하면 다시 빠진다", async () => {
    await db.query(`update public.profiles set ai_consent_at = null where user_id = $1`, [CAROL]);
    expect((await syncable(null)).rows).toEqual([]);
  });

  it("클라이언트는 부를 수 없다", async () => {
    await asUser(db, CAROL, async () => {
      await expect(db.query(`select * from public.syncable_connections(array['notion'])`)).rejects.toThrow(/permission denied/);
    });
  });
});
