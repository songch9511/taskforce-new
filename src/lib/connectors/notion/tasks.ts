import type { z } from "zod";

import { kstDate } from "@/lib/ai/prompts/extract";
import type { DataSourceSetting, saveDataSourceRequestSchema, TaskPropertyMap } from "@/lib/api/contract";
import { isUser, type Person, type UserIdentity } from "@/lib/pipeline/identity";
import type { TaskSnapshot, TaskStatus } from "@/lib/pipeline/structured";

import { dataSourceTitle, type NotionDataSource, type NotionPage, type NotionSchemaProperty, type NotionUser } from "./api";

// Notion 할 일 DB (docs/INTEGRATIONS.md "Notion 할 일 DB"): 어느 DB가 할 일 DB인지 추정하고, 페이지 속성을 스냅샷으로 바꾼다.
// 추정은 제안일 뿐이다. 확인한 DB만 할 일로 처리한다: 사용자가 /lab에서 확인했거나, 매핑이 분명해 동기화가 자동 확인한 DB
// (autoConfirmSetting, 동기화마다 지금 규칙으로 다시 본다: recheckAutoConfirmed). 모두 순수 함수다.

const ASSIGNEE_NAME = /담당|assign|owner|책임/i;
const DUE_NAME = /기한|마감|due|deadline|date|날짜|일정/i;
const STATUS_NAME = /상태|status|진행/i;
const CHECKBOX_DONE_NAME = /done|완료|complete/i;
const ATTENDEE_NAME = /attendee|참석/i;
const MEETING_TITLE = /meeting|회의|미팅|\bsync\b|1:1|1on1|stand-?up|스탠드업|데일리|스크럼|회고|retro/i;
const TASK_TITLE = /action|task|to-?do|할 ?일|액션|업무|이슈|issue/i;
/**
 * 자동 확인에 쓰는 할 일 DB 이름 (TASK_TITLE보다 좁다). 영어는 단어로만 맞춘다: Transactions · Customer Interactions · Satisfaction은 아니다.
 * 리액션도 아니다.
 */
const TASK_TITLE_STRICT = /\b(?:actions?|tasks?|to-?dos?|issues?)(?:\s*items?)?\b|할 ?일|(?<!리)액션|업무|이슈/i;
/** 할 일 같은 말이 있어도 기록 · 문서 DB로 보이는 이름 (업무일지 · 업무 로그 · Task log · 업무 매뉴얼): 자동 확인하지 않는다 */
const RECORD_TITLE = /일지|일기|로그|매뉴얼|가이드|위키|\blogs?\b|journal|diary|wiki|guide|manual/i;
/** Complete 그룹에 있어도 완료가 아니라 취소로 보는 상태 이름 (예: Cancelled, Archived) */
const DROPPED_NAME = /cancel|취소|won'?t|archiv|보관|drop|중단|폐기/i;

/** 이름이 맞는 속성을 먼저, 없으면 그 타입의 속성이 하나뿐일 때만 고른다. */
function pick(props: NotionSchemaProperty[], type: string, name: RegExp, fallbackToOnly = true): NotionSchemaProperty | null {
  const ofType = props.filter((p) => p.type === type);
  return ofType.find((p) => name.test(p.name)) ?? (fallbackToOnly && ofType.length === 1 ? ofType[0] : null);
}

/** 담당(사람) + 상태(상태 또는 "완료" 체크박스)가 있어야 할 일 DB로 쓸 수 있다. */
export function detectProps(ds: NotionDataSource): TaskPropertyMap | null {
  const props = Object.values(ds.properties);
  const title = props.find((p) => p.type === "title");
  const assignee = pick(props, "people", ASSIGNEE_NAME);
  const status = pick(props, "status", STATUS_NAME) ?? pick(props, "checkbox", CHECKBOX_DONE_NAME, false);
  if (!title || !assignee || !status) return null;
  const due = pick(props, "date", DUE_NAME);
  return {
    title: title.id,
    assignee: assignee.id,
    due: due?.id ?? null,
    status: { id: status.id, type: status.type as "status" | "checkbox" },
  };
}

