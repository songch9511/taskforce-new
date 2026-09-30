import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";
import { notifyReconnect } from "@/lib/notify/service";

import {
  addConnectionStats,
  claimConnection,
  connectedAt,
  disconnectConnection,
  ingestDeps,
  loadIdentity,
  loadToken,
  mergeConnectionSettings,
  otherConnections,
  recordSync,
  saveConnection,
  saveToken,
} from "../store";
import type { Connection, Connector, ConnectorSyncOutcome } from "../types";

import { exchangeGoogleCode, GoogleOAuthError, googleAuthorizeUrl, googleTokenSchema, missingScopes, revokeGoogleToken, type GoogleOAuthConfig } from "../google/oauth";
import { accountSettings, googleSettingsSchema } from "../google/settings";
import { GoogleApiError, googleAccess, GoogleReauthError } from "../google/token";

import { gmailClient } from "./client";
import { companyDomain } from "./filter";
import { DEFAULT_GMAIL_SYNC, syncGmail } from "./sync";

// Gmail 연동을 연결 틀(registry.ts)에 올린다: 권한 화면 · 연결 · 동기화 · 토큰 폐기 (docs/go-live/google-integration.md 2-3 · 2-6 · 2-8).
// Google 프로젝트 B(Testing)라 갱신 토큰이 7일마다 만료된다: invalid_grant → reauth, 앱이 다시 연결을 안내한다.

export const GMAIL_READONLY = "https://www.googleapis.com/auth/gmail.readonly";
/** 요청하는 범위 (google-verification.md 1장 B, 처리방침 3장 Gmail과 같아야 한다) */
export const GMAIL_SCOPES = ["openid", "email", GMAIL_READONLY] as const;

export function gmailOAuthConfig(): GoogleOAuthConfig {
  const clientId = process.env.GMAIL_CLIENT_ID;
  const clientSecret = process.env.GMAIL_CLIENT_SECRET;
  const redirectUri = process.env.GMAIL_REDIRECT_URI;
  if (!clientId || !clientSecret || !redirectUri) {
    throw new Error("GMAIL_CLIENT_ID · GMAIL_CLIENT_SECRET · GMAIL_REDIRECT_URI가 필요합니다. .env.example을 보세요.");
  }
  return { clientId, clientSecret, redirectUri };
}

const REAUTH_MESSAGE = "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.";
const RATE_LIMITED_MESSAGE = "Gmail 요청 한도에 걸려 다음 동기화에서 이어서 가져옵니다.";

/** 사용자에게 보여줄 오류. 자세한 내용은 서버 로그에만 (오류 코드뿐, 본문 · 주소 · 토큰 없음) */
function userFacingError(error: unknown): string {
  if (error instanceof GoogleApiError) return `Gmail 요청 실패 (${error.status})`;
  // 토큰 창구의 invalid_grant 밖의 거절(invalid_client 등)은 우리 쪽 설정 문제다: 권한 끊김으로 보지 않는다
  if (error instanceof GoogleOAuthError) return `Google 토큰 요청 실패 (${error.code ?? error.status})`;
  return "동기화 중 오류가 발생했습니다.";
}

const logError = (what: string) => (error: unknown) => console.error(`${what}:`, error instanceof Error ? error.message : error);

/** 저장된 토큰을 폐기한다 (갱신 토큰이 있으면 그것으로: 허용 전체가 거둬진다) */
async function revokeStoredToken(token: unknown): Promise<void> {
  const parsed = googleTokenSchema.safeParse(token);
  if (parsed.success) await revokeGoogleToken(parsed.data.refresh_token ?? parsed.data.access_token);
}

