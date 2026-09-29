import {
  classifySlackMessage,
  slackMessageEventSchema,
  slackTokensRevokedSchema,
  type PendingSlackMessage,
  type SlackEventCallback,
  type SlackMessageEvent,
} from "./events";

// Slack 이벤트 하나를 받아 처리한다 (/api/connectors/slack/events, docs/go-live/slack-integration.md 2-4).
// 받는 쪽은 빨라야 한다(Slack은 3초 안에 답을 기다린다): 남길 메시지를 대기 표에 넣기까지만 하고, 원문으로 묶어 넣는 일은 동기화가 한다.
// DB는 deps로 받는다 (store.ts의 slackReceiveDeps). 원문 · 이름은 로그에 남기지 않는다.

export type SlackConnectionRef = {
  id: string;
  userId: string;
  /** 연결한 이용자의 Slack 사용자 id (external_account_id = 팀 id:사용자 id) */
  slackUserId: string;
  /** 연결 · 다시 연결한 시각. 이보다 앞선 앱 해제 이벤트는 이 연결을 끊지 않는다 */
  connectedAt: Date;
};

export type SlackReceiveDeps = {
  /** 이 워크스페이스의 끊기지 않은(active · error) Slack 연결 */
  connectionsForTeam: (teamId: string) => Promise<SlackConnectionRef[]>;
  consented: (userId: string) => Promise<boolean>;
  /** 이 이벤트를 볼 수 있는 이용자 id 모두 (D4). 알 수 없으면(앱 수준 토큰 없음 · 실패 · 시간 초과) null */
  authorizedUsers: (eventContext: string) => Promise<string[] | null>;
  isThreadTracked: (connectionId: string, channelId: string, threadTs: string) => Promise<boolean>;
  /** 이미 있으면(지움 표시 포함) 아무것도 하지 않는다 (Slack 재전송 · 늦게 온 이벤트가 넣은 메시지를 다시 넣거나 고친 글을 덮지 않게) */
  storeMessage: (connection: SlackConnectionRef, message: PendingSlackMessage) => Promise<void>;
  trackThread: (connection: SlackConnectionRef, channelId: string, threadTs: string) => Promise<void>;
  /** 아직 원문으로 넣지 않았고 지우지 않은 행만 고친다 */
  editMessage: (connectionId: string, channelId: string, ts: string, text: string, editedAt: Date) => Promise<void>;
  /** 지움 표시: 글을 비우고 deleted_at을 적는다. createIfMissing이면 행이 없어도 표시 행을 만든다 (늦게 온 원래 메시지를 막는다) */
  markDeleted: (
    connection: SlackConnectionRef,
    target: { channelId: string; channelType: PendingSlackMessage["channelType"]; ts: string; createIfMissing: boolean },
  ) => Promise<void>;
  /**
   * 앱 해제: 한 트랜잭션에서 토큰 · 대기 메시지 · 추적 스레드 · 이름 캐시를 지우고 revoked로 (DB 함수 revoke_slack_connections).
   * slackUserIds가 null이면 워크스페이스 전체. before 뒤에 다시 연결한 것은 그대로. 끊은 연결 수
   */
  revokeConnections: (teamId: string, slackUserIds: string[] | null, before: Date) => Promise<number>;
};

export type SlackReceiveResult = {
  /** 이 워크스페이스에 Taskforce 연결이 없음 */
  noConnection: boolean;
  kept: number;
  dropped: number;
  edited: number;
  deleted: number;
  skippedNoConsent: number;
  revoked: number;
};

const emptyResult = (): SlackReceiveResult => ({ noConnection: false, kept: 0, dropped: 0, edited: 0, deleted: 0, skippedNoConsent: 0, revoked: 0 });

/** 이 메시지가 (이벤트가 이름을 대지 않은) 이 이용자와 관계있을 수 있는가: 그럴 때만 D4 조회를 한다 (3초 안에 답해야 한다) */
function mayInvolve(event: SlackMessageEvent, slackUserId: string): boolean {
  if (event.subtype === "message_changed" || event.subtype === "message_deleted") return true;
  if (event.channel_type === "im" || event.channel_type === "mpim") return true;
  return event.user === slackUserId || (event.text ?? "").includes(`<@${slackUserId}>`) || Boolean(event.thread_ts);
}

export async function receiveSlackEvent(envelope: SlackEventCallback, deps: SlackReceiveDeps): Promise<SlackReceiveResult> {
  const result = emptyResult();

  // 앱 해제: 이벤트 시각보다 뒤에 다시 연결한 연결은 건드리지 않는다 (두 이벤트는 순서 없이 늦게 올 수 있다)
  const eventAt = new Date(envelope.event_time * 1000);
  if (envelope.event.type === "app_uninstalled") {
    result.revoked = await deps.revokeConnections(envelope.team_id, null, eventAt);
    return result;
  }
  if (envelope.event.type === "tokens_revoked") {
    const parsed = slackTokensRevokedSchema.safeParse(envelope.event);
    const users = parsed.success ? (parsed.data.tokens.oauth ?? []) : [];
    if (users.length > 0) result.revoked = await deps.revokeConnections(envelope.team_id, users, eventAt);
    return result;
  }
  if (envelope.event.type !== "message") return result;

  const parsed = slackMessageEventSchema.safeParse(envelope.event);
  if (!parsed.success) return { ...result, dropped: 1 };
  const event = parsed.data;

  const connections = await deps.connectionsForTeam(envelope.team_id);
  if (connections.length === 0) return { ...result, noConnection: true };

  // 받을 연결: 이벤트가 이름을 댄 설치 + (이 메시지와 관계있을 수 있는 다른 연결이 있으면) 이 이벤트를 볼 수 있는 나머지 이용자 (D4)
  const authorized = new Set((envelope.authorizations ?? []).filter((a) => a.user_id && !a.is_bot).map((a) => a.user_id!));
  const outside = connections.filter((c) => !authorized.has(c.slackUserId));
  if (envelope.event_context && outside.some((c) => mayInvolve(event, c.slackUserId))) {
    for (const user of (await deps.authorizedUsers(envelope.event_context)) ?? []) authorized.add(user);
  }

  const threadTs = event.thread_ts ?? event.message?.thread_ts ?? null;
  const channelMessage = event.channel_type === "channel" || event.channel_type === "group";
  await Promise.all(
    connections
      .filter((c) => authorized.has(c.slackUserId))
      .map(async (connection) => {
        if (!(await deps.consented(connection.userId))) {
          result.skippedNoConsent++;
          return;
        }
        const tracked = channelMessage && threadTs ? await deps.isThreadTracked(connection.id, event.channel, threadTs) : false;
        const decision = classifySlackMessage(event, connection.slackUserId, tracked);
        switch (decision.action) {
          case "keep":
            await deps.storeMessage(connection, decision.message);
            if (decision.track) await deps.trackThread(connection, decision.message.channelId, decision.track);
            result.kept++;
            break;
          case "edit":
            await deps.editMessage(connection.id, decision.channelId, decision.ts, decision.text, decision.editedAt);
            result.edited++;
            break;
          case "delete":
            await deps.markDeleted(connection, decision);
            result.deleted++;
            break;
          case "drop":
            result.dropped++;
            break;
        }
      }),
  );
  return result;
}
