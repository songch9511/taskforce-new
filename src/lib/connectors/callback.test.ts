import { describe, expect, it, vi } from "vitest";

import { handleOAuthCallback, newHandoffId, type OAuthCallbackDeps } from "./callback";
import { newOAuthState, signOAuthState, type OAuthStatePayload } from "./oauth-state";
import type { ConnectedStatus } from "./types";

const SECRET = "s".repeat(64);
const ALICE = "00000000-0000-4000-8000-00000000000a";
const BOB = "00000000-0000-4000-8000-00000000000b";
const NOW = new Date("2026-09-27T01:00:00Z");
const CALLBACK = "http://localhost:3000/api/connectors/notion/callback";

function setup(
  options: {
    session?: { id: string } | null;
    cookie?: { state: string; userId: string } | null;
    consent?: boolean;
    nonces?: string[];
    connect?: () => Promise<ConnectedStatus>;
    saveHandoff?: () => Promise<void>;
  } = {},
) {
  const nonces = new Set(options.nonces ?? []);
  const connected: { userId: string; code: string }[] = [];
  const after: string[] = [];
  const handoffs: { id: string; userId: string; code: string }[] = [];
  let n = 0;
  const deps: OAuthCallbackDeps = {
    provider: "notion",
    stateSecret: () => SECRET,
    now: () => NOW,
    cookieState: async () => options.cookie ?? null,
    authenticate: async () => options.session ?? null,
    hasConsent: async () => options.consent ?? true,
    consumeNonce: async (payload: OAuthStatePayload) => nonces.delete(`${payload.userId}:${payload.nonce}`),
    connect: async (userId, code) => {
      connected.push({ userId, code });
      return options.connect ? options.connect() : "connected";
    },
    onConnected: (userId) => after.push(userId),
    saveHandoff: async (handoff) => {
      await options.saveHandoff?.();
      handoffs.push(handoff);
    },
    newHandoffId: () => `handoff-${++n}`.padEnd(43, "x"),
  };
  return { deps, connected, after, handoffs };
}

const callback = (params: Record<string, string>) => new Request(`${CALLBACK}?${new URLSearchParams(params)}`);

function appState(userId = ALICE) {
  const { state, payload } = newOAuthState({ userId, provider: "notion" }, SECRET, NOW);
  return { state, key: `${userId}:${payload.nonce}` };
}

describe("OAuth callback — 앱 흐름 (서명된 state)", () => {
  it("연결하지 않고 code를 시작한 사용자의 완료 대기로 두고 taskforce://…?handoff=로 돌려보낸다", async () => {
    const { state, key } = appState();
    const { deps, connected, after, handoffs } = setup({ nonces: [key] });
    const response = await handleOAuthCallback(callback({ state, code: "code-1" }), deps);
    expect(response.status).toBe(307);
    const id = "handoff-1".padEnd(43, "x");
    expect(response.headers.get("location")).toBe(`taskforce://connections/notion?handoff=${id}`);
    expect(handoffs).toEqual([{ id, userId: ALICE, code: "code-1" }]);
    // 연결 · 첫 동기화는 앱이 POST /connections/notion/complete로 마칠 때 한다
    expect(connected).toEqual([]);
    expect(after).toEqual([]);
  });

  it("handoff id는 기본으로 32바이트 난수 (base64url 43자)이고 매번 다르다", () => {
    expect(newHandoffId()).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(newHandoffId()).not.toBe(newHandoffId());
  });

  it("재사용: 같은 state로 두 번 들어오면 두 번째는 invalid_state", async () => {
    const { state, key } = appState();
    const { deps, handoffs } = setup({ nonces: [key] });
    await handleOAuthCallback(callback({ state, code: "c" }), deps);
    const again = await handleOAuthCallback(callback({ state, code: "c" }), deps);
    expect(again.headers.get("location")).toBe("taskforce://connections/notion?status=invalid_state");
    expect(handoffs).toHaveLength(1);
  });

  it("다른 사용자: 다른 사용자의 nonce를 가리키면 완료 대기를 만들지 않는다", async () => {
    const { state } = appState(ALICE);
    const { key: bobKey } = appState(BOB);
    const { deps, handoffs } = setup({ nonces: [bobKey] });
    const response = await handleOAuthCallback(callback({ state, code: "c" }), deps);
    expect(response.headers.get("location")).toBe("taskforce://connections/notion?status=invalid_state");
    expect(handoffs).toEqual([]);
  });

  it("변조 · 만료 · 다른 서비스의 state는 invalid_state이고 nonce를 쓰지 않는다", async () => {
    const { state, key } = appState();
    const { deps, handoffs } = setup({ nonces: [key] });
    const tampered = state.replace(/\.([^.]+)$/, (_m, sig: string) => `.${sig.startsWith("A") ? "B" : "A"}${sig.slice(1)}`);
    expect((await handleOAuthCallback(callback({ state: tampered, code: "c" }), deps)).headers.get("location")).toContain("status=invalid_state");

    const late = { ...deps, now: () => new Date(NOW.getTime() + 11 * 60_000) };
    expect((await handleOAuthCallback(callback({ state, code: "c" }), late)).headers.get("location")).toContain("status=invalid_state");

    const google = newOAuthState({ userId: ALICE, provider: "google" }, SECRET, NOW).state;
    expect((await handleOAuthCallback(callback({ state: google, code: "c" }), deps)).headers.get("location")).toContain("status=invalid_state");
    expect(handoffs).toEqual([]);
    // 거부된 시도는 nonce를 쓰지 않았으므로 원래 state로는 아직 이어갈 수 있다
    expect((await handleOAuthCallback(callback({ state, code: "c" }), deps)).headers.get("location")).toContain("handoff=");
  });

  it("사용자가 취소하면 denied, code가 없으면 error (완료 대기를 만들지 않는다)", async () => {
    const first = appState();
    const second = appState();
    const { deps, handoffs } = setup({ nonces: [first.key, second.key] });
    expect((await handleOAuthCallback(callback({ state: first.state, error: "access_denied" }), deps)).headers.get("location")).toBe(
      "taskforce://connections/notion?status=denied",
    );
    expect((await handleOAuthCallback(callback({ state: second.state }), deps)).headers.get("location")).toBe(
      "taskforce://connections/notion?status=error",
    );
    expect(handoffs).toEqual([]);
  });

  it("완료 대기를 저장하지 못하면 error, 로그에는 오류 메시지만 남긴다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { state, key } = appState();
    const { deps } = setup({
      nonces: [key],
      saveHandoff: async () => {
        throw new Error("db down");
      },
    });
    const response = await handleOAuthCallback(callback({ state, code: "secret-code" }), deps);
    expect(response.headers.get("location")).toBe("taskforce://connections/notion?status=error");
    expect(log).toHaveBeenCalledWith("notion 연결: 완료 대기 저장 실패:", "db down");
    expect(JSON.stringify(log.mock.calls)).not.toContain("secret-code");
    log.mockRestore();
  });

  it("서명 state는 /lab으로 돌려보내지 않는다 (예전 return: web 값이 들어 있어도 앱으로)", async () => {
    const { payload } = newOAuthState({ userId: ALICE, provider: "notion" }, SECRET, NOW);
    const legacy = signOAuthState({ ...payload, return: "web" } as OAuthStatePayload, SECRET);
    const { deps } = setup({ nonces: [`${ALICE}:${payload.nonce}`] });
    const response = await handleOAuthCallback(callback({ state: legacy, code: "c" }), deps);
    expect(response.headers.get("location")).toMatch(/^taskforce:\/\/connections\/notion\?handoff=/);
  });
});

