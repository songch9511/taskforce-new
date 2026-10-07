import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { DataSourceSetting } from "@/lib/api/contract";
import { processSource } from "@/lib/sources/process";

import {
  addConnectionStats,
  taskDeps,
  ingestDeps,
  loadIdentity,
  markBackfilled,
  mergeConnectionSettings,
  recordConnectionCreated,
  recordNotionHealth,
  recordSync,
  saveConnection,
} from "./store";
import type { Connection, IngestItem } from "./types";

vi.mock("server-only", () => ({}));
// 원문 처리(추출 · 판정 · 병합 · 알림)는 부른 인자만 본다
vi.mock("@/lib/sources/process", () => ({ processSource: vi.fn(async () => ({ needsConfirmation: [] })), processTaskSource: vi.fn() }));

type Query = { eq: () => Query; single: () => Query; throwOnError: () => Promise<unknown> };

type Rpc = { name: string; args: Record<string, unknown> };

/** connections 행 하나의 settings를 읽고, 설정 쓰기(DB 함수 호출)를 기록하는 가짜 service role 클라이언트 */
function fakeAdmin(stored: Record<string, unknown>, rpcResult: unknown = true, connectedAt = "2026-09-01T00:00:00.000Z") {
  const rpcs: Rpc[] = [];
  const query = (result: () => unknown): Query => {
    const q: Query = { eq: () => q, single: () => q, throwOnError: async () => result() };
    return q;
  };
  const admin = {
    from: () => ({ select: () => query(() => ({ data: { settings: stored, connected_at: connectedAt } })) }),
    rpc: (name: string, args: Record<string, unknown>) => {
      rpcs.push({ name, args });
      return { throwOnError: async () => ({ data: rpcResult }) };
    },
  } as unknown as SupabaseClient;
  /** merge_connection_settings에 넘긴 인자들 */
  const merges = () => rpcs.filter((r) => r.name === "merge_connection_settings").map((r) => r.args);
  return { admin, rpcs, merges };
}

/** 연결 c1(u1)에 넘긴 merge_connection_settings 인자 */
const merged = (patch: { p_set?: object; p_remove?: string[]; p_data_sources?: object }) => ({
  p_user_id: "u1",
  p_connection_id: "c1",
  p_set: {},
  p_remove: [],
  p_data_sources: {},
  ...patch,
});

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
  it("남기되, 그 사이 사용자가 확인한 DB(가져오지 않음 등)는 덮지 않는다: 바뀐 DB의 설정만 넘긴다", async () => {
    const { admin, merges } = fakeAdmin({
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
    // 연결한 사람 · 공유 상태는 그대로라 넘기지 않고, 사용자가 확인한 ds-b는 넘기지 않는다 (DB에 있는 값 그대로)
    expect(merges()).toEqual([merged({ p_data_sources: { "ds-a": auto("Action") } })]);
  });

  it("바뀐 것이 없으면 쓰지 않는다", async () => {
    const { admin, rpcs } = fakeAdmin({
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
    expect(rpcs).toEqual([]);
  });

  it("처음 본 DB · 공유 상태 · 새로 알아낸 연결한 사람만 넘긴다 (다른 DB의 설정은 넘기지 않는다)", async () => {
    const saved = { role: "text", title: "회의록", confirmedAt: "2026-09-27T12:00:00Z" };
    const { admin, merges } = fakeAdmin({ dataSources: { ds1: saved }, health: { unreachable: [], checkedAt: "2026-09-27T00:00:00Z" } });
    const unreachable = [{ id: "ds1", title: "회의록" }];
    await recordNotionHealth(
      admin,
      connection,
      { seen: [{ id: "ds1", title: "회의록", role: "text" }, { id: "ds2", title: "New", role: "text" }], unreachable, notionUserId: "notion-me" },
      now,
    );
    expect(merges()).toEqual([
      merged({
        p_set: { health: { unreachable, checkedAt: now.toISOString() }, notionUserId: "notion-me" },
        p_data_sources: { ds2: { role: "text", title: "New", seenAt: now.toISOString() } },
      }),
    ]);
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

  it("되돌린 자동 확인은 다른 변화가 없어도 남긴다 (처음 훑기 표시도 함께 빠진다: 그 DB의 설정을 통째로 바꾼다)", async () => {
    const { admin, merges } = fakeAdmin({ notionUserId: "notion-me", dataSources: { "ds-p": person({}) } });
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "notion-me", autoConfirmed: [], reverted: [{ id: "ds-p", setting: reverted }] }, now);
    expect(merges()).toEqual([merged({ p_data_sources: { "ds-p": reverted } })]);
  });

  it("그 사이 사용자가 확인한 DB는 되돌리지 않는다 (담당 속성이 Person이어도)", async () => {
    const { admin, rpcs } = fakeAdmin({ notionUserId: "notion-me", dataSources: { "ds-p": person({ confirmedBy: undefined }) } });
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "notion-me", reverted: [{ id: "ds-p", setting: reverted }] }, now);
    expect(rpcs).toEqual([]);
  });

  it("매핑이 바뀌어 다시 자동 확인한 DB는 전의 자동 확인을 덮는다", async () => {
    const { admin, merges } = fakeAdmin({ notionUserId: "notion-me", dataSources: { "ds-a": { ...auto("Action"), confirmedAt: earlier, backfilledAt: earlier } } });
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "notion-me", autoConfirmed: [{ id: "ds-a", setting: auto("Action") }] }, now);
    expect(merges()).toEqual([merged({ p_data_sources: { "ds-a": auto("Action") } })]);
  });
});

