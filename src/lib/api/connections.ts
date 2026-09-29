import { z } from "zod";

import type { OAuthStatePayload } from "@/lib/connectors/oauth-state";
import type { ConnectedStatus, Provider } from "@/lib/connectors/types";

import { consentRequired } from "./consent";
import {
  connectionCompleteRequestSchema,
  connectionRequestSchema,
  connectionStartRequestSchema,
  connectProviderSchema,
  type ConnectionCompleteResponse,
  type ConnectionRequest,
  type ConnectionStartResponse,
  type ConnectProvider,
} from "./contract";
import { retryAfterSeconds } from "./rate-limit";
import { errorResponse, parseBody, unauthorized } from "./respond";

// 연결 시작(POST /api/v1/connections/{provider}/start) · 연결 마치기(POST /api/v1/connections/{provider}/complete) ·
// 연결 끊기(DELETE /api/v1/connections/:id)와 2단계 연동 "원해요"(POST /api/v1/connection-requests) 처리. 인증 · 동의 확인 · 저장을 인자로 받아 Route Handler 밖에서 테스트한다.

export type ConnectionStartDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  hasConsent: (user: User) => Promise<boolean>;
  /** 붙인 서비스면 권한 화면 주소를 만드는 함수, 아직이면 null */
  authorizer: (provider: ConnectProvider) => ((state: string) => string) | null;
  /** 한도(10분에 10번)에 찼으면 다시 할 수 있는 시각, 아니면 시도를 남기고 null */
  rateLimit: (user: User) => Promise<Date | null>;
  /** 이 사용자의 서명된 state와 그 내용 (oauth-state.ts newOAuthState) */
  newState: (user: User, provider: ConnectProvider) => { state: string; payload: OAuthStatePayload };
  /** nonce를 남긴다 (callback에서 한 번만 쓴다) */
  saveNonce: (payload: OAuthStatePayload) => Promise<void>;
  now?: () => Date;
};

export async function handleConnectionStart<User>(
  request: Request,
  providerParam: string,
  deps: ConnectionStartDeps<User>,
): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();

  const provider = connectProviderSchema.safeParse(providerParam);
  if (!provider.success) return errorResponse(404, "not_found", "없는 서비스입니다.");
  const authorize = deps.authorizer(provider.data);
  if (!authorize) return errorResponse(400, "invalid_request", "아직 연결할 수 없어요.");
  // 연결하면 곧바로 원문을 가져와 처리하므로, 외부 AI 처리 동의가 먼저다.
  if (!(await deps.hasConsent(user))) return consentRequired();

  const body = await parseBody(request, connectionStartRequestSchema);
  if ("error" in body) return body.error;

  try {
    const retryAt = await deps.rateLimit(user);
    if (retryAt) {
      const response = errorResponse(429, "rate_limited", "연결 시도가 너무 잦습니다. 잠시 뒤 다시 시도해 주세요.");
      response.headers.set("Retry-After", String(retryAfterSeconds(retryAt, deps.now?.() ?? new Date())));
      return response;
    }
    const { state, payload } = deps.newState(user, provider.data);
    await deps.saveNonce(payload);
    return Response.json({ url: authorize(state) } satisfies ConnectionStartResponse);
  } catch (error) {
    // state · 주소는 로그에 남기지 않는다.
    console.error(`${provider.data} 연결 시작 실패:`, error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "연결을 시작하지 못했습니다.");
  }
}

export type ConnectionCompleteDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  hasConsent: (user: User) => Promise<boolean>;
  /** 붙인 서비스인가 */
  implemented: (provider: ConnectProvider) => boolean;
  /**
   * 이 사용자가 시작한, 만료 전인 handoff를 지우며 code를 꺼낸다 (한 번만). 없거나 · 만료됐거나 · 다른 사용자 것이면 null.
   * (store.ts consumeOAuthHandoff: id · user_id · provider를 모두 조건으로 delete … returning)
   */
  consumeHandoff: (user: User, provider: ConnectProvider, handoff: string) => Promise<string | null>;
  /** code → 토큰 → 암호화 저장 */
  connect: (user: User, provider: ConnectProvider, code: string) => Promise<ConnectedStatus>;
  /** 연결된 뒤 할 일 (지표 · 첫 동기화). 응답을 막지 않도록 부르는 쪽이 after()로 미룬다 */
  onConnected: (user: User, provider: ConnectProvider) => void;
};

/**
 * 앱 흐름의 연결 마치기. 연결은 권한 화면을 연 브라우저가 아니라, 로그인한 앱이 handoff를 내밀어야 생긴다:
 * 남이 시작한 연결(남의 계정에 묶인 handoff)은 404라서, 남이 보낸 권한 주소를 눌러도 내 워크스페이스가 남의 계정에 붙지 않는다.
 */
