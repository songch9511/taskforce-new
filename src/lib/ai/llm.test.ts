import { describe, expect, it } from "vitest";
import { z } from "zod";

import { completeJson, llmConfigFromEnv, LlmError, type LlmConfig } from "./llm";

const schema = z.object({ ok: z.boolean() });
const request = { system: "s", user: "u", schemaName: "t", schema };

function config(contents: (string | null)[], status = 200): LlmConfig & { bodies: unknown[] } {
  const bodies: unknown[] = [];
  let call = 0;
  return {
    apiKey: "key",
    model: "test/model",
    bodies,
    fetch: (async (_url: string, init: RequestInit) => {
      bodies.push(JSON.parse(init.body as string));
      const content = contents[Math.min(call++, contents.length - 1)];
      return new Response(JSON.stringify({ model: "test/model", choices: [{ finish_reason: "stop", message: { content } }] }), {
        status,
      });
    }) as typeof fetch,
  };
}

describe("completeJson", () => {
  it("구조화 출력 · 출력 상한 · 공급자 조건을 보내고 스키마로 검증한다", async () => {
    const c = config(['{"ok":true}']);
    const result = await completeJson(c, request);
    expect(result.data).toEqual({ ok: true });
    expect(c.bodies[0]).toMatchObject({
      model: "test/model",
      max_tokens: 8192,
      response_format: { type: "json_schema", json_schema: { name: "t", strict: true } },
      provider: { require_parameters: true, data_collection: "deny", zdr: true },
    });
    expect(c.bodies[0]).not.toHaveProperty("temperature");
  });

  it("공급자를 고정하면 그 목록만, 그 순서로, 넘어가지 않게 보낸다", async () => {
    const c = { ...config(['{"ok":true}']), providers: ["together", "fireworks"] };
    await completeJson(c, request);
    expect((c.bodies[0] as { provider: unknown }).provider).toEqual({
      require_parameters: true,
      data_collection: "deny",
      zdr: true,
      only: ["together", "fireworks"],
      order: ["together", "fireworks"],
      allow_fallbacks: false,
    });
  });

  it("환경변수 LLM_PROVIDERS로 목록을 바꾸고, 비우면 기본 미국 ZDR 목록", () => {
    expect(llmConfigFromEnv({ OPENROUTER_API_KEY: "k", LLM_MODEL: "m", LLM_PROVIDERS: "deepinfra" }).providers).toEqual(["deepinfra"]);
    expect(llmConfigFromEnv({ OPENROUTER_API_KEY: "k", LLM_MODEL: "m" }).providers).toEqual(["fireworks", "together", "deepinfra"]);
  });

  it("JSON이 아닌 답은 한 번 다시 묻는다", async () => {
    const c = config(["oops", '{"ok":true}']);
    expect((await completeJson(c, request)).data).toEqual({ ok: true });
    expect(c.bodies).toHaveLength(2);
  });

  it("다시 물어도 깨지면 오류", async () => {
    const c = config(["oops", '{"ok":"no"}']);
    await expect(completeJson(c, request)).rejects.toThrow(/스키마/);
    expect(c.bodies).toHaveLength(2);
  });

  it("시간 안에 답이 없으면 한 번 다시 묻는다", async () => {
    let calls = 0;
    const c: LlmConfig = {
      apiKey: "key",
      model: "test/model",
      fetch: (async () => {
        if (calls++ === 0) throw new DOMException("timed out", "TimeoutError");
        return new Response(JSON.stringify({ model: "m", choices: [{ message: { content: '{"ok":true}' } }] }));
      }) as typeof fetch,
    };
    expect((await completeJson(c, request)).data).toEqual({ ok: true });
    expect(calls).toBe(2);
  });

  it("HTTP 오류는 다시 묻지 않는다", async () => {
    const c = config(['{"ok":true}'], 402);
    await expect(completeJson(c, request)).rejects.toBeInstanceOf(LlmError);
    expect(c.bodies).toHaveLength(1);
  });
});
