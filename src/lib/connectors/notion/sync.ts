import { initialSyncLookbackDays } from "../initial-sync";
import { connectionSettingsSchema, type DataSourceSetting } from "@/lib/api/contract";
import type { UserIdentity } from "@/lib/pipeline/identity";

import { DEFAULT_INGEST_OPTIONS, ingestItems, type IngestDeps, type IngestResult } from "../ingest";
import { DEFAULT_TASK_INGEST, ingestTaskItems, type TaskIngestDeps, type TaskIngestResult, type TaskItem } from "../tasks-ingest";
import type { Connection, IngestItem } from "../types";

import { kstDate } from "@/lib/ai/prompts/extract";

import { mergeAttendees } from "../google/attendees";
import type { MeetingEventLookup } from "../google/lookup";

import { dataSourceTitle, NotionError, type NotionClient, type NotionPage, type NotionUser } from "./api";
import { mentionedUserIds, pagePeople, pageToItem, safeNotionUrl } from "./map";
import {
  autoConfirmSetting,
  isActiveTaskSource,
  isIgnoredSource,
  isNotionUserMe,
  openTasksFilter,
  pageSnapshot,
  recheckAutoConfirmed,
  suggestSetting,
} from "./tasks";

// Notion 연결 하나를 동기화한다: 연결에 공유된 페이지 중 커서 이후에 고친 것을 찾아 원문으로 넣는다.
// 본문(markdown)을 받기 전에 "안정됐는지 · 이미 넣었는지"를 먼저 걸러 Notion 요청 수를 아낀다.
// 확인한 할 일 DB(사용자 확인 또는 자동 확인)의 페이지는 글 원문이 아니라 구조화된 할 일로 넣는다 (본문을 받지 않고 속성만 쓴다).

export type NotionTaskDeps = TaskIngestDeps & { identity: (connection: Connection) => Promise<UserIdentity> };

/**
 * 같은 회의의 Calendar 일정 조회 (Google 연결이 Calendar를 허용했을 때만 준다, google-integration.md 2-2 · 2-4).
 * 조회가 한 번 5초를 넘거나 실패하면 그 동기화의 남은 회의록에는 붙이지 않고 그대로 넣는다: Notion 동기화를 막지 않는다.
 */
const MEETING_EVENT_TIMEOUT_MS = 5_000;
/** 한 동기화에서 일정 조회에 쓸 수 있는 시간 합계 (넘으면 남은 회의록에는 붙이지 않는다) */
const MEETING_EVENT_TOTAL_MS = 15_000;

/** 이번 동기화에서 회의록에 일정을 잇는 시도의 결과 (연결 설정 stats에 세어 넣는다) */
export type MeetingLinkCounts = { attached: number; ambiguous: number; none: number; failed: number };

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`시간 초과 (${ms}ms)`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/** 할 일 DB를 처음 켤 때 한 번에 훑는 최대 쪽 수 (한 쪽 100개). 다 못 훑으면 다음 동기화에서 처음부터 다시 훑는다 */
const BACKFILL_MAX_PAGES = 20;
/** 처음 켤 때 가져오는 열린 할 일: 이 기간 안에 고친 것만 (그보다 오래 손대지 않은 일은 방치된 것일 때가 많다) */
const BACKFILL_EDITED_WITHIN_DAYS = 60;

/** 처음 본 DB (저장된 설정 없음): 공유가 나중에 끊기면 알아차리도록 연결 설정에 남긴다 */
export type SeenDataSource = { id: string; title: string | null; role: DataSourceSetting["role"] };
export type UnreachableDataSource = { id: string; title: string | null };
/** 이번 동기화가 할 일 DB로 자동 확인한 DB와 그 설정 (연결 설정에 남긴다, recordNotionHealth) */
export type AutoConfirmed = { id: string; setting: DataSourceSetting };
/** 이번 동기화가 자동 확인을 되돌린 DB와 되돌린 확인 전 설정 (지금 규칙으로는 자동 확인할 수 없다. 연결 설정에 남긴다, recordNotionHealth) */
export type AutoConfirmReverted = { id: string; setting: DataSourceSetting };

/** 처음 훑기를 마친 할 일 DB와, 그때 쓴 설정의 확인 시각 (그 사이 사용자가 설정을 바꿨으면 표시하지 않는다) */
export type Backfilled = { dataSourceId: string; confirmedAt: string };

export type NotionCursor = { after: string };

