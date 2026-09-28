import { describe, expect, it } from "vitest";

import { magicLinkErrorMessage } from "./errors";

describe("magicLinkErrorMessage", () => {
  it("발송 한도 초과를 알려준다", () => {
    expect(magicLinkErrorMessage({ code: "over_email_send_rate_limit", status: 429 })).toMatch(/한도/);
  });

  it("키 오류를 알려준다", () => {
    expect(magicLinkErrorMessage({ code: undefined, status: 401 })).toMatch(/PUBLISHABLE_KEY/);
  });

  it("연결 실패는 URL을 확인하라고 한다", () => {
    expect(magicLinkErrorMessage({ code: undefined, status: undefined })).toMatch(/SUPABASE_URL/);
  });

  it("모르는 오류는 터미널 로그를 보라고 한다", () => {
    expect(magicLinkErrorMessage({ code: "unexpected_failure", status: 500 })).toMatch(/터미널/);
  });
});
