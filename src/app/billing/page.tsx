import type { Metadata } from "next";
import { createClient } from "@/lib/supabase/server";
import { getVerifiedClaims } from "@/lib/supabase/claims";
import { BillingPanel } from "./panel";
import "./style.css";

export const metadata: Metadata = { title: "Subscription · Taskforce", robots: { index: false, follow: false } };

export default async function BillingPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const supabase = await createClient();
  const { data } = await getVerifiedClaims(supabase);
  const claims = data?.claims;
  return <main className="billing-page" lang="en">
    <a className="billing-brand" href="https://www.taskforcelabs.dev/en">Taskforce</a>
    <p className="billing-eyebrow">YOUR SUBSCRIPTION</p>
    <h1>Keep track of what you promised.</h1>
    {(await searchParams).error && <p role="alert">Sign-in did not complete. Try again using the Google account you use in Taskforce.</p>}
    {claims ? <BillingPanel email={typeof claims.email === "string" ? claims.email : "Your Taskforce account"} /> : <section className="billing-card">
      <h2>Use the same account as your Mac app.</h2>
      <p>Sign in to choose a plan, check your subscription, or manage your payments.</p>
      <a className="billing-button" href="/billing/sign-in">Continue with Google</a>
      <p>New to Taskforce? Download the Mac app and try it free for 7 days from your first successful source sync. No card required.</p>
      <a href="https://www.taskforcelabs.dev/en/download">Download for Mac</a>
    </section>}
    <p className="billing-fine">$9.99 monthly or $101.90 yearly (15% off $119.88 for 12 monthly payments, rounded to the nearest cent), plus applicable tax. Each plan includes $3 of AI processing per UTC calendar month. No automatic overage charges.</p>
    <footer><a href="https://www.taskforcelabs.dev/en/terms">Terms</a> · <a href="https://www.taskforcelabs.dev/en/privacy">Privacy</a> · <a href="mailto:privacy@taskforcelabs.dev">Contact</a></footer>
  </main>;
}
