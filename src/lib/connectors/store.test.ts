import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import type { DataSourceSetting } from "@/lib/api/contract";
import { processSource } from "@/lib/sources/process";

import { ingestDeps, loadIdentity, recordNotionHealth, recordSync, updateConnectionSettings } from "./store";
import type { Connection, IngestItem } from "./types";

vi.mock("server-only", () => ({}));
// 원문 처리(추출 · 판정 · 병합 · 알림)는 부른 인자만 본다
vi.mock("@/lib/sources/process", () => ({ processSource: vi.fn(async () => ({ needsConfirmation: [] })), processTaskSource: vi.fn() }));

type Query = { eq: () => Query; single: () => Query; throwOnError: () => Promise<unknown> };

/** connections 행 하나의 settings만 읽고 쓰는 가짜 service role 클라이언트 */
function fakeAdmin(stored: Record<string, unknown>) {
  const writes: Record<string, unknown>[] = [];
  const query = (result: () => unknown): Query => {
    const q: Query = { eq: () => q, single: () => q, throwOnError: async () => result() };
    return q;
  };
  const admin = {
    from: () => ({
      select: () => query(() => ({ data: { settings: stored } })),
      update: (values: { settings: Record<string, unknown> }) =>
        query(() => {
          writes.push(values.settings);
          return { data: null };
        }),
    }),
  } as unknown as SupabaseClient;
  return { admin, writes };
}

const connection: Connection = { id: "c1", userId: "u1", provider: "notion", settings: {}, syncCursor: null };
const now = new Date("2026-09-28T00:00:00.000Z");
const auto = (title: string): DataSourceSetting => ({
  role: "tasks",
  title,
  props: { title: "title", assignee: "own", due: null, status: { id: "st", type: "status" } },
  statusMap: { o1: "open", o5: "done" },
  confirmedAt: now.toISOString(),
  confirmedBy: "auto",
});

describe("recordNotionHealth: 자동 확인한 할 일 DB", () => {
  it("남기되, 그 사이 사용자가 확인한 DB(가져오지 않음 등)는 덮지 않는다", async () => {
    const { admin, writes } = fakeAdmin({
      notionUserId: "notion-me",
      dataSources: {
        "ds-a": { role: "tasks", title: "Action", seenAt: "2026-09-20T00:00:00Z" },
        "ds-b": { role: "ignore", title: "Tasks", confirmedAt: "2026-09-27T12:00:00Z" },
      },
    });
    await recordNotionHealth(
      admin,
      connection,
      { seen: [], unreachable: null, notionUserId: "notion-me", autoConfirmed: [{ id: "ds-a", setting: auto("Action") }, { id: "ds-b", setting: auto("Tasks") }] },
      now,
    );
    expect(writes).toHaveLength(1);
    expect(writes[0]).toMatchObject({
      notionUserId: "notion-me",
      dataSources: {
        "ds-a": auto("Action"),
        "ds-b": { role: "ignore", title: "Tasks", confirmedAt: "2026-09-27T12:00:00Z" },
      },
    });
  });

  it("바뀐 것이 없으면 쓰지 않는다 (그 사이 /lab에서 저장한 설정을 덮지 않게)", async () => {
    const { admin, writes } = fakeAdmin({
      notionUserId: "notion-me",
      dataSources: { "ds-b": { role: "text", title: "Tasks", confirmedAt: "2026-09-27T12:00:00Z" } },
      health: { unreachable: [], checkedAt: "2026-09-27T00:00:00Z" },
    });
    // 자동 확인한 DB를 사용자가 이미 확인했고, 처음 본 DB · 연결한 사람 · 공유 상태도 그대로
    await recordNotionHealth(
      admin,
      connection,
      { seen: [], unreachable: [], notionUserId: "notion-me", autoConfirmed: [{ id: "ds-b", setting: auto("Tasks") }] },
      now,
    );
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, autoConfirmed: [] }, now);
    expect(writes).toEqual([]);
  });
});

