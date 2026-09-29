import { describe, expect, it } from "vitest";

import { googleSettingsSchema, withAccount, withStats } from "./settings";

// Google 연결 설정: 연결한 계정 · 범위, 동기화마다 더하는 이유별 개수 (docs/go-live/google-integration.md 8장).

const now = new Date("2026-09-29T00:00:00.000Z");

describe("withAccount", () => {
  it("계정 · 범위를 남기고 통계 등 나머지 값은 그대로 둔다", () => {
    const stats = { since: "2026-09-01T00:00:00.000Z", counts: { inbound: 3 } };
    const next = withAccount({ stats, googleUserId: "old-sub", email: "old@x.dev" }, { sub: "new-sub", email: "me@company.dev" }, ["openid"]);
    expect(next).toEqual({ stats, googleUserId: "new-sub", email: "me@company.dev", scopes: ["openid"] });
    expect(googleSettingsSchema.safeParse(next).success).toBe(true);
  });

  it("주소를 모르면 email null", () => {
    expect(withAccount({}, { sub: "s", email: null }, [])).toEqual({ googleUserId: "s", email: null, scopes: [] });
  });
});

describe("withStats", () => {
  it("처음이면 지금 시각부터 세기 시작한다", () => {
    expect(withStats({ email: "me@x.dev" }, { inbound: 2, category: 1 }, now)).toEqual({
      email: "me@x.dev",
      stats: { since: now.toISOString(), counts: { inbound: 2, category: 1 } },
    });
  });

  it("있던 개수에 더하고 since는 그대로 둔다. 0 · undefined는 더하지 않는다", () => {
    const settings = { googleUserId: "s", stats: { since: "2026-09-01T00:00:00.000Z", counts: { inbound: 2, bulk: 5 } } };
    expect(withStats(settings, { inbound: 3, sent: 1, bulk: 0, no_reply: undefined }, now)).toEqual({
      googleUserId: "s",
      stats: { since: "2026-09-01T00:00:00.000Z", counts: { inbound: 5, bulk: 5, sent: 1 } },
    });
    // 원래 설정은 바꾸지 않는다
    expect(settings.stats.counts).toEqual({ inbound: 2, bulk: 5 });
  });

  it("더할 것이 없으면(모두 0 · undefined) null: 쓰지 않는다", () => {
    expect(withStats({ stats: { since: "x", counts: { inbound: 1 } } }, { inbound: 0, bulk: undefined }, now)).toBeNull();
    expect(withStats({}, {}, now)).toBeNull();
  });

  it("저장된 통계 모양이 다르면 새로 시작한다", () => {
    expect(withStats({ stats: "broken" }, { inbound: 1 }, now)).toEqual({ stats: { since: now.toISOString(), counts: { inbound: 1 } } });
  });
});
