import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { connectionSettingsSchema, profileInputSchema, type DataSourceSetting } from "@/lib/api/contract";
import { accountDisplayName, resolveIdentity } from "@/lib/api/profile";
import { ConsentRequiredError } from "@/lib/consent/gate";
import type { UserIdentity } from "@/lib/pipeline/identity";
import { renderSnapshot, type TaskSnapshot } from "@/lib/pipeline/structured";
import { processSource, processTaskSource } from "@/lib/sources/process";

import { decryptSecret, encryptSecret, parseTokenKey } from "./crypto";
import type { IngestDeps } from "./ingest";
import type { AutoConfirmed, AutoConfirmReverted, Backfilled, NotionTaskDeps, SeenDataSource, UnreachableDataSource } from "./notion/sync";
import type { OAuthStatePayload } from "./oauth-state";
import type { TaskItem, TaskState } from "./tasks-ingest";
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
        // 다시 연결한 시각: 늦게 온 Slack 앱 해제 이벤트가 새 연결을 끊지 않게 한다 (slack/receive.ts)
        connected_at: new Date().toISOString(),
      },
      { onConflict: "user_id,provider,external_account_id" },
    )
    .select("id, settings")
    .single()
    .throwOnError();

  await admin
    .from("connection_secrets")
    .upsert({ connection_id: data.id, sealed_token: encryptSecret(JSON.stringify(input.token), tokenKey()), updated_at: new Date().toISOString() })
    .throwOnError();

  // 다시 연결: 같은 워크스페이스를 다른 Notion 계정으로 다시 연결하면 연결 행은 그대로라, 남겨 둔 Notion user id가 남으면
  // 그 사람이 쓴 문서가 written_by_me = true가 된다. 그 키만 지운다 (다음 동기화가 새 토큰의 봇 주인으로 다시 알아낸다). 없으면 쓰지 않는다.
  const settings = data.settings as Record<string, unknown> | null;
  if (settings && "notionUserId" in settings) await mergeConnectionSettings(admin, { id: data.id, userId: input.userId }, { remove: ["notionUserId"] });
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

/**
 * 동기화할 연결 (연결 오래 안 한 순서). userId를 주면 그 사용자 것만 (수동 동기화). reauth · revoked는 다시 연결할 때까지 돌리지 않는다.
 * 외부 AI 처리에 동의하지 않은 사용자의 연결은 쿼리에서 빠진다 (syncable_connections, 20261003000000).
 */
export async function activeConnections(admin: SupabaseClient, providers: Provider[], userId?: string): Promise<Connection[]> {
  if (providers.length === 0) return [];
  const { data } = await admin.rpc("syncable_connections", { p_providers: providers, p_user_id: userId ?? null }).throwOnError();
  return ((data ?? []) as ConnectionRow[]).map((row) => ({
    id: row.id,
    userId: row.user_id,
    provider: row.provider,
    settings: row.settings,
    syncCursor: row.sync_cursor,
    lastSyncedAt: row.last_synced_at ? new Date(row.last_synced_at) : null,
  }));
}

/** 앱 OAuth 시작: 서명된 state의 nonce를 남긴다. 그 사용자의 만료된 nonce는 함께 치운다. */
export async function saveOAuthNonce(admin: SupabaseClient, payload: OAuthStatePayload, now = new Date()): Promise<void> {
  await admin.from("oauth_nonces").delete().eq("user_id", payload.userId).lt("expires_at", now.toISOString()).throwOnError();
  await admin
    .from("oauth_nonces")
    .insert({ nonce: payload.nonce, user_id: payload.userId, provider: payload.provider, expires_at: new Date(payload.exp * 1000).toISOString() })
    .throwOnError();
}

/** 앱 OAuth 완료 대기 (handoff): 시작한 사용자가 앱에서 2분 안에 한 번만 완료할 수 있다 */
export const OAUTH_HANDOFF_TTL_MS = 2 * 60_000;

