import "server-only";

import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import { rankNow, type RankInput } from "@/lib/actions/rank";
import { budgetFetch } from "@/lib/ai/budget";
import { decide, jevConfigFromEnv } from "@/lib/ai/jev";
import { completeJson, llmConfigFromEnv } from "@/lib/ai/llm";
import {
  conversationMessageContentSchema,
  conversationSchema,
  messageRefsSchema,
  type Conversation,
  type ConversationMessage,
  type MessageIntent,
} from "@/lib/api/contract";
import { withConsentGate } from "@/lib/consent/gate";
import { consentCheck } from "@/lib/consent/store";
import { buildContextBundle } from "@/lib/context/bundle";
import type { MemoryLike } from "@/lib/context/memory";
import { loadScopeMemory, loadSourceStates, searchContextChunks } from "@/lib/context/store";
import { flagEnabled } from "@/lib/flags";
import type { CompleteJson } from "@/lib/pipeline/extract";
import type { Decide } from "@/lib/pipeline/judge";
import { findQuoteSpan, quoteContext } from "@/lib/pipeline/text";
import { SLACK_DISCONNECTED_QUOTE } from "@/lib/retention";

import {
  CONVERSATION_WINDOW,
  DONE_RECENT_DAYS,
  DONE_RECENT_SHOWN,
  MEMORY_SHOWN,
  OPEN_ACTIONS_SHOWN,
  QUOTES_PER_ACTION,
  REPLY_LEASE_SECONDS,
  SOURCE_EXCERPT_CHARS,
  SOURCES_SHOWN,
} from "./conversation.config";
import type { ShownMemory } from "./memory";
import { normalizeSelected, type SelectedRefs, type Target } from "./referent";
import type { ConsultAction, ConsultContext, ConsultMemory, ConsultSource, TurnPlan, WindowMessage } from "./respond";

// 대화 v2의 DB 쪽 (service role). 모든 쿼리를 user_id로 좁힌다. 규칙은 순수 모듈(respond · intent · referent · proposal · memory)과
// DB 함수(20261106000000_conversations_v2)에 있고 여기는 부르기만 한다. 실행(src/lib/execution)은 가져오지 않는다 (boundary.test.ts):
// 실행 표는 앱이 보낸 run · 산출물 id가 이 사용자의 것인지 읽어 볼 뿐 쓰지 않는다.
// 맥락층(기억 · 범위 · 조각)은 B1 gate를 따른다: MEMORY_ENABLED가 꺼져 있으면 범위 · 기억을 읽지 않고, SOURCE_CHUNKS_ENABLED가 꺼져 있으면 조각을 찾지 않는다.

type Env = Record<string, string | undefined>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CONVERSATION_COLUMNS = "id, title, context_id, created_at, last_message_at, last_read_at, archived_at, text_purged_at";
const MESSAGE_COLUMNS = "id, conversation_id, seq, role, client_message_id, text, refs, intent, created_at, reply_to, content";

// ─── 대화 ─────────────────────────────────────────

export type CreateConversationResult =
  | { status: "created" | "existing"; conversation: Conversation }
  | { status: "id_taken" }
  | { status: "context_not_found" }
  | { status: "context_off" };

/**
 * 대화 만들기. 앱이 id를 정하면 멱등이다: 같은 사용자의 같은 id면 그 대화를 그대로 돌려준다(제목 · 범위를 덮지 않는다).
 * 범위는 MEMORY_ENABLED일 때만, 내 범위여야 한다 (복합 외래키 (context_id, user_id)도 막는다)
 */
