import { describe, expect, it } from "vitest";

import { accountSettings, googleSettingsSchema } from "./settings";

// Google 연결 설정: 연결한 계정 · 범위 (docs/go-live/google-integration.md 2-3). 설정에 합치기 · 통계 더하기는 DB 함수가 한다 (tests/db/connection-settings.test.ts).

describe("accountSettings", () => {
  it("연결할 때 바꿀 키는 계정 · 범위뿐이다 (통계 등 나머지 값은 넘기지 않는다)", () => {
    const set = accountSettings({ sub: "new-sub", email: "me@company.dev" }, ["openid"]);
    expect(set).toEqual({ googleUserId: "new-sub", email: "me@company.dev", scopes: ["openid"] });
    expect(googleSettingsSchema.safeParse(set).success).toBe(true);
  });

  it("주소를 모르면 email null", () => {
    expect(accountSettings({ sub: "s", email: null }, [])).toEqual({ googleUserId: "s", email: null, scopes: [] });
  });
});
