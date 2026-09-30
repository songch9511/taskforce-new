import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { disconnectConnection, mergeConnectionSettings, otherConnections, saveConnection } from "../store";
import { googleTokenSchema, revokeGoogleToken, type GoogleAccount } from "./oauth";
import { accountSettings } from "./settings";

type GoogleProvider = "gmail" | "google";

const logError = (what: string) => (error: unknown) => console.error(`${what}:`, error instanceof Error ? error.message : error);

export async function revokeStoredGoogleToken(token: unknown): Promise<void> {
  const parsed = googleTokenSchema.safeParse(token);
  if (parsed.success) await revokeGoogleToken(parsed.data.refresh_token ?? parsed.data.access_token);
}

export async function saveGoogleAccount(
  admin: SupabaseClient,
  input: { userId: string; provider: GoogleProvider; account: GoogleAccount; scopes: string[]; token: unknown },
): Promise<string> {
  const connectionId = await saveConnection(admin, {
    userId: input.userId,
    provider: input.provider,
    externalAccountId: input.account.sub,
    displayName: input.account.email,
    token: input.token,
  });
  // 받은 범위를 남긴다: 다시 연결하면 그때 허용한 범위로 바뀐다 (동기화는 받은 것만 쓴다). 그 키만 바꿔 통계는 그대로 둔다.
  const merged = await mergeConnectionSettings(admin, { id: connectionId, userId: input.userId }, { set: accountSettings(input.account, input.scopes) });
  if (!merged) {
    throw new Error("연결 설정을 저장하지 못했습니다 (연결이 사라짐)");
  }
  return connectionId;
}

export async function disconnectOtherGoogleAccounts(
  admin: SupabaseClient,
  userId: string,
  provider: GoogleProvider,
  keepId: string,
): Promise<void> {
  const service = provider === "gmail" ? "Gmail" : "Google";
  for (const other of await otherConnections(admin, userId, provider, keepId)) {
    await revokeStoredGoogleToken(other.token).catch(logError(`옛 ${service} 연결 토큰 폐기 실패 (${other.id})`));
    await disconnectConnection(admin, userId, other.id).catch(logError(`옛 ${service} 연결 끊기 실패 (${other.id})`));
  }
}
