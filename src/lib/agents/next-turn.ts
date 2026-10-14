import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import { executionEnabled } from "@/lib/env";

import { adapterEnabled } from "./registry";
import { startAgentTurnResultSchema, startNextQueuedTurn, type StartAgentTurnResult } from "./turns";

type Env = Record<string, string | undefined>;

/**
 * 실행 kill switch(EXECUTION_ENABLED)가 꺼져 있으면 턴을 시작하지 않고 메시지를 not_sent/write_gate_closed로 표시한다 (D2a 보안 검토 P1 방어).
 * 꺼진 채 턴을 시작하면 task · 단계 · 명령 · agent_message_sent 지표가 만들어지지만 전달될 수 없고, bridge가 거둔 것을 자동 계기가 다시 시작하는 끝없는 반복이 된다.
 * DB 쪽 gate(execution_controls · 실행 주체 · 도구)는 bridge lease의 몫이라 여기서 보지 않는다. turns.ts는 바꾸지 않는다 — 기존 mark_agent_message_not_sent 경로만 쓴다
 */
export async function markWriteGateClosed(admin: SupabaseClient, input: { userId: string; messageId: string }): Promise<StartAgentTurnResult> {
  const { data } = await admin
    .rpc("mark_agent_message_not_sent", { p_user_id: input.userId, p_message_id: input.messageId, p_reason: "write_gate_closed" })
    .throwOnError();
  return startAgentTurnResultSchema.parse(data);
}

/** not_sent 중에서도 환경이 바뀌면 저절로 풀리는 이유(gate 계열): 플래그가 켜진 뒤에는 자동으로 다시 시작해도 된다 */
const GATE_REASONS: readonly string[] = ["write_gate_closed", "not_connected", "adapter_disabled"];

/**
 * 자동 시작(보내기 뒤 queue_order 후속 · deliver · referent · Stop · Resume here)이 이 메시지를 시작해도 되는가 (검토 반영 7-1, 형제 D2a 계약 7장 1항과 같은 규칙).
 * queued이거나, not_sent인데 이유가 gate 계열일 때만 true다. spawn_failed · sign_in_needed · usage_limited · not_received · unsupported …로 실패한 메시지는
 * 사용자의 Send again으로만 다시 시작한다 — 자동으로 다시 시작하면 실패 → 재시작이 끝없이 반복된다. 이런 머리는 SQL FIFO(queue_order)가 뒤 메시지를 붙잡는다
 */
export function autoStartable(state: string | null | undefined, reason: string | null | undefined): boolean {
  return state === "queued" || (state === "not_sent" && typeof reason === "string" && GATE_REASONS.includes(reason));
}

/** 세션의 연결 adapter 플래그 (세션 · 연결이 없거나 registry 밖 adapter면 false). sessions.ts와 순환하지 않으려고 여기서 직접 읽는다 */
async function sessionAdapterOpen(admin: SupabaseClient, userId: string, sessionId: string, env: Env): Promise<boolean> {
  const { data: session } = await admin.from("agent_sessions").select("connection_id").eq("user_id", userId).eq("id", sessionId).maybeSingle().throwOnError();
  if (!session) return false;
  const { data: connection } = await admin.from("agent_connections").select("adapter").eq("user_id", userId).eq("id", (session as { connection_id: string }).connection_id).maybeSingle().throwOnError();
  const adapter = (connection as { adapter: string } | null)?.adapter;
  return adapter !== undefined && adapterEnabled(adapter, env);
}

/**
 * startNextQueuedTurn의 방어판: 대기열 머리를 한 번 읽어 자동 시작해도 되는 머리일 때만(autoStartable) 시작한다.
 * 보내기 · Send again · referent · Stop · Resume here 뒤의 "다음 대기 메시지 시작"이 모두 이 함수를 지난다. 잠금을 쥔 채 부르지 않는다.
 * - 머리가 없거나 읽을 수 없거나 자동 시작 대상이 아니면(실패한 not_sent) null: 시작도 표시도 하지 않는다.
 * - 세션 연결의 adapter 플래그가 꺼져 있으면 null (Stop 뒤에도 플래그를 따른다).
 * - 실행 kill switch가 꺼져 있으면 지금 시작하려는 queued 머리만 not_sent/write_gate_closed로 표시한다. 이미 not_sent인 머리의 이유는 덮어쓰지 않는다.
 */
export async function startNextAgentMessage(admin: SupabaseClient, input: { userId: string; sessionId: string }, env: Env = process.env): Promise<StartAgentTurnResult | null> {
  const { data } = await admin.rpc("next_queued_agent_message", { p_user_id: input.userId, p_session_id: input.sessionId }).throwOnError();
  const messageId = z.guid().nullable().parse(data);
  if (messageId === null) return null;
  const { data: head } = await admin.from("conversation_messages").select("delivery_state, delivery_reason").eq("user_id", input.userId).eq("id", messageId).maybeSingle().throwOnError();
  if (!head) return null;
  const { delivery_state: state, delivery_reason: reason } = head as { delivery_state: string | null; delivery_reason: string | null };
  if (!autoStartable(state, reason)) return null;
  if (!(await sessionAdapterOpen(admin, input.userId, input.sessionId, env))) return null;
  if (!executionEnabled(env)) return state === "queued" ? markWriteGateClosed(admin, { userId: input.userId, messageId }) : null;
  return startNextQueuedTurn(admin, input, env);
}
