# Paid beta release — 2026-10-08

This implements the owner's explicit request to open account subscriptions and app/web checkout. It supersedes earlier proposals to charge only for AI execution. Existing free-beta accounts retain their access until at least 30 days' notice and separate paid consent; this release does not send that notice or auto-enrol them.

## Approved offer

- Monthly: USD 9 per account, recurring monthly.
- Annual: USD 91.80, charged yearly (108 × 0.85; USD 7.65/month equivalent).
- Applicable taxes are extra; Lemon Squeezy store tax-inclusive pricing is off.
- Card-free trial: 7 days from first successful source sync; USD 1 total AI supplier cost allowance. Initially proposed USD 0.50 was rejected after the existing model's conservative USD 0.713033 reservation was measured; owner explicitly approved USD 1.
- Both paid plans: USD 3 AI supplier cost allowance per UTC calendar month, reset on day 1. No rollover or automatic overage. Every unresolved older reservation still counts. Saved task viewing/management remains available at the cap or after subscription expiry.
- Checkout charges immediately, including during the trial. No Lemon Squeezy product trial, setup fee, metering, or licence keys.

## Surfaces

- Marketing: `https://www.taskforcelabs.dev/en/pricing`.
- Account checkout: `https://api.taskforcelabs.dev/billing`, using the same Google/Supabase account as the Mac app.
- Mac: Settings → Account → Subscription. Monthly/yearly checkout, portal, and refresh. Client results never grant entitlement.
- API: GET `/api/v1/billing`, POST `/api/v1/billing/checkout` with `{plan,terms_version:"2026-10-08"}`, POST `/api/v1/billing/portal`.
- Provider callback: POST `/api/webhooks/lemonsqueezy`. Signature and configured mode/store/variant are verified; payment is checked against authoritative provider data.
- Retry: `/api/cron/billing` every 10 minutes with the existing CRON_SECRET authorization. Daily retention removes bounded retry records.
- Browser OAuth callback: `https://api.taskforcelabs.dev/auth/billing`. Add this exact address to Supabase Auth's allowed redirects before enabling website sign-in. Never put tokens in marketing URLs.

## Catalog evidence

Store: Task Force labs (`taskforcelabs.lemonsqueezy.com`). Identity verification is active and bank connection/setup steps are complete. This is an existing live store, not a new pending store approval.

Test product `1420342` is a draft with Monthly variant `2218838` ($9/month) and Annual variant `2218883` ($91.80/year). Storefront disabled. Tax category: AI as a Service (AIaaS) - Cloud Based & Downloaded. Product description discloses included allowance and no overage. Screenshot: `evidence/lemonsqueezy-plans-test-2026-10-08.jpg`.

Live product `1420403` is also a draft, with Monthly variant `2218942` ($9/month) and Annual variant `2218943` ($91.80/year). Live/test mode and both prices were verified in the dashboard. Screenshot: `evidence/lemonsqueezy-plans-live-draft-2026-10-08.jpg`. Do not publish a buyable live checkout before account binding and delivery are verified.

## Server configuration and release sequence

Use `.env.example` for exact variable names. API key and webhook secret are server secrets, never NEXT_PUBLIC values or committed files. Set `LEMONSQUEEZY_TEST_MODE` explicitly. Test and live must use separate keys, product IDs and webhook registrations. Production allowance values: monthly `3`, trial `1`. `BILLING_ENABLED` defaults off.

1. Finish regression, PostgreSQL contention, auth/client, Mac build and website checks. Review the billing migration and isolate any test account/data from production.
2. Apply only `supabase/migrations/20261030000000_billing.sql` to the linked project using `supabase db query --linked --project-ref tirtdojsahotjfgdsryi -f <exact file>`. Never `db push`. Migration seeds existing auth users as legacy beta and leaves new accounts on the new offer.
3. Configure test keys/webhook on an isolated test deployment/database, publish the test product, and complete monthly/yearly test checkout. Verify account-bound activation, retry/idempotence, failed payment, cancellation, refund, expiry and deletion with an open checkout.
4. Configure live keys/IDs/webhook and exact Supabase OAuth redirect. Verify price objects remain USD 900/month and USD 9180/year; no product trial or setup fee. Publish live catalog, then enable the server billing flag only when entitlement delivery is verified.
5. Deploy server and website from reviewed commits. Confirm Google login, both checkout amounts/tax disclosure, portal and status refresh through the real domains. Publish signed/notarized Mac build with verified metadata, then download/install/launch it from the website.

The owner authorized opening billing and deploying these surfaces. Browser policy separately requires action-time confirmation for creating API access; that confirmation was requested before creating either key. No key was created merely because the general launch task was authorized.

## Verification status

Local evidence only, not provider/production completion:

- Backend final: lint (0 errors; 1 pre-existing unused-import warning), typecheck, 2,389 tests across 188 files, label-only eval, and Next production build passed. Runtime npm audit: 0 vulnerabilities. A default eval invocation detected inherited provider configuration and was stopped before producing scores; only label validation is complete. No live quality result is claimed.
- Real PostgreSQL final: 27 contention/locking tests across 5 files passed, including two concurrent $2 reservations under a $3 cap, simultaneous monthly/annual checkout, and exclusive deletion claims.
- Swift package final: 527 tests / 62 suites passed, including checkout consent and safe provider URLs.
- macOS final: unsigned Debug build and 107 app tests / 12 suites passed. This does not establish signed installer or live checkout behavior.
- Website: 38 tests passed and production build passed; Next.js patched from 16.3.4 to 16.3.6 and transitive security updates applied. Website npm audit reported 0 vulnerabilities after patching.
- Web auth: fixed-return PKCE callback, failed-code handling, CSRF-protected local signout; no client account ID is accepted for checkout.

Pending: provider test flow, live credentials/webhook configuration, production DB/deployment, signed installed Mac and real-domain checkout proof. Until these are recorded, the release is prepared, not live.

## Official references

- https://docs.lemonsqueezy.com/api/checkouts/create-checkout
- https://docs.lemonsqueezy.com/help/webhooks/signing-requests
- https://docs.lemonsqueezy.com/help/webhooks/event-types
- https://docs.lemonsqueezy.com/guides/developer-guide/testing-going-live
- https://docs.lemonsqueezy.com/help/payments/refunds-chargebacks
- https://www.lemonsqueezy.com/privacy
- https://www.lemonsqueezy.com/buyer-terms
