import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { ConnectProvider } from "@/lib/api/contract";
import { hasConsentFor } from "@/lib/consent/store";
import { gmailConnectEnabled, slackConnectEnabled } from "@/lib/env";
import { isAdmin } from "@/lib/metrics/load";

import { gmailConnector } from "./gmail/run";
import { notionConnector } from "./notion/run";
import { slackConnector } from "./slack/run";
import { activeConnections, recordConnectionCreated, userConnectionTokens } from "./store";
import { syncEach, type SyncAllResult } from "./sync-all";
import type { Connector } from "./types";

// 연결 틀: 연동마다 연결 시작 · callback · 동기화 · 토큰 폐기를 한곳에서 찾는다 (docs/GO_LIVE.md 1장).
// Google Calendar · Meet(google)도 Connector를 구현해 여기에 더하면 앱 연결 화면 · 주기 동기화 · 계정 삭제 · 연결 끊기에 그대로 붙는다.

const CONNECTORS: { [P in ConnectProvider]?: Connector } = { notion: notionConnector, slack: slackConnector, gmail: gmailConnector };

/**
 * 앱에 연결을 연 서비스인가. Slack · Gmail은 처리방침 · 앱 문구를 맞출 때까지 운영에서 닫아 둔다
 * (SLACK_CONNECT_ENABLED · GMAIL_CONNECT_ENABLED)
 */
const opened = (provider: ConnectProvider) =>
  provider === "slack" ? slackConnectEnabled() : provider === "gmail" ? gmailConnectEnabled() : true;

/** 아직 붙이지 않았거나 열지 않은 서비스면 null (앱에는 보이지만 연결은 안 된다) */
export function connectorFor(provider: ConnectProvider): Connector | null {
  return opened(provider) ? (CONNECTORS[provider] ?? null) : null;
}

/**
 * 웹(/lab, 내부 시험)에서 연결할 수 있는 연동. 앱에 연결을 열었거나(SLACK_CONNECT_ENABLED · GMAIL_CONNECT_ENABLED), 연 전이라도
 * 운영자(ADMIN_EMAILS)면 운영에서 끝까지 시험할 수 있게 연다. 그 밖의 사용자는 null (앱에 열기 전에 /lab으로 우회해 연결하지 못하게).
 */
export function webConnector(provider: ConnectProvider, email: string | null | undefined): Connector | null {
  return connectorFor(provider) ?? (isAdmin(email ?? null) ? (CONNECTORS[provider] ?? null) : null);
}

/** 서비스 쪽 토큰 폐기 (연결 끊기). 연결을 열지 않은 서비스라도 이미 있는 연결의 토큰은 폐기한다 */
export function tokenRevokerFor(provider: ConnectProvider): ((token: unknown) => Promise<void>) | null {
  return CONNECTORS[provider]?.revokeToken ?? null;
}

/**
 * 동기화할 연동: 붙인 연동 모두. 연결을 열지 않은 서비스(Slack · Gmail, 여는 플래그 전)라도 이미 있는 연결(운영자 시험)은 돌린다.
 * 닫는 것은 새 연결뿐이다 (connectorFor · webConnector)
 */
const implementedProviders = () => Object.keys(CONNECTORS) as ConnectProvider[];

/**
 * 붙인 모든 연동의 활성 연결을 오래 안 한 순서로 돌린다 (규칙은 sync-all.ts).
 * 외부 AI 처리에 동의하지 않은 사용자의 연결은 건너뛴다: cron · 수동 동기화 · 연결 직후 첫 동기화가 모두 여기를 거친다.
 * 고를 때 SQL에서 한 번(syncable_connections), 연결마다 시작 직전에 한 번, 원문마다 모델을 부르기 직전에 또 확인한다(lib/consent).
 */
export function syncConnections(
  admin: SupabaseClient,
  options: { userId?: string; deadline?: number; minIntervalMs?: number; providers?: ConnectProvider[] } = {},
): Promise<SyncAllResult> {
  const providers = (options.providers ?? implementedProviders()).filter((p) => CONNECTORS[p]);
  return syncEach(
    {
      connections: () => activeConnections(admin, providers, options.userId),
      consented: (userId) => hasConsentFor(admin, userId),
      sync: (connection) => CONNECTORS[connection.provider as ConnectProvider]!.sync(admin, connection, { deadline: options.deadline }),
    },
    options,
  );
}

/**
 * 연결된 뒤 (응답한 다음 after()로): 연결 지표를 남기고, 앱에서 연결했으면(POST /connections/{provider}/complete) 첫 동기화를 바로 돌린다.
 * 웹(/lab) 연결은 지표만 남긴다 ('지금 동기화'로 돌린다).
 */
export async function afterConnected(admin: SupabaseClient, userId: string, provider: ConnectProvider, options: { firstSync: boolean }): Promise<void> {
  await recordConnectionCreated(admin, userId, provider).catch((error) =>
    console.error("연결 지표 기록 실패:", error instanceof Error ? error.message : error),
  );
  if (!options.firstSync) return;
  await syncConnections(admin, { userId, providers: [provider], deadline: Date.now() + 240_000 }).catch((error) =>
    console.error(`${provider} 첫 동기화 실패:`, error instanceof Error ? error.message : error),
  );
}

/**
 * 계정 삭제 전: 서비스 쪽 토큰도 폐기한다 (폐기 API가 있는 연동만). 하나가 실패해도 나머지는 계속하고, 삭제를 막지 않는다.
 * 우리 쪽 토큰(connection_secrets)은 계정을 지울 때 함께 지워진다.
 */
export async function revokeConnectorTokens(admin: SupabaseClient, userId: string): Promise<{ revoked: number; failed: number }> {
  // 연결마다 동시에 폐기한다 (서비스 하나가 느려도 나머지를 기다리게 하지 않는다. 호출마다 10초 제한은 각 연동이 둔다).
  const results = await Promise.allSettled(
    (await userConnectionTokens(admin, userId)).map(async ({ connectionId, provider, token }) => {
      const connector = CONNECTORS[provider as ConnectProvider];
      if (!connector?.revokeToken || token === null) return false;
      try {
        await connector.revokeToken(token);
        return true;
      } catch (error) {
        console.error(`${provider} 토큰 폐기 실패 (${connectionId}):`, error instanceof Error ? error.message : error);
        throw error;
      }
    }),
  );
  return {
    revoked: results.filter((r) => r.status === "fulfilled" && r.value).length,
    failed: results.filter((r) => r.status === "rejected").length,
  };
}
