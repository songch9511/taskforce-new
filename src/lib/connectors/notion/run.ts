import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";
import { notifyReconnect } from "@/lib/notify/service";

import { googleCalendarLookup } from "../google/lookup";
import { addConnectionStats, claimConnection, ingestDeps, loadToken, markBackfilled, recordNotionHealth, recordSync, saveConnection, saveToken, taskDeps } from "../store";
import type { Connection, Connector } from "../types";

import {
  authorizeUrl,
  exchangeCode,
  notionClient,
  NotionError,
  NotionOAuthError,
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

/** 갱신 토큰이 만료 · 거절됨: 다시 연결해야 한다 (같은 갱신을 다시 시도하지 않는다) */
const isInvalidGrant = (error: unknown) => error instanceof NotionOAuthError && error.code === "invalid_grant";

/** 동시에 갱신했을 때 먼저 갱신한 쪽이 새 토큰을 저장할 때까지 기다리는 시간 */
const REFRESH_RACE_WAIT_MS = 1_000;

/** 다른 요청이 먼저 갱신해 저장한 토큰. 같은 순간에 겹쳤으면 저장이 끝나도록 한 번 기다렸다 다시 읽는다. 없으면 null (정말 만료됨) */
async function tokenRefreshedElsewhere(admin: SupabaseClient, connectionId: string, used: string): Promise<NotionToken | null> {
  for (const wait of [0, REFRESH_RACE_WAIT_MS]) {
    if (wait) await new Promise((resolve) => setTimeout(resolve, wait));
    const saved = await loadToken<NotionToken>(admin, connectionId);
    if (saved.refresh_token !== used) return saved;
  }
  return null;
}

/** 연결의 토큰으로 Notion을 부른다. 토큰이 만료됐으면(401) 한 번 갱신해서 다시 부른다. */
export async function withNotionClient<T>(admin: SupabaseClient, connectionId: string, call: (client: NotionClient) => Promise<T>): Promise<T> {
  let token = await loadToken<NotionToken>(admin, connectionId);
  try {
    return await call(notionClient(token.access_token));
  } catch (error) {
    if (!(error instanceof NotionError && error.status === 401 && token.refresh_token)) throw error;
    const used = token.refresh_token;
    try {
      token = { ...token, ...(await refreshToken(notionOAuthConfig(), used)) };
    } catch (refreshError) {
      // Notion은 갱신할 때마다 갱신 토큰을 바꾼다. 다른 요청(/lab 할 일 DB 설정 · 스크립트)이 먼저 갱신해 저장했으면
      // 이 갱신 토큰은 거절된다: 연결이 만료된 것이 아니므로 저장된 새 토큰으로 이어 간다.
      if (!isInvalidGrant(refreshError)) throw refreshError;
      const saved = await tokenRefreshedElsewhere(admin, connectionId, used);
      if (!saved) throw refreshError;
      return call(notionClient(saved.access_token));
    }
    await saveToken(admin, connectionId, token);
    return call(notionClient(token.access_token));
  }
}

export type ConnectionSyncOutcome =
  | { connectionId: string; ok: true; result: NotionSyncResult }
  | { connectionId: string; ok: false; error: string; revoked: boolean; busy?: boolean };

/** 사용자에게 보여줄 오류와 연결 상태. 자세한 내용은 서버 로그에만 남긴다. */
function userFacingError(error: unknown): { message: string; revoked: boolean; reauth: boolean } {
  if (isInvalidGrant(error)) return { message: "Notion 연결이 만료됐습니다. 다시 연결해 주세요.", revoked: false, reauth: true };
  // API 호출의 401만 권한이 끊긴 것이다. 토큰 발급 창구의 401은 우리 쪽 설정 문제라 error로 남기고, 설정을 고치면 다음 동기화가 이어 간다
  if (error instanceof NotionError && !(error instanceof NotionOAuthError) && error.status === 401) {
    return { message: "Notion 연결 권한이 끊겼습니다. 다시 연결해 주세요.", revoked: true, reauth: false };
  }
  if (error instanceof NotionError) return { message: `Notion 요청 실패 (${error.status})`, revoked: false, reauth: false };
  return { message: "동기화 중 오류가 발생했습니다.", revoked: false, reauth: false };
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

  try {
    // 사용자의 google 연결이 Calendar를 허용했으면 이번 회의록에 같은 회의의 일정을 붙인다 (없으면 그대로: Google을 부르지 않는다)
    const calendar = await googleCalendarLookup(admin, connection.userId);
    const run = (client: NotionClient) =>
      syncNotion(connection, client, { ...ingestDeps(admin), tasks: taskDeps(admin), meetingEvent: calendar?.lookup }, {
        now,
        deadline: options.deadline,
        ...DEFAULT_NOTION_SYNC,
      });
    const result = await withNotionClient(admin, connection.id, run);
    // 일정 잇기 결과(붙음 · 애매 · 없음 · 실패)를 google 연결 설정 stats에 센다 (글자 · 주소 없이, 8장)
    if (calendar && result.meetingLinks) {
      const { attached, ambiguous, none, failed } = result.meetingLinks;
      await addConnectionStats(
        admin,
        { id: calendar.connectionId, userId: connection.userId },
        { notion_link_attached: attached, notion_link_ambiguous: ambiguous, notion_link_none: none, notion_link_failed: failed },
        now,
      ).catch((error) => console.error(`Google 통계 기록 실패 (${calendar.connectionId}):`, error instanceof Error ? error.message : error));
    }
    // 상태 기록이 실패해도 이미 넣은 원문 · 커서는 남긴다. 자동 확인한 할 일 DB도 여기서 남기므로 처음 훑기 표시보다 먼저 한다
    // (실패하면 처음 훑기도 표시되지 않아 다음 동기화가 다시 확인하고 다시 훑는다).
    await recordNotionHealth(admin, connection, result).catch((error) =>
      console.error(`Notion 연결 상태 기록 실패 (${connection.id}):`, error instanceof Error ? error.message : error),
    );
    await markBackfilled(admin, connection, result.backfilled);
    await recordSync(admin, connection, { claimedAt: now, cursor: result.cursor });
    return { connectionId: connection.id, ok: true, result };
  } catch (error) {
    // 동기화 도중 외부 AI 처리 동의를 철회함: 남은 항목은 처리하지 않았다. 연결 오류가 아니므로 오류로 남기지 않고,
    // 커서도 옮기지 않아 다시 동의하면 이어서 가져온다.
    if (error instanceof ConsentRequiredError) {
      await recordSync(admin, connection, { claimedAt: now });
      return { connectionId: connection.id, ok: false, error: CONSENT_WITHDRAWN_MESSAGE, revoked: false };
    }
    const { message, revoked, reauth } = userFacingError(error);
    console.error(`Notion 동기화 실패 (${connection.id}):`, error instanceof Error ? error.message : error);
    const changed = await recordSync(admin, connection, { claimedAt: now, error: message, revoked, reauth });
    // 상태를 실제로 reauth로 바꾼 동기화에서만 알림 한 번 (Gmail과 같다, google-integration.md G9). 알림이 실패해도 동기화 결과는 그대로다
    if (reauth && changed) {
      await notifyReconnect(admin, connection.userId, "notion").catch((notifyError) =>
        console.error(`Notion 재연결 알림 실패 (${connection.id}):`, notifyError instanceof Error ? notifyError.message : notifyError),
      );
    }
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
