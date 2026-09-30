import { describe, expect, it } from "vitest";
import { z } from "zod";

import { completeJson, llmConfigFromEnv, LlmError, OVERRUN_RETRY_REASONING, type LlmConfig } from "./llm";

const schema = z.object({ ok: z.boolean() });
const request = { system: "s", user: "u", schemaName: "t", schema };

/** contents: 차례로 돌려줄 답 (finish_reason은 stop, [답, 끝난 이유]로 바꿀 수 있다) */
function config(contents: (string | null | [string | null, string])[], status = 200): LlmConfig & { bodies: Record<string, unknown>[] } {
  const bodies: Record<string, unknown>[] = [];
  let call = 0;
  return {
    apiKey: "key",
    model: "test/model",
    bodies,
    fetch: (async (_url: string, init: RequestInit) => {
      bodies.push(JSON.parse(init.body as string));
      const next = contents[Math.min(call++, contents.length - 1)];
      const [content, finish_reason] = Array.isArray(next) ? next : [next, "stop"];
      return new Response(JSON.stringify({ model: "test/model", choices: [{ finish_reason, message: { content } }] }), {
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

  it("평소에는 추론량을 제한하지 않는다", async () => {
    const c = config(["oops", '{"ok":true}']);
    expect((await completeJson(c, request)).reasoningLimited).toBeUndefined();
    // 형식이 깨진 것(출력 한도 아님)은 제한 없이 다시 묻는다
    expect(c.bodies.map((body) => body.reasoning)).toEqual([undefined, undefined]);
  });

  it("출력 한도를 넘겨 답이 비거나 잘렸으면, 다시 물을 때만 추론량을 제한한다", async () => {
    const empty = config([[null, "length"], '{"ok":true}']);
    expect((await completeJson(empty, request)).data).toEqual({ ok: true });
    expect(empty.bodies.map((body) => body.reasoning)).toEqual([undefined, { ...OVERRUN_RETRY_REASONING, exclude: true }]);

    const cut = config([['{"ok":', "length"], '{"ok":true}']);
    const result = await completeJson(cut, request);
    expect(cut.bodies[1].reasoning).toEqual({ effort: "high", exclude: true });
    // 제한해 다시 물은 답인지 남긴다
    expect(result.reasoningLimited).toBe(true);
  });

  it("시간 한도를 넘겼어도 다시 물을 때 추론량을 제한한다", async () => {
    const bodies: Record<string, unknown>[] = [];
    const c: LlmConfig = {
      apiKey: "key",
      model: "test/model",
      fetch: (async (_url: string, init: RequestInit) => {
        bodies.push(JSON.parse(init.body as string));
        if (bodies.length === 1) throw new DOMException("timed out", "TimeoutError");
        return new Response(JSON.stringify({ model: "m", choices: [{ message: { content: '{"ok":true}' } }] }));
      }) as typeof fetch,
    };
    await completeJson(c, request);
    expect(bodies.map((body) => body.reasoning)).toEqual([undefined, { effort: "high", exclude: true }]);
  });

  it("추론량 제한은 환경변수로 바꾸거나 끌 수 있다 (추론하지 않는 모델로 바꿀 때)", async () => {
    const env = { OPENROUTER_API_KEY: "k", LLM_MODEL: "m" };
    expect(llmConfigFromEnv(env).overrunReasoning).toBeUndefined();
    expect(llmConfigFromEnv({ ...env, LLM_OVERRUN_REASONING_EFFORT: "medium" }).overrunReasoning).toEqual({ effort: "medium" });
    expect(llmConfigFromEnv({ ...env, LLM_OVERRUN_REASONING_EFFORT: "off" }).overrunReasoning).toBeNull();
    expect(() => llmConfigFromEnv({ ...env, LLM_OVERRUN_REASONING_EFFORT: "max" })).toThrow(LlmError);

    const off = { ...config([[null, "length"], '{"ok":true}']), overrunReasoning: null };
    const result = await completeJson(off, request);
    expect(off.bodies.map((body) => body.reasoning)).toEqual([undefined, undefined]);
    expect(result.reasoningLimited).toBeUndefined();
  });

  it("HTTP 오류는 다시 묻지 않는다", async () => {
    const c = config(['{"ok":true}'], 402);
    await expect(completeJson(c, request)).rejects.toBeInstanceOf(LlmError);
    expect(c.bodies).toHaveLength(1);
  });
});