export type NotionSyncOptions = {
  now: Date;
  /** 첫 동기화 때 거슬러 올라갈 기간 */
  lookbackDays: number;
  /** 한 번에 훑어볼 최대 페이지 수 */
  maxScan: number;
  settleMinutes: number;
  maxItems: number;
  minTextLength: number;
  deadline?: number;
  /** 일정 조회 한 번의 제한 (기본 5초) */
  meetingEventTimeoutMs?: number;
  /** 한 동기화의 일정 조회 시간 합계 제한 (기본 15초) */
  meetingEventTotalMs?: number;
};

export const DEFAULT_NOTION_SYNC: Omit<NotionSyncOptions, "now"> = { lookbackDays: 3, maxScan: 300, ...DEFAULT_INGEST_OPTIONS };

export function defaultNotionSyncOptions(): Omit<NotionSyncOptions, "now"> {
  return { ...DEFAULT_NOTION_SYNC, lookbackDays: initialSyncLookbackDays() };
}

export type NotionSyncResult = IngestResult & {
  scanned: number;
  cursor: NotionCursor;
  /** 할 일 DB 처리 결과 (확인한 할 일 DB가 있을 때) */
  tasks?: TaskIngestResult;
  /** 이번에 처음 훑기를 마친 할 일 DB (연결 설정에 backfilledAt을 남긴다) */
  backfilled: Backfilled[];
  /** 이번에 처음 본 DB (공유된 DB 중 설정이 없는 것) */
  seen: SeenDataSource[];
  /** 이번에 자동 확인한 할 일 DB (이번 동기화부터 할 일 경로로 읽었다). 매핑이 바뀌어 다시 자동 확인한 DB도 */
  autoConfirmed: AutoConfirmed[];
  /** 이번에 자동 확인을 되돌린 DB (지금 규칙으로는 맞지 않음. 이번 동기화부터 확인 전 DB처럼 글 원문으로 읽었다) */
  reverted: AutoConfirmReverted[];
  /** 새로 공유된 · 공유가 되돌아온 DB가 있어 최근 기간을 다시 훑었는가 */
  rewound: boolean;
  /** 전에 읽던(설정이 있는) DB 중 지금 읽을 수 없는 것: Notion에서 공유가 빠졌다. 이번에 끝까지 확인하지 못했으면 null(지난 결과를 둔다) */
  unreachable: UnreachableDataSource[] | null;
  /** 연결한 사람의 Notion user id (모르면 null). 연결 설정에 없던 값이면 설정에 남긴다 (recordNotionHealth) */
  notionUserId: string | null;
  /** 회의록에 일정을 이은 결과 (일정 조회를 줬을 때만) */
  meetingLinks?: MeetingLinkCounts;
};

/** 연결 설정에 남겨 둔, 연결한 사람의 Notion user id */
export const savedNotionUserId = (connection: Connection): string | null =>
  typeof connection.settings.notionUserId === "string" ? connection.settings.notionUserId : null;

/**
 * 연결한 사람의 Notion user id: 설정에 없으면 봇 주인(GET /v1/users/me)으로 알아낸다. 페이지를 사용자가 직접 썼는지 가르는 데 쓴다.
 * 알 수 없으면(권한 · 일시적인 오류) null로 두고 동기화는 계속한다 (작성자를 모름). 권한 끊김(401)은 그대로 올린다.
 */
async function connectedUserId(connection: Connection, client: NotionClient): Promise<string | null> {
  const saved = savedNotionUserId(connection);
  if (saved) return saved;
  return client.botOwnerId().catch((error) => {
    if (error instanceof NotionError && error.status === 401) throw error;
    console.error("Notion 연결한 사람 확인 실패:", error instanceof Error ? error.message : error);
    return null;
  });
}

