import { afterEach, describe, expect, it, vi } from "vitest";

import { fakeAdmin } from "./fake-admin";
import { agentRunsAllowed } from "./entitlement";

// 만료된 계정은 에이전트 실행을 시작하지 못한다 (결제 계약 22장). 시작의 공통 경계 한 곳(startPinnedAgentMessage)이 이 판정을 쓴다.
// 결제가 꺼져 있으면(모두 베타) 아무것도 읽지 않고 통과한다 — 동작이 바뀌지 않는다.
const USER = "10000000-0000-4000-8000-000000000001";
const DAY = 86_400_000;
const iso = (offset: number) => new Date(Date.now() + offset).toISOString();
afterEach(() => vi.unstubAllEnvs());

const account = (over: Record<string, unknown> = {}) => ({
  user_id: USER, legacy_beta: false, notice_ends_at: null, trial_ends_at: null, subscription_id: null, customer_id: null, order_id: null, plan: null, status: "none",
  current_period_ends_at: null, deleting: false, first_subscription_at: null, lifetime_order_id: null, lifetime_status: null, lifetime_paid_at: null,
  last_payment_at: null, last_invoice_id: null, refund_requested_at: null, self_refund_used_at: null, ...over,
});
const world = (row: Record<string, unknown> | null) => fakeAdmin({ tables: { billing_accounts: row ? [row] : [] } });

describe("agentRunsAllowed", () => {
  it("결제가 꺼져 있으면 아무것도 읽지 않고 통과한다 (모두 베타)", async () => {
    const fake = world(null);
    expect(await agentRunsAllowed(fake.admin, USER)).toBe(true);
    expect(fake.calls).toEqual([]);
  });

  it.each([
    ["체험 중", { subscription_id: "s", status: "on_trial", trial_ends_at: iso(DAY) }],
    ["Pro 기간 안", { subscription_id: "s", status: "active", current_period_ends_at: iso(5 * DAY) }],
    ["취소했지만 기간이 남음", { subscription_id: "s", status: "cancelled", current_period_ends_at: iso(DAY) }],
    ["결제 실패 유예 안", { subscription_id: "s", status: "past_due", current_period_ends_at: iso(-3 * DAY) }],
    ["Lifetime", { lifetime_status: "active", lifetime_order_id: "o" }],
    ["기존 베타(공지 전)", { legacy_beta: true }],
    ["기존 베타(공지 날짜 전)", { legacy_beta: true, notice_ends_at: iso(DAY) }],
  ])("결제가 켜져 있어도 %s는 시작할 수 있다", async (_label, row) => {
    vi.stubEnv("BILLING_ENABLED", "true");
    expect(await agentRunsAllowed(world(account(row)).admin, USER)).toBe(true);
  });

  it.each([
    ["기록 없는 새 계정", null],
    ["아무것도 산 적 없음", account()],
    ["기간이 끝난 Pro", account({ subscription_id: "s", status: "active", current_period_ends_at: iso(-DAY) })],
    ["끝난 체험", account({ subscription_id: "s", status: "on_trial", trial_ends_at: iso(-DAY) })],
    ["만료됨", account({ subscription_id: "s", status: "expired" })],
    ["환불됨", account({ subscription_id: "s", status: "refunded" })],
    ["유예 16일이 지남", account({ subscription_id: "s", status: "past_due", current_period_ends_at: iso(-20 * DAY) })],
    ["환불된 Lifetime", account({ lifetime_status: "refunded", lifetime_order_id: "o" })],
    ["공지 날짜가 지난 베타", account({ legacy_beta: true, notice_ends_at: iso(-DAY) })],
    ["삭제 중", account({ subscription_id: "s", status: "active", current_period_ends_at: iso(DAY), deleting: true })],
  ])("결제가 켜져 있으면 %s는 시작할 수 없다", async (_label, row) => {
    vi.stubEnv("BILLING_ENABLED", "true");
    expect(await agentRunsAllowed(world(row).admin, USER)).toBe(false);
  });

  it("계정 행을 읽지 못하면 던진다: 읽지 못한 채 시작하지도, 막힌 것으로 표시하지도 않는다", async () => {
    vi.stubEnv("BILLING_ENABLED", "true");
    const fake = fakeAdmin({ tables: { billing_accounts: [account()] }, fail: { "billing_accounts.select": { code: "XX000", message: "db" } } });
    await expect(agentRunsAllowed(fake.admin, USER)).rejects.toThrow();
  });

  it("읽기만 한다: 계정 행을 만들지 않는다", async () => {
    vi.stubEnv("BILLING_ENABLED", "true");
    const fake = world(null);
    await agentRunsAllowed(fake.admin, USER);
    expect(fake.calls.map((call) => call.kind)).toEqual(["select"]);
  });
});
