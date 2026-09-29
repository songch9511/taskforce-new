import { describe, expect, it } from "vitest";

import { eventAuthorizedUsers } from "./client";

describe("eventAuthorizedUsers", () => {
  it("여러 쪽을 이어 받아 봇이 아닌 이용자 id만 모은다", async () => {
    const pages = [
      { ok: true, authorizations: [{ user_id: "U1", is_bot: false }, { user_id: "B1", is_bot: true }], response_metadata: { next_cursor: "next" } },
      { ok: true, authorizations: [{ user_id: "U2", is_bot: false }, { user_id: "U1", is_bot: false }], response_metadata: { next_cursor: "" } },
    ];
    const requests: RequestInit[] = [];
    const fake = (async (_url: string, init: RequestInit) => {
      requests.push(init);
      return new Response(JSON.stringify(pages[requests.length - 1]));
    }) as unknown as typeof fetch;
    expect(await eventAuthorizedUsers("xapp-1", "ctx", fake)).toEqual(["U1", "U2"]);
    expect(String(requests[1].body)).toContain("cursor=next");
    expect((requests[0].headers as Record<string, string>).Authorization).toBe("Bearer xapp-1");
  });

  it("Slack이 ok: false로 답하면 던진다", async () => {
    const fake = (async () => new Response(JSON.stringify({ ok: false, error: "invalid_auth" }))) as unknown as typeof fetch;
    await expect(eventAuthorizedUsers("xapp-1", "ctx", fake)).rejects.toThrow(/invalid_auth/);
  });
});
