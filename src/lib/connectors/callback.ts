import { randomBytes, timingSafeEqual } from "node:crypto";

import { isConnected, type ConnectionAppCallbackError, type ConnectionCallbackStatus, type ConnectProvider } from "@/lib/api/contract";

import { isSignedOAuthState, verifyOAuthState, type OAuthStatePayload } from "./oauth-state";
import type { ConnectedStatus } from "./types";

// OAuth 권한 화면에서 돌아오는 곳 (연동 공통). 두 흐름을 받는다 (docs/GO_LIVE.md 1장).
// - 웹(/lab): 시작할 때 httpOnly 쿠키에 둔 state와 비교하고, 로그인한 사용자가 시작한 사용자와 같아야 한다.
//   바로 연결하고 /lab?{provider}=…로 돌아간다.
// - 앱: 서명된 state(oauth-state.ts)로 시작한 사용자를 알고 nonce를 한 번만 쓴다. 하지만 여기서는 연결하지 않는다:
//   권한 화면을 누른 사람이 시작한 사람이라는 보장이 없다 (남이 만든 권한 주소를 눌러 자기 워크스페이스를 남의 계정에 붙이는 공격).
//   code를 암호화해 완료 대기(handoff, 2분 · 한 번)로 두고 taskforce://connections/{provider}?handoff=<id>로 돌려보낸다.
//   연결은 앱이 로그인한 사용자로 POST /api/v1/connections/{provider}/complete {handoff}를 불러 마친다 (시작한 사용자만 된다).
//   실패하면 taskforce://connections/{provider}?status=denied|error|invalid_state.
// 인증 · 저장 · 토큰 교환은 인자로 받아 Route Handler 밖에서 테스트한다. state · code · handoff는 로그에 남기지 않는다.

export type OAuthCallbackDeps = {
  provider: ConnectProvider;
  /** OAUTH_STATE_SECRET. 설정이 없으면 던진다 (서명 흐름만 부른다) */
  stateSecret: () => string;
  now?: () => Date;
  /** 웹 흐름: 시작할 때 쿠키에 둔 state와 시작한 사용자 */
  cookieState: () => Promise<{ state: string; userId: string } | null>;
  /** 웹 흐름: 로그인한 사용자 */
  authenticate: () => Promise<{ id: string } | null>;
  /** 웹 흐름: 로그인한 사용자가 외부 AI 처리에 동의했나 (시작한 뒤 철회했을 수 있다. 앱 흐름은 complete가 확인한다) */
  hasConsent: () => Promise<boolean>;
  /** 웹 흐름: code → 토큰 → 암호화 저장 */
  connect: (userId: string, code: string) => Promise<ConnectedStatus>;
  /** 웹 흐름: 연결된 뒤 할 일 (지표). 응답을 막지 않도록 부르는 쪽이 after()로 미룬다 */
  onConnected: (userId: string) => void;
  /** 앱 흐름: nonce를 지운다. 이미 썼거나 없으면(다른 사용자 · 다른 서비스 · 만료) false */
  consumeNonce: (payload: OAuthStatePayload) => Promise<boolean>;
  /** 앱 흐름: code를 암호화해 완료 대기로 둔다 (store.ts saveOAuthHandoff) */
  saveHandoff: (handoff: { id: string; userId: string; code: string }) => Promise<void>;
  /** handoff id (기본: 32바이트 난수, base64url) */
  newHandoffId?: () => string;
};

/** 웹 흐름의 쿠키 이름 · 경로 (시작 route와 같아야 한다) */
export const oauthCookie = (provider: ConnectProvider) => ({ name: `${provider}_oauth_state`, path: `/api/connectors/${provider}` });

/** 앱으로 돌아가는 주소: 성공이면 handoff, 실패면 status */
export function appCallbackUrl(provider: ConnectProvider, result: { handoff: string } | { status: ConnectionAppCallbackError }): string {
  const query = "handoff" in result ? `handoff=${encodeURIComponent(result.handoff)}` : `status=${result.status}`;
  return `taskforce://connections/${provider}?${query}`;
}

export const newHandoffId = () => randomBytes(32).toString("base64url");

function redirect(location: string, clearCookie?: ConnectProvider): Response {
  const headers = new Headers({ Location: location });
  if (clearCookie) {
    const { name, path } = oauthCookie(clearCookie);
    headers.append("Set-Cookie", `${name}=; Path=${path}; Max-Age=0; HttpOnly; SameSite=Lax`);
  }
  return new Response(null, { status: 307, headers });
}

export async function handleOAuthCallback(request: Request, deps: OAuthCallbackDeps): Promise<Response> {
  const url = new URL(request.url);
  const state = url.searchParams.get("state") ?? "";
  const code = url.searchParams.get("code");
  const failedStatus = (): "denied" | "error" => (url.searchParams.get("error") === "access_denied" ? "denied" : "error");

  if (isSignedOAuthState(state)) {
    const back = (status: ConnectionAppCallbackError) => redirect(appCallbackUrl(deps.provider, { status }));
    let check: ReturnType<typeof verifyOAuthState>;
    try {
      check = verifyOAuthState(state, deps.stateSecret(), deps.now?.() ?? new Date());
    } catch (error) {
      console.error(`${deps.provider} 연결: state 확인 실패:`, error instanceof Error ? error.message : error);
      return back("error");
    }
    if (!check.ok || check.payload.provider !== deps.provider) return back("invalid_state");
    const { payload } = check;
    // 한 번만 쓴다: 같은 state로 두 번 들어오면(재전송 · 가로챈 주소) 두 번째는 막는다.
    if (!(await deps.consumeNonce(payload).catch(() => false))) return back("invalid_state");
    if (!code) return back(failedStatus());

    const id = (deps.newHandoffId ?? newHandoffId)();
    try {
      await deps.saveHandoff({ id, userId: payload.userId, code });
    } catch (error) {
      console.error(`${deps.provider} 연결: 완료 대기 저장 실패:`, error instanceof Error ? error.message : error);
      return back("error");
    }
    return redirect(appCallbackUrl(deps.provider, { handoff: id }));
  }

  // 웹(/lab) 흐름: 쿠키 state + 로그인 세션
  const user = await deps.authenticate();
  if (!user) return redirect(new URL("/login", request.url).toString());
  const back = (status: ConnectionCallbackStatus) => redirect(new URL(`/lab?${deps.provider}=${status}`, request.url).toString(), deps.provider);

  const cookie = await deps.cookieState();
  const expected = Buffer.from(cookie?.state ?? "");
  const given = Buffer.from(state);
  const stateOk = expected.length > 0 && expected.length === given.length && timingSafeEqual(expected, given);
  // 시작한 계정까지 묶어, 그 사이 다른 계정으로 바꿔 로그인해도 연결이 엉뚱한 계정에 붙지 않게 한다.
  if (!stateOk || cookie?.userId !== user.id) return back("invalid_state");
  if (!code) return back(failedStatus());
  // 연결하면 곧바로 원문을 가져와 처리하므로 연결 직전에 동의를 다시 본다
  const consented = await deps.hasConsent().catch((error) => {
    console.error(`${deps.provider} 동의 확인 실패:`, error instanceof Error ? error.message : error);
    return null;
  });
  if (consented === null) return back("error");
  if (!consented) return back("consent_required");
  let status: ConnectedStatus;
  try {
    status = await deps.connect(user.id, code);
  } catch (error) {
    console.error(`${deps.provider} 연결 실패:`, error instanceof Error ? error.message : error);
    return back("error");
  }
  if (isConnected(status)) deps.onConnected(user.id);
  return back(status);
}
