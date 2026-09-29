import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

import type { DataSourceSetting } from "@/lib/api/contract";

import { recordNotionHealth, recordSync } from "./store";
import type { Connection } from "./types";

vi.mock("server-only", () => ({}));

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
  /** update 값과 조건만 기록하는 가짜 service role 클라이언트 */
  function fakeSyncAdmin() {
    const updates: Record<string, unknown>[] = [];
    const conditions: string[] = [];
    const q = {
      eq: () => q,
      neq: (column: string, value: string) => {
        conditions.push(`${column} <> ${value}`);
        return q;
      },
      select: () => q,
      throwOnError: async () => ({ data: [{ id: "c1" }] }),
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

  it("갱신 토큰이 거절돼 다시 연결해야 하면 reauth로 남긴다. 끊긴 연결(revoked)은 덮지 않는다", async () => {
    const { admin, updates, conditions } = fakeSyncAdmin();
    await recordSync(admin, connection, { error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", reauth: true });
    expect(updates[0]).toMatchObject({ status: "reauth", last_error: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", sync_started_at: null });
    expect(conditions).toEqual(["status <> revoked"]);
  });
});
