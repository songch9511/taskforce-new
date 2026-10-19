import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { completeJson } from "./llm";
import { budgetFetch } from "./budget";
import { accountRow, fakeAdmin, stubBillingEnv } from "@/lib/billing/testing";
vi.mock("server-only", () => ({}));
const chat = "https://openrouter.ai/api/v1/chat/completions";
const request = { method: "POST", body: JSON.stringify({ model: "m", max_tokens: 100, messages: [{ role: "user", content: "hi" }], provider: { only: ["p"], order: ["p"], zdr: true, data_collection: "deny", allow_fallbacks: false } }) };
const endpointReply = () => new Response(JSON.stringify({ data: { endpoints: [{ tag: "p", context_length: 1000, pricing: { prompt: "0", completion: "0", discount: 0 } }] } }));
function fixture(body: unknown = { id: "gen-1", usage: { cost: 0.01 } }) {
  const rpc = vi.fn<(name: string, args: unknown) => Promise<{ error: { message: string } | null }>>(async () => ({ error: null }));
  const admin = { rpc } as unknown as SupabaseClient;
  const send = vi.fn(async (url: string | URL | Request) => String(url).endsWith("/endpoints") ? endpointReply() : new Response(JSON.stringify(String(url).endsWith("/models") ? { data: [{ id: "m", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002" } }] } : body)));
  return { rpc, send, fetch: budgetFetch(admin, "alice", send as typeof fetch) };
}
describe("USD transport admission", () => {
  it("reserves before sending, bounds price/tokens, preserves privacy and settles confirmed cost", async () => {
    const f = fixture();
    await f.fetch(chat, request);
    expect(f.rpc.mock.calls[0]).toEqual(["reserve_ai_spend", expect.objectContaining({ p_user_id: "alice", p_reserved_usd: 0.600001 })]);
    expect(f.rpc.mock.calls[1]).toEqual(["settle_ai_spend", expect.objectContaining({ p_user_id: "alice", p_cost_usd: 0.01, p_generation_id: "gen-1" })]);
    const body = JSON.parse((f.send.mock.calls[2] as unknown as [string, RequestInit])[1].body as string);
    expect(body.provider).toMatchObject({ zdr: true, data_collection: "deny", only: ["p"], max_price: { prompt: 1, completion: 2, request: 0 } });
  });
  it.each([{}, { usage: { cost: -1 } }, { usage: { cost: "0" } }, { usage: { cost: null } }])("holds malformed/missing usage rather than zero: %j", async (body) => {
    const f = fixture(body);
    await f.fetch(chat, request);
    expect(f.rpc.mock.calls[1]).toEqual(["settle_ai_spend", expect.objectContaining({ p_cost_usd: null })]);
  });
  it("holds network uncertainty and reserves separately on retry", async () => {
    const f = fixture();
    f.send.mockImplementation(async (url) => {
      if (String(url).endsWith("/endpoints")) return endpointReply();
      if (String(url).endsWith("/models")) return new Response(JSON.stringify({ data: [{ id: "m", context_length: 1000, pricing: { prompt: "0", completion: "0" } }] }));
      throw new Error("connection lost");
    });
    await expect(f.fetch(chat, request)).rejects.toThrow("connection lost");
    await expect(f.fetch(chat, request)).rejects.toThrow("connection lost");
    expect(f.rpc.mock.calls).toHaveLength(2);
    expect(f.rpc.mock.calls.every((call) => call[0] === "reserve_ai_spend")).toBe(true);
  });
  it("budget rejection sends no paid request", async () => {
    const f = fixture();
    f.rpc.mockResolvedValue({ error: { message: "ai_budget_exhausted" } } as never);
    await expect(f.fetch(chat, request)).rejects.toThrow(/ai_budget_exhausted/);
    expect(f.send).toHaveBeenCalledTimes(2);
  });
  it.each(["https://openrouter.ai/api/v1/responses", "https://unknown.test/chat"])("unproven endpoint fails closed before network: %s", async (url) => {
    const f = fixture();
    await expect(f.fetch(url, request)).rejects.toThrow(/ai_price_bound_unavailable/);
    expect(f.send).not.toHaveBeenCalled();
    expect(f.rpc).not.toHaveBeenCalled();
  });
});

describe("preflight failure boundaries", () => {
  it("blocks unsupported metadata and extra billing dimensions before reserving", async () => {
    for (const pricing of [{ prompt: "1" }, { prompt: "1", completion: "1", input_cache_write: "0.01" }, { prompt: "NaN", completion: "1" }]) {
      const f = fixture();
      f.send.mockResolvedValue(new Response(JSON.stringify({ data: [{ id: "m", context_length: 1000, pricing }] })));
      await expect(f.fetch(chat, request)).rejects.toThrow(/ai_price_bound_unavailable/);
      expect(f.rpc).not.toHaveBeenCalled();
    }
  });
  it("persists a real zero, but keeps failed/malformed responses held", async () => {
    const zero = fixture({ usage: { cost: 0 } });
    await zero.fetch(chat, request);
    expect(zero.rpc.mock.calls[1][1]).toMatchObject({ p_cost_usd: 0 });
    const f = fixture();
    f.send.mockImplementation(async (url) => String(url).endsWith("/endpoints") ? endpointReply() : String(url).endsWith("/models")
      ? new Response(JSON.stringify({ data: [{ id: "m", context_length: 1000, pricing: { prompt: "0", completion: "0" } }] }))
      : new Response("gateway failed", { status: 502 }));
    expect((await f.fetch(chat, request)).status).toBe(502);
    expect(f.rpc.mock.calls[1][1]).toMatchObject({ p_cost_usd: null });
  });
  it("settlement errors do not return an unrecorded success", async () => {
    const f = fixture();
    f.rpc.mockResolvedValueOnce({ error: null }).mockResolvedValueOnce({ error: { message: "db failure" } } as never);
    await expect(f.fetch(chat, request)).rejects.toThrow("db failure");
  });
  it("keeps authenticated account IDs isolated", async () => {
    const f = fixture();
    const second = budgetFetch({ rpc: f.rpc } as unknown as SupabaseClient, "bob", f.send as typeof fetch);
    await Promise.all([f.fetch(chat, request), second(chat, request)]);
    const reservations = f.rpc.mock.calls.filter(([name]) => name === "reserve_ai_spend");
    expect(reservations.map(([, args]) => (args as { p_user_id: string }).p_user_id).sort()).toEqual(["alice", "bob"]);
  });
});


describe("bounded decisions and text embeddings", () => {
  it.each([
    { endpoint: "decisions", url: "https://openrouter.ai/api/alpha/decisions", model: "typesafe/jev-1.13", context: 32000, payload: { state: {}, questions: {} }, reserved: 0.000641 },
    { endpoint: "embeddings", url: "https://openrouter.ai/api/v1/embeddings", model: "openai/text-embedding-3-small", context: 8192, payload: { input: ["a", "b"] }, reserved: 0.000329 },
  ])("$endpoint reserves the full input ceiling and requires free output", async ({ endpoint, url, model, context, payload, reserved }) => {
    const f = fixture({ usage: { cost: 0.00001 } });
    f.send.mockResolvedValueOnce(new Response(JSON.stringify({ data: [{ id: model, context_length: context, pricing: { prompt: "0.00000002", completion: "0" } }] })));
    await f.fetch(url, { method: "POST", body: JSON.stringify({ model, ...payload, provider: JSON.parse(request.body).provider }) });
    expect(f.rpc.mock.calls[0][1]).toMatchObject({ p_endpoint: endpoint, p_reserved_usd: reserved });
    const sent = JSON.parse((f.send.mock.calls[2] as unknown as [string, RequestInit])[1].body as string);
    expect(sent.provider.max_price).toMatchObject({ prompt: 0.02, completion: 0, request: 0 });
  });
  it("never admits a decisions model with paid output or an unknown model", async () => {
    const f = fixture();
    f.send.mockResolvedValueOnce(new Response(JSON.stringify({ data: [{ id: "typesafe/jev-1.13", context_length: 32000, pricing: { prompt: "0.1", completion: "0.1" } }] })));
    await expect(f.fetch("https://openrouter.ai/api/alpha/decisions", { method: "POST", body: JSON.stringify({ model: "typesafe/jev-1.13", state: {}, questions: {}, provider: JSON.parse(request.body).provider }) })).rejects.toThrow(/ai_price_bound_unavailable/);
    expect(f.rpc).not.toHaveBeenCalled();
  });
});


it("real completion retry reserves and settles each invalid-output attempt", async () => {
  const f = fixture();
  let attempts = 0;
  f.send.mockImplementation(async (url) => {
      if (String(url).endsWith("/endpoints")) return endpointReply();
    if (String(url).endsWith("/models")) return new Response(JSON.stringify({ data: [{ id: "m", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002" } }] }));
    attempts++;
    return new Response(JSON.stringify({ id: `gen-${attempts}`, model: "m", usage: { prompt_tokens: 1, completion_tokens: 1, cost: 0.01 }, choices: [{ message: { content: attempts === 1 ? "invalid json" : '{"ok":true}' } }] }));
  });
  const result = await completeJson({ apiKey: "key", model: "m", providers: ["p"], fetch: f.fetch }, { system: "s", user: "u", schemaName: "test", schema: z.object({ ok: z.boolean() }) });
  expect(result.data.ok).toBe(true);
  expect(f.rpc.mock.calls.map(([name]) => name)).toEqual(["reserve_ai_spend", "settle_ai_spend", "reserve_ai_spend", "settle_ai_spend"]);
  expect(result.attempts).toHaveLength(2);
});


it("validates only selected model metadata; rejects its unbounded cache fees and tier overrides", async () => {
  const f = fixture();
  f.send.mockResolvedValueOnce(new Response(JSON.stringify({ data: [
    { id: "unrelated", context_length: null, pricing: { overrides: [{ prompt: "1" }] } },
    { id: "m", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002" } },
  ] })));
  await expect(f.fetch(chat, request)).resolves.toBeInstanceOf(Response);
  for (const pricing of [
    { prompt: "0.00000015", completion: "0.0000005", input_cache_read: "0.0000003" },
    { prompt: "1", completion: "1", overrides: [{ prompt: "2" }] },
  ]) {
    const blocked = fixture();
    blocked.send.mockResolvedValueOnce(new Response(JSON.stringify({ data: [{ id: "m", context_length: 1048576, pricing }] })));
    await expect(blocked.fetch(chat, request)).rejects.toThrow(/ai_price_bound_unavailable/);
    expect(blocked.rpc).not.toHaveBeenCalled();
  }
});


it("rejects an allowed provider's extra fee even when aggregate model prices look safe", async () => {
  const f = fixture();
  f.send.mockResolvedValueOnce(new Response(JSON.stringify({ data: [{ id: "m", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002" } }] })));
  f.send.mockResolvedValueOnce(new Response(JSON.stringify({ data: { endpoints: [{ tag: "p", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002", input_cache_write: "0.000003" } }] } })));
  await expect(f.fetch(chat, request)).rejects.toThrow(/ai_price_bound_unavailable/);
  expect(f.rpc).not.toHaveBeenCalled();
  expect(f.send).toHaveBeenCalledTimes(2);
});

it.each(["malformed", "network"])("catalog %s failure is a pricing error before paid dispatch", async (kind) => {
  const f = fixture();
  f.send.mockImplementation(async () => { if (kind === "network") throw new Error("private"); return new Response("not json"); });
  await expect(f.fetch(chat, request)).rejects.toMatchObject({ code: "ai_pricing_unavailable" });
  expect(f.rpc).not.toHaveBeenCalled();
});


describe("bounded cache-read pricing", () => {
  const aggregate = { data: [{ id: "m", context_length: 1_000_000, pricing: { prompt: "0.00000015", completion: "0.0000005", input_cache_read: "0.00000003" } }] };
  const selected = { tag: "p", context_length: 1_000_000, pricing: { prompt: "0.00000015", completion: "0.0000005", input_cache_read: "0.00000003" } };
  function cached(pricing: Record<string, string> = selected.pricing) {
    const f = fixture();
    f.send.mockResolvedValueOnce(new Response(JSON.stringify(aggregate)));
    f.send.mockResolvedValueOnce(new Response(JSON.stringify({ data: { endpoints: [
      { ...selected, pricing },
      // This regional endpoint is excluded by the unchanged upstream prompt/completion cap.
      { ...selected, tag: "p/region", pricing: { prompt: "0.000000225", completion: "0.00000075", input_cache_write: "1" } },
    ] } })));
    return f;
  }
  it("admits finite cache reads with full conservative allowance and preserves routing", async () => {
    const f = cached();
    await f.fetch(chat, request);
    expect(f.rpc.mock.calls[0][1]).toMatchObject({ p_reserved_usd: 0.680001 });
    const sent = JSON.parse((f.send.mock.calls[2] as unknown as [string, RequestInit])[1].body as string);
    expect(sent.provider).toEqual({ ...JSON.parse(request.body).provider, max_price: { prompt: 0.15, completion: 0.5, request: 0, image: 0 } });
    expect(f.rpc.mock.calls[1][1]).toMatchObject({ p_cost_usd: 0.01 });
  });
  it("includes cache allowance in admission before any paid call", async () => {
    const f = cached();
    f.rpc.mockImplementation(async (_, args) => ({ error: (args as { p_reserved_usd: number }).p_reserved_usd > 0.66 ? { message: "ai_budget_exhausted" } : null }));
    await expect(f.fetch(chat, request)).rejects.toThrow("ai_budget_exhausted");
    expect(f.send).toHaveBeenCalledTimes(2);
  });
  it.each<Record<string, string>>([
    { input_cache_read: "NaN" }, { input_cache_read: "-1" }, { input_cache_read: "" },
    { input_cache_read: "0.00000016" }, { input_cache_write: "0.00000001" }, { unknown_fee: "0.01" },
  ])("rejects unproven selectable endpoint fees: %j", async (extra) => {
    const f = cached({ ...selected.pricing, ...extra });
    await expect(f.fetch(chat, request)).rejects.toThrow(/ai_price_bound_unavailable/);
    expect(f.rpc).not.toHaveBeenCalled();
    expect(f.send).toHaveBeenCalledTimes(2);
  });
  it("retains settlement and violation detection if supplier exceeds the reservation", async () => {
    const f = cached();
    f.send.mockResolvedValueOnce(new Response(JSON.stringify({ usage: { cost: 0.7 } })));
    await expect(f.fetch(chat, request)).rejects.toThrow("ai_provider_cost_exceeded_reservation");
    expect(f.rpc.mock.calls[1][1]).toMatchObject({ p_cost_usd: 0.7 });
  });
});


// ── paid mode (BILLING_ENABLED=true): the v2 reservation, the entitlement gate and token usage ──
describe("paid-plan admission", () => {
  afterEach(() => vi.unstubAllEnvs());
  const DAY = 86_400_000;
  const proAccount = () => accountRow({ subscription_id: "s", status: "active", current_period_ends_at: new Date(Date.now() + DAY).toISOString() });
  function paid(account: Record<string, unknown>, body: unknown = { id: "gen-1", usage: { cost: 0.01, prompt_tokens: 120, completion_tokens: 30 } }, rpcs: Parameters<typeof fakeAdmin>[1] = {}) {
    stubBillingEnv();
    const f = fakeAdmin({ billing_accounts: [account] }, rpcs);
    const send = vi.fn(async (url: string | URL | Request) => String(url).endsWith("/endpoints") ? endpointReply() : new Response(JSON.stringify(String(url).endsWith("/models") ? { data: [{ id: "m", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002" } }] } : body)));
    return { ...f, send, fetch: budgetFetch(f.admin, account.user_id as string, send as typeof fetch) };
  }
  const names = (f: { rpcCalls: [string, unknown][] }) => f.rpcCalls.map(([name]) => name);

  it("reserves through the v2 window with the hidden caps, settles, then records the reference token usage", async () => {
    const f = paid(proAccount());
    await f.fetch(chat, request);
    expect(names(f)).toEqual(["reserve_billing_ai_spend_v2", "settle_ai_spend", "record_ai_spend_tokens"]);
    const reserve = f.rpcNamed("reserve_billing_ai_spend_v2")[0];
    expect(reserve).toMatchObject({ p_user_id: proAccount().user_id, p_endpoint: "chat", p_monthly_cap: 25, p_trial_cap: 4 });
    expect(Object.keys(reserve)).not.toContain("p_initial_sync");
    expect(f.rpcNamed("record_ai_spend_tokens")).toEqual([{ p_user_id: proAccount().user_id, p_id: reserve.p_id, p_prompt_tokens: 120, p_completion_tokens: 30 }]);
  });
  it("takes the operator caps from the environment", async () => {
    const f = paid(proAccount());
    vi.stubEnv("BILLING_MONTHLY_AI_BUDGET_USD", "40");
    vi.stubEnv("BILLING_TRIAL_AI_BUDGET_USD", "5");
    await f.fetch(chat, request);
    expect(f.rpcNamed("reserve_billing_ai_spend_v2")[0]).toMatchObject({ p_monthly_cap: 40, p_trial_cap: 5 });
  });
  it("embeddings report prompt tokens only: the missing completion count is recorded as zero", async () => {
    const f = paid(proAccount(), { usage: { cost: 0.0001, prompt_tokens: 64, total_tokens: 64 } });
    await f.fetch(chat, request);
    expect(f.rpcNamed("record_ai_spend_tokens")[0]).toMatchObject({ p_prompt_tokens: 64, p_completion_tokens: 0 });
  });
  it.each([[{ usage: { cost: 0.01 } }], [{ usage: { cost: 0.01, prompt_tokens: -1, completion_tokens: 5 } }], [{ usage: { cost: 0.01, prompt_tokens: 1.5 } }], [{ usage: { cost: 0.01, prompt_tokens: "9" } }], [{}]])("records no tokens for unusable usage %j and still settles", async (body) => {
    const f = paid(proAccount(), body);
    await f.fetch(chat, request);
    expect(names(f)).toEqual(["reserve_billing_ai_spend_v2", "settle_ai_spend"]);
  });
  it("a failing token write never fails the paid request or hides its settlement", async () => {
    const f = paid(proAccount(), undefined, { record_ai_spend_tokens: () => ({ error: { message: "down" } }) });
    expect((await f.fetch(chat, request)).status).toBe(200);
    expect(names(f)).toContain("settle_ai_spend");
  });
  it("no token is recorded when settlement itself failed", async () => {
    const f = paid(proAccount(), undefined, { settle_ai_spend: () => ({ error: { message: "db failure" } }) });
    await expect(f.fetch(chat, request)).rejects.toThrow("db failure");
    expect(names(f)).not.toContain("record_ai_spend_tokens");
  });
  it("a supplier cost above the reservation is still a violation after the tokens were recorded", async () => {
    const f = paid(proAccount(), { usage: { cost: 5, prompt_tokens: 1, completion_tokens: 1 } });
    await expect(f.fetch(chat, request)).rejects.toThrow("ai_provider_cost_exceeded_reservation");
  });
  it.each([
    ["a new account", accountRow()],
    ["an ended plan", accountRow({ subscription_id: "s", status: "expired" })],
    ["a lapsed period", accountRow({ subscription_id: "s", status: "active", current_period_ends_at: new Date(Date.now() - 1000).toISOString() })],
    ["a past_due plan beyond the grace", accountRow({ subscription_id: "s", status: "past_due", current_period_ends_at: new Date(Date.now() - 17 * DAY).toISOString() })],
  ])("closes %s before any price lookup, reservation or paid call", async (_label, account) => {
    const f = paid(account);
    await expect(f.fetch(chat, request)).rejects.toMatchObject({ code: "billing_required" });
    expect(f.send).not.toHaveBeenCalled();
    expect(f.rpcCalls).toEqual([]);
  });
  it("a Lifetime account passes the plan gate but the database refuses a managed reservation: closed, nothing paid, v1 code unchanged", async () => {
    const f = paid(accountRow({ lifetime_status: "active", lifetime_order_id: "o" }), undefined, { reserve_billing_ai_spend_v2: () => ({ error: { message: "byok_required" } }) });
    await expect(f.fetch(chat, request)).rejects.toMatchObject({ code: "billing_required" });
    expect(f.send).toHaveBeenCalledTimes(2); // catalog reads only
    expect(names(f)).toEqual(["reserve_billing_ai_spend_v2"]);
  });
  it("a fair-use pause is the existing exhausted code, paid call never sent", async () => {
    const f = paid(proAccount(), undefined, { reserve_billing_ai_spend_v2: () => ({ error: { message: "ai_budget_exhausted" } }) });
    await expect(f.fetch(chat, request)).rejects.toMatchObject({ code: "ai_budget_exhausted" });
    expect(f.send).toHaveBeenCalledTimes(2);
  });
  it("billing off keeps today's exact path: legacy reservation, no plan lookup, no token write", async () => {
    stubBillingEnv({ BILLING_ENABLED: "false" });
    const f = fakeAdmin();
    const send = vi.fn(async (url: string | URL | Request) => String(url).endsWith("/endpoints") ? endpointReply() : new Response(JSON.stringify(String(url).endsWith("/models") ? { data: [{ id: "m", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002" } }] } : { id: "gen-1", usage: { cost: 0.01, prompt_tokens: 3, completion_tokens: 4 } })));
    await budgetFetch(f.admin, "alice", send as typeof fetch)(chat, request);
    expect(f.rpcCalls.map(([name]) => name)).toEqual(["reserve_ai_spend", "settle_ai_spend"]);
    expect(f.tables.size).toBe(0);
  });
});
