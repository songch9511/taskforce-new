import { describe, expect, it } from "vitest";

import { policyVersionSchema } from "@/lib/api/contract";

import { effectiveAt, needsAccountCreatedAt, PRIVACY_POLICY, privacyPolicyStatus, UPDATED_NOTICE_DAYS, type PrivacyPolicy } from "./policy";

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
  it("현재 판은 베타 1.3 (2026-10-02 시행)이고 계약 형식을 따른다", () => {
    expect(PRIVACY_POLICY.current.version).toBe("beta-1.3");
    expect(PRIVACY_POLICY.current.effective_date).toBe("2026-10-02");
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
