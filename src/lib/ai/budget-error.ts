/** Closed codes only: never surface database/provider details to clients. */
export class AiBudgetError extends Error {
  constructor(message: string) { super(message); this.name = "AiBudgetError"; }
  get code(): "ai_budget_exhausted" | "ai_pricing_unavailable" | "ai_provider_bound_violation" | "ai_budget_unavailable" {
    if (this.message === "ai_budget_exhausted") return "ai_budget_exhausted";
    if (["ai_price_bound_unavailable", "ai_request_bound_unavailable"].includes(this.message)) return "ai_pricing_unavailable";
    if (["ai_provider_bound_breached", "ai_provider_cost_exceeded_reservation"].includes(this.message)) return "ai_provider_bound_violation";
    return "ai_budget_unavailable";
  }
  get userMessage(): string {
    if (this.code === "ai_budget_exhausted") return "Your $10 free beta AI allowance cannot cover this request. Reservations count until confirmed. There is no billing or monthly reset. You can still manage tasks and connections.";
    if (this.code === "ai_pricing_unavailable") return "AI is unavailable because its price limit cannot be verified. Your beta allowance has not been marked exhausted.";
    if (this.code === "ai_provider_bound_violation") return "AI is paused because a provider exceeded its reserved cost. Your tasks and connections remain available.";
    return "Could not verify your AI allowance. Please try again later.";
  }
}
