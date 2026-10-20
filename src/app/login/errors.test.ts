import { describe, expect, it } from "vitest";

import { loginCodeErrorMessage, maskEmail } from "./errors";

// 화면에 보이는 문구에는 내부 설정 안내(.env · 대시보드 · 공급자 이름 · 문서 경로)를 싣지 않는다. 원인은 서버 로그(code · status)로 본다.
const INTERNAL = /\.env|NEXT_PUBLIC|PUBLISHABLE|SUPABASE_URL|Supabase|Resend|\bPro\b|runbook|docs\/|터미널|대시보드|Authentication|Providers/;

describe("loginCodeErrorMessage", () => {
  it("발송 한도 초과를 알려준다 (Resend 하루 한도도 같은 429)", () => {
    expect(loginCodeErrorMessage({ code: "over_email_send_rate_limit", status: 429 })).toMatch(/한도/);
  });

  it("보낼 수 없는 주소는 주소를 보낼 수 없다고만 알린다", () => {
    expect(loginCodeErrorMessage({ code: "email_address_invalid", status: 400 })).toMatch(/이메일 주소/);
    expect(loginCodeErrorMessage({ code: "email_address_not_authorized", status: 400 })).toMatch(/이메일 주소/);
  });

  it("이메일 로그인이 꺼져 있으면 쓸 수 없다고만 알린다", () => {
    expect(loginCodeErrorMessage({ code: "email_provider_disabled", status: 422 })).toMatch(/이메일 로그인/);
  });

  it("키 오류 · 연결 실패 · 모르는 오류는 모두 같은 일반 문구다 (링크가 아니라 코드를 보내지 못했다고)", () => {
    const generic = loginCodeErrorMessage({ code: "unexpected_failure", status: 500 });
    expect(generic).toMatch(/코드/);
    expect(generic).not.toMatch(/링크/);
    expect(loginCodeErrorMessage({ code: undefined, status: 401 })).toBe(generic);
    expect(loginCodeErrorMessage({ code: undefined, status: 403 })).toBe(generic);
    expect(loginCodeErrorMessage({ code: undefined, status: undefined })).toBe(generic);
  });

  it("어떤 오류 문구에도 내부 설정 안내가 없다", () => {
    const errors = [
      { code: "over_email_send_rate_limit", status: 429 },
      { code: "email_address_invalid", status: 400 },
      { code: "email_address_not_authorized", status: 400 },
      { code: "email_provider_disabled", status: 422 },
      { code: undefined, status: 401 },
      { code: undefined, status: 403 },
      { code: undefined, status: undefined },
      { code: "unexpected_failure", status: 500 },
    ];
    for (const error of errors) expect(loginCodeErrorMessage(error), JSON.stringify(error)).not.toMatch(INTERNAL);
  });
});

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
