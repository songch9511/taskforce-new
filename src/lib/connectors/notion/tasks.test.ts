import { describe, expect, it } from "vitest";

import { connectionSettingsSchema, saveDataSourceRequestSchema, type DataSourceSetting, type TaskPropertyMap } from "@/lib/api/contract";

import type { NotionDataSource, NotionPage } from "./api";
import {
  autoConfirmSetting,
  defaultStatusMap,
  detectProps,
  dueDate,
  isActiveTaskSource,
  isMeetingSource,
  isNotionUserMe,
  openTasksFilter,
  pageSnapshot,
  recheckAutoConfirmed,
  suggestSetting,
  unambiguousProps,
  validateSetting,
} from "./tasks";

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

describe("자동 확인: 분명한 매핑", () => {
  const TASK_STATUS = statusProp("st", "상태", [
    ["To-do", [["o1", "시작 전"]]],
    ["In progress", [["o2", "진행 중"]]],
    ["Complete", [["o3", "완료"]]],
  ]);
  const db = (properties: NotionDataSource["properties"], title = "업무"): NotionDataSource => ({
    object: "data_source",
    id: "ds-task",
    title: [{ plain_text: title }],
    properties: { Name: { id: "title", name: "이름", type: "title" }, ...properties },
  });
  const person = (id: string, name: string) => ({ id, name, type: "people" });
  const date = (id: string, name: string) => ({ id, name, type: "date" });

  it("속성이 하나씩이면 그대로 쓰고, 상태 매핑은 Notion 상태 그룹을 따른다", () => {
    expect(unambiguousProps(ACTION_DB)).toEqual({
      props: { title: "title", assignee: "own", due: "dt", status: { id: "st", type: "status" } },
      statusMap: { o1: "open", o2: "open", o3: "open", o4: "open", o5: "done", o6: "dropped" },
    });
  });

  it("여럿이면 이름이 분명한 것 하나를 고른다: 요청자 · 시작일은 담당 · 기한 후보가 아니다", () => {
    const korean = db({
      Assignee: person("a", "담당자"),
      Requester: person("r", "요청자"),
      Start: date("s", "시작일"),
      Due: date("d", "마감일"),
      Status: TASK_STATUS,
    });
    expect(unambiguousProps(korean)?.props).toEqual({ title: "title", assignee: "a", due: "d", status: { id: "st", type: "status" } });
    // 사람 속성이 여럿이어도 담당 이름이 하나면 그것
    expect(unambiguousProps(db({ A: person("a", "Assignee"), B: person("b", "Designer"), Status: TASK_STATUS }))?.props.assignee).toBe("a");
    // Start date · Due date: Due date만 기한 이름
    expect(unambiguousProps(db({ A: person("a", "Owner"), S: date("s", "Start date"), D: date("d", "Due date"), Status: TASK_STATUS }))?.props.due).toBe("d");
    // 날짜 속성이 아예 없으면 기한 없음으로 확인한다
    expect(unambiguousProps(db({ A: person("a", "Owner"), Status: TASK_STATUS }))?.props.due).toBeNull();
  });

  it("기한: 끝낸 날짜는 빼고 완료 예정 · 목표 날짜는 기한 후보로 둔다. 날짜 속성이 모두 빠지면 애매하다", () => {
    const dueOf = (...dates: [string, string][]) =>
      unambiguousProps(db({ A: person("a", "담당자"), Status: TASK_STATUS, ...Object.fromEntries(dates.map(([id, name]) => [id, date(id, name)])) }));
    expect(dueOf(["p", "완료 예정일"])?.props.due).toBe("p");
    expect(dueOf(["p", "완료 목표일"])?.props.due).toBe("p");
    expect(dueOf(["p", "Target completion"])?.props.due).toBe("p");
    // 끝낸 날짜와 예정일이 함께 있으면 예정일
    expect(dueOf(["c", "완료일"], ["p", "완료 예정일"])?.props.due).toBe("p");
    expect(dueOf(["c", "Completed at"], ["s", "Start date"], ["d", "Deadline"])?.props.due).toBe("d");
    // 날짜 속성이 있는데 모두 기한이 아니면(시작 · 끝낸 · 만든 날짜뿐) 기한이 어디 있는지 몰라 자동 확인하지 않는다
    for (const only of ["Start date", "완료일", "완료 일시", "Completed at", "Done date", "Created"]) {
      expect(dueOf(["x", only]), only).toBeNull();
    }
    expect(dueOf(["s", "시작일"], ["c", "완료일"])).toBeNull();
  });

  it("담당: 사람 속성이 하나뿐이어도 이름이 담당 같지 않으면 자동 확인하지 않는다", () => {
    for (const name of ["참여자", "Participants", "Approver", "결재자", "Team", "Members"]) {
      expect(unambiguousProps(db({ P: person("p", name), Status: TASK_STATUS })), name).toBeNull();
    }
    for (const name of ["담당", "담당자", "Assignee", "Assigned to", "Owner", "책임자"]) {
      expect(unambiguousProps(db({ P: person("p", name), Status: TASK_STATUS }))?.props.assignee, name).toBe("p");
    }
    // 담당 이름인 것 하나 + 다른 사람 속성이면 담당 이름인 것
    expect(unambiguousProps(db({ A: person("a", "Owner"), P: person("p", "Participants"), Status: TASK_STATUS }))?.props.assignee).toBe("a");
  });

  it("이름이 분명히 할 일 DB일 때만 자동 확인한다: 단어가 아니라 글자만 겹치는 이름(Transactions) · 기록 DB(업무일지)는 아니다", () => {
    const now = new Date("2026-09-28T00:00:00.000Z");
    const props = { A: person("a", "Owner"), Status: TASK_STATUS };
    for (const title of ["Transactions", "Customer Interactions", "Satisfaction", "리액션 모음", "업무일지", "업무 로그", "Task log", "업무 매뉴얼"]) {
      // /lab 확인 화면의 제안은 그대로 둔다 (사용자가 확인하기 전에는 할 일로 읽지 않는다)
      expect(suggestSetting(db(props, title)).role, title).toBe("tasks");
      expect(autoConfirmSetting(db(props, title), undefined, now), title).toBeNull();
    }
    for (const title of ["Action", "Action Items", "ActionItems", "Tasks", "To-do", "Todos", "Issues", "할 일", "할일", "업무", "팀 업무", "액션 아이템", "이슈"]) {
      expect(autoConfirmSetting(db(props, title), undefined, now)?.confirmedBy, title).toBe("auto");
    }
  });

  it("담당 · 상태 · 기한 중 하나라도 애매하면 자동 확인하지 않는다", () => {
    // 담당 이름이 둘
    expect(unambiguousProps(db({ A: person("a", "담당자"), B: person("b", "Owner"), Status: TASK_STATUS }))).toBeNull();
    // 사람 속성이 둘인데 이름으로 못 고름
    expect(unambiguousProps(db({ A: person("a", "Designer"), B: person("b", "Developer"), Status: TASK_STATUS }))).toBeNull();
    // 상태 속성과 상태 이름의 선택 속성이 함께 있음
    expect(unambiguousProps(db({ A: person("a", "Owner"), Status: TASK_STATUS, Old: { id: "sel", name: "진행 상태", type: "select" } }))).toBeNull();
    // 기한 후보가 둘인데 기한 이름이 없음
    expect(unambiguousProps(db({ A: person("a", "Owner"), D1: date("d1", "Date"), D2: date("d2", "Sprint"), Status: TASK_STATUS }))).toBeNull();
    // 담당으로 쓸 사람 속성이 없음 (요청자뿐)
    expect(unambiguousProps(db({ R: person("r", "요청자"), Status: TASK_STATUS }))).toBeNull();
  });

  it("완료를 가를 수 없는 상태 속성(완료 그룹 없음)은 자동 확인하지 않는다 (끝난 일까지 열린 할 일로 들어온다)", () => {
    const noGroups = { id: "st", name: "Status", type: "status", status: { options: [{ id: "o1", name: "Todo" }], groups: [] } };
    expect(unambiguousProps(db({ A: person("a", "Owner"), Status: noGroups }))).toBeNull();
    // 완료 체크박스는 체크 = 완료라 분명하다
    expect(unambiguousProps(db({ A: person("a", "Owner"), Done: { id: "cb", name: "Done", type: "checkbox" } }))?.props.status).toEqual({ id: "cb", type: "checkbox" });
  });

  it("확인 전 할 일 DB만 자동 확인한다 (confirmedBy: auto). 처음 본 시각은 둔다", () => {
    const now = new Date("2026-09-28T00:00:00.000Z");
    const setting = autoConfirmSetting(ACTION_DB, { role: "tasks", title: "Action", seenAt: "2026-09-27T00:00:00Z" }, now);
    expect(setting).toEqual({
      role: "tasks",
      title: "Action",
      props: { title: "title", assignee: "own", due: "dt", status: { id: "st", type: "status" } },
      statusMap: defaultStatusMap(ACTION_DB.properties.Status),
      confirmedAt: now.toISOString(),
      confirmedBy: "auto",
      seenAt: "2026-09-27T00:00:00Z",
    });
    expect(isActiveTaskSource(setting!)).toBe(true);
    // 처음 보는 DB(설정 없음)도
    expect(autoConfirmSetting(ACTION_DB, undefined, now)?.confirmedBy).toBe("auto");
  });

  it("사용자가 확인한 설정(가져오지 않음 · 글 원문 · 다른 매핑)은 건드리지 않고, 할 일 DB로 제안되지 않는 DB는 자동 확인하지 않는다", () => {
    const now = new Date("2026-09-28T00:00:00.000Z");
    for (const role of ["ignore", "text", "tasks"] as const) {
      expect(autoConfirmSetting(ACTION_DB, { role, title: "Action", confirmedAt: "2026-09-27T00:00:00Z" }, now), role).toBeNull();
    }
    expect(autoConfirmSetting(MEETING_DB, undefined, now)).toBeNull();
    expect(autoConfirmSetting(GOAL_DB, undefined, now)).toBeNull();
  });
});

