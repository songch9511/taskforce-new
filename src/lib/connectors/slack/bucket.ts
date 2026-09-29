import type { ParticipantsInput } from "@/lib/api/contract";

import type { IngestItem } from "../types";

import { slackTsDate, type PendingSlackMessage } from "./events";

// 대기 메시지(slack_messages)를 대화 묶음으로 나눠 원문(IngestItem)으로 만든다 (docs/go-live/slack-integration.md 2-5, D1).
// 순수 함수: 이름 · 이미 넣은 스레드는 인자로 받는다. 본문 형식은 골든셋(evals/golden/slack-*.json)과 글자까지 같다.
//
// - 묶음 열쇠: DM · 그룹 DM 본 대화는 c:{대화}, 스레드는(모든 대화 종류) t:{대화}:{첫 글 ts}, 채널에서 남긴 첫 글은 t:{대화}:{ts}
// - 한 열쇠 안에서 대화가 30분 멈추거나, 한국 시간 자정을 넘거나, 첫 글에서 3시간이 지나거나, 100개가 되면 거기서 자른다
//   (기한 · Claim 시각이 원문의 occurredAt 하나로 계산된다: 날을 넘으면 "내일"이 하루 틀린다)
// - 마지막 묶음은 마지막 활동이 30분 지나야 넣는다(ingestItems). 자른 앞 묶음은 바로 넣을 수 있게 lastEditedAt을 30분 전 이하로 준다
// - 외부 id = {열쇠}:{묶음 첫 ts}, 버전 = 묶음 마지막 ts. 넣은 뒤 같은 대화에 온 글은 첫 ts가 달라 다음 묶음이 된다

export type StoredSlackMessage = PendingSlackMessage & { editedAt: Date | null };

export type SlackBucketContext = {
  now: Date;
  /** 이용자 본인: Slack id와 Taskforce 프로필 이름 (본인 줄 · 본인 언급은 프로필 이름으로 쓴다, identity.ts가 이름으로 알아본다) */
  me: { slackId: string; name: string };
  /** Slack 사용자 id → 이름 */
  people: ReadonlyMap<string, string>;
  /** 대화 id → 채널 이름(채널) 또는 상대 이름(DM) */
  conversations: ReadonlyMap<string, string>;
  /** 워크스페이스 주소 ("https://acme.slack.com/", auth.test). 없으면 링크 없음 */
  teamUrl: string | null;
  /** 첫 글을 이미 원문으로 넣은 채널 스레드 (threadStartIds의 외부 id 중 이미 넣은 것) */
  startedThreads: ReadonlySet<string>;
};

export type SlackBucket = { item: IngestItem; messages: { channelId: string; ts: string }[] };

export const SLACK_BUCKET_LIMITS = { quietMinutes: 30, maxHours: 3, maxMessages: 100 };

const UNKNOWN_PERSON = "알 수 없는 사용자";
const KST_OFFSET_MS = 9 * 3_600_000;

const isReply = (m: PendingSlackMessage) => m.threadTs !== null && m.threadTs !== m.ts;
const isDirect = (m: PendingSlackMessage) => m.channelType === "im" || m.channelType === "mpim";

function bucketKey(m: PendingSlackMessage): string {
  if (isReply(m)) return `t:${m.channelId}:${m.threadTs}`;
  return isDirect(m) ? `c:${m.channelId}` : `t:${m.channelId}:${m.ts}`;
}

/** 채널 스레드의 첫 묶음 외부 id: 첫 글이 늘 첫 묶음의 맨 앞이다 */
const threadStartId = (channelId: string, threadTs: string) => `t:${channelId}:${threadTs}:${threadTs}`;

/** 첫 글이 대기 목록에 없는 채널 스레드 답글들의 첫 묶음 외부 id. 이미 넣었는지 동기화가 확인한다 (스레드 이어서 · 중간부터) */
export function threadStartIds(messages: PendingSlackMessage[]): string[] {
  const pending = new Set(messages.map((m) => `${m.channelId}:${m.ts}`));
  const ids = messages.filter((m) => isReply(m) && !isDirect(m) && !pending.has(`${m.channelId}:${m.threadTs}`)).map((m) => threadStartId(m.channelId, m.threadTs!));
  return [...new Set(ids)];
}

