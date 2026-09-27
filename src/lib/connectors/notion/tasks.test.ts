import { describe, expect, it } from "vitest";

import { connectionSettingsSchema, type DataSourceSetting, type TaskPropertyMap } from "@/lib/api/contract";

import type { NotionDataSource, NotionPage } from "./api";
import { defaultStatusMap, detectProps, dueDate, isActiveTaskSource, openTasksFilter, pageSnapshot, suggestSetting, validateSetting } from "./tasks";

// 실제 워크스페이스에서 본 모양을 줄인 것: 할 일 DB(Action), 회의 DB(Owner · Status · Date가 함께 있음), 목표 DB
const statusProp = (id: string, name: string, groups: [string, [string, string][]][]) => ({
  id,
  name,
  type: "status",
  status: {
    options: groups.flatMap(([, options]) => options.map(([oid, oname]) => ({ id: oid, name: oname }))),
    groups: groups.map(([group, options]) => ({ name: group, option_ids: options.map(([oid]) => oid) })),
  },
});

const ACTION_DB: NotionDataSource = {
  object: "data_source",
  id: "ds-action",
  title: [{ plain_text: "Action" }],
  properties: {
    Name: { id: "title", name: "Name", type: "title" },
    Owner: { id: "own", name: "Owner", type: "people" },
    Date: { id: "dt", name: "Date", type: "date" },
    Scope: { id: "sc", name: "Scope", type: "select" },
    Status: statusProp("st", "Status", [
      ["To-do", [["o1", "Not started"], ["o2", "Next"]]],
      ["In progress", [["o3", "Current"], ["o4", "Blocked"]]],
      ["Complete", [["o5", "Done"], ["o6", "Archived"]]],
    ]),
  },
};

const MEETING_DB: NotionDataSource = {
  object: "data_source",
  id: "ds-meeting",
  title: [{ plain_text: "Meetings & Calendar" }],
  properties: {
    Name: { id: "title", name: "Name", type: "title" },
    Owner: { id: "own", name: "Owner", type: "people" },
    Attendees: { id: "att", name: "Attendees", type: "people" },
    Date: { id: "dt", name: "Date", type: "date" },
    Status: statusProp("st", "Status", [["Complete", [["m1", "Done"], ["m2", "Cancelled"]]]]),
  },
};

const GOAL_DB: NotionDataSource = { ...ACTION_DB, id: "ds-goal", title: [{ plain_text: "Goal" }] };

describe("DB 역할 제안", () => {
  it("할 일 DB: 담당 · 기한 · 상태 속성을 고른다", () => {
    expect(detectProps(ACTION_DB)).toEqual({ title: "title", assignee: "own", due: "dt", status: { id: "st", type: "status" } });
    expect(suggestSetting(ACTION_DB)).toMatchObject({ role: "tasks", title: "Action" });
  });

  it("회의 DB에 Owner · Status가 있어도 참석자 속성이 있으면 할 일 DB로 보지 않는다 (글 원문)", () => {
    expect(suggestSetting(MEETING_DB).role).toBe("text");
  });

  it("할 일 속성이 있어도 이름이 할 일 같지 않으면 제안하지 않는다 (사용자가 고를 수 있다)", () => {
    expect(suggestSetting(GOAL_DB).role).toBe("text");
  });

  it("상태 속성이 없고 이름 없는 체크박스뿐이면 할 일 DB로 보지 않는다", () => {
    const db: NotionDataSource = {
      ...ACTION_DB,
      properties: { Name: ACTION_DB.properties.Name, Owner: ACTION_DB.properties.Owner, Milestone: { id: "ms", name: "Milestone", type: "checkbox" } },
    };
    expect(detectProps(db)).toBeNull();
  });
});

describe("상태 매핑", () => {
  it("Complete 그룹은 완료, 단 Archived · Cancelled 같은 이름은 취소", () => {
    expect(defaultStatusMap(ACTION_DB.properties.Status)).toEqual({ o1: "open", o2: "open", o3: "open", o4: "open", o5: "done", o6: "dropped" });
    expect(defaultStatusMap(MEETING_DB.properties.Status)).toEqual({ m1: "done", m2: "dropped" });
  });

  it("체크박스는 체크 = 완료", () => {
    expect(defaultStatusMap({ id: "x", name: "Done", type: "checkbox" })).toEqual({ true: "done", false: "open" });
  });
});

