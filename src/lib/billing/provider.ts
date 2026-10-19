import 'server-only';
import { z } from 'zod';
const digits = z.string().regex(/^\d+$/);
// An empty value in a copied .env means "not set", not "invalid".
const optional = <T extends z.ZodType>(schema: T) => z.preprocess(value => (value === '' ? undefined : value), schema.optional());
export function billingConfig() {
    // Variant env names are new on purpose: the ids of the retired first plan must never be read again (contract BL-25).
    const env = z.object({
        LEMONSQUEEZY_API_KEY: z.string().min(1),
        LEMONSQUEEZY_WEBHOOK_SECRET: z.string().min(16),
        LEMONSQUEEZY_STORE_ID: digits,
        LEMONSQUEEZY_PRO_MONTHLY_VARIANT_ID: digits,
        LEMONSQUEEZY_PRO_YEARLY_VARIANT_ID: digits,
        LEMONSQUEEZY_LIFETIME_VARIANT_ID: optional(digits),
        LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE: optional(z.string().regex(/^[A-Za-z0-9_-]{3,256}$/)),
        LEMONSQUEEZY_TEST_MODE: z.enum(['true', 'false']),
    }).safeParse(process.env);
    if (!env.success)
        throw new Error('billing_not_configured');
    return {
        key: env.data.LEMONSQUEEZY_API_KEY, secret: env.data.LEMONSQUEEZY_WEBHOOK_SECRET, store: env.data.LEMONSQUEEZY_STORE_ID,
        variants: { monthly: env.data.LEMONSQUEEZY_PRO_MONTHLY_VARIANT_ID, annual: env.data.LEMONSQUEEZY_PRO_YEARLY_VARIANT_ID, lifetime: env.data.LEMONSQUEEZY_LIFETIME_VARIANT_ID ?? null },
        discountCode: env.data.LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE ?? null,
        test: env.data.LEMONSQUEEZY_TEST_MODE === 'true',
    };
}
type BillingConfig = ReturnType<typeof billingConfig>;
/** Which of our variants a provider variant id is. Anything else in the store is not ours. */
export function variantPlan(config: BillingConfig, variantId: string | number): 'monthly' | 'annual' | 'lifetime' | null {
    const id = String(variantId);
    return id === config.variants.monthly ? 'monthly' : id === config.variants.annual ? 'annual' : config.variants.lifetime && id === config.variants.lifetime ? 'lifetime' : null;
}
export async function provider(path: string, method = 'GET', body?: unknown): Promise<unknown> {
    const response = await fetch(`https://api.lemonsqueezy.com/v1/${path}`, { method, headers: { Authorization: `Bearer ${billingConfig().key}`, Accept: 'application/vnd.api+json', 'Content-Type': 'application/vnd.api+json' }, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000), cache: 'no-store' });
    if (!response.ok)
        throw new Error('billing_provider_unavailable');
    return response.json();
}
// trial_ends_at is only set while on_trial; update_payment_method is a 24h signed link (the-subscription-object).
export const subscriptionSchema = z.object({ data: z.object({ id: z.string(), type: z.literal('subscriptions'), attributes: z.object({ store_id: z.number(), order_id: z.number(), variant_id: z.number(), customer_id: z.number(), test_mode: z.boolean(), status: z.string(), trial_ends_at: z.string().datetime().nullish(), renews_at: z.string().nullable(), ends_at: z.string().nullable(), updated_at: z.string().datetime(), urls: z.object({ customer_portal: z.string().url(), update_payment_method: z.string().url().nullish() }) }) }) });
const providerId = (id: string) => {
    if (!/^\d+$/.test(id))
        throw new Error('billing_invalid_id');
    return id;
};
export async function subscription(id: string) {
    if (!/^\d+$/.test(id))
        throw new Error('billing_invalid_subscription');
    const data = subscriptionSchema.parse(await provider(`subscriptions/${id}`)).data;
    const config = billingConfig();
    const plan = variantPlan(config, data.attributes.variant_id);
    if (String(data.attributes.store_id) !== config.store || data.attributes.test_mode !== config.test || (plan !== 'monthly' && plan !== 'annual'))
        throw new Error('billing_subscription_mismatch');
    return data;
}
export const cancelSubscription = (id: string) => provider(`subscriptions/${providerId(id)}`, 'DELETE');
/** Undo a cancellation before ends_at (update-subscription: cancelled=false). */
export const resumeSubscription = (id: string) => provider(`subscriptions/${providerId(id)}`, 'PATCH', { data: { type: 'subscriptions', id: providerId(id), attributes: { cancelled: false } } });
export function safeProviderUrl(raw: string) {
    const url = new URL(raw);
    if (url.protocol !== 'https:' || !(url.hostname === 'lemonsqueezy.com' || url.hostname.endsWith('.lemonsqueezy.com')) || url.username || url.password)
        throw new Error('billing_invalid_url');
    return url.toString();
}
// Latest invoice, ordered newest-first by the provider, prevents an old refund
// delivery from revoking a subsequently paid billing cycle.
const invoiceSchema = z.object({ id: z.string(), attributes: z.object({ subscription_id: z.number(), store_id: z.number(), test_mode: z.boolean(), status: z.enum(['pending', 'paid', 'void', 'refunded', 'partial_refund']), refunded: z.boolean(), billing_reason: z.string(), created_at: z.string().datetime(), updated_at: z.string().datetime(), discount_total: z.number().nonnegative().default(0) }) });
function checkedInvoice(invoice: z.infer<typeof invoiceSchema>, id: string) {
    const config = billingConfig();
    if (String(invoice.attributes.subscription_id) !== id || String(invoice.attributes.store_id) !== config.store || invoice.attributes.test_mode !== config.test)
        throw new Error('billing_invoice_mismatch');
    return invoice;
}
/** The newest invoice of a subscription, or null when it has none yet (a free trial has no invoice). */
export async function latestInvoice(id: string) {
    const result = z.object({ data: z.array(invoiceSchema) }).parse(await provider(`subscription-invoices?filter[subscription_id]=${providerId(id)}&page[size]=1`));
    const invoice = result.data[0];
    return invoice ? checkedInvoice(invoice, id) : null;
}
export async function invoiceOf(subscriptionId: string, invoiceId: string) {
    return checkedInvoice(z.object({ data: invoiceSchema }).parse(await provider(`subscription-invoices/${providerId(invoiceId)}`)).data, subscriptionId);
}
export const refundInvoice = (id: string) => provider(`subscription-invoices/${providerId(id)}/refund`, 'POST', { data: { type: 'subscription-invoices', id: providerId(id) } });
// status: pending | failed | paid | refunded | partial_refund | fraudulent. refunded is true only for a full refund.
const orderSchema = z.object({ data: z.object({ id: z.string(), attributes: z.object({ store_id: z.number(), customer_id: z.number(), test_mode: z.boolean(), status: z.string(), refunded: z.boolean(), created_at: z.string().datetime(), updated_at: z.string().datetime(), first_order_item: z.object({ variant_id: z.number() }) }) }) });
export async function order(id: string) {
    const result = orderSchema.parse(await provider(`orders/${providerId(id)}`));
    const config = billingConfig();
    if (String(result.data.attributes.store_id) !== config.store || result.data.attributes.test_mode !== config.test)
        throw new Error('billing_order_mismatch');
    return result.data;
}
export async function initialOrder(id: number) {
    return (await order(String(id))).attributes;
}
export const refundOrder = (id: string) => provider(`orders/${providerId(id)}/refund`, 'POST', { data: { type: 'orders', id: providerId(id) } });
