import { describe, expect, it } from "vitest";

import { maskEmail } from "./errors";

describe("maskEmail", () => {
  it("대소문자와 상관없이 모든 자리의 주소를 <email>로 가린다", () => {
    expect(maskEmail("limit for Operator@EXAMPLE.com and operator@example.com, OPERATOR@example.COM.", "operator@example.com")).toBe(
      "limit for <email> and <email>, <email>.",
    );
  });

  it("주소의 점 · 더하기는 글자 그대로 본다 (정규식 문자로 읽지 않는다)", () => {
    expect(maskEmail("a.b+c@example.com / aXb+c@example.com / a.bbc@example.com", "a.b+c@example.com")).toBe(
      "<email> / aXb+c@example.com / a.bbc@example.com",
    );
  });

  it("주소가 없으면 글을 그대로 둔다", () => {
    expect(maskEmail("Token has expired", "operator@example.com")).toBe("Token has expired");
  });
});
