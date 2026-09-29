import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { hasConsentFor } from "@/lib/consent/store";

import { eventAuthorizedUsers } from "./client";
import type { SlackConnectionRef, SlackReceiveDeps } from "./receive";

// Slack 이벤트 받기가 쓰는 DB 함수 (service role). 표 설명은 supabase/migrations/20261011000000_slack.sql.

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

    // Slack에서 앱을 지웠거나 토큰을 거뒀다: 한 트랜잭션에서 쓸 수 없는 토큰과 Slack에서 받아 둔 대기 데이터를 지우고 연결을 끊는다
    // (DB 함수 revoke_slack_connections, 20261012000000). 이미 원문으로 넣은 Slack 글 · 인용을 지우는 일(D3)은 연결 끊기 흐름과 함께 PR 3에서.
    revokeConnections: async (teamId, slackUserIds, before) => {
      const { data } = await admin
        .rpc("revoke_slack_connections", { p_team_id: teamId, p_slack_user_ids: slackUserIds, p_before: before.toISOString() })
        .throwOnError();
      return (data as number | null) ?? 0;
    },
  };
}
