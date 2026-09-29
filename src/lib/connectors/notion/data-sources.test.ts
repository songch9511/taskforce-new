import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { NotionError, NotionOAuthError } from "./api";
import { saveDataSource } from "./data-sources";
import { withNotionClient } from "./run";

vi.mock("server-only", () => ({}));
vi.mock("./run", () => ({ withNotionClient: vi.fn() }));

// 할 일 DB 설정 저장 (/lab): Notion이 DB를 읽을 수 없다고 하면(공유 빠짐) 저장된 역할만 바꿀 수 있다.
// 토큰 발급 창구의 거절(연결 만료 · 설정 문제)은 DB 문제가 아니므로 그대로 올린다.

const SAVED = { role: "text", title: "회의록", confirmedAt: "2026-09-20T00:00:00.000Z" } as const;

/** 연결 설정 하나를 읽고, 쓴 값을 기록하는 가짜 service role 클라이언트 */
function fakeAdmin() {
  const updates: unknown[] = [];
  const q = {
    select: () => q,
    eq: () => q,
    maybeSingle: () => q,
    throwOnError: async () => ({ data: { provider: "notion", settings: { dataSources: { ds1: SAVED } } } }),
  };
  const admin = {
    from: () => ({
      ...q,
      update: (values: unknown) => {
        updates.push(values);
        return { eq: () => ({ eq: () => ({ throwOnError: async () => ({ data: null }) }) }) };
      },
    }),
  } as unknown as SupabaseClient;
  return { admin, updates };
}

beforeEach(() => vi.clearAllMocks());

describe("saveDataSource: 데이터베이스를 읽지 못하면", () => {
  it("Notion이 없다고 하면(404) 저장된 DB의 역할만 바꾼다", async () => {
    vi.mocked(withNotionClient).mockRejectedValue(new NotionError("Notion API 요청 실패 (404 object_not_found)", 404, "object_not_found"));
    const { admin, updates } = fakeAdmin();

    const summary = await saveDataSource(admin, "u1", "c1", "ds1", { role: "ignore" });

    expect(summary).toMatchObject({ id: "ds1", reachable: false, setting: { role: "ignore", title: "회의록" } });
    expect(updates).toHaveLength(1);
  });

  it("토큰 발급 창구의 거절(연결 만료)은 DB가 없는 것으로 보지 않고 그대로 올린다 (설정을 바꾸지 않는다)", async () => {
    vi.mocked(withNotionClient).mockRejectedValue(new NotionOAuthError("Notion 토큰 요청 실패 (400 invalid_grant)", 400, "invalid_grant"));
    const { admin, updates } = fakeAdmin();

    await expect(saveDataSource(admin, "u1", "c1", "ds1", { role: "ignore" })).rejects.toBeInstanceOf(NotionOAuthError);
    expect(updates).toEqual([]);
  });
});
