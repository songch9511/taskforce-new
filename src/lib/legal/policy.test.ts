import { describe, expect, it } from "vitest";

import { policyVersionSchema } from "@/lib/api/contract";

import { legalResponseSchema, type PolicyVersion } from "@/lib/api/contract";

import {
  effectiveAt,
  needsAccountCreatedAt,
  PRIVACY_POLICY,
  privacyNotices,
  privacyPolicyStatus,
  UPCOMING_NOTICE_DAYS,
  UPDATED_NOTICE_DAYS,
  validatePrivacyPolicy,
  type PrivacyPolicy,
  type UpcomingPolicy,
} from "./policy";

const url = { ko: "https://www.taskforcelabs.dev/ko/privacy", en: "https://www.taskforcelabs.dev/en/privacy" };
const v11 = { version: "beta-1.1", effective_date: "2026-09-30", url };
const v12 = {
  version: "beta-1.2",
  effective_date: "2026-10-07",
  url: { ko: "https://www.taskforcelabs.dev/ko/privacy/beta-1.2", en: "https://www.taskforcelabs.dev/en/privacy/beta-1.2" },
};
const now = new Date("2026-10-01T03:00:00Z");
const oldAccount = new Date("2026-09-20T00:00:00Z");

describe("PRIVACY_POLICY", () => {
  it("현재 판은 베타 1.5 (2026-10-07 시행)이고 계약 형식을 따른다", () => {
    expect(PRIVACY_POLICY.current.version).toBe("beta-1.5");
    expect(PRIVACY_POLICY.current.effective_date).toBe("2026-10-07");
    expect(policyVersionSchema.parse(PRIVACY_POLICY.current)).toEqual(PRIVACY_POLICY.current);
    if (PRIVACY_POLICY.upcoming) expect(policyVersionSchema.parse(PRIVACY_POLICY.upcoming)).toEqual(PRIVACY_POLICY.upcoming);
  });
});

describe("effectiveAt", () => {
  it("시행일 한국 시간 0시", () => {
    expect(effectiveAt(v11).toISOString()).toBe("2026-09-29T15:00:00.000Z");
  });
});

describe("privacyPolicyStatus", () => {
  const policy: PrivacyPolicy = { current: v11, upcoming: null };

  it("현재 판 시행 전에 가입한 계정은 updated 안내", () => {
    const status = privacyPolicyStatus(policy, oldAccount, now);
    expect(status).toEqual({ current: v11, upcoming: null, notice: { ...v11, kind: "updated" } });
  });

  it("시행일(한국 시간 0시) 뒤에 가입한 계정은 안내하지 않는다", () => {
    expect(privacyPolicyStatus(policy, new Date("2026-09-29T15:00:00Z"), now).notice).toBeNull();
    expect(privacyPolicyStatus(policy, new Date("2026-09-29T14:59:59Z"), now).notice?.kind).toBe("updated");
  });

  it("updated 안내는 시행일부터 30일 동안만 (그 뒤 처음 연 옛 계정에는 보이지 않는다)", () => {
    expect(UPDATED_NOTICE_DAYS).toBe(30);
    // 시행 2026-09-30 00:00 KST + 30일 = 2026-10-30 00:00 KST = 2026-10-29T15:00Z
    expect(privacyPolicyStatus(policy, oldAccount, new Date("2026-10-29T14:59:59Z")).notice?.kind).toBe("updated");
    expect(privacyPolicyStatus(policy, oldAccount, new Date("2026-10-29T15:00:00Z")).notice).toBeNull();
    expect(privacyPolicyStatus(policy, oldAccount, new Date("2027-03-01T00:00:00Z"))).toEqual({ current: v11, upcoming: null, notice: null });
  });

  it("시행 예정 판이 있으면 새 계정에도 upcoming 안내 (가입 시각 없이)", () => {
    const status = privacyPolicyStatus({ current: v11, upcoming: v12 }, null, now);
    expect(status).toEqual({ current: v11, upcoming: v12, notice: { ...v12, kind: "upcoming" } });
  });

  it("시행 예정 판은 시행일이 지나면 현재 판이 되고, 그 전에 가입한 계정에 updated 안내", () => {
    const later = new Date("2026-10-06T15:00:00Z"); // 2026-10-07 00:00 KST
    const status = privacyPolicyStatus({ current: v11, upcoming: v12 }, oldAccount, later);
    expect(status).toEqual({ current: v12, upcoming: null, notice: { ...v12, kind: "updated" } });
    expect(privacyPolicyStatus({ current: v11, upcoming: v12 }, new Date("2026-10-06T16:00:00Z"), later).notice).toBeNull();
  });
});

