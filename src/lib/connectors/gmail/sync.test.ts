import { afterEach, describe, expect, it, vi } from "vitest";

import type { IngestDeps } from "../ingest";
import { GoogleApiError } from "../google/token";
import type { Connection, IngestItem } from "../types";

import type { GmailClient, GmailMetadata } from "./client";
import { DEFAULT_GMAIL_SYNC, gmailQuery, syncGmail, type GmailCursor, type GmailSyncOptions } from "./sync";

// Gmail 동기화 (G6 · G7 · G8, docs/go-live/google-integration.md 2-6 목록 · 한도 · 커서 · 창).

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const NOW = Date.parse("2026-09-29T12:00:00.000Z");
const iso = (ms: number) => new Date(ms).toISOString();
const seconds = (ms: number) => Math.floor(ms / 1000);

type Mail = { id: string; at: number; labels?: string[]; headers?: Record<string, string>; body?: string };

/** 받은 편지함 흉내: 목록은 검색어의 after: · before:(epoch 초) 창 안의 메일을 새것부터, 쪽마다 pageSize개 */
function fakeGmail(
  mails: Mail[],
  options: {
    pageSize?: number;
    fail?: { list?: Error; metadata?: Record<string, Error>; message?: Record<string, Error> };
    deleted?: { metadata?: string[]; message?: string[] };
    afterMetadata?: () => void;
  } = {},
) {
  const queries: string[] = [];
  const pageTokens: (string | undefined)[] = [];
  const metadataCalls: string[] = [];
  const messageCalls: string[] = [];
  const metadataOf = (mail: Mail): GmailMetadata => ({
    id: mail.id,
    threadId: `thread-${mail.id}`,
    labelIds: mail.labels ?? ["INBOX"],
    internalDate: mail.at,
    headers: { from: "Jordan Lee <jordan@acme.io>", to: "me@company.dev", subject: `Mail ${mail.id}`, ...mail.headers },
  });
  const client: GmailClient = {
    listMessages: async (query, pageToken) => {
      queries.push(query);
      pageTokens.push(pageToken);
      if (options.fail?.list) throw options.fail.list;
      const [, after, before] = query.match(/after:(\d+) before:(\d+)/)!.map(Number);
      const inWindow = mails.filter((m) => m.at >= after * 1000 && m.at < before * 1000).sort((a, b) => b.at - a.at);
      const size = options.pageSize ?? 500;
      const start = pageToken ? Number(pageToken) : 0;
      return {
        messages: inWindow.slice(start, start + size).map((m) => ({ id: m.id, threadId: `thread-${m.id}` })),
        nextPageToken: start + size < inWindow.length ? String(start + size) : null,
      };
    },
    metadata: async (id) => {
      metadataCalls.push(id);
      options.afterMetadata?.();
      const failure = options.fail?.metadata?.[id];
      if (failure) throw failure;
      const mail = mails.find((m) => m.id === id);
      return mail && !options.deleted?.metadata?.includes(id) ? metadataOf(mail) : null;
    },
    message: async (id) => {
      messageCalls.push(id);
      const failure = options.fail?.message?.[id];
      if (failure) throw failure;
      const mail = mails.find((m) => m.id === id);
      if (!mail || options.deleted?.message?.includes(id)) return null;
      return { ...metadataOf(mail), payload: { mimeType: "text/plain", body: { data: Buffer.from(mail.body ?? `Body of ${mail.id}`).toString("base64url") } } };
    },
  };
  return { client, queries, pageTokens, metadataCalls, messageCalls };
}

/** 이미 넣은 원문 id를 알고, 넣은 항목 · 처리한 원문을 남기는 가짜 넣기 */
function fakeIngest(already: string[] = []) {
  const inserted: IngestItem[] = [];
  const processed: string[] = [];
  const deps: IngestDeps = {
    ingestedIds: vi.fn(async (_connection: Connection, ids: string[]) => new Set(ids.filter((id) => already.includes(id)))),
    insertSource: async (_connection, item) => {
      inserted.push(item);
      return `src-${item.externalId}`;
    },
    process: async (_connection, sourceId) => {
      processed.push(sourceId);
    },
  };
  return { deps, inserted, processed };
}