describe("pageSnapshot", () => {
  const props: TaskPropertyMap = { title: "title", assignee: "own", due: "dt", status: { id: "st", type: "status" } };
  const setting: DataSourceSetting & { props: TaskPropertyMap } = {
    role: "tasks",
    title: "Action",
    props,
    statusMap: defaultStatusMap(ACTION_DB.properties.Status),
    confirmedAt: "2026-09-26T00:00:00Z",
  };
  const identity = { name: "청혁", aliases: ["Daniel"], emails: ["daniel@x.com"] };
  const page = (over: { people?: { name?: string; email?: string }[]; date?: { start: string; end?: string | null } | null; status?: { id: string; name: string } }): NotionPage => ({
    object: "page",
    id: "p1",
    url: "https://www.notion.so/p1",
    created_time: "2026-09-20T00:00:00Z",
    last_edited_time: "2026-09-22T00:00:00Z",
    parent: { type: "data_source_id", data_source_id: "ds-action" },
    properties: {
      Name: { id: "title", type: "title", title: [{ plain_text: "UI 레이아웃 이미지 보내기 " }] },
      Owner: {
        id: "own",
        type: "people",
        people: (over.people ?? [{ name: "Daniel Song", email: "daniel@x.com" }]).map((p, i) => ({
          object: "user" as const,
          id: `u${i}`,
          name: p.name,
          person: p.email ? { email: p.email } : undefined,
        })),
      },
      Date: { id: "dt", type: "date", date: over.date === undefined ? { start: "2026-09-23", end: "2026-09-25" } : over.date },
      Status: { id: "st", type: "status", status: over.status ?? { id: "o3", name: "Current" } },
    },
  });

  it("담당에 이메일이 맞는 사람이 있으면 내 할 일, 날짜 범위는 끝 날짜가 기한", () => {
    expect(pageSnapshot(page({}), setting, identity)).toEqual({
      title: "UI 레이아웃 이미지 보내기",
      assignees: ["Daniel Song"],
      owner: "me",
      due: "2026-09-25",
      status: "open",
      statusLabel: "Current",
    });
  });

  it("다른 사람 · 담당 없음", () => {
    expect(pageSnapshot(page({ people: [{ name: "Chan", email: "chan@x.com" }] }), setting, identity)?.owner).toBe("other");
    expect(pageSnapshot(page({ people: [] }), setting, identity)?.owner).toBe("unknown");
  });

  it("Archived는 취소, 매핑 뒤에 생긴 옵션은 이름으로만 판단한다", () => {
    expect(pageSnapshot(page({ status: { id: "o6", name: "Archived" } }), setting, identity)?.status).toBe("dropped");
    expect(pageSnapshot(page({ status: { id: "new", name: "Won't do" } }), setting, identity)?.status).toBe("dropped");
    expect(pageSnapshot(page({ status: { id: "new2", name: "Review" } }), setting, identity)?.status).toBe("open");
  });

  it("기한 없음", () => {
    expect(pageSnapshot(page({ date: null }), setting, identity)?.due).toBeNull();
  });
});

describe("dueDate", () => {
  it("시각이 있으면 한국 시간 날짜", () => {
    expect(dueDate({ start: "2026-09-25T16:00:00.000Z" })).toBe("2026-09-26");
    expect(dueDate({ start: "2026-09-25" })).toBe("2026-09-25");
    expect(dueDate(null)).toBeNull();
  });
});

describe("openTasksFilter", () => {
  const checkbox = (statusMap?: Record<string, "open" | "done" | "dropped">) =>
    openTasksFilter(
      { role: "tasks", title: null, props: { title: "t", assignee: "a", due: null, status: { id: "cb", type: "checkbox" } }, ...(statusMap ? { statusMap } : {}) },
      ACTION_DB,
    );

  it("상태 속성은 done · dropped 옵션을 이름으로 거른다", () => {
    const props = detectProps(ACTION_DB)!;
    expect(openTasksFilter({ ...suggestSetting(ACTION_DB), props }, ACTION_DB)).toEqual({
      and: [
        { property: "st", status: { does_not_equal: "Done" } },
        { property: "st", status: { does_not_equal: "Archived" } },
      ],
    });
  });

  it("체크박스는 매핑에서 open인 값만 (뒤집힌 매핑도 따른다)", () => {
    expect(checkbox()).toEqual({ property: "cb", checkbox: { equals: false } });
    expect(checkbox({ true: "open", false: "done" })).toEqual({ property: "cb", checkbox: { equals: true } });
    expect(checkbox({ true: "open", false: "open" })).toBeUndefined();
  });
});

describe("확인 · 검증", () => {
  it("예전 역할 이름 meetings는 text로 읽는다 (저장된 설정이 깨지지 않게)", () => {
    const parsed = connectionSettingsSchema.parse({ dataSources: { a: { role: "meetings", title: null, confirmedAt: "x" } } });
    expect(parsed.dataSources?.a.role).toBe("text");
  });

  it("확인하지 않은 할 일 DB는 쓰지 않는다", () => {
    const suggested = suggestSetting(ACTION_DB);
    expect(isActiveTaskSource(suggested)).toBe(false);
    expect(isActiveTaskSource({ ...suggested, confirmedAt: "2026-09-26T00:00:00Z" })).toBe(true);
  });

  it("속성 타입 · 상태 옵션이 스키마와 맞아야 한다", () => {
    const props = detectProps(ACTION_DB)!;
    expect(validateSetting(ACTION_DB, { role: "tasks", props })).toBeNull();
    expect(validateSetting(ACTION_DB, { role: "tasks", props: { ...props, assignee: "dt" } })).toMatch(/담당/);
    expect(validateSetting(ACTION_DB, { role: "tasks", props, statusMap: { nope: "done" } })).toMatch(/상태 매핑/);
    expect(validateSetting(ACTION_DB, { role: "text" })).toBeNull();
  });
});