describe("자동 확인 다시 보기 (규칙이 좁아진 뒤)", () => {
  const now = new Date("2026-09-28T00:00:00.000Z");
  const earlier = "2026-09-27T00:00:00.000Z";
  // 실제 연결에서 본 모양: 회의 액션 아이템이 자동으로 쌓이는 DB. 담당 속성 이름이 "Person"이라 지금 규칙으로는 자동 확인하지 않는다.
  const PERSON_DB: NotionDataSource = {
    ...ACTION_DB,
    id: "ds-person",
    title: [{ plain_text: "Action Items" }],
    properties: { Name: ACTION_DB.properties.Name, Person: { id: "per", name: "Person", type: "people" }, Status: ACTION_DB.properties.Status },
  };
  const statusMap = defaultStatusMap(ACTION_DB.properties.Status);
  const personSetting = (extra: Partial<DataSourceSetting>): DataSourceSetting => ({
    role: "tasks",
    title: "Action Items",
    props: { title: "title", assignee: "per", due: null, status: { id: "st", type: "status" } },
    statusMap,
    confirmedAt: earlier,
    backfilledAt: earlier,
    ...extra,
  });

  it("예전 규칙으로 자동 확인된 DB가 지금은 맞지 않으면 확인 전 설정으로 되돌린다 (매핑 · 처음 훑기 표시 없이)", () => {
    expect(autoConfirmSetting(PERSON_DB, undefined, now)).toBeNull();
    const reverted = recheckAutoConfirmed(PERSON_DB, personSetting({ confirmedBy: "auto", seenAt: "2026-09-20T00:00:00Z" }), now);
    // 처음 본 DB로 남겼을 모양: 제안 역할 · 이름 · 처음 본 시각
    expect(reverted).toEqual({ role: suggestSetting(PERSON_DB).role, title: "Action Items", seenAt: "2026-09-20T00:00:00Z" });
    expect(isActiveTaskSource(reverted!)).toBe(false);
    // 처음 본 동기화에서 바로 자동 확인돼 처음 본 시각이 없으면 자동 확인 시각
    expect(recheckAutoConfirmed(PERSON_DB, personSetting({ confirmedBy: "auto" }), now)?.seenAt).toBe(earlier);
  });

  it("사용자가 확인한 설정은 담당이 Person이어도 그대로 두고, 확인 전 설정도 다시 보지 않는다", () => {
    expect(recheckAutoConfirmed(PERSON_DB, personSetting({}), now)).toBeNull();
    expect(recheckAutoConfirmed(PERSON_DB, { role: "text", title: "Action Items", confirmedAt: earlier }, now)).toBeNull();
    expect(recheckAutoConfirmed(PERSON_DB, { role: "tasks", title: "Action Items", seenAt: earlier }, now)).toBeNull();
    expect(recheckAutoConfirmed(PERSON_DB, undefined, now)).toBeNull();
  });

  it("아직 맞으면 그대로 두고(키 순서만 다른 매핑 포함), 매핑이 바뀌었으면 새 매핑으로 다시 자동 확인한다", () => {
    const saved = { ...autoConfirmSetting(ACTION_DB, undefined, new Date(earlier))!, backfilledAt: earlier };
    expect(recheckAutoConfirmed(ACTION_DB, saved, now)).toBeNull();
    const reordered = { ...saved, statusMap: Object.fromEntries(Object.entries(statusMap).reverse()) };
    expect(recheckAutoConfirmed(ACTION_DB, reordered, now)).toBeNull();
    // 기한 속성이 바뀜: 새 확인 시각이라 새 매핑으로 처음 훑기를 다시 한다
    const moved = recheckAutoConfirmed(ACTION_DB, { ...saved, props: { ...saved.props!, due: null } }, now);
    expect(moved).toEqual(autoConfirmSetting(ACTION_DB, undefined, now));
    expect(moved?.backfilledAt).toBeUndefined();
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

  it("담당이 연결한 사람(Notion user id)이면 이메일 · 이름이 프로필과 달라도 내 할 일", () => {
    const stranger = page({ people: [{ name: "Song" }] });
    expect(pageSnapshot(stranger, setting, identity)?.owner).toBe("other");
    expect(pageSnapshot(stranger, setting, identity, "u0")?.owner).toBe("me");
    expect(pageSnapshot(stranger, setting, identity, "someone-else")?.owner).toBe("other");
  });

  it("연결한 사람을 알면 다른 id는 이메일이 맞을 때만 나이고, 모르면 이메일 없는 이름 · 별칭으로 보완한다", () => {
    const sameName = page({ people: [{ name: "청혁" }] });
    const sameAlias = page({ people: [{ name: "Daniel", email: "daniel@other.com" }] });
    const aliasWithoutEmail = page({ people: [{ name: "Daniel" }] });
    // 같은 이름 · 별칭이어도 명시된 다른 이메일 → 남
    expect(pageSnapshot(sameName, setting, identity, "notion-me")?.owner).toBe("other");
    expect(pageSnapshot(sameAlias, setting, identity, "notion-me")?.owner).toBe("other");
    // 같은 id → 나
    expect(pageSnapshot(sameName, setting, identity, "u0")?.owner).toBe("me");
    // 다른 id라도 이메일이 프로필과 같으면 나 (대소문자 무시)
    expect(pageSnapshot(page({ people: [{ name: "Someone", email: "Daniel@X.com" }] }), setting, identity, "notion-me")?.owner).toBe("me");
    // 연결한 사람을 모르면 이메일 없는 이름 · 별칭으로 알아본다. 이메일이 명시되어 다르면 이름보다 우선한다.
    expect(pageSnapshot(sameName, setting, identity)?.owner).toBe("me");
    expect(pageSnapshot(aliasWithoutEmail, setting, identity)?.owner).toBe("me");
    expect(pageSnapshot(sameAlias, setting, identity)?.owner).toBe("other");
  });

  it("연결한 사람을 모를 때 같은 이름에 다른 이메일이 있으면 담당을 남으로 둔다", () => {
    const namesake = page({ people: [{ name: "청혁", email: "colleague@x.com" }] });
    const user = { object: "user" as const, id: "x", name: "청혁", person: { email: "colleague@x.com" } };

    expect(pageSnapshot(namesake, setting, identity)?.owner).toBe("other");
    expect(isNotionUserMe(user, identity, null)).toBe(false);
  });

  it("isNotionUserMe: 담당 · 마지막으로 고친 사람에 같은 규칙", () => {
    const user = (id: string, name: string, email?: string) => ({ object: "user" as const, id, name, ...(email ? { person: { email } } : {}) });
    expect(isNotionUserMe(user("x", "청혁"), identity, "notion-me")).toBe(false);
    expect(isNotionUserMe(user("notion-me", "Anyone"), identity, "notion-me")).toBe(true);
    expect(isNotionUserMe(user("x", "Anyone", "daniel@x.com"), identity, "notion-me")).toBe(true);
    expect(isNotionUserMe(user("x", "청혁"), identity, null)).toBe(true);
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

  it("처음 가져올 때: 최근 60일 안에 고쳤거나 기한이 아직 안 온 열린 할 일만", () => {
    const props = detectProps(ACTION_DB)!;
    const recent = { editedSince: new Date("2026-07-27T12:00:00.000Z"), today: "2026-09-25" };
    const filter = openTasksFilter({ ...suggestSetting(ACTION_DB), props }, ACTION_DB, recent) as { and: unknown[] };
    const edited = { timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-07-27T12:00:00.000Z" } };
    expect(filter.and.at(-1)).toEqual(props.due ? { or: [edited, { property: props.due, date: { on_or_after: "2026-09-25" } }] } : edited);
    // 기한 속성이 없으면 고친 시각만 본다
    const noDue = openTasksFilter({ ...suggestSetting(ACTION_DB), props: { ...props, due: null } }, ACTION_DB, recent) as { and: unknown[] };
    expect(noDue.and.at(-1)).toEqual(edited);
  });

  it("회의록 DB 이름: 흔한 회의 이름은 알아보고, Async 같은 단어에는 걸리지 않는다", () => {
    const named = (title: string): NotionDataSource => ({ object: "data_source", id: "x", title: [{ plain_text: title }], properties: {} });
    for (const title of ["Meeting", "주간 회의", "미팅노트", "Weekly sync", "1on1", "Daily Standup", "스크럼", "회고"]) {
      expect(isMeetingSource(named(title)), title).toBe(true);
    }
    for (const title of ["Async tasks", "Action Items", "Goal"]) expect(isMeetingSource(named(title)), title).toBe(false);
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

  it("앱 · /lab이 확인 주체(confirmedBy)를 보낼 수 없다 (서버가 정한다)", () => {
    expect(saveDataSourceRequestSchema.parse({ role: "text", confirmedBy: "auto" })).toEqual({ role: "text" });
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
