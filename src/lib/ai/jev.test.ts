import { describe, expect, it } from "vitest";

import { decide, JevError, type JevConfig } from "./jev";

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
    expect(JSON.parse(c.requests[0].body as string)).toEqual({ model: "typesafe/jev-1.13", state: { a: 1 }, questions });
    expect((c.requests[0].headers as Record<string, string>).Authorization).toBe("Bearer key");
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
