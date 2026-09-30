import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";
import { notifyReconnect } from "@/lib/notify/service";

import {
  addConnectionStats,
  claimConnection,
  connectedAt,
  ingestDeps,
  loadIdentity,
  loadToken,
  recordSync,
  saveToken,
} from "../store";
import type { Connection, Connector, ConnectorSyncOutcome } from "../types";

import { calendarClient } from "./calendar";
import { meetClient, MeetBudgetExhausted } from "./meet";
import { disconnectOtherGoogleAccounts, revokeStoredGoogleToken, saveGoogleAccount } from "./account";
import { exchangeGoogleCode, GoogleOAuthError, googleAuthorizeUrl, missingScopes, type GoogleOAuthConfig } from "./oauth";
import { googleSettingsSchema } from "./settings";
import { DEFAULT_GOOGLE_SYNC, MEET_REQUEST_BUDGET, syncGoogleMeet } from "./sync";
import { GoogleApiError, googleAccess, GoogleReauthError } from "./token";
import { CALENDAR_EVENTS_SCOPE, MEET_READONLY_SCOPE } from "./unverified";

// google 연결(프로젝트 A: Calendar 조회 · Meet 전사)을 연결 틀(registry.ts)에 올린다: 권한 화면 · 연결 · 동기화 · 토큰 폐기 (docs/go-live/google-integration.md 2-3 · 2-4 · 2-5 · 2-8).
// Calendar는 저장하지 않고 필요할 때 조회하므로(G3) 이 연결의 동기화가 하는 일은 Meet 전사를 원문으로 넣는 것 하나다.
// Notion 회의록에 일정을 붙이는 조회는 notion/run.ts가 lookup.ts로 부른다.

/** 요청하는 범위 (google-verification.md 1장 A, 처리방침 3장 Google과 같아야 한다). Calendar · Meet은 각각 빼도 연결된다 (G10) */
export const GOOGLE_SCOPES = ["openid", "email", CALENDAR_EVENTS_SCOPE, MEET_READONLY_SCOPE] as const;

export function googleOAuthConfig(): GoogleOAuthConfig {
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const redirectUri = process.env.GOOGLE_REDIRECT_URI;
  if (!clientId || !clientSecret || !redirectUri) {
    throw new Error("GOOGLE_CLIENT_ID · GOOGLE_CLIENT_SECRET · GOOGLE_REDIRECT_URI가 필요합니다. .env.example을 보세요.");
  }
  return { clientId, clientSecret, redirectUri };
}

/** 이용자가 허용한 기능 (G10): 허용한 쪽만 쓴다 */
export function grantedFeatures(scopes: readonly string[]): { calendar: boolean; meet: boolean } {
  return {
    calendar: missingScopes(scopes, [CALENDAR_EVENTS_SCOPE]).length === 0,
    meet: missingScopes(scopes, [MEET_READONLY_SCOPE]).length === 0,
  };
}

const REAUTH_MESSAGE = "Google 연결이 만료됐습니다. 다시 연결해 주세요.";
const RATE_LIMITED_MESSAGE = "Google 요청 한도에 걸려 다음 동기화에서 이어서 가져옵니다.";

/** 사용자에게 보여줄 오류. 자세한 내용은 서버 로그에만 (오류 코드뿐, 본문 · 이름 · 토큰 없음) */
function userFacingError(error: unknown): string {
  if (error instanceof GoogleApiError) return `Google 요청 실패 (${error.status})`;
  // 토큰 창구의 invalid_grant 밖의 거절(invalid_client 등)은 우리 쪽 설정 문제다: 권한 끊김으로 보지 않는다
  if (error instanceof GoogleOAuthError) return `Google 토큰 요청 실패 (${error.code ?? error.status})`;
  return "동기화 중 오류가 발생했습니다.";
}

const logError = (what: string) => (error: unknown) => console.error(`${what}:`, error instanceof Error ? error.message : error);

