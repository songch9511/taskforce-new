vi.mock("@/lib/ai/budget", () => ({ budgetFetch: () => fetch }));
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";

import { askModelResponseSchema } from "@/lib/pipeline/ask";

import { askDepsFromEnv } from "./ask-store";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/consent/store", async (importOriginal) => ({ ...(await importOriginal<typeof import("@/lib/consent/store")>()), consentCheck: () => async () => true }));

// 물어보기는 사용자가 답을 기다린다 (v1/ask/route.ts, 실행 한도 60초): 임베딩 · LLM을 마감 안에 끝내고 LLM은 첫 호출부터 추론량을 제한한다.
describe("askDepsFromEnv", () => {
  function fakeOpenRouter() {
    vi.stubEnv("OPENROUTER_API_KEY", "k");
    vi.stubEnv("LLM_MODEL", "m");
    vi.stubEnv("LLM_OVERRUN_REASONING_EFFORT", "");
    const sent: { url: string; body: Record<string, unknown> }[] = [];
    vi.stubGlobal("fetch", async (url: string, init: RequestInit) => {
      sent.push({ url, body: JSON.parse(init.body as string) });
      const content = JSON.stringify({ unknown: true, answer: "", citations: [] });
      return new Response(JSON.stringify({ model: "m", choices: [{ message: { content } }] }));
    });
    return sent;
  }

  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  it("LLM은 첫 호출부터 추론량을 제한한다", async () => {
    const sent = fakeOpenRouter();
    const deps = askDepsFromEnv({} as SupabaseClient, "u1", Date.now() + 55_000);
    const result = await deps.complete({ system: "s", user: "u", schemaName: "ask_answer", schema: askModelResponseSchema, maxTokens: 2048 });
    expect(sent[0].body.reasoning).toEqual({ effort: "high", exclude: true });
    expect(result.reasoningLimited).toBe(true);
  });

  it("마감이 지났으면 임베딩도 LLM도 부르지 않는다", async () => {
    const sent = fakeOpenRouter();
    const deps = askDepsFromEnv({} as SupabaseClient, "u1", Date.now() - 1);
    await expect(deps.embed(["질문"])).rejects.toThrow(/남은 시간 없음/);
    await expect(deps.complete({ system: "s", user: "u", schemaName: "ask_answer", schema: askModelResponseSchema })).rejects.toThrow(/남은 시간 없음/);
    expect(sent).toHaveLength(0);
  });
});
