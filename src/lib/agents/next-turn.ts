import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import { executionEnabled } from "@/lib/env";
import { MAX_LIVE_EXTERNAL_TASKS } from "@/lib/execution/limits";

import { agentAccess, directChat } from "./capability";
import { adapterEnabled } from "./registry";
import { resolveAgentTarget, type ResolvedAgentTarget } from "./targets";
import { startAgentTurnResultSchema, type StartAgentTurnResult } from "./turns";

type Env = Record<string, string | undefined>;

/** not_sent 중에서도 환경이 바뀌면 저절로 풀리는 이유(gate 계열): 플래그가 켜진 뒤에는 자동으로 다시 시작해도 된다. SQL start_agent_turn_auto의 목록과 같아야 한다(시험이 글자를 맞춰 본다) */
export const GATE_REASONS = ["write_gate_closed", "not_connected", "adapter_disabled"] as const;

/**
 * 자동 시작(보내기 뒤 queue_order 후속 · deliver · referent · Stop · Resume here)이 이 메시지를 시작해도 되는가 (검토 반영 7-1, 형제 D2a 계약 7장 1항과 같은 규칙).
 * queued이거나, not_sent인데 이유가 gate 계열일 때만 true다. spawn_failed · sign_in_needed · usage_limited · not_received · unsupported …로 실패한 메시지는
 * 사용자의 Send again으로만 다시 시작한다 — 자동으로 다시 시작하면 실패 → 재시작이 끝없이 반복된다. 이런 머리는 SQL FIFO(queue_order)가 뒤 메시지를 붙잡는다
 */
export function autoStartable(state: string | null | undefined, reason: string | null | undefined): boolean {
  return state === "queued" || (state === "not_sent" && typeof reason === "string" && (GATE_REASONS as readonly string[]).includes(reason));
}

/** 시작 입력용 칩 모양: 저장된 selected 또는 앞서 시작을 시도해 저장한 refs.agent_turn (added 칩만 id 목록에 있다, AC-6) */
export const chipsSchema = z.object({ action_ids: z.array(z.guid()).default([]), context_ids: z.array(z.guid()).default([]) });
export type StartChips = z.infer<typeof chipsSchema>;

/** 칩의 Action 중 지금도 내 것인 것만 (지워진 · 남의 id는 뺀다: SQL이 not_found로 시작을 거절하지 않게). 순서는 그대로. 저장된 selected는 건드리지 않는다 */
export async function existingActionIds(admin: SupabaseClient, userId: string, ids: string[]): Promise<string[]> {
  if (!ids.length) return [];
  const { data } = await admin.from("actions").select("id").eq("user_id", userId).in("id", ids).throwOnError();
  const found = new Set(((data ?? []) as { id: string }[]).map((row) => row.id.toLowerCase()));
  return ids.filter((id) => found.has(id.toLowerCase()));
}

async function markNotSent(admin: SupabaseClient, input: { userId: string; messageId: string }, reason: string): Promise<StartAgentTurnResult> {
  const { data } = await admin.rpc("mark_agent_message_not_sent", { p_user_id: input.userId, p_message_id: input.messageId, p_reason: reason }).throwOnError();
  return startAgentTurnResultSchema.parse(data);
}

/**
 * 실행 kill switch(EXECUTION_ENABLED)가 꺼져 있으면 턴을 시작하지 않고 메시지를 not_sent/write_gate_closed로 표시한다 (D2a 보안 검토 P1 방어).
 * 꺼진 채 턴을 시작하면 task · 단계 · 명령 · agent_message_sent 지표가 만들어지지만 전달될 수 없고, bridge가 거둔 것을 자동 계기가 다시 시작하는 끝없는 반복이 된다.
 * DB 쪽 gate(execution_controls · 실행 주체 · 도구)는 bridge lease의 몫이라 여기서 보지 않는다. turns.ts는 바꾸지 않는다 — 기존 mark_agent_message_not_sent 경로만 쓴다
 */
export function markWriteGateClosed(admin: SupabaseClient, input: { userId: string; messageId: string }): Promise<StartAgentTurnResult> {
  return markNotSent(admin, input, "write_gate_closed");
}

export type PinnedStartResult = StartAgentTurnResult | { status: "skipped" };
const pinnedResultSchema = z.union([z.object({ status: z.literal("skipped") }), startAgentTurnResultSchema]);

/**
 * D1d 자신의 시작 함수 (검토 반영 8-1 · 8-2): 이미 검사한 메시지 id를 고정해 시작한다 — 대기열 머리를 다시 고르지 않는다(turns.ts의 startNextQueuedTurn은 쓰지 않는다).
 * - 등급 판정은 startAgentTurn과 같다(연결 상태 · 등급 · adapter · 직접 대화 가능 여부). 거절 사유가 있으면 시작 대신 not_sent로 표시한다. 이미 같은 이유로 not_sent인 메시지는 다시 쓰지 않는다.
 * - 처리용 칩에서 지워진 Action을 뺀다(existingActionIds). 저장된 selected는 그대로다.
 * - 시작은 SQL 래퍼 start_agent_turn_auto가 한다: 그 메시지를 잠근 뒤 다시 확인해(queued, 또는 not_sent + gate 이유) 아니면 skipped, 맞으면 같은 트랜잭션에서 route_agent_message.
 *   검사한 뒤 다른 요청이 상태를 바꿨어도 낡은 상태로 새 회차를 만들지 않는다.
 * - 진짜 not_found · already_dispatched(칩 때문이 아니다)는 mark_agent_message_not_sent로 대기열에서 뺀다 (형제 D2a와 같다). 잠금을 쥔 채 부르지 않는다
 */
