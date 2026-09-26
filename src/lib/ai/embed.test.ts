import { describe, expect, it } from "vitest";

import { cosine, embed, EMBEDDING_DIMENSIONS, EmbedError, type EmbedConfig } from "./embed";

const vec = (x: number) => Array.from({ length: EMBEDDING_DIMENSIONS }, (_, i) => (i === 0 ? x : 0));

function config(body: unknown, status = 200): EmbedConfig & { sent: unknown[] } {
  const sent: unknown[] = [];
  return {
    apiKey: "k",
    model: "m",
    sent,
    fetch: (async (_url: string, init: RequestInit) => {
      sent.push(JSON.parse(init.body as string));
      return new Response(JSON.stringify(body), { status });
    }) as typeof fetch,
  };
}

describe("embed", () => {
  it("입력 순서대로 벡터를 돌려준다", async () => {
    const c = config({ data: [{ index: 1, embedding: vec(2) }, { index: 0, embedding: vec(1) }] });
    const { vectors } = await embed(c, ["a", "b"]);
    expect(vectors.map((v) => v[0])).toEqual([1, 2]);
    expect(c.sent[0]).toMatchObject({ model: "m", input: ["a", "b"], provider: { data_collection: "deny" } });
  });

  it("차원이 다르면 오류", async () => {
    await expect(embed(config({ data: [{ index: 0, embedding: [1, 2] }] }), ["a"])).rejects.toBeInstanceOf(EmbedError);
  });

  it("빈 입력은 호출하지 않는다", async () => {
    const c = config({});
    expect(await embed(c, [])).toEqual({ vectors: [] });
    expect(c.sent).toEqual([]);
  });
});

describe("cosine", () => {
  it("같은 방향 1, 직교 0", () => {
    expect(cosine([1, 0], [2, 0])).toBeCloseTo(1);
    expect(cosine([1, 0], [0, 3])).toBeCloseTo(0);
    expect(cosine([0, 0], [1, 0])).toBe(0);
  });
});