const connection = (cursor: GmailCursor | Record<string, unknown> | null = null): Connection => ({
  id: "c1",
  userId: "u1",
  provider: "gmail",
  settings: {},
  syncCursor: cursor,
});
const input = { filter: { userEmails: ["me@company.dev"], companyDomain: "company.dev" }, accountEmail: "me@company.dev" };
const options = (extra: Partial<GmailSyncOptions> = {}): GmailSyncOptions => ({ now: new Date(NOW), ...DEFAULT_GMAIL_SYNC, ...extra });
/** 검색어의 창 [after, before) (epoch 초) */
const windowOf = (query: string) => query.match(/after:(\d+) before:(\d+)/)!.slice(1).map(Number) as [number, number];
const promo = (id: string, at: number): Mail => ({ id, at, labels: ["INBOX", "CATEGORY_PROMOTIONS"] });

afterEach(() => {
  vi.restoreAllMocks();
});

describe("기본값 (문서 2-6)", () => {
  it("첫 14일 · 최대 30일 · 겹침 1시간 · 하루 창 · 머리글 200 · 본문 20 · 동시 4 · seen 2,000", () => {
    expect(DEFAULT_GMAIL_SYNC).toEqual({
      lookbackDays: 14,
      maxGapDays: 30,
      overlapMs: HOUR,
      windowMs: DAY,
      maxHeaders: 200,
      maxItems: 20,
      concurrency: 4,
      maxSeen: 2_000,
    });
  });

  it("검색어: 창(epoch 초)과 채팅 · 임시 보관 · 프로모션 · 소셜 빼기", () => {
    expect(gmailQuery(NOW - DAY, NOW)).toBe(`after:${seconds(NOW - DAY)} before:${seconds(NOW)} -in:chats -in:drafts -category:promotions -category:social`);
  });

  it("창 끝은 내림한다 (지금 뒤 1초 안에 받은 메일이 창에 들어와 결정된 것으로 남지 않게)", () => {
    expect(windowOf(gmailQuery(NOW - DAY, NOW + 900))[1]).toBe(seconds(NOW));
  });
});

