import { z } from "zod";

// Slack Events API로 받은 요청의 모양과, 메시지 하나를 남길지 버릴지 가르는 규칙 (docs/go-live/slack-app.md 3-2,
// docs/go-live/slack-integration.md 2-4). 순수 함수: DB는 receive.ts가 부른다.

/** Slack 메시지 ts ("1727678400.000100"). 숫자가 아니면 묶기 · 시각 계산이 깨지므로 받을 때 거른다 */
const slackTs = z.string().regex(/^\d{1,12}\.\d{1,9}$/);

export const slackMessageEventSchema = z.object({
  type: z.literal("message"),
  channel: z.string().min(1),
  /** 고침 · 지움 이벤트에는 없을 수 있다 */
  channel_type: z.enum(["im", "mpim", "channel", "group"]).optional(),
  user: z.string().optional(),
  text: z.string().optional(),
  ts: slackTs,
  thread_ts: slackTs.optional(),
  subtype: z.string().optional(),
  bot_id: z.string().optional(),
  /** message_changed: 고친 뒤의 메시지 */
  message: z
    .object({
      user: z.string().optional(),
      text: z.string().optional(),
      ts: slackTs,
      thread_ts: slackTs.optional(),
      bot_id: z.string().optional(),
      edited: z.object({ ts: z.string() }).optional(),
    })
    .optional(),
  /** message_deleted: 지운 메시지의 ts */
  deleted_ts: slackTs.optional(),
});

export type SlackMessageEvent = z.infer<typeof slackMessageEventSchema>;

export const slackTokensRevokedSchema = z.object({
  type: z.literal("tokens_revoked"),
  tokens: z.object({ oauth: z.array(z.string()).optional(), bot: z.array(z.string()).optional() }),
});

const eventCallbackSchema = z.object({
  type: z.literal("event_callback"),
  // Slack 팀 id(T… · 엔터프라이즈 E…). 연결을 찾는 쿼리에 들어가므로 영문 대문자 · 숫자만 받는다 (와일드카드 %, _, * 차단)
  team_id: z.string().regex(/^[A-Z0-9]{1,32}$/),
  event_id: z.string().min(1),
  event_time: z.number(),
  /** apps.event.authorizations.list로 이 이벤트를 볼 수 있는 설치를 모두 찾을 때 쓴다 */
  event_context: z.string().optional(),
  authorizations: z
    .array(z.object({ user_id: z.string().optional(), team_id: z.string().optional(), is_bot: z.boolean().optional() }))
    .optional(),
  event: z.looseObject({ type: z.string() }),
});

export type SlackEventCallback = z.infer<typeof eventCallbackSchema>;

export const slackEnvelopeSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("url_verification"), challenge: z.string() }),
  eventCallbackSchema,
]);

export type SlackEnvelope = z.infer<typeof slackEnvelopeSchema>;

/** 남길 메시지 한 줄 (slack_messages 행) */
export type PendingSlackMessage = {
  channelId: string;
  channelType: "im" | "mpim" | "channel" | "group";
  ts: string;
  threadTs: string | null;
  senderId: string;
  text: string;
};

export type SlackMessageDecision =
  | { action: "drop"; reason: "subtype" | "bot" | "not_involved" | "unsupported" }
  | { action: "keep"; message: PendingSlackMessage; /** 추적에 올리거나 활동 시각을 갱신할 스레드 (채널만) */ track: string | null }
  | { action: "edit"; channelId: string; ts: string; text: string; editedAt: Date }
  /**
   * 지움 표시: 행을 지우지 않고 글을 비운다 (늦게 온 원래 메시지가 다시 들어오지 않게).
   * createIfMissing: 행이 없어도 표시 행을 만든다 — DM · 그룹 DM만. 채널은 모든 메시지가 오므로 이미 남긴 행에만 표시한다
   * (나와 무관한 채널 글의 지움 · 수정마다 흔적을 남기지 않는다)
   */
  | { action: "delete"; channelId: string; channelType: PendingSlackMessage["channelType"]; ts: string; createIfMissing: boolean };

// 글로 남기는 하위 유형. 나머지(bot_message · channel_join · channel_topic · pinned_item …)는 사람의 대화가 아니다.
const KEPT_SUBTYPES = new Set(["thread_broadcast", "file_share", "me_message"]);

/** Slack ts("1727678400.123456")를 시각으로 */
export const slackTsDate = (ts: string) => new Date(Math.round(Number(ts) * 1000));

/**
 * 메시지 이벤트 하나를 이용자(Slack id) 기준으로 가른다.
 * - DM · 그룹 DM: 모두 남긴다 (봇 · 시스템 하위 유형 제외)
 * - 채널 · 비공개 채널: 이용자를 언급(<@id>)했거나, 이용자가 썼거나, 추적 중인 스레드의 답글일 때만. 나머지는 버린다(저장하지 않음)
 * - 채널에서 남긴 글은 그 스레드(첫 글이면 자기 ts)를 추적에 올린다: 이용자가 쓰거나 언급된 스레드의 답글은 이용자를 부르지 않아도 남긴다
 * - message_changed: 아직 원문으로 넣지 않은 행만 고친다. 채널 글이 고쳐서 이용자와 무관해졌으면(언급을 지움) 지움 표시로 바꾼다
 * - message_deleted: 지움 표시 (receive.ts)
 * @param threadTracked 이 메시지가 속한 스레드를 이미 추적 중인가 (채널의 스레드 답글일 때만 의미가 있다)
 */
export function classifySlackMessage(event: SlackMessageEvent, userSlackId: string, threadTracked: boolean): SlackMessageDecision {
  const channelType = event.channel_type ?? "channel";
  const direct = channelType === "im" || channelType === "mpim";
  if (event.subtype === "message_changed") {
    const edited = event.message;
    if (!edited?.text || edited.bot_id) return { action: "drop", reason: "unsupported" };
    const channelMessage = event.channel_type === "channel" || event.channel_type === "group";
    const stillInvolved =
      !channelMessage || edited.user === userSlackId || edited.text.includes(`<@${userSlackId}>`) || (Boolean(edited.thread_ts) && threadTracked);
    if (!stillInvolved) return { action: "delete", channelId: event.channel, channelType, ts: edited.ts, createIfMissing: false };
    return { action: "edit", channelId: event.channel, ts: edited.ts, text: edited.text, editedAt: slackTsDate(edited.edited?.ts ?? event.ts) };
  }
  if (event.subtype === "message_deleted") {
    return event.deleted_ts
      ? { action: "delete", channelId: event.channel, channelType, ts: event.deleted_ts, createIfMissing: direct }
      : { action: "drop", reason: "unsupported" };
  }
  if (event.subtype && !KEPT_SUBTYPES.has(event.subtype)) return { action: "drop", reason: "subtype" };
  if (event.bot_id) return { action: "drop", reason: "bot" };
  if (!event.user || !event.channel_type) return { action: "drop", reason: "unsupported" };

  const text = event.text ?? "";
  const involved = event.user === userSlackId || text.includes(`<@${userSlackId}>`) || (Boolean(event.thread_ts) && threadTracked);
  if (!direct && !involved) return { action: "drop", reason: "not_involved" };

  const threadTs = event.thread_ts ?? null;
  return {
    action: "keep",
    message: { channelId: event.channel, channelType: event.channel_type, ts: event.ts, threadTs, senderId: event.user, text },
    track: direct ? null : (threadTs ?? event.ts),
  };
}
