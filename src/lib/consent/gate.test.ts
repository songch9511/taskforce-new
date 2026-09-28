import { describe, expect, it } from "vitest";
import { z } from "zod";

import type { CompleteJson } from "@/lib/pipeline/extract";
import type { Decide } from "@/lib/pipeline/judge";

import { assertConsent, ConsentRequiredError, withConsentGate } from "./gate";

function fakeDeps() {
  const calls: string[] = [];
  const complete = (async () => {
    calls.push("complete");
    return { data: { ok: true }, model: "m" };
  }) as unknown as CompleteJson;
  const decide: Decide = async () => {
    calls.push("decide");
    return { model: "jev", answers: {} };
  };
  const embed = async (texts: string[]) => {
    calls.push("embed");
    return texts.map(() => [1]);
  };
  const retrieve = async () => {
    calls.push("retrieve");
    return [];
  };
  return { calls, deps: { complete, decide, embed, retrieve } };
}

const request = { system: "s", user: "u", schemaName: "t", schema: z.object({ ok: z.boolean() }) };

describe("withConsentGate", () => {
  it("동의한 동안에는 모델 호출을 그대로 넘기고, 호출마다 동의를 확인한다", async () => {
    const { calls, deps } = fakeDeps();
    let checks = 0;
    const gated = withConsentGate(deps, async () => {
      checks++;
      return true;
    });
    await gated.complete(request);
    await gated.decide({ state: {}, questions: {} });
    await gated.embed(["a"]);
    expect(calls).toEqual(["complete", "decide", "embed"]);
    expect(checks).toBe(3);
  });

  it("도중에 철회하면 다음 모델 호출부터 부르지 않고 ConsentRequiredError", async () => {
    const { calls, deps } = fakeDeps();
    let consented = true;
    const gated = withConsentGate(deps, async () => consented);
    await gated.embed(["first"]);
    consented = false;
    await expect(gated.complete(request)).rejects.toBeInstanceOf(ConsentRequiredError);
    await expect(gated.decide({ state: {}, questions: {} })).rejects.toBeInstanceOf(ConsentRequiredError);
    await expect(gated.embed(["second"])).rejects.toBeInstanceOf(ConsentRequiredError);
    expect(calls).toEqual(["embed"]);
  });

  it("모델 호출이 아닌 함수(retrieve 등)는 감싸지 않고, 없는 함수는 만들지 않는다", async () => {
    const { calls, deps } = fakeDeps();
    const gated = withConsentGate({ retrieve: deps.retrieve, embed: deps.embed }, async () => false);
    await gated.retrieve();
    expect(calls).toEqual(["retrieve"]);
    expect("complete" in gated).toBe(false);
  });

  it("확인 자체가 실패하면(DB 오류) 모델을 부르지 않는다", async () => {
    const { calls, deps } = fakeDeps();
    const gated = withConsentGate(deps, async () => {
      throw new Error("db down");
    });
    await expect(gated.embed(["a"])).rejects.toThrow("db down");
    expect(calls).toEqual([]);
  });
});

describe("assertConsent", () => {
  it("동의가 없으면 던진다", async () => {
    await expect(assertConsent(async () => false)).rejects.toThrow("외부 AI 처리 동의가 없어 처리하지 않았어요.");
    await expect(assertConsent(async () => true)).resolves.toBeUndefined();
  });
});
