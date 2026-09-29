import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";

import { claimConnection, loadToken, recordSync, saveConnection } from "../store";
import type { Connection, Connector, ConnectorSyncOutcome } from "../types";

import {
  exchangeSlackCode,
  isSlackAuthError,
  revokeSlackToken,
  slackAuthorizeUrl,
  slackAuthTest,
  slackConversation,
  SlackError,
  slackTokenSchema,
  slackUserName,
  type SlackOAuthConfig,
} from "./client";
import { revokeSlackConnections, saveSlackSettings, slackSyncDeps } from "./store";
import { DEFAULT_SLACK_SYNC, slackSettingsSchema, syncSlack, type SlackNameApi } from "./sync";

// Slack 연동을 연결 틀(registry.ts)에 올린다: 권한 화면 · 연결 · 동기화 · 토큰 폐기 (docs/go-live/slack-integration.md 2-3 · 2-5 · 2-7).
// 메시지는 이벤트로 받아 두고(events/route.ts), 동기화는 받아 둔 것만 원문으로 넣는다. 과거 메시지는 가져오지 않는다.

export function slackOAuthConfig(): SlackOAuthConfig {
  const clientId = process.env.SLACK_CLIENT_ID;
  const clientSecret = process.env.SLACK_CLIENT_SECRET;
  const redirectUri = process.env.SLACK_REDIRECT_URI;
  if (!clientId || !clientSecret || !redirectUri) {
    throw new Error("SLACK_CLIENT_ID · SLACK_CLIENT_SECRET · SLACK_REDIRECT_URI가 필요합니다. .env.example을 보세요.");
  }
  return { clientId, clientSecret, redirectUri };
}

const REVOKED_MESSAGE = "Slack 연결 권한이 끊겼습니다. 다시 연결해 주세요.";

/** 사용자에게 보여줄 오류. 자세한 내용은 서버 로그에만 남긴다 */
const userFacingError = (error: unknown) => (error instanceof SlackError ? `Slack 요청 실패 (${error.code})` : "동기화 중 오류가 발생했습니다.");

export async function syncSlackConnection(
  admin: SupabaseClient,
  connection: Connection,
  options: { now?: Date; deadline?: number } = {},
): Promise<ConnectorSyncOutcome> {
  const now = options.now ?? new Date();
  // 같은 연결을 cron과 수동 동기화가 동시에 돌리지 않는다
  if (!(await claimConnection(admin, connection, now))) {
    return { connectionId: connection.id, ok: false, error: "이미 동기화 중입니다.", revoked: false, busy: true };
  }

  // 토큰은 이름을 Slack에 물어야 할 때만 푼다 (대기 메시지가 없으면 Slack을 부르지 않는다)
  let token: Promise<string> | null = null;
  const accessToken = () => (token ??= loadToken(admin, connection.id).then((t) => slackTokenSchema.parse(t).access_token));
  const api: SlackNameApi = {
    userName: async (userId) => slackUserName(await accessToken(), userId),
    conversation: async (channelId) => slackConversation(await accessToken(), channelId),
  };

  try {
    const result = await syncSlack(connection, api, slackSyncDeps(admin), { now, deadline: options.deadline, ...DEFAULT_SLACK_SYNC });
    await recordSync(admin, connection, {});
    return { connectionId: connection.id, ok: true, result };
  } catch (error) {
    // 동기화 도중 외부 AI 처리 동의를 철회함: 연결 오류가 아니다. 처리하지 못한 묶음의 대기 행은 남아 다시 동의하면 넣는다
    if (error instanceof ConsentRequiredError) {
      await recordSync(admin, connection, {});
      return { connectionId: connection.id, ok: false, error: CONSENT_WITHDRAWN_MESSAGE, revoked: false };
    }
    // Slack에서 앱을 지웠거나 권한을 거뒀는데 이벤트를 받지 못했다: 앱 해제와 같게 끊고 Slack에서 온 글자를 지운다 (D3)
    if (isSlackAuthError(error)) {
      const settings = slackSettingsSchema.safeParse(connection.settings);
      // 동기화 도중 다시 연결했으면(connected_at이 지금보다 뒤) 함수가 건드리지 않는다: 새 토큰이 있는 연결을 끊지 않는다
      const revoked = settings.success ? (await revokeSlackConnections(admin, settings.data.teamId, [settings.data.slackUserId], now)) > 0 : true;
      if (revoked) {
        await recordSync(admin, connection, { error: REVOKED_MESSAGE, revoked: true });
        return { connectionId: connection.id, ok: false, error: REVOKED_MESSAGE, revoked: true };
      }
      // 이미 끊겼거나(앱 해제 이벤트가 먼저 처리함) 그 사이 다시 연결했다. recordSync는 끊긴 연결을 되살리지 않는다
      await recordSync(admin, connection, {});
      return { connectionId: connection.id, ok: false, error: REVOKED_MESSAGE, revoked: false };
    }
    const message = userFacingError(error);
    console.error(`Slack 동기화 실패 (${connection.id}):`, error instanceof Error ? error.message : error);
    await recordSync(admin, connection, { error: message });
    return { connectionId: connection.id, ok: false, error: message, revoked: false };
  }
}

/** 연결 틀(registry.ts)에 내놓는 Slack 연동 */
export const slackConnector: Connector = {
  provider: "slack",
  authorizeUrl: (state) => slackAuthorizeUrl(slackOAuthConfig(), state),
  connect: async (admin, userId, code) => {
    const { token, teamName } = await exchangeSlackCode(slackOAuthConfig(), code);
    const { url } = await slackAuthTest(token.access_token);
    const connectionId = await saveConnection(admin, {
      userId,
      provider: "slack",
      externalAccountId: `${token.team_id}:${token.user_id}`,
      displayName: teamName,
      token,
    });
    await saveSlackSettings(admin, userId, connectionId, { slackUserId: token.user_id, teamId: token.team_id, teamUrl: url });
    // 연결한 뒤의 메시지부터 받는다: 첫 동기화에는 넣을 것이 없다 (앱 연결 안내 문구, slack-integration.md 3장)
    return "connected";
  },
  sync: (admin, connection, options) => syncSlackConnection(admin, connection, options),
  revokeToken: async (token) => {
    const parsed = slackTokenSchema.safeParse(token);
    if (parsed.success) await revokeSlackToken(parsed.data.access_token);
  },
};
