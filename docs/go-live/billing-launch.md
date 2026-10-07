# Paid beta release — 2026-10-08

This implements the owner's explicit request to open account subscriptions and app/web checkout. It supersedes earlier proposals to charge only for AI execution. Existing free-beta accounts retain their access until at least 30 days' notice and separate paid consent; this release does not send that notice or auto-enrol them.

## Approved offer

- Monthly: USD 9.99 per account, recurring monthly.
- Annual: USD 101.90, charged yearly (119.88 × 0.85 = 101.898, rounded to cents; approximately USD 8.49/month).
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

Test product `1420342` is published in test mode with Monthly variant `2218838` ($9.99/month) and Annual variant `2218883` ($101.90/year). Storefront disabled. Tax category: AI as a Service (AIaaS) - Cloud Based & Downloaded. Product description discloses included allowance and no overage. Latest price screenshot: `evidence/lemonsqueezy-plans-test-999-2026-10-08.jpg`.

Live product `1420403` is also a draft, with Monthly variant `2218942` ($9.99/month) and Annual variant `2218943` ($101.90/year). Live/test mode and both prices were verified in the dashboard. Latest price screenshot: `evidence/lemonsqueezy-plans-live-999-2026-10-08.jpg`. Earlier screenshots document superseded $9/$91.80 drafts. Do not publish a buyable live checkout before account binding and delivery are verified.

## Server configuration and release sequence

Use `.env.example` for exact variable names. API key and webhook secret are server secrets, never NEXT_PUBLIC values or committed files. Set `LEMONSQUEEZY_TEST_MODE` explicitly. Test and live must use separate keys, product IDs and webhook registrations. Production allowance values: monthly `3`, trial `1`. `BILLING_ENABLED` defaults off.

1. Finish regression, PostgreSQL contention, auth/client, Mac build and website checks. Review the billing migration and isolate any test account/data from production.
2. Apply only `supabase/migrations/20261101000000_billing.sql` to the linked project using `supabase db query --linked --project-ref tirtdojsahotjfgdsryi -f <exact file>`. Never `db push`. Migration seeds existing auth users as legacy beta and leaves new accounts on the new offer.
3. Configure test keys/webhook on an isolated test deployment/database, publish the test product, and complete monthly/yearly test checkout. Verify account-bound activation, retry/idempotence, failed payment, cancellation, refund, expiry and deletion with an open checkout.
4. Configure live keys/IDs/webhook and exact Supabase OAuth redirect. Verify price objects remain USD 999/month and USD 10190/year; no product trial or setup fee. Publish live catalog, then enable the server billing flag only when entitlement delivery is verified.
5. Deploy server and website from reviewed commits. Confirm Google login, both checkout amounts/tax disclosure, portal and status refresh through the real domains. Publish signed/notarized Mac build with verified metadata, then download/install/launch it from the website.

The owner explicitly approved test/live API key creation and Vercel server secret storage on 2026-10-08 KST. Both keys were created (expiry 2027-04-08), authenticated successfully, and saved as Secret values: test scoped to the billing Preview branch and live to Production. Webhook secrets, store 474964, variant IDs, mode, budgets and the initially disabled billing flag were saved in the same scopes. Live webhook 140533 targets the production billing endpoint; test webhook 140532 uses a temporary isolated local endpoint. The exact production OAuth callback was added to the existing same-origin allowlist.

## Verification status

Local evidence only, not provider/production completion. Fresh checks below include integration with upstream beta cost controls (`f19b96d`).

- Backend final: lint (0 errors; 1 pre-existing unused-import warning), typecheck, 2,446 tests across 194 files, label-only eval, and Next production build passed. Runtime npm audit: 0 vulnerabilities. A default eval invocation detected inherited provider configuration and was stopped before producing scores; only label validation is complete. No live quality result is claimed.
- Real PostgreSQL final: 31 contention/locking tests across 5 files passed, including two concurrent $2 reservations under a $3 cap, simultaneous monthly/annual checkout, exclusive deletion claims, and shared global contention between legacy and paid accounts.
- Swift package final: 528 tests / 62 suites passed, including checkout consent and safe provider URLs.
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

## Integration checkpoint

PR #110 was initially based on `4a6c319`. Upstream #109 added beta cost controls and two migrations (`20261030000000_ai_beta_budget_limits.sql`, `20261031000000_ai_budget_retry_candidates.sql`). Billing now follows them as `20261101000000_billing.sql`. Fresh production read-only checks confirmed `ai_budget_policy`, `pending_task_sources` and `ai_budget_retry_candidates` already exist, with USD 3/user/day, USD 5/global/day and USD 50/global lifetime policy. Billing tables remain absent. Apply only the billing migration after integration verification; do not replay the upstream migrations. Preserve these operator circuit breakers alongside subscription allowances. The unsigned/partially archived build 28 at source `c9ae304` was stopped after this conflict was found; it is not a release artifact.

Independent integration review found no new blocking issue. Account usage shows personal allowance; shared operator caps may still pause processing with a separate error. PRs: https://github.com/songch9511/taskforce-new/pull/110 and https://github.com/songch9511/taskforce/pull/35. Earlier website hosted CI passed. The latest website revision is being checked again; Vercel Preview passed and production remains unchanged.

## Price revision

The owner subsequently changed prices to USD 9.99/month and USD 101.90/year. App, API, current legal terms and test/live draft variants were updated; allowance budgets remain unchanged. Signed/notarized build 29 passed at source `e0f6592` but contains the previous display prices and must not be published for this offer. Replacement build 30 at source `5c3b9e22d4c7f90c7c197b78821868cf3a10743d` passed app/DMG signing, notarization, stapling and Gatekeeper validation. Local artifact: `/Users/daniel/.codex/releases/taskforce/billing/Taskforce-0.1.0-30/Taskforce-0.1.0-30.dmg`; SHA-256 `56dd3668fcb04d8cc6eab5bdc87fc4de1a8f88f3b8ab8d73866c0b50db581c06`. It is not published or installed; provider configuration and checkout verification remain release gates. Pricing now appears on the home page and its dedicated page, preserving the cream/sand website design, with USD 119.88 struck through next to the annual offer.

## Provider E2E and deployment checkpoint (2026-10-08 KST)

Real Lemon Squeezy TEST checkouts succeeded at $9.99 monthly and $101.90 yearly using official test cards and synthetic accounts on a disposable local Supabase stack. Both account mappings became active with $3 monthly allowance and UTC month reset; six initial signed events were processed. Portal API and portal UI worked. Monthly cancellation preserved paid-through access; full annual initial-order refund revoked paid access. A declined card did not grant a paid plan. Signed duplicate delivery returned 200 twice; unsigned webhook returned 401. No real card was charged.

The refund flow exposed a trial fallback defect; regression tests reproduced it before a fix in application state and SQL spending/trial functions. Repeating the actual refunded account check confirmed can_use_ai=false, no allowance, and database subscription_required. Focused checks: 48 billing tests and 9 PostgreSQL billing tests; full tests 2,446 across 194 files, lint and typecheck passed. The isolated production build passed. Native source is unchanged from signed build 30.

Only the billing migration was applied to production in an explicit transaction; existing beta access is grandfathered. Production activation, live Google/checkout verification, publication and installation of build 30 remain subsequent gates. Test mode evidence does not prove a live charge. Raw credentials and synthetic access tokens remain outside Git and are removed after setup verification.
