import { z } from "zod";

import type { UserIdentity } from "@/lib/pipeline/identity";

import { ingestItems, type IngestDeps } from "../ingest";
import type { Connection, ConnectorSyncResult, IngestItem } from "../types";

import { bucketSlackMessages, SLACK_BUCKET_LIMITS, slackIdsToName, threadStartIds, type StoredSlackMessage } from "./bucket";
import { SlackError } from "./client";

// Slack 연결 하나의 동기화: 대기 메시지 → 이름 찾기 → 묶기 → 원문으로 넣기 (docs/go-live/slack-integration.md 2-1 ⑥~⑧).
// DB · Slack 호출은 인자로 받는다(run.ts가 붙인다). 과거 메시지는 가져오지 않는다: 이벤트로 받아 둔 것만 넣는다.

/** 연결할 때 적는 설정 (connections.settings, run.ts connect) */
export const slackSettingsSchema = z.looseObject({
  slackUserId: z.string().min(1),
  teamId: z.string().regex(/^[A-Z0-9]{1,32}$/),
  /** 원본 링크의 워크스페이스 주소 (auth.test url) */
  teamUrl: z.string().nullish(),
});

export type CachedSlackName = { slackId: string; kind: "user" | "conversation"; name: string; fetchedAt: Date };

/** 이름을 모르는 id만 Slack에 묻는다. 토큰은 처음 부를 때 푼다 */
export type SlackNameApi = {
  userName: (userId: string) => Promise<string | null>;
  conversation: (channelId: string) => Promise<{ name: string | null; counterpartId: string | null }>;
};

export type SlackSyncDeps = {
  /** 아직 넣지 않았고 지우지 않은 대기 메시지 */
  pending: (connection: Connection) => Promise<StoredSlackMessage[]>;
  cachedNames: (connection: Connection, slackIds: string[]) => Promise<CachedSlackName[]>;
  /** 이름 캐시 저장. 이름을 못 찾은 id는 빈 이름으로 남겨 캐시 기간 동안 다시 묻지 않는다 */
  saveNames: (connection: Connection, names: Omit<CachedSlackName, "fetchedAt">[]) => Promise<void>;
  identity: (connection: Connection) => Promise<UserIdentity>;
  /** 이 연결에서 이미 넣은 외부 id */
  ingestedIds: IngestDeps["ingestedIds"];
  /**
   * 원문 저장 + 이번에 읽은 대기 행 표시 (한 트랜잭션, slack_ingest_source). 넣지 않았으면 null:
   * 이미 넣은 묶음(동시 동기화) · 읽은 뒤 Slack에서 지운 메시지가 있음. 끊긴 연결이면 던진다
   */
  insertSource: (connection: Connection, item: IngestItem, messages: { channelId: string; ts: string }[]) => Promise<string | null>;
  process: IngestDeps["process"];
  /** 처리를 마친 원문의 대기 행 본문을 비운다 (행은 재전송 막기용으로 3일 남는다) */
  clearText: (connection: Connection, sourceId: string) => Promise<void>;
  /** 처리 도중 연결을 끊었거나 앱이 지워졌으면(원문이 D3로 지워짐) 처리가 그 뒤에 쓴 인용 · 판정 기록도 지운다 (slack_repurge_if_disconnected) */
  repurgeIfDisconnected: (connection: Connection, sourceId: string) => Promise<void>;
};

export const DEFAULT_SLACK_SYNC = { maxItems: 20, nameCacheDays: 7 };

/**
 * Slack이 그 id가 없다고 답하면(지운 사용자 · 볼 수 없는 채널) 이름 없이 넣고 빈 이름으로 캐시한다.
 * 그 밖의 오류(토큰 · 속도 제한 · Slack 장애)는 동기화를 멈춘다: 일시 오류를 "이름 없음"으로 7일 동안 캐시하지 않게
 */
const NOT_FOUND = new Set(["user_not_found", "users_not_found", "user_not_visible", "channel_not_found"]);
const skippable = (error: unknown) => error instanceof SlackError && NOT_FOUND.has(error.code);

