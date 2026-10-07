import { NextRequest } from "next/server";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ exchange: vi.fn(), signIn: vi.fn(), signOut: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ auth: { exchangeCodeForSession: mocks.exchange, signInWithOAuth: mocks.signIn, signOut: mocks.signOut } }) }));
import { GET as callback } from "./route";
import { GET as signIn } from "@/app/billing/sign-in/route";
import { POST as signOut } from "@/app/billing/sign-out/route";

beforeEach(() => { vi.clearAllMocks(); });
describe("billing browser authentication", () => {
  it("uses PKCE Google login and a fixed same-origin callback", async () => {
    mocks.signIn.mockResolvedValue({ data: { url: "https://example.supabase.co/auth/v1/authorize" }, error: null });
    const response = await signIn(new NextRequest("https://api.taskforcelabs.dev/billing/sign-in?next=https://evil.test"));
    expect(mocks.signIn).toHaveBeenCalledWith({ provider: "google", options: { redirectTo: "https://api.taskforcelabs.dev/auth/billing", queryParams: { prompt: "select_account" } } });
    expect(response.headers.get("location")).toBe("https://example.supabase.co/auth/v1/authorize");
  });
  it("exchanges a code then returns only to billing", async () => {
    mocks.exchange.mockResolvedValue({ error: null });
    const response = await callback(new NextRequest("https://api.taskforcelabs.dev/auth/billing?code=fixture&next=https://evil.test"));
    expect(mocks.exchange).toHaveBeenCalledWith("fixture");
    expect(response.headers.get("location")).toBe("https://api.taskforcelabs.dev/billing");
  });
  it("does not treat a rejected code as a successful login", async () => {
    mocks.exchange.mockResolvedValue({ error: new Error("invalid") });
    const response = await callback(new NextRequest("https://api.taskforcelabs.dev/auth/billing?code=bad"));
    expect(response.headers.get("location")).toBe("https://api.taskforcelabs.dev/billing?error=sign-in");
  });
  it("blocks cross-site signout and signs out only this browser", async () => {
    expect((await signOut(new Request("https://api.taskforcelabs.dev/billing/sign-out", { method: "POST", headers: { origin: "https://evil.test" } }))).status).toBe(403);
    expect(mocks.signOut).not.toHaveBeenCalled();
    const response = await signOut(new Request("https://api.taskforcelabs.dev/billing/sign-out", { method: "POST", headers: { origin: "https://api.taskforcelabs.dev" } }));
    expect(mocks.signOut).toHaveBeenCalledWith({ scope: "local" });
    expect(response.status).toBe(303);
  });
});
