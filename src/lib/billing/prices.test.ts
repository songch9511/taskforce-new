import { expect, it } from 'vitest';
import { BILLING_TERMS_VERSION, PAST_DUE_GRACE_DAYS, PRICE_CENTS, REFUND_WINDOW_HOURS, billingPrices, displayPrice } from './prices';
it('charges exactly what the 2026-10-09 pricing says: Pro $12.99 (first month $6.99) or $119.88 a year, Lifetime $229', () => {
    expect(PRICE_CENTS).toEqual({ pro_monthly: 1299, pro_first_month: 699, pro_yearly: 11988, lifetime: 22900 });
    expect(billingPrices()).toEqual({ pro_monthly: '$12.99', pro_first_month: '$6.99', pro_yearly: '$119.88', lifetime: '$229' });
});
it('the yearly price is the $9.99 a month the pricing quotes', () => {
    expect(PRICE_CENTS.pro_yearly / 12).toBeCloseTo(999, 5);
});
it('formats whole dollars without cents and everything else with two digits', () => {
    expect(displayPrice(22900)).toBe('$229');
    expect(displayPrice(1299)).toBe('$12.99');
    expect(displayPrice(5)).toBe('$0.05');
});
it('keeps the policy numbers the contract fixes', () => {
    expect(REFUND_WINDOW_HOURS).toBe(72);
    expect(PAST_DUE_GRACE_DAYS).toBe(16);
    expect(BILLING_TERMS_VERSION).toMatch(/^\d{4}-\d{2}-\d{2}$/);
});
it('no retired $9.99 plan constant is left in the billing code', async () => {
    const { readFileSync, readdirSync } = await import('node:fs');
    const { fileURLToPath } = await import('node:url');
    const dir = fileURLToPath(new URL('.', import.meta.url));
    for (const file of readdirSync(dir).filter(name => name.endsWith('.ts') && !name.endsWith('.test.ts') && name !== 'testing.ts')) {
        const text = readFileSync(dir + file, 'utf8');
        // the two literals required by the frozen v1 response are the only allowed places
        const lines = text.split('\n').filter(line => /101\.9|9\.99/.test(line));
        expect(lines.every(line => file === 'state.ts' && line.includes('as const')), `${file}: ${lines.join('|')}`).toBe(true);
    }
});