export async function syncGmailConnection(
  admin: SupabaseClient,
  connection: Connection,
  options: { now?: Date; deadline?: number } = {},
): Promise<ConnectorSyncOutcome> {
  const now = options.now ?? new Date();
  // 같은 연결을 cron과 수동 동기화가 동시에 돌리지 않는다
  if (!(await claimConnection(admin, connection, now))) {
    return { connectionId: connection.id, ok: false, error: "이미 동기화 중입니다.", revoked: false, busy: true };
  }
  const settings = googleSettingsSchema.safeParse(connection.settings);
  const accountEmail = settings.success ? settings.data.email : null;

  try {
    const access = googleAccess({ load: () => loadToken(admin, connection.id), save: (token) => saveToken(admin, connection.id, token) }, gmailOAuthConfig());
    const [identity, since] = await Promise.all([loadIdentity(admin, connection.userId), connectedAt(admin, connection)]);
    const result = await syncGmail(
      connection,
      gmailClient(access),
      // 연결(다시 연결) 전 시각의 메일은 확인 요청 알림을 보내지 않는다: 첫 14일 · 끊긴 동안의 메일
      ingestDeps(admin, { notifyFrom: since }),
      { filter: { userEmails: identity.emails, companyDomain: companyDomain(accountEmail) }, accountEmail },
      { now, deadline: options.deadline, ...DEFAULT_GMAIL_SYNC },
    );
    await recordSync(admin, connection, { claimedAt: now, cursor: result.cursor, error: result.rateLimited ? RATE_LIMITED_MESSAGE : null });
    // 커서를 남긴 뒤에 센다: 커서 기록이 실패하면 다음 동기화가 같은 메일을 다시 결정해 두 번 세지 않게
    await addConnectionStats(admin, connection, { ...result.decisions, ingested: result.created.length }, now).catch(logError(`Gmail 통계 기록 실패 (${connection.id})`));
    return { connectionId: connection.id, ok: true, result };
  } catch (error) {
    // 동기화 도중 외부 AI 처리 동의를 철회함: 연결 오류가 아니다. 커서를 옮기지 않아 다시 동의하면 이어서 가져온다
    if (error instanceof ConsentRequiredError) {
      await recordSync(admin, connection, { claimedAt: now });
      return { connectionId: connection.id, ok: false, error: CONSENT_WITHDRAWN_MESSAGE, revoked: false };
    }
    // 갱신 토큰 만료 (테스트 상태 7일 · 이용자가 Google 계정에서 접근을 거둠 등): 다시 연결할 때까지 동기화하지 않는다
    if (error instanceof GoogleReauthError) {
      const changed = await recordSync(admin, connection, { claimedAt: now, error: REAUTH_MESSAGE, reauth: true });
      // 상태를 실제로 reauth로 바꾼 동기화에서만 알림 한 번 (G9). 알림이 실패해도 동기화 결과는 그대로다
      if (changed) await notifyReconnect(admin, connection.userId, "gmail").catch(logError(`Gmail 재연결 알림 실패 (${connection.id})`));
      return { connectionId: connection.id, ok: false, error: REAUTH_MESSAGE, revoked: false };
    }
    const message = userFacingError(error);
    logError(`Gmail 동기화 실패 (${connection.id})`)(error);
    await recordSync(admin, connection, { claimedAt: now, error: message });
    return { connectionId: connection.id, ok: false, error: message, revoked: false };
  }
}

/** 한 서비스에 계정 하나 (베타): 다른 Google 계정으로 연결했으면 옛 연결의 토큰을 폐기하고 끊는다. 실패해도 새 연결은 그대로 둔다 */
async function disconnectOtherAccounts(admin: SupabaseClient, userId: string, keepId: string): Promise<void> {
  for (const other of await otherConnections(admin, userId, "gmail", keepId)) {
    await revokeStoredToken(other.token).catch(logError(`옛 Gmail 연결 토큰 폐기 실패 (${other.id})`));
    await disconnectConnection(admin, userId, other.id).catch(logError(`옛 Gmail 연결 끊기 실패 (${other.id})`));
  }
}

/** 연결 틀(registry.ts)에 내놓는 Gmail 연동 */
export const gmailConnector: Connector = {
  provider: "gmail",
  authorizeUrl: (state) => googleAuthorizeUrl(gmailOAuthConfig(), GMAIL_SCOPES, state),
  connect: async (admin, userId, code) => {
    const grant = await exchangeGoogleCode(gmailOAuthConfig(), code);
    // 권한 화면에서 Gmail 체크를 뺐거나 계정을 알 수 없으면(openid 없음) 연결하지 않고, 쓸 수 없는 토큰은 바로 폐기한다 (G10)
    if (!grant.account || missingScopes(grant.scopes, [GMAIL_READONLY]).length > 0) {
      await revokeStoredToken(grant.token).catch(logError("Gmail 토큰 폐기 실패 (범위 부족)"));
      return "missing_scope";
    }
    const account = grant.account;
    const connectionId = await saveConnection(admin, {
      userId,
      provider: "gmail",
      externalAccountId: account.sub,
      displayName: account.email,
      token: grant.token,
    });
    if (!(await mergeConnectionSettings(admin, { id: connectionId, userId }, { set: accountSettings(account, grant.scopes) }))) {
      throw new Error("연결 설정을 저장하지 못했습니다 (연결이 사라짐)");
    }
    await disconnectOtherAccounts(admin, userId, connectionId);
    return "connected";
  },
  sync: (admin, connection, options) => syncGmailConnection(admin, connection, options),
  revokeToken: revokeStoredToken,
};
