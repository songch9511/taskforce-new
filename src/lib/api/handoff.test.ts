import { AiBudgetError } from "@/lib/ai/budget-error";
import { DeadlineExceededError } from "@/lib/ai/deadline";
import { HandoffGenerationError } from "@/lib/ai/handoff-error";
import { ConsentRequiredError } from "@/lib/consent/gate";
import { afterEach, describe, expect, it, vi } from "vitest";

import { handleHandoff, type HandoffHandlerDeps } from "./handoff";
import { apiErrorSchema, handoffResponseSchema, type HandoffResponse } from "./contract";
import { RateLimitedError } from "./rate-limit";

const legacy: HandoffResponse = { action_id: "11111111-1111-4111-8111-111111111111", title: "Prepare proposal", markdown: "# Prepare proposal\n" };
const assisted: HandoffResponse = {
  ...legacy,
  markdown: "# Draft\n\n## Reference\n\n# Prepare proposal\n",
  assessment: { effort: "medium", difficulty: "high", context: "sufficient", model: "typesafe/jev-1.13", rubric_version: "handoff-v1" },
};
const post = (body?: string) => new Request("https://api.example.dev/api/v1/actions/a1/handoff", { method: "POST", ...(body === undefined ? {} : { body }) });

function setup(handoff: (assisted: boolean) => Promise<HandoffResponse> = async (assistedMode) => (assistedMode ? assisted : legacy)) {
  const execute = vi.fn(handoff);
  const deps: HandoffHandlerDeps = { handoff: execute, now: () => new Date("2026-10-07T00:00:00Z") };
  return { deps, execute };
}

afterEach(() => vi.restoreAllMocks());

describe("POST /api/v1/actions/:id/handoff", () => {
  it("keeps an absent body on the deterministic legacy path and response shape", async () => {
    const { deps, execute } = setup();
    const response = await handleHandoff(post(), deps);
    expect(response.status).toBe(200);
    expect(handoffResponseSchema.parse(await response.json())).toEqual(legacy);
    expect(execute).toHaveBeenCalledWith(false);
  });

  it("accepts only the explicit assisted opt-in", async () => {
    const { deps, execute } = setup();
    const response = await handleHandoff(post('{"mode":"assisted"}'), deps);
    expect(response.status).toBe(200);
    expect(handoffResponseSchema.parse(await response.json())).toEqual(assisted);
    expect(execute).toHaveBeenCalledWith(true);
  });

  it.each(['{}', '{"mode":"legacy"}', '{"mode":"assisted","extra":true}', '{'])("rejects unsupported bodies without invoking the service (%s)", async (body) => {
    const { deps, execute } = setup();
    expect((await handleHandoff(post(body), deps)).status).toBe(400);
    expect(execute).not.toHaveBeenCalled();
  });

  it("maps consent, rate, deadline, and budget failures truthfully", async () => {
    const consent = await handleHandoff(post('{"mode":"assisted"}'), setup(async () => { throw new ConsentRequiredError(); }).deps);
    expect(consent.status).toBe(409);
    expect(apiErrorSchema.parse(await consent.json()).error.code).toBe("conflict");

    const limited = await handleHandoff(post('{"mode":"assisted"}'), setup(async () => { throw new RateLimitedError(new Date("2026-10-07T00:05:00Z")); }).deps);
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("300");

    const timeout = await handleHandoff(post('{"mode":"assisted"}'), setup(async () => { throw new DeadlineExceededError("llm", "timeout"); }).deps);
    expect(timeout.status).toBe(504);
    expect(apiErrorSchema.parse(await timeout.json()).error.code).toBe("ai_timeout");

    const budget = await handleHandoff(post('{"mode":"assisted"}'), setup(async () => { throw new AiBudgetError("ai_budget_exhausted"); }).deps);
    expect(budget.status).toBe(403);
    expect(apiErrorSchema.parse(await budget.json()).error.code).toBe("ai_budget_exhausted");
  });

  it("returns a retryable failure and logs no provider or source text", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await handleHandoff(post('{"mode":"assisted"}'), setup(async () => { throw new HandoffGenerationError("plan"); }).deps);
    expect(response.status).toBe(503);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("ai_unavailable");
    expect(JSON.stringify(log.mock.calls)).not.toContain("provider response");
  });
});
