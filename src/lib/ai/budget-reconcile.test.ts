import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { reconcileAiSpend } from "./budget";
vi.mock("server-only", () => ({}));
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });
describe("AI spend reconciliation", () => {
  it("confirms matching generation total_cost; missing, malformed and failed lookup holds remain", async () => {
    vi.stubEnv("OPENROUTER_API_KEY", "key");
    const rows = ["ok", "pending", "negative", "missing-cost", "wrong", "error"].map((id) => ({ id, user_id: "alice", generation_id: `gen-${id}`, model: "m" }));
    const q = { select: vi.fn(() => q), is: vi.fn(() => q), not: vi.fn(() => q), order: vi.fn(() => q), limit: vi.fn(() => q), update: vi.fn(() => q), eq: vi.fn(() => q), throwOnError: vi.fn(async () => ({ data: rows })) };
    const rpc = vi.fn(async () => ({ error: null }));
    const admin = { from: vi.fn(() => q), rpc } as unknown as SupabaseClient;
    vi.stubGlobal("fetch", async (url: string) => {
      const id = new URL(url).searchParams.get("id");
      if (id === "gen-pending") return new Response(null, { status: 404 });
      if (id === "gen-error") throw new TypeError("connection lost");
      return new Response(JSON.stringify({ data: { id: id === "gen-wrong" ? "gen-other" : id, model: "m", total_cost: id === "gen-missing-cost" ? undefined : id === "gen-negative" ? -1 : 0.002, created_at: "2026-10-05T00:00:00Z" } }));
    });
    expect(await reconcileAiSpend(admin)).toEqual({ attempted: 6, settled: 1, deferred: 2, errors: 3 });
    expect(rpc).toHaveBeenCalledExactlyOnceWith("settle_ai_spend", { p_user_id: "alice", p_id: "ok", p_cost_usd: 0.002, p_generation_id: "gen-ok" });
    expect(q.update).toHaveBeenCalledTimes(6);
    expect(q.order).toHaveBeenCalledWith("reconcile_checked_at", { nullsFirst: true });
  });
});


it.each(["update", "lookup", "settlement", "list"])("counts %s infrastructure failure without exposing identifiers or releasing holds", async (stage) => {
  vi.stubEnv("OPENROUTER_API_KEY", "secret-key");
  const sensitive = "private-user gen-private secret-key provider-body";
  const rows = [{ id: "attempt", user_id: "private-user", generation_id: "gen-private", model: "m" }];
  const q = { select: () => q, is: () => q, not: () => q, order: () => q, limit: () => q, update: () => q, eq: () => q,
    throwOnError: vi.fn(async () => ({ data: rows })) };
  if (stage === "list") q.throwOnError.mockRejectedValueOnce(new Error(sensitive));
  if (stage === "update") q.throwOnError.mockResolvedValueOnce({ data: rows }).mockRejectedValueOnce(new Error(sensitive));
  const rpc = vi.fn(async () => ({ error: stage === "settlement" ? { message: sensitive } : null }));
  const admin = { from: () => q, rpc } as unknown as SupabaseClient;
  vi.stubGlobal("fetch", async () => {
    if (stage === "lookup") throw new Error(sensitive);
    return new Response(JSON.stringify({ data: { id: "gen-private", model: "m", total_cost: 0.002, created_at: "2026-10-05T00:00:00Z" } }));
  });
  const result = await reconcileAiSpend(admin);
  expect(result).toEqual({ attempted: stage === "list" ? 0 : 1, settled: 0, deferred: 0, errors: 1 });
  expect(JSON.stringify(result)).not.toMatch(/private|gen-|secret|provider-body/);
  if (stage === "settlement") expect(rpc).toHaveBeenCalledOnce();
  else expect(rpc).not.toHaveBeenCalled();
});

it("reconciles anonymous spend retained after account deletion",async()=>{
  vi.stubEnv("OPENROUTER_API_KEY","key");
  const rows=[{id:"orphan",user_id:null,generation_id:"gen-orphan",model:"m"}];
  const q={select:()=>q,is:vi.fn(()=>q),not:()=>q,order:()=>q,limit:()=>q,update:()=>q,eq:()=>q,throwOnError:vi.fn(async()=>({data:rows}))};
  const rpc=vi.fn(async()=>({error:null}));
  vi.stubGlobal("fetch",async()=>new Response(JSON.stringify({data:{id:"gen-orphan",model:"m",total_cost:.01,created_at:"2026-10-05T00:00:00Z"}})));
  expect(await reconcileAiSpend({from:()=>q,rpc} as unknown as SupabaseClient)).toEqual({attempted:1,settled:1,deferred:0,errors:0});
  expect(q.is).toHaveBeenCalledWith("user_id",null);
  expect(rpc).toHaveBeenCalledWith("settle_ai_spend",{p_user_id:null,p_id:"orphan",p_cost_usd:.01,p_generation_id:"gen-orphan"});
});
