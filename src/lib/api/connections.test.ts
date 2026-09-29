import { describe, expect, it, vi } from "vitest";

import { handleOAuthCallback, type OAuthCallbackDeps } from "@/lib/connectors/callback";
import { newOAuthState, verifyOAuthState, type OAuthStatePayload } from "@/lib/connectors/oauth-state";
import type { ConnectedStatus } from "@/lib/connectors/types";

import {
  handleConnectionComplete,
  handleConnectionDelete,
  handleConnectionRequest,
  handleConnectionStart,
  type ConnectionCompleteDeps,
  type ConnectionDeleteDeps,
  type ConnectionStartDeps,
} from "./connections";
import { handleGiveConsent, handleWithdrawConsent, type ConsentDeps } from "./consent";
import { apiErrorSchema, connectionCompleteResponseSchema, connectionStartResponseSchema } from "./contract";

type User = { id: string };
const ALICE: User = { id: "00000000-0000-4000-8000-00000000000a" };
const BOB: User = { id: "00000000-0000-4000-8000-00000000000b" };
const SECRET = "s".repeat(64);

function startDeps(options: { user?: User | null; consent?: boolean; saveNonce?: () => Promise<void>; retryAt?: Date | null } = {}) {
  const nonces: OAuthStatePayload[] = [];
  const deps: ConnectionStartDeps<User> = {
    authenticate: async () => (options.user === undefined ? ALICE : options.user),
    hasConsent: async () => options.consent ?? true,
    authorizer: (provider) => (provider === "notion" ? (state) => `https://api.notion.com/v1/oauth/authorize?state=${encodeURIComponent(state)}` : null),
    rateLimit: async () => options.retryAt ?? null,
    now: () => new Date("2026-09-27T01:00:00Z"),
    newState: (user, provider) => newOAuthState({ userId: user.id, provider }, SECRET),
    saveNonce: async (payload) => {
      await options.saveNonce?.();
      nonces.push(payload);
    },
  };
  return { deps, nonces };
}

const post = (url: string, body?: unknown) =>
  new Request(url, { method: "POST", body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body) });

const errorOf = async (response: Response) => apiErrorSchema.parse(await response.json()).error;

describe("POST /api/v1/connections/{provider}/start", () => {
  it("본문 없이 부르면 앱으로 돌아오는 서명된 state를 담은 권한 화면 주소를 준다", async () => {
    const { deps, nonces } = startDeps();
    const response = await handleConnectionStart(post("http://localhost/api/v1/connections/notion/start"), "notion", deps);
    expect(response.status).toBe(200);
    const { url } = connectionStartResponseSchema.parse(await response.json());
    const state = new URL(url).searchParams.get("state")!;
    const check = verifyOAuthState(state, SECRET);
    expect(check).toEqual({ ok: true, payload: nonces[0] });
    expect(nonces[0]).toMatchObject({ userId: ALICE.id, provider: "notion" });
  });

  it("예전 앱이 보내던 return 필드는 무시한다 (웹으로 돌아가는 서명 state는 없다)", async () => {
    const { deps, nonces } = startDeps();
    const response = await handleConnectionStart(post("http://localhost/x", { return: "web" }), "notion", deps);
    expect(response.status).toBe(200);
    expect(nonces[0]).not.toHaveProperty("return");
  });

  it("10분에 10번을 넘으면 429와 Retry-After이고 state를 만들지 않는다", async () => {
    const { deps, nonces } = startDeps({ retryAt: new Date("2026-09-27T01:04:00Z") });
    const response = await handleConnectionStart(post("http://localhost/x"), "notion", deps);
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("240");
    expect((await errorOf(response)).code).toBe("rate_limited");
    expect(nonces).toEqual([]);
  });

  it("아직 붙이지 않은 서비스(google · gmail · slack)는 400", async () => {
    for (const provider of ["google", "gmail", "slack"]) {
      const { deps, nonces } = startDeps();
      const response = await handleConnectionStart(post("http://localhost/x"), provider, deps);
      expect(response.status).toBe(400);
      expect(await errorOf(response)).toEqual({ code: "invalid_request", message: "아직 연결할 수 없어요." });
      expect(nonces).toEqual([]);
    }
  });

  it("모르는 서비스는 404", async () => {
    const response = await handleConnectionStart(post("http://localhost/x"), "zoom", startDeps().deps);
    expect(response.status).toBe(404);
    expect((await errorOf(response)).code).toBe("not_found");
  });

  it("외부 AI 처리 동의 전이면 409 conflict이고 state를 만들지 않는다", async () => {
    const { deps, nonces } = startDeps({ consent: false });
    const response = await handleConnectionStart(post("http://localhost/x"), "notion", deps);
    expect(response.status).toBe(409);
    expect(await errorOf(response)).toEqual({ code: "conflict", message: "외부 AI 처리 동의가 필요해요." });
    expect(nonces).toEqual([]);
  });

  it("로그인하지 않았으면 401", async () => {
    expect((await handleConnectionStart(post("http://localhost/x"), "notion", startDeps({ user: null }).deps)).status).toBe(401);
  });

  it("nonce를 저장하지 못하면 500, 로그에 state를 남기지 않는다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { deps } = startDeps({
      saveNonce: async () => {
        throw new Error("db down");
      },
    });
    const response = await handleConnectionStart(post("http://localhost/x"), "notion", deps);
    expect(response.status).toBe(500);
    expect(log).toHaveBeenCalledWith("notion 연결 시작 실패:", "db down");
    log.mockRestore();
  });
});