/** callback: code를 암호화해 두고 handoff id를 돌려준다. id는 32바이트 난수(base64url)라 추측할 수 없다. */
export async function saveOAuthHandoff(
  admin: SupabaseClient,
  input: { id: string; userId: string; provider: Provider; code: string },
  now = new Date(),
): Promise<void> {
  await admin
    .from("oauth_handoffs")
    .insert({
      id: input.id,
      user_id: input.userId,
      provider: input.provider,
      sealed_code: encryptSecret(input.code, tokenKey()),
      expires_at: new Date(now.getTime() + OAUTH_HANDOFF_TTL_MS).toISOString(),
    })
    .throwOnError();
}

/**
 * 완료: id · 로그인한 사용자 · 서비스가 모두 맞고 만료 전인 handoff를 지우며 code를 꺼낸다 (한 번만, 한 문장이라 동시에 두 번 꺼낼 수 없다).
 * 없거나 다른 사용자 것이면 null.
 */
export async function consumeOAuthHandoff(
  admin: SupabaseClient,
  input: { id: string; userId: string; provider: Provider },
  now = new Date(),
): Promise<string | null> {
  const { data } = await admin
    .from("oauth_handoffs")
    .delete()
    .eq("id", input.id)
    .eq("user_id", input.userId)
    .eq("provider", input.provider)
    .gt("expires_at", now.toISOString())
    .select("sealed_code")
    .throwOnError();
  const row = (data ?? [])[0] as { sealed_code: string } | undefined;
  return row ? decryptSecret(row.sealed_code, tokenKey()) : null;
}

/** 만료된 nonce · handoff를 모두 지운다 (주기 동기화 cron). 지운 수 */
export async function sweepExpiredOAuth(admin: SupabaseClient, now = new Date()): Promise<{ nonces: number; handoffs: number }> {
  const at = now.toISOString();
  const [{ count: nonces }, { count: handoffs }] = await Promise.all([
    admin.from("oauth_nonces").delete({ count: "exact" }).lt("expires_at", at).throwOnError(),
    admin.from("oauth_handoffs").delete({ count: "exact" }).lt("expires_at", at).throwOnError(),
  ]);
  return { nonces: nonces ?? 0, handoffs: handoffs ?? 0 };
}

/** callback: nonce를 지우며 확인한다 (한 번만 쓴다). 사용자 · 서비스가 다르거나 만료됐으면 false. */
export async function consumeOAuthNonce(admin: SupabaseClient, payload: OAuthStatePayload, now = new Date()): Promise<boolean> {
  const { data } = await admin
    .from("oauth_nonces")
    .delete()
    .eq("nonce", payload.nonce)
    .eq("user_id", payload.userId)
    .eq("provider", payload.provider)
    .gt("expires_at", now.toISOString())
    .select("nonce")
    .throwOnError();
  return (data?.length ?? 0) > 0;
}

/** 연결 완료 지표 (설치 → 연결 → 첫 Action 흐름). 서버만 남긴다. provider로 재연결 알림(connection_reauth · reconnect_notified)과 서비스별로 맞춘다. */
export async function recordConnectionCreated(admin: SupabaseClient, userId: string, provider: Provider): Promise<void> {
  await admin.from("metric_events").insert({ user_id: userId, type: "connection_created", provider }).throwOnError();
}