export async function handleConnectionComplete<User>(
  request: Request,
  providerParam: string,
  deps: ConnectionCompleteDeps<User>,
): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();

  const provider = connectProviderSchema.safeParse(providerParam);
  if (!provider.success) return errorResponse(404, "not_found", "없는 서비스입니다.");
  if (!deps.implemented(provider.data)) return errorResponse(400, "invalid_request", "아직 연결할 수 없어요.");
  const body = await parseBody(request, connectionCompleteRequestSchema);
  if ("error" in body) return body.error;
  // handoff를 쓰기 전에 확인한다: 동의하고 2분 안에 다시 부르면 이어서 마칠 수 있다.
  if (!(await deps.hasConsent(user))) return consentRequired();

  let code: string | null;
  try {
    code = await deps.consumeHandoff(user, provider.data, body.data.handoff);
  } catch (error) {
    console.error(`${provider.data} 연결 마치기 실패:`, error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "연결을 마치지 못했습니다.");
  }
  // 없음 · 만료 · 재사용 · 다른 사용자가 시작함을 구분하지 않는다 (다른 사람의 handoff가 있는지 알려 주지 않는다).
  if (!code) return errorResponse(404, "not_found", "연결 요청이 없거나 만료됐어요. 다시 연결해 주세요.");

  let status: ConnectedStatus;
  try {
    status = await deps.connect(user, provider.data, code);
  } catch (error) {
    // code · 토큰은 로그에 남기지 않는다.
    console.error(`${provider.data} 연결 실패:`, error instanceof Error ? error.message : error);
    return errorResponse(502, "internal_error", "서비스와 연결하지 못했어요. 다시 연결해 주세요.");
  }
  deps.onConnected(user, provider.data);
  return Response.json({ status } satisfies ConnectionCompleteResponse);
}

export type ConnectionDeleteDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  /** 이 사용자의 연결과 풀어 둔 토큰 (연결이 없으면 null, 토큰을 풀지 못했으면 token null) */
  load: (user: User, id: string) => Promise<{ provider: Provider; token: unknown } | null>;
  /** 서비스 쪽 토큰 폐기 (연결 틀의 revokeToken). 폐기 API가 없는 연동은 null */
  revoker: (provider: Provider) => ((token: unknown) => Promise<void>) | null;
  /** Slack이면 Slack에서 온 글자를 지우고(D3) 연결 행을 지운다 (한 트랜잭션, disconnect_connection). 이 사용자의 연결이 없으면 false */
  disconnect: (user: User, id: string) => Promise<boolean>;
};

/**
 * 연결 끊기를 서버 권한으로: 서비스 쪽 토큰 폐기 → (Slack) Slack 글자 지우기 → 연결 행 삭제 (docs/go-live/slack-integration.md 2-7).
 * 토큰 폐기가 실패해도(서비스 장애) 끊기는 계속한다: 우리 쪽 토큰은 연결과 함께 지워지고, 데이터 지우기가 더 중요하다.
 * 남의 연결 · 없는 연결은 같은 404.
 */
export async function handleConnectionDelete<User>(request: Request, id: string, deps: ConnectionDeleteDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  if (!z.uuid().safeParse(id).success) return errorResponse(404, "not_found", "연결이 없습니다.");

  try {
    const connection = await deps.load(user, id);
    if (!connection) return errorResponse(404, "not_found", "연결이 없습니다.");
    const revoke = connection.token === null ? null : deps.revoker(connection.provider);
    if (revoke) {
      await revoke(connection.token).catch((error) =>
        console.error(`${connection.provider} 토큰 폐기 실패 (연결 끊기):`, error instanceof Error ? error.message : error),
      );
    }
    if (!(await deps.disconnect(user, id))) return errorResponse(404, "not_found", "연결이 없습니다.");
  } catch (error) {
    console.error("연결 끊기 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "연결을 끊지 못했습니다.");
  }
  return new Response(null, { status: 204 });
}

export type ConnectionRequestDeps<User> = {
  authenticate: (request: Request) => Promise<User | null>;
  /** 이미 요청했으면 그대로 둔다 (사용자 · 서비스마다 하나) */
  save: (user: User, provider: ConnectionRequest["provider"]) => Promise<void>;
};

export async function handleConnectionRequest<User>(request: Request, deps: ConnectionRequestDeps<User>): Promise<Response> {
  const user = await deps.authenticate(request);
  if (!user) return unauthorized();
  const body = await parseBody(request, connectionRequestSchema);
  if ("error" in body) return body.error;
  try {
    await deps.save(user, body.data.provider);
  } catch (error) {
    console.error("연동 요청 저장 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "요청을 저장하지 못했습니다.");
  }
  return new Response(null, { status: 204 });
}
