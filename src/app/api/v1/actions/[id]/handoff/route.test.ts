import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { INTERACTIVE_MAX_DURATION_S, RESPONSE_MARGIN_MS } from "@/lib/ai/deadline";
import { generateAssistedHandoffFromEnv } from "@/lib/ai/handoff";
import { handoffAction } from "@/lib/actions/service";
import { authenticateRequest } from "@/lib/api/auth";
import { askRateLimit } from "@/lib/api/ask-store";
import { hasAiConsent } from "@/lib/api/profile-store";
import { maxDuration, POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({ admin: true })) }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn(async () => ({ user: { id: "u1" }, supabase: { user: true } })) }));
vi.mock("@/lib/api/profile-store", () => ({ hasAiConsent: vi.fn(async () => true) }));
vi.mock("@/lib/api/ask-store", () => ({ askRateLimit: vi.fn(async () => null) }));
vi.mock("@/lib/ai/handoff", () => ({ generateAssistedHandoffFromEnv: vi.fn(async (markdown: string) => ({
  markdown: `# Draft\n\n## Reference\n\n${markdown}`,
  assessment: { effort: "low", difficulty: "medium", context: "sufficient", model: "typesafe/jev-1.13", rubric_version: "handoff-v1" },
})) }));
vi.mock("@/lib/actions/service", () => ({
  handoffAction: vi.fn(async (
    _client: unknown,
    _admin: unknown,
    _userId: string,
    _id: string,
    assist?: (markdown: string) => Promise<{ markdown: string; assessment: { effort: "low"; difficulty: "medium"; context: "sufficient"; model: string; rubric_version: "handoff-v1" } }>,
  ) => {
    const legacy = { action_id: "11111111-1111-4111-8111-111111111111", title: "Proposal", markdown: "# Proposal\n" };
    if (!assist) return legacy;
    return { ...legacy, ...(await assist(legacy.markdown)) };
  }),
}));

const ACTION_ID = "11111111-1111-4111-8111-111111111111";
const post = (body?: string) => new Request(`https://api.example.dev/api/v1/actions/${ACTION_ID}/handoff`, { method: "POST", ...(body === undefined ? {} : { body }) });
const route = (request: Request, id = ACTION_ID) => POST(request, { params: Promise.resolve({ id }) });

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.restoreAllMocks());

describe("POST /api/v1/actions/:id/handoff route", () => {
  it("uses the same 60-second interactive request bound", () => {
    expect(maxDuration).toBe(INTERACTIVE_MAX_DURATION_S);
  });

  it("requires authentication and rejects an invalid Action ID before service work", async () => {
    vi.mocked(authenticateRequest).mockResolvedValueOnce(null);
    expect((await route(post())).status).toBe(401);
    expect(handoffAction).not.toHaveBeenCalled();

    expect((await route(post(), "not-a-uuid")).status).toBe(404);
    expect(handoffAction).not.toHaveBeenCalled();
  });

  it("keeps legacy requests deterministic without consent, rate-limit, or AI work", async () => {
    const response = await route(post());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ action_id: ACTION_ID, title: "Proposal", markdown: "# Proposal\n" });
    expect(handoffAction).toHaveBeenCalledWith({ user: true }, { admin: true }, "u1", ACTION_ID, undefined);
    expect(hasAiConsent).not.toHaveBeenCalled();
    expect(askRateLimit).not.toHaveBeenCalled();
    expect(generateAssistedHandoffFromEnv).not.toHaveBeenCalled();
  });

  it("checks consent then the shared AI limit and passes the shared deadline to assisted generation", async () => {
    vi.spyOn(Date, "now").mockReturnValue(1_000_000);
    const response = await route(post('{"mode":"assisted"}'));
    expect(response.status).toBe(200);
    expect(hasAiConsent).toHaveBeenCalledTimes(1);
    expect(askRateLimit).toHaveBeenCalledWith({ admin: true }, "u1");
    expect(generateAssistedHandoffFromEnv).toHaveBeenCalledWith("# Proposal\n", { admin: true }, "u1", 1_000_000 + INTERACTIVE_MAX_DURATION_S * 1000 - RESPONSE_MARGIN_MS);
    expect((await response.json()).assessment.rubric_version).toBe("handoff-v1");
  });

  it("stops assisted mode before the shared limiter if consent is absent", async () => {
    vi.mocked(hasAiConsent).mockResolvedValueOnce(false);
    const response = await route(post('{"mode":"assisted"}'));
    expect(response.status).toBe(409);
    expect(askRateLimit).not.toHaveBeenCalled();
    expect(generateAssistedHandoffFromEnv).not.toHaveBeenCalled();
  });

  it("applies the shared interactive limit before any model call", async () => {
    vi.mocked(askRateLimit).mockResolvedValueOnce(new Date(Date.now() + 90_000));
    const response = await route(post('{"mode":"assisted"}'));
    expect(response.status).toBe(429);
    expect(generateAssistedHandoffFromEnv).not.toHaveBeenCalled();
  });

  it("does not invoke service on unknown body modes", async () => {
    const response = await route(post('{"mode":"legacy"}'));
    expect(response.status).toBe(400);
    expect(handoffAction).not.toHaveBeenCalled();
  });

  it("returns 404 for an Action hidden by RLS without checking consent, rate, or calling AI", async () => {
    vi.mocked(handoffAction).mockRejectedValueOnce(Object.assign(new Error("hidden"), { name: "ActionNotFoundError" }));
    const response = await route(post('{"mode":"assisted"}'));
    expect(response.status).toBe(404);
    expect(hasAiConsent).not.toHaveBeenCalled();
    expect(askRateLimit).not.toHaveBeenCalled();
    expect(generateAssistedHandoffFromEnv).not.toHaveBeenCalled();
  });
});
