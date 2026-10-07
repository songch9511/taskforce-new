import "server-only";
import { AiBudgetError } from "./budget-error";
export { AiBudgetError } from "./budget-error";

import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import { fetchGeneration, generationConfigFromEnv } from "./generation";

const CHAT = "https://openrouter.ai/api/v1/chat/completions";
const EMBEDDINGS = "https://openrouter.ai/api/v1/embeddings";
const DECISIONS = "https://openrouter.ai/api/alpha/decisions";
const MODELS = "https://openrouter.ai/api/v1/models";
const NO_EXTRA_FEES = { request: 0, image: 0 };
const MAX_OUTPUT = 8192;
const MAX_BODY_BYTES = 1_000_000;
const cost = z.number().finite().nonnegative();
// Budget starts only at the coordinated guarded-code rollout; schema alone cannot intercept old processes.
// Accounts retain this ledger for the beta period without reset; pre-beta spend is intentionally excluded.
const metadata = z.object({
  id: z.string().regex(/^gen-[0-9A-Za-z-]{1,124}$/).optional().catch(undefined),
  usage: z.object({ cost }).optional().catch(undefined),
});
const modelMetadata = z.object({
  id: z.string(), context_length: z.number().int().positive(),
  pricing: z.record(z.string(), z.string()),
});
const models = z.object({ data: z.array(z.object({ id: z.string() }).passthrough()) });
const provider = z.object({ only: z.array(z.string()).min(1), order: z.array(z.string()).min(1), zdr: z.literal(true), data_collection: z.literal("deny"), allow_fallbacks: z.literal(false), require_parameters: z.boolean().optional() }).strict();
const chatRequest = z.object({
  model: z.string().min(1), max_tokens: z.number().int().positive().max(MAX_OUTPUT),
  messages: z.array(z.object({ role: z.enum(["system", "user"]), content: z.string() })).min(1),
  provider,
  response_format: z.unknown().optional(),
  temperature: z.number().optional(),
  reasoning: z.object({ effort: z.enum(["low", "medium", "high"]), exclude: z.literal(true) }).optional(),
}).strict();
const embeddingRequest = z.object({ model: z.string().min(1), input: z.array(z.string().min(1)).min(1).max(128), provider }).strict();
const decisionRequest = z.object({ model: z.literal("typesafe/jev-1.13"), state: z.unknown(), questions: z.record(z.string(), z.unknown()).refine((q) => Object.keys(q).length <= 128), provider }).strict();



/**
 * Durable hold per HTTP attempt, including retry/timeout/invalid reply. No unknown cost is zero.
 * Reserve FULL context ceilings, never heuristic token counts:
 * - chat: context_length * (prompt + completion price). Some providers exclude reasoning from
 *   max_tokens, so reserve the whole output context too; still send the existing output limit.
 * - text embeddings: context_length * item count * prompt price, zero-priced output only.
 * - fixed Jev: context_length * prompt price, zero-priced output only (state + questions share context).
 * Cache reads add a full input-context allowance from selectable endpoint metadata.
 * All three schemas document provider.max_price. Unknown extra billing dimensions fail closed.
 * Upstream context/price contract violations cannot be prevented locally; record and freeze them.
 * https://openrouter.ai/docs/guides/routing/provider-selection#max-price
 * https://openrouter.ai/docs/api/api-reference/embeddings/submit-an-embedding-request
 * https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request
 * https://openrouter.ai/docs/guides/community/jev
 */
