import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { aiSpendSummarySchema } from "@/lib/api/contract";
import { accountRow, fakeAdmin, stubBillingEnv } from "@/lib/billing/testing";
vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ auth: vi.fn(), rpc: vi.fn(), client: vi.fn() }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: () => mocks.client() }));
import { GET } from "./route";
const summary = { cap_usd: 10, confirmed_usd: 2, reserved_usd: 3, pending_count: 4, remaining_usd: 5, status: "available" };
beforeEach(() => { vi.clearAllMocks(); mocks.auth.mockResolvedValue({ user: { id: "alice" } }); mocks.rpc.mockResolvedValue({ data: summary, error: null }); mocks.client.mockImplementation(() => ({ rpc: mocks.rpc })); });
afterEach(() => vi.unstubAllEnvs());
it("auth scopes aggregate reads, ignores supplied account and strips detail", async () => {
  mocks.rpc.mockResolvedValue({ data: { ...summary, generation_id: "private" }, error: null });
  const response = await GET(new Request("https://test/api/v1/ai-budget?user_id=bob"));
  expect(mocks.rpc).toHaveBeenCalledWith("ai_spend_summary", { p_user_id: "alice" });
  expect(await response.json()).toEqual(summary);
  expect(response.headers.get("Cache-Control")).toBe("no-store");
});
it("requires authentication", async () => {
  mocks.auth.mockResolvedValue(null);
  expect((await GET(new Request("https://test"))).status).toBe(401);
  expect(mocks.rpc).not.toHaveBeenCalled();
});
it.each([{ data: null, error: { message: "private database detail" } }, { data: { ...summary, confirmed_usd: null }, error: null }])("does not invent a zero summary on database/malformed results", async (result) => {
  mocks.rpc.mockResolvedValue(result);
  const response = await GET(new Request("https://test"));
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ error: { code: "ai_budget_unavailable", message: "Could not load your AI allowance." } });
});