export async function createConversation(
  admin: SupabaseClient,
  userId: string,
  input: { id?: string; title?: string; contextId?: string | null },
  env: Env = process.env,
): Promise<CreateConversationResult> {
  const id = input.id ?? randomUUID();
  const existing = await readConversation(admin, userId, id);
  if (existing) return { status: "existing", conversation: existing };
  if (input.contextId) {
    if (!flagEnabled("MEMORY_ENABLED", env)) return { status: "context_off" };
    const { data } = await admin.from("work_contexts").select("id").eq("user_id", userId).eq("id", input.contextId).maybeSingle().throwOnError();
    if (!data) return { status: "context_not_found" };
  }
  const { data } = await admin
    .from("conversations")
    .upsert({ id, user_id: userId, title: input.title ?? null, context_id: input.contextId ?? null }, { onConflict: "id", ignoreDuplicates: true })
    .select(CONVERSATION_COLUMNS)
    .throwOnError();
  const created = (data ?? [])[0];
  if (created) return { status: "created", conversation: conversationSchema.parse(created) };
  // 같은 id가 이미 있다: 내 것이면 그것 (동시에 만든 경우), 아니면 다른 사용자의 id
  const raced = await readConversation(admin, userId, id);
  return raced ? { status: "existing", conversation: raced } : { status: "id_taken" };
}

async function readConversation(admin: SupabaseClient, userId: string, id: string): Promise<Conversation | null> {
  const { data } = await admin.from("conversations").select(CONVERSATION_COLUMNS).eq("user_id", userId).eq("id", id).maybeSingle().throwOnError();
  return data ? conversationSchema.parse(data) : null;
}

export type LoadedConversation = { id: string; contextId: string | null; contextName: string | null };

/** 내 대화 (없거나 남의 대화면 null). 범위는 MEMORY_ENABLED일 때만 읽는다: 꺼져 있으면 All work로 답한다 */
export async function loadConversation(admin: SupabaseClient, userId: string, id: string, env: Env = process.env): Promise<LoadedConversation | null> {
  const conversation = await readConversation(admin, userId, id);
  if (!conversation) return null;
  if (!conversation.context_id || !flagEnabled("MEMORY_ENABLED", env)) return { id: conversation.id, contextId: null, contextName: null };
  const { data } = await admin.from("work_contexts").select("id, name").eq("user_id", userId).eq("id", conversation.context_id).maybeSingle().throwOnError();
  const context = data as { id: string; name: string } | null;
  return context ? { id: conversation.id, contextId: context.id, contextName: context.name } : { id: conversation.id, contextId: null, contextName: null };
}

// ─── 앱이 보낸 대상 ─────────────────────────────────

/**
 * 앱이 보낸 대상(refs)이 모두 이 사용자의 것인지 확인한다. 하나라도 아니면 missing: 남의 id로 권한을 얻지 못한다.
 * 실행 표는 읽기만 한다 (id · 사용자만)
 */
export async function verifySelected(
  admin: SupabaseClient,
  userId: string,
  refs: { action_ids?: string[]; run_ids?: string[]; artifact_ids?: string[] } | undefined,
): Promise<{ targets: Target[] } | { missing: true }> {
  // uuid는 대소문자 없이 같은 값이다: 소문자로 모아 중복을 지운 뒤 행 수와 견준다 (대소문자만 다른 같은 id를 두 개로 세지 않는다)
  const { action_ids: actionIds, run_ids: runIds, artifact_ids: artifactIds } = normalizeSelected(refs);
  const targets: Target[] = [];
  if (actionIds.length) {
    const { data } = await admin.from("actions").select("id, title").eq("user_id", userId).in("id", actionIds).throwOnError();
    const rows = (data ?? []) as { id: string; title: string }[];
    if (rows.length !== actionIds.length) return { missing: true };
    targets.push(...rows.map((r) => ({ kind: "action" as const, id: r.id, title: r.title })));
  }
  if (runIds.length) {
    const { data } = await admin.from("execution_runs").select("id").eq("user_id", userId).in("id", runIds).throwOnError();
    if ((data ?? []).length !== runIds.length) return { missing: true };
    targets.push(...((data ?? []) as { id: string }[]).map((r) => ({ kind: "run" as const, id: r.id })));
  }
  if (artifactIds.length) {
    const { data } = await admin.from("execution_artifacts").select("id").eq("user_id", userId).in("id", artifactIds).throwOnError();
    if ((data ?? []).length !== artifactIds.length) return { missing: true };
    targets.push(...((data ?? []) as { id: string }[]).map((r) => ({ kind: "artifact" as const, id: r.id })));
  }
  return { targets };
}

