import { z } from "zod";

const publicEnvSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z
    .url()
    .refine((url) => (URL.parse(url)?.pathname ?? "/") === "/", {
      message:
        "경로 없이 프로젝트 주소만 넣어야 합니다 (예: https://<프로젝트 ref>.supabase.co). /rest/v1/ 이나 대시보드 주소는 안 됩니다",
    }),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z.string().min(1),
});

export type PublicEnv = z.infer<typeof publicEnvSchema>;

export function parsePublicEnv(source: Record<string, string | undefined>): PublicEnv {
  const result = publicEnvSchema.safeParse(source);
  if (!result.success) {
    const problems = result.error.issues
      .map((issue) => `${issue.path.join(".")} (${issue.message})`)
      .join(", ");
    throw new Error(`환경변수가 없거나 잘못되었습니다: ${problems}. .env.example을 참고해 .env.local을 채우세요.`);
  }
  return result.data;
}

// NEXT_PUBLIC_* 값은 빌드 때 브라우저 번들에 인라인되므로 process.env.X 형태로 직접 참조해야 한다.
export function publicEnv(): PublicEnv {
  return parsePublicEnv({
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  });
}

/** 주간 질문(지표 5)을 묻는가 (WEEKLY_CHECK_ENABLED, 서버 전용). 기본은 켜짐이고, 베타가 끝나면 "false"로 끈다. */
export function weeklyCheckEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return !["false", "0", "off"].includes((env.WEEKLY_CHECK_ENABLED ?? "").trim().toLowerCase());
}

/** 서명된 OAuth state를 만들고 확인할 때 쓰는 키의 최소 길이 (openssl rand -hex 32는 64자) */
const MIN_OAUTH_STATE_SECRET = 32;

/**
 * 앱의 OAuth 연결(서명된 state, HMAC-SHA256)에 쓰는 비밀값 (OAUTH_STATE_SECRET, 서버 전용).
 * 없거나 짧으면 던진다: 약한 키로 서명한 state는 다른 사람 계정에 연결을 끼워 넣는 데 쓰일 수 있다.
 */
export function oauthStateSecret(env: Record<string, string | undefined> = process.env): string {
  const secret = env.OAUTH_STATE_SECRET?.trim() ?? "";
  if (secret.length < MIN_OAUTH_STATE_SECRET) {
    throw new Error(`OAUTH_STATE_SECRET이 없거나 ${MIN_OAUTH_STATE_SECRET}자보다 짧습니다. openssl rand -hex 32로 만들어 .env.local에 넣으세요.`);
  }
  return secret;
}

/**
 * Slack이 보낸 요청의 서명을 확인하는 키 (SLACK_SIGNING_SECRET, 서버 전용). Slack 앱 → Basic Information → App Credentials.
 * 없으면 던진다: 서명을 확인하지 않고 받으면 누구나 가짜 메시지를 이용자의 원문으로 넣을 수 있다.
 */
export function slackSigningSecret(env: Record<string, string | undefined> = process.env): string {
  const secret = env.SLACK_SIGNING_SECRET?.trim() ?? "";
  if (!secret) throw new Error("SLACK_SIGNING_SECRET이 없습니다. Slack 앱의 Basic Information → Signing Secret을 .env.local에 넣으세요.");
  return secret;
}

/**
 * 앱 수준 토큰 (SLACK_APP_TOKEN, xapp-, 권한 authorizations:read). 한 워크스페이스에 Taskforce 이용자가 둘 이상일 때
 * 이벤트를 볼 수 있는 이용자를 모두 찾는 데만 쓴다(apps.event.authorizations.list, slack-integration.md D4). 없으면 null.
 */
export function slackAppToken(env: Record<string, string | undefined> = process.env): string | null {
  const token = env.SLACK_APP_TOKEN?.trim() ?? "";
  return token.startsWith("xapp-") ? token : null;
}

/**
 * 앱에 Slack 연결을 여는가 (SLACK_CONNECT_ENABLED = "true"). 운영은 처리방침 · 앱 문구(slack-integration.md PR 4)를 맞춘 뒤에 켠다:
 * 연동 틀에 올리면 앱의 "Coming soon"이 바로 Connect가 된다. 설정하지 않았으면 개발 서버에서만 연다.
 * 닫혀 있어도 이미 있는 연결의 토큰 폐기 · 이벤트 받기는 그대로 한다.
 */
export function slackConnectEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return connectFlag(env, "SLACK_CONNECT_ENABLED");
}

/**
 * 앱에 Gmail 연결을 여는가 (GMAIL_CONNECT_ENABLED = "true"). Slack과 같은 모양: 운영은 처리방침 3장 Gmail 절 · 앱 문구
 * (docs/go-live/google-integration.md PR 4 · 5)를 맞춘 뒤에 켠다. 설정하지 않았으면 개발 서버에서만 연다.
 * 닫혀 있어도 이미 있는 연결의 동기화 · 토큰 폐기는 그대로 한다.
 */
export function gmailConnectEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return connectFlag(env, "GMAIL_CONNECT_ENABLED");
}

/**
 * 앱에 google(Calendar · Meet 전사) 연결을 여는가 (GOOGLE_CONNECT_ENABLED = "true"). Gmail과 같은 모양: 운영은 처리방침 3장 Google 절 · 앱 문구
 * (docs/go-live/google-integration.md PR 4 · 5)를 맞춘 뒤에 켠다. 설정하지 않았으면 개발 서버에서만 연다.
 * 닫혀 있어도 이미 있는 연결의 동기화 · 토큰 폐기는 그대로 한다.
 */
export function googleConnectEnabled(env: Record<string, string | undefined> = process.env): boolean {
  return connectFlag(env, "GOOGLE_CONNECT_ENABLED");
}

function connectFlag(env: Record<string, string | undefined>, name: string): boolean {
  const flag = env[name]?.trim();
  if (flag) return flag === "true";
  return env.NODE_ENV === "development";
}