describe("recordNotionHealth: 잠금 뒤 다시 연결했으면 notionUserId 다시 쓰지 않기", () => {
  const claimedAt = new Date("2026-09-28T00:00:00.000Z");

  it("잠금을 잡은 뒤 다시 연결했으면(connected_at이 뒤) 옛 연결로 알아낸 notionUserId를 쓰지 않는다 (saveConnection이 뺀 값)", async () => {
    const { admin, rpcs } = fakeAdmin({}, true, "2026-09-28T00:01:00.000Z");
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "old-person" }, now, claimedAt);
    expect(rpcs).toEqual([]);
  });

  it("다시 연결하지 않았으면(connected_at이 앞) 처음 알아낸 notionUserId를 남긴다", async () => {
    const { admin, merges } = fakeAdmin({}, true, "2026-09-27T00:00:00.000Z");
    await recordNotionHealth(admin, connection, { seen: [], unreachable: null, notionUserId: "notion-me" }, now, claimedAt);
    expect(merges()).toEqual([merged({ p_set: { notionUserId: "notion-me" } })]);
  });
});

describe("markBackfilled: 처음 훑기 표시", () => {
  const tasks = (confirmedAt: string): DataSourceSetting => ({ ...auto("Tasks"), confirmedAt });

  it("확인 시각이 같은 할 일 DB의 설정만 넘긴다 (그 사이 다시 확인한 DB · 다른 DB는 넘기지 않는다)", async () => {
    const { admin, merges } = fakeAdmin({ dataSources: { t1: tasks("A"), t2: tasks("B"), doc: { role: "text", title: "회의록" } } });
    await markBackfilled(
      admin,
      connection,
      [
        { dataSourceId: "t1", confirmedAt: "A" },
        { dataSourceId: "t2", confirmedAt: "old" },
        { dataSourceId: "doc", confirmedAt: "A" },
      ],
      now,
    );
    expect(merges()).toEqual([merged({ p_data_sources: { t1: { ...tasks("A"), backfilledAt: now.toISOString() } } })]);
  });

  it("표시할 것이 없으면 쓰지 않는다", async () => {
    const { admin, rpcs } = fakeAdmin({ dataSources: { t1: tasks("B") } });
    await markBackfilled(admin, connection, [{ dataSourceId: "t1", confirmedAt: "A" }], now);
    await markBackfilled(admin, connection, [], now);
    expect(rpcs).toEqual([]);
  });
});

