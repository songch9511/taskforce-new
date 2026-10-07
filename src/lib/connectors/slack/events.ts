import { z } from "zod";

// Slack Events API로 받은 요청의 모양과, 메시지 하나를 남길지 버릴지 가르는 규칙 (docs/go-live/slack-app.md 3-2,
// docs/go-live/slack-integration.md 2-4). 순수 함수: DB는 receive.ts가 부른다.

/** Slack 메시지 ts ("1727678400.000100"). 숫자가 아니면 묶기 · 시각 계산이 깨지므로 받을 때 거른다 */
const slackTs = z.string().regex(/^\d{1,12}\.\d{1,9}$/);
const slackMessageContentSchema = z.object({
  user: z.string().optional(),
  text: z.string().optional(),
  ts: slackTs,
  thread_ts: slackTs.optional(),
  bot_id: z.string().optional(),
  app_id: z.string().optional(),
  bot_profile: z.object({ app_id: z.string().optional() }).optional(),
  subtype: z.string().optional(),
  blocks: z.array(z.unknown()).optional(),
  attachments: z.array(z.unknown()).optional(),
  edited: z.object({ ts: z.string() }).optional(),
});

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
  app_id: z.string().optional(),
  bot_profile: z.object({ app_id: z.string().optional() }).optional(),
  edited: z.object({ ts: z.string() }).optional(),
  blocks: z.array(z.unknown()).optional(),
  attachments: z.array(z.unknown()).optional(),
  /** message_changed: 고친 뒤의 메시지 */
  message: slackMessageContentSchema.optional(),
  /** message_deleted: 지운 메시지의 ts */
  deleted_ts: slackTs.optional(),
});

export type SlackMessageEvent = z.infer<typeof slackMessageEventSchema>;
type SlackMessageContent = z.infer<typeof slackMessageContentSchema>;

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
  /** api_app_id는 메시지의 app_id와 비교할 때만 Taskforce 작성 글을 가리는 데 쓴다 */
  api_app_id: z.string().optional(),
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

// message_changed의 현재 내용은 event.message에 있다. 나머지 이벤트는 바깥 메시지 필드를 쓴다.
export function slackMessageContent(event: SlackMessageEvent): SlackMessageContent | SlackMessageEvent {
  return event.subtype === "message_changed" ? event.message ?? event : event;
}

/** 봇은 user 필드도 가질 수 있으므로 bot_id가 사람 id보다 우선한다. app_id는 classic bot의 보조 식별자다. */
export function slackBotSenderId(message: Pick<SlackMessageContent, "bot_id" | "app_id" | "bot_profile">): string | null {
  if (message.bot_id) return `bot:${message.bot_id}`;
  const appId = message.app_id || message.bot_profile?.app_id;
  return appId ? `app:${appId}` : null;
}

export const isSyntheticSlackBotSender = (senderId: string) => senderId.startsWith("bot:") || senderId.startsWith("app:");

/** api_app_id identifies the receiving app. Only a matching authored message belongs to that app. */
export function isSlackSelfAppMessage(message: Pick<SlackMessageContent, "app_id" | "bot_profile">, apiAppId?: string): boolean {
  return Boolean(apiAppId && (message.app_id === apiAppId || message.bot_profile?.app_id === apiAppId));
}

// The Events route accepts at most 1 MB of JSON. Keep structured expansion within that same envelope bound.
const MAX_TEXT_LENGTH = 1_000_000;
const MAX_STRUCTURED_NODES = 100;
const MAX_STRUCTURED_DEPTH = 6;
const BROADCASTS = new Set(["here", "channel", "everyone"]);