describe("syncGmail: 커서 · 창", () => {
  it("첫 동기화는 14일 전부터, after − 1시간에서 시작하는 하루 창을 오래된 것부터 받고 지금까지 따라잡는다", async () => {
    const gmail = fakeGmail([]);
    const result = await syncGmail(connection(), gmail.client, fakeIngest().deps, input, options());

    const start = NOW - 14 * DAY - HOUR;
    expect(gmail.queries[0]).toBe(`after:${seconds(start)} before:${seconds(start + DAY)} -in:chats -in:drafts -category:promotions -category:social`);
    const windows = gmail.queries.map(windowOf);
    for (let i = 1; i < windows.length; i++) {
      // 다음 창은 앞 창 끝(= 새 after) − 1시간에서 시작한다
      expect(windows[i][0]).toBe(windows[i - 1][1] - 3600);
    }
    for (const [after, before] of windows.slice(0, -1)) expect(before - after).toBe(86_400);
    expect(windows.at(-1)![1]).toBe(seconds(NOW));
    // 14일을 23시간씩 나아가므로 창 15개
    expect(windows).toHaveLength(15);
    expect(result.cursor).toEqual({ after: iso(NOW), seen: {} });
    expect(result.rateLimited).toBe(false);
  });

  it("저장된 커서가 30일보다 오래됐으면(끊겼다 다시 연결) 30일 전으로 당긴다", async () => {
    const gmail = fakeGmail([]);
    await syncGmail(connection({ after: iso(NOW - 45 * DAY), seen: {} }), gmail.client, fakeIngest().deps, input, options());
    expect(windowOf(gmail.queries[0])[0]).toBe(seconds(NOW - 30 * DAY - HOUR));
  });

  it("30일 안의 커서는 그대로 이어 간다", async () => {
    const gmail = fakeGmail([]);
    await syncGmail(connection({ after: iso(NOW - 3 * DAY), seen: {} }), gmail.client, fakeIngest().deps, input, options());
    expect(windowOf(gmail.queries[0])[0]).toBe(seconds(NOW - 3 * DAY - HOUR));
  });

  it("커서 모양이 다르면 첫 동기화처럼 14일 전부터", async () => {
    const gmail = fakeGmail([]);
    await syncGmail(connection({ since: "2026-09-01T00:00:00Z" }), gmail.client, fakeIngest().deps, input, options());
    expect(windowOf(gmail.queries[0])[0]).toBe(seconds(NOW - 14 * DAY - HOUR));
  });

  it("창 하나를 다 결정하면 after를 창 끝으로 옮기고, 다음 창에서 멈추면 거기 그대로 둔다", async () => {
    // 창 1: [NOW−37h, NOW−13h), 창 2: [NOW−14h, NOW)
    const mails = [promo("a", NOW - 30 * HOUR), promo("b", NOW - 12 * HOUR), promo("c", NOW - 11 * HOUR)];
    const gmail = fakeGmail(mails);
    const result = await syncGmail(connection({ after: iso(NOW - 36 * HOUR), seen: {} }), gmail.client, fakeIngest().deps, input, options({ maxHeaders: 2 }));

    expect(gmail.metadataCalls).toEqual(["a", "b"]);
    expect(result.cursor.after).toBe(iso(NOW - 13 * HOUR));
    // a는 새 after − 1시간보다 앞이라 다시 목록에 나오지 않는다: seen에 남기지 않는다
    expect(result.cursor.seen).toEqual({ b: NOW - 12 * HOUR });
    expect(result.scanned).toBe(2);
  });

  it("한 창의 목록은 다음 쪽까지 끝까지 받는다", async () => {
    const mails = Array.from({ length: 5 }, (_, i) => promo(`m${i}`, NOW - 50 * MINUTE + i * MINUTE));
    const gmail = fakeGmail(mails, { pageSize: 2 });
    const result = await syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, fakeIngest().deps, input, options());

    expect(gmail.pageTokens).toEqual([undefined, "2", "4"]);
    expect([...gmail.metadataCalls].sort()).toEqual(["m0", "m1", "m2", "m3", "m4"]);
    expect(result.cursor.after).toBe(iso(NOW));
  });
});