export async function syncNotion(
  connection: Connection,
  client: NotionClient,
  ingest: IngestDeps & { tasks?: NotionTaskDeps; meetingEvent?: MeetingEventLookup },
  options: NotionSyncOptions,
): Promise<NotionSyncResult> {
  const parsed = connectionSettingsSchema.safeParse(connection.settings);
  // 설정을 읽지 못하면 사용자가 정한 역할(가져오지 않음 · 글 원문)을 모르므로 이번에는 자동 확인하지 않는다 (설정 내용은 로그에 남기지 않는다).
  if (!parsed.success) {
    console.error(`Notion 연결 설정을 읽지 못해 이번 동기화는 할 일 DB를 자동 확인하지 않습니다 (${connection.id}): 문제 ${parsed.error.issues.length}개`);
  }
  const settings = parsed.data;
  const dataSources = { ...(settings?.dataSources ?? {}) };
  const settingOf = (page: NotionPage) => (page.parent.data_source_id ? dataSources[page.parent.data_source_id] : undefined);
  const taskSettingOf = (page: NotionPage) => {
    const setting = settingOf(page);
    return isActiveTaskSource(setting) ? setting : undefined;
  };

  // 공유된 DB 목록: 처음 보는 DB를 남기고(나중에 공유가 끊기면 알아차리려고), 전에 읽던 DB가 빠졌는지 본다.
  // 이 확인이 실패해도(속도 제한 등) 동기화는 계속한다.
  const visible = await client
    .searchDataSources()
    .then((list) => new Map(list.map((ds) => [ds.id, ds])))
    .catch((error) => {
      console.error("Notion 데이터베이스 목록 실패:", error instanceof Error ? error.message : error);
      return null;
    });
  const seen: SeenDataSource[] = [...(visible?.values() ?? [])]
    .filter((ds) => !dataSources[ds.id])
    .map((ds) => ({ id: ds.id, title: dataSourceTitle(ds), role: suggestSetting(ds).role }));
  const recovered = (settings?.health?.unreachable ?? []).some((d) => visible?.has(d.id));

  // 할 일 DB로 보이고 담당 · 상태 · 기한 속성이 분명한 DB는 사용자 확인 없이 확인한다 (앱에 확인 화면이 없다).
  // 이번 동기화부터 할 일 경로로 읽어(처음 훑기 포함) 같은 페이지를 글 원문으로 또 넣지 않는다. 사용자가 확인한 설정은 건드리지 않는다.
  // 이미 자동 확인한 DB는 지금 규칙 · 지금 스키마로 다시 본다: 규칙을 좁히기 전에 자동 확인된 DB가 계속 남의 할 일을 만들지 않게.
  // 더는 맞지 않으면 확인 전으로 되돌려 이번 동기화부터 할 일 경로로 읽지 않는다(처음 훑기도 하지 않는다).
  const autoConfirmed: AutoConfirmed[] = [];
  const reverted: AutoConfirmReverted[] = [];
  for (const ds of ingest.tasks && parsed.success ? (visible?.values() ?? []) : []) {
    const saved = dataSources[ds.id];
    if (saved?.confirmedBy === "auto") {
      const next = recheckAutoConfirmed(ds, saved, options.now);
      if (next?.confirmedBy === "auto") autoConfirmed.push({ id: ds.id, setting: next });
      else if (next) reverted.push({ id: ds.id, setting: next });
      continue;
    }
    const setting = autoConfirmSetting(ds, saved, options.now);
    if (setting) autoConfirmed.push({ id: ds.id, setting });
  }
  for (const { id, setting } of [...autoConfirmed, ...reverted]) dataSources[id] = setting;
  if (reverted.length > 0) console.warn(`Notion 할 일 DB 자동 확인을 되돌렸습니다 (${connection.id}): ${reverted.length}개`);

  const cursor = connection.syncCursor as NotionCursor | null;
  const lookback = new Date(options.now.getTime() - options.lookbackDays * 86_400_000);
  let after = cursor?.after ? new Date(cursor.after) : lookback;
  // 새로 공유됐거나 공유가 되돌아온 DB가 있으면 이번만 최근 기간을 다시 훑는다: 공유되지 않은 동안에도 커서는 지나갔으므로
  // 그 사이 고친 페이지(예: 끊겨 있던 동안의 회의록)를 놓치지 않게. 이미 넣은 페이지는 ingestedIds로 걸러진다.
  const recoveryLookback = new Date(options.now.getTime() - 14 * 86_400_000);
  const rewound = Boolean(cursor?.after) && (seen.length > 0 || recovered) && after > recoveryLookback;
  if (rewound) after = recoveryLookback;
  const settledBefore = options.now.getTime() - options.settleMinutes * 60_000;

  // 1) 최근 수정순으로 훑다가 커서보다 오래된 페이지가 나오면 멈춘다.
  const scanned: NotionPage[] = [];
  let next: string | null | undefined;
  scan: do {
    const { pages, nextCursor } = await client.searchPages(next ?? undefined);
    for (const page of pages) {
      if (new Date(page.last_edited_time) <= after) break scan;
      if (!page.in_trash && !page.archived) scanned.push(page);
      if (scanned.length >= options.maxScan) break scan;
    }
    next = nextCursor;
  } while (next);

  const taskPages = ingest.tasks ? scanned.filter((p) => taskSettingOf(p)) : [];

  // "가져오지 않음"으로 확인한 DB의 페이지는 건너뛴다. 확인 전 DB는 글 원문으로 읽는다
  // (보류하면 이름으로 회의록 DB를 못 알아본 경우 핵심 원문이 조용히 끊기고, 커서가 지나가 되살릴 수 없다).
  const textPages = scanned.filter((p) => !taskPages.includes(p) && !isIgnoredSource(settingOf(p)));



  // 2) 막 고친 페이지는 다음에, 이미 넣은 페이지는 건너뛴다. 오래된 것부터 상한만큼.
  const settling = textPages.filter((p) => new Date(p.last_edited_time).getTime() > settledBefore);
  const settled = textPages.filter((p) => new Date(p.last_edited_time).getTime() <= settledBefore);
  const already = await ingest.ingestedIds(connection, settled.map((p) => p.id));
  const fresh = settled
    .filter((p) => !already.has(p.id))
    .sort((a, b) => a.last_edited_time.localeCompare(b.last_edited_time));
  const chosen = fresh.slice(0, options.maxItems);
  const deferred = [...settling, ...fresh.slice(options.maxItems)];

  // 3) 고른 페이지만 본문과 사람 이름을 받아 원문으로 만든다. 만든 사람이 연결한 사람이면 사용자가 직접 쓴 문서다.
  //    할 일도 담당 · 고친 사람이 연결한 사람이면 사용자다. 넣을 것이 없으면 봇 주인을 묻지 않는다.
  const taskWork = Boolean(ingest.tasks) && (taskPages.length > 0 || Object.values(dataSources).some((s) => isActiveTaskSource(s) && !s.backfilledAt));
  const notionUserId = chosen.length > 0 || taskWork ? await connectedUserId(connection, client) : savedNotionUserId(connection);
  const users = new Map<string, NotionUser>();
  const items: IngestItem[] = [];
  const links: MeetingLinkCounts = { attached: 0, ambiguous: 0, none: 0, failed: 0 };
  let linking = Boolean(ingest.meetingEvent);
  /** 회의록이면 같은 회의의 일정을 붙인다: 관련자에 일정 참석자를 합치고 sources.meeting에 일정 제목 · 시각을 남긴다. 한 번 실패하면 남은 페이지는 붙이지 않는다 */
  let linkingSpentMs = 0;
  const withMeetingEvent = async (page: NotionPage, item: IngestItem): Promise<IngestItem> => {
    if (!linking || !ingest.meetingEvent || item.kind !== "meeting") return item;
    const startedAt = Date.now();
    try {
      const found = await withTimeout(
        ingest.meetingEvent({
          day: kstDate(item.occurredAt).iso,
          createdAt: new Date(page.created_time),
          title: item.title,
          // 시각만으로 일정을 고르는 것은 사용자가 만든 페이지에서만: 다른 사람이 같은 시각에 만든 페이지에 사용자의 일정을 붙이지 않는다
          createdByUser: Boolean(notionUserId && page.created_by?.id === notionUserId),
        }),
        options.meetingEventTimeoutMs ?? MEETING_EVENT_TIMEOUT_MS,
      );
      links[found.result]++;
      if (found.result !== "attached") return item;
      const { event } = found;
      return {
        ...item,
        participants: { ...item.participants, attendees: mergeAttendees(event.attendees, item.participants?.attendees ?? []) },
        meeting: { calendar_event_id: event.calendarEventId, title: event.title, start: event.start, end: event.end },
      };
    } catch (error) {
      linking = false;
      links.failed++;
      console.error("Google 일정 조회 실패 (남은 회의록은 일정 없이 넣습니다):", error instanceof Error ? error.message : error);
      return item;
    } finally {
      // 조회 한 번은 5초 안이라도 회의록이 20건이면 100초가 된다: 한 동기화의 조회 시간에도 상한을 둔다 (공유하는 cron 시간 예산을 Google이 다 쓰지 않게)
      linkingSpentMs += Date.now() - startedAt;
      if (linking && linkingSpentMs > (options.meetingEventTotalMs ?? MEETING_EVENT_TOTAL_MS)) {
        linking = false;
        console.error("Google 일정 조회가 이번 동기화의 시간 상한을 넘어 남은 회의록은 일정 없이 넣습니다.");
      }
    }
  };
  for (const page of chosen) {
    if (options.deadline && Date.now() > options.deadline) break;
    const { markdown } = await client.pageMarkdown(page.id);
    for (const person of pagePeople(page)) users.set(person.id, person);
    for (const id of mentionedUserIds(markdown)) {
      if (!users.has(id)) {
        const user = await client.user(id);
        if (user) users.set(id, user);
      }
    }
    items.push(await withMeetingEvent(page, pageToItem(page, markdown, [...users.values()], notionUserId)));
  }

  const result = await ingestItems(connection, items, ingest, {
    now: options.now,
    settleMinutes: options.settleMinutes,
    maxItems: options.maxItems,
    minTextLength: options.minTextLength,
    deadline: options.deadline,
  });

  // 3-1) 할 일 DB: 속성만으로 스냅샷을 만들어 넣는다.
  const taskRun = ingest.tasks
    ? await syncTasks(connection, client, ingest.tasks, dataSources, taskPages, users, notionUserId, options)
    : { result: undefined, backfilled: [] as Backfilled[] };
  if (taskRun.result) deferred.push(...taskPages.filter((p) => taskRun.result!.deferred.includes(p.id)));

  // 4) 커서: 미룬 페이지가 있으면 그 직전까지만, 없으면 훑은 것 중 가장 최근까지 옮긴다.
  const newest = scanned.reduce((max, p) => (p.last_edited_time > max ? p.last_edited_time : max), after.toISOString());
  // 시간이 모자라 본문을 못 받았거나 처리하지 못한 페이지도 다음에 다시 본다.
  const fetched = new Set(items.map((i) => i.externalId));
  const notReached = new Set(result.notReached);
  deferred.push(...chosen.filter((p) => !fetched.has(p.id) || notReached.has(p.id)));
  const oldestDeferred = deferred.reduce<string | null>((min, p) => (min === null || p.last_edited_time < min ? p.last_edited_time : min), null);
  const nextAfter = oldestDeferred ? new Date(new Date(oldestDeferred).getTime() - 1).toISOString() : newest;

  // 5) 전에 읽던 DB 중 지금 읽을 수 없는 것 (가져오지 않음으로 둔 것은 빼고).
  //    끝까지 확인하지 못했으면(시간 한도 · 일시적인 오류) null: 경고가 깜빡이지 않게 지난 결과를 둔다.
  let unreachable: UnreachableDataSource[] | null = visible ? [] : null;
  for (const [id, setting] of Object.entries(dataSources)) {
    if (!unreachable || !visible) break;
    if (setting.role === "ignore" || visible.has(id)) continue;
    if (options.deadline && Date.now() > options.deadline) {
      unreachable = null;
      break;
    }
    const ds = await client.dataSource(id).catch(unshared);
    if (ds === undefined) unreachable = null;
    else if (ds === null) unreachable.push({ id, title: setting.title });
  }

  return {
    ...result,
    created: [...result.created, ...(taskRun.result?.created ?? [])],
    tasks: taskRun.result,
    backfilled: taskRun.backfilled,
    seen,
    autoConfirmed,
    reverted,
    rewound,
    unreachable,
    notionUserId,
    ...(ingest.meetingEvent ? { meetingLinks: links } : {}),
    skipped: { ...result.skipped, settling: settling.length, overLimit: fresh.length - chosen.length, alreadyIngested: result.skipped.alreadyIngested + already.size },
    scanned: scanned.length,
    cursor: { after: nextAfter < after.toISOString() ? after.toISOString() : nextAfter },
  };
}