describe("recordSync: 동기화 결과를 연결 상태로", () => {
  const claimedAt = new Date("2026-09-29T00:00:00.000Z");

  /** update 값과 조건을 기록하는 가짜 service role 클라이언트. matched: 조건에 맞는 행이 있는가 */
  function fakeSyncAdmin(matched = true, insertError: Error | null = null) {
    const updates: Record<string, unknown>[] = [];
    const conditions: string[] = [];
    const events: { table: string; row: unknown }[] = [];
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
      from: (table: string) => ({
        update: (values: Record<string, unknown>) => {
          updates.push(values);
          return q;
        },
        insert: (row: unknown) => ({
          throwOnError: async () => {
            if (insertError) throw insertError;
            events.push({ table, row });
          },
        }),
      }),
    } as unknown as SupabaseClient;
    return { admin, updates, conditions, events };
  }

  it("갱신 토큰이 거절돼 다시 연결해야 하면 reauth로 남기고 true(바꿨음)를 돌려준다. 끊긴 연결(revoked) · 이미 reauth인 연결 · 동기화 뒤에 다시 연결한 연결은 덮지 않는다", async () => {
    const { admin, updates, conditions } = fakeSyncAdmin();
    const changed = await recordSync(admin, connection, { claimedAt, error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    expect(changed).toBe(true);
    expect(updates[0]).toMatchObject({ status: "reauth", last_error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", sync_started_at: null });
    expect(conditions).toEqual(["connected_at <= 2026-09-29T00:00:00.000Z", "status <> revoked", "status <> reauth"]);
  });

  it("이미 reauth인 연결에 reauth를 또 적으면(조건에 맞는 행 없음) false: 잠금만 풀고 알림 대상이 아니다", async () => {
    const { admin, updates } = fakeSyncAdmin(false);
    const changed = await recordSync(admin, connection, { claimedAt, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    expect(changed).toBe(false);
    expect(updates).toHaveLength(2);
    expect(updates[1]).toEqual({ sync_started_at: null });
  });

  /** 연결 행 하나의 상태 · connected_at을 두고 eq · neq · lte 조건을 실제로 적용하는 가짜 service role 클라이언트 */
  function statefulAdmin(row: { status: string; connected_at: string; sync_started_at: string | null }) {
    const events: unknown[] = [];
    const admin = {
      from: () => ({
        insert: (event: unknown) => ({ throwOnError: async () => void events.push(event) }),
        update: (values: Record<string, unknown>) => {
          const filters: ((r: typeof row) => boolean)[] = [];
          const q = {
            eq: () => q,
            neq: (column: keyof typeof row, value: string) => (filters.push((r) => r[column] !== value), q),
            lte: (column: keyof typeof row, value: string) => (filters.push((r) => (r[column] as string) <= value), q),
            select: () => q,
            throwOnError: async () => {
              if (!filters.every((f) => f(row))) return { data: [] };
              Object.assign(row, values);
              return { data: [{ id: "c1" }] };
            },
          };
          return q;
        },
      }),
    } as unknown as SupabaseClient;
    return Object.assign(admin, { events });
  }

  it("재연결 알림 한 번: active → reauth로 바꾼 첫 동기화만 true, 같은 reauth를 또 적으면 false", async () => {
    const row = { status: "active", connected_at: "2026-09-28T00:00:00.000Z", sync_started_at: claimedAt.toISOString() };
    const admin = statefulAdmin(row);
    const reauth = { claimedAt, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true };
    expect(await recordSync(admin, connection, reauth)).toBe(true);
    expect(row).toMatchObject({ status: "reauth", sync_started_at: null });
    expect(await recordSync(admin, connection, reauth)).toBe(false);
    expect(row.status).toBe("reauth");
    // 만료 지표도 바뀐 첫 호출에서만 한 줄
    expect(admin.events).toEqual([{ user_id: "u1", type: "connection_reauth", provider: "notion" }]);
  });

  it("재연결 알림 없음: 동기화 도중 다시 연결했으면(connected_at이 잠금 시각보다 뒤) false이고 새 연결은 그대로", async () => {
    const row = { status: "active", connected_at: "2026-09-29T00:00:30.000Z", sync_started_at: claimedAt.toISOString() };
    const admin = statefulAdmin(row);
    expect(await recordSync(admin, connection, { claimedAt, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true })).toBe(false);
    expect(row).toMatchObject({ status: "active", sync_started_at: null });
    expect(admin.events).toEqual([]);
  });

  it("재연결 알림 없음: 이미 끊긴(revoked) 연결은 reauth로 바꾸지 않는다", async () => {
    const row = { status: "revoked", connected_at: "2026-09-28T00:00:00.000Z", sync_started_at: claimedAt.toISOString() };
    const admin = statefulAdmin(row);
    expect(await recordSync(admin, connection, { claimedAt, error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true })).toBe(false);
    expect(row.status).toBe("revoked");
    expect(admin.events).toEqual([]);
  });

  it("reauth로 바꾸면 알림이 가는지와 상관없이 서비스를 담은 connection_reauth 지표를 남기고, 바꾸지 않은 기록은 남기지 않는다", async () => {
    const changed = fakeSyncAdmin();
    await recordSync(changed.admin, { ...connection, provider: "gmail" }, { claimedAt, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    expect(changed.events).toEqual([{ table: "metric_events", row: { user_id: "u1", type: "connection_reauth", provider: "gmail" } }]);

    const unchanged = fakeSyncAdmin(false);
    await recordSync(unchanged.admin, connection, { claimedAt, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    const other = fakeSyncAdmin();
    await recordSync(other.admin, connection, { claimedAt, error: "Notion 요청 실패 (503)" });
    await recordSync(other.admin, connection, { claimedAt, error: "Slack 연결이 끊겼습니다.", revoked: true });
    expect([...unchanged.events, ...other.events]).toEqual([]);
  });

  it("지표 기록이 실패해도 recordSync는 그대로 true를 돌려준다 (동기화 · 알림에 영향 없음, 오류 로그만)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = fakeSyncAdmin(true, new Error("check constraint"));
    expect(await recordSync(admin, connection, { claimedAt, error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true })).toBe(true);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("재연결 필요 지표 기록 실패"), "check constraint");
    log.mockRestore();
  });

  it("reauth가 아닌 기록은 행을 바꿔도 false다 (알림은 reauth로 바뀔 때만)", async () => {
    const { admin, conditions } = fakeSyncAdmin();
    expect(await recordSync(admin, connection, { claimedAt, error: "Notion 요청 실패 (503)" })).toBe(false);
    expect(await recordSync(admin, connection, { claimedAt, error: "Slack 연결이 끊겼습니다.", revoked: true })).toBe(false);
    // "이미 reauth가 아님" 조건은 reauth를 적을 때만 붙는다
    expect(conditions).not.toContain("status <> reauth");
  });

  it("동기화를 시작한 뒤 다시 연결했으면(connected_at이 뒤) 새 연결 상태를 덮지 않고 잠금만 푼다. reauth였어도 false", async () => {
    const { admin, updates } = fakeSyncAdmin(false);
    expect(await recordSync(admin, connection, { claimedAt, error: "Notion 요청 실패 (503)" })).toBe(false);
    expect(updates).toHaveLength(2);
    expect(updates[1]).toEqual({ sync_started_at: null });
    const reauth = fakeSyncAdmin(false);
    expect(await recordSync(reauth.admin, connection, { claimedAt, error: "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true })).toBe(false);
  });

  it("끊긴 것으로 남기려 했는데 그 사이 다시 연결했으면 끊지 않고 잠금만 푼다", async () => {
    const { admin, updates, conditions } = fakeSyncAdmin(false);
    await recordSync(admin, connection, { claimedAt, error: "Slack 연결이 끊겼습니다.", revoked: true });
    expect(updates[0]).toMatchObject({ status: "revoked" });
    expect(conditions).toEqual(["connected_at <= 2026-09-29T00:00:00.000Z"]);
    expect(updates[1]).toEqual({ sync_started_at: null });
  });
});

describe("ingestDeps.insertSource: 붙인 일정 (sources.meeting)", () => {
  const item: IngestItem = {
    externalId: "conferenceRecords/c1/transcripts/t1",
    externalVersion: "1",
    kind: "meeting",
    title: "Proposal review — Acme",
    text: "[Google Meet · Proposal review — Acme]\nJordan Lee: Hello there, everyone.",
    occurredAt: new Date("2026-09-30T01:00:00Z"),
    lastEditedAt: new Date("2026-09-30T02:00:00Z"),
    externalUrl: null,
  };

  /** 넣는 행을 기록하는 가짜 service role 클라이언트. failures를 주면 차례로 그 오류를 돌려준다 (그 뒤는 성공) */
  function fakeInsert(failures: { code: string; message: string }[] = []) {
    const rows: Record<string, unknown>[] = [];
    const pending = [...failures];
    const admin = {
      from: () => ({
        insert: (row: Record<string, unknown>) => {
          rows.push(row);
          const error = pending.shift();
          return { select: () => ({ single: async () => (error ? { data: null, error } : { data: { id: "src-1" }, error: null }) }) };
        },
      }),
    } as unknown as SupabaseClient;
    return { admin, rows };
  }
  const meeting = { calendar_event_id: "evt-1", title: "Proposal review — Acme", start: "2026-09-30T01:00:00.000Z", end: "2026-09-30T02:00:00.000Z" };

  it("일정이 붙은 원문은 { calendar_event_id, title, start, end }를 meeting에 저장한다", async () => {
    const { admin, rows } = fakeInsert();
    expect(await ingestDeps(admin).insertSource(connection, { ...item, meeting })).toBe("src-1");
    expect(rows[0]).toMatchObject({ user_id: "u1", connection_id: "c1", external_id: item.externalId, kind: "meeting", meeting });
  });

  it("일정이 없는 원문은 meeting 열을 보내지 않는다: 마이그레이션을 적용하기 전에 배포해도 다른 원문의 저장은 그대로 된다", async () => {
    const { admin, rows } = fakeInsert();
    await ingestDeps(admin).insertSource(connection, item);
    expect("meeting" in rows[0]).toBe(false);
  });

  it.each([
    ["PostgREST 스키마 캐시에 열이 없음", "PGRST204"],
    ["Postgres undefined_column", "42703"],
  ])("마이그레이션 전이라 meeting 열이 없으면(%s) 일정 없이 다시 넣는다: 일정 붙이기가 동기화 전체를 막지 않는다 (일정 연결만 잃고, 로그에 남긴다)", async (_name, code) => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin, rows } = fakeInsert([{ code, message: "Could not find the 'meeting' column of 'sources' in the schema cache" }]);

    expect(await ingestDeps(admin).insertSource(connection, { ...item, meeting })).toBe("src-1");

    expect(rows).toHaveLength(2);
    expect("meeting" in rows[0]).toBe(true);
    expect("meeting" in rows[1]).toBe(false);
    expect(rows[1]).toMatchObject({ external_id: item.externalId, raw_text: item.text });
    expect(spy).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(spy.mock.calls)).not.toContain("Jordan");
    spy.mockRestore();
  });

  it("그 밖의 저장 오류는 다시 넣지 않고 던진다. 동시에 같은 항목이 들어왔으면(23505) null", async () => {
    const failing = fakeInsert([{ code: "23514", message: "check constraint sources_meeting_shape" }]);
    await expect(ingestDeps(failing.admin).insertSource(connection, { ...item, meeting })).rejects.toThrow(/원문 저장 실패/);
    expect(failing.rows).toHaveLength(1);

    const duplicate = fakeInsert([{ code: "23505", message: "duplicate key" }]);
    expect(await ingestDeps(duplicate.admin).insertSource(connection, { ...item, meeting })).toBeNull();
    expect(duplicate.rows).toHaveLength(1);
  });
});

describe("recordConnectionCreated: 연결 완료 지표", () => {
  it("서비스를 담아 남긴다 (재연결 알림 지표와 서비스별로 맞추려고)", async () => {
    const inserted: unknown[] = [];
    const admin = {
      from: (table: string) => ({ insert: (row: unknown) => ({ throwOnError: async () => void inserted.push({ table, row }) }) }),
    } as unknown as SupabaseClient;
    await recordConnectionCreated(admin, "u1", "gmail");
    expect(inserted).toEqual([{ table: "metric_events", row: { user_id: "u1", type: "connection_created", provider: "gmail" } }]);
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

  it("연결로 가져온 원문임을 파이프라인에 알린다 (메일의 인용된 옛 메일 속 후보를 버리는 기준)", async () => {
    const admin = identityAdmin();
    await ingestDeps(admin).process(gmailConnection, "src-7", item(connectedAt));
    expect(processSource).toHaveBeenLastCalledWith(admin, expect.anything(), expect.objectContaining({ kind: "email", fromConnector: true }));
  });

  it("Google 연결(Meet 전사)의 원문도 같은 길로 fromConnector를 넘긴다", async () => {
    const admin = identityAdmin();
    const google: Connection = { id: "g2", userId: "u1", provider: "google", settings: {}, syncCursor: null };
    await ingestDeps(admin).process(google, "src-8", { ...item(connectedAt), kind: "meeting", text: "[Google Meet · 회의]\n김민수: 금요일까지 보내드릴게요" });
    expect(processSource).toHaveBeenLastCalledWith(admin, expect.anything(), expect.objectContaining({ kind: "meeting", fromConnector: true }));
  });

  it("\"원문 속 나\"에 연결한 Gmail 주소가 들어간다", async () => {
    const admin = identityAdmin();
    await ingestDeps(admin).process(gmailConnection, "src-6", item(connectedAt));
    const [, , input] = vi.mocked(processSource).mock.lastCall!;
    expect(input.identity.emails).toContain("me@company.dev");
  });
});

describe("mergeConnectionSettings", () => {
  it("바꿀 키 · 뺄 키 · DB 설정을 DB 함수에 넘기고, 고친 연결이 있는지 돌려준다", async () => {
    const { admin, rpcs } = fakeAdmin({});
    const setting: DataSourceSetting = { role: "text", title: "회의록", confirmedAt: now.toISOString() };
    expect(await mergeConnectionSettings(admin, connection, { set: { scopes: ["openid"] }, remove: ["notionUserId"], dataSources: { ds1: setting } })).toBe(true);
    expect(rpcs).toEqual([
      { name: "merge_connection_settings", args: merged({ p_set: { scopes: ["openid"] }, p_remove: ["notionUserId"], p_data_sources: { ds1: setting } }) },
    ]);
  });

  it("빠진 값은 빈 값으로 넘긴다. 연결이 없으면(그 사이 끊김) false", async () => {
    const { admin, rpcs } = fakeAdmin({}, false);
    expect(await mergeConnectionSettings(admin, connection, { set: { email: null } })).toBe(false);
    expect(rpcs[0].args).toEqual(merged({ p_set: { email: null } }));
  });
});

describe("addConnectionStats", () => {
  it("0 · undefined를 빼고 더할 개수와 시각을 DB 함수에 넘긴다", async () => {
    const { admin, rpcs } = fakeAdmin({});
    await addConnectionStats(admin, connection, { inbound: 3, sent: 1, bulk: 0, no_reply: undefined }, now);
    expect(rpcs).toEqual([
      { name: "add_connection_stats", args: { p_user_id: "u1", p_connection_id: "c1", p_counts: { inbound: 3, sent: 1 }, p_now: now.toISOString() } },
    ]);
  });

  it("더할 것이 없으면(모두 0 · undefined) 부르지 않는다", async () => {
    const { admin, rpcs } = fakeAdmin({});
    await addConnectionStats(admin, connection, { inbound: 0, bulk: undefined }, now);
    await addConnectionStats(admin, connection, {}, now);
    expect(rpcs).toEqual([]);
  });
});

describe("saveConnection: 다시 연결", () => {
  /** upsert한 연결 행(settings)을 돌려주고, 토큰 저장 · DB 함수 호출을 기록하는 가짜 service role 클라이언트 */
  function fakeConnectAdmin(settings: Record<string, unknown> | null) {
    const rpcs: Rpc[] = [];
    const tables: string[] = [];
    const chain = (data: unknown) => {
      const q = { select: () => q, single: () => q, throwOnError: async () => ({ data }) };
      return q;
    };
    const admin = {
      from: (table: string) => ({
        upsert: () => {
          tables.push(table);
          return chain(table === "connections" ? { id: "c1", settings } : null);
        },
      }),
      rpc: (name: string, args: Record<string, unknown>) => {
        rpcs.push({ name, args });
        return { throwOnError: async () => ({ data: true }) };
      },
    } as unknown as SupabaseClient;
    return { admin, rpcs, tables };
  }
  const input = { userId: "u1", provider: "notion" as const, externalAccountId: "ws", displayName: "WS", token: { access_token: "t" } };

  beforeEach(() => vi.stubEnv("CONNECTOR_TOKEN_KEY", Buffer.alloc(32, 1).toString("base64")));
  afterEach(() => vi.unstubAllEnvs());

  it("남겨 둔 Notion user id가 있으면 그 키만 뺀다 (다른 설정은 DB에 있는 값 그대로)", async () => {
    const { admin, rpcs, tables } = fakeConnectAdmin({ notionUserId: "notion-old", dataSources: {} });
    expect(await saveConnection(admin, input)).toBe("c1");
    expect(tables).toEqual(["connections", "connection_secrets"]);
    expect(rpcs).toEqual([{ name: "merge_connection_settings", args: merged({ p_remove: ["notionUserId"] }) }]);
  });

  it("뺄 것이 없으면 설정을 쓰지 않는다", async () => {
    for (const settings of [{ dataSources: {} }, null]) {
      const { admin, rpcs } = fakeConnectAdmin(settings);
      await saveConnection(admin, input);
      expect(rpcs).toEqual([]);
    }
  });
});

it("pending tasks use the bounded SQL queue before loading task states", async () => {
  const { admin, rpcs } = fakeAdmin({}, []);
  await taskDeps(admin).pendingTasks({ id: "c1", userId: "u1" } as Connection);
  expect(rpcs).toEqual([{ name: "pending_task_sources", args: { p_user_id: "u1", p_connection_id: "c1", p_since: expect.any(String) } }]);
});
