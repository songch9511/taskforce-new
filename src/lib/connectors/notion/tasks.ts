import type { z } from "zod";

import { kstDate } from "@/lib/ai/prompts/extract";
import type { DataSourceSetting, saveDataSourceRequestSchema, TaskPropertyMap } from "@/lib/api/contract";
import { isUser, type Person, type UserIdentity } from "@/lib/pipeline/identity";
import type { TaskSnapshot, TaskStatus } from "@/lib/pipeline/structured";

import { dataSourceTitle, type NotionDataSource, type NotionPage, type NotionSchemaProperty, type NotionUser } from "./api";

// Notion 할 일 DB (docs/INTEGRATIONS.md "Notion 할 일 DB"): 어느 DB가 할 일 DB인지 추정하고, 페이지 속성을 스냅샷으로 바꾼다.
// 추정은 제안일 뿐이다. 사용자가 /lab에서 확인한 DB만 할 일로 처리한다. 모두 순수 함수다.

const ASSIGNEE_NAME = /담당|assignee|owner|책임/i;
const DUE_NAME = /기한|마감|due|deadline|date|날짜|일정/i;
const STATUS_NAME = /상태|status|진행/i;
const CHECKBOX_DONE_NAME = /done|완료|complete/i;
const ATTENDEE_NAME = /attendee|참석/i;
const MEETING_TITLE = /meeting|회의|미팅|\bsync\b|1:1|1on1|stand-?up|스탠드업|데일리|스크럼|회고|retro/i;
const TASK_TITLE = /action|task|to-?do|할 ?일|액션|업무|이슈|issue/i;
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

/** 페이지 한 버전 → 스냅샷. 제목이 비었으면 null */
export function pageSnapshot(page: NotionPage, setting: DataSourceSetting & { props: TaskPropertyMap }, identity: UserIdentity): TaskSnapshot | null {
  const { props } = setting;
  const title = byId(page, props.title)
    ?.title?.map((t) => t.plain_text)
    .join("")
    .trim();
  if (!title) return null;

  const people = byId(page, props.assignee)?.people ?? [];
  const owner = people.some((u) => isUser(toPerson(u), identity)) ? "me" : people.length > 0 ? "other" : "unknown";

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
