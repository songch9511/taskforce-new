import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  events: [] as string[],
  afterCallbacks: [] as (() => unknown)[],
  cookieValue: "",
  authenticateRequest: vi.fn(),
  hasAiConsent: vi.fn(),
  cookies: vi.fn(),
  after: vi.fn(),
  afterConnected: vi.fn(),
  webConnector: vi.fn(),
  connect: vi.fn(),
  consumeOAuthNonce: vi.fn(),
  saveOAuthHandoff: vi.fn(),
  oauthStateSecret: vi.fn(),
  createAdminClient: vi.fn(),
}));

vi.mock("next/headers", () => ({ cookies: mocks.cookies }));
vi.mock("next/server", () => ({ after: mocks.after }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.authenticateRequest }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: mocks.hasAiConsent }));
vi.mock("@/lib/connectors/registry", () => ({ afterConnected: mocks.afterConnected, webConnector: mocks.webConnector }));
vi.mock("@/lib/connectors/store", () => ({ consumeOAuthNonce: mocks.consumeOAuthNonce, saveOAuthHandoff: mocks.saveOAuthHandoff }));
vi.mock("@/lib/env", () => ({ oauthStateSecret: mocks.oauthStateSecret }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.createAdminClient }));

import { GET, maxDuration } from "./route";
import { newOAuthState } from "@/lib/connectors/oauth-state";

const ADMIN = { admin: true };
const USER_ID = "00000000-0000-4000-8000-00000000000a";
const SECRET = "s".repeat(64);

describe("Gmail OAuth callback route adapter", () => {
  beforeEach(() => {
    vi.resetAllMocks();
    mocks.events.length = 0;
    mocks.afterCallbacks.length = 0;
    mocks.cookieValue = `web-state.${USER_ID}`;
    mocks.createAdminClient.mockImplementation(() => {
      mocks.events.push("admin");
      return ADMIN;
    });
    mocks.authenticateRequest.mockImplementation(async () => {
      mocks.events.push("authenticate");
      return { user: { id: USER_ID, email: "tester@example.com", name: "Tester" }, supabase: {} };
    });
    mocks.cookies.mockImplementation(async () => ({
      get: (name: string) => {
        mocks.events.push("cookies");
        return name === "gmail_oauth_state" ? { value: mocks.cookieValue } : undefined;
      },
    }));
    mocks.hasAiConsent.mockImplementation(async () => {
      mocks.events.push("consent");
      return true;
    });
    mocks.oauthStateSecret.mockReturnValue(SECRET);
    mocks.connect.mockImplementation(async () => {
      mocks.events.push("connect");
      return "connected";
    });
    mocks.webConnector.mockImplementation(() => {
      mocks.events.push("webConnector");
      return { connect: mocks.connect };
    });
    mocks.after.mockImplementation((callback: () => unknown) => {
      mocks.events.push("after");
      mocks.afterCallbacks.push(callback);
    });
    mocks.afterConnected.mockImplementation(async () => {
      mocks.events.push("afterConnected");
    });
    mocks.consumeOAuthNonce.mockResolvedValue(true);
    mocks.saveOAuthHandoff.mockResolvedValue(undefined);
  });

  it("keeps the web callback order, consent gate, cookie binding, and deferred firstSync:false hook", async () => {
    const response = await GET(new Request("https://app.example.test/api/connectors/gmail/callback?state=web-state&code=auth-code"));

    expect(maxDuration).toBe(60);
    expect(mocks.events).toEqual(["admin", "authenticate", "cookies", "consent", "webConnector", "connect", "after"]);
    expect(mocks.webConnector).toHaveBeenCalledWith("gmail", "tester@example.com");
    expect(mocks.connect).toHaveBeenCalledWith(ADMIN, USER_ID, "auth-code");
    expect(mocks.oauthStateSecret).not.toHaveBeenCalled();
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://app.example.test/lab?gmail=connected");
    expect(response.headers.get("set-cookie")).toContain("Path=/api/connectors/gmail; Max-Age=0");
    expect(mocks.afterConnected).not.toHaveBeenCalled();

    await mocks.afterCallbacks[0]?.();
    expect(mocks.afterConnected).toHaveBeenCalledWith(ADMIN, USER_ID, "gmail", { firstSync: false });
  });

  it("keeps signed app callbacks lazy and stores the Gmail handoff without web authentication", async () => {
    const { state, payload } = newOAuthState({ userId: USER_ID, provider: "gmail" }, SECRET, new Date());
    const response = await GET(new Request(`https://app.example.test/api/connectors/gmail/callback?${new URLSearchParams({ state, code: "auth-code" })}`));

    expect(mocks.events).toEqual(["admin"]);
    expect(mocks.oauthStateSecret).toHaveBeenCalledOnce();
    expect(mocks.authenticateRequest).not.toHaveBeenCalled();
    expect(mocks.cookies).not.toHaveBeenCalled();
    expect(mocks.hasAiConsent).not.toHaveBeenCalled();
    expect(mocks.webConnector).not.toHaveBeenCalled();
    expect(mocks.consumeOAuthNonce).toHaveBeenCalledWith(ADMIN, payload);
    expect(mocks.saveOAuthHandoff).toHaveBeenCalledWith(
      ADMIN,
      expect.objectContaining({ userId: USER_ID, provider: "gmail", code: "auth-code" }),
    );
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toMatch(/^taskforce:\/\/connections\/gmail\?handoff=[A-Za-z0-9_-]{43}$/);
  });
});
