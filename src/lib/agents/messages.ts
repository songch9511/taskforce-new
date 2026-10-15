import { createHash } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import {
  agentConversationMessageSchema,
  messageRefsSchema,
  type AgentConversationMessage,
  type AgentDelivery,
  type AgentSessionStatus,
  type AgentTaskState,
  type AttachmentKind,
  type AttachmentOrigin,
  type PostAgentMessageResponse,
} from "@/lib/api/contract";
import { REPLY_LEASE_SECONDS } from "@/lib/conversation/conversation.config";
import { executionEnabled } from "@/lib/env";
import type { StepState } from "@/lib/execution/types";

import { readConversationTarget } from "./conversations";
import { agentDeliveryView, type AgentMessageDeliveryState } from "./delivery";
import { autoStartable, chipsSchema, markWriteGateClosed, startNextAgentMessage, startPinnedAgentMessage } from "./next-turn";
import { retryOnConflict } from "./retry";
import { resolveAgentTarget } from "./targets";
import type { StartAgentTurnResult } from "./turns";

// 에이전트 대상 대화의 메시지 (Assistant 계약 v3 3.2, OA D1d-s): 저장 · 전달 시작 · 다시 보내기 · 만료 sweep · 응답용 전달 표시 읽기.
// 규칙은 SQL(conversation_post_message · start_agent_turn_auto/route_agent_message/start_agent_turn · requeue_agent_messages)에 있고 여기는 부르기만 한다.
// 사용자 글 · 칩 id는 로그에 남기지 않는다 (이벤트 이름 · 오류 이름만).

type Env = Record<string, string | undefined>;

// ─── 저장 ───

const postedSchema = z.object({
  status: z.enum(["created", "exists", "mismatch", "refs_mismatch", "not_found"]),
  message_id: z.guid().nullable(),
  seq: z.number().int().positive().nullable(),
});
export type PostedAgentMessage = { status: z.infer<typeof postedSchema>["status"]; messageId: string | null; seq: number | null };

/**
 * 사용자 메시지 쓰기 (conversation_post_message, 대상 agent): 새 메시지는 queued + 24시간, 같은 client_message_id는 글 · 고른 대상이 같을 때만 exists.
 * Taskforce 모델의 처리 상태(answered · in_progress · retry · stale)는 이 대상에서 나오지 않는다: 나오면 던진다
 */
export async function postAgentUserMessage(
  admin: SupabaseClient,
  input: { userId: string; conversationId: string; clientMessageId: string; text: string; selected: unknown },
): Promise<PostedAgentMessage> {
  const { data } = await retryOnConflict(async () =>
    admin
      .rpc("conversation_post_message", {
        p_user_id: input.userId,
        p_conversation_id: input.conversationId,
        p_client_message_id: input.clientMessageId,
        p_text: input.text,
        p_selected: input.selected,
        p_lease_seconds: REPLY_LEASE_SECONDS,
      })
      .single()
      .throwOnError(),
  );
  const parsed = postedSchema.parse(data);
  return { status: parsed.status, messageId: parsed.message_id, seq: parsed.seq };
}