function escapeSlackLiteral(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function textValue(value: unknown, literal = false): string[] {
  if (typeof value === "string") {
    const text = literal ? escapeSlackLiteral(value) : value;
    return text.trim() ? [text.trim()] : [];
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  const item = value as Record<string, unknown>;
  const text = item.text;
  if (typeof text !== "string" || !text.trim()) return [];
  const content = item.type !== "mrkdwn" || literal ? escapeSlackLiteral(text) : text;
  return [content.trim()];
}

type TextBudget = { remaining: number };

/** Read only Slack's known human-readable rich-text element shapes; never stringify arbitrary payloads. */
function richText(value: unknown, budget: TextBudget, depth = 0): string[] {
  if (depth > MAX_STRUCTURED_DEPTH || budget.remaining <= 0) return [];
  if (Array.isArray(value)) return value.slice(0, budget.remaining).flatMap((child) => richText(child, budget, depth + 1));
  if (!value || typeof value !== "object") return [];
  budget.remaining--;
  const item = value as Record<string, unknown>;
  const type = typeof item.type === "string" ? item.type : "";

  if (type === "user" && typeof item.user_id === "string") return [`<@${escapeSlackLiteral(item.user_id)}>`];
  if (type === "broadcast" && typeof item.range === "string" && BROADCASTS.has(item.range)) return [`<!${item.range}>`];
  if (type === "channel" && typeof item.channel_id === "string") {
    const channelId = escapeSlackLiteral(item.channel_id);
    const name = typeof item.name === "string" ? escapeSlackLiteral(item.name) : "";
    return [`<#${channelId}${name ? `|${name}` : ""}>`];
  }
  if (type === "link") {
    const url = typeof item.url === "string" ? item.url : "";
    const safeUrl = escapeSlackLiteral(url);
    const label = typeof item.text === "string" ? escapeSlackLiteral(item.text) : "";
    return [safeUrl && label ? `<${safeUrl}|${label}>` : label || safeUrl].filter(Boolean);
  }
  if (type === "text") return typeof item.text === "string" && item.text ? [escapeSlackLiteral(item.text)] : [];
  if (type === "emoji" && typeof item.name === "string") return [`:${escapeSlackLiteral(item.name)}:`];
  if (type === "image") return textValue(item.alt_text, true);
  if (type === "plain_text" || type === "mrkdwn") return textValue(item);
  if (type === "section") {
    const output = textValue(item.text);
    if (Array.isArray(item.fields)) {
      for (const field of item.fields.slice(0, 20)) output.push(...textValue(field));
    }
    return output;
  }
  if (type === "header") return textValue(item.text, true);
  if (type === "rich_text_section") {
    const body = richTextInline(item.elements, budget, depth + 1).join("").trim();
    return body ? [body] : [];
  }
  if (type === "rich_text_list") {
    return richText(item.elements, budget, depth + 1).map((line) => `• ${line}`);
  }
  if (["rich_text", "context", "actions"].includes(type)) {
    return richText(item.elements, budget, depth + 1);
  }
  return [];
}

/** Rich text sections contain inline leaves; join them before turning them into separate source lines. */
function richTextInline(value: unknown, budget: TextBudget, depth = 0): string[] {
  if (depth > MAX_STRUCTURED_DEPTH || budget.remaining <= 0) return [];
  if (Array.isArray(value)) return value.slice(0, budget.remaining).flatMap((child) => richTextInline(child, budget, depth + 1));
  if (!value || typeof value !== "object") return [];
  budget.remaining--;
  const item = value as Record<string, unknown>;
  const type = typeof item.type === "string" ? item.type : "";
  if (type === "text") return typeof item.text === "string" && item.text ? [escapeSlackLiteral(item.text)] : [];
  if (type === "user" && typeof item.user_id === "string") return [`<@${escapeSlackLiteral(item.user_id)}>`];
  if (type === "broadcast" && typeof item.range === "string" && BROADCASTS.has(item.range)) return [`<!${item.range}>`];
  if (type === "channel" && typeof item.channel_id === "string") {
    const channelId = escapeSlackLiteral(item.channel_id);
    const name = typeof item.name === "string" ? escapeSlackLiteral(item.name) : "";
    return [`<#${channelId}${name ? `|${name}` : ""}>`];
  }
  if (type === "link") {
    const url = typeof item.url === "string" ? item.url : "";
    const safeUrl = escapeSlackLiteral(url);
    const label = typeof item.text === "string" ? escapeSlackLiteral(item.text) : "";
    return [safeUrl && label ? `<${safeUrl}|${label}>` : label || safeUrl].filter(Boolean);
  }
  if (type === "emoji" && typeof item.name === "string") return [`:${escapeSlackLiteral(item.name)}:`];
  if (type === "date" && (typeof item.timestamp === "number" || typeof item.timestamp === "string")) {
    return typeof item.fallback === "string" ? [escapeSlackLiteral(item.fallback)] : [];
  }
  if (type === "linebreak") return ["\n"];
  if (type === "rich_text_section") return richTextInline(item.elements, budget, depth + 1);
  return [];
}

function structuredMessageText(message: Pick<SlackMessageContent, "blocks" | "attachments">): string[] {
  const budget = { remaining: MAX_STRUCTURED_NODES };
  const output: string[] = [];
  for (const block of message.blocks ?? []) output.push(...richText(block, budget));
  for (const raw of (message.attachments ?? []).slice(0, 20)) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw) || budget.remaining <= 0) continue;
    budget.remaining--;
    const attachment = raw as Record<string, unknown>;
    const mrkdwnIn = new Set(Array.isArray(attachment.mrkdwn_in) ? attachment.mrkdwn_in.filter((value): value is string => typeof value === "string") : []);
    for (const key of ["pretext", "text"]) output.push(...textValue(attachment[key], !mrkdwnIn.has(key)));
    // Legacy attachment fallback/title/field titles are plain text. Only fields explicitly named in mrkdwn_in
    // can contain audience syntax, matching Slack's attachment rendering rules.
    output.push(...textValue(attachment.fallback, true), ...textValue(attachment.title, true));
    if (Array.isArray(attachment.fields)) {
      for (const field of attachment.fields.slice(0, 20)) {
        if (!field || typeof field !== "object" || Array.isArray(field)) continue;
        const value = field as Record<string, unknown>;
        output.push(...textValue(value.title, true), ...textValue(value.value, !mrkdwnIn.has("fields")));
      }
    }
    if (Array.isArray(attachment.blocks)) output.push(...richText(attachment.blocks, budget));
  }
  return output;
}

