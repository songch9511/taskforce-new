import { connectionSettingsSchema, type DataSourceSetting } from "@/lib/api/contract";
import { isUser, type UserIdentity } from "@/lib/pipeline/identity";

import { DEFAULT_INGEST_OPTIONS, ingestItems, type IngestDeps, type IngestResult } from "../ingest";
import { DEFAULT_TASK_INGEST, ingestTaskItems, type TaskIngestDeps, type TaskIngestResult, type TaskItem } from "../tasks-ingest";
import type { Connection, IngestItem } from "../types";

import type { NotionClient, NotionPage, NotionUser } from "./api";
import { mentionedUserIds, pagePeople, pageToItem, safeNotionUrl } from "./map";
import { isActiveTaskSource, isIgnoredSource, openTasksFilter, pageSnapshot, toPerson } from "./tasks";

// Notion 연결 하나를 동기화한다: 연결에 공유된 페이지 중 커서 이후에 고친 것을 찾아 원문으로 넣는다.
// 본문(markdown)을 받기 전에 "안정됐는지 · 이미 넣었는지"를 먼저 걸러 Notion 요청 수를 아낀다.
// 사용자가 확인한 할 일 DB의 페이지는 글 원문이 아니라 구조화된 할 일로 넣는다 (본문을 받지 않고 속성만 쓴다).

export type NotionTaskDeps = TaskIngestDeps & { identity: (connection: Connection) => Promise<UserIdentity> };

/** 할 일 DB를 처음 켤 때 한 번에 훑는 최대 쪽 수 (한 쪽 100개). 다 못 훑으면 다음 동기화에서 처음부터 다시 훑는다 */
const BACKFILL_MAX_PAGES = 20;

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
};

export const DEFAULT_NOTION_SYNC: Omit<NotionSyncOptions, "now"> = { lookbackDays: 14, maxScan: 300, ...DEFAULT_INGEST_OPTIONS };

export type NotionSyncResult = IngestResult & {
  scanned: number;
  cursor: NotionCursor;
  /** 할 일 DB 처리 결과 (확인한 할 일 DB가 있을 때) */
  tasks?: TaskIngestResult;
  /** 이번에 처음 훑기를 마친 할 일 DB (연결 설정에 backfilledAt을 남긴다) */
  backfilled: Backfilled[];
};

export async function syncNotion(
  connection: Connection,
  client: NotionClient,
  ingest: IngestDeps & { tasks?: NotionTaskDeps },
  options: NotionSyncOptions,
): Promise<NotionSyncResult> {
  const dataSources = connectionSettingsSchema.safeParse(connection.settings).data?.dataSources ?? {};
  const settingOf = (page: NotionPage) => (page.parent.data_source_id ? dataSources[page.parent.data_source_id] : undefined);
  const taskSettingOf = (page: NotionPage) => {
    const setting = settingOf(page);
    return isActiveTaskSource(setting) ? setting : undefined;
  };

  const cursor = connection.syncCursor as NotionCursor | null;
  const after = cursor?.after ? new Date(cursor.after) : new Date(options.now.getTime() - options.lookbackDays * 86_400_000);
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
  // "가져오지 않음"으로 확인한 DB의 페이지는 건너뛴다.
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

  // 3) 고른 페이지만 본문과 사람 이름을 받아 원문으로 만든다.
  const users = new Map<string, NotionUser>();
  const items: IngestItem[] = [];
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
    items.push(pageToItem(page, markdown, [...users.values()]));
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
    ? await syncTasks(connection, client, ingest.tasks, dataSources, taskPages, users, options)
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

  return {
    ...result,
    created: [...result.created, ...(taskRun.result?.created ?? [])],
    tasks: taskRun.result,
    backfilled: taskRun.backfilled,
    skipped: { ...result.skipped, settling: settling.length, overLimit: fresh.length - chosen.length, alreadyIngested: result.skipped.alreadyIngested + already.size },
    scanned: scanned.length,
    cursor: { after: nextAfter < after.toISOString() ? after.toISOString() : nextAfter },
  };
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
  options: NotionSyncOptions,
): Promise<{ result: TaskIngestResult | undefined; backfilled: Backfilled[] }> {
  const pages = new Map(scannedTaskPages.map((p) => [p.id, p]));
  const backfillOnly = new Set<string>();
  const backfilled: Backfilled[] = [];
  for (const [id, setting] of Object.entries(dataSources)) {
    if (!isActiveTaskSource(setting) || setting.backfilledAt) continue;
    if (options.deadline && Date.now() > options.deadline) break;
    try {
      // 열린 할 일만 받는다: 처음 보는 할 일은 열린 것만 넣는다.
      const filter = openTasksFilter(setting, await client.dataSource(id));
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
  // 마지막으로 고친 사람은 id만 온다. 사용자인지 알려면 사람 정보(이메일)가 필요하다.
  const editedByUser = async (page: NotionPage) => {
    const id = page.last_edited_by?.id;
    if (!id) return false;
    if (!users.has(id)) {
      const user = await client.user(id);
      if (user) users.set(id, user);
    }
    const user = users.get(id);
    return user ? isUser(toPerson(user), identity) : false;
  };

  const items: TaskItem[] = [];
  for (const page of pages.values()) {
    const setting = dataSources[page.parent.data_source_id ?? ""];
    if (!isActiveTaskSource(setting)) continue;
    const snapshot = pageSnapshot(page, setting, identity);
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