/** 이 대화(내 것)에 같은 client_message_id의 사용자 메시지가 이미 있는가 (재전송이면 사라진 칩을 404가 아니라 dropped로 본다, OD-23) */
export async function agentMessageExists(admin: SupabaseClient, userId: string, conversationId: string, clientMessageId: string): Promise<boolean> {
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

/** context_attached (계약 8장 · OD-17): 새로 저장한 메시지의 칩마다 한 줄. props는 종류 · 출처 · 보냈는가 · 대상뿐이다 (id · 글 0) */
export async function recordContextAttached(
  admin: SupabaseClient,
  userId: string,
  targetKind: "taskforce" | "agent",
  chips: { kind: AttachmentKind; origin: AttachmentOrigin; sent: boolean }[],
): Promise<void> {
  if (!chips.length) return;
  await admin
    .from("metric_events")
    .insert(chips.map((chip) => ({ user_id: userId, type: "context_attached", props: { kind: chip.kind, origin: chip.origin, sent: chip.sent, target_kind: targetKind } })))
    .throwOnError();
}

// ─── 만료 sweep ───

const EXPIRE_BATCH = 1000;
const EXPIRE_MAX_ROUNDS = 10;

/**
 * 보관 24시간이 지난 queued · not_sent를 expired로 (conversation_expire_agent_messages, 한 번에 ≤ 1,000행).
 * 1,000이면 더 있을 수 있어 다시 부르고 한 번의 cron에서 최대 10회까지 돈다 (OD-18). 숫자만 돌려준다
 */
export async function expireAgentMessages(admin: SupabaseClient, now: Date): Promise<{ expired: number; rounds: number }> {
  let expired = 0;
  let rounds = 0;
  while (rounds < EXPIRE_MAX_ROUNDS) {
    rounds++;
    const { data } = await admin.rpc("conversation_expire_agent_messages", { p_now: now.toISOString() }).throwOnError();
    const count = z.number().int().nonnegative().parse(data);
    expired += count;
    if (count < EXPIRE_BATCH) break;
  }
  return { expired, rounds };
}

// ─── Send again ───

const requeueSchema = z.object({
  status: z.enum(["ok", "not_found", "wrong_target"]),
  messages: z.array(z.object({
    message_id: z.guid(),
    result: z.enum(["requeued", "skipped"]),
    reason: z.enum(["not_eligible", "not_found", "unknown_outcome"]).optional(),
  })),
});
export type RequeueResult = z.infer<typeof requeueSchema>;

/** requeue_agent_messages: not_sent · expired를 queued로 (새 24시간). 실제 전달은 이 호출이 commit된 뒤 startAgentMessage가 한다 */
export async function requeueAgentMessages(admin: SupabaseClient, input: { userId: string; conversationId: string; messageIds?: string[] }): Promise<RequeueResult> {
  const { data } = await retryOnConflict(async () =>
    admin.rpc("requeue_agent_messages", { p_user_id: input.userId, p_conversation_id: input.conversationId, p_message_ids: input.messageIds ?? null }).throwOnError(),
  );
  return requeueSchema.parse(data);
}

// ─── 전달 시작 ───

const pendingSchema = z.object({
  delivery_state: z.string().nullable(),
  delivery_reason: z.string().nullable(),
  delivery_expires_at: z.string().nullable(),
  refs: z.object({ agent_turn: chipsSchema.optional() }).passthrough().nullable(),
  selected: chipsSchema.nullable(),
});

export type StartAgentMessageResult = StartAgentTurnResult | { status: "skipped" };

/**
 * 저장된 메시지의 전달을 시작한다 (startPinnedAgentMessage → start_agent_turn_auto → route_agent_message → start_agent_turn). 보낼 차례를 기다리는 만료 전 메시지만 대상이고, 아니면 건드리지 않는다(skipped, RPC 0).
 * 대상은 queued, 그리고 not_sent인데 이유가 gate 계열(write_gate_closed · not_connected · adapter_disabled)인 것뿐이다 (autoStartable, 검토 반영 7-1):
 * spawn_failed · sign_in_needed · usage_limited … 로 실패한 not_sent는 사용자의 Send again(deliver)으로만 다시 시작한다.
 * 칩은 앞서 시작을 시도해 저장한 refs.agent_turn, 없으면 저장된 selected의 added 칩이다 (auto 칩은 id 목록에 없다, AC-6). 그 사이 지워진 Action 칩은 처리 입력에서 뺀다
 * (저장된 selected는 그대로: 같은 제출 비교가 처음과 같다, 검토 반영 7-3).
 * 대화의 연결 · registry · 정책 mode로 등급을 정하고(resolveAgentTarget) adapter gate가 꺼져 있으면 시작하지 않는다 (OD-2).
 * 실행 kill switch(EXECUTION_ENABLED)가 꺼져 있으면 시작하지 않고, 지금 시작하려는 queued 메시지만 not_sent/write_gate_closed로 표시한다 (D2a 보안 검토 P1 방어).
 * 이미 not_sent인 메시지의 이유는 덮어쓰지 않는다.
 * queue_order로 밀렸고 세션이 있으면 대기열 머리를 한 번 시작해 본다 (OD-10): 실패해도 첫 시작의 결과는 유효하다 — 다음 계기(D2a)가 이어 간다.
 * 잠금을 쥔 채 부르지 않는다: 호출자는 쓰기 함수가 commit된 뒤 부른다
 */
export async function startAgentMessage(
  admin: SupabaseClient,
  input: { userId: string; conversationId: string; messageId: string },
  env: Env = process.env,
  now: Date = new Date(),
): Promise<StartAgentMessageResult> {
  const { data } = await admin
    .from("conversation_messages")
    .select("delivery_state, delivery_reason, delivery_expires_at, refs, selected")
    .eq("user_id", input.userId)
    .eq("conversation_id", input.conversationId)
    .eq("id", input.messageId)
    .eq("role", "user")
    .maybeSingle()
    .throwOnError();
  if (!data) return { status: "skipped" };
  const message = pendingSchema.parse(data);
  if (!autoStartable(message.delivery_state, message.delivery_reason) || !message.delivery_expires_at || Date.parse(message.delivery_expires_at) <= now.getTime()) return { status: "skipped" };

  const conversation = await readConversationTarget(admin, input.userId, input.conversationId);
  if (!conversation?.connectionId || conversation.targetKind !== "agent") return { status: "skipped" };
  const target = await resolveAgentTarget(admin, input.userId, conversation.connectionId, env);
  if (!target?.enabled) return { status: "skipped" };
  // 실행 kill switch가 꺼져 있으면 시작하지 않고 표시만 한다 (D2a 보안 검토 P1 방어): task · 단계 · 명령 · 지표 0. 이미 not_sent인 메시지의 이유는 덮어쓰지 않는다
  if (!executionEnabled(env)) return message.delivery_state === "queued" ? markWriteGateClosed(admin, { userId: input.userId, messageId: input.messageId }) : { status: "skipped" };

  const chips = message.refs?.agent_turn ?? message.selected ?? { action_ids: [], context_ids: [] };
  const result = await startPinnedAgentMessage(
    admin,
    { userId: input.userId, messageId: input.messageId, state: message.delivery_state, reason: message.delivery_reason, chips, target },
    env,
  );
  if (result.status === "queued" && result.reason === "queue_order") {
    try {
      // 첫 시작이 세션을 묶었을 수 있어 대화를 다시 읽는다
      const sessionId = (await readConversationTarget(admin, input.userId, input.conversationId))?.sessionId;
      if (sessionId) await startNextAgentMessage(admin, { userId: input.userId, sessionId }, env);
    } catch (error) {
      console.error(JSON.stringify({ event: "agent_start_next_failed", error: error instanceof Error ? error.name : "unknown" }));
    }
  }
  return result;
}

/**
 * Send again 한 번 (계약 2.3): requeue → commit 뒤 다시 대기시킨 메시지를 seq 순으로 하나씩 시작한다. 앞 것이 시작되면 뒤는 SQL이 session_busy로 순서대로 대기시킨다.
 * 건너뛴(skipped) 메시지는 시작하지 않는다: 두 번 눌러도 새 전달은 한 번뿐이다 (단계 intent message:<id>)
 */
export async function deliverAgentMessages(
  admin: SupabaseClient,
  input: { userId: string; conversationId: string; messageIds?: string[] },
  env: Env = process.env,
  now: Date = new Date(),
): Promise<RequeueResult> {
  const requeued = await requeueAgentMessages(admin, input);
  if (requeued.status !== "ok") return requeued;
  for (const item of requeued.messages) {
    if (item.result === "requeued") await startAgentMessage(admin, { userId: input.userId, conversationId: input.conversationId, messageId: item.message_id }, env, now);
  }
  return requeued;
}

// ─── 응답용 읽기: 전달 표시 · 새 Action · 작업 ───

const MESSAGE_COLUMNS = "id, conversation_id, seq, role, client_message_id, text, refs, intent, created_at, reply_to, content, delivery_state, delivery_reason, delivery_expires_at";

type MessageRecord = Record<string, unknown> & { id: string; refs: Record<string, unknown> | null; delivery_state: AgentMessageDeliveryState | null; delivery_reason: string | null };
type TaskRecord = { id: string; message_id: string; state: AgentTaskState; agent_session_id: string; run_id: string; turn_seq: number | null };

/** start_agent_turn이 이 메시지에서 만드는 Action의 결정적 id (sha256 앞 32자). 버전 비트가 없다 */
export function deterministicActionId(messageId: string): string {
  const hex = createHash("sha256").update(`tf:assistant_agent:action:${messageId}`).digest("hex").slice(0, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function deliveryViews(admin: SupabaseClient, userId: string, rows: MessageRecord[], now: Date) {
  const ids = rows.map((row) => row.id);
  const tasks = new Map<string, TaskRecord>();
  const sessions = new Map<string, AgentSessionStatus>();
  const steps = new Map<string, string>();
  if (ids.length) {
    const { data } = await admin.from("agent_tasks").select("id, message_id, state, agent_session_id, run_id, turn_seq").eq("user_id", userId).in("message_id", ids).throwOnError();
    for (const row of (data ?? []) as TaskRecord[]) {
      const known = tasks.get(row.message_id);
      if (!known || (row.turn_seq ?? 0) > (known.turn_seq ?? 0)) tasks.set(row.message_id, row);
    }
  }
  const sessionIds = [...new Set([...tasks.values()].map((task) => task.agent_session_id))];
  if (sessionIds.length) {
    const { data } = await admin.from("agent_sessions").select("id, status").eq("user_id", userId).in("id", sessionIds).throwOnError();
    for (const row of (data ?? []) as { id: string; status: AgentSessionStatus }[]) sessions.set(row.id, row.status);
  }
  // 원문 메시지의 전달 단계: 그 메시지를 가리키는 최신 task의 run 안에서 args->>message_id가 그 메시지인 agent_message 단계 중 seq 최대 (검토 반영 7-4 · 8-3).
  // task.step_id는 질문에 답하면 답 단계로 옮겨 가므로 쓰지 않는다 — 답 단계가 실패해도 이미 받은 원문은 accepted 그대로다.
  // run 구분 없이 seq 최댓값으로 고르면 안 된다: 옛 run의 실패(seq 2) → Done → 다시 열기 → 재전송이 새 run seq 1에서 접수돼도 옛 실패가 이긴다
  const originIds = rows.filter((row) => row.refs?.answer_for === undefined && tasks.has(row.id)).map((row) => row.id);
  if (originIds.length) {
    const runIds = [...new Set(originIds.map((id) => tasks.get(id)!.run_id))];
    const { data } = await admin.from("execution_steps").select("run_id, state, seq, args").eq("user_id", userId).eq("kind", "agent_message").in("run_id", runIds).in("args->>message_id", originIds).throwOnError();
    const latest = new Map<string, number>();
    for (const row of (data ?? []) as { run_id: string; state: string; seq: number; args: { message_id: string } }[]) {
      if (row.run_id !== tasks.get(row.args.message_id)?.run_id) continue;
      if (row.seq > (latest.get(row.args.message_id) ?? -1)) {
        latest.set(row.args.message_id, row.seq);
        steps.set(row.args.message_id, row.state);
      }
    }
  }
  const answerFor = rows.filter((row) => row.refs?.answer_for !== undefined).map((row) => row.id);
  const answers = new Map<string, { state: string; reason: string | null; seq: number }>();
  if (answerFor.length) {
    const { data } = await admin.from("execution_steps").select("state, receipt, seq, args").eq("user_id", userId).in("args->>answer_message_id", answerFor).throwOnError();
    for (const row of (data ?? []) as { state: string; receipt: { reason?: unknown } | null; seq: number; args: { answer_message_id: string } }[]) {
      const known = answers.get(row.args.answer_message_id);
      if (!known || row.seq > known.seq) answers.set(row.args.answer_message_id, { state: row.state, reason: typeof row.receipt?.reason === "string" ? row.receipt.reason : null, seq: row.seq });
    }
  }
  const candidateIds = [...new Set(rows.filter((row) => row.delivery_state === "queued").flatMap((row) => (Array.isArray(row.refs?.referent_candidates) ? (row.refs.referent_candidates as unknown[]) : [])).filter((id): id is string => typeof id === "string"))];
  const titles = new Map<string, string>();
  if (candidateIds.length) {
    const { data } = await admin.from("actions").select("id, title").eq("user_id", userId).in("id", candidateIds).throwOnError();
    for (const row of (data ?? []) as { id: string; title: string }[]) titles.set(row.id, row.title);
  }

  const views = new Map<string, AgentDelivery>();
  for (const row of rows) {
    const answer = answers.get(row.id);
    views.set(
      row.id,
      agentDeliveryView({
        row: { state: row.delivery_state ?? "queued", reason: row.delivery_reason, refs: row.refs },
        stepState: (steps.get(row.id) as StepState | undefined) ?? null,
        sessionStatus: sessions.get(tasks.get(row.id)?.agent_session_id ?? ""),
        answerStep: answer ? { state: answer.state as StepState, reason: answer.reason } : null,
        titles,
        expiresAt: typeof row.delivery_expires_at === "string" ? row.delivery_expires_at : null,
        now,
      }),
    );
  }
  return { views, tasks };
}

const iso = (value: unknown) => (typeof value === "string" ? new Date(value).toISOString() : value);

function toMessage(row: MessageRecord): AgentConversationMessage {
  const refs = messageRefsSchema.safeParse(row.refs ?? {});
  return agentConversationMessageSchema.parse({
    ...row,
    refs: refs.success ? refs.data : messageRefsSchema.parse({}),
    created_at: iso(row.created_at),
    delivery_expires_at: iso(row.delivery_expires_at ?? null),
  });
}

export type AgentMessageOutcome = Pick<PostAgentMessageResponse, "message" | "delivery" | "created_action" | "agent_task">;

/**
 * 메시지 하나의 응답 재료를 다시 읽어 계산한다 (계약 2.4): 전달 표시 · 이 메시지가 만든 새 Action(번호 포함) · 마지막 턴의 작업.
 * 없거나 남의 메시지 · 다른 대화의 메시지면 null. 읽기만 한다
 */
export async function loadAgentMessageOutcome(admin: SupabaseClient, userId: string, conversationId: string, messageId: string, now: Date = new Date()): Promise<AgentMessageOutcome | null> {
  const { data } = await admin
    .from("conversation_messages")
    .select(MESSAGE_COLUMNS)
    .eq("user_id", userId)
    .eq("conversation_id", conversationId)
    .eq("id", messageId)
    .eq("role", "user")
    .maybeSingle()
    .throwOnError();
  if (!data) return null;
  const row = data as unknown as MessageRecord;
  const { views, tasks } = await deliveryViews(admin, userId, [row], now);
  const task = tasks.get(row.id);

  let createdAction: AgentMessageOutcome["created_action"] = null;
  if (task) {
    const { data: run } = await admin.from("execution_runs").select("action_id").eq("user_id", userId).eq("id", task.run_id).maybeSingle().throwOnError();
    const deterministic = deterministicActionId(row.id);
    if ((run as { action_id: string } | null)?.action_id?.toLowerCase() === deterministic) {
      const [{ data: action }, { data: members }] = await Promise.all([
        admin.from("actions").select("id, title, number").eq("user_id", userId).eq("id", deterministic).maybeSingle().throwOnError(),
        admin.from("context_members").select("context_id, removed_at, created_at").eq("user_id", userId).eq("member_kind", "action").eq("action_id", deterministic).throwOnError(),
      ]);
      if (action) {
        const active = ((members ?? []) as { context_id: string; removed_at: string | null; created_at: string }[]).filter((member) => member.removed_at === null).sort((a, b) => (a.created_at < b.created_at ? -1 : 1));
        const found = action as { id: string; title: string; number: number | null };
        createdAction = { id: found.id, number: found.number ?? null, title: found.title, context_id: active[0]?.context_id ?? null };
      }
    }
  }
  return {
    message: toMessage(row),
    delivery: views.get(row.id)!,
    created_action: createdAction,
    agent_task: task ? { id: task.id, state: task.state, agent_session_id: task.agent_session_id } : null,
  };
}

/** GET /api/v2/conversations/{id}/delivery (OD-13): since_seq 뒤의 사용자 메시지 ≤ 100개의 전달 표시 (seq 순). 읽기만 한다 */
export async function loadAgentDeliveries(
  admin: SupabaseClient,
  userId: string,
  conversationId: string,
  options: { sinceSeq?: number; limit?: number },
  now: Date = new Date(),
): Promise<{ message_id: string; seq: number; delivery: AgentDelivery }[]> {
  const limit = Math.min(options.limit ?? 100, 100);
  const query = admin.from("conversation_messages").select(MESSAGE_COLUMNS).eq("user_id", userId).eq("conversation_id", conversationId).eq("role", "user");
  const { data } = await (options.sinceSeq !== undefined ? query.gt("seq", options.sinceSeq) : query).order("seq", { ascending: true }).limit(limit).throwOnError();
  const rows = (data ?? []) as unknown as (MessageRecord & { seq: number })[];
  if (!rows.length) return [];
  const { views } = await deliveryViews(admin, userId, rows, now);
  return rows.map((row) => ({ message_id: row.id, seq: row.seq, delivery: views.get(row.id)! }));
}

// ─── referent (계약 2.4) ───

const referentSchema = z.object({ status: z.enum(["selected", "not_found", "already_dispatched", "expired"]) });

/**
 * needs_referent 후보 중 하나를 고른다. SQL 함수(set_agent_message_referent)는 대화를 보지 않으므로(메시지 · 사용자 · 대상만),
 * 이 대화의 내 사용자 메시지인지 먼저 확인한다 (아니면 not_found, SQL 0). 시작은 호출자가 selected일 때만 한다
 */
export async function setAgentMessageReferent(
  admin: SupabaseClient,
  input: { userId: string; conversationId: string; messageId: string; actionId: string },
): Promise<"selected" | "not_found" | "already_dispatched" | "expired"> {
  const { data } = await admin
    .from("conversation_messages")
    .select("id")
    .eq("user_id", input.userId)
    .eq("conversation_id", input.conversationId)
    .eq("id", input.messageId)
    .eq("role", "user")
    .maybeSingle()
    .throwOnError();
  if (!data) return "not_found";
  const { data: result } = await retryOnConflict(async () =>
    admin.rpc("set_agent_message_referent", { p_user_id: input.userId, p_message_id: input.messageId, p_action_id: input.actionId }).throwOnError(),
  );
  return referentSchema.parse(result).status;
}

/** Send again 응답용: 메시지 id별 전달 표시 (이 대화 · 이 사용자의 사용자 메시지만, 읽기만) */
export async function loadAgentDeliveriesByIds(admin: SupabaseClient, userId: string, conversationId: string, messageIds: string[], now: Date = new Date()): Promise<Record<string, AgentDelivery>> {
  if (!messageIds.length) return {};
  const { data } = await admin
    .from("conversation_messages")
    .select(MESSAGE_COLUMNS)
    .eq("user_id", userId)
    .eq("conversation_id", conversationId)
    .eq("role", "user")
    .in("id", messageIds)
    .throwOnError();
  const rows = (data ?? []) as unknown as MessageRecord[];
  if (!rows.length) return {};
  const { views } = await deliveryViews(admin, userId, rows, now);
  return Object.fromEntries(rows.map((row) => [row.id, views.get(row.id)!]));
}

// ─── cron: 만료 sweep을 route에 거는 한 줄 ───

/**
 * 실행 sweep cron이 부르는 만료 반복 (OD-18): 실패는 가두고 숫자만 로그에 남긴다 — cron 응답 본문 · 상태 코드를 바꾸지 않고 기존 sweep을 막지 않는다.
 * 실행 플래그와 무관하게 돈다 (꺼져 있어도 대기 메시지는 24시간 뒤 expired가 된다)
 */
export async function expireAgentMessagesQuietly(admin: SupabaseClient, now: Date = new Date()): Promise<void> {
  try {
    const { expired, rounds } = await expireAgentMessages(admin, now);
    console.info(JSON.stringify({ event: "agent_message_expiry", expired, rounds }));
  } catch (error) {
    console.error(JSON.stringify({ event: "agent_message_expiry_failed", error: error instanceof Error ? error.name : "unknown" }));
  }
}
