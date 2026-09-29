import { z } from "zod";

import { ingestItems, type IngestDeps } from "../ingest";
import { GoogleApiError } from "../google/token";
import type { Connection, ConnectorSyncResult, IngestItem } from "../types";

import type { GmailClient, GmailMessageRef, GmailMetadata } from "./client";
import { filterMessage, type GmailDropReason, type GmailFilterContext, type GmailKeepReason } from "./filter";
import { messageToItem } from "./message";

// Gmail 연결 하나를 동기화한다 (G6 · G7 · G8, docs/go-live/google-integration.md 2-6 목록 · 한도 · 커서).
// 1) 커서 뒤를 하루 단위 창으로 오래된 창부터 나눠 메일 id를 받는다 (창 안은 끝 쪽까지).
// 2) 이미 넣은 것 · 이미 결정한 것을 빼고 남은 메일만 머리글을 읽어 거른다. 거른 메일은 본문을 받지 않는다.
// 3) 남긴 메일만 본문을 받아 원문으로 넣는다 (메일 한 통 = 원문 하나, 안정화 없이).
// 창 하나를 다 결정하면 커서를 창 끝으로 옮긴다. 한도 · 시간 · 속도 제한으로 멈추면 결정한 메일만 seen에 남겨 다음 동기화가 이어 간다.

/**
 * after: 이보다 먼저 받은 메일은 모두 결정됐다 (넣음 · 거름).
 * seen: after − 겹침 뒤에서 이미 결정한 메일 id → 받은 시각(epoch ms). 다음 목록에서 머리글을 다시 읽지 않는다.
 */
export const gmailCursorSchema = z.object({ after: z.iso.datetime(), seen: z.record(z.string(), z.number()) });
export type GmailCursor = z.infer<typeof gmailCursorSchema>;

export type GmailSyncOptions = {
  now: Date;
  /** 첫 동기화 때 거슬러 올라갈 기간 (G8) */
  lookbackDays: number;
  /** 다시 연결했을 때 이어 가져오는 최대 기간 (G8) */
  maxGapDays: number;
  /** 목록을 커서보다 이만큼 앞부터 받는다 (방금 받은 메일이 검색에 늦게 잡혀도 놓치지 않게) */
  overlapMs: number;
  /** 목록 창 하나의 길이 */
  windowMs: number;
  /** 한 동기화에서 머리글을 읽는 최대 메일 수 */
  maxHeaders: number;
  /** 한 동기화에서 본문을 받아 넣는 최대 메일 수 (넣기 상한과 같게: 본문을 받았는데 넣지 못한 메일이 생기지 않게) */
  maxItems: number;
  /** 동시에 부르는 Gmail 요청 수 */
  concurrency: number;
  /** seen에 남기는 최대 id 수 */
  maxSeen: number;
  deadline?: number;
};

const DAY_MS = 86_400_000;

export const DEFAULT_GMAIL_SYNC: Omit<GmailSyncOptions, "now"> = {
  lookbackDays: 14,
  maxGapDays: 30,
  overlapMs: 3_600_000,
  windowMs: DAY_MS,
  maxHeaders: 200,
  maxItems: 20,
  concurrency: 4,
  maxSeen: 2_000,
};

/** 이번 동기화가 결정한 메일 수: 남긴 이유 · 버린 이유별 (본문 · 주소 없이 연결 설정 stats에 더한다) */
export type GmailDecisionCounts = Partial<Record<GmailKeepReason | GmailDropReason, number>>;

export type GmailSyncResult = ConnectorSyncResult & {
  cursor: GmailCursor;
  decisions: GmailDecisionCounts;
  /** Gmail 속도 제한(429)에 걸려 멈췄다 */
  rateLimited: boolean;
};

export type GmailSyncInput = {
  /** 거르기에 쓰는 사용자 주소 · 회사 도메인 */
  filter: GmailFilterContext;
  /** 연결한 Google 주소 (원본 링크의 authuser) */
  accountEmail: string | null;
};