/** 담당으로 쓰지 않는 사람 속성 이름 (참석자 · 요청자 · 검토자 · 참조 · 작성자 등) */
const NOT_ASSIGNEE_NAME = /attendee|참석|요청|request|review|검토|참조|\bcc\b|report|작성|creat|생성|멘션|mention|watch|follow|구독/i;
/** 기한으로 쓰지 않는 날짜 속성 이름 (시작 · 만든 · 고친 날짜) */
const NOT_DUE_NAME = /start|begin|시작|착수|creat|생성|작성|등록|edit|수정|updat/i;
/** 끝낸 날짜로 보이는 이름 (완료일 · 완료 일시 · Completed at · Done date · Closed): 기한으로 쓰지 않는다 */
const DONE_DATE_NAME = /complet|완료|finish|closed|done|resolved/i;
/** 끝낼 예정 · 목표 날짜 (완료 예정일 · 완료 목표일 · Target completion): 끝낸 날짜가 아니라 기한 후보다 */
const PLANNED_NAME = /예정|목표|target|plan|expect|estimat|기한|마감|due|deadline/i;
const isNotDueName = (name: string) => NOT_DUE_NAME.test(name) || (DONE_DATE_NAME.test(name) && !PLANNED_NAME.test(name));
/** 날짜 속성이 여럿일 때 기한으로 고르는 이름 (DUE_NAME보다 좁다: Start date · 날짜 같은 이름은 고르지 않는다) */
const DUE_STRONG_NAME = /기한|마감|due|deadline/i;

/** 후보가 없으면 null, 하나면 그것, 여럿이면 이름이 맞는 것이 딱 하나일 때 그것. 그래도 못 고르면 undefined (애매함) */
function onlyOne(candidates: NotionSchemaProperty[], name: RegExp): NotionSchemaProperty | null | undefined {
  if (candidates.length <= 1) return candidates[0] ?? null;
  const named = candidates.filter((p) => name.test(p.name));
  return named.length === 1 ? named[0] : undefined;
}

/**
 * 사용자 확인 없이 쓸 수 있을 만큼 분명한 속성 매핑. 하나라도 애매하면 null (docs/INTEGRATIONS.md "자동 확인").
 * - 담당: 이름이 담당 · Assignee · Assign · Owner · 책임인 사람 속성(참석자 · 요청자 · 검토자 등으로 보이는 것은 빼고)이 딱 하나.
 *   사람 속성이 하나뿐이어도 이름이 담당 같지 않으면(참여자 · Participants · Approver · Team) 고르지 않는다.
 * - 상태: 상태 속성 + 이름이 상태 같은 선택 속성 + 이름이 완료 같은 체크박스 중 하나뿐이거나, 여럿이면 이름이 상태 · Status · 진행인 것이 딱 하나.
 *   고른 것이 선택 속성이면 null (할 일로 읽을 수 없다). 상태 속성이면 열린 옵션과 완료 · 취소 옵션이 모두 있어야 한다
 *   (완료를 가를 수 없으면 끝난 할 일까지 열린 할 일로 들어온다).
 * - 기한: 시작 · 만든 · 고친 날짜와 끝낸 날짜(완료일 · Completed at, 완료 예정일 · Target completion 같은 예정 · 목표 날짜는 빼지 않음)를 뺀
 *   날짜 속성이 하나면 그것, 여럿이면 이름이 기한 · 마감 · Due · Deadline인 것이 딱 하나. 날짜 속성이 아예 없으면 기한 없음.
 *   날짜 속성이 있는데 모두 빠졌으면(시작일뿐 등) 애매하다: 기한이 어디 있는지 모른다.
 */
export function unambiguousProps(ds: NotionDataSource): { props: TaskPropertyMap; statusMap: Record<string, TaskStatus> } | null {
  const props = Object.values(ds.properties);
  const titles = props.filter((p) => p.type === "title");
  const assignees = props.filter((p) => p.type === "people" && ASSIGNEE_NAME.test(p.name) && !NOT_ASSIGNEE_NAME.test(p.name));
  const status = onlyOne(
    props.filter(
      (p) => p.type === "status" || (p.type === "select" && STATUS_NAME.test(p.name)) || (p.type === "checkbox" && CHECKBOX_DONE_NAME.test(p.name)),
    ),
    STATUS_NAME,
  );
  const dates = props.filter((p) => p.type === "date");
  const dueCandidates = dates.filter((p) => !isNotDueName(p.name));
  const due = dates.length > 0 && dueCandidates.length === 0 ? undefined : onlyOne(dueCandidates, DUE_STRONG_NAME);
  if (titles.length !== 1 || assignees.length !== 1 || !status || due === undefined) return null;
  const assignee = assignees[0];
  if (status.type !== "status" && status.type !== "checkbox") return null;
  const statusMap = defaultStatusMap(status);
  const values = Object.values(statusMap);
  if (!values.includes("open") || !values.some((v) => v === "done" || v === "dropped")) return null;
  return {
    props: { title: titles[0].id, assignee: assignee.id, due: due?.id ?? null, status: { id: status.id, type: status.type } },
    statusMap,
  };
}

