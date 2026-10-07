import { describe, expect, it, vi } from "vitest";

import { ConsentRequiredError } from "@/lib/consent/gate";

import type { Connection, IngestItem } from "../types";

import type { StoredSlackMessage } from "./bucket";
import { SlackError } from "./client";
import { syncSlack, type CachedSlackName, type SlackNameApi, type SlackSyncDeps } from "./sync";

const connection: Connection = {
  id: "conn-a",
  userId: "user-a",
  provider: "slack",
  settings: { slackUserId: "UME", teamId: "T1", teamUrl: "https://acme.slack.com/" },
  syncCursor: null,
};

const NOW = new Date("2026-10-07T15:30:00+09:00");
const ts = (kst: string) => `${Date.parse(`2026-10-07T${kst}:00+09:00`) / 1000}.000100`;
const dm = (kst: string, senderId: string, text: string): StoredSlackMessage => ({
  channelId: "D1",
  channelType: "im",
  ts: ts(kst),
  threadTs: null,
  senderId,
  text,
  editedAt: null,
});

function fakes(messages: StoredSlackMessage[], over: Partial<SlackSyncDeps> = {}, cached: CachedSlackName[] = []) {
  const log = {
    inserted: [] as { item: IngestItem; rows: { channelId: string; ts: string }[] }[],
    processed: [] as string[],
    cleared: [] as string[],
    repurged: [] as string[],
    savedNames: [] as Omit<CachedSlackName, "fetchedAt">[],
    apiCalls: [] as string[],
  };
  const api: SlackNameApi = {
    userName: async (id) => {
      log.apiCalls.push(`user:${id}`);
      return ({ UKIM: "김대표", UPARK: "박지훈" } as Record<string, string>)[id] ?? null;
    },
    conversation: async (id) => {
      log.apiCalls.push(`conversation:${id}`);
      return id === "D1" ? { name: null, counterpartId: "UKIM" } : { name: "ops", counterpartId: null };
    },
  };
  const deps: SlackSyncDeps = {
    pending: async () => messages,
    cachedNames: async (_c, ids) => cached.filter((c) => ids.includes(c.slackId)),
    saveNames: async (_c, names) => void log.savedNames.push(...names),
    identity: async () => ({ name: "윤지호", aliases: [], emails: [] }),
    ingestedIds: async () => new Set(),
    insertSource: async (_c, item, rows) => {
      log.inserted.push({ item, rows });
      return `source-${log.inserted.length}`;
    },
    process: async (_c, sourceId) => void log.processed.push(sourceId),
    clearText: async (_c, sourceId) => void log.cleared.push(sourceId),
    repurgeIfDisconnected: async (_c, sourceId) => void log.repurged.push(sourceId),
    ...over,
  };
  return { api, deps, log };
}

