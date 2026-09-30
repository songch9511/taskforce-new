import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 연결 설정을 DB 안에서 한 번에 고치기 (20261017000000_connection_settings_atomic): 바꿀 것만 넘기고 지금 값에 합친다.
// 전에는 서버가 설정 전체를 읽고 통째로 다시 써서, 다시 연결한 범위 · 계정이나 통계 한 번분이 늦게 쓴 쪽에 덮였다 (FEATURE_MAP 3-3).

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const NOW = "2026-10-05T12:00:00.000Z";

let db: PGlite;

async function connection(userId: string, settings: unknown, provider = "google"): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.connections (user_id, provider, external_account_id, settings) values ($1, $2, gen_random_uuid()::text, $3) returning id`,
    [userId, provider, JSON.stringify(settings)],
  );
  return rows[0].id;
}

const settingsOf = async (id: string) =>
  (await db.query<{ settings: Record<string, unknown> }>(`select settings from public.connections where id = $1`, [id])).rows[0].settings;

const merge = async (
  userId: string,
  id: string,
  patch: { set?: object; remove?: string[]; dataSources?: object } = {},
): Promise<boolean> =>
  (
    await db.query<{ ok: boolean }>(`select public.merge_connection_settings($1, $2, $3, $4, $5) as ok`, [
      userId,
      id,
      JSON.stringify(patch.set ?? {}),
      patch.remove ?? [],
      JSON.stringify(patch.dataSources ?? {}),
    ])
  ).rows[0].ok;

const addStats = async (userId: string, id: string, counts: unknown, now = NOW): Promise<boolean> =>
  (await db.query<{ ok: boolean }>(`select public.add_connection_stats($1, $2, $3, $4) as ok`, [userId, id, JSON.stringify(counts), now])).rows[0].ok;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("merge_connection_settings", () => {
  it("넘긴 키만 바꾸고 나머지(통계 등)는 그대로 둔다", async () => {
    const stats = { since: "2026-09-01T00:00:00.000Z", counts: { meet_transcripts: 4 } };
    const id = await connection(ALICE, { googleUserId: "old-sub", email: "old@x.dev", scopes: ["openid"], stats });

    expect(await merge(ALICE, id, { set: { googleUserId: "new-sub", email: "me@company.dev", scopes: ["openid", "email"] } })).toBe(true);
    expect(await settingsOf(id)).toEqual({ googleUserId: "new-sub", email: "me@company.dev", scopes: ["openid", "email"], stats });
  });

  it("키를 뺀다 (다시 연결하면 남겨 둔 notionUserId를 지운다). 없는 키를 빼도 괜찮다", async () => {
    const id = await connection(ALICE, { notionUserId: "notion-old", dataSources: { ds1: { role: "text", title: "회의록" } } }, "notion");

    expect(await merge(ALICE, id, { remove: ["notionUserId"] })).toBe(true);
    expect(await settingsOf(id)).toEqual({ dataSources: { ds1: { role: "text", title: "회의록" } } });
    expect(await merge(ALICE, id, { remove: ["notionUserId"] })).toBe(true);
    expect(await settingsOf(id)).toEqual({ dataSources: { ds1: { role: "text", title: "회의록" } } });
  });

  it("Notion DB 설정은 넘긴 DB만 통째로 바꾸고 다른 DB 설정 · 다른 키는 그대로 둔다", async () => {
    const id = await connection(
      ALICE,
      {
        notionUserId: "notion-me",
        health: { unreachable: [], checkedAt: "2026-09-27T00:00:00Z" },
        dataSources: {
          ds1: { role: "tasks", title: "Tasks", confirmedAt: "2026-09-20T00:00:00Z", backfilledAt: "2026-09-20T00:00:00Z" },
          ds2: { role: "text", title: "회의록", confirmedAt: "2026-09-21T00:00:00Z" },
        },
      },
      "notion",
    );

    const health = { unreachable: [{ id: "ds9", title: null }], checkedAt: "2026-09-28T00:00:00Z" };
    await merge(ALICE, id, { set: { health }, dataSources: { ds1: { role: "ignore", title: "Tasks", confirmedAt: "2026-09-28T00:00:00Z" }, ds3: { role: "text", title: "New", seenAt: "x" } } });
    expect(await settingsOf(id)).toEqual({
      notionUserId: "notion-me",
      health,
      dataSources: {
        ds1: { role: "ignore", title: "Tasks", confirmedAt: "2026-09-28T00:00:00Z" },
        ds2: { role: "text", title: "회의록", confirmedAt: "2026-09-21T00:00:00Z" },
        ds3: { role: "text", title: "New", seenAt: "x" },
      },
    });
  });

  it("설정 · dataSources가 비었거나 객체가 아니면 빈 객체에서 시작한다", async () => {
    const empty = await connection(ALICE, {}, "notion");
    await merge(ALICE, empty, { dataSources: { ds1: { role: "text", title: null } } });
    expect(await settingsOf(empty)).toEqual({ dataSources: { ds1: { role: "text", title: null } } });

    const broken = await connection(ALICE, { dataSources: "broken", other: 1 }, "notion");
    await merge(ALICE, broken, { dataSources: { ds1: { role: "text", title: null } } });
    expect(await settingsOf(broken)).toEqual({ dataSources: { ds1: { role: "text", title: null } }, other: 1 });

    const array = await connection(ALICE, ["x"]);
    await merge(ALICE, array, { set: { scopes: [] } });
    expect(await settingsOf(array)).toEqual({ scopes: [] });
  });

  it("다른 사용자의 연결은 고치지 않는다 (false)", async () => {
    const id = await connection(ALICE, { scopes: ["openid"] });
    expect(await merge(BOB, id, { set: { scopes: [] }, remove: ["scopes"] })).toBe(false);
    expect(await merge(ALICE, "00000000-0000-0000-0000-0000000000ff", { set: { scopes: [] } })).toBe(false);
    expect(await settingsOf(id)).toEqual({ scopes: ["openid"] });
  });

  it("잘못된 인자는 오류: 객체가 아닌 값, dataSources를 두 길로 함께 바꾸기", async () => {
    const id = await connection(ALICE, {}, "notion");
    await expect(db.query(`select public.merge_connection_settings($1, $2, '[1]'::jsonb)`, [ALICE, id])).rejects.toThrow(/잘못된 인자/);
    await expect(merge(ALICE, id, { set: { dataSources: {} }, dataSources: { ds1: {} } })).rejects.toThrow(/함께 바꿀 수 없음/);
    await expect(merge(ALICE, id, { remove: ["dataSources"], dataSources: { ds1: {} } })).rejects.toThrow(/함께 바꿀 수 없음/);
  });
});

describe("add_connection_stats", () => {
  it("처음이면 p_now부터 세고, 두 번 더하면 개수가 합쳐지며 since는 그대로다", async () => {
    const id = await connection(ALICE, { googleUserId: "sub", email: "me@x.dev", scopes: ["openid"] });

    expect(await addStats(ALICE, id, { inbound: 2, category: 1 })).toBe(true);
    expect(await settingsOf(id)).toEqual({ googleUserId: "sub", email: "me@x.dev", scopes: ["openid"], stats: { since: NOW, counts: { inbound: 2, category: 1 } } });

    expect(await addStats(ALICE, id, { inbound: 3, sent: 1 }, "2026-10-06T00:00:00.000Z")).toBe(true);
    expect((await settingsOf(id)).stats).toEqual({ since: NOW, counts: { inbound: 5, category: 1, sent: 1 } });
  });

  it("다시 연결(계정 · 범위)과 통계 기록은 어느 순서로 겹쳐도 둘 다 남는다", async () => {
    const id = await connection(ALICE, { googleUserId: "sub", email: "me@x.dev", scopes: ["openid"] });

    await addStats(ALICE, id, { meet_transcripts: 1 });
    await merge(ALICE, id, { set: { googleUserId: "sub", email: "me@x.dev", scopes: ["openid", "calendar"] } });
    await addStats(ALICE, id, { notion_link_attached: 2 });
    expect(await settingsOf(id)).toEqual({
      googleUserId: "sub",
      email: "me@x.dev",
      scopes: ["openid", "calendar"],
      stats: { since: NOW, counts: { meet_transcripts: 1, notion_link_attached: 2 } },
    });
  });

  it("0 · 음수 · 숫자가 아닌 값은 더하지 않고, 더할 것이 없으면 쓰지 않는다 (false)", async () => {
    const stats = { since: "2026-09-01T00:00:00.000Z", counts: { inbound: 1 } };
    const id = await connection(ALICE, { stats });

    expect(await addStats(ALICE, id, { inbound: 0, bulk: -1, sent: "3", no_reply: null })).toBe(false);
    expect(await addStats(ALICE, id, {})).toBe(false);
    expect(await settingsOf(id)).toEqual({ stats });

    expect(await addStats(ALICE, id, { inbound: 0, sent: 2, bulk: "x" })).toBe(true);
    expect((await settingsOf(id)).stats).toEqual({ since: "2026-09-01T00:00:00.000Z", counts: { inbound: 1, sent: 2 } });
  });

  it("저장된 통계 모양이 다르면(형 변환 오류 없이) 새로 센다", async () => {
    for (const broken of [
      "broken",
      { since: 1, counts: { inbound: 1 } },
      { since: "2026-09-01T00:00:00.000Z", counts: [1] },
      { since: "2026-09-01T00:00:00.000Z", counts: { inbound: "7", sent: 1 } },
      { counts: { inbound: 1 } },
    ]) {
      const id = await connection(ALICE, { email: "me@x.dev", stats: broken });
      expect(await addStats(ALICE, id, { inbound: 1 })).toBe(true);
      expect(await settingsOf(id)).toEqual({ email: "me@x.dev", stats: { since: NOW, counts: { inbound: 1 } } });
    }
  });

  it("통계 안의 다른 키는 남기지 않는다 ({ since, counts }만)", async () => {
    const id = await connection(ALICE, { stats: { since: "2026-09-01T00:00:00.000Z", counts: { inbound: 1 }, extra: true } });
    await addStats(ALICE, id, { inbound: 1 });
    expect(await settingsOf(id)).toEqual({ stats: { since: "2026-09-01T00:00:00.000Z", counts: { inbound: 2 } } });
  });

  it("다른 사용자의 연결 · 없는 연결에는 더하지 않는다 (false)", async () => {
    const id = await connection(ALICE, {});
    expect(await addStats(BOB, id, { inbound: 1 })).toBe(false);
    expect(await addStats(ALICE, "00000000-0000-0000-0000-0000000000ff", { inbound: 1 })).toBe(false);
    expect(await settingsOf(id)).toEqual({});
  });

  it("잘못된 인자는 오류: 객체가 아닌 개수, 시각 없음", async () => {
    const id = await connection(ALICE, {});
    await expect(addStats(ALICE, id, [1])).rejects.toThrow(/잘못된 인자/);
    await expect(db.query(`select public.add_connection_stats($1, $2, '{"inbound":1}'::jsonb, null)`, [ALICE, id])).rejects.toThrow(/잘못된 인자/);
  });
});

describe("권한: 서버(service role)만 부른다", () => {
  it("로그인한 사용자(authenticated)는 자기 연결이어도 부를 수 없다", async () => {
    const id = await connection(ALICE, { scopes: ["openid"] });
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.merge_connection_settings($1, $2, '{"scopes":[]}'::jsonb)`, [ALICE, id])).rejects.toThrow(/permission denied/);
      await expect(db.query(`select public.add_connection_stats($1, $2, '{"inbound":1}'::jsonb, now())`, [ALICE, id])).rejects.toThrow(/permission denied/);
    });
    expect(await settingsOf(id)).toEqual({ scopes: ["openid"] });
  });

  it("anon도 부를 수 없다", async () => {
    const id = await connection(ALICE, { scopes: ["openid"] });
    await db.query("set role anon");
    try {
      await expect(db.query(`select public.merge_connection_settings($1, $2, '{"scopes":[]}'::jsonb)`, [ALICE, id])).rejects.toThrow(/permission denied/);
      await expect(db.query(`select public.add_connection_stats($1, $2, '{"inbound":1}'::jsonb, now())`, [ALICE, id])).rejects.toThrow(/permission denied/);
    } finally {
      await db.query("reset role");
    }
    expect(await settingsOf(id)).toEqual({ scopes: ["openid"] });
  });

  it("service role은 부를 수 있다", async () => {
    const id = await connection(ALICE, {});
    await db.query("set role service_role");
    try {
      expect(await merge(ALICE, id, { set: { scopes: ["openid"] } })).toBe(true);
      expect(await addStats(ALICE, id, { inbound: 1 })).toBe(true);
    } finally {
      await db.query("reset role");
    }
    expect(await settingsOf(id)).toEqual({ scopes: ["openid"], stats: { since: NOW, counts: { inbound: 1 } } });
  });
});
