import { describe, expect, it, vi } from "vitest";

import { checkSlackTokens, type SlackHealthDeps, type SlackTokenCheckTarget } from "./health";

const A: SlackTokenCheckTarget = { id: "conn-a", teamId: "T1", slackUserId: "UA" };
const B: SlackTokenCheckTarget = { id: "conn-b", teamId: "T1", slackUserId: "UB" };
const C: SlackTokenCheckTarget = { id: "conn-c", teamId: "T2", slackUserId: "UC" };

describe("checkSlackTokens (매일 토큰 확인)", () => {
  it("토큰이 죽은 연결만 앱 해제와 같게 끊고, 확인에 실패한 연결은 두고 나머지를 계속 본다", async () => {
    const revoked: string[] = [];
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const deps: SlackHealthDeps = {
      connections: async () => [A, B, C],
      tokenAlive: async (c) => {
        if (c.id === "conn-b") throw new Error("slack down");
        return c.id !== "conn-c";
      },
      revoke: async (c) => {
        revoked.push(c.id);
        return 1;
      },
    };
    expect(await checkSlackTokens(deps)).toEqual({ checked: 3, revoked: 1, failed: 1 });
    expect(revoked).toEqual(["conn-c"]);
    error.mockRestore();
  });

  it("시간 한도를 넘기면 남은 연결은 다음 날 본다", async () => {
    const seen: string[] = [];
    const deps: SlackHealthDeps = {
      connections: async () => [A, B],
      tokenAlive: async (c) => {
        seen.push(c.id);
        return true;
      },
      revoke: async () => 0,
    };
    expect(await checkSlackTokens(deps, { deadline: Date.now() - 1 })).toEqual({ checked: 0, revoked: 0, failed: 0 });
    expect(seen).toEqual([]);
  });
});