export function budgetFetch(admin: SupabaseClient, userId: string, send: typeof fetch = fetch): typeof fetch {
  return async (url, init) => {
    if (!userId) throw new AiBudgetError("ai_user_required");
    const endpoint = String(url) === CHAT ? "chat" : String(url) === EMBEDDINGS ? "embeddings" : String(url) === DECISIONS ? "decisions" : null;
    if (!endpoint) throw new AiBudgetError("ai_price_bound_unavailable");
    if (init?.method !== "POST" || typeof init.body !== "string" || Buffer.byteLength(init.body) > MAX_BODY_BYTES) throw new AiBudgetError("ai_request_bound_unavailable");
    const raw: unknown = JSON.parse(init.body);
    const parsed = (endpoint === "chat" ? chatRequest : endpoint === "embeddings" ? embeddingRequest : decisionRequest).safeParse(raw);
    if (!parsed.success) throw new AiBudgetError("ai_request_bound_unavailable");
    const body = parsed.data;
    // Text-only payloads; newly added paid features need a separately reviewed cost bound.
    const catalog = endpoint === "embeddings" ? `${EMBEDDINGS}/models` : endpoint === "decisions" ? `${MODELS}?output_modalities=decisions` : MODELS;
    const readCatalog = async (url: string): Promise<unknown> => {
      try {
        const response = await send(url, { signal: init.signal ?? AbortSignal.timeout(10_000) });
        if (!response.ok) throw new AiBudgetError("ai_price_bound_unavailable");
        return await response.json();
      } catch (error) {
        if (error instanceof DOMException && error.name === "TimeoutError") throw error;
        throw new AiBudgetError("ai_price_bound_unavailable");
      }
    };
    const catalogData = models.safeParse(await readCatalog(catalog));
    const model = modelMetadata.safeParse(catalogData.data?.data.find((item) => item.id === body.model)).data;
    if (!model || body.model.startsWith("~") || body.model.startsWith("openrouter/") || body.model.includes(":")) throw new AiBudgetError("ai_price_bound_unavailable");
    if (!Object.hasOwn(model.pricing, "prompt") || !Object.hasOwn(model.pricing, "completion") || Object.entries(model.pricing).some(([key, value]) => {
      const price = Number(value);
      return value.trim() === "" || !Number.isFinite(price) || price < 0 || (!["prompt", "completion", "input_cache_read"].includes(key) && price !== 0) || (key === "input_cache_read" && price > Number(model.pricing.prompt));
    }) || (endpoint !== "chat" && Number(model.pricing.completion) !== 0)) throw new AiBudgetError("ai_price_bound_unavailable");
    // Advertised rates are USD/token; the enforced upstream filter is USD/million tokens.
    const price = { ...NO_EXTRA_FEES, prompt: Number(model.pricing.prompt) * 1_000_000, completion: endpoint === "chat" ? Number(model.pricing.completion) * 1_000_000 : 0 };
    // Aggregate model prices alone do not prove every allowed provider's fee dimensions.

    const endpoints = z.object({ data: z.object({ endpoints: z.array(z.object({
      tag: z.string(), context_length: z.number().int().positive(),
      pricing: z.record(z.string(), z.union([z.string(), z.number()])),
    })) }) }).safeParse(await readCatalog(`${MODELS}/${body.model}/endpoints`)).data?.data.endpoints;
    const matches = (tag: string, slug: string) => tag === slug || tag.startsWith(`${slug}/`);
    const allowed = endpoints?.filter((e) => body.provider.only.some((slug) => matches(e.tag, slug)));
    if (!allowed?.length || body.provider.only.some((slug) => !allowed.some((e) => matches(e.tag, slug)))) throw new AiBudgetError("ai_price_bound_unavailable");
    // max_price excludes expensive endpoints, including regional variants of an allowed slug.
    // Missing/malformed base prices cannot establish exclusion and must fail closed.
    if (allowed.some((e) => ["prompt", "completion"].some((key) => {
      const value = e.pricing[key];
      return value === undefined || String(value).trim() === "" || !Number.isFinite(Number(value)) || Number(value) < 0;
    }))) throw new AiBudgetError("ai_price_bound_unavailable");
    const selectable = allowed.filter((e) => Number(e.pricing.prompt) * 1_000_000 <= price.prompt && Number(e.pricing.completion) * 1_000_000 <= price.completion);
    if (!selectable.length || selectable.some((e) =>
      e.context_length > model.context_length || Object.entries(e.pricing).some(([key, value]) => {
        const n = Number(value);
        if (String(value).trim() === "" || !Number.isFinite(n) || n < 0) return true;
        if (key === "discount") return n > 1;
        if (key === "prompt" || key === "completion") return false;
        if (key === "input_cache_read") return n > Number(e.pricing.prompt);
        return n !== 0;
      })
    )) throw new AiBudgetError("ai_price_bound_unavailable");
    // max_price has no cache-read field. Reserve its full input-context allowance separately,
    // even though cached tokens are a subset of prompt tokens; unknown write fees stay blocked.
    const cacheReadPrice = Math.max(...selectable.map((e) => Number(e.pricing.input_cache_read ?? 0))) * 1_000_000;
    const items = "input" in body ? body.input.length : 1;
    // Round UP plus one micro-dollar for floating conversion error (< $10 admission); DB uses exact numeric.
    const reserved = (Math.ceil(model.context_length * items * (price.prompt + price.completion + cacheReadPrice)) + 1) / 1_000_000;
    const id = crypto.randomUUID();
    const reservation = await admin.rpc("reserve_ai_spend", { p_user_id: userId, p_id: id, p_endpoint: endpoint, p_model: body.model, p_reserved_usd: reserved });
    if (reservation.error) throw new AiBudgetError(reservation.error.message);
    // No finally/release: any abort, network/read failure or process death keeps the hold.
    const result = await send(url, { ...init, body: JSON.stringify({ ...body, provider: { ...body.provider, max_price: price } }) });
    let meta: z.infer<typeof metadata> | undefined;
    try { meta = metadata.safeParse(await result.clone().json()).data; } catch { /* The paid request may have completed. Keep its hold. */ }
    const settlement = await admin.rpc("settle_ai_spend", { p_user_id: userId, p_id: id, p_cost_usd: meta?.usage?.cost ?? null, p_generation_id: meta?.id ?? null });
    if (settlement.error) throw new AiBudgetError(settlement.error.message);
    if (meta?.usage && meta.usage.cost > reserved) throw new AiBudgetError("ai_provider_cost_exceeded_reservation");
    return result;
  };
}

