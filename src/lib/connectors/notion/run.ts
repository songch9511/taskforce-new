import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { activeConnections, claimConnection, ingestDeps, loadToken, recordSync, saveToken } from "../store";
import type { Connection } from "../types";

import { notionClient, NotionError, refreshToken, type NotionOAuthConfig, type NotionToken } from "./api";
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

  let token = await loadToken<NotionToken>(admin, connection.id);
  const run = () =>
    syncNotion(connection, notionClient(token.access_token), ingestDeps(admin), { now, deadline: options.deadline, ...DEFAULT_NOTION_SYNC });

  try {
    let result: NotionSyncResult;
    try {
      result = await run();
    } catch (error) {
      // 토큰이 만료됐으면 한 번 갱신해서 다시 시도한다.
      if (!(error instanceof NotionError && error.status === 401 && token.refresh_token)) throw error;
      token = { ...token, ...(await refreshToken(notionOAuthConfig(), token.refresh_token)) };
      await saveToken(admin, connection.id, token);
      result = await run();
    }
    await recordSync(admin, connection, { cursor: result.cursor });
    return { connectionId: connection.id, ok: true, result };
  } catch (error) {
    const { message, revoked } = userFacingError(error);
    console.error(`Notion 동기화 실패 (${connection.id}):`, error instanceof Error ? error.message : error);
    await recordSync(admin, connection, { error: message, revoked });
    return { connectionId: connection.id, ok: false, error: message, revoked };
  }
}

/** 활성 Notion 연결을 오래 안 한 순서로 돌린다. 실행 시간 한도(deadline)를 넘기면 남은 연결은 다음 차례로 미룬다. */
export async function syncAllNotion(
  admin: SupabaseClient,
  options: { userId?: string; deadline?: number; minIntervalMs?: number } = {},
) {
  const outcomes: ConnectionSyncOutcome[] = [];
  for (const connection of await activeConnections(admin, "notion", options.userId)) {
    // 수동 동기화를 연달아 누르지 못하게 한다.
    const since = connection.lastSyncedAt ? Date.now() - connection.lastSyncedAt.getTime() : Infinity;
    if (options.minIntervalMs && since < options.minIntervalMs) {
      outcomes.push({ connectionId: connection.id, ok: false, error: "방금 동기화했습니다. 잠시 뒤 다시 시도해 주세요.", revoked: false, busy: true });
      continue;
    }
    if (options.deadline && Date.now() > options.deadline) break;
    outcomes.push(await syncNotionConnection(admin, connection, { deadline: options.deadline }));
  }
  return outcomes;
}
