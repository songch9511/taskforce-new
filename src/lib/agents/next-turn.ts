import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import { executionEnabled } from "@/lib/env";

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

/**
 * startNextQueuedTurn의 실행 플래그 방어판: 켜져 있으면 그대로 부르고, 꺼져 있으면 대기열 머리를 시작하지 않고 write_gate_closed로 표시한다.
 * 보내기 · Send again · referent · Stop · Resume here 뒤의 "다음 대기 메시지 시작"이 모두 이 함수를 지난다. 잠금을 쥔 채 부르지 않는다
 */
export async function startNextAgentMessage(admin: SupabaseClient, input: { userId: string; sessionId: string }, env: Env = process.env): Promise<StartAgentTurnResult | null> {
  if (executionEnabled(env)) return startNextQueuedTurn(admin, input, env);
  const { data } = await admin.rpc("next_queued_agent_message", { p_user_id: input.userId, p_session_id: input.sessionId }).throwOnError();
  const messageId = z.guid().nullable().parse(data);
  return messageId === null ? null : markWriteGateClosed(admin, { userId: input.userId, messageId });
}