function normalizedTextKey(value: string) {
  return value.replace(/\s+/g, " ").trim().toLocaleLowerCase();
}

/** Message text plus bounded visible Block Kit / attachment content (including structured mentions). */
export function slackMessageText(message: Pick<SlackMessageContent, "text" | "blocks" | "attachments">): string {
  const base = message.text?.trim() ?? "";
  const structured = structuredMessageText(message);
  if (structured.length === 0) return base;
  const lines = base ? [base] : [];
  for (const candidate of structured) {
    const key = normalizedTextKey(candidate);
    if (!key || lines.some((line) => normalizedTextKey(line).includes(key))) continue;
    // A rich-text label can contain the smaller title already seen in an attachment.
    const contained = lines.findIndex((line) => key.includes(normalizedTextKey(line)));
    if (contained >= 0) lines.splice(contained, 1);
    lines.push(candidate.trim());
  }
  return lines.join("\n").slice(0, MAX_TEXT_LENGTH);
}

export function slackMessageHasUserMention(text: string, slackUserId: string): boolean {
  for (const match of text.matchAll(/<@([^|<>]+)(?:\|[^<>]*)?>/g)) if (match[1] === slackUserId) return true;
  return false;
}

export function slackMessageHasBroadcast(text: string): boolean {
  for (const match of text.matchAll(/<!([^|<>]+)(?:\|[^<>]*)?>/g)) if (BROADCASTS.has(match[1])) return true;
  return false;
}

/** Slack ts("1727678400.123456")를 시각으로 */
export const slackTsDate = (ts: string) => new Date(Math.round(Number(ts) * 1000));