/**
 * 동기화가 스스로 확인하는 할 일 DB 설정 (confirmedBy: auto). 할 일 DB로 제안되고(suggestSetting) 이름이 분명히 할 일 DB이고
 * (TASK_TITLE_STRICT, 기록 · 문서 DB 이름이 아님) 매핑이 분명할 때만(unambiguousProps).
 * suggestSetting은 /lab 확인 화면의 기본값일 뿐이라 느슨하게 둔다 (사용자가 확인하기 전에는 할 일로 읽지 않는다).
 * 사용자가 확인한 설정은 역할 · 매핑과 상관없이(가져오지 않음 · 글 원문 포함) 건드리지 않는다. 사용자는 /lab(이후 앱)에서 바꿀 수 있다.
 */
export function autoConfirmSetting(ds: NotionDataSource, saved: DataSourceSetting | undefined, now: Date): DataSourceSetting | null {
  if (saved?.confirmedAt || suggestSetting(ds).role !== "tasks") return null;
  const title = dataSourceTitle(ds) ?? "";
  if (!TASK_TITLE_STRICT.test(title) || RECORD_TITLE.test(title)) return null;
  const mapping = unambiguousProps(ds);
  if (!mapping) return null;
  return {
    role: "tasks",
    title: dataSourceTitle(ds),
    props: mapping.props,
    statusMap: mapping.statusMap,
    confirmedAt: now.toISOString(),
    confirmedBy: "auto",
    ...(saved?.seenAt ? { seenAt: saved.seenAt } : {}),
  };
}

/** 같은 매핑인가 (속성 id · 타입, 상태 매핑). 저장된 값은 jsonb라 키 순서가 바뀌어 올 수 있어 값으로 비교한다. */
function sameMapping(a: DataSourceSetting, b: DataSourceSetting): boolean {
  const [pa, pb] = [a.props, b.props];
  const [ma, mb] = [a.statusMap ?? {}, b.statusMap ?? {}];
  return (
    pa?.title === pb?.title &&
    pa?.assignee === pb?.assignee &&
    pa?.due === pb?.due &&
    pa?.status.id === pb?.status.id &&
    pa?.status.type === pb?.status.type &&
    Object.keys(ma).length === Object.keys(mb).length &&
    Object.entries(ma).every(([key, value]) => mb[key] === value)
  );
}

/**
 * 자동 확인한 설정(confirmedBy: auto)을 지금 규칙 · 지금 스키마로 다시 본다 (동기화마다). 규칙을 좁히기 전에 자동 확인된 DB
 * (예: 담당 속성 이름이 "Person"인 회의 액션 아이템 목록)가 계속 할 일로 읽혀 남의 일을 만들지 않게. 바꿀 것이 없으면 null:
 * 자동 확인이 아니거나(사용자 확인 · 확인 전은 건드리지 않는다), 아직 맞고 매핑도 같다.
 * - 아직 맞는데 매핑이 바뀌었으면 새 자동 확인 설정 (새 confirmedAt이라 새 매핑으로 처음 훑기를 다시 한다. /lab에서 매핑을 바꿀 때와 같다).
 * - 더는 맞지 않으면 자동 확인이 없었을 때의 확인 전 설정 (처음 본 DB로 남기는 모양: 제안 역할 · 이름 · 처음 본 시각).
 *   매핑 · backfilledAt은 남기지 않는다: 나중에 다시 맞게 되면 새로 자동 확인하고 처음 훑기도 다시 한다.
 */
export function recheckAutoConfirmed(ds: NotionDataSource, saved: DataSourceSetting | undefined, now: Date): DataSourceSetting | null {
  if (saved?.confirmedBy !== "auto") return null;
  const next = autoConfirmSetting(ds, { role: saved.role, title: saved.title, ...(saved.seenAt ? { seenAt: saved.seenAt } : {}) }, now);
  if (next) return sameMapping(next, saved) ? null : next;
  return {
    role: suggestSetting(ds).role,
    title: dataSourceTitle(ds)?.slice(0, 200) ?? null,
    seenAt: saved.seenAt ?? saved.confirmedAt ?? now.toISOString(),
  };
}

