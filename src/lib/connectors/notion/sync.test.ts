import { describe, expect, it, vi } from "vitest";

import type { MeetingEventLookup } from "../google/lookup";
import type { IngestDeps } from "../ingest";
import type { TaskItem } from "../tasks-ingest";
import type { Connection, IngestItem } from "../types";

import { NotionError, type NotionClient, type NotionDataSource, type NotionPage } from "./api";
import { settingsWithoutNotionUserId, syncNotion, type NotionTaskDeps } from "./sync";

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
  options: { dataSourceFails?: boolean; visible?: NotionDataSource[]; unshared?: string[]; markdown?: string; owner?: string | Error } = {},
) {
  const markdownCalls: string[] = [];
  const queryCalls: { id: string; filter: unknown }[] = [];
  let ownerCalls = 0;
  const client: NotionClient = {
    searchPages: async (cursor) => {
      const index = cursor ? Number(cursor) : 0;
      return { pages: pages[index] ?? [], nextCursor: index + 1 < pages.length ? String(index + 1) : null };
    },
    pageMarkdown: async (id) => {
      markdownCalls.push(id);
      return { markdown: options.markdown ?? MD, truncated: false };
    },
    page: async () => null,
    botOwnerId: async () => {
      ownerCalls++;
      if (options.owner instanceof Error) throw options.owner;
      return options.owner ?? null;
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
  return { client, markdownCalls, queryCalls, ownerCalls: () => ownerCalls };
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
  const taskPage = (id: string, editedMinutesAgo: number, owner = "me"): NotionPage =>
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

  it("담당이 연결한 사람이면 내 할 일로 넣고, 다른 사람 담당은 넣지 않는다 (연결한 사람을 모르면 봇 주인으로 알아낸다)", async () => {
    const { client, ownerCalls } = fakeClient([[taskPage("mine", 40, "notion-me"), taskPage("theirs", 50, "chan")]], [], { owner: "notion-me" });
    const { tasks, processed } = fakeTasks();
    const conn = { ...connection(minutesAgo(200)), settings: settings("2026-09-20T00:00:00Z") };
    const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);
    // 이메일(notion-me@x.com) · 이름이 프로필과 달라도 연결한 사람이 담당이면 내 할 일
    expect(processed.map((i) => [i.externalId, i.snapshot.owner])).toEqual([["mine", "me"]]);
    expect(result.tasks?.skipped.notMine).toBe(1);
    expect(ownerCalls()).toBe(1);
    expect(result.notionUserId).toBe("notion-me");
  });

  it("고친 사람: 연결한 사람을 알면 다른 id는 이름이 같아도 사용자가 아니다 (이메일이 맞을 때만). 모르면 이름으로도 알아본다", async () => {
    const editedBy = (id: string, editor: string, owner: string) => ({ ...taskPage(id, 40, owner), last_edited_by: { id: editor } });
    // 모든 사람의 이름이 사용자와 같다. 이메일은 id "me"만 프로필과 같다.
    const namesakes = (client: NotionClient) => {
      client.user = async (id) => ({ object: "user", id, name: "청혁", person: { email: id === "me" ? "me@x.com" : `${id}@other.com` } });
    };
    const editors = (items: TaskItem[]) => Object.fromEntries(items.map((i) => [i.externalId, i.editedByUser]));

    const known = fakeClient([[editedBy("by-namesake", "namesake", "notion-me"), editedBy("by-email", "me", "notion-me"), editedBy("by-me", "notion-me", "notion-me")]]);
    namesakes(known.client);
    const first = fakeTasks();
    const conn = { ...connection(minutesAgo(200)), settings: { ...settings("2026-09-20T00:00:00Z"), notionUserId: "notion-me" } };
    await syncNotion(conn, known.client, { ...fakeIngest().deps, tasks: first.tasks }, options);
    expect(editors(first.processed)).toEqual({ "by-namesake": false, "by-email": true, "by-me": true });

    const unknown = fakeClient([[editedBy("by-namesake", "namesake", "me")]]);
    namesakes(unknown.client);
    const second = fakeTasks();
    await syncNotion({ ...connection(minutesAgo(200)), settings: settings("2026-09-20T00:00:00Z") }, unknown.client, { ...fakeIngest().deps, tasks: second.tasks }, options);
    expect(editors(second.processed)).toEqual({ "by-namesake": true });
  });

  it("담당: 연결한 사람을 알면 이름만 같은 다른 사람의 할 일은 넣지 않는다", async () => {
    const namesake: NotionPage = {
      ...taskPage("namesake", 40),
      properties: { ...taskPage("namesake", 40).properties, Own: { id: "own", type: "people", people: [{ object: "user", id: "other-id", name: "청혁" }] } },
    };
    const { client } = fakeClient([[namesake]]);
    const { tasks, processed } = fakeTasks();
    const conn = { ...connection(minutesAgo(200)), settings: { ...settings("2026-09-20T00:00:00Z"), notionUserId: "notion-me" } };
    const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);
    expect(processed).toEqual([]);
    expect(result.tasks?.skipped.notMine).toBe(1);
  });
});

