import { afterEach, describe, expect, it, vi } from "vitest";

import { DeadlineExceededError, MIN_REQUEST_MS } from "./deadline";
import { cosine, embed, embedConfigFromEnv, EMBEDDING_DIMENSIONS, EmbedError, type EmbedConfig } from "./embed";

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
    expect(c.sent[0]).toMatchObject({ model: "m", input: ["a", "b"], provider: { data_collection: "deny", zdr: true } });
  });

  it("공급자를 Azure(ZDR)로 고정해 보낸다 (환경변수 EMBED_PROVIDERS, 비우면 azure)", async () => {
    const cfg = embedConfigFromEnv({ OPENROUTER_API_KEY: "k" });
    expect(cfg.providers).toEqual(["azure"]);
    const c = { ...config({ data: [{ index: 0, embedding: vec(1) }] }), providers: cfg.providers };
    await embed(c, ["a"]);
    expect((c.sent[0] as { provider: unknown }).provider).toEqual({ data_collection: "deny", zdr: true, only: ["azure"], order: ["azure"], allow_fallbacks: false });
  });

  it("차원이 다르면 오류", async () => {
    await expect(embed(config({ data: [{ index: 0, embedding: [1, 2] }] }), ["a"])).rejects.toBeInstanceOf(EmbedError);
  });

  describe("마감이 있으면(빠진 할 일 신고 · 물어보기)", () => {
    afterEach(() => {
      vi.restoreAllMocks();
    });

    it("시간 한도를 남은 시간까지로 줄인다 (마감이 없으면 30초)", async () => {
      vi.spyOn(Date, "now").mockReturnValue(1_000_000);
      const sent = vi.spyOn(AbortSignal, "timeout");
      await embed({ ...config({ data: [{ index: 0, embedding: vec(1) }] }), deadline: 1_000_000 + 7_000 }, ["a"]);
      await embed({ ...config({ data: [{ index: 0, embedding: vec(1) }] }), deadline: 1_000_000 + 60_000 }, ["a"]);
      await embed(config({ data: [{ index: 0, embedding: vec(1) }] }), ["a"]);
      expect(sent.mock.calls.map(([ms]) => ms)).toEqual([7_000, 30_000, 30_000]);
    });

    it("1초가 안 남았으면 부르지 않는다", async () => {
      const c = { ...config({ data: [{ index: 0, embedding: vec(1) }] }), deadline: Date.now() + MIN_REQUEST_MS - 1 };
      const error = await embed(c, ["a"]).catch((e: unknown) => e);
      expect(error).toBeInstanceOf(DeadlineExceededError);
      expect((error as DeadlineExceededError).stage).toBe("embed");
      expect(c.sent).toEqual([]);
    });

    it("줄인 시간 한도를 넘기면 마감 오류 (마감이 없으면 원래 오류 그대로)", async () => {
      const timedOut = (async () => {
        throw new DOMException("timed out", "TimeoutError");
      }) as typeof fetch;
      await expect(embed({ apiKey: "k", model: "m", fetch: timedOut, deadline: Date.now() + 5_000 }, ["a"])).rejects.toBeInstanceOf(DeadlineExceededError);
      await expect(embed({ apiKey: "k", model: "m", fetch: timedOut }, ["a"])).rejects.toBeInstanceOf(DOMException);
    });
  });

  it("머리글 뒤 본문을 읽다가 시간 한도가 울리면: 마감이 있으면 마감 오류, 없으면 원래 오류 그대로", async () => {
    const bodyTimesOut = (async () =>
      ({ ok: true, status: 200, json: async () => { throw new DOMException("timed out", "TimeoutError"); } }) as unknown as Response) as typeof fetch;
    await expect(embed({ apiKey: "k", model: "m", fetch: bodyTimesOut, deadline: Date.now() + 20_000 }, ["a"])).rejects.toBeInstanceOf(DeadlineExceededError);
    await expect(embed({ apiKey: "k", model: "m", fetch: bodyTimesOut }, ["a"])).rejects.toBeInstanceOf(DOMException);
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
