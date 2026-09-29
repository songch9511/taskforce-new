import { describe, expect, it } from "vitest";

import {
  eventAuthorizedUsers,
  exchangeSlackCode,
  isSlackAuthError,
  revokeSlackToken,
  slackAuthorizeUrl,
  slackConversation,
  SlackError,
  slackUserName,
} from "./client";

/** 부른 요청을 남기고 준비한 응답을 차례로 돌려주는 가짜 fetch */
function fakeFetch(...bodies: (unknown | Response)[]) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const body = bodies[calls.length - 1];
    return body instanceof Response ? body : new Response(JSON.stringify(body));
  }) as unknown as typeof fetch;
  return { fetchImpl, calls };
}

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

describe("Slack OAuth", () => {
  const config = { clientId: "1.2", clientSecret: "secret", redirectUri: "https://api.example.com/api/connectors/slack/callback" };

  it("권한 화면은 사용자 권한 9개만 (봇 scope 없음)", () => {
    const url = new URL(slackAuthorizeUrl(config, "state-1"));
    expect(url.origin + url.pathname).toBe("https://slack.com/oauth/v2/authorize");
    expect(url.searchParams.get("user_scope")?.split(",")).toHaveLength(9);
    expect(url.searchParams.has("scope")).toBe(false);
    expect(url.searchParams.get("state")).toBe("state-1");
  });

  it("code를 이용자 토큰으로 바꾼다. 팀 id가 영문 대문자 · 숫자가 아니면 거절한다", async () => {
    const { fetchImpl, calls } = fakeFetch({
      ok: true,
      authed_user: { id: "U1", scope: "im:history,users:read", access_token: "xoxp-1", token_type: "user" },
      team: { id: "T1", name: "Acme" },
    });
    expect(await exchangeSlackCode({ ...config, fetch: fetchImpl }, "code-1")).toEqual({
      token: { access_token: "xoxp-1", scope: "im:history,users:read", user_id: "U1", team_id: "T1" },
      teamName: "Acme",
    });
    expect(calls[0].url).toBe("https://slack.com/api/oauth.v2.access");
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe(`Basic ${Buffer.from("1.2:secret").toString("base64")}`);
    expect(String(calls[0].init.body)).toContain("code=code-1");

    const bad = fakeFetch({ ok: true, authed_user: { id: "U1", access_token: "xoxp-1" }, team: { id: "T1%" } });
    await expect(exchangeSlackCode({ ...config, fetch: bad.fetchImpl }, "c")).rejects.toMatchObject({ code: "bad_response" });
  });

  it("토큰 폐기: 이미 폐기된 토큰은 성공으로 보고, 그 밖의 실패는 던진다", async () => {
    await expect(revokeSlackToken("xoxp-1", fakeFetch({ ok: true, revoked: true }).fetchImpl)).resolves.toBeUndefined();
    await expect(revokeSlackToken("xoxp-1", fakeFetch({ ok: false, error: "token_revoked" }).fetchImpl)).resolves.toBeUndefined();
    await expect(revokeSlackToken("xoxp-1", fakeFetch({ ok: false, error: "fatal_error" }).fetchImpl)).rejects.toMatchObject({ code: "fatal_error" });
  });
});

describe("Slack 이름", () => {
  it("사용자 이름은 실명을 먼저, 없으면 표시 이름 · 계정 이름", async () => {
    const full = fakeFetch({ ok: true, user: { name: "jiho", real_name: "Jiho Park", profile: { real_name: "Jiho Park", display_name: "Jiho" } } });
    expect(await slackUserName("xoxp-1", "U1", full.fetchImpl)).toBe("Jiho Park");
    const display = fakeFetch({ ok: true, user: { name: "jiho", profile: { real_name: "", display_name: "Jiho" } } });
    expect(await slackUserName("xoxp-1", "U1", display.fetchImpl)).toBe("Jiho");
  });

  it("대화: 채널은 이름, DM은 상대 id, 그룹 DM은 이름 없음", async () => {
    expect(await slackConversation("xoxp-1", "C1", fakeFetch({ ok: true, channel: { name: "ops" } }).fetchImpl)).toEqual({ name: "ops", counterpartId: null });
    expect(await slackConversation("xoxp-1", "D1", fakeFetch({ ok: true, channel: { is_im: true, user: "U2" } }).fetchImpl)).toEqual({
      name: null,
      counterpartId: "U2",
    });
    expect(await slackConversation("xoxp-1", "G1", fakeFetch({ ok: true, channel: { is_mpim: true, name: "mpdm-a--b-1" } }).fetchImpl)).toEqual({
      name: null,
      counterpartId: null,
    });
  });

  it("속도 제한(429) · 토큰 오류를 알아볼 수 있게 던진다", async () => {
    const limited = fakeFetch(new Response("", { status: 429, headers: { "Retry-After": "30" } }));
    await expect(slackUserName("xoxp-1", "U1", limited.fetchImpl)).rejects.toMatchObject({ code: "ratelimited" });
    const revoked = fakeFetch({ ok: false, error: "token_revoked" });
    const error = await slackUserName("xoxp-1", "U1", revoked.fetchImpl).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(SlackError);
    expect(isSlackAuthError(error)).toBe(true);
    expect(isSlackAuthError(new SlackError("x", "user_not_found"))).toBe(false);
  });
});
