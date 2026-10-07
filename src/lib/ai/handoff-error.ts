export class HandoffGenerationError extends Error {
  constructor(readonly stage: "assessment" | "plan") {
    super("AI handoff generation failed");
    this.name = "HandoffGenerationError";
  }
}
