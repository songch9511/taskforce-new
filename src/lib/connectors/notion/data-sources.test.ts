import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { mergeConnectionSettings } from "../store";

import { NotionError, NotionOAuthError, type NotionDataSource } from "./api";
import { saveDataSource } from "./data-sources";
import { withNotionClient } from "./run";

vi.mock("server-only", () => ({}));
vi.mock("./run", () => ({ withNotionClient: vi.fn() }));
vi.mock("../store", () => ({ mergeConnectionSettings: vi.fn() }));

// 할 일 DB 설정 저장 (/lab): Notion이 DB를 읽을 수 없다고 하면(공유 빠짐) 저장된 역할만 바꿀 수 있다.
// 토큰 발급 창구의 거절(연결 만료 · 설정 문제)은 DB 문제가 아니므로 그대로 올린다.
// 저장은 그 DB의 설정만 합친다 (mergeConnectionSettings): 다른 DB의 설정 · 동기화가 남긴 값은 DB에 있는 값 그대로.

const SAVED = { role: "text", title: "회의록", confirmedAt: "2026-09-20T00:00:00.000Z" } as const;
const NOW = new Date("2026-09-28T00:00:00.000Z");

/** 연결 설정 하나를 읽는 가짜 service role 클라이언트 */
function fakeAdmin() {
  const q = {
    select: () => q,
    eq: () => q,
    maybeSingle: () => q,
    throwOnError: async () => ({ data: { provider: "notion", settings: { dataSources: { ds1: SAVED, ds2: SAVED } } } }),
  };
  return { from: () => q } as unknown as SupabaseClient;
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(mergeConnectionSettings).mockResolvedValue(true);
});

describe("saveDataSource: 데이터베이스를 읽지 못하면", () => {
  it("Notion이 없다고 하면(404) 저장된 DB의 역할만 바꾼다", async () => {
    vi.mocked(withNotionClient).mockRejectedValue(new NotionError("Notion API 요청 실패 (404 object_not_found)", 404, "object_not_found"));
    const admin = fakeAdmin();

    const summary = await saveDataSource(admin, "u1", "c1", "ds1", { role: "ignore" }, NOW);

    expect(summary).toMatchObject({ id: "ds1", reachable: false, setting: { role: "ignore", title: "회의록" } });
    expect(mergeConnectionSettings).toHaveBeenCalledTimes(1);
    expect(mergeConnectionSettings).toHaveBeenCalledWith(admin, { id: "c1", userId: "u1" }, {
      dataSources: { ds1: { role: "ignore", title: "회의록", confirmedAt: NOW.toISOString() } },
    });
  });

  it("토큰 발급 창구의 거절(연결 만료)은 DB가 없는 것으로 보지 않고 그대로 올린다 (설정을 바꾸지 않는다)", async () => {
    vi.mocked(withNotionClient).mockRejectedValue(new NotionOAuthError("Notion 토큰 요청 실패 (400 invalid_grant)", 400, "invalid_grant"));

    await expect(saveDataSource(fakeAdmin(), "u1", "c1", "ds1", { role: "ignore" })).rejects.toBeInstanceOf(NotionOAuthError);
    expect(mergeConnectionSettings).not.toHaveBeenCalled();
  });
});

describe("saveDataSource: 읽을 수 있는 데이터베이스", () => {
  it("그 DB의 설정만 넘긴다 (다른 DB의 설정은 넘기지 않는다)", async () => {
    const ds = { id: "ds1", title: [{ plain_text: "회의록 DB" }], properties: {} } as unknown as NotionDataSource;
    vi.mocked(withNotionClient).mockResolvedValue(ds);
    const admin = fakeAdmin();

    await saveDataSource(admin, "u1", "c1", "ds1", { role: "text" }, NOW);

    expect(mergeConnectionSettings).toHaveBeenCalledWith(admin, { id: "c1", userId: "u1" }, {
      dataSources: { ds1: { role: "text", title: "회의록 DB", confirmedAt: NOW.toISOString() } },
    });
  });
});