describe("syncGmail: 머리글 읽기 · 거르기 · 본문 받기", () => {
  it("seen에 있거나 이미 넣은 메일은 머리글을 읽지 않는다", async () => {
    const mails: Mail[] = [
      { id: "seen-1", at: NOW - 20 * MINUTE },
      { id: "ingested-1", at: NOW - 15 * MINUTE },
      { id: "new-1", at: NOW - 10 * MINUTE, labels: ["INBOX", "CATEGORY_SOCIAL"] },
    ];
    const gmail = fakeGmail(mails);
    const ingest = fakeIngest(["ingested-1"]);
    const result = await syncGmail(
      connection({ after: iso(NOW - 30 * MINUTE), seen: { "seen-1": NOW - 20 * MINUTE } }),
      gmail.client,
      ingest.deps,
      input,
      options(),
    );

    expect(gmail.metadataCalls).toEqual(["new-1"]);
    expect(ingest.deps.ingestedIds).toHaveBeenCalledWith(expect.anything(), expect.arrayContaining(["ingested-1", "new-1"]));
    expect(vi.mocked(ingest.deps.ingestedIds).mock.calls[0][1]).not.toContain("seen-1");
    expect(result.skipped.alreadyIngested).toBe(1);
    expect(result.cursor.seen).toEqual({ "seen-1": NOW - 20 * MINUTE, "new-1": NOW - 10 * MINUTE });
  });

  it("거른 메일은 본문을 받지 않고, 남긴 메일만 본문을 받는다. 이유별로 센다", async () => {
    const at = (m: number) => NOW - 50 * MINUTE + m * MINUTE;
    const mails: Mail[] = [
      promo("promo", at(1)),
      { id: "list", at: at(2), headers: { "list-unsubscribe": "<https://news.acme.io/u>" } },
      { id: "noreply", at: at(3), headers: { from: "Acme <no-reply@acme.io>" } },
      { id: "kept", at: at(4) },
      { id: "mine", at: at(5), labels: ["SENT"], headers: { from: "me@company.dev" } },
    ];
    const gmail = fakeGmail(mails);
    const ingest = fakeIngest();
    const result = await syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, ingest.deps, input, options());

    expect(gmail.messageCalls).toEqual(["kept", "mine"]);
    expect(result.decisions).toEqual({ category: 1, mailing_list: 1, no_reply: 1, inbound: 1, sent: 1 });
    expect(result.skipped).toEqual({ alreadyIngested: 0, category: 1, mailing_list: 1, no_reply: 1 });
    expect(result.created).toEqual(["src-kept", "src-mine"]);
    expect(result.scanned).toBe(5);
    expect(Object.keys(result.cursor.seen).sort()).toEqual(["kept", "list", "mine", "noreply", "promo"]);
  });

  it("남긴 메일은 기다리지 않고(settleMinutes 0) 짧아도(minTextLength 1) 원문으로 넣는다", async () => {
    const mail: Mail = { id: "ok", at: NOW - MINUTE, headers: { subject: "Re: plan" }, body: "OK" };
    const gmail = fakeGmail([mail]);
    const ingest = fakeIngest();
    const result = await syncGmail(connection({ after: iso(NOW - 10 * MINUTE), seen: {} }), gmail.client, ingest.deps, input, options());

    expect(result.created).toEqual(["src-ok"]);
    expect(ingest.processed).toEqual(["src-ok"]);
    expect(ingest.inserted).toEqual([
      expect.objectContaining({
        externalId: "ok",
        kind: "email",
        text: "제목: Re: plan\n\nOK",
        occurredAt: new Date(NOW - MINUTE),
        externalUrl: "https://mail.google.com/mail/?authuser=me%40company.dev#all/thread-ok",
      }),
    ]);
    expect(result.cursor.seen).toEqual({ ok: NOW - MINUTE });
  });

  it("목록과 머리글 읽기 사이에 지워진 메일은 건너뛴다 (결정하지 않고, 창은 마친다)", async () => {
    const gmail = fakeGmail([{ id: "gone", at: NOW - 30 * MINUTE }, { id: "kept", at: NOW - 20 * MINUTE }], { deleted: { metadata: ["gone"] } });
    const result = await syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, fakeIngest().deps, input, options());

    expect(gmail.messageCalls).toEqual(["kept"]);
    expect(result.cursor).toEqual({ after: iso(NOW), seen: { kept: NOW - 20 * MINUTE } });
    expect(result.decisions).toEqual({ inbound: 1 });
  });

  it("머리글과 본문 받기 사이에 지워진 메일은 넣지 않는다", async () => {
    const gmail = fakeGmail([{ id: "gone", at: NOW - 30 * MINUTE }], { deleted: { message: ["gone"] } });
    const ingest = fakeIngest();
    const result = await syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, ingest.deps, input, options());

    expect(ingest.inserted).toEqual([]);
    expect(result.cursor.seen).toEqual({});
  });
});

