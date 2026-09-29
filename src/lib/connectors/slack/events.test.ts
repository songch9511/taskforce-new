import { describe, expect, it } from "vitest";

import { classifySlackMessage, slackEnvelopeSchema, slackTsDate, type SlackMessageEvent } from "./events";

const ME = "U_ME";
const msg = (over: Partial<SlackMessageEvent> = {}): SlackMessageEvent => ({
  type: "message",
  channel: "C1",
  channel_type: "channel",
  user: "U_OTHER",
  text: "배포는 목요일 저녁이에요",
  ts: "1727678400.000100",
  ...over,
});

describe("classifySlackMessage — 버리는 규칙 (slack-app.md 3-2)", () => {
  it("DM · 그룹 DM은 모두 남기고 스레드를 추적하지 않는다", () => {
    for (const channel_type of ["im", "mpim"] as const) {
      const decision = classifySlackMessage(msg({ channel: "D1", channel_type }), ME, false);
      expect(decision).toMatchObject({ action: "keep", track: null, message: { channelType: channel_type, senderId: "U_OTHER" } });
    }
  });

  it("채널에서 나와 무관한 글은 버린다", () => {
    expect(classifySlackMessage(msg(), ME, false)).toEqual({ action: "drop", reason: "not_involved" });
    expect(classifySlackMessage(msg({ channel_type: "group" }), ME, false)).toEqual({ action: "drop", reason: "not_involved" });
  });

  it("채널에서 나를 언급했거나 내가 쓴 글은 남기고, 그 글의 스레드를 추적한다", () => {
    expect(classifySlackMessage(msg({ text: "<@U_ME> 체크리스트 봐주세요" }), ME, false)).toMatchObject({ action: "keep", track: "1727678400.000100" });
    expect(classifySlackMessage(msg({ user: ME, thread_ts: "1727678000.000001" }), ME, false)).toMatchObject({
      action: "keep",
      track: "1727678000.000001",
      message: { threadTs: "1727678000.000001" },
    });
  });

  it("추적 중인 스레드의 답글은 나를 부르지 않아도 남긴다. 스레드 밖의 글은 추적 여부와 상관없다", () => {
    const reply = msg({ thread_ts: "1727678000.000001", text: "참고로 금요일까지예요" });
    expect(classifySlackMessage(reply, ME, true)).toMatchObject({ action: "keep", track: "1727678000.000001" });
    expect(classifySlackMessage(reply, ME, false)).toEqual({ action: "drop", reason: "not_involved" });
    expect(classifySlackMessage(msg(), ME, true)).toEqual({ action: "drop", reason: "not_involved" });
  });

  it("봇 · 시스템 하위 유형은 버리고, 스레드 방송 · 파일 공유 글은 남긴다", () => {
    expect(classifySlackMessage(msg({ channel_type: "im", bot_id: "B1" }), ME, false)).toEqual({ action: "drop", reason: "bot" });
    expect(classifySlackMessage(msg({ channel_type: "im", subtype: "channel_join" }), ME, false)).toEqual({ action: "drop", reason: "subtype" });
    expect(classifySlackMessage(msg({ channel_type: "im", subtype: "bot_message" }), ME, false)).toEqual({ action: "drop", reason: "subtype" });
    expect(classifySlackMessage(msg({ channel_type: "im", subtype: "file_share" }), ME, false)).toMatchObject({ action: "keep" });
    expect(classifySlackMessage(msg({ subtype: "thread_broadcast", user: ME, thread_ts: "1.0" }), ME, false)).toMatchObject({ action: "keep", track: "1.0" });
  });

  it("고침 · 지움은 아직 넣지 않은 행에 쓰도록 넘긴다", () => {
    const changed = msg({
      subtype: "message_changed",
      channel_type: undefined,
      user: undefined,
      ts: "1727678500.000000",
      message: { ts: "1727678400.000100", text: "제안서는 화요일에 받아도 괜찮아요", edited: { ts: "1727678499.000000" } },
    });
    expect(classifySlackMessage(changed, ME, false)).toEqual({
      action: "edit",
      channelId: "C1",
      ts: "1727678400.000100",
      text: "제안서는 화요일에 받아도 괜찮아요",
      editedAt: slackTsDate("1727678499.000000"),
    });
    expect(classifySlackMessage(msg({ subtype: "message_deleted", deleted_ts: "1727678400.000100" }), ME, false)).toEqual({
      action: "delete",
      channelId: "C1",
      channelType: "channel",
      ts: "1727678400.000100",
      createIfMissing: false,
    });
    expect(classifySlackMessage(msg({ channel_type: "im", subtype: "message_deleted", deleted_ts: "1.0" }), ME, false)).toMatchObject({
      action: "delete",
      createIfMissing: true,
    });
  });

  it("채널 글을 고쳐 나와 무관해지면(언급을 지움) 지움 표시로, 여전히 관계있으면 고침으로", () => {
    const edit = (text: string, extra: object = {}) =>
      msg({ subtype: "message_changed", user: undefined, ts: "2.0", message: { ts: "1.0", text, user: "U_OTHER", ...extra } });
    expect(classifySlackMessage(edit("체크리스트 봐주세요"), ME, false)).toEqual({
      action: "delete",
      channelId: "C1",
      channelType: "channel",
      ts: "1.0",
      createIfMissing: false,
    });
    expect(classifySlackMessage(edit("<@U_ME> 체크리스트 봐주세요"), ME, false)).toMatchObject({ action: "edit", ts: "1.0" });
    expect(classifySlackMessage(edit("참고로 금요일", { thread_ts: "0.5" }), ME, true)).toMatchObject({ action: "edit" });
  });

  it("보낸 사람이나 대화 종류를 모르면 버린다", () => {
    expect(classifySlackMessage(msg({ user: undefined, channel_type: "im" }), ME, false)).toEqual({ action: "drop", reason: "unsupported" });
    expect(classifySlackMessage(msg({ channel_type: undefined }), ME, false)).toEqual({ action: "drop", reason: "unsupported" });
  });
});

describe("slackEnvelopeSchema", () => {
  it("팀 id는 영문 대문자 · 숫자만 받는다 (연결을 찾는 쿼리에 와일드카드가 들어가지 않게)", () => {
    const base = { type: "event_callback", event_id: "Ev1", event_time: 1, event: { type: "message" } };
    expect(slackEnvelopeSchema.safeParse({ ...base, team_id: "T0ABC12345Z" }).success).toBe(true);
    for (const team_id of ["T1%", "T_1", "*", "", "t1"]) expect(slackEnvelopeSchema.safeParse({ ...base, team_id }).success, team_id).toBe(false);
  });

  it("URL 확인과 이벤트 요청을 가른다", () => {
    expect(slackEnvelopeSchema.parse({ type: "url_verification", challenge: "abc", token: "legacy" })).toEqual({ type: "url_verification", challenge: "abc" });
    const envelope = slackEnvelopeSchema.parse({
      type: "event_callback",
      team_id: "T1",
      event_id: "Ev1",
      event_time: 1727678400,
      authorizations: [{ user_id: "U_ME", team_id: "T1", is_bot: false }],
      event: { type: "message", channel: "D1", ts: "1.0", extra: true },
    });
    expect(envelope.type === "event_callback" && envelope.event).toMatchObject({ type: "message", extra: true });
  });
});
