import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { completeJson } from "./llm";
import { budgetFetch } from "./budget";
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