async function resolveNames(
  connection: Connection,
  messages: StoredSlackMessage[],
  meSlackId: string,
  api: SlackNameApi,
  deps: SlackSyncDeps,
  options: { now: Date; nameCacheDays: number },
): Promise<{ people: Map<string, string>; conversations: Map<string, string> }> {
  const { users, conversations: channels } = slackIdsToName(messages, meSlackId);
  const freshAfter = options.now.getTime() - options.nameCacheDays * 86_400_000;
  const cached = (await deps.cachedNames(connection, [...users, ...channels])).filter((c) => c.fetchedAt.getTime() > freshAfter);
  const known = new Set(cached.map((c) => c.slackId));
  const people = new Map(cached.filter((c) => c.kind === "user" && c.name).map((c) => [c.slackId, c.name]));
  const conversations = new Map(cached.filter((c) => c.kind === "conversation" && c.name).map((c) => [c.slackId, c.name]));
  const fetched: Omit<CachedSlackName, "fetchedAt">[] = [];

  const userName = async (userId: string): Promise<string | null> => {
    if (known.has(userId)) return people.get(userId) ?? null;
    let name: string | null = null;
    try {
      name = await api.userName(userId);
    } catch (error) {
      if (!skippable(error)) throw error;
    }
    known.add(userId);
    fetched.push({ slackId: userId, kind: "user", name: name ?? "" });
    if (name) people.set(userId, name);
    return name;
  };

  try {
    for (const channelId of channels.filter((id) => !known.has(id))) {
      let name: string | null = null;
      try {
        const info = await api.conversation(channelId);
        // DM은 상대 이름을 대화 이름으로 둔다 (머리줄 [DM · 상대])
        name = info.counterpartId ? await userName(info.counterpartId) : info.name;
      } catch (error) {
        if (!skippable(error)) throw error;
      }
      known.add(channelId);
      fetched.push({ slackId: channelId, kind: "conversation", name: name ?? "" });
      if (name) conversations.set(channelId, name);
    }
    for (const userId of users) await userName(userId);
  } finally {
    // 도중에 멈춰도(속도 제한 등) 찾은 이름은 남겨 다음 동기화가 이어서 찾는다
    if (fetched.length > 0) await deps.saveNames(connection, fetched);
  }
  return { people, conversations };
}

export async function syncSlack(
  connection: Connection,
  api: SlackNameApi,
  deps: SlackSyncDeps,
  options: { now: Date; deadline?: number; maxItems?: number; nameCacheDays?: number },
): Promise<ConnectorSyncResult> {
  const settings = slackSettingsSchema.parse(connection.settings);
  const messages = await deps.pending(connection);
  if (messages.length === 0) return { created: [], scanned: 0, skipped: {} };

  const identity = await deps.identity(connection);
  const me = { slackId: settings.slackUserId, name: identity.name };
  const { people, conversations } = await resolveNames(connection, messages, me.slackId, api, deps, {
    now: options.now,
    nameCacheDays: options.nameCacheDays ?? DEFAULT_SLACK_SYNC.nameCacheDays,
  });
  const startedThreads = await deps.ingestedIds(connection, threadStartIds(messages));
  const buckets = bucketSlackMessages(messages, { now: options.now, me, people, conversations, teamUrl: settings.teamUrl ?? null, startedThreads });
  const rowsOf = new Map(buckets.map((b) => [b.item.externalId, b.messages]));

  const result = await ingestItems(
    connection,
    buckets.map((b) => b.item),
    {
      ingestedIds: deps.ingestedIds,
      insertSource: (c, item) => deps.insertSource(c, item, rowsOf.get(item.externalId) ?? []),
      // 처리가 끝나면(성공이든 보통 실패든 원문 행에 글이 있다) 대기 행 본문을 비운다.
      // 동의 철회(ConsentRequiredError)면 비우지 않는다: 원문이 지워지며 표시가 풀려(on delete set null) 다시 동의하면 다시 묶인다.
      // 처리 도중 연결을 끊었거나 앱이 지워졌으면, 처리가 그 뒤에 쓴 글자도 지운다 (D3가 먼저 끝나도 Slack 글이 남지 않게)
      process: async (c, sourceId, item) => {
        try {
          await deps.process(c, sourceId, item);
          await deps.clearText(c, sourceId);
        } finally {
          // 실패해도 처리 결과(동의 철회 등)를 가리지 않는다. 남은 글자는 매일 정리가 다시 지운다 (purge_slack_buffers)
          await deps.repurgeIfDisconnected(c, sourceId).catch((error) =>
            console.error("Slack 원문 다시 지우기 확인 실패:", error instanceof Error ? error.message : error),
          );
        }
      },
    },
    {
      now: options.now,
      settleMinutes: SLACK_BUCKET_LIMITS.quietMinutes,
      maxItems: options.maxItems ?? DEFAULT_SLACK_SYNC.maxItems,
      // 길이로 거르지 않는다: ":+1:" · "넵!" 한 줄도 수락일 수 있다 (D5). 글이 하나도 없는 묶음만 건너뛴다
      minTextLength: 1,
      deadline: options.deadline,
    },
  );
  return { created: result.created, scanned: buckets.length, skipped: result.skipped };
}