describe("OAuth callback — 웹 흐름 (쿠키 state, /lab)", () => {
  const cookieState = "randomCookieState123";

  it("쿠키 state와 로그인한 사용자가 맞으면 연결하고 /lab으로 돌아가며 쿠키를 지운다", async () => {
    const { deps, connected, after } = setup({ session: { id: ALICE }, cookie: { state: cookieState, userId: ALICE } });
    const response = await handleOAuthCallback(callback({ state: cookieState, code: "c" }), deps);
    expect(response.headers.get("location")).toBe("http://localhost:3000/lab?notion=connected");
    expect(response.headers.get("set-cookie")).toMatch(/^notion_oauth_state=; Path=\/api\/connectors\/notion; Max-Age=0/);
    expect(connected).toEqual([{ userId: ALICE, code: "c" }]);
    expect(after).toEqual([ALICE]);
  });

  it("시작한 뒤 외부 AI 처리 동의를 철회했으면 연결하지 않고 consent_required", async () => {
    const { deps, connected, after } = setup({ session: { id: ALICE }, cookie: { state: cookieState, userId: ALICE }, consent: false });
    const response = await handleOAuthCallback(callback({ state: cookieState, code: "c" }), deps);
    expect(response.headers.get("location")).toBe("http://localhost:3000/lab?notion=consent_required");
    expect(connected).toEqual([]);
    expect(after).toEqual([]);
  });

  it("로그인하지 않았으면 /login으로 보낸다", async () => {
    const { deps, connected } = setup({ session: null, cookie: { state: cookieState, userId: ALICE } });
    const response = await handleOAuthCallback(callback({ state: cookieState, code: "c" }), deps);
    expect(response.headers.get("location")).toBe("http://localhost:3000/login");
    expect(connected).toEqual([]);
  });

  it("state가 다르거나, 시작한 사용자와 로그인한 사용자가 다르면 invalid_state", async () => {
    const mismatch = setup({ session: { id: ALICE }, cookie: { state: cookieState, userId: ALICE } });
    expect((await handleOAuthCallback(callback({ state: "otherState", code: "c" }), mismatch.deps)).headers.get("location")).toBe(
      "http://localhost:3000/lab?notion=invalid_state",
    );
    const switched = setup({ session: { id: BOB }, cookie: { state: cookieState, userId: ALICE } });
    expect((await handleOAuthCallback(callback({ state: cookieState, code: "c" }), switched.deps)).headers.get("location")).toBe(
      "http://localhost:3000/lab?notion=invalid_state",
    );
    const noCookie = setup({ session: { id: ALICE }, cookie: null });
    expect((await handleOAuthCallback(callback({ state: "", code: "c" }), noCookie.deps)).headers.get("location")).toBe(
      "http://localhost:3000/lab?notion=invalid_state",
    );
    expect([...mismatch.connected, ...switched.connected, ...noCookie.connected]).toEqual([]);
  });
});