describe("syncNotion: 할 일 DB 자동 확인", () => {
  const ACTION_DB: NotionDataSource = {
    object: "data_source",
    id: "ds-action",
    title: [{ plain_text: "Action" }],
    properties: {
      Name: { id: "title", name: "Name", type: "title" },
      Owner: { id: "own", name: "Owner", type: "people" },
      Status: {
        id: "st",
        name: "Status",
        type: "status",
        status: {
          options: [
            { id: "o1", name: "Not started" },
            { id: "o5", name: "Done" },
          ],
          groups: [
            { name: "To-do", option_ids: ["o1"] },
            { name: "Complete", option_ids: ["o5"] },
          ],
        },
      },
    },
  };
  const taskPage = (id: string, editedMinutesAgo: number): NotionPage =>
    page(id, editedMinutesAgo, {
      parent: { type: "data_source_id", data_source_id: "ds-action" },
      last_edited_by: { id: "me" },
      properties: {
        Name: { id: "title", type: "title", title: [{ plain_text: `할 일 ${id}` }] },
        Own: { id: "own", type: "people", people: [{ object: "user", id: "me", name: "청혁", person: { email: "me@x.com" } }] },
        Status: { id: "st", type: "status", status: { id: "o1", name: "Not started" } },
      },
    });
  const tasksDeps = () => {
    const processed: TaskItem[] = [];
    const tasks: NotionTaskDeps = {
      identity: async () => ({ name: "청혁", aliases: [], emails: ["me@x.com"] }),
      taskStates: async () => new Map(),
      insertTaskSource: async (_c, item) => `task-${item.externalId}`,
      processTask: async (_c, _s, item) => void processed.push(item),
      pendingTasks: async () => [],
    };
    return { tasks, processed };
  };
  // 실제 연결에서 본 모양: 동기화가 할 일 DB로 제안해 남겼지만(seenAt) 아무도 확인하지 않음
  const seenOnly = { dataSources: { "ds-action": { role: "tasks", title: "Action", seenAt: "2026-09-20T00:00:00Z" } } };

  it("매핑이 분명하면 자동 확인해 이번 동기화부터 할 일로 읽고(글 원문으로 또 넣지 않음), 처음 훑기로 열린 할 일을 가져온다", async () => {
    const { client, markdownCalls, queryCalls } = fakeClient([[taskPage("t1", 40), page("meeting", 60)]], [taskPage("old", 60 * 24 * 30)], {
      visible: [ACTION_DB],
    });
    const { tasks, processed } = tasksDeps();
    const conn = { ...connection(minutesAgo(200)), settings: seenOnly };
    const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);

    expect(markdownCalls).toEqual(["meeting"]);
    expect(processed.map((i) => i.externalId).sort()).toEqual(["old", "t1"]);
    expect(queryCalls.map((q) => q.id)).toEqual(["ds-action"]);
    const confirmedAt = now.toISOString();
    expect(result.autoConfirmed).toEqual([
      {
        id: "ds-action",
        setting: {
          role: "tasks",
          title: "Action",
          props: { title: "title", assignee: "own", due: null, status: { id: "st", type: "status" } },
          statusMap: { o1: "open", o5: "done" },
          confirmedAt,
          confirmedBy: "auto",
          seenAt: "2026-09-20T00:00:00Z",
        },
      },
    ]);
    // 처음 훑기 표시는 자동 확인 시각과 맞춘다 (markBackfilled가 저장된 confirmedAt과 비교한다)
    expect(result.backfilled).toEqual([{ dataSourceId: "ds-action", confirmedAt }]);
  });

  it("사용자가 확인한 역할(글 원문 · 가져오지 않음)은 바꾸지 않는다", async () => {
    for (const role of ["text", "ignore"] as const) {
      const { client, markdownCalls } = fakeClient([[taskPage("t1", 40)]], [], { visible: [ACTION_DB] });
      const { tasks, processed } = tasksDeps();
      const conn = { ...connection(minutesAgo(200)), settings: { dataSources: { "ds-action": { role, title: "Action", confirmedAt: "2026-09-20T00:00:00Z" } } } };
      const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);
      expect(result.autoConfirmed, role).toEqual([]);
      expect(processed, role).toEqual([]);
      expect(markdownCalls, role).toEqual(role === "text" ? ["t1"] : []);
    }
  });

  it("매핑이 애매하면 자동 확인하지 않고 지금처럼 글 원문으로 읽는다", async () => {
    const ambiguous: NotionDataSource = {
      ...ACTION_DB,
      properties: { ...ACTION_DB.properties, Reviewer: { id: "own2", name: "담당 리뷰어", type: "people" }, Lead: { id: "own3", name: "Owner (lead)", type: "people" } },
    };
    const { client, markdownCalls } = fakeClient([[taskPage("t1", 40)]], [], { visible: [ambiguous] });
    const { tasks, processed } = tasksDeps();
    const result = await syncNotion({ ...connection(minutesAgo(200)), settings: seenOnly }, client, { ...fakeIngest().deps, tasks }, options);
    expect(result.autoConfirmed).toEqual([]);
    expect(markdownCalls).toEqual(["t1"]);
    expect(processed).toEqual([]);
  });

  describe("자동 확인한 DB를 지금 규칙으로 다시 본다", () => {
    // 실제 연결에서 본 모양: 규칙을 좁히기 전에 담당 속성 "Person"으로 자동 확인된 회의 액션 아이템 DB (남의 일이 내 할 일로 들어왔다)
    const PERSON_DB: NotionDataSource = {
      ...ACTION_DB,
      properties: { Name: ACTION_DB.properties.Name, Person: { id: "per", name: "Person", type: "people" }, Status: ACTION_DB.properties.Status },
    };
    const personSetting = (extra: Record<string, unknown> = {}) => ({
      role: "tasks",
      title: "Action",
      props: { title: "title", assignee: "per", due: null, status: { id: "st", type: "status" } },
      statusMap: { o1: "open", o5: "done" },
      confirmedAt: "2026-09-21T00:00:00Z",
      seenAt: "2026-09-20T00:00:00Z",
      ...extra,
    });
    const personPage = (id: string, editedMinutesAgo: number): NotionPage => {
      const base = taskPage(id, editedMinutesAgo);
      return { ...base, properties: { ...base.properties, Person: { id: "per", type: "people", people: [{ object: "user", id: "me", name: "청혁", person: { email: "me@x.com" } }] } } };
    };

    it("더는 맞지 않으면(담당 속성 Person) 확인 전으로 되돌려 이번 동기화부터 할 일로 읽지 않고(처음 훑기도 하지 않음), 사용자 데이터 없이 로그를 남긴다", async () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
      try {
        const { client, markdownCalls, queryCalls } = fakeClient([[personPage("t1", 40)]], [personPage("old", 60 * 24 * 3)], { visible: [PERSON_DB] });
        const { tasks, processed } = tasksDeps();
        // 처음 훑기를 아직 마치지 못한 상태: 되돌리지 않으면 이번 동기화가 다시 훑는다
        const conn = { ...connection(minutesAgo(200)), settings: { dataSources: { "ds-action": personSetting({ confirmedBy: "auto" }) } } };
        const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);

        expect(result.reverted).toEqual([{ id: "ds-action", setting: { role: "tasks", title: "Action", seenAt: "2026-09-20T00:00:00Z" } }]);
        expect(result.autoConfirmed).toEqual([]);
        // 확인 전 할 일 DB처럼 글 원문으로 읽는다
        expect(markdownCalls).toEqual(["t1"]);
        expect(processed).toEqual([]);
        expect(queryCalls).toEqual([]);
        expect(result.backfilled).toEqual([]);
        expect(warn).toHaveBeenCalledWith(expect.stringContaining("(c1): 1개"));
        expect(JSON.stringify(warn.mock.calls)).not.toContain("Action");
      } finally {
        warn.mockRestore();
      }
    });

    it("사용자가 확인한 DB는 담당 속성이 Person이어도 그대로 할 일로 읽는다", async () => {
      const { client, markdownCalls } = fakeClient([[personPage("t1", 40)]], [], { visible: [PERSON_DB] });
      const { tasks, processed } = tasksDeps();
      const conn = { ...connection(minutesAgo(200)), settings: { dataSources: { "ds-action": personSetting({ backfilledAt: "2026-09-21T00:00:00Z" }) } } };
      const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);
      expect(result.reverted).toEqual([]);
      expect(result.autoConfirmed).toEqual([]);
      expect(markdownCalls).toEqual([]);
      expect(processed.map((i) => [i.externalId, i.snapshot.owner])).toEqual([["t1", "me"]]);
    });

    it("아직 맞는 자동 확인은 그대로 둔다 (다시 확인 · 처음 훑기 없이 할 일로 읽는다)", async () => {
      const { client, markdownCalls, queryCalls } = fakeClient([[taskPage("t1", 40)]], [], { visible: [ACTION_DB] });
      const { tasks, processed } = tasksDeps();
      const saved = {
        role: "tasks",
        title: "Action",
        props: { title: "title", assignee: "own", due: null, status: { id: "st", type: "status" } },
        statusMap: { o5: "done", o1: "open" },
        confirmedAt: "2026-09-21T00:00:00Z",
        confirmedBy: "auto",
        backfilledAt: "2026-09-21T00:00:00Z",
      };
      const conn = { ...connection(minutesAgo(200)), settings: { dataSources: { "ds-action": saved } } };
      const result = await syncNotion(conn, client, { ...fakeIngest().deps, tasks }, options);
      expect(result.reverted).toEqual([]);
      expect(result.autoConfirmed).toEqual([]);
      expect(markdownCalls).toEqual([]);
      expect(queryCalls).toEqual([]);
      expect(processed.map((i) => i.externalId)).toEqual(["t1"]);
    });
  });

  it("연결 설정을 읽지 못하면 이번에는 자동 확인하지 않고(사용자가 정한 역할을 모른다), 설정 내용 없이 로그만 남긴다", async () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined);
    try {
      const { client } = fakeClient([[taskPage("t1", 40)]], [], { visible: [ACTION_DB] });
      const { tasks, processed } = tasksDeps();
      const broken = { dataSources: { "ds-action": { role: "ignore", title: "비밀 프로젝트", confirmedAt: 42 } } };
      const result = await syncNotion({ ...connection(minutesAgo(200)), settings: broken }, client, { ...fakeIngest().deps, tasks }, options);
      expect(result.autoConfirmed).toEqual([]);
      expect(processed).toEqual([]);
      expect(errors).toHaveBeenCalledWith(expect.stringContaining("자동 확인하지 않습니다"));
      expect(JSON.stringify(errors.mock.calls)).not.toContain("비밀 프로젝트");
    } finally {
      errors.mockRestore();
    }
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