export async function startPinnedAgentMessage(
  admin: SupabaseClient,
  input: { userId: string; messageId: string; state: string | null; reason: string | null; chips: StartChips; target: Pick<ResolvedAgentTarget, "capability" | "mode" | "connectionStatus"> },
  env: Env = process.env,
): Promise<PinnedStartResult> {
  const { capability, mode, connectionStatus } = input.target;
  const access = agentAccess(capability, mode);
  const refusal = connectionStatus !== "active" ? connectionStatus
    : access === null ? "write_gate_closed"
    : !adapterEnabled(capability.adapter, env) || directChat(capability, mode) !== "supported" ? "unsupported" : null;
  if (refusal !== null || access === null) {
    const reason = refusal ?? "write_gate_closed";
    return input.state === "not_sent" && input.reason === reason ? { status: "skipped" } : markNotSent(admin, input, reason);
  }
  const { data } = await admin
    .rpc("start_agent_turn_auto", {
      p_user_id: input.userId, p_message_id: input.messageId, p_access: access, p_live_limit: MAX_LIVE_EXTERNAL_TASKS,
      p_action_ids: await existingActionIds(admin, input.userId, input.chips.action_ids), p_context_ids: input.chips.context_ids,
    })
    .throwOnError();
  const result = pinnedResultSchema.parse(data);
  if (result.status === "not_found" || result.status === "already_dispatched") return markNotSent(admin, input, result.status);
  return result;
}

/** 세션 → 연결 → 시작 입력용 대상 (세션이 없거나 연결이 없거나 registry 밖 adapter면 null) */
async function sessionTarget(admin: SupabaseClient, userId: string, sessionId: string, env: Env): Promise<ResolvedAgentTarget | null> {
  const { data } = await admin.from("agent_sessions").select("connection_id").eq("user_id", userId).eq("id", sessionId).maybeSingle().throwOnError();
  return data ? resolveAgentTarget(admin, userId, (data as { connection_id: string }).connection_id, env) : null;
}

const headSchema = z.object({
  delivery_state: z.string().nullable(),
  delivery_reason: z.string().nullable(),
  refs: z.object({ agent_turn: chipsSchema.optional() }).passthrough().nullable(),
  selected: chipsSchema.nullable(),
});

/**
 * 세션의 다음 대기 메시지를 시작해 본다. 대기열 머리를 **한 번** 고르고(next_queued_agent_message) 그 메시지 id를 끝까지 고정한다 —
 * 고른 뒤 머리가 바뀌어도(예: 그 메시지가 만료돼 뒤의 실패한 not_sent가 머리가 됨) 다시 고르지 않는다 (검토 반영 8-1).
 * 보내기 · Send again · referent · Stop · Resume here 뒤의 "다음 대기 메시지 시작"이 모두 이 함수를 지난다. 잠금을 쥔 채 부르지 않는다.
 * - 머리가 없거나 읽을 수 없거나 자동 시작 대상이 아니면(실패한 not_sent) null: 시작도 표시도 하지 않는다.
 * - 세션 연결의 adapter 플래그가 꺼져 있으면 null (Stop 뒤에도 플래그를 따른다).
 * - 실행 kill switch가 꺼져 있으면 지금 시작하려는 queued 머리만 not_sent/write_gate_closed로 표시한다. 이미 not_sent인 머리의 이유는 덮어쓰지 않는다.
 * - 그 밖에는 startPinnedAgentMessage (처리용 칩 필터 + 잠금 안 재확인)
 */
export async function startNextAgentMessage(admin: SupabaseClient, input: { userId: string; sessionId: string }, env: Env = process.env): Promise<StartAgentTurnResult | null> {
  const { data } = await admin.rpc("next_queued_agent_message", { p_user_id: input.userId, p_session_id: input.sessionId }).throwOnError();
  const messageId = z.guid().nullable().parse(data);
  if (messageId === null) return null;
  const { data: row } = await admin.from("conversation_messages").select("delivery_state, delivery_reason, refs, selected").eq("user_id", input.userId).eq("id", messageId).maybeSingle().throwOnError();
  if (!row) return null;
  const head = headSchema.parse(row);
  if (!autoStartable(head.delivery_state, head.delivery_reason)) return null;
  const target = await sessionTarget(admin, input.userId, input.sessionId, env);
  if (!target?.enabled) return null;
  if (!executionEnabled(env)) return head.delivery_state === "queued" ? markWriteGateClosed(admin, { userId: input.userId, messageId }) : null;
  const result = await startPinnedAgentMessage(
    admin,
    { userId: input.userId, messageId, state: head.delivery_state, reason: head.delivery_reason, chips: head.refs?.agent_turn ?? head.selected ?? { action_ids: [], context_ids: [] }, target },
    env,
  );
  return result.status === "skipped" ? null : result;
}
