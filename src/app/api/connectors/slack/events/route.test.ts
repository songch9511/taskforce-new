import { createHmac } from "node:crypto";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { receiveSlackEvent } from "@/lib/connectors/slack/receive";

import { POST } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn(() => ({})) }));
vi.mock("@/lib/connectors/slack/receive", () => ({ receiveSlackEvent: vi.fn() }));

// POST /api/connectors/slack/events: 서명 확인 → URL 확인 응답 → 이벤트 처리. 처리 규칙은 receive.test.ts · events.test.ts가 본다.

const SECRET = "test-signing-secret";

function slackRequest(payload: unknown, options: { secret?: string; timestamp?: number } = {}) {
  const body = JSON.stringify(payload);
  const timestamp = String(options.timestamp ?? Math.floor(Date.now() / 1000));
  const signature = `v0=${createHmac("sha256", options.secret ?? SECRET).update(`v0:${timestamp}:${body}`).digest("hex")}`;
  return new Request("http://localhost/api/connectors/slack/events", {
    method: "POST",
    headers: { "content-type": "application/json", "x-slack-request-timestamp": timestamp, "x-slack-signature": signature },
    body,
  });
}

const messageEvent = {
  type: "event_callback",
  team_id: "T1",
  event_id: "Ev1",
  event_time: 1727678400,
  authorizations: [{ user_id: "U1", is_bot: false }],
  event: { type: "message", channel: "D1", channel_type: "im", user: "U2", text: "월요일에 받아도 괜찮아요", ts: "1.0" },
};

describe("POST /api/connectors/slack/events", () => {
  beforeEach(() => {
    vi.stubEnv("SLACK_SIGNING_SECRET", SECRET);
    vi.mocked(receiveSlackEvent).mockReset();
  });
  afterEach(() => vi.unstubAllEnvs());

  it("URL 확인 요청에 challenge를 그대로 돌려준다", async () => {
    const response = await POST(slackRequest({ type: "url_verification", challenge: "abc123", token: "legacy" }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ challenge: "abc123" });
  });

  it("서명이 틀렸거나 오래된 요청은 401이고 처리하지 않는다", async () => {
    expect((await POST(slackRequest(messageEvent, { secret: "other" }))).status).toBe(401);
    expect((await POST(slackRequest(messageEvent, { timestamp: Math.floor(Date.now() / 1000) - 600 }))).status).toBe(401);
    expect(receiveSlackEvent).not.toHaveBeenCalled();
  });

  it("서명 헤더가 없으면 본문을 읽지 않고 401, 너무 큰 본문은 413", async () => {
    const noHeaders = new Request("http://localhost/api/connectors/slack/events", { method: "POST", body: "{}" });
    const read = vi.spyOn(noHeaders, "text");
    expect((await POST(noHeaders)).status).toBe(401);
    expect(read).not.toHaveBeenCalled();
    const big = slackRequest(messageEvent);
    const huge = new Request(big.url, { method: "POST", headers: { ...Object.fromEntries(big.headers), "content-length": "2000000" }, body: "{}" });
    expect((await POST(huge)).status).toBe(413);
  });

  it("서명 키가 설정되지 않았으면 500 (Slack이 다시 보낸다)", async () => {
    vi.stubEnv("SLACK_SIGNING_SECRET", "");
    expect((await POST(slackRequest(messageEvent))).status).toBe(500);
  });

  it("이벤트는 처리하고 200, 처리에 실패하면 500 (Slack이 다시 보낸다)", async () => {
    vi.mocked(receiveSlackEvent).mockResolvedValueOnce({ noConnection: false, kept: 1, dropped: 0, edited: 0, deleted: 0, skippedNoConsent: 0, revoked: 0 });
    expect((await POST(slackRequest(messageEvent))).status).toBe(200);
    expect(vi.mocked(receiveSlackEvent).mock.calls[0][0]).toMatchObject({ team_id: "T1", event: { type: "message" } });

    vi.mocked(receiveSlackEvent).mockRejectedValueOnce(new Error("db down"));
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    expect((await POST(slackRequest(messageEvent))).status).toBe(500);
    // 로그에는 메시지 본문을 남기지 않는다
    expect(JSON.stringify(error.mock.calls)).not.toContain("월요일에 받아도 괜찮아요");
    error.mockRestore();
  });

  it("모르는 형식은 받고 버린다 (200), JSON이 아니면 400", async () => {
    expect((await POST(slackRequest({ type: "app_rate_limited", minute_rate_limited: 1 }))).status).toBe(200);
    expect(receiveSlackEvent).not.toHaveBeenCalled();
    const timestamp = String(Math.floor(Date.now() / 1000));
    const body = "not json";
    const signature = `v0=${createHmac("sha256", SECRET).update(`v0:${timestamp}:${body}`).digest("hex")}`;
    const request = new Request("http://localhost/api/connectors/slack/events", {
      method: "POST",
      headers: { "x-slack-request-timestamp": timestamp, "x-slack-signature": signature },
      body,
    });
    expect((await POST(request)).status).toBe(400);
  });
});