const MENTION = /<@([^|<>]+)(?:\|[^<>]*)?>/g;

/** 이름을 알아야 하는 Slack id: 보낸 사람 · 언급된 사람(본인 제외), 채널 이름 · DM 상대를 알아야 하는 대화 */
export function slackIdsToName(messages: PendingSlackMessage[], meSlackId: string): { users: string[]; conversations: string[] } {
  const users = new Set<string>();
  const conversations = new Set<string>();
  for (const m of messages) {
    if (m.senderId && m.senderId !== meSlackId) users.add(m.senderId);
    for (const [, id] of m.text.matchAll(MENTION)) if (id !== meSlackId) users.add(id);
    if (m.channelType !== "mpim") conversations.add(m.channelId);
  }
  return { users: [...users], conversations: [...conversations] };
}

/** ts 순서 (초 · 소수부를 따로 비교: Number로 바꾸면 마이크로초 자리가 뭉개질 수 있다) */
export function compareSlackTs(a: string, b: string): number {
  const [aSec, aFrac = ""] = a.split(".");
  const [bSec, bFrac = ""] = b.split(".");
  const bySec = Number(aSec) - Number(bSec);
  if (bySec !== 0) return bySec;
  const x = aFrac.padEnd(6, "0");
  const y = bFrac.padEnd(6, "0");
  return x < y ? -1 : x > y ? 1 : 0;
}

const kstDay = (ms: number) => new Date(ms + KST_OFFSET_MS).toISOString().slice(0, 10);

