import { DEFAULT_INGEST_OPTIONS, ingestItems, type IngestDeps, type IngestResult } from "../ingest";
import type { Connection, IngestItem } from "../types";

import type { NotionClient, NotionPage, NotionUser } from "./api";
import { mentionedUserIds, pagePeople, pageToItem } from "./map";

// Notion 연결 하나를 동기화한다: 연결에 공유된 페이지 중 커서 이후에 고친 것을 찾아 원문으로 넣는다.
// 본문(markdown)을 받기 전에 "안정됐는지 · 이미 넣었는지"를 먼저 걸러 Notion 요청 수를 아낀다.

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

export type NotionSyncResult = IngestResult & { scanned: number; cursor: NotionCursor };

export async function syncNotion(
  connection: Connection,
  client: NotionClient,
  ingest: IngestDeps,
  options: NotionSyncOptions,
): Promise<NotionSyncResult> {
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

  // 2) 막 고친 페이지는 다음에, 이미 넣은 페이지는 건너뛴다. 오래된 것부터 상한만큼.
  const settling = scanned.filter((p) => new Date(p.last_edited_time).getTime() > settledBefore);
  const settled = scanned.filter((p) => new Date(p.last_edited_time).getTime() <= settledBefore);
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
    skipped: { ...result.skipped, settling: settling.length, overLimit: fresh.length - chosen.length, alreadyIngested: result.skipped.alreadyIngested + already.size },
    scanned: scanned.length,
    cursor: { after: nextAfter < after.toISOString() ? after.toISOString() : nextAfter },
  };
}