describe("needsAccountCreatedAt", () => {
  it("시행 예정 판이 있거나 updated 기간이 지났으면 가입 시각이 필요 없다", () => {
    expect(needsAccountCreatedAt({ current: v11, upcoming: null }, now)).toBe(true);
    expect(needsAccountCreatedAt({ current: v11, upcoming: v12 }, now)).toBe(false);
    expect(needsAccountCreatedAt({ current: v11, upcoming: null }, new Date("2026-10-29T15:00:00Z"))).toBe(false);
    // 시행 예정 판이 시행되면 다시 필요하다 (그 판의 updated 기간)
    expect(needsAccountCreatedAt({ current: v11, upcoming: v12 }, new Date("2026-10-06T15:00:00Z"))).toBe(true);
  });
});

// ─── 시행 예정 판 둘 (게시 규칙 6: 1.6을 먼저, 그 위에 1.7, 30일 고지가 겹쳐 돈다) ───

const link = (version: string) => ({ ko: `https://www.taskforcelabs.dev/ko/privacy/${version}`, en: `https://www.taskforcelabs.dev/en/privacy/${version}` });
// 현재 1.5(10-07 시행). 1.6은 10-10에 알려 11-10 시행, 1.7은 10-20에 알려 11-20 시행 (고지 기간이 10-20 ~ 11-10에 겹친다)
const v15 = { version: "beta-1.5", effective_date: "2026-10-07", url: link("beta-1.5") };
const v16: UpcomingPolicy = { version: "beta-1.6", effective_date: "2026-11-10", url: link("beta-1.6"), notice_from: "2026-10-10" };
const v17: UpcomingPolicy = { version: "beta-1.7", effective_date: "2026-11-20", url: link("beta-1.7"), notice_from: "2026-10-20" };
const strip = (v: UpcomingPolicy): PolicyVersion => ({ version: v.version, effective_date: v.effective_date, url: v.url });
const two: PrivacyPolicy = { current: v15, upcoming: [v16, v17] };
const during = new Date("2026-10-25T03:00:00Z"); // 두 고지가 함께 도는 때
const afterFirst = new Date("2026-11-10T15:00:00Z"); // 2026-11-11 00:00 KST: 1.6 시행 뒤, 1.7 시행 전
const afterBoth = new Date("2026-11-20T15:00:00Z"); // 2026-11-21 00:00 KST

describe("시행 예정 판 둘", () => {
  it("둘을 함께 받는다: upcoming은 먼저 시행될 판, notice도 그 판 (옛 앱 · 계약 형식 그대로)", () => {
    const status = privacyPolicyStatus(two, null, during);
    expect(status.current).toEqual(v15);
    expect(status.upcoming).toEqual(strip(v16));
    expect(status.notice).toEqual({ ...strip(v16), kind: "upcoming" });
    // 고지 시작일 같은 내부 값은 응답에 새지 않는다
    expect(JSON.stringify(status)).not.toContain("notice_from");
    expect(() => legalResponseSchema.parse({ privacy: status })).not.toThrow();
  });

  it("privacyNotices는 시행 예정 판을 시행 순서대로 모두 돌려준다 (새 앱이 둘 다 보일 수 있게)", () => {
    expect(privacyNotices(two, null, during)).toEqual([
      { ...strip(v16), kind: "upcoming" },
      { ...strip(v17), kind: "upcoming" },
    ]);
    expect(privacyNotices({ current: v15, upcoming: v16 }, null, during)).toEqual([{ ...strip(v16), kind: "upcoming" }]);
    expect(privacyNotices({ current: v15, upcoming: null }, null, during)).toEqual([]);
  });

  it("첫 판이 시행되면 현재 판이 되고 둘째 판이 시행 예정으로 남는다", () => {
    const status = privacyPolicyStatus(two, new Date("2026-09-01T00:00:00Z"), afterFirst);
    expect(status.current).toEqual(strip(v16));
    expect(status.upcoming).toEqual(strip(v17));
    expect(status.notice).toEqual({ ...strip(v17), kind: "upcoming" });
  });

  it("둘 다 시행되면 마지막 판이 현재 판이고, 그 전에 가입한 계정에 updated 안내", () => {
    const status = privacyPolicyStatus(two, new Date("2026-09-01T00:00:00Z"), afterBoth);
    expect(status.current).toEqual(strip(v17));
    expect(status.upcoming).toBeNull();
    expect(status.notice).toEqual({ ...strip(v17), kind: "updated" });
    expect(privacyPolicyStatus(two, new Date("2026-11-20T15:00:00Z"), afterBoth).notice).toBeNull();
  });

  it("한꺼번에 둘이 시행돼도(앱을 오래 안 연 경우) 건너뛰지 않는다", () => {
    expect(privacyNotices(two, new Date("2026-09-01T00:00:00Z"), afterBoth)).toEqual([{ ...strip(v17), kind: "updated" }]);
  });

  it("시행 예정 판이 하나라도 남아 있으면 가입 시각이 필요 없고, 둘 다 시행되면 다시 필요하다", () => {
    expect(needsAccountCreatedAt(two, during)).toBe(false);
    expect(needsAccountCreatedAt(two, afterFirst)).toBe(false);
    expect(needsAccountCreatedAt(two, afterBoth)).toBe(true);
  });

  it("옛 모양(하나 · 없음)과 같은 결과를 낸다", () => {
    const single: PrivacyPolicy = { current: v15, upcoming: v16 };
    expect(privacyPolicyStatus(single, null, during)).toEqual(privacyPolicyStatus({ current: v15, upcoming: [v16] }, null, during));
    expect(privacyPolicyStatus({ current: v15, upcoming: [] }, null, during)).toEqual(privacyPolicyStatus({ current: v15, upcoming: null }, null, during));
  });
});

