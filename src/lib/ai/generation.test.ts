import { describe, expect, it } from "vitest";

import { fetchGeneration, generationConfigFromEnv, GenerationError, type GenerationConfig } from "./generation";

function config(status: number, body: unknown): GenerationConfig & { urls: string[]; headers: Record<string, string>[] } {
  const urls: string[] = [];
  const headers: Record<string, string>[] = [];
  return {
    apiKey: "key",
    urls,
    headers,
    fetch: (async (url: string, init: RequestInit) => {
      urls.push(url);
      headers.push(init.headers as Record<string, string>);
      return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
    }) as typeof fetch,
  };
}

// 2026-10-02 개발 키로 받은 응답의 모양 (값만 바꿈). 글(원문 · 답)은 들어 있지 않다.
const data = {
  id: "gen-1790938614-QtLw2iJ7w1tAyV9n84Xz",
  model: "z-ai/glm-5.3-flash-20260826",
  total_cost: 0.0000884,
  created_at: "2026-10-02T10:56:54.35Z",
  provider_name: "Together",
  tokens_prompt: 12,
  tokens_completion: 162,
  native_tokens_prompt: 26,
  native_tokens_completion: 169,
  native_tokens_reasoning: 159,
  cancelled: false,
  is_byok: false,
  usage: 0.0000884,
  origin: "",
  data_region: "global",
};

describe("fetchGeneration", () => {
  it("generation id로 조회해 확정 비용 · 공급자 · 청구 기준 토큰 수를 돌려준다", async () => {
    const c = config(200, { data });
    const result = await fetchGeneration(c, data.id);
    expect(c.urls[0]).toBe(`https://openrouter.ai/api/v1/generation?id=${data.id}`);
    expect(c.headers[0].Authorization).toBe("Bearer key");
    expect(result).toEqual({
      status: "found",
      generation: {
        id: data.id,
        model: data.model,
        costUsd: 0.0000884,
        provider: "Together",
        promptTokens: 26,
        completionTokens: 169,
        reasoningTokens: 159,
        cancelled: false,
        createdAt: data.created_at,
      },
    });
  });

  it("생성 직후처럼 아직 없으면(404) pending", async () => {
    const c = config(404, { error: { message: `Generation ${data.id} not found`, code: 404 } });
    expect(await fetchGeneration(c, data.id)).toEqual({ status: "pending" });
  });

  it("generation id 형식이 아니면 부르지 않는다", async () => {
    const c = config(200, { data });
    await expect(fetchGeneration(c, "gen-1&id=gen-2")).rejects.toBeInstanceOf(GenerationError);
    await expect(fetchGeneration(c, "chatcmpl-123")).rejects.toBeInstanceOf(GenerationError);
    expect(c.urls).toHaveLength(0);
  });

  it("다른 HTTP 오류 · 형식이 다른 응답 · 다른 id의 응답은 오류", async () => {
    await expect(fetchGeneration(config(401, "unauthorized"), data.id)).rejects.toThrow("generation 조회 실패 (401)");
    await expect(fetchGeneration(config(200, { data: { id: data.id } }), data.id)).rejects.toThrow("형식");
    await expect(fetchGeneration(config(200, { data: { ...data, id: "gen-other" } }), data.id)).rejects.toThrow("다른 generation");
  });

  it("시간 초과 · 네트워크 오류 · JSON이 아닌 본문도 GenerationError", async () => {
    const timeout: GenerationConfig = { apiKey: "key", fetch: (async () => { throw new DOMException("timed out", "TimeoutError"); }) as typeof fetch };
    await expect(fetchGeneration(timeout, data.id)).rejects.toMatchObject({ name: "GenerationError", message: "generation 조회 실패 (TimeoutError)" });
    await expect(fetchGeneration(config(200, "<html>"), data.id)).rejects.toBeInstanceOf(GenerationError);
  });

  it("빈 선택 값은 null로 둔다", async () => {
    const sparse = { id: data.id, model: data.model, total_cost: data.total_cost, created_at: data.created_at, tokens_prompt: 12, tokens_completion: 162, native_tokens_completion: null };
    const result = await fetchGeneration(config(200, { data: sparse }), data.id);
    expect(result).toMatchObject({ generation: { provider: null, promptTokens: 12, completionTokens: 162, reasoningTokens: null, cancelled: null } });
  });

  it("키가 없으면 설정 오류", () => {
    expect(() => generationConfigFromEnv({})).toThrow(GenerationError);
    expect(generationConfigFromEnv({ OPENROUTER_API_KEY: "k" })).toEqual({ apiKey: "k" });
  });
});