describe("recordNotionHealth: 자동 확인 다시 보기", () => {
  const earlier = "2026-09-21T00:00:00.000Z";
  const reverted = { role: "tasks" as const, title: "Action Items", seenAt: "2026-09-20T00:00:00Z" };
  const person = (extra: Partial<DataSourceSetting>): DataSourceSetting => ({
    ...auto("Action Items"),
    props: { title: "title", assignee: "per", due: null, status: { id: "st", type: "status" } },
    confirmedAt: earlier,
    backfilledAt: earlier,
    seenAt: "2026-09-20T00:00:00Z",
    ...extra,
  });

  it("되돌린 자동 확인은 다른 변화가 없어도 남긴다 (처음 훑기 표시도 함께 빠진다)", async () => {
    const { admin, writes } = fakeAdmin({ notionUserId: "notion-me", dataSources: { "ds-p": person({}) } });
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "notion-me", autoConfirmed: [], reverted: [{ id: "ds-p", setting: reverted }] }, now);
    expect(writes).toHaveLength(1);
    expect((writes[0].dataSources as Record<string, unknown>)["ds-p"]).toEqual(reverted);
  });

  it("그 사이 사용자가 확인한 DB는 되돌리지 않는다 (담당 속성이 Person이어도)", async () => {
    const { admin, writes } = fakeAdmin({ notionUserId: "notion-me", dataSources: { "ds-p": person({ confirmedBy: undefined }) } });
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "notion-me", reverted: [{ id: "ds-p", setting: reverted }] }, now);
    expect(writes).toEqual([]);
  });

  it("매핑이 바뀌어 다시 자동 확인한 DB는 전의 자동 확인을 덮는다", async () => {
    const { admin, writes } = fakeAdmin({ notionUserId: "notion-me", dataSources: { "ds-a": { ...auto("Action"), confirmedAt: earlier, backfilledAt: earlier } } });
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "notion-me", autoConfirmed: [{ id: "ds-a", setting: auto("Action") }] }, now);
    expect(writes).toHaveLength(1);
    expect((writes[0].dataSources as Record<string, unknown>)["ds-a"]).toEqual(auto("Action"));
  });
});