describe("syncNotion: 사용자가 쓴 문서", () => {
  const DOC_MD = "## 다음 단계\n- 도메인 연결 설정 바꾸기\n- 수요일까지 케이스 스터디 정리";
  const doc = (id: string, createdBy: string) =>
    page(id, 60, { created_by: { id: createdBy }, properties: { Name: { type: "title", title: [{ plain_text: `사이트 개편 ${id}` }] } } });
  const capture = () => {
    const items: IngestItem[] = [];
    const deps: IngestDeps = {
      ingestedIds: async () => new Set(),
      insertSource: async (_c, item) => {
        items.push(item);
        return `src-${item.externalId}`;
      },
      process: async () => undefined,
    };
    return { deps, items };
  };
  const writtenByMe = (items: IngestItem[]) => Object.fromEntries(items.map((i) => [i.externalId, i.writtenByMe]));

  it("만든 사람이 연결 설정에 남긴 연결한 사람이면 사용자가 쓴 문서로 넣는다 (봇 주인을 다시 묻지 않는다)", async () => {
    const { client, ownerCalls } = fakeClient([[doc("mine", "notion-me"), doc("theirs", "notion-other")]], [], { markdown: DOC_MD, owner: "notion-me" });
    const { deps, items } = capture();
    const result = await syncNotion({ ...connection(minutesAgo(200)), settings: { notionUserId: "notion-me" } }, client, deps, options);
    expect(writtenByMe(items)).toEqual({ mine: true, theirs: false });
    expect(ownerCalls()).toBe(0);
    expect(result.notionUserId).toBe("notion-me");
  });

  it("설정에 없으면 봇 주인으로 알아내고 결과로 돌려준다 (연결 설정에 남기도록)", async () => {
    const { client, ownerCalls } = fakeClient([[doc("mine", "notion-me")]], [], { markdown: DOC_MD, owner: "notion-me" });
    const { deps, items } = capture();
    const result = await syncNotion(connection(minutesAgo(200)), client, deps, options);
    expect(writtenByMe(items)).toEqual({ mine: true });
    expect(ownerCalls()).toBe(1);
    expect(result.notionUserId).toBe("notion-me");
  });

  it("회의록은 사용자가 만들었어도 모름(null)으로 넣는다", async () => {
    const { client } = fakeClient([[page("meeting", 60, { created_by: { id: "notion-me" } })]], [], { owner: "notion-me" });
    const { deps, items } = capture();
    await syncNotion(connection(minutesAgo(200)), client, deps, options);
    expect(items.map((i) => [i.kind, i.writtenByMe])).toEqual([["meeting", null]]);
  });

  it("연결한 사람을 알 수 없으면 작성자를 모름으로 두고 동기화는 계속한다", async () => {
    const { client } = fakeClient([[doc("mine", "notion-me")]], [], { markdown: DOC_MD, owner: new NotionError("Notion API 요청 실패 (500)", 500) });
    const { deps, items } = capture();
    const result = await syncNotion(connection(minutesAgo(200)), client, deps, options);
    expect(writtenByMe(items)).toEqual({ mine: null });
    expect(result.notionUserId).toBeNull();
  });

  it("권한이 끊겼으면(401) 그대로 올려 토큰을 갱신하게 한다", async () => {
    const { client } = fakeClient([[doc("mine", "notion-me")]], [], { markdown: DOC_MD, owner: new NotionError("Notion API 요청 실패 (401)", 401) });
    await expect(syncNotion(connection(minutesAgo(200)), client, capture().deps, options)).rejects.toThrow("401");
  });

  it("새로 넣을 글 원문이 없으면 봇 주인을 묻지 않는다", async () => {
    const { client, ownerCalls } = fakeClient([[doc("editing", "notion-me")].map((p) => ({ ...p, last_edited_time: minutesAgo(5) }))], [], { owner: "notion-me" });
    const result = await syncNotion(connection(minutesAgo(200)), client, capture().deps, options);
    expect(ownerCalls()).toBe(0);
    expect(result.notionUserId).toBeNull();
  });

  it("다시 연결하면(saveConnection) 남겨 둔 연결한 사람을 지우고, 다음 동기화가 새 봇 주인으로 다시 알아낸다", async () => {
    // 같은 워크스페이스를 다른 Notion 계정으로 다시 연결: 연결 행 · 다른 설정은 그대로, notionUserId만 빠진다.
    const settings = settingsWithoutNotionUserId({ notionUserId: "notion-old", dataSources: {} });
    expect(settings).toEqual({ dataSources: {} });
    // 뺄 것이 없으면 쓰지 않는다.
    expect(settingsWithoutNotionUserId({ dataSources: {} })).toBeNull();
    expect(settingsWithoutNotionUserId(null)).toBeNull();

    const { client, ownerCalls } = fakeClient([[doc("mine", "notion-new"), doc("theirs", "notion-old")]], [], { markdown: DOC_MD, owner: "notion-new" });
    const { deps, items } = capture();
    const result = await syncNotion({ ...connection(minutesAgo(200)), settings: settings! }, client, deps, options);
    expect(ownerCalls()).toBe(1);
    expect(writtenByMe(items)).toEqual({ mine: true, theirs: false });
    expect(result.notionUserId).toBe("notion-new");
  });
});