/**
 * 목록 검색어: 창 [start, end), 채팅 · 임시 보관 · 프로모션 · 소셜은 목록에서 뺀다. after: · before:는 epoch 초를 받는다(9장).
 * 끝은 내림한다: 올리면 창 끝(지금) 뒤 1초 안에 받은 메일이 들어와, 창을 끝낸 커서보다 뒤인데 이미 결정한 것으로 남는다
 */
export function gmailQuery(start: number, end: number): string {
  return `after:${Math.floor(start / 1000)} before:${Math.floor(end / 1000)} -in:chats -in:drafts -category:promotions -category:social`;
}

/** 속도 제한: 429, 또는 403 + rateLimitExceeded · userRateLimitExceeded (Gmail은 둘 다 쓴다) */
const isRateLimited = (error: unknown) =>
  error instanceof GoogleApiError &&
  (error.status === 429 || (error.status === 403 && ["rateLimitExceeded", "userRateLimitExceeded"].includes(error.reason ?? "")));

/** 저장된 커서. 형식이 다르면(없음) null: 첫 동기화처럼 */
export function parseGmailCursor(cursor: Record<string, unknown> | null): GmailCursor | null {
  const parsed = gmailCursorSchema.safeParse(cursor);
  return parsed.success ? parsed.data : null;
}

class Stop extends Error {}