describe("recordSync: 동기화 결과를 연결 상태로", () => {
  const claimedAt = new Date("2026-09-29T00:00:00.000Z");

  /** update 값과 조건을 기록하는 가짜 service role 클라이언트. matched: 조건에 맞는 행이 있는가 */
  function fakeSyncAdmin(matched = true) {
    const updates: Record<string, unknown>[] = [];
    const conditions: string[] = [];
    const q = {
      eq: () => q,
      neq: (column: string, value: string) => {
        conditions.push(`${column} <> ${value}`);
        return q;
      },
      lte: (column: string, value: string) => {
        conditions.push(`${column} <= ${value}`);
        return q;
      },
      select: () => q,
      throwOnError: async () => ({ data: matched ? [{ id: "c1" }] : [] }),
    };
    const admin = {
      from: () => ({
        update: (values: Record<string, unknown>) => {
          updates.push(values);
          return q;
        },
      }),
    } as unknown as SupabaseClient;
    return { admin, updates, conditions };
  }

  it("갱신 토큰이 거절돼 다시 연결해야 하면 reauth로 남긴다. 끊긴 연결(revoked) · 동기화 뒤에 다시 연결한 연결은 덮지 않는다", async () => {
    const { admin, updates, conditions } = fakeSyncAdmin();
    await recordSync(admin, connection, { claimedAt, error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    expect(updates[0]).toMatchObject({ status: "reauth", last_error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", sync_started_at: null });
    expect(conditions).toEqual(["connected_at <= 2026-09-29T00:00:00.000Z", "status <> revoked"]);
  });

  it("동기화를 시작한 뒤 다시 연결했으면(connected_at이 뒤) 새 연결 상태를 덮지 않고 잠금만 푼다", async () => {
    const { admin, updates } = fakeSyncAdmin(false);
    await recordSync(admin, connection, { claimedAt, error: "Notion 요청 실패 (503)" });
    expect(updates).toHaveLength(2);
    expect(updates[1]).toEqual({ sync_started_at: null });
  });

  it("끊긴 것으로 남기려 했는데 그 사이 다시 연결했으면 끊지 않고 잠금만 푼다", async () => {
    const { admin, updates, conditions } = fakeSyncAdmin(false);
    await recordSync(admin, connection, { claimedAt, error: "Slack 연결이 끊겼습니다.", revoked: true });
    expect(updates[0]).toMatchObject({ status: "revoked" });
    expect(conditions).toEqual(["connected_at <= 2026-09-29T00:00:00.000Z"]);
    expect(updates[1]).toEqual({ sync_started_at: null });
  });
});

describe("ingestDeps.ingestedIds: 이미 넣은 원문", () => {
  type Row = { user_id: string; connection_id: string | null; external_id: string };

  /** sources 행을 eq · in · or(eq · is.null)로 거르는 가짜 service role 클라이언트 */
  function fakeSources(rows: Row[]) {
    return {
      from: () => {
        let result = rows;
        const q = {
          select: () => q,
          eq: (column: keyof Row, value: string) => {
            result = result.filter((row) => row[column] === value);
            return q;
          },
          in: (column: keyof Row, values: string[]) => {
            result = result.filter((row) => values.includes(row[column] as string));
            return q;
          },
          or: (filters: string) => {
            const tests = filters.split(",").map((filter) => {
              const [column, op, value] = filter.split(".") as [keyof Row, string, string];
              return (row: Row) => (op === "is" && value === "null" ? row[column] === null : row[column] === value);
            });
            result = result.filter((row) => tests.some((test) => test(row)));
            return q;
          },
          throwOnError: async () => ({ data: result }),
        };
        return q;
      },
    } as unknown as SupabaseClient;
  }

  it("끊었다가 다시 연결해도(연결이 비워진 원문) 같은 페이지를 다시 넣지 않는다. 남의 원문 · 다른 연결의 원문은 보지 않는다", async () => {
    const admin = fakeSources([
      { user_id: "u1", connection_id: "c1", external_id: "p1" },
      { user_id: "u1", connection_id: null, external_id: "p2" },
      { user_id: "u1", connection_id: "c-other", external_id: "p3" },
      { user_id: "u2", connection_id: null, external_id: "p4" },
    ]);
    const ids = await ingestDeps(admin).ingestedIds(connection, ["p1", "p2", "p3", "p4", "p5"]);
    expect([...ids].sort()).toEqual(["p1", "p2"]);
  });

  it("id가 많으면(Gmail 한 창) 150개씩 나눠 묻고 결과를 합친다", async () => {
    const rows: Row[] = Array.from({ length: 320 }, (_, i) => ({ user_id: "u1", connection_id: i % 2 ? "c1" : null, external_id: `m${i}` }));
    const inCalls: number[] = [];
    const admin = fakeSources(rows);
    const from = admin.from.bind(admin);
    (admin as unknown as { from: (table: string) => unknown }).from = (table: string) => {
      const q = from(table) as unknown as { in: (column: keyof Row, values: string[]) => unknown };
      const original = q.in;
      q.in = (column, values) => {
        inCalls.push(values.length);
        return original(column, values);
      };
      return q;
    };
    const ids = await ingestDeps(admin).ingestedIds(connection, rows.map((r) => r.external_id));
    expect(inCalls).toEqual([150, 150, 20]);
    expect(ids.size).toBe(320);
  });
});

/** 프로필 · 로그인 계정 · 연결 행을 읽는 가짜 service role 클라이언트 (loadIdentity) */
function fakeIdentityAdmin(options: {
  profile?: unknown;
  email?: string | null;
  connections?: { user_id: string; provider: string; settings: unknown }[];
}) {
  const filters: string[] = [];
  const admin = {
    auth: { admin: { getUserById: async (id: string) => ({ data: { user: { id, email: options.email ?? null, user_metadata: {} } } }) } },
    from: (table: string) => {
      if (table === "profiles") {
        const q = { select: () => q, eq: () => q, maybeSingle: async () => ({ data: options.profile ?? null }) };
        return q;
      }
      if (table !== "connections") throw new Error(`예상하지 않은 표: ${table}`);
      let rows = options.connections ?? [];
      const q = {
        select: () => q,
        eq: (column: "user_id" | "provider", value: string) => {
          filters.push(`${column}=${value}`);
          rows = rows.filter((row) => row[column] === value);
          return q;
        },
        in: async (column: "provider", values: string[]) => {
          filters.push(`${column} in ${values.join(",")}`);
          return { data: rows.filter((row) => values.includes(row[column])).map(({ settings }) => ({ settings })) };
        },
      };
      return q;
    },
  } as unknown as SupabaseClient;
  return { admin, filters };
}

describe("loadIdentity: 연결한 Google 주소", () => {
  const profile = { display_name: "Me", aliases: [], emails: ["Work@Company.dev"] };

  it("google · gmail 연결의 settings.email을 사용자 주소에 더한다 (소문자, 겹치면 하나)", async () => {
    const { admin, filters } = fakeIdentityAdmin({
      profile,
      email: "login@example.com",
      connections: [
        { user_id: "u1", provider: "gmail", settings: { email: " Me@Company.dev " } },
        { user_id: "u1", provider: "google", settings: { email: "LOGIN@example.com" } },
        { user_id: "u1", provider: "gmail", settings: { email: null } },
        { user_id: "u1", provider: "gmail", settings: null },
        { user_id: "u1", provider: "notion", settings: { email: "notion@elsewhere.dev" } },
        { user_id: "u2", provider: "gmail", settings: { email: "someone@else.dev" } },
      ],
    });
    const identity = await loadIdentity(admin, "u1");
    expect(identity.name).toBe("Me");
    expect(identity.emails).toEqual(["login@example.com", "work@company.dev", "me@company.dev"]);
    expect(filters).toEqual(["user_id=u1", "provider in google,gmail"]);
  });

  it("Google 연결이 없으면 프로필 · 로그인 주소만", async () => {
    const { admin } = fakeIdentityAdmin({ profile, email: "login@example.com" });
    expect((await loadIdentity(admin, "u1")).emails).toEqual(["login@example.com", "work@company.dev"]);
  });
});

describe("ingestDeps.process: 확인 요청 알림", () => {
  const gmailConnection: Connection = { id: "g1", userId: "u1", provider: "gmail", settings: {}, syncCursor: null };
  const connectedAt = new Date("2026-09-28T00:00:00.000Z");
  const item = (occurredAt: Date): IngestItem => ({
    externalId: "m1",
    externalVersion: "1",
    kind: "email",
    title: "Signed contract",
    text: "제목: Signed contract\n\nSure, I'll send it by Monday.",
    occurredAt,
    lastEditedAt: occurredAt,
    externalUrl: null,
    writtenByMe: null,
  });
  const identityAdmin = () =>
    fakeIdentityAdmin({ email: "login@example.com", connections: [{ user_id: "u1", provider: "gmail", settings: { email: "me@company.dev" } }] }).admin;

  it("연결한 시각보다 먼저 받은 메일은 알림 없이(notify: false) 처리한다", async () => {
    const admin = identityAdmin();
    await ingestDeps(admin, { notifyFrom: connectedAt }).process(gmailConnection, "src-1", item(new Date(connectedAt.getTime() - 1)));
    expect(processSource).toHaveBeenLastCalledWith(
      admin,
      { id: "src-1", userId: "u1", notify: false },
      expect.objectContaining({ kind: "email", text: "제목: Signed contract\n\nSure, I'll send it by Monday." }),
    );
  });

  it("연결한 뒤(같은 시각 포함) 받은 메일은 알린다 (notify: true)", async () => {
    const admin = identityAdmin();
    const deps = ingestDeps(admin, { notifyFrom: connectedAt });
    await deps.process(gmailConnection, "src-2", item(connectedAt));
    expect(processSource).toHaveBeenLastCalledWith(admin, { id: "src-2", userId: "u1", notify: true }, expect.anything());
    await deps.process(gmailConnection, "src-3", item(new Date(connectedAt.getTime() + 60_000)));
    expect(processSource).toHaveBeenLastCalledWith(admin, { id: "src-3", userId: "u1", notify: true }, expect.anything());
  });

  it("notifyFrom이 없으면(다른 연동 · 연결 시각을 모름) 늘 알린다", async () => {
    const admin = identityAdmin();
    await ingestDeps(admin).process(gmailConnection, "src-4", item(new Date("2020-01-01T00:00:00Z")));
    expect(processSource).toHaveBeenLastCalledWith(admin, expect.objectContaining({ notify: true }), expect.anything());
    await ingestDeps(admin, { notifyFrom: null }).process(gmailConnection, "src-5", item(new Date("2020-01-01T00:00:00Z")));
    expect(processSource).toHaveBeenLastCalledWith(admin, expect.objectContaining({ notify: true }), expect.anything());
  });

  it("\"원문 속 나\"에 연결한 Gmail 주소가 들어간다", async () => {
    const admin = identityAdmin();
    await ingestDeps(admin).process(gmailConnection, "src-6", item(connectedAt));
    const [, , input] = vi.mocked(processSource).mock.lastCall!;
    expect(input.identity.emails).toContain("me@company.dev");
  });
});

describe("updateConnectionSettings", () => {
  it("지금 설정을 넘겨 받은 값으로 고친다", async () => {
    const { admin, writes } = fakeAdmin({ googleUserId: "s", stats: { since: "x", counts: {} } });
    const seen: Record<string, unknown>[] = [];
    await updateConnectionSettings(admin, connection, (settings) => {
      seen.push(settings);
      return { ...settings, email: "me@company.dev" };
    });
    expect(seen).toEqual([{ googleUserId: "s", stats: { since: "x", counts: {} } }]);
    expect(writes).toEqual([{ googleUserId: "s", stats: { since: "x", counts: {} }, email: "me@company.dev" }]);
  });

  it("update가 null이면 쓰지 않는다 (그 사이 다른 곳에서 저장한 설정을 덮지 않게)", async () => {
    const { admin, writes } = fakeAdmin({ googleUserId: "s" });
    await updateConnectionSettings(admin, connection, () => null);
    expect(writes).toEqual([]);
  });

  it("설정이 비어 있으면(null) 빈 객체를 넘긴다", async () => {
    const { admin, writes } = fakeAdmin(null as unknown as Record<string, unknown>);
    await updateConnectionSettings(admin, connection, (settings) => ({ ...settings, scopes: [] }));
    expect(writes).toEqual([{ scopes: [] }]);
  });
});