describe("syncGmail: 한도 · 멈춤", () => {
  it("머리글 상한에서 멈추면 after는 그대로, 결정한 id만 seen에 남고 다음 동기화가 이어 간다", async () => {
    const mails = Array.from({ length: 5 }, (_, i) => promo(`m${i + 1}`, NOW - 170 * MINUTE + i * MINUTE));
    const gmail = fakeGmail(mails);
    const saved = { after: iso(NOW - 2 * HOUR), seen: {} };
    const first = await syncGmail(connection(saved), gmail.client, fakeIngest().deps, input, options({ maxHeaders: 3, concurrency: 2 }));

    // 오래된 것부터
    expect(gmail.metadataCalls).toEqual(["m1", "m2", "m3"]);
    expect(first.scanned).toBe(3);
    expect(first.cursor.after).toBe(saved.after);
    expect(Object.keys(first.cursor.seen).sort()).toEqual(["m1", "m2", "m3"]);
    expect(first.decisions).toEqual({ category: 3 });

    const next = fakeGmail(mails);
    const second = await syncGmail(connection(first.cursor), next.client, fakeIngest().deps, input, options({ maxHeaders: 3, concurrency: 2 }));
    expect(next.metadataCalls).toEqual(["m4", "m5"]);
    expect(second.cursor.after).toBe(iso(NOW));
  });

  it("본문 상한(maxItems)에 닿으면 남긴 메일을 더 읽지 않고 멈춘다. 넣은 것만 seen에", async () => {
    const mails: Mail[] = Array.from({ length: 4 }, (_, i) => ({ id: `k${i + 1}`, at: NOW - 50 * MINUTE + i * MINUTE }));
    const gmail = fakeGmail(mails);
    const saved = { after: iso(NOW - HOUR), seen: {} };
    const result = await syncGmail(connection(saved), gmail.client, fakeIngest().deps, input, options({ maxItems: 2, concurrency: 2 }));

    expect(gmail.metadataCalls).toEqual(["k1", "k2"]);
    expect(gmail.messageCalls).toEqual(["k1", "k2"]);
    expect(result.created).toEqual(["src-k1", "src-k2"]);
    expect(result.cursor).toEqual({ after: saved.after, seen: { k1: NOW - 50 * MINUTE, k2: NOW - 49 * MINUTE } });
  });

  it("한 번에 읽은 머리글이 본문 상한보다 많이 남으면 넘친 메일은 결정하지 않는다", async () => {
    const mails: Mail[] = Array.from({ length: 3 }, (_, i) => ({ id: `k${i + 1}`, at: NOW - 50 * MINUTE + i * MINUTE }));
    const gmail = fakeGmail(mails);
    const saved = { after: iso(NOW - HOUR), seen: {} };
    const result = await syncGmail(connection(saved), gmail.client, fakeIngest().deps, input, options({ maxItems: 1, concurrency: 4 }));

    expect(gmail.messageCalls).toEqual(["k1"]);
    expect(result.cursor).toEqual({ after: saved.after, seen: { k1: NOW - 50 * MINUTE } });
  });

  it("시간 한도를 넘기면 결정한 것(거른 메일)만 남기고 본문은 받지 않는다", async () => {
    let clock = 1_000;
    vi.spyOn(Date, "now").mockImplementation(() => clock);
    const mails: Mail[] = [promo("dropped", NOW - 50 * MINUTE), { id: "kept", at: NOW - 40 * MINUTE }, { id: "later", at: NOW - 30 * MINUTE }];
    const gmail = fakeGmail(mails, { afterMetadata: () => (clock = 2_000) });
    const saved = { after: iso(NOW - HOUR), seen: {} };
    const ingest = fakeIngest();
    const result = await syncGmail(connection(saved), gmail.client, ingest.deps, input, options({ concurrency: 2, deadline: 1_500 }));

    expect(gmail.metadataCalls).toEqual(["dropped", "kept"]);
    expect(gmail.messageCalls).toEqual([]);
    expect(ingest.inserted).toEqual([]);
    expect(result.cursor).toEqual({ after: saved.after, seen: { dropped: NOW - 50 * MINUTE } });
  });

  it("시작부터 시간 한도를 넘겼으면 아무것도 부르지 않고 커서를 그대로 둔다", async () => {
    const gmail = fakeGmail([promo("m1", NOW - 10 * MINUTE)]);
    const saved = { after: iso(NOW - HOUR), seen: { x: NOW - 30 * MINUTE } };
    const result = await syncGmail(connection(saved), gmail.client, fakeIngest().deps, input, options({ deadline: 0 }));

    expect(gmail.queries).toEqual([]);
    expect(result.cursor).toEqual(saved);
  });

  it("머리글 읽기가 429면 멈추고 rateLimited. 그 전에 결정한 것은 남긴다", async () => {
    const mails = Array.from({ length: 4 }, (_, i) => promo(`m${i + 1}`, NOW - 50 * MINUTE + i * MINUTE));
    const gmail = fakeGmail(mails, { fail: { metadata: { m3: new GoogleApiError("Gmail 요청 실패 (429 rateLimitExceeded)", 429, "rateLimitExceeded") } } });
    const saved = { after: iso(NOW - HOUR), seen: {} };
    const result = await syncGmail(connection(saved), gmail.client, fakeIngest().deps, input, options({ concurrency: 2 }));

    expect(result.rateLimited).toBe(true);
    expect(result.cursor).toEqual({ after: saved.after, seen: { m1: NOW - 50 * MINUTE, m2: NOW - 49 * MINUTE } });
    expect(result.decisions).toEqual({ category: 2 });
  });

  it("목록이 429여도 멈추고 rateLimited (커서 그대로)", async () => {
    const gmail = fakeGmail([], { fail: { list: new GoogleApiError("Gmail 요청 실패 (429)", 429) } });
    const saved = { after: iso(NOW - HOUR), seen: {} };
    const result = await syncGmail(connection(saved), gmail.client, fakeIngest().deps, input, options());
    expect(result.rateLimited).toBe(true);
    expect(result.cursor).toEqual(saved);
  });

  it("본문 받기가 429면 넣지 않고 멈춘다. 같은 창에서 거른 메일은 결정된 것으로 남긴다", async () => {
    const mails: Mail[] = [promo("dropped", NOW - 50 * MINUTE), { id: "kept", at: NOW - 40 * MINUTE }];
    const gmail = fakeGmail(mails, { fail: { message: { kept: new GoogleApiError("Gmail 요청 실패 (429)", 429) } } });
    const ingest = fakeIngest();
    const result = await syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, ingest.deps, input, options());

    expect(result.rateLimited).toBe(true);
    expect(ingest.inserted).toEqual([]);
    expect(result.cursor.seen).toEqual({ dropped: NOW - 50 * MINUTE });
  });

  it("429가 아닌 오류는 그대로 던진다", async () => {
    const gmail = fakeGmail([promo("m1", NOW - 10 * MINUTE)], { fail: { metadata: { m1: new GoogleApiError("Gmail 요청 실패 (403 insufficientPermissions)", 403) } } });
    await expect(syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, fakeIngest().deps, input, options())).rejects.toMatchObject({
      status: 403,
    });
  });

  it("원문 처리가 던지면(동의 철회 등) 그대로 던진다", async () => {
    const gmail = fakeGmail([{ id: "kept", at: NOW - 10 * MINUTE }]);
    const ingest = fakeIngest();
    ingest.deps.process = async () => {
      throw new Error("consent withdrawn");
    };
    await expect(syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, ingest.deps, input, options())).rejects.toThrow("consent withdrawn");
  });
});