// 서버의 handoff 저장소를 흉내 낸다: consumeOAuthHandoff처럼 id · 사용자 · 서비스 · 만료가 모두 맞아야 지우며 꺼낸다 (한 번만).
function handoffStore(now: () => Date) {
  const rows = new Map<string, { userId: string; provider: string; code: string; expiresAt: number }>();
  return {
    rows,
    save: (h: { id: string; userId: string; provider: string; code: string }) =>
      rows.set(h.id, { userId: h.userId, provider: h.provider, code: h.code, expiresAt: now().getTime() + 2 * 60_000 }),
    consume: (userId: string, provider: string, id: string) => {
      const row = rows.get(id);
      if (!row || row.userId !== userId || row.provider !== provider || row.expiresAt <= now().getTime()) return null;
      rows.delete(id);
      return row.code;
    },
  };
}

function completeDeps(options: { user?: User | null; consent?: boolean; connect?: () => Promise<ConnectedStatus> } = {}) {
  let clock = new Date("2026-09-27T01:00:00Z");
  const store = handoffStore(() => clock);
  const connected: { userId: string; code: string }[] = [];
  const after: string[] = [];
  let user: User | null = options.user === undefined ? ALICE : options.user;
  const deps: ConnectionCompleteDeps<User> = {
    authenticate: async () => user,
    hasConsent: async () => options.consent ?? true,
    implemented: (provider) => provider === "notion",
    consumeHandoff: async (u, provider, handoff) => store.consume(u.id, provider, handoff),
    connect: async (u, _provider, code) => {
      connected.push({ userId: u.id, code });
      return options.connect ? options.connect() : "connected";
    },
    onConnected: (u) => after.push(u.id),
  };
  return {
    deps,
    store,
    connected,
    after,
    signIn: (next: User | null) => (user = next),
    advance: (ms: number) => (clock = new Date(clock.getTime() + ms)),
  };
}

const HANDOFF = "h".repeat(43);
const complete = (handoff: unknown = HANDOFF) => post("http://localhost/api/v1/connections/notion/complete", { handoff });