/**
 * 메시지 이벤트 하나를 이용자(Slack id) 기준으로 가른다.
 * - DM · 그룹 DM: 봇 · 시스템 하위 유형을 빼고 모두 남긴다
 * - 채널: 이용자 직접 언급, 실제 broadcast mention, 이용자 본인, 기존 추적 스레드만 남긴다
 * - broadcast mention만으로 받은 글은 저장하지만 새 스레드를 추적하지 않는다
 * - 봇 작성자는 bot_id/app_id를 보존해 사람 작성자와 구분한다
 * - message_changed의 현재 내용은 중첩 message에서 읽고 같은 제외 규칙을 적용한다
 * @param threadTracked 이 메시지가 속한 스레드를 이미 추적 중인가 (채널의 스레드 답글일 때만 의미가 있다)
 */
export function classifySlackMessage(
  event: SlackMessageEvent,
  userSlackId: string,
  threadTracked: boolean,
  apiAppId?: string,
): SlackMessageDecision {
  const content = slackMessageContent(event);
  const channelType = event.channel_type ?? "channel";
  const direct = channelType === "im" || channelType === "mpim";
  // An edit can omit channel_type. Preserve the prior update-by-ts behavior when Slack gives no scope metadata.
  const channelMessage = event.channel_type === "channel" || event.channel_type === "group";
  const text = slackMessageText(content);
  const botSenderId = slackBotSenderId(content);
  const isBot = Boolean(botSenderId) || content.subtype === "bot_message";
  const selfApp = isSlackSelfAppMessage(content, apiAppId);
  const userMention = slackMessageHasUserMention(text, userSlackId);
  const broadcast = slackMessageHasBroadcast(text);
  const threadTs = content.thread_ts ?? event.thread_ts ?? null;
  const humanSelf = !isBot && content.user === userSlackId;
  const explicitlyInvolved = humanSelf || userMention || (Boolean(threadTs) && threadTracked);

  if (event.subtype === "message_changed") {
    if (selfApp || !text || !content || (content.subtype && content.subtype !== "bot_message" && !KEPT_SUBTYPES.has(content.subtype))) {
      return { action: "drop", reason: selfApp ? "bot" : content?.subtype ? "subtype" : "unsupported" };
    }
    if (content.subtype === "bot_message" && !botSenderId) return { action: "drop", reason: "unsupported" };
    const stillInvolved = !channelMessage || explicitlyInvolved || broadcast;
    if (!stillInvolved) return { action: "delete", channelId: event.channel, channelType, ts: content.ts, createIfMissing: false };
    return { action: "edit", channelId: event.channel, ts: content.ts, text, editedAt: slackTsDate(content.edited?.ts ?? event.ts) };
  }
  if (event.subtype === "message_deleted") {
    return event.deleted_ts
      ? { action: "delete", channelId: event.channel, channelType, ts: event.deleted_ts, createIfMissing: direct }
      : { action: "drop", reason: "unsupported" };
  }
  if (event.subtype && event.subtype !== "bot_message" && !KEPT_SUBTYPES.has(event.subtype)) {
    return { action: "drop", reason: "subtype" };
  }
  if (selfApp) return { action: "drop", reason: "bot" };
  if (event.subtype === "bot_message" && !botSenderId) return { action: "drop", reason: "unsupported" };

  const senderId = botSenderId ?? content.user;
  if (!senderId || !event.channel_type) return { action: "drop", reason: "unsupported" };
  if (isBot && !botSenderId) return { action: "drop", reason: "unsupported" };
  if (!direct && !explicitlyInvolved && !broadcast) return { action: "drop", reason: isBot ? "bot" : "not_involved" };

  return {
    action: "keep",
    message: { channelId: event.channel, channelType: event.channel_type, ts: event.ts, threadTs, senderId, text },
    track: direct ? null : explicitlyInvolved ? (threadTs ?? event.ts) : null,
  };
}

// Stable bot/app identity lets bot_message through without treating it as a human. Other system subtypes stay excluded.
const KEPT_SUBTYPES = new Set(["thread_broadcast", "file_share", "me_message"]);
