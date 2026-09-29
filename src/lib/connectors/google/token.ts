import { googleTokenSchema, isInvalidGrant, refreshGoogleToken, type GoogleOAuthConfig, type GoogleToken } from "./oauth";

// 연결에 저장된 Google 토큰으로 API를 부른다 (docs/go-live/google-integration.md 2-3).
// - 만료 60초 전이면 먼저 갱신해 저장한다. API가 401이면 한 번 갱신해 다시 부른다 (동시에 여럿이 401을 받아도 갱신은 한 번).
// - 갱신이 invalid_grant면 GoogleReauthError: 다시 연결할 때까지 동기화하지 않는다 (recordSync reauth).
// - Google은 갱신 토큰을 바꾸지 않아, 다른 실행이 동시에 갱신해도 둘 다 유효하다 (Notion의 동시 갱신 확인이 필요 없다).

/** API 호출의 실패 (Gmail · Calendar · Meet). reason은 Google 오류 본문의 reason · status (예: rateLimitExceeded, PERMISSION_DENIED) */
export class GoogleApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly reason?: string,
  ) {
    super(message);
    this.name = "GoogleApiError";
  }
}

/** 갱신 토큰을 더 쓸 수 없다: 이용자가 다시 연결해야 한다 */
export class GoogleReauthError extends Error {
  constructor() {
    super("Google 갱신 토큰이 거절됐습니다 (invalid_grant)");
    this.name = "GoogleReauthError";
  }
}

export type GoogleTokenStore = { load: () => Promise<unknown>; save: (token: GoogleToken) => Promise<void> };

/** 토큰을 붙여 GET 한다. 401이면 한 번 갱신해 다시 부른 응답을 돌려준다 (그래도 401이면 그 응답) */
export type GoogleAccess = { get: (url: string) => Promise<Response> };

const REFRESH_BEFORE_MS = 60_000;
const REQUEST_TIMEOUT_MS = 15_000;

export function googleAccess(store: GoogleTokenStore, config: GoogleOAuthConfig, options: { now?: () => number } = {}): GoogleAccess {
  const now = options.now ?? Date.now;
  const doFetch = config.fetch ?? fetch;

  const refresh = async (token: GoogleToken): Promise<GoogleToken> => {
    let next: GoogleToken;
    try {
      next = await refreshGoogleToken(config, token, new Date(now()));
    } catch (error) {
      if (isInvalidGrant(error)) throw new GoogleReauthError();
      throw error;
    }
    await store.save(next);
    return next;
  };

  let current: Promise<GoogleToken> | null = null;
  const token = () =>
    (current ??= store.load().then((raw) => {
      const parsed = googleTokenSchema.safeParse(raw);
      if (!parsed.success) throw new Error("저장된 Google 토큰 형식이 예상과 다릅니다");
      return parsed.data.expires_at - REFRESH_BEFORE_MS <= now() ? refresh(parsed.data) : parsed.data;
    }));
  // 401을 받은 액세스 토큰 → 그 뒤의 갱신. 같은 토큰으로 401을 받은 요청은 이 갱신을 함께 기다린다
  let refreshed: { from: string; next: Promise<GoogleToken> } | null = null;

  const call = (url: string, used: GoogleToken) =>
    doFetch(url, { headers: { Authorization: `Bearer ${used.access_token}` }, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });

  return {
    async get(url) {
      const used = await token();
      const response = await call(url, used);
      if (response.status !== 401) return response;
      if (refreshed?.from !== used.access_token) {
        const next = refresh(used);
        refreshed = { from: used.access_token, next };
        current = next;
      }
      return call(url, await refreshed.next);
    },
  };
}

/** 오류 응답에서 짧은 이유 (본문 · 토큰은 담지 않는다) */
export async function googleErrorReason(response: Response): Promise<string | undefined> {
  const body = (await response.json().catch(() => null)) as { error?: { status?: unknown; errors?: { reason?: unknown }[] } } | null;
  const reason = body?.error?.errors?.[0]?.reason ?? body?.error?.status;
  return typeof reason === "string" ? reason : undefined;
}
