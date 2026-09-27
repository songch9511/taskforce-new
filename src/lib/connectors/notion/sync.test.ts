import { describe, expect, it } from "vitest";

import type { IngestDeps } from "../ingest";
import type { TaskItem } from "../tasks-ingest";
import type { Connection } from "../types";

import { NotionError, type NotionClient, type NotionDataSource, type NotionPage } from "./api";
import { syncNotion, type NotionTaskDeps } from "./sync";

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

function fakeClient(
  pages: NotionPage[][],
  dataSourcePages: NotionPage[] = [],
  options: { dataSourceFails?: boolean; visible?: NotionDataSource[]; unshared?: string[] } = {},
) {
  const markdownCalls: string[] = [];
  const queryCalls: { id: string; filter: unknown }[] = [];
  const client: NotionClient = {
    searchPages: async (cursor) => {
      const index = cursor ? Number(cursor) : 0;
      return { pages: pages[index] ?? [], nextCursor: index + 1 < pages.length ? String(index + 1) : null };
    },
    pageMarkdown: async (id) => {
      markdownCalls.push(id);
      return { markdown: MD, truncated: false };
    },
    user: async (id) => ({ object: "user", id, name: id === "me" ? "청혁" : "Chan", person: { email: id === "me" ? "me@x.com" : "chan@x.com" } }),
    searchDataSources: async () => options.visible ?? [],
    dataSource: async (id) => {
      if (options.dataSourceFails || options.unshared?.includes(id)) throw new NotionError("Notion API 요청 실패 (404 object_not_found)", 404, "object_not_found");
      return {
        object: "data_source",
        id,
        properties: {
          Status: {
            id: "st",
            name: "Status",
            type: "status",
            status: {
              options: [
                { id: "o1", name: "Not started" },
                { id: "o5", name: "Done" },
              ],
              groups: [],
            },
          },
        },
      };
    },
    queryDataSource: async (id, _cursor, filter) => {
      queryCalls.push({ id, filter });
      return { pages: dataSourcePages, nextCursor: null };
    },
  };
  return { client, markdownCalls, queryCalls };
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

describe("syncNotion 할 일 DB", () => {
  const settings = (backfilledAt?: string) => ({
    dataSources: {
      "ds-action": {
        role: "tasks",
        title: "Action",
        props: { title: "title", assignee: "own", due: null, status: { id: "st", type: "status" } },
        statusMap: { o1: "open", o5: "done" },
        confirmedAt: "2026-09-20T00:00:00Z",
        ...(backfilledAt ? { backfilledAt } : {}),
      },
    },
  });
  const taskPage = (id: string, editedMinutesAgo: number, owner: "me" | "chan" = "me"): NotionPage =>
    page(id, editedMinutesAgo, {
      parent: { type: "data_source_id", data_source_id: "ds-action" },
      last_edited_by: { id: "me" },
      properties: {
        Name: { id: "title", type: "title", title: [{ plain_text: `할 일 ${id}` }] },
        Own: { id: "own", type: "people", people: [{ object: "user", id: owner, name: owner, person: { email: `${owner}@x.com` } }] },
        Status: { id: "st", type: "status", status: { id: "o1", name: "Not started" } },
      },
    });

  function fakeTasks() {
    const processed: TaskItem[] = [];
    const tasks: NotionTaskDeps = {
      identity: async () => ({ name: "청혁", aliases: [], emails: ["me@x.com"] }),
      taskStates: async () => new Map(),
      insertTaskSource: async (_c, item) => `task-${item.externalId}`,
      processTask: async (_c, _s, item) => void processed.push(item),
      pendingTasks: async () => [],
    };
    return { tasks, processed };
  }

  it("확인한 할 일 DB의 페이지는 본문을 받지 않고 속성으로 넣는다", async () => {
    const { client, markdownCalls } = fakeClient([[taskPage("t1", 40), page("meeting", 60)]]);
    const { tasks, processed } = fakeTasks();
    const conn = { ...connection(minutesAgo(200)), settings: settings("2026-09-20T00:00:00Z") };
    const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);

    expect(markdownCalls).toEqual(["meeting"]);
    expect(processed.map((i) => [i.externalId, i.snapshot.owner, i.editedByUser])).toEqual([["t1", "me", true]]);
    // 글 원문으로 들어왔던 같은 페이지 버전과 겹치지 않게 할 일 버전은 task:를 붙인다 (실제 동기화에서 발견).
    expect(processed[0].externalVersion).toBe(`task:${minutesAgo(40)}`);
    expect(result.created).toEqual(["src-meeting", "task-t1"]);
    expect(result.backfilled).toEqual([]);
  });

  it("처음 켠 할 일 DB는 한 번 전체를 훑어 커서 이전의 열린 할 일도 가져온다", async () => {
    const { client, queryCalls } = fakeClient([[]], [taskPage("old", 60 * 24 * 30), taskPage("theirs", 60 * 24 * 30, "chan")]);
    const { tasks, processed } = fakeTasks();
    const conn = { ...connection(minutesAgo(200)), settings: settings() };
    const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);

    // 끝난 할 일은 받지 않는다 (상태 이름으로 거른다)
    // 60일 넘게 손대지 않은 열린 할 일도 받지 않는다 (방치된 일)
    expect(queryCalls).toEqual([
      {
        id: "ds-action",
        filter: {
          and: [
            { property: "st", status: { does_not_equal: "Done" } },
            { timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-07-27T12:00:00.000Z" } },
          ],
        },
      },
    ]);
    expect(processed.map((i) => i.externalId)).toEqual(["old"]);
    expect(result.backfilled).toEqual([{ dataSourceId: "ds-action", confirmedAt: "2026-09-20T00:00:00Z" }]);
  });

  it("공유가 끊긴 할 일 DB 하나 때문에 동기화 전체가 멈추지 않는다", async () => {
    const { client, markdownCalls } = fakeClient([[page("meeting", 60)]], [], { dataSourceFails: true });
    const { tasks } = fakeTasks();
    const conn = { ...connection(minutesAgo(200)), settings: settings() };
    const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);
    expect(markdownCalls).toEqual(["meeting"]);
    expect(result.backfilled).toEqual([]);
  });

  it("가져오지 않음으로 확인한 DB의 페이지는 건너뛴다", async () => {
    const ignored = page("goal", 60, { parent: { type: "data_source_id", data_source_id: "ds-goal" } });
    const { client, markdownCalls } = fakeClient([[ignored, page("meeting", 70)]]);
    const conn = {
      ...connection(minutesAgo(200)),
      settings: { dataSources: { "ds-goal": { role: "ignore", title: "Goal", confirmedAt: "2026-09-20T00:00:00Z" } } },
    };
    await syncNotion(conn, client, fakeIngest().deps, options);
    expect(markdownCalls).toEqual(["meeting"]);
  });

  it("막 고친 할 일 페이지는 커서를 그 앞에 둔다", async () => {
    const { client } = fakeClient([[taskPage("t1", 2)]]);
    const conn = { ...connection(minutesAgo(200)), settings: settings("2026-09-20T00:00:00Z") };
    const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks: fakeTasks().tasks }, options);
    expect(result.tasks?.skipped.settling).toBe(1);
    expect(result.cursor.after).toBe(new Date(new Date(minutesAgo(2)).getTime() - 1).toISOString());
  });

  it("확인하지 않은 할 일 DB는 지금처럼 글 원문으로 읽는다", async () => {
    const { client, markdownCalls } = fakeClient([[taskPage("t1", 40)]]);
    const unconfirmed = { dataSources: { "ds-action": { ...settings().dataSources["ds-action"], confirmedAt: undefined } } };
    const { tasks, processed } = fakeTasks();
    await syncNotion({ ...connection(minutesAgo(200)), settings: unconfirmed }, client, { ...fakeIngest().deps, tasks }, options);
    expect(markdownCalls).toEqual(["t1"]);
    expect(processed).toEqual([]);
  });
});

