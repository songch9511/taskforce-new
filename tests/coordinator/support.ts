import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";

import { createLocalSupabase } from "../db/local-supabase";
import { sqlAdmin, type Query } from "../conversation/sql-admin";

// 코디네이터 통합 시험의 공통 도구: 테스트 시계가 있는 PGlite, 운영 store · reads가 부르는 supabase-js 흉내(sql-admin), 시드.

// 운영의 db_now()는 now()뿐이다. 마이그레이션을 적용한 뒤 테스트 안에서만 app.now 판으로 바꾼다 (tests/execution/driver.ts와 같은 판)
const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;

export const T0 = new Date("2026-10-12T00:00:00Z");

export async function createCoordinatorDb(): Promise<PGlite> {
  const db = await createLocalSupabase();
  await db.exec(TEST_CLOCK);
  await setClock(db, T0);
  return db;
}

export const setClock = (db: PGlite, at: Date) => db.query("select set_config('app.now', $1, false)", [at.toISOString()]);
export const advanceClock = (db: PGlite, ms: number) =>
  db.query("select set_config('app.now', (public.db_now() + make_interval(secs => $1::float8 / 1000))::text, false)", [ms]);

export const queryOf = (db: PGlite): Query => async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows;
export const adminOf = (db: PGlite): SupabaseClient => sqlAdmin(queryOf(db));

export function seed(db: PGlite) {
  const q = queryOf(db);
  const one = async (sql: string, params: unknown[] = []) => (await q(sql, params))[0];
  const id = async (sql: string, params: unknown[] = []) => (await one(sql, params)).id as string;
  return {
    q,
    one,
    id,
    count: async (sql: string, params: unknown[] = []) => Number((await one(`select count(*)::int as n from (${sql}) x`, params)).n),
    async user(): Promise<string> {
      const userId = randomUUID();
      await q(`insert into auth.users (id, email) values ($1, $2)`, [userId, `${userId}@example.com`]);
      return userId;
    },
    action: (userId: string, extra: { title?: string; dueAt?: string | null; status?: string; needsConfirmation?: boolean } = {}) =>
      id(`insert into public.actions (user_id, title, due_at, status, needs_confirmation) values ($1, $2, $3, $4, $5) returning id`, [
        userId, extra.title ?? "제안서 쓰기", extra.dueAt ?? null, extra.status ?? "open", extra.needsConfirmation ?? false,
      ]),
    source: (userId: string, extra: { kind?: string; externalId?: string; version?: string; connection?: string } = {}) =>
      id(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, external_id, external_version, connection_id) values ($1, $2, '원문 본문', now(), $3, $4, $5) returning id`,
        [userId, extra.kind ?? "meeting", extra.externalId ?? null, extra.version ?? null, extra.connection ?? null],
      ),
    connection: (userId: string) => id(`insert into public.connections (user_id, provider, external_account_id) values ($1, 'notion', $2) returning id`, [userId, randomUUID()]),
    /** pending → processing → done (processSource가 하듯. 처리 요약도 남긴다) */
    async finishSource(sourceId: string) {
      await q(`update public.sources set processing_status = 'processing' where id = $1`, [sourceId]);
      await q(`update public.sources set processing_status = 'done', processed_at = now(), processing_summary = '{"attempt":1}' where id = $1`, [sourceId]);
    },
    /** 근거: 그 원문에서 Action이 나왔다 (evidence) */
    evidence: (userId: string, actionId: string, sourceId: string) =>
      q(`insert into public.evidence (user_id, action_id, source_id, quote, role) values ($1, $2, $3, '금요일까지', 'created')`, [userId, actionId, sourceId]),
    context: (userId: string) => id(`insert into public.work_contexts (user_id, name, kind) values ($1, 'Shape 출시 준비', 'project') returning id`, [userId]),
    member: (userId: string, contextId: string, sourceId: string) =>
      q(`insert into public.context_members (user_id, context_id, member_kind, source_id, origin) values ($1, $2, 'source', $3, 'user')`, [userId, contextId, sourceId]),
    conversation: (userId: string) => id(`insert into public.conversations (user_id) values ($1) returning id`, [userId]),
    message: (userId: string, conversationId: string, selected: Record<string, unknown> | null = null, seq = 1) =>
      id(
        `insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text, selected) values ($1, $2, $3, 'user', $4, '안녕', $5) returning id`,
        [userId, conversationId, seq, randomUUID(), selected ? JSON.stringify(selected) : null],
      ),
    /** 열린 draft run (살아 있는 run). context를 주면 그 범위에서 시작한 run */
    async run(userId: string, actionId: string, extra: { contextId?: string; bundleContextVersion?: number } = {}): Promise<string> {
      const runId = (await one(`select public.create_run($1, $2, 'draft', '초안') as id`, [userId, actionId])).id as string;
      if (extra.contextId) await q(`update public.execution_runs set context_id = $2, bundle_context_version = $3 where id = $1`, [runId, extra.contextId, extra.bundleContextVersion ?? 1]);
      return runId;
    },
    /** 직접 적재 (원천이 없는 종류 · 위조 refs 시험) */
    async event(userId: string, type: string, key: string, refs: Record<string, unknown> = {}): Promise<string> {
      return id(`insert into public.inbox_events (user_id, type, dedup_key, refs, created_at) values ($1, $2, $3, $4, public.db_now()) returning id`, [userId, type, key, JSON.stringify(refs)]);
    },
    result: (eventId: string) =>
      one(`select processed_at is not null as processed, result_kind, result_evidence, result_ids, attempts, model_calls, jev_calls, dead_at is not null as dead from public.inbox_events where id = $1`, [eventId]),
    expire: (eventId: string) => q(`update public.inbox_events set claim_expires_at = public.db_now() - interval '1 second' where id = $1`, [eventId]),
  };
}