// 회의록에 같은 회의의 Calendar 일정 붙이기 (google-integration.md 2-2 notion/sync.ts · 2-4 · G3 · G4)
describe("syncNotion: 회의록에 Calendar 일정 붙이기", () => {
  const capture = () => {
    const items: IngestItem[] = [];
    const deps: IngestDeps = {
      ingestedIds: async () => new Set(),
      insertSource: async (_c, item) => {
        items.push(item);
        return `src-${item.externalId}`;
      },
      process: async () => undefined,
    };
    return { deps, items };
  };
  const byId = (items: IngestItem[]) => Object.fromEntries(items.map((i) => [i.externalId, i]));
  /** 회의 날짜 속성이 없는 회의록: 날짜는 페이지를 만든 날(한국 시간) */
  const meeting = (id: string, editedMinutesAgo = 60) =>
    page(id, editedMinutesAgo, {
      properties: {
        Name: { type: "title", title: [{ plain_text: `Proposal review ${id}` }] },
        Attendees: { type: "people", people: [{ object: "user", id: `u-${id}`, name: "Jordan Lee", person: { email: "jordan@harborline.example" } }] },
      },
    });
  const EVENT = {
    calendarEventId: "evt-1",
    title: "Proposal review — Acme",
    start: "2026-09-25T02:00:00.000Z",
    end: "2026-09-25T03:00:00.000Z",
    attendees: [
      { name: "Alex Kim", email: "alex@lumenfield.example" },
      { name: "Jordan Lee", email: "jordan@harborline.example" },
      { name: "Noah Patel", email: "noah@lumenfield.example" },
    ],
  };
  const attached = { result: "attached" as const, event: EVENT };

  it("일정을 찾으면 관련자에 일정 참석자를 합치고(이메일이 같은 사람은 하나로) meeting을 붙인다", async () => {
    const { client } = fakeClient([[meeting("a")]]);
    const { deps, items } = capture();
    const meetingEvent = vi.fn(async () => attached);

    const result = await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent }, options);

    expect(items[0].participants).toEqual({
      attendees: [
        { name: "Alex Kim", email: "alex@lumenfield.example" },
        { name: "Jordan Lee", email: "jordan@harborline.example" },
        { name: "Noah Patel", email: "noah@lumenfield.example" },
      ],
    });
    expect(items[0].meeting).toEqual({ calendar_event_id: "evt-1", title: "Proposal review — Acme", start: EVENT.start, end: EVENT.end });
    // 찾을 것: 회의 날짜(한국 날짜) · 페이지를 만든 시각 · 제목 · 만든 사람이 연결한 사용자인가 (연결한 Notion 계정을 알아내지 못했으면 아니다)
    expect(meetingEvent).toHaveBeenCalledWith({ day: "2026-09-25", createdAt: new Date(minutesAgo(120)), title: "Proposal review a", createdByUser: false });
    expect(result.meetingLinks).toEqual({ attached: 1, ambiguous: 0, none: 0, failed: 0 });
  });

  it("페이지를 만든 사람이 연결한 Notion 계정이면 createdByUser, 다른 사람이거나 모르면 아니다 (시각만으로 일정을 고르는 길의 조건)", async () => {
    const created = (id: string, by?: string) => ({ ...meeting(id), ...(by ? { created_by: { id: by } } : {}) });
    const { client } = fakeClient([[created("mine", "notion-me"), created("theirs", "notion-other"), created("unknown")]], [], { owner: "notion-me" });
    const { deps } = capture();
    const meetingEvent = vi.fn<MeetingEventLookup>(async () => ({ result: "none" }));

    await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent }, { ...options, maxItems: 3 });

    const createdByUser = Object.fromEntries(meetingEvent.mock.calls.map(([target]) => [target.title, target.createdByUser]));
    expect(createdByUser).toEqual({ "Proposal review mine": true, "Proposal review theirs": false, "Proposal review unknown": false });
  });

  it("일정이 없으면 Notion 관련자 그대로, 애매해도 잇지 않는다: 결과만 센다", async () => {
    const { client } = fakeClient([[meeting("a", 60), meeting("b", 70), meeting("c", 80)]]);
    const { deps, items } = capture();
    const answers = [{ result: "none" as const }, { result: "ambiguous" as const }, attached];
    const meetingEvent = vi.fn(async () => answers.shift()!);

    const result = await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent }, { ...options, maxItems: 3 });

    const found = byId(items);
    // 오래된 것부터 넣는다: c(80분 전) → b → a
    expect(meetingEvent).toHaveBeenCalledTimes(3);
    expect(found.c.meeting).toBeUndefined();
    expect(found.c.participants).toEqual({ attendees: [{ name: "Jordan Lee", email: "jordan@harborline.example" }] });
    expect(found.b.meeting).toBeUndefined();
    expect(found.a.meeting?.calendar_event_id).toBe("evt-1");
    expect(result.meetingLinks).toEqual({ attached: 1, ambiguous: 1, none: 1, failed: 0 });
  });

  it("Notion 사람 속성이 없는 회의록도 일정 참석자만으로 관련자가 생긴다", async () => {
    const { client } = fakeClient([[page("bare", 60)]]);
    const { deps, items } = capture();
    await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent: async () => attached }, options);
    expect(items[0].participants?.attendees).toEqual(EVENT.attendees);
  });

  it("조회 함수를 주지 않으면(google 연결 없음) 부르지 않고 결과도 없다", async () => {
    const { client } = fakeClient([[meeting("a")]]);
    const { deps, items } = capture();
    const result = await syncNotion(connection(minutesAgo(200)), client, deps, options);
    expect(items[0].meeting).toBeUndefined();
    expect(result.meetingLinks).toBeUndefined();
  });

  it("회의록이 아닌 글(doc)에는 붙이지 않는다", async () => {
    const memo = page("memo", 60, { properties: { Name: { type: "title", title: [{ plain_text: "사이트 개편 메모" }] } } });
    const { client } = fakeClient([[memo]], [], { markdown: "## 다음 단계\n- 도메인 연결 설정 바꾸기\n- 수요일까지 케이스 스터디 정리" });
    const { deps, items } = capture();
    const meetingEvent = vi.fn(async () => attached);
    const result = await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent }, options);
    expect(items[0].kind).toBe("doc");
    expect(meetingEvent).not.toHaveBeenCalled();
    expect(result.meetingLinks).toEqual({ attached: 0, ambiguous: 0, none: 0, failed: 0 });
  });

  it("Google이 한 번 실패하면 남은 회의록에는 붙이지 않고 그대로 넣는다: Notion 동기화를 막지 않는다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { client } = fakeClient([[meeting("a", 60), meeting("b", 70), meeting("c", 80)]]);
    const { deps, items } = capture();
    const meetingEvent = vi.fn(async () => {
      throw new Error("Calendar 요청 실패 (503)");
    });

    const result = await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent }, { ...options, maxItems: 3 });

    expect(meetingEvent).toHaveBeenCalledTimes(1);
    expect(items).toHaveLength(3);
    expect(items.every((i) => i.meeting === undefined)).toBe(true);
    expect(result.meetingLinks).toEqual({ attached: 0, ambiguous: 0, none: 0, failed: 1 });
    expect(result.created).toHaveLength(3);
    vi.restoreAllMocks();
  });

  it("조회 한 번이 제한(기본 5초)을 넘으면 실패로 보고 그 동기화의 나머지는 붙이지 않는다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { client } = fakeClient([[meeting("a", 60), meeting("b", 70)]]);
    const { deps, items } = capture();
    const meetingEvent = vi.fn(() => new Promise<never>(() => {}));

    const result = await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent }, { ...options, meetingEventTimeoutMs: 20 });

    expect(meetingEvent).toHaveBeenCalledTimes(1);
    expect(items).toHaveLength(2);
    expect(result.meetingLinks?.failed).toBe(1);
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).toMatch(/시간 초과/);
    vi.restoreAllMocks();
  });

  it("조회 시간의 합계에도 상한이 있다 (기본 15초): 한 번이 5초 안이라도 회의록이 많으면 남은 회의록에는 붙이지 않는다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { client } = fakeClient([[meeting("a", 60), meeting("b", 70), meeting("c", 80), meeting("d", 90)]]);
    const { deps, items } = capture();
    const meetingEvent = vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, 25));
      return attached;
    });

    const result = await syncNotion(connection(minutesAgo(200)), client, { ...deps, meetingEvent }, { ...options, maxItems: 4, meetingEventTotalMs: 40 });

    // 25ms + 25ms = 50ms > 40ms → 두 번 조회한 뒤 멈춘다. 실패가 아니므로 failed는 세지 않는다
    expect(meetingEvent).toHaveBeenCalledTimes(2);
    expect(items).toHaveLength(4);
    expect(items.filter((i) => i.meeting).length).toBe(2);
    expect(result.meetingLinks).toEqual({ attached: 2, ambiguous: 0, none: 0, failed: 0 });
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).toContain("시간 상한");
    vi.restoreAllMocks();
  });

  it("실패를 로그에 남길 때 오류 메시지만 남긴다 (일정 제목 · 참석자 없음)", async () => {
    const spy = vi.spyOn(console, "error").mockImplementation(() => {});
    const { client } = fakeClient([[meeting("a")]]);
    await syncNotion(connection(minutesAgo(200)), client, { ...capture().deps, meetingEvent: async () => Promise.reject(new Error("Calendar 요청 실패 (403 rateLimitExceeded)")) }, options);
    expect(JSON.stringify(spy.mock.calls)).toContain("Calendar 요청 실패 (403 rateLimitExceeded)");
    expect(JSON.stringify(spy.mock.calls)).not.toMatch(/Jordan|harborline|Proposal/);
    vi.restoreAllMocks();
  });
});