describe("syncNotion: 확인 전 DB와 공유 상태", () => {
  const ds = (id: string, title: string): NotionDataSource => ({ object: "data_source", id, title: [{ plain_text: title }], properties: {} });
  const inDb = (id: string, dataSourceId: string, minutes: number) => page(id, minutes, { parent: { type: "data_source_id", data_source_id: dataSourceId } });

  it("확인 전 DB도 글 원문으로 읽고(이름으로 회의록을 못 알아봐도 끊기지 않게), 처음 본 DB는 알려준다", async () => {
    const { client, markdownCalls } = fakeClient([[inDb("m1", "ds-weekly", 40), inDb("g1", "ds-goal", 50), page("loose", 60)]], [], {
      visible: [ds("ds-weekly", "Weekly"), ds("ds-goal", "Goal")],
    });
    const conn = { ...connection(minutesAgo(200)), settings: { dataSources: { "ds-goal": { role: "text", title: "Goal", seenAt: "2026-09-20T00:00:00Z" } } } };
    const result = await syncNotion(conn, client, fakeIngest().deps, { ...options, maxItems: 5 });
    expect(markdownCalls.sort()).toEqual(["g1", "loose", "m1"]);
    // 이미 남긴 DB는 다시 알리지 않는다
    expect(result.seen).toEqual([{ id: "ds-weekly", title: "Weekly", role: "text" }]);
  });

  it("새로 공유된 DB가 있으면 이번만 최근 기간을 다시 훑는다 (공유가 끊겨 있던 동안의 회의록을 놓치지 않게)", async () => {
    const old = inDb("m-old", "ds-meeting", 60 * 24 * 3); // 커서보다 오래됐지만 14일 안
    const known = { ...connection(minutesAgo(60)), settings: { dataSources: { "ds-meeting": { role: "text", title: "Meeting", seenAt: "2026-09-20T00:00:00Z" } } } };

    const first = fakeClient([[old]], [], { visible: [ds("ds-meeting", "Meeting")] });
    const rewound = await syncNotion(connection(minutesAgo(60)), first.client, fakeIngest().deps, options);
    expect(rewound.rewound).toBe(true);
    expect(first.markdownCalls).toEqual(["m-old"]);

    // 이미 아는 DB뿐이면 커서대로
    const second = fakeClient([[old]], [], { visible: [ds("ds-meeting", "Meeting")] });
    const normal = await syncNotion(known, second.client, fakeIngest().deps, options);
    expect(normal.rewound).toBe(false);
    expect(second.markdownCalls).toEqual([]);

    // 공유가 끊겼다가 되돌아온 DB도 다시 훑는다
    const recovered = { ...known, settings: { ...known.settings, health: { unreachable: [{ id: "ds-meeting", title: "Meeting" }], checkedAt: "2026-09-26T00:00:00Z" } } };
    const third = fakeClient([[old]], [], { visible: [ds("ds-meeting", "Meeting")] });
    expect((await syncNotion(recovered, third.client, fakeIngest().deps, options)).rewound).toBe(true);
    expect(third.markdownCalls).toEqual(["m-old"]);
  });

  it("데이터베이스 목록을 못 받아도 동기화는 계속하고, 공유 상태는 이번엔 판단하지 않는다", async () => {
    const { client, markdownCalls } = fakeClient([[page("loose", 60)]]);
    client.searchDataSources = async () => {
      throw new NotionError("Notion API 요청 실패 (502)", 502, "bad_gateway");
    };
    const conn = { ...connection(minutesAgo(200)), settings: { dataSources: { "ds-old": { role: "text", title: "Old", seenAt: "2026-09-20T00:00:00Z" } } } };
    const result = await syncNotion(conn, client, fakeIngest().deps, options);
    expect(markdownCalls).toEqual(["loose"]);
    expect(result.unreachable).toBeNull();
  });

  it("일시적인 오류로 DB를 확인하지 못하면 끊겼다고 하지 않는다 (지난 결과를 둔다)", async () => {
    const { client } = fakeClient([[]], [], { visible: [] });
    client.dataSource = async () => {
      throw new NotionError("Notion API 요청 실패 (429)", 429, "rate_limited");
    };
    const conn = { ...connection(minutesAgo(200)), settings: { dataSources: { "ds-old": { role: "text", title: "Old", seenAt: "2026-09-20T00:00:00Z" } } } };
    const result = await syncNotion(conn, client, fakeIngest().deps, options);
    expect(result.unreachable).toBeNull();
  });

  it("전에 읽던 DB의 공유가 끊기면 알려준다 (가져오지 않음으로 둔 DB는 빼고)", async () => {
    const { client } = fakeClient([[]], [], { visible: [ds("ds-meeting", "Meeting")], unshared: ["ds-old", "ds-ignored"] });
    const conn = {
      ...connection(minutesAgo(200)),
      settings: {
        dataSources: {
          "ds-meeting": { role: "text", title: "Meeting", seenAt: "2026-09-20T00:00:00Z" },
          "ds-old": { role: "text", title: "Old meetings", seenAt: "2026-09-20T00:00:00Z" },
          "ds-ignored": { role: "ignore", title: "Goal", confirmedAt: "2026-09-20T00:00:00Z" },
        },
      },
    };
    const result = await syncNotion(conn, client, fakeIngest().deps, options);
    expect(result.unreachable).toEqual([{ id: "ds-old", title: "Old meetings" }]);
  });
});
