import { describe, expect, it } from "vitest";

import type { NotionPage } from "./api";
import { mentionedUserIds, pageOccurredAt, pageToItem } from "./map";

const person = (id: string, name: string, email?: string) => ({ object: "user" as const, id, name, type: "person", person: email ? { email } : {} });

const page: NotionPage = {
  object: "page",
  id: "p1",
  url: "https://www.notion.so/p1",
  created_time: "2026-09-08T00:30:00.000Z",
  last_edited_time: "2026-09-08T05:43:00.000Z",
  parent: { type: "data_source_id" },
  properties: {
    "Meeting name": { type: "title", title: [{ plain_text: "Shape Weekly Meeting" }] },
    Date: { type: "date", date: { start: "2026-09-08" } },
    Attendees: { type: "people", people: [person("u1", "도윤", "doyun@x.com"), person("u2", "태오")] },
    Owner: { type: "people", people: [person("u2", "태오"), { object: "user", id: "b1", type: "bot" }] },
  },
};

const markdown = `<meeting-notes>\n<summary>\n- [ ] <mention-user url="user://u1"/> - UX 기획 진행 [^https://a]\n</summary>\n</meeting-notes>`;

describe("pageToItem", () => {
  it("제목 · 회의 날짜 · 참석자 · 정리한 본문으로 IngestItem을 만든다", () => {
    const item = pageToItem(page, markdown, [person("u1", "도윤"), person("u2", "태오")]);
    expect(item).toEqual({
      externalId: "p1",
      externalVersion: "2026-09-08T05:43:00.000Z",
      kind: "meeting",
      title: "Shape Weekly Meeting",
      text: "# Shape Weekly Meeting\n\n[AI 요약]\n- [ ] @도윤 - UX 기획 진행",
      occurredAt: new Date("2026-09-08T00:00:00+09:00"),
      lastEditedAt: new Date("2026-09-08T05:43:00.000Z"),
      externalUrl: "https://www.notion.so/p1",
      participants: { attendees: [{ name: "도윤", email: "doyun@x.com" }, { name: "태오" }] },
    });
  });

  it("회의 표시가 없는 페이지는 문서로 본다", () => {
    const doc = { ...page, properties: { Name: { type: "title", title: [{ plain_text: "SFT 스펙" }] } } };
    expect(pageToItem(doc, "본문", []).kind).toBe("doc");
  });
});

describe("pageOccurredAt", () => {
  it("날짜 속성이 없으면 만든 시각", () => {
    expect(pageOccurredAt({ ...page, properties: {} })).toEqual(new Date("2026-09-08T00:30:00.000Z"));
  });

  it("시각이 있는 날짜는 그대로", () => {
    const withTime = { ...page, properties: { 일시: { type: "date", date: { start: "2026-09-08T14:00:00.000+09:00" } } } };
    expect(pageOccurredAt(withTime)).toEqual(new Date("2026-09-08T05:00:00.000Z"));
  });
});

describe("mentionedUserIds", () => {
  it("본문의 사람 언급 id를 중복 없이 모은다", () => {
    expect(mentionedUserIds('<mention-user url="user://a"/> <mention-user url="user://b"/> <mention-user url="user://a"/>')).toEqual(["a", "b"]);
  });
});
