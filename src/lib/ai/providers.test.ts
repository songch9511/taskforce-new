import { describe, expect, it } from "vitest";

import { DEFAULT_LLM_PROVIDERS, parseProviders, providerRouting } from "./providers";

describe("parseProviders", () => {
  it("쉼표로 나누고 다듬는다 (소문자, 중복 제거, 순서 유지)", () => {
    expect(parseProviders(" Together, deepinfra ,together,", DEFAULT_LLM_PROVIDERS)).toEqual(["together", "deepinfra"]);
  });

  it("비어 있으면 기본 목록 (고정을 끌 수 없다)", () => {
    expect(parseProviders(undefined, ["azure"])).toEqual(["azure"]);
    expect(parseProviders(" , ", ["azure"])).toEqual(["azure"]);
  });
});

describe("providerRouting", () => {
  it("목록의 공급자만, 그 순서로, 넘어가지 않게 + ZDR · 저장 금지", () => {
    expect(providerRouting(["together", "fireworks"])).toEqual({
      data_collection: "deny",
      zdr: true,
      only: ["together", "fireworks"],
      order: ["together", "fireworks"],
      allow_fallbacks: false,
    });
  });

  it("목록이 없어도 ZDR · 저장 금지는 항상 보낸다", () => {
    expect(providerRouting(undefined)).toEqual({ data_collection: "deny", zdr: true });
  });
});