// ─── 메시지 ─────────────────────────────────────────

export type PostStatus = "created" | "retry" | "answered" | "in_progress" | "mismatch" | "refs_mismatch" | "stale" | "not_found";

/** 사용자 메시지 쓰기 (conversation_post_message: 원자적 seq · client_message_id + 글 + 고른 대상으로 멱등 · 처리 중 표시) */
export async function postUserMessage(
  admin: SupabaseClient,
  userId: string,
  conversationId: string,
  clientMessageId: string,
  text: string,
  selected: SelectedRefs = normalizeSelected(undefined),
): Promise<{ status: PostStatus; messageId: string | null; seq: number | null; replyId: string | null }> {
  const { data } = await admin
    .rpc("conversation_post_message", {
      p_user_id: userId,
      p_conversation_id: conversationId,
      p_client_message_id: clientMessageId,
      p_text: text,
      p_selected: selected,
      p_lease_seconds: REPLY_LEASE_SECONDS,
    })
    .single<{ status: PostStatus; message_id: string | null; seq: number | null; reply_id: string | null }>()
    .throwOnError();
  return { status: data.status, messageId: data.message_id, seq: data.seq, replyId: data.reply_id };
}

/** 이 대화(내 것)에 같은 client_message_id의 사용자 메시지가 이미 있는가 */
export async function userMessageExists(admin: SupabaseClient, userId: string, conversationId: string, clientMessageId: string): Promise<boolean> {
  const { data } = await admin
    .from("conversation_messages")
    .select("id")
    .eq("user_id", userId)
    .eq("conversation_id", conversationId)
    .eq("client_message_id", clientMessageId)
    .maybeSingle()
    .throwOnError();
  return Boolean(data);
}

/** 처리 표시 풀기 (실패 뒤): 같은 client_message_id로 다시 보내면 다시 처리한다 */
export async function releaseLease(admin: SupabaseClient, userId: string, messageId: string): Promise<void> {
  await admin.rpc("conversation_release_lease", { p_user_id: userId, p_message_id: messageId }).throwOnError();
}

type MessageRow = {
  id: string;
  conversation_id: string;
  seq: number;
  role: "user" | "assistant" | "event";
  client_message_id: string | null;
  text: string;
  refs: unknown;
  intent: unknown;
  created_at: string;
  reply_to: string | null;
  content: unknown;
};

const iso = (value: string) => new Date(value).toISOString();

function toMessage(row: MessageRow): ConversationMessage {
  const refs = messageRefsSchema.safeParse(row.refs ?? {});
  const content = row.content ? conversationMessageContentSchema.safeParse(row.content) : null;
  return {
    id: row.id,
    conversation_id: row.conversation_id,
    seq: row.seq,
    role: row.role,
    client_message_id: row.client_message_id,
    text: row.text,
    refs: refs.success ? refs.data : messageRefsSchema.parse({}),
    intent: (row.intent as MessageIntent | null) ?? null,
    created_at: iso(row.created_at),
    reply_to: row.reply_to,
    content: content?.success ? content.data : null,
  };
}

function toWindowMessage(message: ConversationMessage): WindowMessage {
  return {
    id: message.id,
    seq: message.seq,
    role: message.role,
    text: message.text,
    textExpired: message.text === "",
    createdAt: message.created_at,
    refs: message.refs,
    content: message.content ?? null,
  };
}

/** 메시지 하나 (내 것만) */
export async function loadMessage(admin: SupabaseClient, userId: string, id: string): Promise<ConversationMessage | null> {
  const { data } = await admin.from("conversation_messages").select(MESSAGE_COLUMNS).eq("user_id", userId).eq("id", id).maybeSingle().throwOnError();
  return data ? toMessage(data as MessageRow) : null;
}

