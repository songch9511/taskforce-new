import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";

import { claimConnection, ingestDeps, loadToken, markBackfilled, recordNotionHealth, recordSync, saveConnection, saveToken, taskDeps } from "../store";
import type { Connection, Connector } from "../types";

import {
  authorizeUrl,
  exchangeCode,
  notionClient,
  NotionError,
  notionTokenSchema,
  refreshToken,
  revokeToken,
  type NotionClient,
  type NotionOAuthConfig,
  type NotionToken,
} from "./api";
import { notionCoverage } from "./data-sources";
import { DEFAULT_NOTION_SYNC, syncNotion, type NotionSyncResult } from "./sync";

// Notion 연결을 실제로 동기화한다: 토큰을 풀고, 만료됐으면 갱신하고, 결과와 커서를 남긴다.

export function notionOAuthConfig(): NotionOAuthConfig {
  const clientId = process.env.NOTION_CLIENT_ID;
  const clientSecret = process.env.NOTION_CLIENT_SECRET;
  const redirectUri = process.env.NOTION_REDIRECT_URI;
  if (!clientId || !clientSecret || !redirectUri) {
    throw new Error("NOTION_CLIENT_ID · NOTION_CLIENT_SECRET · NOTION_REDIRECT_URI가 필요합니다. .env.example을 보세요.");
  }
  return { clientId, clientSecret, redirectUri };
}

/** 연결의 토큰으로 Notion을 부른다. 토큰이 만료됐으면(401) 한 번 갱신해서 다시 부른다. */
export async function withNotionClient<T>(admin: SupabaseClient, connectionId: string, call: (client: NotionClient) => Promise<T>): Promise<T> {
  let token = await loadToken<NotionToken>(admin, connectionId);
  try {
    return await call(notionClient(token.access_token));
  } catch (error) {
    if (!(error instanceof NotionError && error.status === 401 && token.refresh_token)) throw error;
    token = { ...token, ...(await refreshToken(notionOAuthConfig(), token.refresh_token)) };
    await saveToken(admin, connectionId, token);
    return call(notionClient(token.access_token));
  }
}

export type ConnectionSyncOutcome =
  | { connectionId: string; ok: true; result: NotionSyncResult }
  | { connectionId: string; ok: false; error: string; revoked: boolean; busy?: boolean };

/** 사용자에게 보여줄 오류. 자세한 내용은 서버 로그에만 남긴다. */
function userFacingError(error: unknown): { message: string; revoked: boolean } {
  if (error instanceof NotionError && error.status === 401) {
    return { message: "Notion 연결 권한이 끊겼습니다. 다시 연결해 주세요.", revoked: true };
  }
  if (error instanceof NotionError) return { message: `Notion 요청 실패 (${error.status})`, revoked: false };
  return { message: "동기화 중 오류가 발생했습니다.", revoked: false };
}

export async function syncNotionConnection(
  admin: SupabaseClient,
  connection: Connection,
  options: { now?: Date; deadline?: number } = {},
): Promise<ConnectionSyncOutcome> {
  const now = options.now ?? new Date();
  // 같은 연결을 cron과 수동 동기화가 동시에 돌리지 않는다 (중복 조회 · 토큰 갱신 경쟁 방지).
  if (!(await claimConnection(admin, connection, now))) {
    return { connectionId: connection.id, ok: false, error: "이미 동기화 중입니다.", revoked: false, busy: true };
  }

  const run = (client: NotionClient) =>
    syncNotion(connection, client, { ...ingestDeps(admin), tasks: taskDeps(admin) }, {
      now,
      deadline: options.deadline,
      ...DEFAULT_NOTION_SYNC,
    });

  try {
    const result = await withNotionClient(admin, connection.id, run);
    // 상태 기록이 실패해도 이미 넣은 원문 · 커서는 남긴다. 자동 확인한 할 일 DB도 여기서 남기므로 처음 훑기 표시보다 먼저 한다
    // (실패하면 처음 훑기도 표시되지 않아 다음 동기화가 다시 확인하고 다시 훑는다).
    await recordNotionHealth(admin, connection, result).catch((error) =>
      console.error(`Notion 연결 상태 기록 실패 (${connection.id}):`, error instanceof Error ? error.message : error),
    );
    await markBackfilled(admin, connection, result.backfilled);
    await recordSync(admin, connection, { cursor: result.cursor });
    return { connectionId: connection.id, ok: true, result };
  } catch (error) {
    // 동기화 도중 외부 AI 처리 동의를 철회함: 남은 항목은 처리하지 않았다. 연결 오류가 아니므로 오류로 남기지 않고,
    // 커서도 옮기지 않아 다시 동의하면 이어서 가져온다.
    if (error instanceof ConsentRequiredError) {
      await recordSync(admin, connection, {});
      return { connectionId: connection.id, ok: false, error: CONSENT_WITHDRAWN_MESSAGE, revoked: false };
    }
    const { message, revoked } = userFacingError(error);
    console.error(`Notion 동기화 실패 (${connection.id}):`, error instanceof Error ? error.message : error);
    await recordSync(admin, connection, { error: message, revoked });
    return { connectionId: connection.id, ok: false, error: message, revoked };
  }
}

/** 연결 틀(registry.ts)에 내놓는 Notion 연동 */
export const notionConnector: Connector = {
  provider: "notion",
  authorizeUrl: (state) => authorizeUrl(notionOAuthConfig(), state),
  connect: async (admin, userId, code) => {
    const token = await exchangeCode(notionOAuthConfig(), code);
    const connectionId = await saveConnection(admin, {
      userId,
      provider: "notion",
      externalAccountId: token.workspace_id,
      displayName: token.workspace_name ?? null,
      token,
    });
    // 선택 화면에서 아무것도 고르지 않았거나 회의록 DB가 빠졌으면 바로 알린다 (점검이 실패해도 연결은 된 것으로 둔다).
    const coverage = await notionCoverage(admin, userId, connectionId).catch(() => "ok" as const);
    return coverage === "empty" ? "connected_empty" : coverage === "no_meetings" ? "connected_no_meetings" : "connected";
  },
  sync: (admin, connection, options) => syncNotionConnection(admin, connection, options),
  revokeToken: async (token) => {
    const parsed = notionTokenSchema.safeParse(token);
    if (parsed.success) await revokeToken(notionOAuthConfig(), parsed.data.access_token);
  },
};