describe("POST /api/v1/connections/{provider}/complete", () => {
  it("시작한 사용자가 handoff를 내밀면 code를 토큰으로 바꿔 연결하고 상태를 돌려준 뒤 첫 동기화를 맡긴다", async () => {
    const { deps, store, connected, after } = completeDeps({ connect: async () => "connected_no_meetings" });
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "notion", code: "code-1" });
    const response = await handleConnectionComplete(complete(), "notion", deps);
    expect(response.status).toBe(200);
    expect(connectionCompleteResponseSchema.parse(await response.json())).toEqual({ status: "connected_no_meetings" });
    expect(connected).toEqual([{ userId: ALICE.id, code: "code-1" }]);
    expect(after).toEqual([ALICE.id]);
  });

  it("필요한 권한이 빠져 연결하지 않았으면(missing_scope) 200 {status: missing_scope}이고 첫 동기화를 맡기지 않는다", async () => {
    const { deps, store, connected, after } = completeDeps({ connect: async () => "missing_scope" });
    const gmail = { ...deps, implemented: (provider: string) => provider === "gmail" };
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "gmail", code: "code-1" });
    const response = await handleConnectionComplete(post("http://localhost/api/v1/connections/gmail/complete", { handoff: HANDOFF }), "gmail", gmail);
    expect(response.status).toBe(200);
    expect(connectionCompleteResponseSchema.parse(await response.json())).toEqual({ status: "missing_scope" });
    expect(connected).toEqual([{ userId: ALICE.id, code: "code-1" }]);
    expect(after).toEqual([]);
    // handoff는 썼다: 다시 연결하려면 권한 화면부터
    expect(store.rows.has(HANDOFF)).toBe(false);
  });

  it("일부 권한만 허용해 연결했으면(connected_partial) 200 {status: connected_partial}이고 첫 동기화를 맡긴다 (google, G10)", async () => {
    const { deps, store, connected, after } = completeDeps({ connect: async () => "connected_partial" });
    const google = { ...deps, implemented: (provider: string) => provider === "google" };
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "google", code: "code-1" });
    const response = await handleConnectionComplete(post("http://localhost/api/v1/connections/google/complete", { handoff: HANDOFF }), "google", google);
    expect(response.status).toBe(200);
    expect(connectionCompleteResponseSchema.parse(await response.json())).toEqual({ status: "connected_partial" });
    expect(connected).toEqual([{ userId: ALICE.id, code: "code-1" }]);
    expect(after).toEqual([ALICE.id]);
  });

  it("공격자가 시작한 연결의 handoff를 다른 사용자가 완료하면 404이고 연결이 생기지 않는다", async () => {
    const { deps, store, connected, after } = completeDeps();
    store.save({ id: HANDOFF, userId: BOB.id, provider: "notion", code: "victim-code" });
    const response = await handleConnectionComplete(complete(), "notion", deps);
    expect(response.status).toBe(404);
    expect(await errorOf(response)).toEqual({ code: "not_found", message: "연결 요청이 없거나 만료됐어요. 다시 연결해 주세요." });
    expect(connected).toEqual([]);
    expect(after).toEqual([]);
    // 남의 handoff를 건드리지도 않는다
    expect(store.rows.has(HANDOFF)).toBe(true);
  });

  it("한 번만 쓴다: 두 번째 완료는 404", async () => {
    const { deps, store, connected } = completeDeps();
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "notion", code: "c" });
    expect((await handleConnectionComplete(complete(), "notion", deps)).status).toBe(200);
    expect((await handleConnectionComplete(complete(), "notion", deps)).status).toBe(404);
    expect(connected).toHaveLength(1);
  });

  it("만료(2분)되면 404", async () => {
    const { deps, store, connected, advance } = completeDeps();
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "notion", code: "c" });
    advance(2 * 60_000);
    expect((await handleConnectionComplete(complete(), "notion", deps)).status).toBe(404);
    expect(connected).toEqual([]);
  });

  it("다른 서비스 경로로 내밀면 404", async () => {
    const { deps, store } = completeDeps();
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "google", code: "c" });
    const google = { ...deps, implemented: () => true };
    expect((await handleConnectionComplete(complete(), "notion", google)).status).toBe(404);
  });

  it("외부 AI 처리 동의 전이면 409이고 handoff를 쓰지 않는다 (동의 후 다시 부르면 된다)", async () => {
    const { deps, store, connected } = completeDeps({ consent: false });
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "notion", code: "c" });
    const response = await handleConnectionComplete(complete(), "notion", deps);
    expect(response.status).toBe(409);
    expect(await errorOf(response)).toEqual({ code: "conflict", message: "외부 AI 처리 동의가 필요해요." });
    expect(store.rows.has(HANDOFF)).toBe(true);
    expect(connected).toEqual([]);
  });

  it("토큰 교환이 실패하면 502, 로그에는 오류 메시지만 남긴다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { deps, store, after } = completeDeps({
      connect: async () => {
        throw new Error("Notion 토큰 요청 실패 (400)");
      },
    });
    store.save({ id: HANDOFF, userId: ALICE.id, provider: "notion", code: "secret-code" });
    const response = await handleConnectionComplete(complete(), "notion", deps);
    expect(response.status).toBe(502);
    expect((await errorOf(response)).code).toBe("internal_error");
    expect(after).toEqual([]);
    expect(log).toHaveBeenCalledWith("notion 연결 실패:", "Notion 토큰 요청 실패 (400)");
    expect(JSON.stringify(log.mock.calls)).not.toContain("secret-code");
    log.mockRestore();
  });

  it("로그인 · 본문 · 서비스 확인: 401 · 400 · 404 · 아직 붙이지 않은 서비스 400", async () => {
    expect((await handleConnectionComplete(complete(), "notion", completeDeps({ user: null }).deps)).status).toBe(401);
    expect((await handleConnectionComplete(complete("short"), "notion", completeDeps().deps)).status).toBe(400);
    expect((await handleConnectionComplete(post("http://localhost/x", {}), "notion", completeDeps().deps)).status).toBe(400);
    expect((await handleConnectionComplete(complete(), "zoom", completeDeps().deps)).status).toBe(404);
    expect((await handleConnectionComplete(complete(), "slack", completeDeps().deps)).status).toBe(400);
  });

  it("시작부터 끝까지: 공격자가 만든 권한 주소를 피해자가 눌러도 피해자의 워크스페이스가 공격자 계정에 붙지 않는다", async () => {
    // 1) 공격자(BOB)가 연결을 시작해 자기 사용자로 서명된 state가 든 권한 주소를 받는다.
    const { deps: start, nonces } = startDeps({ user: BOB });
    const { url } = connectionStartResponseSchema.parse(await (await handleConnectionStart(post("http://localhost/x"), "notion", start)).json());
    const state = new URL(url).searchParams.get("state")!;

    // 2) 피해자(ALICE)가 그 주소를 눌러 자기 Notion으로 허용한다. callback은 연결하지 않고 BOB의 완료 대기만 만든다.
    const { deps: finish, store, connected, signIn } = completeDeps();
    const callbackDeps: OAuthCallbackDeps = {
      provider: "notion",
      stateSecret: () => SECRET,
      cookieState: async () => null,
      authenticate: async () => null,
      hasConsent: async () => true,
      connect: async () => {
        throw new Error("앱 흐름에서는 callback이 연결하지 않는다");
      },
      onConnected: () => {},
      consumeNonce: async (payload) => nonces.some((n) => n.nonce === payload.nonce && n.userId === payload.userId),
      saveHandoff: async ({ id, userId, code }) => void store.save({ id, userId, provider: "notion", code }),
    };
    const redirect = await handleOAuthCallback(new Request(`http://localhost/api/connectors/notion/callback?state=${encodeURIComponent(state)}&code=victim-code`), callbackDeps);
    const handoff = new URL(redirect.headers.get("location")!.replace("taskforce://", "https://app.invalid/")).searchParams.get("handoff")!;
    expect(handoff).toMatch(/^[A-Za-z0-9_-]{43}$/);

    // 3) handoff는 피해자 기기의 앱으로 간다. 피해자 앱(ALICE로 로그인)이 완료를 부르면 404 — 피해자 계정에도 붙지 않는다.
    signIn(ALICE);
    expect((await handleConnectionComplete(complete(handoff), "notion", finish)).status).toBe(404);
    expect(connected).toEqual([]);
    // 공격자는 handoff 값을 받지 못한다 (피해자 기기의 taskforce:// 주소로만 간다). 2분이 지나면 cron이 치운다.
  });
});