// With billing on, the current Release Mac (old window) keeps reading this endpoint. It must keep its v1 shape (cap 10, remaining <= 10)
// and must not 503 for any state that can still use AI, while the operator's hidden cap never leaves the server.
describe("billing on: the old Mac keeps a valid v1 summary", () => {
  const DAY = 86_400_000;
  const iso = (offset: number) => new Date(Date.now() + offset).toISOString();
  const ACCOUNTS: Record<string, Record<string, unknown>> = {
    trial: { subscription_id: "s", status: "on_trial", trial_ends_at: iso(DAY), first_subscription_at: iso(-DAY) },
    pro: { subscription_id: "s", status: "active", current_period_ends_at: iso(20 * DAY), last_payment_at: iso(-DAY) },
    cancelled: { subscription_id: "s", status: "cancelled", current_period_ends_at: iso(5 * DAY), last_payment_at: iso(-DAY) },
    past_due: { subscription_id: "s", status: "past_due", current_period_ends_at: iso(-3 * DAY), last_payment_at: iso(-33 * DAY) },
  };
  const v2 = (cap: number, extra: Record<string, unknown> = {}) => ({ cap_usd: cap, confirmed_usd: cap * 0.4, reserved_usd: cap * 0.1, pending_count: 2, remaining_usd: cap * 0.5, status: "available", ...extra });
  function world(account: Record<string, unknown>, rpcs: Parameters<typeof fakeAdmin>[1] = {}) {
    stubBillingEnv();
    const f = fakeAdmin({ billing_accounts: [accountRow({ user_id: "alice", ...account })] }, rpcs);
    mocks.client.mockImplementation(() => f.admin);
    return f;
  }

  it.each(Object.keys(ACCOUNTS))("%s reads the new window summary, never the old one, and answers 200", async (name) => {
    const f = world(ACCOUNTS[name], { billing_spend_summary_v2: () => ({ data: v2(10) }) });
    const response = await GET(new Request("https://test"));
    expect(response.status).toBe(200);
    expect(aiSpendSummarySchema.parse(await response.json())).toEqual({ cap_usd: 10, confirmed_usd: 4, reserved_usd: 1, pending_count: 2, remaining_usd: 5, status: "available" });
    expect(f.rpcNamed("billing_spend_summary_v2")).toEqual([{ p_user_id: "alice", p_monthly_cap: 25, p_trial_cap: 4 }]);
    expect(f.rpcNamed("billing_spend_summary")).toEqual([]);
    expect(response.headers.get("Cache-Control")).toBe("no-store");
  });
  it.each([[25, 5], [100, 0.5], [3, 10 / 3]])("a hidden monthly cap of %s is shown on the legacy 10-unit scale: shape valid, the real cap never appears", async (cap) => {
    const f = world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(cap) }) });
    vi.stubEnv("BILLING_MONTHLY_AI_BUDGET_USD", String(cap));
    const response = await GET(new Request("https://test"));
    expect(response.status).toBe(200);
    const body = aiSpendSummarySchema.parse(await response.json());
    expect(body).toEqual({ cap_usd: 10, confirmed_usd: 4, reserved_usd: 1, pending_count: 2, remaining_usd: 5, status: "available" });
    expect(JSON.stringify(body)).not.toContain(String(cap === 10 ? 11 : cap));
    expect(f.rpcNamed("billing_spend_summary_v2")[0]).toMatchObject({ p_monthly_cap: cap });
  });
  it("shows whole units only: usage rounds up, what is left rounds down, so no fraction can be used to work back to the hidden cap", async () => {
    world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(7, { confirmed_usd: 0.3, reserved_usd: 0.01, remaining_usd: 6.69 }) }) });
    const body = aiSpendSummarySchema.parse(await (await GET(new Request("https://test"))).json());
    expect(body).toEqual({ cap_usd: 10, confirmed_usd: 1, reserved_usd: 1, pending_count: 2, remaining_usd: 9, status: "available" });
  });
  it.each([[3, 0.123456], [25, 17.77], [100, 0.01], [40, 39.999], [12, 0]])("a hidden cap of %s with %s spent never produces a fraction", async (cap, spent) => {
    world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(cap, { confirmed_usd: spent, reserved_usd: 0, remaining_usd: cap - spent }) }) });
    const body = aiSpendSummarySchema.parse(await (await GET(new Request("https://test"))).json());
    for (const value of [body.cap_usd, body.confirmed_usd, body.reserved_usd, body.remaining_usd]) {
      expect(Number.isInteger(value)).toBe(true);
      expect(value).toBeGreaterThanOrEqual(0);
      expect(value).toBeLessThanOrEqual(10);
    }
  });
  it.each(["exhausted", "provider_bound_violation"])("passes the %s status through so the old screen stops offering AI", async (status) => {
    world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(40, { status, remaining_usd: 0, confirmed_usd: 40, reserved_usd: 0 }) }) });
    const body = await (await GET(new Request("https://test"))).json();
    expect(body).toMatchObject({ cap_usd: 10, remaining_usd: 0, confirmed_usd: 10, status });
  });
  it("values never leave the legacy range even when a provider cost went over its reservation", async () => {
    world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(10, { confirmed_usd: 14, remaining_usd: 0, status: "provider_bound_violation" }) }) });
    const response = await GET(new Request("https://test"));
    expect(response.status).toBe(200);
    expect(aiSpendSummarySchema.parse(await response.json()).confirmed_usd).toBeLessThanOrEqual(10);
  });
  it("the grandfathered beta keeps its own legacy summary, unscaled", async () => {
    const f = world({ legacy_beta: true }, { ai_spend_summary: () => ({ data: summary }) });
    const response = await GET(new Request("https://test"));
    expect(await response.json()).toEqual(summary);
    expect(f.rpcNamed("ai_spend_summary")).toEqual([{ p_user_id: "alice" }]);
    expect(f.rpcNamed("billing_spend_summary_v2")).toEqual([]);
  });
  it("Lifetime has no managed spend: a valid, untouched summary, and no database summary call", async () => {
    const f = world({ lifetime_status: "active", lifetime_order_id: "o" });
    const response = await GET(new Request("https://test"));
    expect(response.status).toBe(200);
    expect(aiSpendSummarySchema.parse(await response.json())).toEqual({ cap_usd: 10, confirmed_usd: 0, reserved_usd: 0, pending_count: 0, remaining_usd: 10, status: "available" });
    expect(f.rpcCalls).toEqual([]);
  });
  it.each([
    ["a new account", {}],
    ["an ended plan", { subscription_id: "s", status: "expired" }],
    ["a lapsed period", { subscription_id: "s", status: "active", current_period_ends_at: iso(-1000) }],
    ["a deleting account", { deleting: true, subscription_id: "s", status: "active", current_period_ends_at: iso(DAY) }],
  ])("%s is told the plan has ended (403 billing_required), not that the service is down", async (_label, account) => {
    const f = world(account);
    const response = await GET(new Request("https://test"));
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: { code: "billing_required", message: "Your plan has ended. Restart Pro in Settings → Account → Plan & usage." } });
    expect(f.rpcCalls).toEqual([]);
  });
  it.each([
    ["a database failure", () => ({ error: { message: "private database detail" } })],
    ["a malformed summary", () => ({ data: v2(10, { confirmed_usd: null }) })],
    ["a zero cap", () => ({ data: v2(10, { cap_usd: 0 }) })],
  ])("%s is still a plain 503 without detail", async (_label, reply) => {
    world(ACCOUNTS.pro, { billing_spend_summary_v2: reply });
    const response = await GET(new Request("https://test"));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: { code: "ai_budget_unavailable", message: "Could not load your AI allowance." } });
  });
  it("a bad operator cap env is a 503, never a made-up summary", async () => {
    world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(10) }) });
    vi.stubEnv("BILLING_MONTHLY_AI_BUDGET_USD", "500");
    expect((await GET(new Request("https://test"))).status).toBe(503);
  });
  it("an unset operator cap is a 503 too: the code has no default to fall back on", async () => {
    world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(10) }) });
    vi.stubEnv("BILLING_MONTHLY_AI_BUDGET_USD", "");
    expect((await GET(new Request("https://test"))).status).toBe(503);
  });
  it("acts for the authenticated user only", async () => {
    const f = world(ACCOUNTS.pro, { billing_spend_summary_v2: () => ({ data: v2(10) }) });
    await GET(new Request("https://test/api/v1/ai-budget?user_id=bob"));
    expect(f.rpcNamed("billing_spend_summary_v2")[0]).toMatchObject({ p_user_id: "alice" });
    expect(f.tables.get("billing_accounts")).toHaveLength(1);
  });
});