describe("syncSlack", () => {
  it("멈춘 대화를 원문으로 넣고, 읽은 행을 함께 넘기고, 처리가 끝나면 대기 행 본문을 비운다", async () => {
    const { api, deps, log } = fakes([dm("14:30", "UKIM", "제안서는 월요일에 받아도 괜찮아요."), dm("14:32", "UME", "넵 알겠습니다!")]);
    const result = await syncSlack(connection, api, deps, { now: NOW });
    expect(result).toMatchObject({ created: ["source-1"], scanned: 1 });
    expect(log.inserted[0].item.text).toBe("[DM · 김대표]\n김대표: 제안서는 월요일에 받아도 괜찮아요.\n윤지호: 넵 알겠습니다!");
    expect(log.inserted[0].rows).toEqual([
      { channelId: "D1", ts: ts("14:30") },
      { channelId: "D1", ts: ts("14:32") },
    ]);
    expect(log.processed).toEqual(["source-1"]);
    expect(log.cleared).toEqual(["source-1"]);
    // 처리 도중 연결이 끊겼으면 처리가 쓴 글자도 지우도록 늘 확인한다
    expect(log.repurged).toEqual(["source-1"]);
  });

  it("DM 상대는 대화 정보로 찾고, 찾은 이름을 캐시에 남긴다. 캐시에 있는 이름은 다시 묻지 않는다", async () => {
    const first = fakes([dm("14:30", "UME", "IR 자료는 금요일까지 공유드릴게요")]);
    await syncSlack(connection, first.api, first.deps, { now: NOW });
    expect(first.log.apiCalls).toEqual(["conversation:D1", "user:UKIM"]);
    expect(first.log.savedNames).toEqual([
      { slackId: "UKIM", kind: "user", name: "김대표" },
      { slackId: "D1", kind: "conversation", name: "김대표" },
    ]);

    const cached: CachedSlackName[] = [{ slackId: "D1", kind: "conversation", name: "김대표", fetchedAt: new Date("2026-10-06T00:00:00Z") }];
    const second = fakes([dm("14:30", "UME", "IR 자료는 금요일까지 공유드릴게요")], {}, cached);
    await syncSlack(connection, second.api, second.deps, { now: NOW });
    expect(second.log.apiCalls).toEqual([]);

    // 7일이 지난 이름은 다시 묻는다
    const stale = fakes([dm("14:30", "UME", "메모")], {}, [{ ...cached[0], fetchedAt: new Date("2026-09-20T00:00:00Z") }]);
    await syncSlack(connection, stale.api, stale.deps, { now: NOW });
    expect(stale.log.apiCalls).toContain("conversation:D1");
  });

  it("synthetic bot sender는 users.info 조회에서 건너뛰고 실제 사람 mention은 계속 푼다", async () => {
    const bot = fakes([dm("14:30", "bot:B123", "<@UKIM> 배포는 금요일까지 확인해 주세요")]);
    await syncSlack(connection, bot.api, bot.deps, { now: NOW });
    expect(bot.log.apiCalls).not.toContain("user:bot:B123");
    expect(bot.log.apiCalls).toContain("user:UKIM");
    expect(bot.log.inserted[0].item.text).toContain("Slack app: @김대표 배포는 금요일까지 확인해 주세요");

    const app = fakes([dm("14:30", "app:A123", "일정은 금요일입니다")]);
    await syncSlack(connection, app.api, app.deps, { now: NOW });
    expect(app.log.apiCalls).not.toContain("user:app:A123");
    expect(app.log.inserted[0].item.text).toContain("Slack app: 일정은 금요일입니다");
  });

  it("Slack이 그 id가 없다고 하면 이름 없이 넣고, 그 밖의 오류(토큰 · 속도 제한 · 장애)는 동기화를 멈춘다", async () => {
    const missing = fakes([dm("14:30", "UGONE", "금요일까지 부탁드려요")]);
    missing.api.userName = async () => {
      throw new SlackError("x", "user_not_found");
    };
    missing.api.conversation = async () => ({ name: null, counterpartId: null });
    await syncSlack(connection, missing.api, missing.deps, { now: NOW });
    expect(missing.log.inserted[0].item.text).toBe("[DM]\n알 수 없는 사용자: 금요일까지 부탁드려요");
    expect(missing.log.savedNames).toContainEqual({ slackId: "UGONE", kind: "user", name: "" });

    for (const code of ["token_revoked", "ratelimited", "bad_response", "internal_error"]) {
      const broken = fakes([dm("14:30", "UKIM", "메모")]);
      broken.api.conversation = async () => {
        throw new SlackError("x", code);
      };
      await expect(syncSlack(connection, broken.api, broken.deps, { now: NOW })).rejects.toMatchObject({ code });
      expect(broken.log.inserted).toEqual([]);
    }
  });

  it("멈추기 전에 찾은 이름은 남긴다 (다음 동기화가 이어서 찾는다)", async () => {
    const { api, deps, log } = fakes([dm("14:30", "UKIM", "메모"), { ...dm("14:31", "UPARK", "메모"), channelId: "C1", channelType: "channel" }]);
    api.conversation = async (id) => {
      if (id === "C1") throw new SlackError("x", "ratelimited");
      return { name: null, counterpartId: "UKIM" };
    };
    await expect(syncSlack(connection, api, deps, { now: NOW })).rejects.toMatchObject({ code: "ratelimited" });
    expect(log.savedNames).toEqual([
      { slackId: "UKIM", kind: "user", name: "김대표" },
      { slackId: "D1", kind: "conversation", name: "김대표" },
    ]);
  });

  it("대화가 아직 이어지는 중(30분 전)이면 넣지 않고, 대기 메시지가 없으면 Slack을 부르지 않는다", async () => {
    const recent = fakes([dm("15:10", "UKIM", "혹시 내일 가능할까요?")]);
    const result = await syncSlack(connection, recent.api, recent.deps, { now: NOW });
    expect(result.created).toEqual([]);
    expect(result.skipped).toMatchObject({ settling: 1 });

    const empty = fakes([]);
    expect(await syncSlack(connection, empty.api, empty.deps, { now: NOW })).toEqual({ created: [], scanned: 0, skipped: {} });
    expect(empty.log.apiCalls).toEqual([]);
  });

  it("이미 넣은 묶음은 건너뛰고, 넣지 않은 묶음(insertSource가 null: 동시 동기화 · 읽은 뒤 지운 메시지)은 처리하지 않는다", async () => {
    const already = fakes([dm("14:30", "UKIM", "메모")], { ingestedIds: async (_c, ids) => new Set(ids) });
    expect((await syncSlack(connection, already.api, already.deps, { now: NOW })).skipped).toMatchObject({ alreadyIngested: 1 });
    expect(already.log.inserted).toEqual([]);

    const { api, deps, log } = fakes([dm("14:30", "UKIM", "메모")], { insertSource: async () => null });
    const result = await syncSlack(connection, api, deps, { now: NOW });
    expect(result.created).toEqual([]);
    expect(result.skipped).toMatchObject({ alreadyIngested: 1 });
    expect(log.processed).toEqual([]);
  });

  it("동의를 철회해 처리가 멈추면 대기 행 본문을 비우지 않는다 (다시 동의하면 다시 묶는다)", async () => {
    const { api, deps, log } = fakes([dm("14:30", "UKIM", "메모")], {
      process: async () => {
        throw new ConsentRequiredError();
      },
    });
    await expect(syncSlack(connection, api, deps, { now: NOW })).rejects.toBeInstanceOf(ConsentRequiredError);
    expect(log.cleared).toEqual([]);
    expect(log.repurged).toEqual(["source-1"]);

    // 다시 지우기 확인이 실패해도 동의 철회 오류를 가리지 않는다
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const failing = fakes([dm("14:30", "UKIM", "메모")], {
      process: async () => {
        throw new ConsentRequiredError();
      },
      repurgeIfDisconnected: async () => {
        throw new Error("db down");
      },
    });
    await expect(syncSlack(connection, failing.api, failing.deps, { now: NOW })).rejects.toBeInstanceOf(ConsentRequiredError);
    error.mockRestore();
  });

  it("첫 글이 대기 목록에 없는 채널 스레드는 첫 묶음을 넣었는지 물어 '이어서' · '중간부터'를 가른다", async () => {
    const parent = ts("10:00");
    const reply: StoredSlackMessage = { channelId: "C1", channelType: "channel", ts: ts("14:30"), threadTs: parent, senderId: "UPARK", text: "<@UME> 금요일 오전까지만 주셔도 돼요", editedAt: null };
    const asked: string[][] = [];
    const { api, deps, log } = fakes([reply], {
      ingestedIds: async (_c, ids) => {
        asked.push(ids);
        return new Set(ids.filter((id) => id === `t:C1:${parent}:${parent}`));
      },
    });
    await syncSlack(connection, api, deps, { now: NOW });
    expect(asked[0]).toEqual([`t:C1:${parent}:${parent}`]);
    expect(log.inserted[0].item.text).toBe("[#ops · 스레드 이어서]\n박지훈: @윤지호 금요일 오전까지만 주셔도 돼요");
  });

  it("연결 설정에 Slack id가 없으면 던진다 (다시 연결해야 한다)", async () => {
    const { api, deps } = fakes([dm("14:30", "UKIM", "메모")]);
    await expect(syncSlack({ ...connection, settings: {} }, api, deps, { now: NOW })).rejects.toThrow();
  });
});
