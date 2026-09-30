import { afterEach, describe, expect, it, vi } from "vitest";

import { DeadlineExceededError, MIN_REQUEST_MS } from "./deadline";
import { decide, JEV_DEADLINE_FIRST_MS, JEV_TIMEOUT_MS, jevConfigFromEnv, JevError, jevTimeoutMs, type JevConfig } from "./jev";

function config(body: unknown, status = 200): JevConfig & { requests: RequestInit[] } {
  const requests: RequestInit[] = [];
  return {
    apiKey: "key",
    model: "typesafe/jev-1.13",
    requests,
    fetch: (async (_url: string, init: RequestInit) => {
      requests.push(init);
      return new Response(typeof body === "string" ? body : JSON.stringify(body), { status });
    }) as typeof fetch,
  };
}

const questions = { ok: { type: "noul" as const, instructions: "?" } };

describe("decide", () => {
  it("모델 · state · questions를 보내고 답을 검증해 돌려준다", async () => {
    const c = config({ model: "typesafe/jev-1.13-x", answers: { ok: { type: "noul", noul: 0.7 } } });
    const result = await decide(c, { state: { a: 1 }, questions });
    expect(result.answers.ok).toEqual({ type: "noul", noul: 0.7 });
    expect(JSON.parse(c.requests[0].body as string)).toEqual({
      model: "typesafe/jev-1.13",
      state: { a: 1 },
      questions,
      provider: { data_collection: "deny", zdr: true },
    });
    expect((c.requests[0].headers as Record<string, string>).Authorization).toBe("Bearer key");
  });

  it("공급자를 TypeSafe로 고정해 보낸다 (환경변수 JEV_PROVIDERS, 비우면 typesafe)", async () => {
    const cfg = jevConfigFromEnv({ OPENROUTER_API_KEY: "k", JEV_MODEL: "typesafe/jev-1.13" });
    expect(cfg.providers).toEqual(["typesafe"]);
    const c = { ...config({ model: "m", answers: { ok: { type: "noul", noul: 0.5 } } }), providers: cfg.providers };
    await decide(c, { state: {}, questions });
    expect(JSON.parse(c.requests[0].body as string).provider).toEqual({
      data_collection: "deny",
      zdr: true,
      only: ["typesafe"],
      order: ["typesafe"],
      allow_fallbacks: false,
    });
  });

  it("시간 초과는 한 번 다시 묻고, 또 넘기면 JevError", async () => {
    let calls = 0;
    const flaky: JevConfig = {
      apiKey: "key",
      model: "m",
      fetch: (async () => {
        if (calls++ === 0) throw new DOMException("timed out", "TimeoutError");
        return new Response(JSON.stringify({ model: "m", answers: { ok: { type: "noul", noul: 0.5 } } }));
      }) as typeof fetch,
    };
    expect((await decide(flaky, { state: {}, questions })).answers.ok).toEqual({ type: "noul", noul: 0.5 });
    expect(calls).toBe(2);

    const stuck: JevConfig = {
      apiKey: "key",
      model: "m",
      fetch: (async () => {
        throw new DOMException("timed out", "TimeoutError");
      }) as typeof fetch,
    };
    await expect(decide(stuck, { state: {}, questions })).rejects.toThrow(/시간 초과/);
  });

  describe("마감이 있으면(빠진 할 일 신고)", () => {
    afterEach(() => {
      vi.restoreAllMocks();
    });

    /** Date.now를 가짜 시계로 바꾸고, 요청마다 준 시간 한도(AbortSignal.timeout에 넘긴 값)를 모은다 */
    function fakeClock(start = 1_000_000) {
      const clock = { now: start };
      vi.spyOn(Date, "now").mockImplementation(() => clock.now);
      const spy = vi.spyOn(AbortSignal, "timeout");
      return { clock, sent: () => spy.mock.calls.map(([ms]) => ms) };
    }

    it("첫 요청은 남은 시간의 절반과 10초 중 짧은 쪽, 다시 묻기는 남은 시간. 1초가 안 남으면 묻지 않는다", () => {
      const now = 0;
      expect(jevTimeoutMs({}, true, now)).toBe(JEV_TIMEOUT_MS);
      expect(jevTimeoutMs({ deadline: 40_000 }, true, now)).toBe(JEV_DEADLINE_FIRST_MS);
      expect(jevTimeoutMs({ deadline: 12_000 }, true, now)).toBe(6_000);
      expect(jevTimeoutMs({ deadline: 12_000 }, false, now)).toBe(12_000);
      expect(jevTimeoutMs({ deadline: 60_000 }, false, now)).toBe(JEV_TIMEOUT_MS);
      // 둘로 나눌 만큼 남지 않았으면 첫 요청에 남은 시간을 다 준다
      expect(jevTimeoutMs({ deadline: 1_500 }, true, now)).toBe(1_500);
      expect(jevTimeoutMs({ deadline: MIN_REQUEST_MS - 1 }, true, now)).toBeNull();
    });

    it("남은 시간이 1초가 안 되면 부르지 않는다", async () => {
      const c = { ...config({ model: "m", answers: { ok: { type: "noul", noul: 0.5 } } }), deadline: Date.now() + MIN_REQUEST_MS - 1 };
      const error = await decide(c, { state: {}, questions }).catch((e: unknown) => e);
      expect(error).toBeInstanceOf(DeadlineExceededError);
      expect((error as DeadlineExceededError).stage).toBe("jev");
      expect(c.requests).toHaveLength(0);
    });

    it("첫 요청이 멈추면 남은 시간으로 다시 묻고, 또 넘기면 그 시도의 실제 한도를 적은 마감 오류", async () => {
      const { clock, sent } = fakeClock();
      const slow: JevConfig = {
        apiKey: "key",
        model: "m",
        deadline: clock.now + 40_000,
        fetch: (async () => {
          clock.now += sent().length === 1 ? 10_000 : 30_000;
          throw new DOMException("timed out", "TimeoutError");
        }) as typeof fetch,
      };
      const error = await decide(slow, { state: {}, questions }).catch((e: unknown) => e);
      // 첫 요청 10초(상한), 다시 묻기는 남은 30초
      expect(sent()).toEqual([10_000, 30_000]);
      expect(error).toBeInstanceOf(DeadlineExceededError);
      expect((error as Error).message).toContain("Decisions API 응답 시간 초과 (30초)");
    });

    it("첫 요청이 마감 가까이까지 멈췄으면 다시 묻지 않는다", async () => {
      const { clock, sent } = fakeClock();
      const stuck: JevConfig = {
        apiKey: "key",
        model: "m",
        deadline: clock.now + 3_000,
        fetch: (async () => {
          clock.now += 2_500;
          throw new DOMException("timed out", "TimeoutError");
        }) as typeof fetch,
      };
      await expect(decide(stuck, { state: {}, questions })).rejects.toThrow(/다시 물을 시간 없음/);
      // 첫 요청은 1.5초(3초의 절반). 끝났을 때 남은 0.5초는 1초가 안 되어 다시 묻지 않는다
      expect(sent()).toEqual([1_500]);
    });
  });

  it("HTTP 오류는 JevError", async () => {
    await expect(decide(config("nope", 500), { state: {}, questions })).rejects.toBeInstanceOf(JevError);
  });

  it("답이 빠지거나 형식이 다르면 JevError", async () => {
    await expect(decide(config({ model: "m", answers: {} }), { state: {}, questions })).rejects.toThrow(/답이 없는 질문/);
    await expect(
      decide(config({ model: "m", answers: { ok: { type: "choice", choice: "a", probabilities: {} } } }), { state: {}, questions }),
    ).rejects.toThrow(/형식이 다릅니다/);
    await expect(decide(config({ model: "m", answers: { ok: { type: "noul", noul: 3 } } }), { state: {}, questions })).rejects.toThrow(
      /응답 형식/,
    );
  });
});