/** 상태 옵션 → open / done / dropped. Notion 상태 그룹(To-do · In progress → open, Complete → done)을 따르되 취소류 이름은 dropped. */
export function defaultStatusMap(property: NotionSchemaProperty): Record<string, TaskStatus> {
  if (property.type === "checkbox") return { true: "done", false: "open" };
  const map: Record<string, TaskStatus> = {};
  for (const group of property.status?.groups ?? []) {
    const complete = /complete|완료/i.test(group.name);
    for (const id of group.option_ids) {
      const name = property.status?.options.find((o) => o.id === id)?.name ?? "";
      map[id] = DROPPED_NAME.test(name) ? "dropped" : complete ? "done" : "open";
    }
  }
  return map;
}

/** 회의록 DB로 보이는가: 참석자 속성이 있거나 이름이 회의 같다. */
export function isMeetingSource(ds: NotionDataSource): boolean {
  const hasAttendees = Object.values(ds.properties).some((p) => p.type === "people" && ATTENDEE_NAME.test(p.name));
  return hasAttendees || MEETING_TITLE.test(dataSourceTitle(ds) ?? "");
}

/**
 * DB 역할 제안. 회의 DB에도 Owner · Status · Date가 흔해서 속성 타입만으로는 할 일 DB라고 하지 않는다:
 * 참석자 속성이나 회의 이름이 아니고, 할 일 속성이 있고, 이름도 할 일 같으면 tasks. 나머지는 지금처럼 글 원문(text).
 */
export function suggestSetting(ds: NotionDataSource): DataSourceSetting {
  const title = dataSourceTitle(ds);
  const props = detectProps(ds);
  const isMeeting = isMeetingSource(ds);
  const role = !isMeeting && props && TASK_TITLE.test(title ?? "") ? "tasks" : "text";
  const statusProperty = props && Object.values(ds.properties).find((p) => p.id === props.status.id);
  return {
    role,
    title,
    ...(props ? { props } : {}),
    ...(statusProperty ? { statusMap: defaultStatusMap(statusProperty) } : {}),
  };
}

/** 사용자가 "가져오지 않음"으로 확인한 DB인가 */
export const isIgnoredSource = (setting: DataSourceSetting | undefined) => setting?.role === "ignore" && Boolean(setting.confirmedAt);

/** 확인을 마친 할 일 DB인가 */
export const isActiveTaskSource = (setting: DataSourceSetting | undefined): setting is DataSourceSetting & { props: TaskPropertyMap } =>
  setting?.role === "tasks" && Boolean(setting.props) && Boolean(setting.confirmedAt);

const byId = (page: NotionPage, id: string) => Object.values(page.properties).find((p) => p.id === id);

/** 날짜 범위면 끝 날짜(마감), 시각이 있으면 한국 시간 날짜 */
export function dueDate(date: { start: string; end?: string | null } | null | undefined): string | null {
  const value = date?.end ?? date?.start;
  if (!value) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : kstDate(parsed).iso;
}

export const toPerson = (u: NotionUser): Person => ({ ...(u.name ? { name: u.name } : {}), ...(u.person?.email ? { email: u.person.email } : {}) });

/**
 * Notion 사람이 사용자인가 (할 일의 담당 · 마지막으로 고친 사람).
 * 연결한 사람의 Notion user id(notionUserId, 봇 주인)를 알면: 그 id이거나, 다른 id면 이메일이 프로필과 맞을 때만 (이름 · 별칭은 보지 않는다:
 * 같은 이름의 팀원을 사용자로 보면 남의 할 일이 내 할 일이 되고 그 수정이 사용자 권한(tracker)이 된다).
 * 모르면 프로필과 맞는지(isUser: 이메일 · 이름 · 별칭)로 본다.
 */
export function isNotionUserMe(u: NotionUser, identity: UserIdentity, notionUserId: string | null): boolean {
  if (notionUserId === null) return isUser(toPerson(u), identity);
  if (u.id === notionUserId) return true;
  return u.person?.email ? isUser({ email: u.person.email }, identity) : false;
}

/**
 * 페이지 한 버전 → 스냅샷. 제목이 비었으면 null.
 * 담당에 사용자(isNotionUserMe: 연결한 사람의 Notion user id, 이메일, 연결한 사람을 모를 때만 이름 · 별칭)가 있으면 내 할 일.
 */
