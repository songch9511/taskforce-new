import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { hasConsentFor } from "@/lib/consent/store";

import { ingestDeps, loadIdentity } from "../store";
import type { Connection } from "../types";

import type { StoredSlackMessage } from "./bucket";
import { eventAuthorizedUsers } from "./client";
import type { SlackConnectionRef, SlackReceiveDeps } from "./receive";
import type { CachedSlackName, SlackSyncDeps } from "./sync";

// Slack 이벤트 받기 · 동기화가 쓰는 DB 함수 (service role). 표 · 함수 설명은 supabase/migrations/20261011000000_slack.sql · 20261013000000_slack_sync.sql.

type ConnectionRow = { id: string; user_id: string; external_account_id: string; connected_at: string };

/** external_account_id("T…:U…")에서 Slack 사용자 id */
const slackUserIdOf = (externalAccountId: string) => externalAccountId.slice(externalAccountId.indexOf(":") + 1);

/**
 * receiveSlackEvent에 넘길 DB 함수. 한 요청 안에서 동의 확인은 이용자마다 한 번만 읽는다.
 * @param appToken 앱 수준 토큰(SLACK_APP_TOKEN). 없으면 같은 워크스페이스의 다른 이용자를 찾지 않는다 (D4)
 */
export function slackReceiveDeps(admin: SupabaseClient, appToken: string | null): SlackReceiveDeps {
  const consent = new Map<string, Promise<boolean>>();
  return {
    // teamId는 events.ts의 스키마가 영문 대문자 · 숫자로 확인했다 (LIKE 와일드카드가 들어오지 않는다)
    connectionsForTeam: async (teamId) => {
      const { data } = await admin
        .from("connections")
        .select("id, user_id, external_account_id, connected_at")
        .eq("provider", "slack")
        .in("status", ["active", "error"])
        .like("external_account_id", `${teamId}:%`)
        .throwOnError();
      return ((data ?? []) as ConnectionRow[]).map(
        (row): SlackConnectionRef => ({
          id: row.id,
          userId: row.user_id,
          slackUserId: slackUserIdOf(row.external_account_id),
          connectedAt: new Date(row.connected_at),
        }),
      );
    },

    consented: (userId) => {
      if (!consent.has(userId)) consent.set(userId, hasConsentFor(admin, userId));
      return consent.get(userId)!;
    },

    authorizedUsers: async (eventContext) => {
      if (!appToken) return null;
      // 3초 안에 답해야 해서 짧게 끊는다. 실패하면 이벤트가 이름을 댄 이용자만 받는다
      return eventAuthorizedUsers(appToken, eventContext, fetch, { timeoutMs: 700, maxPages: 2 }).catch((error) => {
        console.error("Slack 이벤트 설치 조회 실패:", error instanceof Error ? error.message : error);
        return null;
      });
    },

    isThreadTracked: async (connectionId, channelId, threadTs) => {
      const { data } = await admin
        .from("slack_threads")
        .select("thread_ts")
        .eq("connection_id", connectionId)
        .eq("channel_id", channelId)
        .eq("thread_ts", threadTs)
        .maybeSingle()
        .throwOnError();
      return Boolean(data);
    },

    storeMessage: async (connection, message) => {
      await admin
        .from("slack_messages")
        .upsert(
          {
            user_id: connection.userId,
            connection_id: connection.id,
            channel_id: message.channelId,
            channel_type: message.channelType,
            ts: message.ts,
            thread_ts: message.threadTs,
            sender_id: message.senderId,
            text: message.text,
          },
          { onConflict: "connection_id,channel_id,ts", ignoreDuplicates: true },
        )
        .throwOnError();
    },

    trackThread: async (connection, channelId, threadTs) => {
      await admin
        .from("slack_threads")
        .upsert(
          { connection_id: connection.id, user_id: connection.userId, channel_id: channelId, thread_ts: threadTs, last_activity_at: new Date().toISOString() },
          { onConflict: "connection_id,channel_id,thread_ts" },
        )
        .throwOnError();
    },

    editMessage: async (connectionId, channelId, ts, text, editedAt) => {
      await admin
        .from("slack_messages")
        .update({ text, edited_at: editedAt.toISOString() })
        .eq("connection_id", connectionId)
        .eq("channel_id", channelId)
        .eq("ts", ts)
        .is("source_id", null)
        .is("deleted_at", null)
        .throwOnError();
    },

    // 행을 지우지 않는다: 늦게 온 원래 메시지 · 재전송이 (connection_id, channel_id, ts) unique에 막혀 다시 들어오지 않게 글만 비운 표시를 남긴다.
    // DM · 그룹 DM은 행이 아직 없어도(지움이 먼저 도착) 표시 행을 만든다. 채널은 이미 남긴 행에만 표시한다.
    // 이미 원문으로 넣은 행도 표시만 남는다(원문은 그대로, slack-app.md 7장 검토 3).
    markDeleted: async (connection, target) => {
      const deletedAt = new Date().toISOString();
      if (target.createIfMissing) {
        await admin
          .from("slack_messages")
          .upsert(
            {
              user_id: connection.userId,
              connection_id: connection.id,
              channel_id: target.channelId,
              channel_type: target.channelType,
              ts: target.ts,
              sender_id: "",
              text: "",
              deleted_at: deletedAt,
            },
            { onConflict: "connection_id,channel_id,ts" },
          )
          .throwOnError();
        return;
      }
      await admin
        .from("slack_messages")
        .update({ text: "", deleted_at: deletedAt })
        .eq("connection_id", connection.id)
        .eq("channel_id", target.channelId)
        .eq("ts", target.ts)
        .throwOnError();
    },

    revokeConnections: (teamId, slackUserIds, before) => revokeSlackConnections(admin, teamId, slackUserIds, before),
  };
}