/** 지금 메시지까지의 최근 메시지 (seq 순) + 창에 넣지 않은 앞 메시지 수. 지금 메시지 뒤에 들어온 메시지는 넣지 않는다 */
export async function loadWindow(admin: SupabaseClient, userId: string, conversationId: string, uptoSeq: number): Promise<{ messages: WindowMessage[]; omitted: number }> {
  const { data } = await admin
    .from("conversation_messages")
    .select(MESSAGE_COLUMNS)
    .eq("user_id", userId)
    .eq("conversation_id", conversationId)
    .lte("seq", uptoSeq)
    .order("seq", { ascending: false })
    .limit(CONVERSATION_WINDOW)
    .throwOnError();
  const messages = ((data ?? []) as MessageRow[]).map(toMessage).reverse().map(toWindowMessage);
  // seq는 대화마다 1부터 빈틈없이 매긴다 (conversation_post_message · finish_turn, 메시지를 지우지 않는다)
  const omitted = messages.length === CONVERSATION_WINDOW ? Math.max(0, messages[0].seq - 1) : 0;
  return { messages, omitted };
}

export type FinishStatus = "written" | "answered" | "stale" | "conflict" | "not_found";

/** 한 번의 답 쓰기 (conversation_finish_turn 한 트랜잭션) */
export async function finishTurn(
  admin: SupabaseClient,
  userId: string,
  messageId: string,
  plan: Pick<TurnPlan, "intent" | "user" | "reply" | "memory" | "adopt">,
): Promise<{ status: FinishStatus; replyId: string | null; memoryIds: string[]; actionId: string | null }> {
  const { data } = await admin
    .rpc("conversation_finish_turn", {
      p_user_id: userId,
      p_message_id: messageId,
      p_turn: {
        user: { intent: plan.intent, refs: plan.user.refs },
        reply: { text: plan.reply.text, refs: plan.reply.refs, content: plan.reply.content },
        memory: plan.memory,
        adopt: plan.adopt,
      },
    })
    .single<{ status: FinishStatus; reply_id: string | null; memory_ids: string[] | null; action_id: string | null }>()
    .throwOnError();
  return { status: data.status, replyId: data.reply_id, memoryIds: data.memory_ids ?? [], actionId: data.action_id };
}

// ─── 상담 기록 (조건 조회 · 기억 · 원문) ─────────────────

const ACTION_COLUMNS = "id, title, owner, status, due_date, counterpart, needs_confirmation, started_at, last_activity_at";
/** 순서를 매기려고 읽는 열린 할 일 수 상한 (보여 주는 수는 OPEN_ACTIONS_SHOWN, 전체 수는 count로 따로) */
const OPEN_ACTIONS_READ = 500;

type ActionRow = RankInput & { started_at: string | null };
type QuoteRow = { action_id: string; source_id: string | null; quote: string | null; created_at: string };
type SourceRow = { id: string; title: string | null; kind: string; occurred_at: string | null; external_url: string | null; raw_text: string; raw_text_purged_at: string | null };

/**
 * 상담에 쓰는 기록을 읽는다 (respond.ts의 retrieve).
 * - 등록된 할 일: 조건 조회(열린 것 전체 수 + 서버 순서 rankNow, 최근 끝낸 것). 검색 top-k가 아니다 (A04).
 * - 근거 원문: 보여 주는 할 일의 근거 구절 · 원문 발췌. 접근을 잃은 문서의 원문은 넣지 않는다(문서 단위, B1 context_source_states). 글이 지워진 원문은 저장된 구절만.
 * - 기억 · 조각: B1 묶음(buildContextBundle)이 고른 것만: 요청 범위의 지금 기억(explicit · observed, 추정 · 정정 · 잊은 · 만료 · 읽을 수 없는 원문 제외),
 *   범위 조각(접근 상실 · 글 지움 · Slack 제외). 범위 version은 기억 · 조각보다 먼저 읽는다 (B1: 늦게 읽으면 바뀐 내용을 옛 version으로 적는다).
 */
