import { describe, expect, it } from "vitest";

import { scrubSecrets } from "./scrub";

// 시험용 모양 값이다 (실제 키가 아니다): sk-or- 접두 + 뜻 없는 글자. 실제 키 형식(16진수 64자)은 일부러 피했다
const SHAPE = "sk-or-v1-notarealkeynotarealkeynotarealkeynotarealkeynotarealkeynotarealkey";

describe("scrubSecrets", () => {
  it("OpenRouter 키 모양을 sk-or-[가림]으로 바꾼다", () => {
    expect(scrubSecrets(`Invalid key ${SHAPE} for this request`)).toBe("Invalid key sk-or-[가림] for this request");
  });

  it("JSON 본문 안의 키도 따옴표 앞에서 끝나게 바꾼다", () => {
    const body = JSON.stringify({ error: { message: `User key ${SHAPE}`, metadata: { key: SHAPE } } });
    const scrubbed = scrubSecrets(body);
    expect(scrubbed).not.toContain(SHAPE);
    expect(scrubbed).not.toContain("notarealkey");
    expect(JSON.parse(scrubbed)).toEqual({ error: { message: "User key sk-or-[가림]", metadata: { key: "sk-or-[가림]" } } });
  });

  it("여러 번 나와도, 대문자 접두여도 모두 바꾼다", () => {
    const scrubbed = scrubSecrets(`${SHAPE} and ${SHAPE.toUpperCase()} and ${SHAPE}`);
    expect(scrubbed).toBe("sk-or-[가림] and sk-or-[가림] and sk-or-[가림]");
  });

  it("끊긴 앞부분(접두 + 몇 글자)도 남기지 않는다", () => {
    expect(scrubSecrets("cut sk-or-v1-0123")).toBe("cut sk-or-[가림]");
    expect(scrubSecrets("cut sk-or-")).toBe("cut sk-or-[가림]");
  });

  it("키가 없는 글은 그대로 둔다", () => {
    for (const text of ["", "No endpoints found for model", "sk-orange is not a key", "sk_or_underscore"]) expect(scrubSecrets(text)).toBe(text);
  });

  it("500자 경계에 걸린 키도 앞부분이 남지 않는다", () => {
    const text = `${"x".repeat(490)}${SHAPE}`;
    expect(scrubSecrets(text).slice(0, 500)).not.toMatch(/sk-or-v1/);
  });
});
