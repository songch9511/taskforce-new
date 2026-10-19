// The one place that knows what Taskforce charges (2026-10-09 pricing). The Mac app shows the strings from here
// (GET /api/v2/billing -> prices) and carries no price constant. Lemon Squeezy owns the real amounts:
// change the dashboard price and this file together, then deploy (Lifetime ladder steps work the same way).
export const PRICE_CENTS = {
    pro_monthly: 1299,
    pro_first_month: 699,
    pro_yearly: 11988,
    lifetime: 22900,
} as const;

/** Terms the buyer accepts in the app. Replace with the published date when the new terms go live (docs/legal). */
export const BILLING_TERMS_VERSION = '2026-10-19';

/** A paid invoice / order can be refunded by the buyer for this long after the provider created it. */
export const REFUND_WINDOW_HOURS = 72;
/** past_due keeps working for the provider's retry period (about two weeks) plus margin, never longer. */
export const PAST_DUE_GRACE_DAYS = 16;

export function displayPrice(cents: number): string {
    const dollars = cents / 100;
    return Number.isInteger(dollars) ? `$${dollars}` : `$${dollars.toFixed(2)}`;
}
export function billingPrices() {
    return {
        pro_monthly: displayPrice(PRICE_CENTS.pro_monthly),
        pro_first_month: displayPrice(PRICE_CENTS.pro_first_month),
        pro_yearly: displayPrice(PRICE_CENTS.pro_yearly),
        lifetime: displayPrice(PRICE_CENTS.lifetime),
    };
}