/**
 * Slack에서 앱을 지웠거나 토큰을 거뒀다: 한 트랜잭션에서 쓸 수 없는 토큰을 지우고, Slack에서 온 글자를 지우고(D3: 대기 데이터 · 원문 본문 · 인용),
 * 연결을 끊는다 (DB 함수 revoke_slack_connections, 20261012000000 · 20261013000000). 끊은 연결 수.
 * @param slackUserIds null이면 그 워크스페이스 전체(app_uninstalled)
 * @param before 이 시각 뒤에 다시 연결한 것은 건드리지 않는다
 */
export async function revokeSlackConnections(admin: SupabaseClient, teamId: string, slackUserIds: string[] | null, before: Date): Promise<number> {
  const { data } = await admin
    .rpc("revoke_slack_connections", { p_team_id: teamId, p_slack_user_ids: slackUserIds, p_before: before.toISOString() })
    .throwOnError();
  return (data as number | null) ?? 0;
}

/** 연결할 때: 이용자의 Slack id · 팀 id · 워크스페이스 주소를 연결 설정에 둔다 (다른 설정은 그대로) */
export async function saveSlackSettings(
  admin: SupabaseClient,
  userId: string,
  connectionId: string,
  values: { slackUserId: string; teamId: string; teamUrl: string | null },
): Promise<void> {
  const { data } = await admin.from("connections").select("settings").eq("id", connectionId).eq("user_id", userId).single().throwOnError();
  const settings = (data.settings as Record<string, unknown> | null) ?? {};
  await admin
    .from("connections")
    .update({ settings: { ...settings, ...values } })
    .eq("id", connectionId)
    .eq("user_id", userId)
    .throwOnError();
}

type PendingRow = {
  channel_id: string;
  channel_type: StoredSlackMessage["channelType"];
  ts: string;
  thread_ts: string | null;
  sender_id: string;
  text: string;
  edited_at: string | null;
};

/** 한 번 동기화에서 읽는 대기 메시지 상한 (남은 것은 다음 동기화) */
const PENDING_LIMIT = 2000;
/** 이름 캐시를 한 번에 읽는 id 수 (주소 길이) */
const NAME_CHUNK = 200;

/** syncSlack에 넘길 DB 함수 */
export function slackSyncDeps(admin: SupabaseClient): SlackSyncDeps {
  const base = ingestDeps(admin);
  const scoped = (connection: Connection) => ({ connection_id: connection.id, user_id: connection.userId });
  return {
    pending: async (connection) => {
      const { data } = await admin
        .from("slack_messages")
        .select("channel_id, channel_type, ts, thread_ts, sender_id, text, edited_at")
        .eq("connection_id", connection.id)
        .eq("user_id", connection.userId)
        .is("source_id", null)
        .is("deleted_at", null)
        .order("received_at")
        .limit(PENDING_LIMIT)
        .throwOnError();
      return ((data ?? []) as PendingRow[]).map((row) => ({
        channelId: row.channel_id,
        channelType: row.channel_type,
        ts: row.ts,
        threadTs: row.thread_ts,
        senderId: row.sender_id,
        text: row.text,
        editedAt: row.edited_at ? new Date(row.edited_at) : null,
      }));
    },

    cachedNames: async (connection, slackIds) => {
      const names: CachedSlackName[] = [];
      for (let i = 0; i < slackIds.length; i += NAME_CHUNK) {
        const { data } = await admin
          .from("slack_people")
          .select("slack_id, kind, name, fetched_at")
          .eq("connection_id", connection.id)
          .eq("user_id", connection.userId)
          .in("slack_id", slackIds.slice(i, i + NAME_CHUNK))
          .throwOnError();
        for (const row of (data ?? []) as { slack_id: string; kind: CachedSlackName["kind"]; name: string; fetched_at: string }[]) {
          names.push({ slackId: row.slack_id, kind: row.kind, name: row.name, fetchedAt: new Date(row.fetched_at) });
        }
      }
      return names;
    },

    saveNames: async (connection, names) => {
      const fetchedAt = new Date().toISOString();
      await admin
        .from("slack_people")
        .upsert(
          names.map((n) => ({ ...scoped(connection), slack_id: n.slackId, kind: n.kind, name: n.name.slice(0, 200), fetched_at: fetchedAt })),
          { onConflict: "connection_id,slack_id" },
        )
        .throwOnError();
    },

    identity: (connection) => loadIdentity(admin, connection.userId),

    ingestedIds: base.ingestedIds,

    insertSource: async (connection, item, messages) => {
      const { data } = await admin
        .rpc("slack_ingest_source", {
          p_user_id: connection.userId,
          p_connection_id: connection.id,
          p_source: {
            external_id: item.externalId,
            external_version: item.externalVersion,
            kind: item.kind,
            title: item.title,
            raw_text: item.text,
            occurred_at: item.occurredAt.toISOString(),
            external_url: item.externalUrl,
            participants: item.participants ?? null,
          },
          p_channel_ids: messages.map((m) => m.channelId),
          p_ts: messages.map((m) => m.ts),
        })
        .single<{ source_id: string | null; created: boolean }>()
        .throwOnError();
      return data.created ? data.source_id : null;
    },

    process: base.process,

    clearText: async (connection, sourceId) => {
      await admin.from("slack_messages").update({ text: "" }).eq("user_id", connection.userId).eq("source_id", sourceId).throwOnError();
    },

    repurgeIfDisconnected: async (connection, sourceId) => {
      await admin.rpc("slack_repurge_if_disconnected", { p_user_id: connection.userId, p_source_id: sourceId }).throwOnError();
    },
  };
}
