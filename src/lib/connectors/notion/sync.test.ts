import { describe, expect, it } from "vitest";

import type { IngestDeps } from "../ingest";
import type { Connection } from "../types";

import type { NotionClient, NotionPage } from "./api";
import { syncNotion } from "./sync";

const now = new Date("2026-09-25T12:00:00.000Z");
const minutesAgo = (m: number) => new Date(now.getTime() - m * 60_000).toISOString();

const page = (id: string, editedMinutesAgo: number, extra: Partial<NotionPage> = {}): NotionPage => ({
  object: "page",
  id,
  url: `https://www.notion.so/${id}`,
  created_time: minutesAgo(editedMinutesAgo + 60),
  last_edited_time: minutesAgo(editedMinutesAgo),
  parent: { type: "data_source_id" },
  properties: { Name: { type: "title", title: [{ plain_text: `회의 ${id}` }] } },
  ...extra,
});

const MD = "<meeting-notes><summary>\n- [ ] 태오: 금요일까지 도면 역설계 결과 공유\n</summary></meeting-notes>";

function fakeClient(pages: NotionPage[][]) {
  const markdownCalls: string[] = [];
  const client: NotionClient = {
    searchPages: async (cursor) => {
      const index = cursor ? Number(cursor) : 0;
      return { pages: pages[index] ?? [], nextCursor: index + 1 < pages.length ? String(index + 1) : null };
    },
    pageMarkdown: async (id) => {
      markdownCalls.push(id);
      return { markdown: MD, truncated: false };
    },
    user: async () => null,
  };
  return { client, markdownCalls };
}

function fakeIngest(already: string[] = []) {
  const created: string[] = [];
  const deps: IngestDeps = {
    ingestedIds: async (_c, ids) => new Set(ids.filter((id) => already.includes(id))),
    insertSource: async (_c, item) => `src-${item.externalId}`,
    process: async (_c, sourceId) => void created.push(sourceId),
  };
  return { deps, created };
}

const connection = (after?: string): Connection => ({
  id: "c1",
  userId: "u1",
  provider: "notion",
  settings: {},
  syncCursor: after ? { after } : null,
});

const options = { now, lookbackDays: 14, maxScan: 100, settleMinutes: 30, maxItems: 2, minTextLength: 10 };

describe("syncNotion", () => {
  it("커서 이후 페이지 중 안정되고 새 것만 본문을 받아 넣는다", async () => {
    const { client, markdownCalls } = fakeClient([
      [page("editing", 5), page("new", 60), page("done", 90)],
      [page("trashed", 100, { in_trash: true }), page("older", 300)],
    ]);
    const { deps, created } = fakeIngest(["done"]);
    const result = await syncNotion(connection(minutesAgo(200)), client, deps, options);

    expect(markdownCalls).toEqual(["new"]);
    expect(created).toEqual(["src-new"]);
    expect(result.scanned).toBe(3); // older는 커서보다 오래돼 멈춤, trashed는 제외
    expect(result.skipped).toMatchObject({ settling: 1, alreadyIngested: 1 });
    // 막 고친 페이지를 다시 보도록 커서는 그 직전까지만 간다.
    expect(result.cursor.after).toBe(new Date(new Date(minutesAgo(5)).getTime() - 1).toISOString());
  });

  it("상한을 넘은 페이지가 있으면 커서를 그 앞에 둔다", async () => {
    const { client } = fakeClient([[page("a", 40), page("b", 50), page("c", 60)]]);
    const { deps, created } = fakeIngest();
    const result = await syncNotion(connection(minutesAgo(200)), client, deps, options);
    expect(created).toEqual(["src-c", "src-b"]);
    expect(result.skipped.overLimit).toBe(1);
    expect(result.cursor.after).toBe(new Date(new Date(minutesAgo(40)).getTime() - 1).toISOString());
  });

  it("미룬 것이 없으면 가장 최근 수정 시각까지 옮긴다", async () => {
    const { client } = fakeClient([[page("a", 40)]]);
    const result = await syncNotion(connection(minutesAgo(200)), client, fakeIngest().deps, options);
    expect(result.cursor.after).toBe(minutesAgo(40));
  });

  it("첫 동기화는 lookbackDays만큼 거슬러 본다", async () => {
    const { client, markdownCalls } = fakeClient([[page("recent", 60 * 24 * 3), page("ancient", 60 * 24 * 30)]]);
    await syncNotion(connection(), client, fakeIngest().deps, options);
    expect(markdownCalls).toEqual(["recent"]);
  });
});

describe("syncNotion 시간 한도", () => {
  it("한도를 넘기면 남은 페이지를 처리하지 않고 커서를 그 앞에 둔다", async () => {
    const { client, markdownCalls } = fakeClient([[page("a", 40), page("b", 50)]]);
    const { deps, created } = fakeIngest();
    const result = await syncNotion(connection(minutesAgo(200)), client, deps, { ...options, deadline: Date.now() - 1 });
    expect(markdownCalls).toEqual([]);
    expect(created).toEqual([]);
    expect(result.cursor.after).toBe(new Date(new Date(minutesAgo(50)).getTime() - 1).toISOString());
  });
});
