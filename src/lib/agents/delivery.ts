import { agentDeliveryReasonSchema, type AgentDelivery } from "@/lib/api/contract";
import type { StepState } from "@/lib/execution/types";

export type AgentMessageDeliveryState = "queued" | "not_sent" | "dispatched" | "expired" | "cancelled";

/** Failed delivery must already have been reset to not_sent by the event transaction. */
export function agentMessageDelivery(state: AgentMessageDeliveryState, stepState: StepState | null) {
  if (state !== "dispatched") return state;
  switch (stepState) {
    case "prepared":
    case "calling": return "sent";
    case "called": return "accepted";
    case "unknown_outcome": return "unknown";
    default: return "not_sent";
  }
}

// ─── D1d: 응답의 전달 표시 (Assistant 계약 v3 2.4 · 2.15). 위 agentMessageDelivery는 그대로 쓴다 (OD-11) ───

export type AgentDeliveryInput = {
  row: { state: AgentMessageDeliveryState; reason: string | null; refs: Record<string, unknown> | null };
  /** 그 메시지의 마지막 턴 단계 상태 (agent_tasks.message_id → turn_seq 최대 → step_id → execution_steps.state) */
  stepState: StepState | null;
  /** refs.answer_for인 글(질문에 자유 글로 답한 메시지)의 답 단계. failed의 이유는 단계 receipt.reason */
  answerStep?: { state: StepState; reason: string | null } | null;
  /** needs_referent 후보 Action 제목 (읽지 못한 후보는 뺀다) */
  titles: ReadonlyMap<string, string>;
};

const reasonOf = (reason: string | null | undefined) => {
  const parsed = agentDeliveryReasonSchema.safeParse(reason);
  return parsed.success ? parsed.data : undefined;
};

/**
 * 메시지 행 + 마지막 턴 단계로 계산하는 전달 표시 (순수 함수, 서버만 계산한다 — CLAUDE.md "표시 규칙" 예외에 없다).
 * 행: cancelled → cancelled · answer_for(질문의 답) → answered(답 단계 failed면 not_sent + 이유, skipped면 cancelled) ·
 * queued + 후보 + 아직 안 고름 → needs_referent · queued/not_sent/expired → 그 상태 + 이유 · dispatched → sent · accepted · unknown(그 밖은 not_sent 방어)
 */
export function agentDeliveryView({ row, stepState, answerStep, titles }: AgentDeliveryInput): AgentDelivery {
  const refs = row.refs ?? {};
  if (row.state === "cancelled") return { state: "cancelled" };
  if (refs.answer_for !== undefined && row.state === "dispatched") {
    if (answerStep?.state === "failed") {
      const reason = reasonOf(answerStep.reason);
      return reason ? { state: "not_sent", reason } : { state: "not_sent" };
    }
    if (answerStep?.state === "skipped") return { state: "cancelled" };
    return { state: "answered" };
  }
  if (row.state === "queued" && Array.isArray(refs.referent_candidates) && refs.referent_candidates.length > 0 && !refs.referent_action_id) {
    const candidates = refs.referent_candidates
      .filter((id): id is string => typeof id === "string" && titles.has(id))
      .slice(0, 3)
      .map((id) => ({ action_id: id, title: titles.get(id)! }));
    return { state: "needs_referent", candidates };
  }
  if (row.state === "queued" || row.state === "not_sent" || row.state === "expired") {
    const reason = reasonOf(row.reason);
    return reason ? { state: row.state, reason } : { state: row.state };
  }
  const delivered = agentMessageDelivery(row.state, stepState);
  return { state: delivered === "sent" || delivered === "accepted" || delivered === "unknown" ? delivered : "not_sent" };
}
