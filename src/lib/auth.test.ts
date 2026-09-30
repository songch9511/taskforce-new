import { createClient as createSupabaseClient } from "@supabase/supabase-js";
import { afterEach, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createClient: vi.fn(), redirect: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createClient }));

import { requireUser } from "./auth";

afterEach(() => {
  vi.clearAllMocks();
});

it("redirects to login when a malformed cookie JWT cannot be verified", async () => {
  const userId = "11111111-1111-4111-8111-111111111111";
  const session = {
    access_token: `bnVsbA.${Buffer.from(JSON.stringify({ sub: userId, exp: 4_102_444_800 })).toString("base64url")}.c2ln`,
    token_type: "bearer",
    expires_in: 3600,
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    refresh_token: "local-test-refresh-token",
    user: { id: userId },
  };
  const supabase = createSupabaseClient("https://project.example.test", "sb_publishable_local-test", {
    auth: {
      storage: {
        getItem: async () => JSON.stringify(session),
        setItem: async () => {},
        removeItem: async () => {},
      },
      persistSession: true,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
  mocks.createClient.mockResolvedValue(supabase);
  mocks.redirect.mockImplementation((path: string) => {
    throw new Error(`redirect:${path}`);
  });

  await expect(requireUser()).rejects.toThrow("redirect:/login");
  expect(mocks.redirect).toHaveBeenCalledWith("/login");
});