describe("syncGmail: 멈추지 않기", () => {
  it("403 rateLimitExceeded · userRateLimitExceeded도 속도 제한으로 보고 멈춘다 (오류로 던지지 않는다)", async () => {
    for (const reason of ["rateLimitExceeded", "userRateLimitExceeded"]) {
      const gmail = fakeGmail([promo("m1", NOW - 30 * MINUTE)], { fail: { metadata: { m1: new GoogleApiError(`Gmail 요청 실패 (403 ${reason})`, 403, reason) } } });
      const result = await syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, fakeIngest().deps, input, options());
      expect(result.rateLimited).toBe(true);
    }
  });

  it("그 밖의 403(권한 부족)은 그대로 던진다", async () => {
    const gmail = fakeGmail([promo("m1", NOW - 30 * MINUTE)], { fail: { metadata: { m1: new GoogleApiError("Gmail 요청 실패 (403 insufficientPermissions)", 403, "insufficientPermissions") } } });
    await expect(syncGmail(connection({ after: iso(NOW - HOUR), seen: {} }), gmail.client, fakeIngest().deps, input, options())).rejects.toMatchObject({ status: 403 });
  });

  it("한 창의 메일이 seen에 다 담기지 않을 만큼 많으면 창을 반씩(2시간까지) 줄여, 여러 번의 동기화로 끝까지 따라잡는다", async () => {
    const after = NOW - 3 * DAY;
    // 첫 하루 창 앞부분에 거를 메일 12통 (seen 10 − 머리글 4 = 6통보다 많다)
    const busy = Array.from({ length: 12 }, (_, i) => promo(`b${i}`, after + i * MINUTE));
    const small = { maxSeen: 10, maxHeaders: 4, concurrency: 2 };

    const first = fakeGmail(busy);
    const once = await syncGmail(connection({ after: iso(after), seen: {} }), first.client, fakeIngest().deps, input, options(small));
    const spans = first.queries.map((q) => (windowOf(q)[1] - windowOf(q)[0]) / 3600);
    expect(spans).toEqual([24, 12, 6, 3, 2]);
    expect(Object.keys(once.cursor.seen)).toHaveLength(4);

    // 이어 가면 커서가 멈추지 않고 지금까지 오고, 같은 메일을 두 번 세지 않는다
    let cursor: GmailCursor = once.cursor;
    let category = once.decisions.category ?? 0;
    for (let run = 0; run < 20 && cursor.after !== iso(NOW); run++) {
      const next = await syncGmail(connection(cursor), fakeGmail(busy).client, fakeIngest().deps, input, options(small));
      cursor = next.cursor;
      category += next.decisions.category ?? 0;
    }
    expect(cursor.after).toBe(iso(NOW));
    expect(category).toBe(12);
  });
});