export async function loadConsultContext(
  admin: SupabaseClient,
  userId: string,
  args: { contextId: string | null; query: string; chunks: boolean; deadline: number; now: Date },
  env: Env = process.env,
): Promise<ConsultContext> {
  const memoryOn = flagEnabled("MEMORY_ENABLED", env);
  const contextId = memoryOn ? args.contextId : null;

  let contextVersion: number | null = null;
  if (contextId) {
    const { data } = await admin.from("work_contexts").select("context_version").eq("user_id", userId).eq("id", contextId).maybeSingle().throwOnError();
    contextVersion = (data as { context_version: number } | null)?.context_version ?? null;
  }

  const since = new Date(args.now.getTime() - DONE_RECENT_DAYS * 86_400_000).toISOString();
  const [openResult, doneResult, memberRows, memoryRows, chunkRows] = await Promise.all([
    admin.from("actions").select(ACTION_COLUMNS, { count: "exact" }).eq("user_id", userId).eq("status", "open").limit(OPEN_ACTIONS_READ).throwOnError(),
    admin
      .from("actions")
      .select(ACTION_COLUMNS, { count: "exact" })
      .eq("user_id", userId)
      .eq("status", "done")
      .gte("last_activity_at", since)
      .order("last_activity_at", { ascending: false })
      .limit(DONE_RECENT_SHOWN)
      .throwOnError(),
    contextId ? memberActionIds(admin, userId, contextId) : Promise.resolve(null),
    memoryOn ? loadScopeMemory(admin, userId, { contextId }, env) : Promise.resolve([] as MemoryLike[]),
    contextId && args.chunks ? searchContextChunks(admin, userId, contextId, args.query, 8, env, { deadline: args.deadline }) : Promise.resolve([]),
  ]);

  const openRows = (openResult.data ?? []) as ActionRow[];
  const ranked = rankNow(openRows, args.now);
  const rankedIds = new Set([...ranked.now, ...ranked.confirmations].map((a) => a.id));
  const others = openRows
    .filter((a) => !rankedIds.has(a.id))
    .sort((a, b) => (a.due_date ?? "9999").localeCompare(b.due_date ?? "9999") || b.last_activity_at.localeCompare(a.last_activity_at));
  const ordered = [...ranked.now, ...ranked.confirmations, ...others].slice(0, OPEN_ACTIONS_SHOWN);
  const doneRows = (doneResult.data ?? []) as ActionRow[];
  const listed = [...ordered, ...doneRows];

  // 근거 구절 (evidence · 원문 Claim), 최근 것부터 · 할 일마다 QUOTES_PER_ACTION개
  const quotes = await actionQuotes(admin, userId, listed.map((a) => a.id));
  const memoryLike = memoryRows as (MemoryLike & { version: number })[];
  const observedSourceIds = memoryLike.filter((m) => m.origin === "observed").map((m) => m.source_ref?.source_id).filter((v): v is string => typeof v === "string" && UUID.test(v));
  const quoteSourceIds = [...new Set([...quotes.values()].flat().map((q) => q.sourceId))];
  const chunkSourceIds = [...new Set(chunkRows.map((c) => c.source_id))];
  const states = await loadSourceStates(admin, userId, [...new Set([...observedSourceIds, ...quoteSourceIds, ...chunkSourceIds])]);
  const lostIds = new Set(states.filter((s) => s.accessLost).map((s) => s.id.toLowerCase()));

  // 기억 · 조각은 B1 묶음 규칙으로 고른다 (id만 쓰고 글은 아래 행에서)
  const { bundle } = buildContextBundle({
    context: contextId && contextVersion !== null ? { id: contextId, context_version: contextVersion } : null,
    me: { display_name: "", emails: [] },
    memory: memoryLike,
    people: [],
    chunks: chunkRows,
    sources: states,
    now: args.now,
    limits: { memory: MEMORY_SHOWN, materials: SOURCES_SHOWN },
  });
  const memoryById = new Map(memoryLike.map((m) => [m.id, m]));
  const memory: ConsultMemory[] = bundle.memory.flatMap((m) => {
    const row = memoryById.get(m.id);
    if (!row || (row.origin !== "explicit" && row.origin !== "observed")) return [];
    const shown: ShownMemory = {
      id: row.id,
      version: row.version,
      kind: row.kind,
      subject: row.subject ?? null,
      statement: row.statement,
      origin: row.origin,
      scope_kind: row.scope_kind,
      context_id: row.context_id,
      action_id: row.action_id,
      person_id: row.person_id,
      agent_adapter: row.agent_adapter,
    };
    return [{ ...shown, observed_at: (row.observed_at instanceof Date ? row.observed_at : new Date(row.observed_at)).toISOString() }];
  });

  // 원문: 할 일 근거(접근 상실 문서 제외) + 범위 조각(묶음이 고른 것)
  const materialTexts = new Map<string, string[]>();
  for (const material of bundle.materials) materialTexts.set(material.source_id, [...(materialTexts.get(material.source_id) ?? []), material.text]);
  const usableQuoteSources = quoteSourceIds.filter((id) => !lostIds.has(id.toLowerCase()));
  const sourceRows = await loadSources(admin, userId, [...new Set([...usableQuoteSources, ...materialTexts.keys()])]);
  const sourceById = new Map(sourceRows.map((s) => [s.id, s]));

  const actionsOf = (rows: ActionRow[], inScope: Set<string> | null): ConsultAction[] =>
    rows.map((a) => ({
      id: a.id,
      title: a.title,
      status: a.status,
      owner: a.owner,
      due_date: a.due_date,
      counterpart: a.counterpart,
      needs_confirmation: a.needs_confirmation,
      in_scope: inScope ? inScope.has(a.id) : null,
      quotes: (quotes.get(a.id) ?? []).filter((q) => sourceById.has(q.sourceId) && !lostIds.has(q.sourceId.toLowerCase())),
    }));
  const openActions = actionsOf(ordered, memberRows);
  const doneRecent = actionsOf(doneRows, memberRows);

  const sources: ConsultSource[] = [];
  const quotesBySource = new Map<string, string[]>();
  for (const action of [...openActions, ...doneRecent]) {
    for (const q of action.quotes) quotesBySource.set(q.sourceId, [...(quotesBySource.get(q.sourceId) ?? []), q.quote]);
  }
  for (const [sourceId, list] of quotesBySource) {
    const row = sourceById.get(sourceId);
    if (!row) continue;
    const text = row.raw_text_purged_at ? null : row.raw_text;
    sources.push({ ...sourceOf(row, text), excerpts: excerptsFor(text, list) });
  }
  for (const [sourceId, texts] of materialTexts) {
    const row = sourceById.get(sourceId);
    if (!row || quotesBySource.has(sourceId) || row.raw_text_purged_at) continue;
    sources.push({ ...sourceOf(row, row.raw_text), excerpts: texts.map((t) => t.slice(0, SOURCE_EXCERPT_CHARS * 2)) });
  }

  return {
    openActions,
    openTotal: openResult.count ?? openRows.length,
    doneRecent,
    doneRecentTotal: doneResult.count ?? doneRows.length,
    memory,
    sources: sources.slice(0, SOURCES_SHOWN),
    contextVersion,
  };
}

