import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";

import { DeadlineExceededError } from "./deadline";
import {
  attemptTimeoutMs,
  completeJson,
  DEADLINE_OVERRUN_REASONING,
  LLM_MIN_ATTEMPT_MS,
  LLM_TIMEOUT_MS,
  llmConfigFromEnv,
  LlmError,
  OVERRUN_RETRY_REASONING,
  type LlmConfig,
} from "./llm";

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

describe("사용자가 기다리는 호출 (마감 있음: 빠진 할 일 신고 · 물어보기)", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  /** Date.now를 가짜 시계로 바꾼다. 가짜 fetch가 시간을 흘려 보낸다 */
  function fakeClock(start = 1_000_000) {
    const clock = { now: start };
    vi.spyOn(Date, "now").mockImplementation(() => clock.now);
    return clock;
  }

  /** 시도마다 준 시간 한도 (AbortSignal.timeout에 넘긴 값) */
  function timeouts() {
    const spy = vi.spyOn(AbortSignal, "timeout");
    return () => spy.mock.calls.map(([ms]) => ms);
  }

  const high = { ...OVERRUN_RETRY_REASONING, exclude: true };
  const low = { ...DEADLINE_OVERRUN_REASONING, exclude: true };

  it("시도마다 남은 시간을 남은 시도 수로 나눠 한도를 정하고, 모자라면 한 시도에 다 주거나 묻지 않는다", () => {
    const now = 0;
    // 마감이 없으면(배경 처리) 지금처럼 90초
    expect(attemptTimeoutMs({}, 2, now)).toBe(LLM_TIMEOUT_MS);
    expect(attemptTimeoutMs({ timeoutMs: 10_000 }, 2, now)).toBe(10_000);
    // 첫 시도는 남은 38초의 절반, 마지막 시도는 남은 시간 전부
    expect(attemptTimeoutMs({ deadline: 38_000 }, 2, now)).toBe(19_000);
    expect(attemptTimeoutMs({ deadline: 38_000 }, 1, now)).toBe(38_000);
    // 90초보다 길게 주지 않는다
    expect(attemptTimeoutMs({ deadline: 300_000 }, 2, now)).toBe(LLM_TIMEOUT_MS);
    // 나누면 한 시도가 5초보다 짧아지면 이 시도에 남은 시간을 다 준다 (다시 묻기는 빠진다)
    expect(attemptTimeoutMs({ deadline: 8_000 }, 2, now)).toBe(8_000);
    expect(attemptTimeoutMs({ deadline: 12_000 }, 2, now)).toBe(6_000);
    expect(attemptTimeoutMs({ deadline: LLM_MIN_ATTEMPT_MS - 1 }, 1, now)).toBeNull();
  });

  it("첫 호출부터 추론량을 제한하고 그렇게 받은 답이라고 남긴다", async () => {
    const c = { ...config(['{"ok":true}']), deadline: Date.now() + 52_000 };
    const result = await completeJson(c, request);
    expect(c.bodies[0].reasoning).toEqual(high);
    expect(result.reasoningLimited).toBe(true);
  });

  it("형식이 깨져 다시 물을 때는 같은 제한으로 묻는다", async () => {
    const c = { ...config(["oops", '{"ok":true}']), deadline: Date.now() + 52_000 };
    expect((await completeJson(c, request)).data).toEqual({ ok: true });
    expect(c.bodies.map((body) => body.reasoning)).toEqual([high, high]);
  });

  it("제한했는데도 출력 한도를 넘기면 low로 줄여 다시 묻는다 (배경 처리는 그대로 high)", async () => {
    const c = { ...config([[null, "length"], '{"ok":true}']), deadline: Date.now() + 52_000 };
    const result = await completeJson(c, request);
    expect(c.bodies.map((body) => body.reasoning)).toEqual([high, low]);
    expect(result.reasoningLimited).toBe(true);

    const background = config([[null, "length"], '{"ok":true}']);
    await completeJson(background, request);
    expect(background.bodies.map((body) => body.reasoning)).toEqual([undefined, high]);
  });

  it("추론량 제한을 끄면(LLM_OVERRUN_REASONING_EFFORT=off) 마감이 있어도, 넘겨도 제한하지 않는다", async () => {
    const c = { ...config([[null, "length"], '{"ok":true}']), deadline: Date.now() + 52_000, overrunReasoning: null };
    const result = await completeJson(c, request);
    expect(c.bodies.map((body) => body.reasoning)).toEqual([undefined, undefined]);
    expect(result.reasoningLimited).toBeUndefined();
  });

  it("첫 시도가 빨리 실패하면 다시 묻기는 절반이 아니라 남은 시간을 다 받는다", async () => {
    const clock = fakeClock();
    const sent = timeouts();
    const c = { ...config(["oops", '{"ok":true}']), deadline: clock.now + 40_000 };
    const answer = c.fetch!;
    c.fetch = (async (url: string, init: RequestInit) => {
      clock.now += 10_000;
      return answer(url, init);
    }) as typeof fetch;
    await completeJson(c, request);
    // 첫 시도 20초(40초의 절반). 10초 만에 형식 오류 → 다시 묻기는 남은 30초 (절반 15초가 아니다)
    expect(sent()).toEqual([20_000, 30_000]);
  });

  it("첫 시도가 시간 초과면 다시 묻기는 남은 시간을 받고, 또 넘기면 그 한도를 적은 마감 오류", async () => {
    const clock = fakeClock();
    const sent = timeouts();
    let calls = 0;
    const c: LlmConfig = {
      apiKey: "key",
      model: "test/model",
      deadline: clock.now + 40_000,
      fetch: (async () => {
        calls++;
        clock.now += calls === 1 ? 20_000 : 18_000;
        throw new DOMException("timed out", "TimeoutError");
      }) as typeof fetch,
    };
    const error = await completeJson(c, request).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(DeadlineExceededError);
    expect((error as DeadlineExceededError).stage).toBe("llm");
    expect((error as Error).message).toContain("응답 시간 초과 (20초)");
    expect(sent()).toEqual([20_000, 20_000]);
  });

  it("남은 시간이 한 번 더 물을 만큼이 아니면 다시 묻지 않고 마감 오류로 끝낸다", async () => {
    const clock = fakeClock();
    const c = { ...config(["oops", '{"ok":true}']), deadline: clock.now + 40_000 };
    const answer = c.fetch!;
    c.fetch = (async (url: string, init: RequestInit) => {
      // 첫 시도가 형식이 깨진 답을 늦게 준다: 남은 시간이 최소 시간보다 1ms 모자란다
      clock.now += 40_000 - LLM_MIN_ATTEMPT_MS + 1;
      return answer(url, init);
    }) as typeof fetch;
    const error = await completeJson(c, request).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(DeadlineExceededError);
    expect((error as Error).message).toMatch(/다시 물을 시간 없음 \(JSON이 아닌 응답/);
    expect(c.bodies).toHaveLength(1);
  });

  it("마감까지 남은 시간이 없으면 부르지 않는다", async () => {
    const c = { ...config(['{"ok":true}']), deadline: Date.now() + LLM_MIN_ATTEMPT_MS - 1_000 };
    await expect(completeJson(c, request)).rejects.toBeInstanceOf(DeadlineExceededError);
    expect(c.bodies).toHaveLength(0);
  });

  describe("추론 옵션을 받는 공급자가 없다는 거절 (추론하지 않는 모델로 바꾸고 제한을 끄지 않음)", () => {
    const rejectBody = JSON.stringify({ error: { code: 404, message: "No endpoints found that can handle the requested parameters." } });

    /** 첫 요청은 status · body로 거절하고, 다음부터 답한다 */
    function rejectingFirst(status: number, body: string, deadline?: number): LlmConfig & { bodies: Record<string, unknown>[] } {
      const bodies: Record<string, unknown>[] = [];
      return {
        apiKey: "key",
        model: "test/model",
        deadline,
        bodies,
        fetch: (async (_url: string, init: RequestInit) => {
          bodies.push(JSON.parse(init.body as string));
          if (bodies.length === 1) return new Response(body, { status });
          return new Response(JSON.stringify({ model: "test/model", choices: [{ finish_reason: "stop", message: { content: '{"ok":true}' } }] }));
        }) as typeof fetch,
      };
    }

    it("마감이 있으면 한 번, 추론 옵션 없이 다시 묻고 제한하지 않은 답으로 남긴다", async () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
      const c = rejectingFirst(404, rejectBody, Date.now() + 52_000);
      const result = await completeJson(c, request);
      expect(result.data).toEqual({ ok: true });
      expect(c.bodies.map((body) => body.reasoning)).toEqual([high, undefined]);
      expect(result.reasoningLimited).toBeUndefined();
      expect(warn).toHaveBeenCalledWith(expect.stringContaining("LLM_OVERRUN_REASONING_EFFORT=off"));
    });

    it("다른 404(모델이 없음)나 배경 처리는 다시 묻지 않는다", async () => {
      const missingModel = rejectingFirst(404, JSON.stringify({ error: { code: 404, message: "No endpoints found for test/model." } }), Date.now() + 52_000);
      await expect(completeJson(missingModel, request)).rejects.toThrow("OpenRouter 요청 실패 (404)");
      expect(missingModel.bodies).toHaveLength(1);

      const background = rejectingFirst(404, rejectBody);
      await expect(completeJson(background, request)).rejects.toMatchObject({ kind: "unsupported_parameters" });
      expect(background.bodies).toHaveLength(1);
    });
  });
});