export async function syncGmail(
  connection: Connection,
  client: GmailClient,
  deps: IngestDeps,
  input: GmailSyncInput,
  options: GmailSyncOptions,
): Promise<GmailSyncResult> {
  const now = options.now.getTime();
  const saved = parseGmailCursor(connection.syncCursor);
  const floor = now - options.maxGapDays * DAY_MS;
  let after = saved ? Math.max(Date.parse(saved.after), floor) : now - options.lookbackDays * DAY_MS;
  const seen = new Map(Object.entries(saved?.seen ?? {}));

  const decisions: GmailDecisionCounts = {};
  const created: string[] = [];
  let headersRead = 0;
  let bodiesLeft = options.maxItems;
  let alreadyIngested = 0;
  let rateLimited = false;
  const timeUp = () => options.deadline !== undefined && Date.now() > options.deadline;
  const outOfBudget = () => timeUp() || headersRead >= options.maxHeaders || bodiesLeft <= 0;
  /** 결정한 메일: 다음 목록에서 다시 읽지 않고, 이유별 개수를 센다 */
  const decide = (id: string, at: number, reason: GmailKeepReason | GmailDropReason) => {
    seen.set(id, at);
    decisions[reason] = (decisions[reason] ?? 0) + 1;
  };

  /** 여럿을 동시에 부른다. 속도 제한이면 Stop(여기까지 결정한 것은 남긴다), 그 밖의 오류는 그대로 던진다 */
  async function batch<T, R>(inputs: T[], call: (input: T) => Promise<R>): Promise<R[]> {
    const results = await Promise.allSettled(inputs.map(call));
    const failed = results.find((r): r is PromiseRejectedResult => r.status === "rejected");
    if (failed) {
      if (isRateLimited(failed.reason)) {
        rateLimited = true;
        throw new Stop();
      }
      throw failed.reason;
    }
    return results.map((r) => (r as PromiseFulfilledResult<R>).value);
  }

  async function listWindow(start: number, end: number): Promise<GmailMessageRef[]> {
    const refs: GmailMessageRef[] = [];
    let pageToken: string | undefined;
    do {
      const [page] = await batch([pageToken], (token) => client.listMessages(gmailQuery(start, end), token));
      refs.push(...page.messages);
      pageToken = page.nextPageToken ?? undefined;
    } while (pageToken);
    return refs;
  }

  // 창 길이: 결정할 메일이 seen에 다 담기지 않을 만큼 많은 날은 반씩 줄인다 (seen을 넘치면 오래된 결정부터 잊어 커서가 그 창에 묶인다)
  let span = options.windowMs;
  const minSpan = 2 * options.overlapMs;
  try {
    while (!outOfBudget()) {
      const start = after - options.overlapMs;
      const end = Math.min(start + span, now);
      const refs = await listWindow(start, end);

      // 이미 결정한 메일 · 이미 넣은 메일(끊긴 연결의 원문 포함)은 머리글도 읽지 않는다
      const unseen = [...new Map(refs.filter((r) => !seen.has(r.id)).map((r) => [r.id, r])).values()];
      if (unseen.length > options.maxSeen - options.maxHeaders && span > minSpan) {
        span = Math.max(Math.floor(span / 2), minSpan);
        continue;
      }
      const ingested = await deps.ingestedIds(connection, unseen.map((r) => r.id));
      alreadyIngested += ingested.size;
      // 목록은 보통 새것부터 온다: 오래된 것부터 본다
      const pending = unseen.filter((r) => !ingested.has(r.id)).reverse();

      const kept: { meta: GmailMetadata; reason: GmailKeepReason }[] = [];
      let complete = true;
      let next = 0;
      while (next < pending.length) {
        const size = Math.min(options.concurrency, options.maxHeaders - headersRead, pending.length - next);
        if (timeUp() || size <= 0 || kept.length >= bodiesLeft) {
          complete = false;
          break;
        }
        const refsNow = pending.slice(next, next + size);
        next += size;
        headersRead += refsNow.length;
        for (const meta of await batch(refsNow, (r) => client.metadata(r.id))) {
          if (!meta) continue; // 그 사이 지워짐: 다시 목록에 나오지 않는다
          const decision = filterMessage(meta, input.filter);
          if (decision.keep) kept.push({ meta, reason: decision.reason });
          else decide(meta.id, meta.internalDate, decision.reason);
        }
      }

      // 남긴 메일만 본문을 받는다 (오래된 것부터, 넣기 상한까지). 넘친 것은 다음 동기화에서 다시 본다
      kept.sort((a, b) => a.meta.internalDate - b.meta.internalDate);
      const fetchNow = kept.slice(0, bodiesLeft);
      if (fetchNow.length < kept.length) complete = false;
      const items: { item: IngestItem; reason: GmailKeepReason }[] = [];
      for (let i = 0; i < fetchNow.length; i += options.concurrency) {
        if (timeUp()) {
          complete = false;
          break;
        }
        const chunk = fetchNow.slice(i, i + options.concurrency);
        const messages = await batch(chunk, ({ meta }) => client.message(meta.id));
        messages.forEach((message, j) => {
          if (message) items.push({ item: messageToItem(message, input.accountEmail), reason: chunk[j].reason });
        });
      }
      bodiesLeft -= fetchNow.length;

      const result = await ingestItems(
        connection,
        items.map(({ item }) => item),
        deps,
        { now: options.now, settleMinutes: 0, maxItems: options.maxItems, minTextLength: 1, deadline: options.deadline },
      );
      created.push(...result.created);
      const notReached = new Set(result.notReached);
      for (const { item, reason } of items) {
        // 시간 한도로 넣지 못했거나, 서버 시계보다 뒤의 시각이라 ingestItems가 안정화 중으로 건너뛴 메일은 다음에 다시 본다
        if (notReached.has(item.externalId) || item.lastEditedAt > options.now) complete = false;
        else decide(item.externalId, item.occurredAt.getTime(), reason);
      }

      if (!complete) break;
      after = end;
      span = options.windowMs;
      if (end >= now) break;
    }
  } catch (error) {
    if (!(error instanceof Stop)) throw error;
  }

  // after − 겹침보다 먼저 받은 메일은 다시 목록에 나오지 않는다. 너무 많으면 최근 것만 남긴다
  const recent = [...seen].filter(([, at]) => at >= after - options.overlapMs).sort((a, b) => b[1] - a[1]).slice(0, options.maxSeen);
  const skipped: Record<string, number> = { alreadyIngested };
  for (const [reason, count] of Object.entries(decisions)) if (reason !== "sent" && reason !== "inbound") skipped[reason] = count;

  return {
    created,
    scanned: headersRead,
    skipped,
    cursor: { after: new Date(after).toISOString(), seen: Object.fromEntries(recent) },
    decisions,
    rateLimited,
  };
}