/** 공유되지 않았거나 없는 DB는 null, 그 밖의 오류(속도 제한 · 서버 오류)는 undefined(이번엔 모름). 권한 끊김(401)은 그대로 올린다. */
function unshared(error: unknown): null | undefined {
  if (error instanceof NotionError && error.status === 401) throw error;
  if (error instanceof NotionError && (error.status === 404 || error.status === 400 || error.status === 403)) return null;
  console.error("Notion 데이터베이스 확인 실패:", error instanceof Error ? error.message : error);
  return undefined;
}

/**
 * 할 일 원문의 버전 값. 같은 페이지가 할 일 DB로 확인되기 전에 글 원문으로 들어온 적이 있으면, 수정 시각만으로는
 * 원문 고유 조건(연결 · 페이지 · 버전)에 걸려 저장되지 않는다. 앞에 task:를 붙여 글 원문 버전과 가른다 (시각 순서는 그대로).
 */
export const taskVersion = (lastEditedTime: string) => `task:${lastEditedTime}`;

/** 확인한 할 일 DB의 페이지를 구조화된 할 일로 넣는다. 처음 켠 DB는 한 번 전체를 훑어 열린 할 일을 가져온다. */
async function syncTasks(
  connection: Connection,
  client: NotionClient,
  deps: NotionTaskDeps,
  dataSources: Record<string, DataSourceSetting>,
  scannedTaskPages: NotionPage[],
  users: Map<string, NotionUser>,
  notionUserId: string | null,
  options: NotionSyncOptions,
): Promise<{ result: TaskIngestResult | undefined; backfilled: Backfilled[] }> {
  const pages = new Map(scannedTaskPages.map((p) => [p.id, p]));
  const backfillOnly = new Set<string>();
  const backfilled: Backfilled[] = [];
  for (const [id, setting] of Object.entries(dataSources)) {
    if (!isActiveTaskSource(setting) || setting.backfilledAt) continue;
    if (options.deadline && Date.now() > options.deadline) break;
    try {
      // 열린 할 일만 받는다: 처음 보는 할 일은 열린 것만 넣는다. 오래 손대지 않은 것은 빼고.
      const editedSince = new Date(options.now.getTime() - BACKFILL_EDITED_WITHIN_DAYS * 86_400_000);
      const filter = openTasksFilter(setting, await client.dataSource(id), { editedSince, today: kstDate(options.now).iso });
      let cursor: string | undefined;
      let exhausted = false;
      for (let n = 0; n < BACKFILL_MAX_PAGES; n++) {
        const { pages: batch, nextCursor } = await client.queryDataSource(id, cursor, filter);
        for (const page of batch) {
          if (page.in_trash || page.archived || pages.has(page.id)) continue;
          pages.set(page.id, page);
          backfillOnly.add(page.id);
        }
        if (!nextCursor) {
          exhausted = true;
          break;
        }
        cursor = nextCursor;
      }
      if (exhausted) backfilled.push({ dataSourceId: id, confirmedAt: setting.confirmedAt! });
    } catch (error) {
      // 공유가 끊겼거나 지워진 DB 하나 때문에 연결 전체의 동기화를 멈추지 않는다. 다음 동기화에서 다시 시도한다.
      console.error(`할 일 DB 처음 훑기 실패 (${id}):`, error instanceof Error ? error.message : error);
    }
  }
  // 페이지가 없어도 처리를 마치지 못한 할 일은 다시 처리한다.
  const hasTaskSources = Object.values(dataSources).some(isActiveTaskSource);
  if (pages.size === 0 && !hasTaskSources) return { result: undefined, backfilled };

  const identity = await deps.identity(connection);
  // 마지막으로 고친 사람은 id만 온다. 연결한 사람이 아니면 사람 정보로 사용자인지 가린다 (isNotionUserMe: 연결한 사람을 알면 이메일만).
  const editedByUser = async (page: NotionPage) => {
    const id = page.last_edited_by?.id;
    if (!id) return false;
    if (id === notionUserId) return true;
    if (!users.has(id)) {
      const user = await client.user(id);
      if (user) users.set(id, user);
    }
    const user = users.get(id);
    return user ? isNotionUserMe(user, identity, notionUserId) : false;
  };

  const items: TaskItem[] = [];
  for (const page of pages.values()) {
    const setting = dataSources[page.parent.data_source_id ?? ""];
    if (!isActiveTaskSource(setting)) continue;
    const snapshot = pageSnapshot(page, setting, identity, notionUserId);
    if (!snapshot) continue;
    items.push({
      externalId: page.id,
      externalVersion: taskVersion(page.last_edited_time),
      snapshot,
      editedByUser: await editedByUser(page),
      lastEditedAt: new Date(page.last_edited_time),
      externalUrl: safeNotionUrl(page.url),
    });
  }

  const result = await ingestTaskItems(connection, items, deps, { now: options.now, ...DEFAULT_TASK_INGEST, deadline: options.deadline });
  // 처음 훑기에서만 본 페이지가 미뤄졌으면 다음에 다시 훑는다 (커서로는 다시 보이지 않는다).
  const complete = !result.deferred.some((id) => backfillOnly.has(id));
  return { result, backfilled: complete ? backfilled : [] };
}