export async function syncGoogleConnection(
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
  // 설정을 읽지 못하면 아무 기능도 허용하지 않은 것으로 보고 동기화가 아무것도 하지 않는다: 조용히 성공으로 남지 않게 로그를 남긴다 (설정 내용은 남기지 않는다)
  if (!settings.success) console.error(`Google 연결 설정을 읽지 못해 이번 동기화는 아무것도 가져오지 않습니다 (${connection.id}): 문제 ${settings.error.issues.length}개`);

  try {
    const access = googleAccess({ load: () => loadToken(admin, connection.id), save: (token) => saveToken(admin, connection.id, token) }, googleOAuthConfig());
    const features = grantedFeatures(settings.success ? settings.data.scopes : []);
    const calendar = features.calendar ? calendarClient(access) : null;

    // Meet을 허용하지 않은 연결(Calendar만): 가져올 전사가 없다. 토큰이 아직 쓸 수 있는지만 본다 (만료 · 거둠이면 reauth로 알린다)
    if (!features.meet) {
      if (calendar) await calendar.list({ timeMin: now, timeMax: new Date(now.getTime() + 60_000), maxResults: 1 });
      await recordSync(admin, connection, { claimedAt: now });
      return { connectionId: connection.id, ok: true, result: { created: [], scanned: 0, skipped: {} } };
    }

    const [identity, since] = await Promise.all([loadIdentity(admin, connection.userId), connectedAt(admin, connection)]);
    const result = await syncGoogleMeet(
      connection,
      {
        meet: true,
        calendar,
        meetApi: meetClient(access, { budget: { left: MEET_REQUEST_BUDGET } }),
        me: {
          name: identity.name,
          aliases: identity.aliases,
          email: settings.success ? settings.data.email : null,
          sub: settings.success ? settings.data.googleUserId : null,
        },
      },
      // 연결(다시 연결) 전 시각의 전사는 확인 요청 알림을 보내지 않는다: 첫 14일 · 끊긴 동안의 회의
      ingestDeps(admin, { notifyFrom: since }),
      { now, deadline: options.deadline, ...DEFAULT_GOOGLE_SYNC },
    );
    await recordSync(admin, connection, {
      claimedAt: now,
      ...(result.cursor ? { cursor: result.cursor } : {}),
      error: result.rateLimited ? RATE_LIMITED_MESSAGE : null,
    });
    // 커서를 남긴 뒤에 센다: 커서 기록이 실패하면 다음 동기화가 같은 전사를 다시 결정해 두 번 세지 않게
    await addConnectionStats(admin, connection, result.counts, now).catch(logError(`Google 통계 기록 실패 (${connection.id})`));
    return { connectionId: connection.id, ok: true, result };
  } catch (error) {
    // 동기화 도중 외부 AI 처리 동의를 철회함: 연결 오류가 아니다. 커서를 옮기지 않아 다시 동의하면 이어서 가져온다
    if (error instanceof ConsentRequiredError) {
      await recordSync(admin, connection, { claimedAt: now });
      return { connectionId: connection.id, ok: false, error: CONSENT_WITHDRAWN_MESSAGE, revoked: false };
    }
    // 갱신 토큰 만료 (이용자가 Google 계정에서 접근을 거둠 등): 다시 연결할 때까지 동기화하지 않는다
    if (error instanceof GoogleReauthError) {
      const changed = await recordSync(admin, connection, { claimedAt: now, error: REAUTH_MESSAGE, reauth: true });
      // 상태를 실제로 reauth로 바꾼 동기화에서만 알림 한 번 (G9). 알림이 실패해도 동기화 결과는 그대로다.
      // 문구는 앱 연결 화면의 이름 그대로 "Reconnect Google Calendar & Meet to keep syncing." (notify/service.ts SERVICE_NAMES)
      if (changed) await notifyReconnect(admin, connection.userId, "google").catch(logError(`Google 재연결 알림 실패 (${connection.id})`));
      return { connectionId: connection.id, ok: false, error: REAUTH_MESSAGE, revoked: false };
    }
    // 예산을 다 썼다면 여기까지 온 것은 예상 밖이다(동기화 본체가 잡는다). 일반 오류로 남긴다
    const message = error instanceof MeetBudgetExhausted ? RATE_LIMITED_MESSAGE : userFacingError(error);
    logError(`Google 동기화 실패 (${connection.id})`)(error);
    await recordSync(admin, connection, { claimedAt: now, error: message });
    return { connectionId: connection.id, ok: false, error: message, revoked: false };
  }
}

/** 연결 틀(registry.ts)에 내놓는 google 연동 */
export const googleConnector: Connector = {
  provider: "google",
  authorizeUrl: (state) => googleAuthorizeUrl(googleOAuthConfig(), GOOGLE_SCOPES, state),
  connect: async (admin, userId, code) => {
    const grant = await exchangeGoogleCode(googleOAuthConfig(), code);
    const features = grantedFeatures(grant.scopes);
    // 권한 화면에서 Calendar · Meet 체크를 둘 다 뺐거나 계정을 알 수 없으면(openid 없음) 연결하지 않고, 쓸 수 없는 토큰은 바로 폐기한다 (G10)
    if (!grant.account || (!features.calendar && !features.meet)) {
      await revokeStoredGoogleToken(grant.token).catch(logError("Google 토큰 폐기 실패 (범위 부족)"));
      return "missing_scope";
    }
    const account = grant.account;
    const connectionId = await saveGoogleAccount(admin, {
      userId,
      provider: "google",
      account,
      scopes: grant.scopes,
      token: grant.token,
    });
    await disconnectOtherGoogleAccounts(admin, userId, "google", connectionId);
    return features.calendar && features.meet ? "connected" : "connected_partial";
  },
  sync: (admin, connection, options) => syncGoogleConnection(admin, connection, options),
  revokeToken: revokeStoredGoogleToken,
};
