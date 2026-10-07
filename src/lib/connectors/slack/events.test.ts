import { describe, expect, it } from "vitest";

import {
  classifySlackMessage,
  slackEnvelopeSchema,
  slackMessageEventSchema,
  slackMessageHasBroadcast,
  slackMessageHasUserMention,
  slackMessageText,
  slackTsDate,
  type SlackMessageEvent,
} from "./events";

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

  it("외부 앱 봇 DM과 직접 언급은 남기되 bot sender를 사람으로 오인하지 않는다", () => {
    expect(classifySlackMessage(msg({ channel_type: "im", bot_id: "B1", user: undefined }), ME, false)).toMatchObject({
      action: "keep",
      message: { senderId: "bot:B1" },
    });
    expect(classifySlackMessage(msg({ bot_id: "B1", user: undefined, subtype: "bot_message", text: "<@" + ME + "|Daniel> 배포를 확인해 주세요" }), ME, false)).toMatchObject({
      action: "keep",
      track: "1727678400.000100",
      message: { senderId: "bot:B1" },
    });
    expect(classifySlackMessage(msg({ bot_id: "B1", user: ME, text: "일반 봇 안내" }), ME, false)).toEqual({ action: "drop", reason: "bot" });
    expect(classifySlackMessage(msg({ channel_type: "im", subtype: "channel_join" }), ME, false)).toEqual({ action: "drop", reason: "subtype" });
    expect(classifySlackMessage(msg({ channel_type: "im", subtype: "bot_message" }), ME, false)).toEqual({ action: "drop", reason: "unsupported" });
    expect(classifySlackMessage(msg({ channel_type: "im", subtype: "file_share" }), ME, false)).toMatchObject({ action: "keep" });
    expect(classifySlackMessage(msg({ subtype: "thread_broadcast", user: ME, thread_ts: "1.0" }), ME, false)).toMatchObject({ action: "keep", track: "1.0" });
  });

  it("broadcast mention은 저장하지만 방송만으로 스레드를 새로 추적하지 않는다", () => {
    for (const text of ["<!channel> 일정 확인", "<!here> 일정 확인", "<!everyone> 일정 확인"]) {
      expect(classifySlackMessage(msg({ text }), ME, false)).toMatchObject({ action: "keep", track: null });
    }
    expect(classifySlackMessage(msg({ text: "<#C1|team> 일정 확인" }), ME, false)).toEqual({ action: "drop", reason: "not_involved" });
    expect(classifySlackMessage(msg({ text: "<@U_ME2> 이름이 비슷한 사용자" }), ME, false)).toEqual({ action: "drop", reason: "not_involved" });
    expect(slackMessageHasBroadcast("<#C1|team> <!channel>")).toBe(true);
    expect(slackMessageHasBroadcast("<#C1|team>")).toBe(false);
    expect(slackMessageHasUserMention("<@U_ME|Daniel>", ME)).toBe(true);
    expect(slackMessageHasUserMention("<@U_ME2>", ME)).toBe(false);
  });

  it("수신 앱 id 자체가 아니라 메시지의 app id가 일치할 때만 Taskforce 글을 버린다", () => {
    const own = msg({ user: ME, bot_id: "B_TASKFORCE", app_id: "A_TASKFORCE", text: "<!channel> 내부 공지" });
    expect(classifySlackMessage(own, ME, false, "A_TASKFORCE")).toEqual({ action: "drop", reason: "bot" });
    expect(classifySlackMessage(msg({ user: ME, text: "내 약속" }), ME, false, "A_TASKFORCE")).toMatchObject({ action: "keep", message: { senderId: ME } });
    expect(classifySlackMessage(msg({ user: undefined, bot_profile: { app_id: "A_TASKFORCE" }, bot_id: "B_TASKFORCE" }), ME, false, "A_TASKFORCE")).toEqual({
      action: "drop",
      reason: "bot",
    });
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

  it("편집은 중첩된 rich text의 언급을 읽고, 시스템 하위 유형과 Taskforce 자기 수정은 제외한다", () => {
    const edited = msg({
      subtype: "message_changed",
      channel_type: "channel",
      ts: "2.0",
      message: {
        ts: "1.0",
        user: "U_OTHER",
        text: "New message",
        blocks: [{ type: "section", text: { type: "mrkdwn", text: "<@U_ME|Daniel> 금요일까지 확인해 주세요 <!here>" } }],
      },
    });
    expect(classifySlackMessage(edited, ME, false)).toMatchObject({
      action: "edit",
      text: "New message\n<@U_ME|Daniel> 금요일까지 확인해 주세요 <!here>",
    });
    expect(
      classifySlackMessage(
        msg({
          subtype: "message_changed",
          channel_type: "channel",
          ts: "2.0",
          message: { ts: "1.0", bot_id: "B_TASKFORCE", bot_profile: { app_id: "A_TASKFORCE" }, text: "<!channel> self edit" },
        }),
        ME,
        false,
        "A_TASKFORCE",
      ),
    ).toEqual({ action: "drop", reason: "bot" });
    expect(
      classifySlackMessage(
        msg({ subtype: "message_changed", channel_type: "channel", ts: "2.0", message: { ts: "1.0", subtype: "channel_topic", text: "<!channel> system" } }),
        ME,
        false,
      ),
    ).toEqual({ action: "drop", reason: "subtype" });
  });

  it("채널 종류를 생략한 Slack 편집도 기존 pending row를 갱신한다", () => {
    const changed = msg({
      subtype: "message_changed",
      channel_type: undefined,
      user: undefined,
      ts: "2.0",
      message: { ts: "1.0", text: "화요일까지로 변경", user: "U_OTHER" },
    });
    expect(classifySlackMessage(changed, ME, false)).toMatchObject({ action: "edit", ts: "1.0" });
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
      api_app_id: "A_TASKFORCE",
      authorizations: [{ user_id: "U_ME", team_id: "T1", is_bot: false }],
      event: { type: "message", channel: "D1", ts: "1.0", extra: true },
    });
    expect(envelope.type === "event_callback" && envelope.api_app_id).toBe("A_TASKFORCE");
    expect(envelope.type === "event_callback" && envelope.event).toMatchObject({ type: "message", extra: true });
  });
});