/** 계정 삭제 전 폐기할 연동 토큰: 사용자의 모든 연결과 풀어 둔 토큰 (풀지 못한 것은 null) */
export async function userConnectionTokens(admin: SupabaseClient, userId: string): Promise<{ connectionId: string; provider: Provider; token: unknown }[]> {
  const { data } = await admin.from("connections").select("id, provider").eq("user_id", userId).throwOnError();
  const rows = (data ?? []) as { id: string; provider: Provider }[];
  return Promise.all(
    rows.map(async (row) => ({ connectionId: row.id, provider: row.provider, token: await loadToken(admin, row.id).catch(() => null) })),
  );
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

/**
 * 동기화 결과를 연결 상태로 남긴다. revoked: 서비스 쪽에서 권한이 끊김, reauth: 토큰을 더 갱신할 수 없음(갱신 토큰 만료 · 거절).
 * 둘 다 다시 연결할 때까지 동기화하지 않는다 (syncable_connections). 다시 연결하면 saveConnection이 active로 되돌린다.
 * 돌려주는 값: 이 호출이 연결을 reauth로 바꿨는가. 이미 reauth였거나 · 끊겼거나(revoked) · 그 사이 다시 연결했으면 false.
 * 바꿨으면 지표 이벤트 connection_reauth를 남긴다(알림이 갔는지와 상관없이 만료를 센다, 실패해도 동기화에는 영향 없다).
 * 알림 한 번(재연결 안내)은 이 값이 true일 때만 보낸다 (docs/go-live/google-integration.md G9).
 *
 * 불변식: reauth가 아닌 기록(active · error)은 reauth 연결을 덮어쓰지 않는다. reauth 연결은 syncable_connections가 고르지 않아 새 동기화가 시작되지 않고,
 * 같은 연결의 동기화는 겹치지 않는다(claimConnection 잠금 SYNC_LEASE_MINUTES = 10분 > 함수 최대 실행 300초). reauth로 바꾸는 곳은 이 함수뿐이다.
 */
export async function recordSync(
  admin: SupabaseClient,
  connection: Connection,
  /** claimedAt: 이 동기화가 잠금을 잡은 시각 (claimConnection의 now) */
  update: { claimedAt: Date; cursor?: Record<string, unknown>; error?: string | null; revoked?: boolean; reauth?: boolean },
): Promise<boolean> {
  let query = admin
    .from("connections")
    .update({
      ...(update.cursor ? { sync_cursor: update.cursor } : {}),
      last_synced_at: new Date().toISOString(),
      last_error: update.error ?? null,
      sync_started_at: null,
      status: update.revoked ? "revoked" : update.reauth ? "reauth" : update.error ? "error" : "active",
    })
    .eq("id", connection.id)
    .eq("user_id", connection.userId)
    // 동기화 도중 다시 연결했으면(saveConnection이 connected_at을 새로 적음) 새 연결의 상태 · 커서를 덮지 않는다: 잠금만 푼다
    .lte("connected_at", update.claimedAt.toISOString());
  // 동기화 도중 끊긴 연결(Slack 앱 해제 · 토큰 오류, revoked)은 되살리지 않는다: 잠금만 푼다
  if (!update.revoked) query = query.neq("status", "revoked");
  // 이미 reauth인 연결에 reauth를 또 적지 않는다: 한 문장의 조건이라 "바꿨는가"가 같은 순간에 정해진다 (알림이 두 번 가지 않게)
  const toReauth = !update.revoked && Boolean(update.reauth);
  if (toReauth) query = query.neq("status", "reauth");
  const { data } = await query.select("id").throwOnError();
  const matched = (data?.length ?? 0) > 0;
  if (!matched) {
    await admin.from("connections").update({ sync_started_at: null }).eq("id", connection.id).eq("user_id", connection.userId).throwOnError();
  }
  const changed = matched && toReauth;
  if (changed) await recordConnectionReauth(admin, connection);
  return changed;
}

/** 연결이 reauth로 바뀐 것을 지표로 남긴다 (원칙 6). 기록이 실패해도 동기화 · 알림은 그대로다: 오류 로그만 (연결 id · 서비스뿐) */
async function recordConnectionReauth(admin: SupabaseClient, connection: Connection): Promise<void> {
  try {
    await admin.from("metric_events").insert({ user_id: connection.userId, type: "connection_reauth", provider: connection.provider }).throwOnError();
  } catch (error) {
    console.error(`재연결 필요 지표 기록 실패 (${connection.provider} ${connection.id}):`, error instanceof Error ? error.message : error);
  }
}

/** "이미 넣음"을 한 번에 묻는 외부 id 수 */
const INGESTED_IDS_CHUNK = 150;

/**
 * 연동 원문을 저장하고, 사용자 프로필로 "원문 속 나"를 정해 파이프라인을 돌린다.
 * notifyFrom을 주면 그보다 앞 시각의 원문(연결 전 메일을 한꺼번에 가져옴)은 확인 요청 알림을 보내지 않는다 (Gmail, 2-2).
 */
export function ingestDeps(admin: SupabaseClient, options: { notifyFrom?: Date | null } = {}): IngestDeps {
  return {
    ingestedIds: async (connection, externalIds) => {
      const found = new Set<string>();
      // 요청 주소가 길어지지 않게 나눠 묻는다 (Gmail은 한 창에 id가 수백 · 수천 개)
      for (let i = 0; i < externalIds.length; i += INGESTED_IDS_CHUNK) {
        // 연결을 끊으면 원문의 connection_id가 비고, 다시 연결하면 새 연결이 된다. 비워진 이 사용자의 원문도 이미 넣은 것으로 본다:
        // 최근 14일을 다시 넣어 같은 원문을 두 번 처리하지 않게 (external_id는 서비스의 전역 id)
        const { data } = await admin
          .from("sources")
          .select("external_id")
          .eq("user_id", connection.userId)
          .or(`connection_id.eq.${connection.id},connection_id.is.null`)
          .in("external_id", externalIds.slice(i, i + INGESTED_IDS_CHUNK))
          .throwOnError();
        for (const row of data ?? []) found.add(row.external_id as string);
      }
      return found;
    },

    insertSource: async (connection, item) => {
      const row: Record<string, unknown> = {
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
        written_by_me: item.writtenByMe ?? null,
      };
      // 일정이 붙은 원문만 meeting 열을 보낸다: 마이그레이션(20261016000000_sources_meeting)을 적용하기 전에 배포해도 다른 원문의 저장은 그대로 된다
      let { data, error } = await admin
        .from("sources")
        .insert(item.meeting ? { ...row, meeting: item.meeting } : row)
        .select("id")
        .single();
      // 그래도 열이 아직 없으면(PostgREST PGRST204 · Postgres 42703) 일정 없이 다시 넣는다: 일정 붙이기가 Notion 동기화를 막지 않게.
      // 그 원문은 일정 연결(근거 줄의 일정 제목)을 잃는다. 원인은 마이그레이션 미적용이므로 로그에 남긴다 (원문은 남기지 않는다)
      if (item.meeting && (error?.code === "PGRST204" || error?.code === "42703")) {
        console.error("sources.meeting 열이 없어 일정 없이 저장합니다. 마이그레이션 20261016000000_sources_meeting을 적용하세요.");
        ({ data, error } = await admin.from("sources").insert(row).select("id").single());
      }
      if (error?.code === "23505") return null; // 동시에 같은 항목을 넣음
      if (error) throw new Error(`원문 저장 실패: ${error.message}`);
      return (data as { id: string }).id;
    },

    process: async (connection, sourceId, item) => {
      const identity = await loadIdentity(admin, connection.userId);
      try {
        const notify = !options.notifyFrom || item.occurredAt >= options.notifyFrom;
        await processSource(admin, { id: sourceId, userId: connection.userId, notify }, {
          text: item.text,
          kind: item.kind,
          occurredAt: item.occurredAt,
          identity,
          participants: item.participants,
          writtenByMe: item.writtenByMe,
          // 연결로 가져온 원문: 메일이면 스레드의 앞선 메일이 따로 들어오므로 인용된 옛 메일 속 후보는 버린다 (pipeline/verify.ts)
          fromConnector: true,
        });
      } catch (error) {
        // 동의를 철회해 처리하지 못한 원문은, 아직 아무 Action의 근거도 되지 않았으면 지운다:
        // 다시 동의하면 다음 동기화가 같은 항목을 새로 가져와 처리한다 (남겨 두면 "이미 넣은 항목"으로 건너뛴다).
        if (error instanceof ConsentRequiredError) await forgetUnprocessedSource(admin, connection, sourceId);
        throw error;
      }
    },
  };
}

async function forgetUnprocessedSource(admin: SupabaseClient, connection: Connection, sourceId: string): Promise<void> {
  const { count } = await admin
    .from("evidence")
    .select("id", { count: "exact", head: true })
    .eq("user_id", connection.userId)
    .eq("source_id", sourceId)
    .throwOnError();
  if ((count ?? 0) > 0) return;
  await admin.from("sources").delete().eq("id", sourceId).eq("user_id", connection.userId).throwOnError();
}

/**
 * 사용자 프로필(이름 · 별칭 · 이메일)과 계정으로 "원문 속 나"를 정한다.
 * 연결한 Google 계정 주소(google · gmail 연결의 settings.email)도 사용자 주소로 본다: 로그인 주소와 다른 회사 Gmail이어도
 * "보낸 사람 = 나"를 알아본다.
 */
export async function loadIdentity(admin: SupabaseClient, userId: string): Promise<UserIdentity> {
  const [{ data: profileRow }, { data: account }, { data: googleRows }] = await Promise.all([
    admin.from("profiles").select("display_name, aliases, emails").eq("user_id", userId).maybeSingle(),
    admin.auth.admin.getUserById(userId),
    admin.from("connections").select("settings").eq("user_id", userId).in("provider", ["google", "gmail"]),
  ]);
  const email = account.user?.email ?? null;
  const identity = resolveIdentity(profileInputSchema.safeParse(profileRow).data ?? null, {
    name: accountDisplayName(account.user?.user_metadata, email),
    email,
  });
  const googleEmails = ((googleRows ?? []) as { settings: { email?: unknown } | null }[]).flatMap(({ settings }) =>
    typeof settings?.email === "string" ? [settings.email.trim().toLowerCase()] : [],
  );
  return { ...identity, emails: [...new Set([...identity.emails, ...googleEmails])] };
}

/** 연결을 (다시) 맺은 시각. 없으면 null */
export async function connectedAt(admin: SupabaseClient, connection: Pick<Connection, "id" | "userId">): Promise<Date | null> {
  const { data } = await admin
    .from("connections")
    .select("connected_at")
    .eq("id", connection.id)
    .eq("user_id", connection.userId)
    .maybeSingle<{ connected_at: string }>()
    .throwOnError();
  return data ? new Date(data.connected_at) : null;
}

/** 연결 설정에서 바꿀 것 (mergeConnectionSettings) */
export type ConnectionSettingsPatch = {
  /** 위 수준 키를 이 값으로 바꾼다 */
  set?: Record<string, unknown>;
  /** 뺄 위 수준 키 */
  remove?: string[];
  /** Notion DB 설정(settings.dataSources)에서 이 DB들의 설정만 통째로 바꾼다 */
  dataSources?: Record<string, DataSourceSetting>;
};

/**
 * 연결 설정에서 넘긴 키만 바꾼다. 나머지 값(통계 · 다른 DB 설정 등)은 DB에 있는 지금 값 그대로 둔다.
 * 설정 전체를 읽고 다시 쓰지 않고 DB 함수 한 번으로 합치므로(merge_connection_settings, 20261017000000), 같은 연결의 설정을 동시에 쓰는 쪽을 되돌리지 않는다.
 * 돌려주는 값: 고친 연결이 있는가 (그 사이 끊겨 없으면 false).
 */
export async function mergeConnectionSettings(
  admin: SupabaseClient,
  connection: Pick<Connection, "id" | "userId">,
  patch: ConnectionSettingsPatch,
): Promise<boolean> {
  const { data } = await admin
    .rpc("merge_connection_settings", {
      p_user_id: connection.userId,
      p_connection_id: connection.id,
      p_set: patch.set ?? {},
      p_remove: patch.remove ?? [],
      p_data_sources: patch.dataSources ?? {},
    })
    .throwOnError();
  return data === true;
}

/**
 * 이번 동기화의 개수(이유 코드별, 글자 · 주소 없이)를 연결 설정 통계(settings.stats)에 더한다. 0 · undefined는 빼고, 더할 것이 없으면 부르지 않는다.
 * DB 함수가 연결 행을 잠근 채 더하므로(add_connection_stats, 20261017000000) 동시에 더한 개수가 모두 남는다.
 * 처음이면 now부터 세고, 저장된 통계 모양이 다르면 새로 센다.
 */
export async function addConnectionStats(
  admin: SupabaseClient,
  connection: Pick<Connection, "id" | "userId">,
  counts: Partial<Record<string, number>>,
  now: Date,
): Promise<void> {
  const added = Object.entries(counts).filter((entry): entry is [string, number] => (entry[1] ?? 0) > 0);
  if (added.length === 0) return;
  await admin
    .rpc("add_connection_stats", {
      p_user_id: connection.userId,
      p_connection_id: connection.id,
      p_counts: Object.fromEntries(added),
      p_now: now.toISOString(),
    })
    .throwOnError();
}

/** 같은 서비스의 다른 연결 (다른 계정으로 다시 연결했을 때 끊을 옛 연결)과 풀어 둔 토큰 (풀지 못했으면 null) */
export async function otherConnections(
  admin: SupabaseClient,
  userId: string,
  provider: Provider,
  keepId: string,
): Promise<{ id: string; token: unknown }[]> {
  const { data } = await admin.from("connections").select("id").eq("user_id", userId).eq("provider", provider).neq("id", keepId).throwOnError();
  return Promise.all(((data ?? []) as { id: string }[]).map(async ({ id }) => ({ id, token: await loadToken(admin, id).catch(() => null) })));
}

/** 연결을 끊는다 (DELETE /api/v1/connections/:id와 같은 RPC: Slack이면 Slack 글자도 지운다). 없었으면 false */
export async function disconnectConnection(admin: SupabaseClient, userId: string, connectionId: string): Promise<boolean> {
  const { data } = await admin.rpc("disconnect_connection", { p_user_id: userId, p_connection_id: connectionId }).throwOnError();
  return data === true;
}

/** 이보다 오래 "처리 중"인 할 일 원문은 중간에 죽은 실행으로 보고 다시 처리한다. */
const TASK_PROCESSING_STALE_MINUTES = 10;
/** 처리를 마치지 못한 할 일은 이 기간 안에서만 다시 처리한다. 한 번에 이만큼씩 */
const TASK_RETRY_DAYS = 3;
/** 상태 함수 한 번에 넘기는 항목 수 (결과 행 수 한도 1,000 아래로: 항목마다 최대 2행) */
const TASK_STATE_CHUNK = 200;

/** sources.structured (kind = task) */
type StoredTask = { snapshot: TaskSnapshot; editedByUser: boolean };

type TaskStateRow = {
  external_id: string;
  source_id: string;
  external_version: string;
  /** 보관 기간(90일)이 지나 원문이 비워졌으면 null (purge_expired_source_text) */
  structured: StoredTask | null;
  processing_status: "pending" | "processing" | "done" | "failed" | "blocked";
  started_at: string;
  linked: boolean;
};

/** 항목마다 비교 기준(마지막으로 처리를 마친 버전)과 다시 처리할 버전 */
async function taskStates(admin: SupabaseClient, connection: Connection, externalIds: string[]): Promise<Map<string, TaskState>> {
  const states = new Map<string, TaskState>();
  const staleBefore = Date.now() - TASK_PROCESSING_STALE_MINUTES * 60_000;
  for (let i = 0; i < externalIds.length; i += TASK_STATE_CHUNK) {
    const { data } = await admin
      .rpc("task_source_states", {
        p_user_id: connection.userId,
        p_connection_id: connection.id,
        p_external_ids: externalIds.slice(i, i + TASK_STATE_CHUNK),
      })
      .throwOnError();
    for (const row of (data ?? []) as TaskStateRow[]) {
      const state = states.get(row.external_id) ?? { linked: row.linked };
      if (row.processing_status === "done") {
        state.done = { version: row.external_version, snapshot: row.structured?.snapshot ?? null };
      } else if (row.processing_status === "blocked") {
        state.blockedVersion = row.external_version;
      } else if (row.processing_status === "failed" || new Date(row.started_at).getTime() < staleBefore) {
        state.retry = { sourceId: row.source_id, version: row.external_version };
      } else {
        state.inFlight = true;
      }
      states.set(row.external_id, state);
    }
  }
  // 처리를 마친 버전보다 오래된 실패는 다시 처리하지 않는다 (그 뒤 버전이 이미 반영됐다).
  for (const state of states.values()) {
    if (state.retry && state.done && state.retry.version <= state.done.version) delete state.retry;
  }
  return states;
}

/** 구조화된 할 일(할 일 DB)을 원문으로 저장하고 처리한다. */
export function taskDeps(admin: SupabaseClient): NotionTaskDeps {
  return {
    identity: (connection) => loadIdentity(admin, connection.userId),

    taskStates: (connection, externalIds) => taskStates(admin, connection, externalIds),

    pendingTasks: async (connection) => {
      const since = new Date(Date.now() - TASK_RETRY_DAYS * 86_400_000).toISOString();
      const { data } = await admin
        .rpc("pending_task_sources", { p_user_id: connection.userId, p_connection_id: connection.id, p_since: since })
        .throwOnError();
      const rows = (data ?? []) as { id: string; external_id: string; external_version: string; structured: StoredTask; occurred_at: string; external_url: string | null }[];
      if (rows.length === 0) return [];
      // 항목마다 다시 처리할 버전(가장 최근의 실패 · 멈춤, 처리를 마친 버전보다 새것)만 고른다.
      const states = await taskStates(admin, connection, [...new Set(rows.map((r) => r.external_id))]);
      return rows.flatMap((row) => {
        const state = states.get(row.external_id);
        if (state?.retry?.sourceId !== row.id) return [];
        const item: TaskItem = {
          externalId: row.external_id,
          externalVersion: row.external_version,
          snapshot: row.structured.snapshot,
          editedByUser: row.structured.editedByUser,
          lastEditedAt: new Date(row.occurred_at),
          externalUrl: row.external_url,
        };
        return [{ sourceId: row.id, item, prev: state.linked ? (state.done?.snapshot ?? null) : null }];
      });
    },

    insertTaskSource: async (connection, item) => {
      const { data, error } = await admin
        .from("sources")
        .insert({
          user_id: connection.userId,
          connection_id: connection.id,
          external_id: item.externalId,
          external_version: item.externalVersion,
          kind: "task",
          title: item.snapshot.title,
          raw_text: renderSnapshot(item.snapshot),
          structured: { snapshot: item.snapshot, editedByUser: item.editedByUser } satisfies StoredTask,
          occurred_at: item.lastEditedAt.toISOString(),
          external_url: item.externalUrl,
        })
        .select("id")
        .single();
      if (error?.code === "23505") return null; // 동시에 같은 버전을 넣음
      if (error) throw new Error(`원문 저장 실패: ${error.message}`);
      return data.id as string;
    },

    processTask: async (connection, sourceId, item, prev) => {
      await processTaskSource(
        admin,
        { id: sourceId, userId: connection.userId, connectionId: connection.id },
        {
          externalId: item.externalId,
          snapshot: item.snapshot,
          prev,
          edit: { editedByUser: item.editedByUser, occurredAt: item.lastEditedAt },
          identity: await loadIdentity(admin, connection.userId),
        },
      );
    },
  };
}

/**
 * 할 일 DB를 처음 훑었다고 남긴다. 그 사이 사용자가 설정을 다시 확인했으면(confirmedAt이 다르면) 새 설정으로는 아직 훑지 않았으므로 남기지 않는다.
 * 지금 값을 다시 읽어 그 DB의 설정만 고친다 (다른 DB의 설정 · 다른 키는 DB에 있는 값 그대로, mergeConnectionSettings).
 */
export async function markBackfilled(admin: SupabaseClient, connection: Connection, done: Backfilled[], now = new Date()): Promise<void> {
  if (done.length === 0) return;
  const { data } = await admin.from("connections").select("settings").eq("id", connection.id).eq("user_id", connection.userId).single().throwOnError();
  const saved = connectionSettingsSchema.parse(data.settings ?? {}).dataSources ?? {};
  const changed: Record<string, DataSourceSetting> = {};
  for (const { dataSourceId, confirmedAt } of done) {
    const current = saved[dataSourceId];
    if (current?.role !== "tasks" || current.confirmedAt !== confirmedAt) continue;
    changed[dataSourceId] = { ...current, backfilledAt: now.toISOString() };
  }
  if (Object.keys(changed).length === 0) return;
  await mergeConnectionSettings(admin, connection, { dataSources: changed });
}

/**
 * 동기화가 본 연결 상태를 남긴다: 처음 본 DB(확인 전, seenAt)와 전에 읽던 DB 중 지금 읽을 수 없는 것(health.unreachable).
 * 공유가 조용히 끊기면 원문이 들어오지 않아도 알 수 없으므로, 앱 · /lab이 이 값으로 경고를 띄운다.
 * 연결한 사람의 Notion user id(notionUserId)를 처음 알아냈으면 함께 남겨, 다음 동기화부터 다시 묻지 않는다.
 * 자동 확인한 할 일 DB(autoConfirmed)와 자동 확인을 되돌린 DB(reverted)도 남긴다. markBackfilled보다 먼저 불러야 처음 훑기 표시가 이 확인 시각과 맞는다.
 * claimedAt: 이 동기화가 잠금을 잡은 시각. 그 뒤에 다시 연결했으면(saveConnection이 connected_at을 새로 적고 notionUserId를 뺌)
 * 옛 연결로 알아낸 notionUserId를 다시 쓰지 않는다 (다른 Notion 계정으로 다시 연결했을 수 있다, recordSync와 같은 기준).
 */
export async function recordNotionHealth(
  admin: SupabaseClient,
  connection: Connection,
  report: {
    seen: SeenDataSource[];
    unreachable: UnreachableDataSource[] | null;
    notionUserId?: string | null;
    autoConfirmed?: AutoConfirmed[];
    reverted?: AutoConfirmReverted[];
  },
  now = new Date(),
  claimedAt?: Date,
): Promise<void> {
  const { data } = await admin
    .from("connections")
    .select("settings, connected_at")
    .eq("id", connection.id)
    .eq("user_id", connection.userId)
    .single()
    .throwOnError();
  const settings = connectionSettingsSchema.parse(data.settings ?? {});
  const reconnected = claimedAt !== undefined && typeof data.connected_at === "string" && new Date(data.connected_at) > claimedAt;
  const saved = settings.dataSources ?? {};
  // 동기화는 확인 전 DB와 자동 확인한 DB(매핑이 바뀌어 다시 확인 · 되돌림)만 바꾼다.
  // 그 사이 사용자가 확인한 DB(가져오지 않음 · 글 원문 포함)는 덮지 않는다.
  const changed: Record<string, DataSourceSetting> = {};
  const confirmed = (report.autoConfirmed ?? []).filter(({ id }) => !saved[id]?.confirmedAt || saved[id]?.confirmedBy === "auto");
  const reverted = (report.reverted ?? []).filter(({ id }) => saved[id]?.confirmedBy === "auto");
  for (const { id, setting } of [...confirmed, ...reverted]) changed[id] = setting;
  const added = report.seen.filter(({ id }) => !saved[id] && !changed[id]);
  for (const { id, title, role } of added) changed[id] = { role, title: title?.slice(0, 200) ?? null, seenAt: now.toISOString() };
  const notionUserId = !reconnected && report.notionUserId && report.notionUserId !== settings.notionUserId ? report.notionUserId : null;
  // 바뀐 것이 있을 때만, 바뀐 DB의 설정과 값만 쓴다 (다른 DB의 설정 · 다른 키는 DB에 있는 값 그대로, mergeConnectionSettings).
  // 끝까지 확인하지 못한 동기화(null)는 지난 결과를 그대로 둔다.
  const key = (list: UnreachableDataSource[]) => list.map((d) => d.id).sort().join(",");
  if (added.length === 0 && confirmed.length === 0 && reverted.length === 0 && !notionUserId && (!report.unreachable || key(settings.health?.unreachable ?? []) === key(report.unreachable))) return;
  await mergeConnectionSettings(admin, connection, {
    set: {
      ...(report.unreachable ? { health: { unreachable: report.unreachable, checkedAt: now.toISOString() } } : {}),
      ...(notionUserId ? { notionUserId } : {}),
    },
    dataSources: changed,
  });
}
