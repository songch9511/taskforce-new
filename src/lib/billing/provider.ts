import 'server-only';
import { z } from 'zod';
export function billingConfig() {
    const env = z.object({ LEMONSQUEEZY_API_KEY: z.string().min(1), LEMONSQUEEZY_WEBHOOK_SECRET: z.string().min(16), LEMONSQUEEZY_STORE_ID: z.string().regex(/^\d+$/), LEMONSQUEEZY_MONTHLY_VARIANT_ID: z.string().regex(/^\d+$/), LEMONSQUEEZY_ANNUAL_VARIANT_ID: z.string().regex(/^\d+$/), LEMONSQUEEZY_TEST_MODE: z.enum(['true', 'false']) }).safeParse(process.env);
    if (!env.success)
        throw new Error('billing_not_configured');
    return { key: env.data.LEMONSQUEEZY_API_KEY, secret: env.data.LEMONSQUEEZY_WEBHOOK_SECRET, store: env.data.LEMONSQUEEZY_STORE_ID, variants: { monthly: env.data.LEMONSQUEEZY_MONTHLY_VARIANT_ID, annual: env.data.LEMONSQUEEZY_ANNUAL_VARIANT_ID }, test: env.data.LEMONSQUEEZY_TEST_MODE === 'true' };
}
export async function provider(path: string, method = 'GET', body?: unknown): Promise<unknown> {
    const response = await fetch(`https://api.lemonsqueezy.com/v1/${path}`, { method, headers: { Authorization: `Bearer ${billingConfig().key}`, Accept: 'application/vnd.api+json', 'Content-Type': 'application/vnd.api+json' }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000), cache: 'no-store' });
    if (!response.ok)
        throw new Error('billing_provider_unavailable');
    return response.json();
}
export const subscriptionSchema = z.object({ data: z.object({ id: z.string(), type: z.literal('subscriptions'), attributes: z.object({ store_id: z.number(), order_id: z.number(), variant_id: z.number(), customer_id: z.number(), test_mode: z.boolean(), status: z.string(), renews_at: z.string().nullable(), ends_at: z.string().nullable(), updated_at: z.string().datetime(), urls: z.object({ customer_portal: z.string().url() }) }) }) });
export async function subscription(id: string) {
    if (!/^\d+$/.test(id))
        throw new Error('billing_invalid_subscription');
    const data = subscriptionSchema.parse(await provider(`subscriptions/${id}`)).data;
    const config = billingConfig();
    if (String(data.attributes.store_id) !== config.store || data.attributes.test_mode !== config.test || !Object.values(config.variants).includes(String(data.attributes.variant_id)))
        throw new Error('billing_subscription_mismatch');
    return data;
}
export function safeProviderUrl(raw: string) {
    const url = new URL(raw);
    if (url.protocol !== 'https:' || !(url.hostname === 'lemonsqueezy.com' || url.hostname.endsWith('.lemonsqueezy.com')) || url.username || url.password)
        throw new Error('billing_invalid_url');
    return url.toString();
}
// Latest invoice, ordered newest-first by the provider, prevents an old refund
// delivery from revoking a subsequently paid billing cycle.
const invoiceSchema = z.object({ id: z.string(), attributes: z.object({ subscription_id: z.number(), store_id: z.number(), test_mode: z.boolean(), status: z.enum(['pending', 'paid', 'void', 'refunded', 'partial_refund']), refunded: z.boolean(), billing_reason: z.string(), created_at: z.string().datetime(), updated_at: z.string().datetime() }) });
export async function latestInvoice(id: string) {
    const result = z.object({ data: z.array(invoiceSchema) }).parse(await provider(`subscription-invoices?filter[subscription_id]=${id}&page[size]=1`));
    const invoice = result.data[0];
    if (!invoice)
        throw new Error('billing_payment_unconfirmed');
    const config = billingConfig();
    if (String(invoice.attributes.subscription_id) !== id || String(invoice.attributes.store_id) !== config.store || invoice.attributes.test_mode !== config.test)
        throw new Error('billing_invoice_mismatch');
    return invoice;
}
export async function initialOrder(id: number) {
    const result = z.object({ data: z.object({ attributes: z.object({ store_id: z.number(), test_mode: z.boolean(), refunded: z.boolean(), updated_at: z.string().datetime() }) }) }).parse(await provider(`orders/${id}`));
    const config = billingConfig();
    if (String(result.data.attributes.store_id) !== config.store || result.data.attributes.test_mode !== config.test)
        throw new Error('billing_order_mismatch');
    return result.data.attributes;
}
