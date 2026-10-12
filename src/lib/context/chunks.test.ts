import { describe, expect, it, vi } from "vitest";

import { withConsentGate } from "@/lib/consent/gate";

import { CHUNK_MAX_CHARS, CHUNK_MIN_CHARS, chunkText, EMBED_BATCH, indexSourceChunks, MAX_CHUNKS_PER_SOURCE, type ChunkIndexDeps } from "./chunks";

// 원문 조각 (아키텍처 6.2): 1–2k자로 나누기, gate · 동의 · Slack을 먼저 보고, 임베딩은 주입한 가짜(결정적)로만.

const ON = { SOURCE_CHUNKS_ENABLED: "true" };
const fakeVector = (seed: number) => Array.from({ length: 1536 }, (_, i) => (i === seed % 1536 ? 1 : 0));

function deps(overrides: Partial<ChunkIndexDeps> = {}) {
  const embed = vi.fn(async (texts: string[]) => texts.map((_, i) => fakeVector(i)));
  const replace = vi.fn(async (_userId: string, _sourceId: string, chunks: { text: string; embedding: number[] }[]) => ({ status: "replaced", chunks: chunks.length }));
  return { embed, replace, deps: { embed, replace, ...overrides } as ChunkIndexDeps };
}

const source = { userId: "u1", sourceId: "s1", text: "회의록에 적힌 안건과 결정.\n\n".repeat(400), provider: "notion", externalUrl: "https://notion.so/page" };

describe("chunkText", () => {
  it("짧은 글은 한 조각, 빈 글은 없음", () => {
    expect(chunkText("  짧은 메모  ")).toEqual(["짧은 메모"]);
    expect(chunkText(" \n ")).toEqual([]);
    expect(chunkText("가".repeat(CHUNK_MAX_CHARS))).toHaveLength(1);
  });

  it("긴 글은 마지막 두 조각을 빼면 1–2k자이고, 모든 조각이 2k자 이하이며 이어 붙이면 원문의 글자를 잃지 않는다", () => {
    const paragraphs = Array.from({ length: 40 }, (_, i) => `${i}번 안건: ${"출시 준비와 디자인 확정 일정을 논의했다. ".repeat(6)}`);
    const text = paragraphs.join("\n\n");
    const chunks = chunkText(text);
    expect(chunks.length).toBeGreaterThan(3);
    for (const chunk of chunks) expect(chunk.length).toBeLessThanOrEqual(CHUNK_MAX_CHARS);
    for (const chunk of chunks.slice(0, -2)) expect(chunk.length).toBeGreaterThanOrEqual(CHUNK_MIN_CHARS);
    expect(chunks.join("").replace(/\s/g, "")).toBe(text.replace(/\s/g, ""));
    // 문단 경계에서 끊는다
    for (const chunk of chunks.slice(0, -1)) expect(chunk).toMatch(/다\.$/);
  });

  it("끊을 자리가 없으면 2k자에서 자르되 대리 쌍(이모지)을 가르지 않고, 끝에 아주 짧은 조각만 남기지 않는다", () => {
    const emoji = "😀".repeat(1500); // 3,000 UTF-16 단위
    const chunks = chunkText(emoji);
    for (const chunk of chunks) {
      expect(chunk.length).toBeLessThanOrEqual(CHUNK_MAX_CHARS);
      expect(chunk).not.toMatch(/^[\udc00-\udfff]|[\ud800-\udbff]$/);
    }
    expect(chunks.join("")).toBe(emoji);
    const sizes = chunkText("가".repeat(2100)).map((c) => c.length);
    expect(Math.min(...sizes)).toBeGreaterThanOrEqual(700);
    // 끊을 자리가 앞쪽에만 있어도 제목 한 줄만 따로 떨어지지 않는다
    const titled = chunkText(`제목\n\n${"가".repeat(2300)}`).map((c) => c.length);
    expect(Math.min(...titled)).toBeGreaterThanOrEqual(700);
  });
});

describe("indexSourceChunks", () => {
  it("gate가 꺼져 있으면 임베딩 · 저장을 부르지 않는다", async () => {
    const { embed, replace, deps: d } = deps();
    expect(await indexSourceChunks(d, source, {})).toEqual({ status: "gate_off", chunks: 0 });
    expect(await indexSourceChunks(d, source, { SOURCE_CHUNKS_ENABLED: "1" })).toEqual({ status: "gate_off", chunks: 0 });
    expect(embed).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
  });

  it("Slack 원문 · 빈 글은 만들지 않는다", async () => {
    const { embed, replace, deps: d } = deps();
    expect(await indexSourceChunks(d, { ...source, provider: "slack" }, ON)).toEqual({ status: "slack", chunks: 0 });
    expect(await indexSourceChunks(d, { ...source, provider: null, externalUrl: "https://acme.slack.com/archives/C1/p2" }, ON)).toEqual({ status: "slack", chunks: 0 });
    expect(await indexSourceChunks(d, { ...source, text: "   " }, ON)).toEqual({ status: "empty", chunks: 0 });
    expect(embed).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
  });

  it("동의가 없으면(withConsentGate) 모델을 부르지 않고 저장도 하지 않는다", async () => {
    const { embed, replace } = deps();
    const gated = withConsentGate({ embed }, async () => false);
    expect(await indexSourceChunks({ embed: gated.embed!, replace }, source, ON)).toEqual({ status: "no_consent", chunks: 0 });
    expect(embed).not.toHaveBeenCalled();
    expect(replace).not.toHaveBeenCalled();
  });

  it("조각마다 임베딩을 붙여 한 번에 바꾼다. 개수 · 차원이 다르면 저장하지 않는다", async () => {
    const { embed, replace, deps: d } = deps();
    const result = await indexSourceChunks(d, source, ON);
    const texts = chunkText(source.text);
    expect(result).toEqual({ status: "replaced", chunks: texts.length });
    expect(embed).toHaveBeenCalledWith(texts);
    expect(replace).toHaveBeenCalledTimes(1);
    expect(replace.mock.calls[0][2].map((c) => c.text)).toEqual(texts);
    expect(replace.mock.calls[0][2][1].embedding).toEqual(fakeVector(1));

    const short = deps({ embed: async () => [fakeVector(0).slice(0, 10)] });
    await expect(indexSourceChunks(short.deps, { ...source, text: "짧은 원문" }, ON)).rejects.toThrow(/차원/);
    expect(short.replace).not.toHaveBeenCalled();
  });

  it("긴 원문은 조각 수 상한까지만, 임베딩은 묶음으로 나눠 부른다", async () => {
    const { embed, replace, deps: d } = deps();
    const huge = { ...source, text: "회의록에 적힌 안건과 결정을 길게 적었다.\n\n".repeat(30_000) };
    const result = await indexSourceChunks(d, huge, ON);
    expect(result).toEqual({ status: "replaced", chunks: MAX_CHUNKS_PER_SOURCE });
    expect(embed.mock.calls.map((call) => call[0].length)).toEqual([EMBED_BATCH, EMBED_BATCH, EMBED_BATCH, MAX_CHUNKS_PER_SOURCE - 3 * EMBED_BATCH]);
    expect(replace.mock.calls[0][2]).toHaveLength(MAX_CHUNKS_PER_SOURCE);
  });

  it("지운 원문 · 더 새 revision이면 DB가 넣지 않은 결과를 그대로 돌려준다", async () => {
    for (const status of ["purged", "stale"]) {
      const { deps: d } = deps({ replace: async () => ({ status, chunks: 0 }) });
      expect(await indexSourceChunks(d, source, ON)).toEqual({ status, chunks: 0 });
    }
  });
});
