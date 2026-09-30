import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  authenticateRequest: vi.fn(),
  hasAiConsent: vi.fn(),
  webConnector: vi.fn(),
}));

vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.authenticateRequest }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: mocks.hasAiConsent }));
vi.mock("@/lib/connectors/registry", () => ({ webConnector: mocks.webConnector }));

import { GET } from "./route";

describe("Gmail web OAuth start route", () => {
  afterEach(() => vi.resetAllMocks());

  it("keeps its auth, connector, and consent gates before setting the shared state cookie", async () => {
    mocks.authenticateRequest.mockResolvedValue({ user: { id: "user-1", email: "tester@example.com" } });
    mocks.hasAiConsent.mockResolvedValue(true);
    const authorizeUrl = vi.fn((state: string) => `https://accounts.google.com/auth?state=${state}`);
    mocks.webConnector.mockReturnValue({ authorizeUrl });

    const response = await GET(new Request("https://app.example.test/api/connectors/gmail/start"));
    const state = authorizeUrl.mock.calls[0][0];

    expect(mocks.webConnector).toHaveBeenCalledWith("gmail", "tester@example.com");
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://accounts.google.com/auth?state=${state}`);
    expect(response.cookies.get("gmail_oauth_state")?.value).toBe(`${state}.user-1`);
  });

  it.each([
    {
      name: "missing session",
      authenticated: false,
      connectorAvailable: false,
      expectedLocation: "https://app.example.test/login",
      connectorCalls: 0,
      consentCalls: 0,
    },
    {
      name: "unavailable connector",
      authenticated: true,
      connectorAvailable: false,
      expectedLocation: "https://app.example.test/lab?gmail=unavailable",
      connectorCalls: 1,
      consentCalls: 0,
    },
    {
      name: "missing consent",
      authenticated: true,
      connectorAvailable: true,
      expectedLocation: "https://app.example.test/lab?gmail=consent_required",
      connectorCalls: 1,
      consentCalls: 1,
    },
  ])(
    "preserves the $name gate before OAuth redirect and cookie setup",
    async ({ authenticated, connectorAvailable, expectedLocation, connectorCalls, consentCalls }) => {
      const authorizeUrl = vi.fn((state: string) => `https://accounts.google.com/auth?state=${state}`);
      mocks.authenticateRequest.mockResolvedValue(authenticated ? { user: { id: "user-1", email: "tester@example.com" } } : null);
      mocks.webConnector.mockReturnValue(connectorAvailable ? { authorizeUrl } : null);
      mocks.hasAiConsent.mockResolvedValue(false);
      const response = await GET(new Request("https://app.example.test/api/connectors/gmail/start"));

      expect(response.status).toBe(307);
      expect(response.headers.get("location")).toBe(expectedLocation);
      expect(response.headers.get("set-cookie")).toBeNull();
      expect(mocks.webConnector).toHaveBeenCalledTimes(connectorCalls);
      expect(mocks.hasAiConsent).toHaveBeenCalledTimes(consentCalls);
      expect(authorizeUrl).not.toHaveBeenCalled();
    },
  );
});
