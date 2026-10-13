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