describe("validatePrivacyPolicy", () => {
  it("겹치는 고지 두 개: 1.7 시행일이 자기 고지 + 30일 이후이고 1.6 시행일 이후면 통과", () => {
    expect(UPCOMING_NOTICE_DAYS).toBe(30);
    expect(validatePrivacyPolicy(two)).toEqual([]);
    expect(validatePrivacyPolicy({ current: v15, upcoming: null })).toEqual([]);
  });

  it("지금 올라 있는 PRIVACY_POLICY가 규칙을 지킨다", () => {
    expect(validatePrivacyPolicy(PRIVACY_POLICY)).toEqual([]);
  });

  it("자기 고지 + 30일보다 앞선 시행일은 거절한다 (하루 모자라도)", () => {
    const early = { ...v17, effective_date: "2026-11-18" }; // 10-20 + 30일 = 11-19
    expect(validatePrivacyPolicy({ current: v15, upcoming: [v16, early] }).join("\n")).toContain("beta-1.7");
    expect(validatePrivacyPolicy({ current: v15, upcoming: [v16, { ...v17, effective_date: "2026-11-19" }] })).toEqual([]);
  });

  it("뒤 판의 시행일이 앞 판보다 이르면 거절한다 (같은 날은 허용)", () => {
    const earlier = { ...v17, effective_date: "2026-11-09", notice_from: "2026-10-01" };
    expect(validatePrivacyPolicy({ current: v15, upcoming: [v16, earlier] }).join("\n")).toContain("beta-1.6");
    expect(validatePrivacyPolicy({ current: v15, upcoming: [v16, { ...v17, effective_date: v16.effective_date, notice_from: v16.notice_from }] })).toEqual([]);
  });

  it("고지 시작일이 없거나 형식이 틀리면 거절한다", () => {
    const bare: UpcomingPolicy = strip(v16);
    expect(validatePrivacyPolicy({ current: v15, upcoming: bare }).length).toBeGreaterThan(0);
    expect(validatePrivacyPolicy({ current: v15, upcoming: { ...v16, notice_from: "10/10" } }).length).toBeGreaterThan(0);
  });

  it("현재 판보다 이르거나 같은 시행일 · 겹치는 판 이름은 거절한다", () => {
    expect(validatePrivacyPolicy({ current: v15, upcoming: { ...v16, effective_date: "2026-10-07" } }).length).toBeGreaterThan(0);
    expect(validatePrivacyPolicy({ current: v15, upcoming: [v16, { ...v17, version: "beta-1.6" }] }).length).toBeGreaterThan(0);
    expect(validatePrivacyPolicy({ current: v15, upcoming: { ...v16, version: "beta-1.5" } }).length).toBeGreaterThan(0);
  });

  it("고지 기간을 줄이는 notice_days는 7일 아래로 내릴 수 없다", () => {
    expect(validatePrivacyPolicy({ current: v15, upcoming: { ...v16, effective_date: "2026-10-17", notice_days: 7 } })).toEqual([]);
    expect(validatePrivacyPolicy({ current: v15, upcoming: { ...v16, effective_date: "2026-10-12", notice_days: 2 } }).length).toBeGreaterThan(0);
  });
});