async function memberActionIds(admin: SupabaseClient, userId: string, contextId: string): Promise<Set<string>> {
  const { data } = await admin
    .from("context_members")
    .select("action_id")
    .eq("user_id", userId)
    .eq("context_id", contextId)
    .eq("member_kind", "action")
    .is("removed_at", null)
    .in("origin", ["user", "auto"])
    .throwOnError();
  return new Set(((data ?? []) as { action_id: string }[]).map((r) => r.action_id));
}

async function actionQuotes(admin: SupabaseClient, userId: string, actionIds: string[]): Promise<Map<string, { sourceId: string; quote: string }[]>> {
  const result = new Map<string, { sourceId: string; quote: string }[]>();
  if (actionIds.length === 0) return result;
  const [{ data: evidenceRows }, { data: claimRows }] = await Promise.all([
    admin.from("evidence").select("action_id, source_id, quote, created_at").eq("user_id", userId).in("action_id", actionIds).throwOnError(),
    admin.from("claims").select("action_id, source_id, quote, created_at").eq("user_id", userId).eq("origin", "source").in("action_id", actionIds).throwOnError(),
  ]);
  const rows = [...((evidenceRows ?? []) as QuoteRow[]), ...((claimRows ?? []) as QuoteRow[])].sort((a, b) => b.created_at.localeCompare(a.created_at));
  for (const row of rows) {
    // 빈 인용 · Slack 연결을 끊어 지운 인용 자리 표시는 근거가 아니다 (물어보기와 같다)
    if (!row.source_id || !row.quote || row.quote === SLACK_DISCONNECTED_QUOTE) continue;
    const list = result.get(row.action_id) ?? [];
    if (list.length >= QUOTES_PER_ACTION || list.some((q) => q.sourceId === row.source_id && q.quote === row.quote)) continue;
    list.push({ sourceId: row.source_id, quote: row.quote });
    result.set(row.action_id, list);
  }
  return result;
}

