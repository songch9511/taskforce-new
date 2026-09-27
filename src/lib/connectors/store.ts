import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { connectionSettingsSchema, profileSchema } from "@/lib/api/contract";
import { accountDisplayName, resolveIdentity } from "@/lib/api/profile";
import type { UserIdentity } from "@/lib/pipeline/identity";
import { renderSnapshot, type TaskSnapshot } from "@/lib/pipeline/structured";
import { processSource, processTaskSource } from "@/lib/sources/process";

import { decryptSecret, encryptSecret, parseTokenKey } from "./crypto";
import type { IngestDeps } from "./ingest";
import type { Backfilled, NotionTaskDeps, SeenDataSource, UnreachableDataSource } from "./notion/sync";
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
      const identity = await loadIdentity(admin, connection.userId);
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

/** 사용자 프로필(이름 · 별칭 · 이메일)과 계정으로 "원문 속 나"를 정한다. */
export async function loadIdentity(admin: SupabaseClient, userId: string): Promise<UserIdentity> {
  const [{ data: profileRow }, { data: account }] = await Promise.all([
    admin.from("profiles").select("display_name, aliases, emails").eq("user_id", userId).maybeSingle(),
    admin.auth.admin.getUserById(userId),
  ]);
  const email = account.user?.email ?? null;
  return resolveIdentity(profileSchema.safeParse(profileRow).data ?? null, {
    name: accountDisplayName(account.user?.user_metadata, email),
    email,
  });
}

/** 이보다 오래 "처리 중"인 할 일 원문은 중간에 죽은 실행으로 보고 다시 처리한다. */
const TASK_PROCESSING_STALE_MINUTES = 10;
/** 처리를 마치지 못한 할 일은 이 기간 안에서만 다시 처리한다. 한 번에 이만큼씩 */
const TASK_RETRY_DAYS = 3;
const TASK_RETRY_BATCH = 20;
/** 상태 함수 한 번에 넘기는 항목 수 (결과 행 수 한도 1,000 아래로: 항목마다 최대 2행) */
const TASK_STATE_CHUNK = 200;

/** sources.structured (kind = task) */
type StoredTask = { snapshot: TaskSnapshot; editedByUser: boolean };

type TaskStateRow = {
  external_id: string;
  source_id: string;
  external_version: string;
  structured: StoredTask;
  processing_status: "pending" | "processing" | "done" | "failed";
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
        state.done = { version: row.external_version, snapshot: row.structured.snapshot };
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
        .from("sources")
        .select("id, external_id, external_version, structured, occurred_at, external_url")
        .eq("user_id", connection.userId)
        .eq("connection_id", connection.id)
        .eq("kind", "task")
        .neq("processing_status", "done")
        .gte("created_at", since)
        .order("occurred_at")
        .limit(TASK_RETRY_BATCH)
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
 * 지금 값을 다시 읽어 그 항목만 고친다.
 */
export async function markBackfilled(admin: SupabaseClient, connection: Connection, done: Backfilled[], now = new Date()): Promise<void> {
  if (done.length === 0) return;
  const { data } = await admin.from("connections").select("settings").eq("id", connection.id).eq("user_id", connection.userId).single().throwOnError();
  const settings = connectionSettingsSchema.parse(data.settings ?? {});
  const dataSources = { ...(settings.dataSources ?? {}) };
  let changed = false;
  for (const { dataSourceId, confirmedAt } of done) {
    const current = dataSources[dataSourceId];
    if (current?.role !== "tasks" || current.confirmedAt !== confirmedAt) continue;
    dataSources[dataSourceId] = { ...current, backfilledAt: now.toISOString() };
    changed = true;
  }
  if (!changed) return;
  await admin
    .from("connections")
    .update({ settings: { ...settings, dataSources } })
    .eq("id", connection.id)
    .eq("user_id", connection.userId)
    .throwOnError();
}

/**
 * 동기화가 본 연결 상태를 남긴다: 처음 본 DB(확인 전, seenAt)와 전에 읽던 DB 중 지금 읽을 수 없는 것(health.unreachable).
 * 공유가 조용히 끊기면 원문이 들어오지 않아도 알 수 없으므로, 앱 · /lab이 이 값으로 경고를 띄운다.
 */
export async function recordNotionHealth(
  admin: SupabaseClient,
  connection: Connection,
  report: { seen: SeenDataSource[]; unreachable: UnreachableDataSource[] | null },
  now = new Date(),
): Promise<void> {
  const { data } = await admin.from("connections").select("settings").eq("id", connection.id).eq("user_id", connection.userId).single().throwOnError();
  const settings = connectionSettingsSchema.parse(data.settings ?? {});
  const dataSources = { ...(settings.dataSources ?? {}) };
  const added = report.seen.filter(({ id }) => !dataSources[id]);
  for (const { id, title, role } of added) dataSources[id] = { role, title: title?.slice(0, 200) ?? null, seenAt: now.toISOString() };
  // 바뀐 것이 있을 때만 쓴다: 설정 전체를 다시 쓰므로, 매 동기화마다 쓰면 그 사이 /lab에서 저장한 설정을 덮을 수 있다.
  // 끝까지 확인하지 못한 동기화(null)는 지난 결과를 그대로 둔다.
  const key = (list: UnreachableDataSource[]) => list.map((d) => d.id).sort().join(",");
  const health = report.unreachable ? { unreachable: report.unreachable, checkedAt: now.toISOString() } : settings.health;
  if (added.length === 0 && (!report.unreachable || key(settings.health?.unreachable ?? []) === key(report.unreachable))) return;
  await admin
    .from("connections")
    .update({ settings: { ...settings, dataSources, ...(health ? { health } : {}) } })
    .eq("id", connection.id)
    .eq("user_id", connection.userId)
    .throwOnError();
}
