import { describe, expect, it } from "vitest";
import { agentBetaUserAllowed } from "./flags";
const USERS = ["10000000-0000-4000-8000-000000000001", "20000000-0000-4000-8000-000000000002", "30000000-0000-4000-8000-000000000003"];
const env = { CONVERSATIONS_V2_ENABLED: "true", AGENT_BETA_USER_IDS: USERS.join(",") };
describe("explicit existing-beta snapshot", () => {
  it("admits only the three snapshotted UUIDs", () => {
    for (const user of USERS) expect(agentBetaUserAllowed(user, env)).toBe(true);
    expect(agentBetaUserAllowed("40000000-0000-4000-8000-000000000004", env)).toBe(false);
  });
  it.each([undefined, "", " ", `${USERS[0]},`, ` ${USERS[0]}`, `${USERS[0]},bad`, "*", "true", `${USERS[0]}\n`])("fails closed for malformed list %j", (list) => {
    expect(agentBetaUserAllowed(USERS[0], { ...env, AGENT_BETA_USER_IDS: list })).toBe(false);
  });
  it("keeps the conversation global gate", () => {
    expect(agentBetaUserAllowed(USERS[0], { ...env, CONVERSATIONS_V2_ENABLED: "false" })).toBe(false);
  });
});
