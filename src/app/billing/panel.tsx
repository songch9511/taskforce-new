"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { billingStatusSchema } from "@/lib/api/contract";

type Status = ReturnType<typeof billingStatusSchema.parse>;
async function readStatus(): Promise<Status> {
  const res = await fetch("/api/v1/billing", { cache: "no-store" });
  if (!res.ok) throw new Error("billing_unavailable");
  return billingStatusSchema.parse(await res.json());
}
const labels: Record<string, string> = { legacy_beta: "Your free beta access is still available", trial_pending: "Your 7-day trial starts with your first source sync", trialing: "Your free trial is active", active: "Your subscription is active", cancelled: "Cancelled — access continues until the date below", expired: "Choose a plan to resume AI processing", past_due: "Update your payment method to resume AI processing", unpaid: "Payment is required to resume AI processing", paused: "Your subscription is paused", refunded: "Your payment was refunded", deleting: "Account deletion is in progress" };

export function BillingPanel({ email }: { email: string }) {
  const [status, setStatus] = useState<Status | null>(null);
  const [message, setMessage] = useState("");
  const [busy, setBusy] = useState(false);
  const [accepted, setAccepted] = useState(false);
  const submitting = useRef(false);
  const refresh = useCallback(async () => {
    try {
      setStatus(await readStatus());
      setMessage("");
    } catch { setMessage("We could not load your subscription. Refresh to try again."); }
  }, []);
  useEffect(() => {
    let mounted = true;
    readStatus().then(value => { if (mounted) setStatus(value); }).catch(() => { if (mounted) setMessage("We could not load your subscription. Refresh to try again."); });
    const focus = () => void refresh();
    window.addEventListener("focus", focus);
    return () => { mounted = false; window.removeEventListener("focus", focus); };
  }, [refresh]);

  async function open(kind: "checkout" | "portal", plan?: "monthly" | "annual") {
    if (submitting.current) return;
    submitting.current = true; setBusy(true); setMessage("");
    try {
      const res = await fetch(`/api/v1/billing/${kind}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(plan ? { plan, terms_version: "2026-10-08" } : {}) });
      if (!res.ok) throw new Error();
      const data = await res.json();
      const url = new URL(data.url);
      if (url.protocol !== "https:" || !url.hostname.endsWith(".lemonsqueezy.com") || url.username || url.password) throw new Error();
      window.location.assign(url.href);
    } catch { setMessage("We could not open billing. An existing checkout may still be open. Please try again or contact support."); }
    finally { submitting.current = false; setBusy(false); }
  }
  const end = status?.current_period_ends_at ?? status?.trial_ends_at;
  return <section className="billing-card">
    <p>Signed in as <strong>{email}</strong></p>
    <h2>{status ? labels[status.status] ?? "Manage your subscription" : "Loading your subscription…"}</h2>
    {end && <p>Access until {new Date(end).toLocaleDateString("en", { dateStyle: "long", timeZone: "UTC" })} (UTC).</p>}
    {status?.status === "legacy_beta" && <p>Your existing free beta access remains available. Any future paid transition requires at least 30 days’ notice and your separate agreement.</p>}
    {status?.can_checkout && <>
      <label className="billing-consent"><input type="checkbox" checked={accepted} onChange={event => setAccepted(event.target.checked)} /> I agree to the <a href="https://www.taskforcelabs.dev/en/terms" target="_blank" rel="noreferrer">subscription terms</a> and have read the <a href="https://www.taskforcelabs.dev/en/privacy" target="_blank" rel="noreferrer">billing privacy information</a>. I am at least 14 and do not live in the EEA or UK.</label>
      <div className="billing-plans">
        <div><h3>Monthly</h3><p className="billing-price">$9 <span>/ month</span></p><button disabled={busy || !accepted} onClick={() => void open("checkout", "monthly")}>Subscribe monthly</button></div>
        <div><h3>Yearly · Save 15%</h3><p className="billing-price">$91.80 <span>/ year</span></p><button disabled={busy || !accepted} onClick={() => void open("checkout", "annual")}>Subscribe yearly</button></div>
      </div>
      <p>Payment starts immediately when you complete checkout, including during a free trial. Your plan renews automatically until cancelled. Cancel in Manage subscription before renewal. Taxes are shown at checkout.</p>
      <p>Both plans include $3 of AI processing per UTC calendar month, reset on the first day of each month. Unused allowance does not roll over. AI pauses at the limit; there are no automatic extra charges. The 7-day trial includes $1 total AI processing.</p>
    </>}
    {status?.plan && <button disabled={busy} onClick={() => void open("portal")}>Manage subscription</button>}
    {status && !status.can_checkout && !status.plan && status.status !== "deleting" && <p>Checkout is not available yet. Your current access is shown above.</p>}
    <div className="billing-actions"><button className="billing-secondary" disabled={busy} onClick={() => void refresh()}>Refresh status</button><form action="/billing/sign-out" method="post"><button className="billing-secondary" disabled={busy}>Sign out</button></form></div>
    {message && <p role="alert">{message}</p>}
    <p className="billing-fine">After checkout, return here or to the Mac app and refresh. Access is enabled after payment is confirmed.</p>
  </section>;
}