export type AiSpendReconciliation = { attempted: number; settled: number; deferred: number; errors: number };

/** Aggregate counters only. Missing IDs/404/malformed costs never release a hold. */
export async function reconcileAiSpend(admin: SupabaseClient): Promise<AiSpendReconciliation> {
  const result: AiSpendReconciliation = { attempted: 0, settled: 0, deferred: 0, errors: 0 };
  try {
    const { data } = await admin.from("ai_spend_attempts").select("id,user_id,generation_id,model")
      .is("cost_usd", null).not("generation_id", "is", null).order("reconcile_checked_at", { nullsFirst: true }).limit(20).throwOnError();
    if (!data?.length) return result;
    const config = generationConfigFromEnv();
    await Promise.all(data.map(async (row) => {
      result.attempted++;
      try {
        const update = admin.from("ai_spend_attempts").update({ reconcile_checked_at: new Date().toISOString() }).eq("id", row.id);
        await (row.user_id === null ? update.is("user_id", null) : update.eq("user_id", row.user_id)).throwOnError();
        const lookup = await fetchGeneration(config, row.generation_id);
        if (lookup.status !== "found" || !cost.safeParse(lookup.generation.costUsd).success) {
          result.deferred++;
          return;
        }
        const { error } = await admin.rpc("settle_ai_spend", { p_user_id: row.user_id, p_id: row.id, p_cost_usd: lookup.generation.costUsd, p_generation_id: row.generation_id });
        if (error) throw error;
        result.settled++;
      } catch {
        // Count infrastructure/response failures without retaining error text or identifiers.
        result.errors++;
      }
    }));
  } catch {
    // Listing/configuration can fail before any attempt; the next scheduled sweep retries.
    result.errors++;
  }
  return result;
}
