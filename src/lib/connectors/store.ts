import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { profileSchema } from "@/lib/api/contract";
import { accountDisplayName, resolveIdentity } from "@/lib/api/profile";
import { processSource } from "@/lib/sources/process";

import { decryptSecret, encryptSecret, parseTokenKey } from "./crypto";
import type { IngestDeps } from "./ingest";
import type { Connection, Provider } from "./types";

// 연결 · 토큰 · 연동 원문을 DB에 읽고 쓴다. 모두 service role 클라이언트로 부르며, 쿼리마다 user_id · connection_id로 범위를 좁힌다.

const tokenKey = () => parseTokenKey(process.env.CONNECTOR_TOKEN_KEY);

export async function saveConnection(
  admin: SupabaseClient,
  input: { userId: string; provider: Provider; externalAccountId: string; displayName: string | null; token: unknown },
): Promise<string> {
  const { data } = await admin
    .from("connections")
    .upsert(
      {
        user_id: input.userId,
        provider: input.provider,
        external_account_id: input.externalAccountId,
        display_name: input.displayName,
        status: "active",
        last_error: null,
      },
      { onConflict: "user_id,provider,external_account_id" },
    )
    .select("id")
    .single()
    .throwOnError();

  await admin
    .from("connection_secrets")
    .upsert({ connection_id: data.id, sealed_token: encryptSecret(JSON.stringify(input.token), tokenKey()), updated_at: new Date().toISOString() })
    .throwOnError();
  return data.id as string;
}

export async function saveToken(admin: SupabaseClient, connectionId: string, token: unknown): Promise<void> {
  await admin
    .from("connection_secrets")
    .update({ sealed_token: encryptSecret(JSON.stringify(token), tokenKey()), updated_at: new Date().toISOString() })
    .eq("connection_id", connectionId)
    .throwOnError();
}

export async function loadToken<T>(admin: SupabaseClient, connectionId: string): Promise<T> {
  const { data } = await admin
    .from("connection_secrets")
    .select("sealed_token")
    .eq("connection_id", connectionId)
    .single()
    .throwOnError();
  return JSON.parse(decryptSecret(data.sealed_token as string, tokenKey())) as T;
}

type ConnectionRow = {
  id: string;
  user_id: string;
  last_synced_at: string | null;
  provider: Provider;
  settings: Record<string, unknown>;
  sync_cursor: Record<string, unknown> | null;
};

/** 동기화할 연결. userId를 주면 그 사용자 것만 (수동 동기화) */
export async function activeConnections(admin: SupabaseClient, provider: Provider, userId?: string): Promise<Connection[]> {
  let query = admin
    .from("connections")
    .select("id, user_id, provider, settings, sync_cursor, last_synced_at")
    .eq("provider", provider)
    .in("status", ["active", "error"]);
  if (userId) query = query.eq("user_id", userId);
  const { data } = await query
    .order("last_synced_at", { ascending: true, nullsFirst: true })
    .returns<ConnectionRow[]>()
    .throwOnError();
  return (data ?? []).map((row) => ({
    id: row.id,
    userId: row.user_id,
    provider: row.provider,
    settings: row.settings,
    syncCursor: row.sync_cursor,
    lastSyncedAt: row.last_synced_at ? new Date(row.last_synced_at) : null,
  }));
}

/** 이 시간보다 오래 잡힌 잠금은 중간에 죽은 실행으로 보고 풀어 준다. */
const SYNC_LEASE_MINUTES = 10;

/**
 * 연결을 동기화하겠다고 잡는다. 다른 실행(cron · 수동)이 잡고 있으면 false.
 * last_synced_at도 함께 옮겨, 중간에 죽은 연결이 매번 맨 앞에 서서 다른 사용자를 막지 않게 한다.
 */
export async function claimConnection(admin: SupabaseClient, connection: Connection, now = new Date()): Promise<boolean> {
  const staleBefore = new Date(now.getTime() - SYNC_LEASE_MINUTES * 60_000).toISOString();
  const { data } = await admin
    .from("connections")
    .update({ sync_started_at: now.toISOString(), last_synced_at: now.toISOString() })
    .eq("id", connection.id)
    .eq("user_id", connection.userId)
    .or(`sync_started_at.is.null,sync_started_at.lt.${staleBefore}`)
    .select("id")
    .throwOnError();
  return (data?.length ?? 0) > 0;
}

export async function recordSync(
  admin: SupabaseClient,
  connection: Connection,
  update: { cursor?: Record<string, unknown>; error?: string | null; revoked?: boolean },
): Promise<void> {
  await admin
    .from("connections")
    .update({
      ...(update.cursor ? { sync_cursor: update.cursor } : {}),
      last_synced_at: new Date().toISOString(),
      last_error: update.error ?? null,
      sync_started_at: null,
      status: update.revoked ? "revoked" : update.error ? "error" : "active",
    })
    .eq("id", connection.id)
    .eq("user_id", connection.userId)
    .throwOnError();
}

/** 연동 원문을 저장하고, 사용자 프로필로 "원문 속 나"를 정해 파이프라인을 돌린다. */
export function ingestDeps(admin: SupabaseClient): IngestDeps {
  return {
    ingestedIds: async (connection, externalIds) => {
      if (externalIds.length === 0) return new Set();
      const { data } = await admin
        .from("sources")
        .select("external_id")
        .eq("user_id", connection.userId)
        .eq("connection_id", connection.id)
        .in("external_id", externalIds)
        .throwOnError();
      return new Set((data ?? []).map((row) => row.external_id as string));
    },

    insertSource: async (connection, item) => {
      const { data, error } = await admin
        .from("sources")
        .insert({
          user_id: connection.userId,
          connection_id: connection.id,
          external_id: item.externalId,
          external_version: item.externalVersion,
          kind: item.kind,
          title: item.title,
          raw_text: item.text,
          occurred_at: item.occurredAt.toISOString(),
          external_url: item.externalUrl,
          participants: item.participants ?? null,
        })
        .select("id")
        .single();
      if (error?.code === "23505") return null; // 동시에 같은 항목을 넣음
      if (error) throw new Error(`원문 저장 실패: ${error.message}`);
      return data.id as string;
    },

    process: async (connection, sourceId, item) => {
      const [{ data: profileRow }, { data: account }] = await Promise.all([
        admin.from("profiles").select("display_name, aliases, emails").eq("user_id", connection.userId).maybeSingle(),
        admin.auth.admin.getUserById(connection.userId),
      ]);
      const email = account.user?.email ?? null;
      const identity = resolveIdentity(profileSchema.safeParse(profileRow).data ?? null, {
        name: accountDisplayName(account.user?.user_metadata, email),
        email,
      });
      await processSource(admin, { id: sourceId, userId: connection.userId }, {
        text: item.text,
        kind: item.kind,
        occurredAt: item.occurredAt,
        identity,
        participants: item.participants,
      });
    },
  };
}