export function pageSnapshot(
  page: NotionPage,
  setting: DataSourceSetting & { props: TaskPropertyMap },
  identity: UserIdentity,
  notionUserId: string | null = null,
): TaskSnapshot | null {
  const { props } = setting;
  const title = byId(page, props.title)
    ?.title?.map((t) => t.plain_text)
    .join("")
    .trim();
  if (!title) return null;

  const people = byId(page, props.assignee)?.people ?? [];
  const owner = people.some((u) => isNotionUserMe(u, identity, notionUserId)) ? "me" : people.length > 0 ? "other" : "unknown";

  const statusProperty = byId(page, props.status.id);
  let status: TaskStatus = "open";
  let statusLabel: string | null = null;
  if (props.status.type === "checkbox") {
    const checked = statusProperty?.checkbox === true;
    status = setting.statusMap?.[String(checked)] ?? (checked ? "done" : "open");
    statusLabel = checked ? "완료" : "미완료";
  } else if (statusProperty?.status) {
    const option = statusProperty.status;
    // 매핑 뒤에 새로 생긴 옵션은 이름으로만 판단한다 (그룹 정보는 페이지에 없다).
    status = setting.statusMap?.[option.id] ?? (DROPPED_NAME.test(option.name) ? "dropped" : "open");
    statusLabel = option.name;
  }

  return {
    title: title.slice(0, 200),
    assignees: people.map((u) => u.name ?? "이름 없음"),
    owner,
    due: props.due ? dueDate(byId(page, props.due)?.date) : null,
    status,
    statusLabel,
  };
}

export type SaveDataSourceRequest = z.infer<typeof saveDataSourceRequestSchema>;

/** 매핑이 실제 스키마와 맞는지 확인한다 (속성 id · 타입, 상태 옵션 id). */
export function validateSetting(ds: NotionDataSource, request: SaveDataSourceRequest): string | null {
  if (request.role !== "tasks" || !request.props) return null;
  const type = (id: string | null) => (id ? Object.values(ds.properties).find((p) => p.id === id)?.type : undefined);
  const { props } = request;
  if (type(props.title) !== "title") return "제목 속성이 맞지 않습니다.";
  if (type(props.assignee) !== "people") return "담당 속성은 사람 속성이어야 합니다.";
  if (props.due && type(props.due) !== "date") return "기한 속성은 날짜 속성이어야 합니다.";
  if (type(props.status.id) !== props.status.type) return "상태 속성이 맞지 않습니다.";
  if (request.statusMap) {
    const status = Object.values(ds.properties).find((p) => p.id === props.status.id);
    const allowed = props.status.type === "checkbox" ? ["true", "false"] : (status?.status?.options.map((o) => o.id) ?? []);
    if (Object.keys(request.statusMap).some((key) => !allowed.includes(key))) return "상태 매핑에 없는 옵션이 있습니다.";
  }
  return null;
}

/**
 * 처음 켤 때 훑을 페이지를 열린 할 일로 줄이는 Notion 쿼리 필터. 처음 보는 할 일은 열린 것만 넣으므로(tasks-ingest.ts)
 * 끝난 · 취소된 할 일은 받을 필요가 없다. 상태 필터는 옵션 이름으로 건다.
 */
export function openTasksFilter(
  setting: DataSourceSetting & { props: TaskPropertyMap },
  ds: NotionDataSource,
  recent?: { editedSince: Date; today: string },
): unknown {
  const { id, type } = setting.props.status;
  const conditions: unknown[] = [];
  if (type === "checkbox") {
    const open = (["true", "false"] as const).filter((key) => (setting.statusMap?.[key] ?? (key === "true" ? "done" : "open")) === "open");
    if (open.length === 1) conditions.push({ property: id, checkbox: { equals: open[0] === "true" } });
  } else {
    const options = Object.values(ds.properties).find((p) => p.id === id)?.status?.options ?? [];
    const closed = options.filter((o) => {
      const mapped = setting.statusMap?.[o.id];
      return mapped === "done" || mapped === "dropped";
    });
    conditions.push(...closed.map((o) => ({ property: id, status: { does_not_equal: o.name } })));
  }
  // 오래 손대지 않은 열린 할 일은 방치된 것일 때가 많다: 처음 가져올 때 "지금 할 일" 맨 위를 묵은 일로 채우지 않는다.
  // 단 기한이 아직 오지 않은 일은 손대지 않았어도 살아 있는 약속이라 가져온다. 나중에 다시 고친 일은 동기화로 들어온다.
  if (recent) {
    const edited = { timestamp: "last_edited_time", last_edited_time: { on_or_after: recent.editedSince.toISOString() } };
    const dueType = setting.props.due ? Object.values(ds.properties).find((p) => p.id === setting.props.due)?.type : undefined;
    conditions.push(dueType === "date" ? { or: [edited, { property: setting.props.due, date: { on_or_after: recent.today } }] } : edited);
  }
  if (conditions.length === 0) return undefined;
  return conditions.length === 1 ? conditions[0] : { and: conditions };
}