/** Slack 서식을 읽는 글로: <@U…> → @이름, <#C…|이름> → #이름, <주소|글> → 글 (주소), &lt; &gt; &amp; 풀기. 이모지 코드는 그대로 */
export function renderSlackText(text: string, context: Pick<SlackBucketContext, "me" | "people" | "conversations">): string {
  return text
    .replace(/<([^<>]*)>/g, (_, inner: string) => {
      const bar = inner.indexOf("|");
      const target = bar < 0 ? inner : inner.slice(0, bar);
      const label = bar < 0 ? null : inner.slice(bar + 1) || null;
      if (target.startsWith("@")) {
        const id = target.slice(1);
        return `@${id === context.me.slackId ? context.me.name : (context.people.get(id) ?? label ?? UNKNOWN_PERSON)}`;
      }
      if (target.startsWith("#")) return `#${label ?? context.conversations.get(target.slice(1)) ?? "channel"}`;
      if (target.startsWith("!")) {
        const special = target.slice(1);
        if (special === "here" || special === "channel" || special === "everyone") return `@${special}`;
        return label ?? (special.startsWith("subteam^") ? "@group" : "");
      }
      if (target.startsWith("mailto:")) return label ?? target.slice("mailto:".length);
      return label && label !== target ? `${label} (${target})` : target;
    })
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function messageLink(teamUrl: string | null, m: PendingSlackMessage): string | null {
  if (!teamUrl) return null;
  const base = teamUrl.endsWith("/") ? teamUrl : `${teamUrl}/`;
  const link = `${base}archives/${m.channelId}/p${m.ts.replace(".", "")}`;
  return isReply(m) ? `${link}?thread_ts=${m.threadTs}&cid=${m.channelId}` : link;
}

/** 한 열쇠의 메시지(ts 순)를 D1 규칙으로 자른다 */
function segment(messages: StoredSlackMessage[]): StoredSlackMessage[][] {
  const quietMs = SLACK_BUCKET_LIMITS.quietMinutes * 60_000;
  const maxSpanMs = SLACK_BUCKET_LIMITS.maxHours * 3_600_000;
  const segments: StoredSlackMessage[][] = [];
  let current: StoredSlackMessage[] = [];
  for (const m of messages) {
    if (current.length > 0) {
      const at = slackTsDate(m.ts).getTime();
      const first = slackTsDate(current[0].ts).getTime();
      const previous = slackTsDate(current[current.length - 1].ts).getTime();
      if (at - previous > quietMs || kstDay(at) !== kstDay(first) || at - first > maxSpanMs || current.length >= SLACK_BUCKET_LIMITS.maxMessages) {
        segments.push(current);
        current = [];
      }
    }
    current.push(m);
  }
  if (current.length > 0) segments.push(current);
  return segments;
}

/** 대기 메시지 → 원문 묶음. 넣을 때가 됐는지는 ingestItems가 lastEditedAt으로 가른다 */
export function bucketSlackMessages(messages: StoredSlackMessage[], context: SlackBucketContext): SlackBucket[] {
  const byKey = new Map<string, StoredSlackMessage[]>();
  for (const m of [...messages].sort((a, b) => compareSlackTs(a.ts, b.ts))) {
    const key = bucketKey(m);
    const list = byKey.get(key);
    if (list) list.push(m);
    else byKey.set(key, [m]);
  }

  const settledAt = context.now.getTime() - SLACK_BUCKET_LIMITS.quietMinutes * 60_000;
  const speaker = (senderId: string) => (senderId === context.me.slackId ? context.me.name : (context.people.get(senderId) ?? UNKNOWN_PERSON));

  const buckets: SlackBucket[] = [];
  for (const [key, all] of byKey) {
    const segments = segment(all);
    segments.forEach((part, index) => {
      const first = part[0];
      const last = part[part.length - 1];
      const lines = part.flatMap((m) => {
        const text = renderSlackText(m.text, context).trim();
        return text ? [`${speaker(m.senderId)}: ${text}`] : [];
      });

      // 머리줄 · 제목
      const counterpart =
        first.channelType === "im"
          ? (context.conversations.get(first.channelId) ?? part.map((m) => context.people.get(m.senderId)).find((name) => name && name !== context.me.name) ?? null)
          : null;
      const channelName = context.conversations.get(first.channelId) ?? "channel";
      const place = first.channelType === "im" ? (counterpart ? `DM · ${counterpart}` : "DM") : first.channelType === "mpim" ? "그룹 DM" : `#${channelName}`;
      const title =
        first.channelType === "im" ? (counterpart ? `Slack · DM with ${counterpart}` : "Slack · DM") : first.channelType === "mpim" ? "Slack · Group DM" : `Slack · #${channelName}`;
      // 첫 글이 이 묶음에 없는 스레드: 앞 원문에 있으면(또는 모든 글을 남기는 DM이면) 이어서, 아니면 중간부터 (D2)
      let suffix = "";
      if (isReply(first)) {
        const continued =
          isDirect(first) || all.some((m) => m.ts === first.threadTs) || context.startedThreads.has(threadStartId(first.channelId, first.threadTs!));
        suffix = continued ? " · 스레드 이어서" : " · 스레드 중간부터";
      }

      // 관련자: DM은 상대와 이용자, 그 밖에는 글을 쓴 사람 + 언급된 사람 + 이용자 (@이름이 다른 사람인지 가리는 데 쓴다, TRUTH_RULES 1장)
      const names: string[] = [];
      const add = (name: string | null | undefined) => {
        const trimmed = name?.trim().slice(0, 100);
        if (trimmed && trimmed !== UNKNOWN_PERSON && !names.some((n) => n.replace(/\s+/g, "") === trimmed.replace(/\s+/g, ""))) names.push(trimmed);
      };
      if (first.channelType === "im") {
        add(counterpart);
      } else {
        for (const m of part) add(speaker(m.senderId));
        for (const m of part) for (const [, id] of m.text.matchAll(MENTION)) add(id === context.me.slackId ? context.me.name : context.people.get(id));
      }
      add(context.me.name);
      const participants: ParticipantsInput = { attendees: names.map((name) => ({ name })) };

      const lastActivity = Math.max(...part.map((m) => Math.max(slackTsDate(m.ts).getTime(), m.editedAt?.getTime() ?? 0)));
      const closed = index < segments.length - 1;
      buckets.push({
        item: {
          externalId: `${key}:${first.ts}`,
          externalVersion: last.ts,
          kind: "message",
          title,
          text: lines.length > 0 ? [`[${place}${suffix}]`, ...lines].join("\n") : "",
          occurredAt: slackTsDate(first.ts),
          lastEditedAt: new Date(closed ? Math.min(lastActivity, settledAt) : lastActivity),
          externalUrl: messageLink(context.teamUrl, first),
          participants,
          writtenByMe: null,
        },
        messages: part.map((m) => ({ channelId: m.channelId, ts: m.ts })),
      });
    });
  }
  return buckets;
}