describe("POST /api/v1/connection-requests", () => {
  function requestDeps(user: User | null = ALICE) {
    const saved: string[] = [];
    return {
      saved,
      deps: {
        authenticate: async () => user,
        save: async (_user: User, provider: string) => {
          if (!saved.includes(provider)) saved.push(provider);
        },
      },
    };
  }

  it("2단계 서비스 요청을 남기고 204, 다시 보내도 그대로 204", async () => {
    const { deps, saved } = requestDeps();
    expect((await handleConnectionRequest(post("http://localhost/x", { provider: "zoom" }), deps)).status).toBe(204);
    expect((await handleConnectionRequest(post("http://localhost/x", { provider: "zoom" }), deps)).status).toBe(204);
    expect(saved).toEqual(["zoom"]);
  });

  it("2단계 서비스가 아니면 400, 로그인하지 않았으면 401", async () => {
    expect((await handleConnectionRequest(post("http://localhost/x", { provider: "notion" }), requestDeps().deps)).status).toBe(400);
    expect((await handleConnectionRequest(post("http://localhost/x", {}), requestDeps().deps)).status).toBe(400);
    expect((await handleConnectionRequest(post("http://localhost/x", { provider: "zoom" }), requestDeps(null).deps)).status).toBe(401);
  });
});

