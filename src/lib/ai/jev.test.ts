import { describe, expect, it, vi } from "vitest";

import { decide, jevConfigFromEnv, JevError, type JevConfig } from "./jev";

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

  it("마감이 있으면(빠진 할 일 신고) 남은 시간이 없을 때 묻지도 다시 묻지도 않는다", async () => {
    let calls = 0;
    const late: JevConfig = {
      apiKey: "key",
      model: "m",
      deadline: Date.now() - 1,
      fetch: (async () => {
        calls++;
        return new Response(JSON.stringify({ model: "m", answers: { ok: { type: "noul", noul: 0.5 } } }));
      }) as typeof fetch,
    };
    await expect(decide(late, { state: {}, questions })).rejects.toThrow(/남은 시간 없음/);
    expect(calls).toBe(0);

    // 첫 요청이 마감까지 멈췄으면 다시 묻지 않는다
    const clock = { now: 1_000_000 };
    const spy = vi.spyOn(Date, "now").mockImplementation(() => clock.now);
    try {
      const stuck: JevConfig = {
        apiKey: "key",
        model: "m",
        deadline: clock.now + 10_000,
        fetch: (async () => {
          calls++;
          clock.now += 10_000;
          throw new DOMException("timed out", "TimeoutError");
        }) as typeof fetch,
      };
      await expect(decide(stuck, { state: {}, questions })).rejects.toBeInstanceOf(JevError);
      expect(calls).toBe(1);

      // 다시 묻기는 남은 시간(40 − 30 = 10초)만 기다리고, 오류에 그 한도를 적는다
      const slow: JevConfig = {
        apiKey: "key",
        model: "m",
        deadline: clock.now + 40_000,
        fetch: (async () => {
          clock.now += 30_000;
          throw new DOMException("timed out", "TimeoutError");
        }) as typeof fetch,
      };
      await expect(decide(slow, { state: {}, questions })).rejects.toThrow("Decisions API 응답 시간 초과 (10초)");
    } finally {
      spy.mockRestore();
    }
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
