import { describe, expect, it } from "vitest";

import { loginCodeErrorMessage } from "./errors";

describe("loginCodeErrorMessage", () => {
  it("발송 한도 초과를 알려준다 (Resend 하루 한도도 같은 429)", () => {
    expect(loginCodeErrorMessage({ code: "over_email_send_rate_limit", status: 429 })).toMatch(/한도/);
  });

  it("키 오류를 알려준다", () => {
    expect(loginCodeErrorMessage({ code: undefined, status: 401 })).toMatch(/PUBLISHABLE_KEY/);
  });

  it("연결 실패는 URL을 확인하라고 한다", () => {
    expect(loginCodeErrorMessage({ code: undefined, status: undefined })).toMatch(/SUPABASE_URL/);
  });

  it("모르는 오류는 터미널 로그를 보라고 한다 (링크가 아니라 코드를 보내지 못했다고)", () => {
    const message = loginCodeErrorMessage({ code: "unexpected_failure", status: 500 });
    expect(message).toMatch(/터미널/);
    expect(message).toMatch(/코드/);
    expect(message).not.toMatch(/링크/);
  });

  it("이메일 로그인이 꺼져 있으면 Email 제공자를 켜라고 한다", () => {
    expect(loginCodeErrorMessage({ code: "email_provider_disabled", status: 422 })).toMatch(/Email/);
  });
});