describe("POST · DELETE /api/v1/consent", () => {
  function consentDeps(user: User | null = ALICE) {
    const saved: (string | null)[] = [];
    const deps: ConsentDeps<User> = {
      authenticate: async () => user,
      save: async (_user, at) => {
        saved.push(at?.toISOString() ?? null);
      },
      now: () => new Date("2026-09-27T01:00:00Z"),
    };
    return { deps, saved };
  }

  it("동의하면 지금 시각을 적고 204", async () => {
    const { deps, saved } = consentDeps();
    const response = await handleGiveConsent(post("http://localhost/api/v1/consent", { ai_processing: true }), deps);
    expect(response.status).toBe(204);
    expect(saved).toEqual(["2026-09-27T01:00:00.000Z"]);
  });

  it("ai_processing: true가 아니면 400이고 아무것도 적지 않는다", async () => {
    const { deps, saved } = consentDeps();
    for (const body of [{ ai_processing: false }, {}, "not json"]) {
      expect((await handleGiveConsent(post("http://localhost/api/v1/consent", body), deps)).status).toBe(400);
    }
    expect(saved).toEqual([]);
  });

  it("철회하면 null을 적고 204", async () => {
    const { deps, saved } = consentDeps();
    const response = await handleWithdrawConsent(new Request("http://localhost/api/v1/consent", { method: "DELETE" }), deps);
    expect(response.status).toBe(204);
    expect(saved).toEqual([null]);
  });

  it("로그인하지 않았으면 401", async () => {
    const { deps, saved } = consentDeps(null);
    expect((await handleGiveConsent(post("http://localhost/api/v1/consent", { ai_processing: true }), deps)).status).toBe(401);
    expect((await handleWithdrawConsent(new Request("http://localhost/api/v1/consent", { method: "DELETE" }), deps)).status).toBe(401);
    expect(saved).toEqual([]);
  });
});

describe("DELETE /api/v1/connections/:id", () => {
  const ID = "00000000-0000-4000-8000-0000000000c1";
  const del = () => new Request(`http://localhost/api/v1/connections/${ID}`, { method: "DELETE" });

  function deleteDeps(options: { user?: User | null; connection?: { provider: "slack" | "notion"; token: unknown } | null; revokeFails?: boolean } = {}) {
    const log: string[] = [];
    const deps: ConnectionDeleteDeps<User> = {
      authenticate: async () => (options.user === undefined ? ALICE : options.user),
      load: async (user, id) => (user.id === ALICE.id && id === ID ? (options.connection === undefined ? { provider: "slack", token: { access_token: "xoxp-1" } } : options.connection) : null),
      revoker: (provider) =>
        provider === "slack" || provider === "notion"
          ? async () => {
              log.push(`revoke:${provider}`);
              if (options.revokeFails) throw new Error("slack down");
            }
          : null,
      disconnect: async (user, id) => {
        log.push(`disconnect:${id}`);
        return user.id === ALICE.id;
      },
    };
    return { deps, log };
  }

  it("서비스 쪽 토큰을 폐기한 뒤 (Slack이면 글자를 지우고) 연결을 지운다", async () => {
    const { deps, log } = deleteDeps();
    expect((await handleConnectionDelete(del(), ID, deps)).status).toBe(204);
    expect(log).toEqual(["revoke:slack", `disconnect:${ID}`]);
  });

  it("토큰 폐기가 실패해도 끊기는 계속한다. 풀지 못한 토큰은 폐기하지 않는다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const failing = deleteDeps({ revokeFails: true });
    expect((await handleConnectionDelete(del(), ID, failing.deps)).status).toBe(204);
    expect(failing.log).toEqual(["revoke:slack", `disconnect:${ID}`]);
    const noToken = deleteDeps({ connection: { provider: "notion", token: null } });
    expect((await handleConnectionDelete(del(), ID, noToken.deps)).status).toBe(204);
    expect(noToken.log).toEqual([`disconnect:${ID}`]);
    error.mockRestore();
  });

  it("로그인 없이 401, 남의 연결 · 없는 연결 · id가 uuid가 아니면 404 (토큰도 건드리지 않는다)", async () => {
    expect((await handleConnectionDelete(del(), ID, deleteDeps({ user: null }).deps)).status).toBe(401);
    const other = deleteDeps({ user: BOB });
    const response = await handleConnectionDelete(del(), ID, other.deps);
    expect(response.status).toBe(404);
    expect((await errorOf(response)).code).toBe("not_found");
    expect(other.log).toEqual([]);
    expect((await handleConnectionDelete(del(), "not-a-uuid", deleteDeps().deps)).status).toBe(404);
  });
});
