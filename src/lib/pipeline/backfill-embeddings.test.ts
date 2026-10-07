import { AiBudgetError } from "@/lib/ai/budget-error";
import { describe, expect, it, vi } from "vitest";

import { backfillEmbeddings, EMBEDDING_BACKFILL_LIMIT, type EmbeddingBackfillStore, type UnembeddedAction } from "./backfill-embeddings";

function fakeStore(actions: UnembeddedAction[], options: { failRead?: boolean; failSave?: boolean } = {}) {
  const limits: number[] = [];
  const saved: [string, number[]][] = [];
  const store: EmbeddingBackfillStore = {
    unembedded: async (limit) => {
      limits.push(limit);
      if (options.failRead) throw new Error("select failed");
      return actions.slice(0, limit);
    },
    saveEmbedding: async (id, vector) => {
      if (options.failSave) throw new Error("update failed");
      saved.push([id, vector]);
    },
  };
  return { store, limits, saved };
}

const withQuote: UnembeddedAction = { id: "a1", title: "견적서 보내기", quote: "금요일까지 견적서 보내드릴게요" };
const titleOnly: UnembeddedAction = { id: "a2", title: "비밀 프로젝트 계약서 검토", quote: null };

describe("backfillEmbeddings", () => {
  it("임베딩이 없는 열린 Action을 한 번에 임베딩해 Action마다 채운다 (직접 추가와 같은 글)", async () => {
    const { store, limits, saved } = fakeStore([withQuote, titleOnly]);
    const texts: string[][] = [];
    const embed = async (batch: string[]) => {
      texts.push(batch);
      return batch.map((_, i) => [i, 1]);
    };
    expect(await backfillEmbeddings(store, embed)).toBe(2);
    expect(limits).toEqual([EMBEDDING_BACKFILL_LIMIT]);
    // 근거 구절이 있으면 후보와 같은 "제목\n구절", 원문 없이 추가했으면 제목만
    expect(texts).toEqual([["견적서 보내기\n금요일까지 견적서 보내드릴게요", "비밀 프로젝트 계약서 검토"]]);
    expect(saved).toEqual([
      ["a1", [0, 1]],
      ["a2", [1, 1]],
    ]);
  });

  it("한 번에 최대 20개까지만 (남은 것은 다음 처리가 채운다)", async () => {
    const many = Array.from({ length: 25 }, (_, i) => ({ id: `a${i}`, title: `할 일 ${i}`, quote: null }));
    const { store, saved } = fakeStore(many);
    expect(await backfillEmbeddings(store, async (batch) => batch.map(() => [1]))).toBe(20);
    expect(saved.map(([id]) => id)).toEqual(many.slice(0, 20).map((a) => a.id));
  });

  it("채울 것이 없으면 모델을 부르지 않는다", async () => {
    const { store } = fakeStore([]);
    const embed = vi.fn(async () => [] as number[][]);
    expect(await backfillEmbeddings(store, embed)).toBe(0);
    expect(embed).not.toHaveBeenCalled();
  });

  it.each([
    ["임베딩 실패", {}, "임베딩 요청 실패 (502)"],
    ["읽기 실패", { failRead: true }, "select failed"],
    ["쓰기 실패", { failSave: true }, "update failed"],
  ])("%s해도 던지지 않고(원문 처리를 막지 않는다), 로그에 제목 · 구절을 남기지 않는다", async (_label, options, message) => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { store, saved } = fakeStore([withQuote, titleOnly], options);
    const embed = async (batch: string[]) => {
      if (message.startsWith("임베딩")) throw new Error(message);
      return batch.map(() => [1]);
    };
    expect(await backfillEmbeddings(store, embed)).toBe(0);
    expect(saved).toEqual([]);
    expect(log).toHaveBeenCalledWith("임베딩 채우기 실패:", message);
    const logged = JSON.stringify(log.mock.calls);
    expect(logged).not.toContain("비밀 프로젝트");
    expect(logged).not.toContain("견적서");
    log.mockRestore();
  });
});

it("propagates budget stops instead of continuing with incomplete match evidence", async () => {
  const { store } = fakeStore([withQuote]);
  const error = new AiBudgetError("ai_user_daily_budget_exhausted");
  await expect(backfillEmbeddings(store, async () => { throw error; })).rejects.toBe(error);
});
