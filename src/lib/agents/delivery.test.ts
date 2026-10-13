import { expect, it } from "vitest";
import { agentMessageDelivery } from "./delivery";

it.each(["queued", "not_sent", "expired", "cancelled"] as const)("preserves %s", (state) => {
  expect(agentMessageDelivery(state, "called")).toBe(state);
});
it.each([["prepared", "sent"], ["calling", "sent"], ["called", "accepted"], ["unknown_outcome", "unknown"]] as const)("maps dispatched/%s to %s", (step, state) => {
  expect(agentMessageDelivery("dispatched", step)).toBe(state);
});
it.each(["failed", "pending", "skipped", null] as const)("defensively maps inconsistent dispatched/%s instead of claiming delivery", (step) => {
  expect(agentMessageDelivery("dispatched", step)).toBe("not_sent");
});