async function loadSources(admin: SupabaseClient, userId: string, ids: string[]): Promise<SourceRow[]> {
  if (ids.length === 0) return [];
  const { data } = await admin
    .from("sources")
    .select("id, title, kind, occurred_at, external_url, raw_text, raw_text_purged_at")
    .eq("user_id", userId)
    .in("id", ids)
    .throwOnError();
  return (data ?? []) as SourceRow[];
}

function sourceOf(row: SourceRow, text: string | null) {
  return {
    id: row.id,
    title: row.title,
    kind: row.kind,
    occurredAt: row.occurred_at ? new Date(row.occurred_at) : null,
    externalUrl: row.external_url,
    text,
  };
}

/** 근거 구절 앞뒤 발췌 (원문이 지워졌으면 저장된 구절 자체) */
function excerptsFor(text: string | null, quotes: string[]): string[] {
  const excerpts: string[] = [];
  for (const quote of quotes) {
    const excerpt = text === null ? quote : (quoteContext(text, quote, 2, SOURCE_EXCERPT_CHARS) ?? findQuoteSpan(text, quote)?.quote ?? null);
    if (!excerpt || excerpts.some((e) => e.includes(excerpt) || excerpt.includes(e))) continue;
    excerpts.push(excerpt);
  }
  return excerpts;
}

// ─── 모델 ─────────────────────────────────────────

/**
 * 대화의 모델 호출 (J1 Jev · J2 LLM). 부르기 직전마다 외부 AI 처리 동의를 다시 확인하고(도중 철회 → ConsentRequiredError),
 * AI 원가 한도(budgetFetch)를 거치고, 사용자가 기다리므로 마감(deadline) 안에 끝낸다. 설정이 없으면(키 없음) 부르는 순간 오류다.
 */
export function conversationModelsFromEnv(admin: SupabaseClient, userId: string, deadline: number): { decide: Decide; complete: CompleteJson } {
  const fetch = budgetFetch(admin, userId);
  return withConsentGate<{ decide: Decide; complete: CompleteJson }>(
    {
      decide: (request) => decide({ ...jevConfigFromEnv(), deadline, fetch }, request),
      complete: (request) => completeJson({ ...llmConfigFromEnv(), deadline, fetch }, request),
    },
    consentCheck(admin, userId),
  );
}
