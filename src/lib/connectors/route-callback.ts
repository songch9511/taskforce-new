import { cookies } from "next/headers";
import { after } from "next/server";

import type { ConnectProvider } from "@/lib/api/contract";
import { authenticateRequest, type ApiContext } from "@/lib/api/auth";
import { hasAiConsent } from "@/lib/api/profile-store";
import { oauthStateSecret } from "@/lib/env";
import { createAdminClient } from "@/lib/supabase/admin";

import { handleOAuthCallback, oauthCookie } from "./callback";
import { afterConnected } from "./registry";
import { consumeOAuthNonce, saveOAuthHandoff } from "./store";
import type { ConnectedStatus } from "./types";

type Admin = ReturnType<typeof createAdminClient>;
type Connect = (
  admin: Admin,
  userId: string,
  code: string,
  context: ApiContext | null,
) => Promise<ConnectedStatus>;

export function handleOAuthCallbackRoute(request: Request, provider: ConnectProvider, connect: Connect): Promise<Response> {
  const admin = createAdminClient();
  let context: ApiContext | null = null;
  return handleOAuthCallback(request, {
    provider,
    stateSecret: () => oauthStateSecret(),
    cookieState: async () => {
      const [state = "", userId = ""] = ((await cookies()).get(oauthCookie(provider).name)?.value ?? "").split(".");
      return state ? { state, userId } : null;
    },
    authenticate: async () => {
      context = await authenticateRequest(request);
      return context?.user ?? null;
    },
    hasConsent: async () => (context ? hasAiConsent(context) : false),
    connect: (userId, code) => connect(admin, userId, code, context),
    onConnected: (userId) => after(() => afterConnected(admin, userId, provider, { firstSync: false })),
    consumeNonce: (payload) => consumeOAuthNonce(admin, payload),
    saveHandoff: ({ id, userId, code }) => saveOAuthHandoff(admin, { id, userId, provider, code }),
  });
}