describe("slackMessageEventSchema", () => {
  it("ts는 숫자.숫자만 받는다 (묶기 · 시각 계산이 깨지지 않게)", () => {
    const base = { type: "message", channel: "D1" };
    expect(slackMessageEventSchema.safeParse({ ...base, ts: "1727678400.000100" }).success).toBe(true);
    for (const ts of ["abc", "1727678400", "", "1.2.3"]) expect(slackMessageEventSchema.safeParse({ ...base, ts }).success, ts).toBe(false);
    expect(slackMessageEventSchema.safeParse({ ...base, ts: "1.0", thread_ts: "x" }).success).toBe(false);
  });
});

describe("Slack block text fallback", () => {
  it("bounded section/rich_text/attachment text adds missing actions and mentions without duplicating fallback", () => {
    const message = {
      text: "New request",
      blocks: [
        { type: "section", text: { type: "mrkdwn", text: "Review by Friday" } },
        { type: "section", fields: [{ type: "mrkdwn", text: "Priority: High" }] },
        {
          type: "rich_text",
          elements: [{ type: "rich_text_section", elements: [{ type: "user", user_id: ME }, { type: "text", text: " please review" }, { type: "broadcast", range: "here" }] }],
        },
      ],
      attachments: [{ fallback: "New request", title: "New request", fields: [{ title: "Owner", value: "Daniel" }] }],
    };
    expect(slackMessageText(message)).toBe("New request\nReview by Friday\nPriority: High\n<@U_ME> please review<!here>\nOwner\nDaniel");
    expect(slackMessageText({ text: "Review by Friday", blocks: [{ type: "section", text: { type: "plain_text", text: "Review by Friday" } }] })).toBe("Review by Friday");
    expect(slackMessageText({ text: undefined, blocks: [{ arbitrary: { secret: "must not be stringified" } }] })).toBe("");
    const longPlainText = "A".repeat(13_000) + " <@" + ME + ">";
    expect(slackMessageText({ text: longPlainText })).toBe(longPlainText);
    expect(slackMessageHasUserMention(slackMessageText({ text: longPlainText }), ME)).toBe(true);
  });

  it("plain_text, rich_text text leaves, and link labels keep mention syntax literal", () => {
    const plain = msg({
      text: undefined,
      blocks: [{ type: "section", text: { type: "plain_text", text: "Example <@U_ME> <!channel>" } }],
    });
    const rich = msg({
      text: undefined,
      blocks: [
        {
          type: "rich_text",
          elements: [{ type: "rich_text_section", elements: [{ type: "text", text: "Literal <@U_ME> <!channel>" }] }],
        },
        {
          type: "rich_text",
          elements: [{
            type: "rich_text_section",
            elements: [
              { type: "link", url: "https://example.test/<@U_ME>", text: "<@U_ME> <!channel>" },
              { type: "date", timestamp: 1727678400, fallback: "Literal <!everyone>" },
              { type: "date", timestamp: 1727678400 },
              { type: "channel", channel_id: "C1", name: "Literal <@U_ME>" },
            ],
          }],
        },
      ],
    });
    for (const message of [plain, rich]) {
      const text = slackMessageText(message);
      expect(slackMessageHasUserMention(text, ME)).toBe(false);
      expect(slackMessageHasBroadcast(text)).toBe(false);
      expect(classifySlackMessage(message, ME, false)).toEqual({ action: "drop", reason: "not_involved" });
    }
    expect(slackMessageText(plain)).toBe("Example &lt;@U_ME&gt; &lt;!channel&gt;");
    expect(slackMessageText(rich)).toContain("&lt;@U_ME&gt; &lt;!channel&gt;");
    expect(slackMessageText(rich)).toContain("&lt;!everyone&gt;");
    expect(slackMessageText(rich)).not.toContain("1727678400");
  });

  it("legacy attachment title, fallback, and non-mrkdwn fields keep mention syntax literal", () => {
    const message = msg({
      text: undefined,
      attachments: [{
        title: "Literal <@U_ME>",
        fallback: "Literal <!channel>",
        pretext: "Literal <!here>",
        text: "Literal <@U_ME>",
        fields: [{ title: "Literal <!everyone>", value: "Literal <@U_ME>" }],
      }],
    });
    const text = slackMessageText(message);
    expect(text).toContain("&lt;@U_ME&gt;");
    expect(text).toContain("&lt;!channel&gt;");
    expect(text).toContain("&lt;!here&gt;");
    expect(text).toContain("&lt;!everyone&gt;");
    expect(slackMessageHasUserMention(text, ME)).toBe(false);
    expect(slackMessageHasBroadcast(text)).toBe(false);
    expect(classifySlackMessage(message, ME, false)).toEqual({ action: "drop", reason: "not_involved" });
  });

  it("legacy attachment mrkdwn_in allows only configured text and field values to carry audience markers", () => {
    const message = msg({
      text: undefined,
      attachments: [{
        title: "Literal <@U_ME>",
        fallback: "Literal <!everyone>",
        text: "<!channel> Friday handoff",
        fields: [{ title: "Literal <@U_ME>", value: "<@U_ME> assigned" }],
        mrkdwn_in: ["text", "fields"],
      }],
    });
    const text = slackMessageText(message);
    expect(slackMessageHasBroadcast(text)).toBe(true);
    expect(slackMessageHasUserMention(text, ME)).toBe(true);
    expect(text).toContain("&lt;@U_ME&gt;");
    expect(text).toContain("&lt;!everyone&gt;");
    expect(classifySlackMessage(message, ME, false)).toMatchObject({ action: "keep", track: "1727678400.000100" });
  });

  it("structured user and broadcast mention elements are actionable audience markers", () => {
    const direct = msg({
      text: undefined,
      blocks: [
        {
          type: "rich_text",
          elements: [{ type: "rich_text_section", elements: [{ type: "user", user_id: ME }, { type: "text", text: " please " }, { type: "text", text: "review" }, { type: "text", text: " today" }] }],
        },
      ],
    });
    const broadcast = msg({
      text: undefined,
      blocks: [{ type: "rich_text", elements: [{ type: "rich_text_section", elements: [{ type: "broadcast", range: "channel" }, { type: "text", text: " release update" }] }] }],
    });
    expect(classifySlackMessage(direct, ME, false)).toMatchObject({ action: "keep", track: "1727678400.000100" });
    expect(classifySlackMessage(direct, ME, false)).toMatchObject({ message: { text: "<@U_ME> please review today" } });
    expect(classifySlackMessage(broadcast, ME, false)).toMatchObject({ action: "keep", track: null });
  });
});