describe("syncGmail: seen 정리", () => {
  it("after − 겹침보다 먼저 받은 메일은 지우고, 너무 많으면 최근 것만 maxSeen개 남긴다", async () => {
    const after = NOW - 2 * HOUR;
    const saved = {
      after: iso(after),
      seen: { old: after - 2 * HOUR, r1: after - 30 * MINUTE, r2: after + 20 * MINUTE, r3: after + 30 * MINUTE },
    };
    const result = await syncGmail(connection(saved), fakeGmail([]).client, fakeIngest().deps, input, options({ deadline: 0, maxSeen: 2 }));
    expect(result.cursor.seen).toEqual({ r3: after + 30 * MINUTE, r2: after + 20 * MINUTE });
  });

  it("따라잡으면 지금 − 1시간 안에 받은 메일만 seen에 남긴다 (다음 창이 겹치는 부분)", async () => {
    const mails = [promo("older", NOW - 90 * MINUTE), promo("recent", NOW - 30 * MINUTE)];
    const result = await syncGmail(connection({ after: iso(NOW - 2 * HOUR), seen: {} }), fakeGmail(mails).client, fakeIngest().deps, input, options());
    expect(result.cursor).toEqual({ after: iso(NOW), seen: { recent: NOW - 30 * MINUTE } });
  });
});
