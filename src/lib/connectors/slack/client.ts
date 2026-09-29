import { z } from "zod";

// Slack Web API 호출. 응답은 모두 zod로 확인한다. 토큰은 로그에 남기지 않는다.
// Slack은 실패도 HTTP 200 + { ok: false, error }로 답한다(속도 제한만 429 + Retry-After).

const SLACK_API = "https://slack.com/api";

export class SlackError extends Error {
  constructor(
    message: string,
    /** Slack의 error 값 (예: token_revoked). 속도 제한은 ratelimited, 응답 형식이 다르면 bad_response */
    readonly code: string,
  ) {
    super(message);
    this.name = "SlackError";
  }
}

/** 토큰을 더 쓸 수 없다는 오류: 이용자가 Slack에서 앱을 지웠거나 권한을 거뒀다(계정 비활성 포함) */
const AUTH_ERRORS = new Set(["token_revoked", "invalid_auth", "account_inactive", "not_authed", "token_expired"]);
export const isSlackAuthError = (error: unknown): boolean => error instanceof SlackError && AUTH_ERRORS.has(error.code);

const envelopeSchema = z.looseObject({ ok: z.boolean(), error: z.string().optional() });

async function callSlack<T>(
  method: string,
  auth: string,
  params: Record<string, string>,
  schema: z.ZodType<T>,
  options: { fetch?: typeof fetch; timeoutMs?: number } = {},
): Promise<T> {
  const response = await (options.fetch ?? fetch)(`${SLACK_API}/${method}`, {
    method: "POST",
    headers: { Authorization: auth, "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(params),
    signal: AbortSignal.timeout(options.timeoutMs ?? 10_000),
  });
  if (response.status === 429) throw new SlackError(`Slack ${method} 속도 제한`, "ratelimited");
  const envelope = envelopeSchema.safeParse(await response.json().catch(() => null));
  if (!envelope.success) throw new SlackError(`Slack ${method} 응답 형식이 예상과 다릅니다 (${response.status})`, "bad_response");
  if (!envelope.data.ok) {
    const code = envelope.data.error ?? `http_${response.status}`;
    throw new SlackError(`Slack ${method} 실패: ${code}`, code);
  }
  const parsed = schema.safeParse(envelope.data);
  if (!parsed.success) throw new SlackError(`Slack ${method} 응답 형식이 예상과 다릅니다`, "bad_response");
  return parsed.data;
}

const bearer = (token: string) => `Bearer ${token}`;

// ─── OAuth (사용자 토큰만, 봇 없음: docs/go-live/slack-app.md) ─────────────

/** 이용자에게 요청하는 권한 9개 (slack-app.md 3-1, slack-integration.md D7). 처리방침 3장 목록과 같아야 한다 */
export const SLACK_USER_SCOPES = [
  "im:history",
  "mpim:history",
  "channels:history",
  "groups:history",
  "users:read",
  "im:read",
  "mpim:read",
  "channels:read",
  "groups:read",
] as const;

export type SlackOAuthConfig = { clientId: string; clientSecret: string; redirectUri: string; fetch?: typeof fetch };

/** 권한 화면 주소. 봇 권한이 없으므로 scope는 비우고 user_scope만 보낸다 */
export function slackAuthorizeUrl(config: Pick<SlackOAuthConfig, "clientId" | "redirectUri">, state: string): string {
  const url = new URL("https://slack.com/oauth/v2/authorize");
  url.search = new URLSearchParams({
    client_id: config.clientId,
    user_scope: SLACK_USER_SCOPES.join(","),
    redirect_uri: config.redirectUri,
    state,
  }).toString();
  return url.toString();
}

/** 저장하는 토큰 (connection_secrets, 암호화). 토큰 갱신(rotation)은 끈 채라 만료가 없다 */
export const slackTokenSchema = z.object({
  access_token: z.string().min(1),
  scope: z.string(),
  user_id: z.string().min(1),
  team_id: z.string().min(1),
});
export type SlackToken = z.infer<typeof slackTokenSchema>;

const oauthAccessSchema = z.object({
  authed_user: z.object({ id: z.string().min(1), access_token: z.string().min(1), scope: z.string().default("") }),
  // 팀 id는 연결을 찾는 쿼리(external_account_id)에 들어가므로 영문 대문자 · 숫자만 받는다 (events.ts와 같다)
  team: z.object({ id: z.string().regex(/^[A-Z0-9]{1,32}$/), name: z.string().nullish() }),
});

/** callback의 code를 이용자 토큰으로 바꾼다 (oauth.v2.access) */
export async function exchangeSlackCode(config: SlackOAuthConfig, code: string): Promise<{ token: SlackToken; teamName: string | null }> {
  const basic = `Basic ${Buffer.from(`${config.clientId}:${config.clientSecret}`).toString("base64")}`;
  const body = await callSlack("oauth.v2.access", basic, { code, redirect_uri: config.redirectUri }, oauthAccessSchema, { fetch: config.fetch });
  return {
    token: { access_token: body.authed_user.access_token, scope: body.authed_user.scope, user_id: body.authed_user.id, team_id: body.team.id },
    teamName: body.team.name ?? null,
  };
}

const authTestSchema = z.object({ url: z.url(), team_id: z.string(), user_id: z.string() });

/** 토큰의 워크스페이스 주소(원본 링크에 쓴다, "https://acme.slack.com/")와 사용자 · 팀 id (auth.test) */
export function slackAuthTest(token: string, fetchImpl?: typeof fetch): Promise<z.infer<typeof authTestSchema>> {
  return callSlack("auth.test", bearer(token), {}, authTestSchema, { fetch: fetchImpl });
}

/** 이미 폐기됐거나 무효인 토큰이면 성공으로 본다 */
const ALREADY_REVOKED = new Set(["token_revoked", "invalid_auth", "account_inactive", "not_authed"]);

/** Slack 쪽 토큰 폐기 (auth.revoke): 연결을 끊거나 계정을 지울 때. 앱이 이용자의 Slack 앱 목록에서 사라진다 */
export async function revokeSlackToken(token: string, fetchImpl?: typeof fetch): Promise<void> {
  try {
    await callSlack("auth.revoke", bearer(token), {}, z.object({ revoked: z.boolean().optional() }), { fetch: fetchImpl });
  } catch (error) {
    if (error instanceof SlackError && ALREADY_REVOKED.has(error.code)) return;
    throw error;
  }
}

// ─── 이름 (users:read · im:read · mpim:read · channels:read · groups:read) ────

const userInfoSchema = z.object({
  user: z.object({
    name: z.string().nullish(),
    real_name: z.string().nullish(),
    profile: z.object({ real_name: z.string().nullish(), display_name: z.string().nullish() }).nullish(),
  }),
});

/** Slack 사용자 id → 이름 (users.info). 실명을 먼저 쓴다: 회의록 · 메일의 이름과 맞춰야 담당 · 상대를 알아본다 */
export async function slackUserName(token: string, userId: string, fetchImpl?: typeof fetch): Promise<string | null> {
  const { user } = await callSlack("users.info", bearer(token), { user: userId }, userInfoSchema, { fetch: fetchImpl });
  const name = [user.profile?.real_name, user.real_name, user.profile?.display_name, user.name].find((n) => n?.trim());
  return name?.trim() ?? null;
}

const conversationInfoSchema = z.object({
  channel: z.object({
    name: z.string().nullish(),
    is_im: z.boolean().optional(),
    is_mpim: z.boolean().optional(),
    /** DM 상대 */
    user: z.string().optional(),
  }),
});

/** 대화 id → 채널 이름 또는 DM 상대 id (conversations.info) */
export async function slackConversation(
  token: string,
  channelId: string,
  fetchImpl?: typeof fetch,
): Promise<{ name: string | null; counterpartId: string | null }> {
  const { channel } = await callSlack("conversations.info", bearer(token), { channel: channelId }, conversationInfoSchema, { fetch: fetchImpl });
  if (channel.is_im) return { name: null, counterpartId: channel.user ?? null };
  return { name: channel.is_mpim ? null : (channel.name?.trim() ?? null), counterpartId: null };
}

// ─── 이벤트 받기 ──────────────────────────────────────────

const authorizationsSchema = z.object({
  authorizations: z.array(z.object({ user_id: z.string().optional(), team_id: z.string().optional(), is_bot: z.boolean().optional() })).optional(),
  response_metadata: z.object({ next_cursor: z.string().optional() }).optional(),
});

/**
 * 이 이벤트를 볼 수 있는 설치(이용자)의 Slack 사용자 id 모두 (apps.event.authorizations.list, 앱 수준 토큰 · authorizations:read).
 * Slack은 같은 메시지를 워크스페이스에 한 번만, 설치 하나의 이름으로 보낸다. 같은 워크스페이스에 Taskforce 이용자가 둘 이상이면
 * 나머지 이용자를 여기서 찾는다(slack-integration.md D4). 이벤트에 3초 안에 답해야 해서 짧게 기다린다.
 */
export async function eventAuthorizedUsers(
  appToken: string,
  eventContext: string,
  fetchImpl: typeof fetch = fetch,
  options: { timeoutMs?: number; maxPages?: number } = {},
): Promise<string[]> {
  const users = new Set<string>();
  let cursor = "";
  for (let page = 0; page < (options.maxPages ?? 5); page++) {
    const body = await callSlack(
      "apps.event.authorizations.list",
      bearer(appToken),
      { event_context: eventContext, ...(cursor ? { cursor } : {}) },
      authorizationsSchema,
      { fetch: fetchImpl, timeoutMs: options.timeoutMs ?? 1500 },
    );
    for (const authorization of body.authorizations ?? []) {
      if (authorization.user_id && !authorization.is_bot) users.add(authorization.user_id);
    }
    cursor = body.response_metadata?.next_cursor ?? "";
    if (!cursor) break;
  }
  return [...users];
}
