import { MAX_SOURCE_TEXT } from "@/lib/api/contract";

import type { IngestItem } from "../types";

import type { NotionPage, NotionUser } from "./api";
import { cleanNotionMarkdown, type UserNames } from "./markdown";

// Notion 페이지 한 장 → 공통 IngestItem. 속성에서 제목 · 회의 날짜 · 참석자를 읽고, 본문은 정리한 markdown을 쓴다.

const DATE_PROPERTY = /date|날짜|일시|일자|when/i;

export function pageTitle(page: NotionPage): string | null {
  for (const property of Object.values(page.properties)) {
    if (property.type === "title" && property.title?.length) {
      const title = property.title.map((t) => t.plain_text).join("").trim();
      if (title) return title;
    }
  }
  return null;
}

/** 회의 날짜 속성(이름에 Date · 날짜 등)이 있으면 그 날, 없으면 페이지를 만든 시각. 날짜만 있으면 한국 시간 그날 0시. */
export function pageOccurredAt(page: NotionPage): Date {
  const dates = Object.entries(page.properties).filter(([, p]) => p.type === "date" && p.date?.start);
  const [, property] = dates.find(([name]) => DATE_PROPERTY.test(name)) ?? dates[0] ?? [];
  const start = property?.date?.start;
  if (start) {
    const date = new Date(/^\d{4}-\d{2}-\d{2}$/.test(start) ? `${start}T00:00:00+09:00` : start);
    if (!Number.isNaN(date.getTime())) return date;
  }
  return new Date(page.created_time);
}

/** 사람 속성(참석자 · 담당자 등)에 있는 모든 사람 */
export function pagePeople(page: NotionPage): NotionUser[] {
  const seen = new Map<string, NotionUser>();
  for (const property of Object.values(page.properties)) {
    for (const person of property.type === "people" ? (property.people ?? []) : []) {
      if (person.type !== "bot") seen.set(person.id, person);
    }
  }
  return [...seen.values()];
}

/** 본문의 사람 언급에서 user id를 모은다 (이름을 알아야 원문에 넣을 수 있다). */
export function mentionedUserIds(markdown: string): string[] {
  return [...new Set([...markdown.matchAll(/<mention-user\b[^>]*url="user:\/\/([^"]+)"/g)].map((m) => m[1]))];
}

export function isMeetingPage(markdown: string, title: string | null): boolean {
  return /<meeting-notes\b/.test(markdown) || /meeting|sync|1:1|회의|미팅|싱크/i.test(title ?? "");
}

export function pageToItem(page: NotionPage, markdown: string, users: NotionUser[]): IngestItem {
  const names: UserNames = Object.fromEntries(users.filter((u) => u.name).map((u) => [u.id, u.name as string]));
  const title = pageTitle(page);
  const body = cleanNotionMarkdown(markdown, names);
  const attendees = pagePeople(page)
    .map((u) => ({ ...(u.name ? { name: u.name } : {}), ...(u.person?.email ? { email: u.person.email } : {}) }))
    .filter((p) => p.name || p.email);

  // 직접 입력(POST /api/v1/sources)과 같은 한도를 둔다. 긴 페이지는 비용 · 실행 시간을 키운다.
  return {
    externalId: page.id,
    externalVersion: page.last_edited_time,
    kind: isMeetingPage(markdown, title) ? "meeting" : "doc",
    title: title?.slice(0, 200) ?? null,
    text: (title ? `# ${title}\n\n${body}` : body).slice(0, MAX_SOURCE_TEXT),
    occurredAt: pageOccurredAt(page),
    lastEditedAt: new Date(page.last_edited_time),
    externalUrl: /^https:\/\/([a-z0-9-]+\.)*notion\.(so|site|com)\//i.test(page.url) ? page.url : null,
    ...(attendees.length > 0 ? { participants: { attendees: attendees.slice(0, 200) } } : {}),
  };
}
