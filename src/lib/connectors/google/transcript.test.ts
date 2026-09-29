import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { MAX_SOURCE_TEXT } from "@/lib/api/contract";

import type { MeetingEvent } from "./calendar";
import type { ConferenceRecord, MeetParticipant, Transcript, TranscriptEntry } from "./meet";
import { kstMinute, participantLabels, transcriptToItem, type TranscriptInput } from "./transcript";

// Meet 전사 → 원문 (docs/go-live/google-integration.md 2-5). 본문 형식은 골든셋(evals/golden/*meet*.json)과 글자까지 같다.

const ME_SUB = "1000000000000000001";
const ME = { name: "Alex Kim", email: "alex@lumenfield.example", sub: ME_SUB };

const record: ConferenceRecord = {
  name: "conferenceRecords/c1",
  startTime: new Date("2026-09-30T01:00:00Z"),
  endTime: new Date("2026-09-30T02:00:00Z"),
  space: "spaces/s1",
};
const transcript: Transcript = {
  name: "conferenceRecords/c1/transcripts/t1",
  state: "FILE_GENERATED",
  startTime: new Date("2026-09-30T01:00:05Z"),
  endTime: new Date("2026-09-30T01:58:00Z"),
  documentId: "1kuceFZohVoCh6FulBHxwy6I15Ogpc4hP",
};

const pName = (n: number) => `conferenceRecords/c1/participants/p${n}`;
const signedin = (n: number, displayName: string, user = `users/${n}`): MeetParticipant => ({ name: pName(n), kind: "signedin", user, displayName });
const entry = (n: number, text: string, second = n): TranscriptEntry => ({ participant: pName(n), text, startTime: new Date(Date.UTC(2026, 8, 30, 1, 0, second)) });

function input(overrides: Partial<TranscriptInput> = {}): TranscriptInput {
  return { record, transcript, entries: [], participants: [], event: null, me: ME, ...overrides };
}

type GoldenSource = { id: string; text: string; participants?: { attendees?: { name?: string; email?: string }[] } };
type Golden = { user: { name: string; emails: string[] }; sources: GoldenSource[] };

const golden = (file: string): Golden => JSON.parse(readFileSync(join(process.cwd(), "evals/golden", `${file}.json`), "utf8")) as Golden;

/** 골든셋 전사 원문을 API 모양(전사 항목 · 참가자 · 일정)으로 되돌린다. 사용자의 Meet 표시 이름은 프로필 이름과 다르게 둔다 */
function reconstruct(file: string, sourceId: string) {
  const data = golden(file);
  const source = data.sources.find((s) => s.id === sourceId)!;
  const [header, ...body] = source.text.split("\n");
  const title = header.match(/^\[Google Meet · (.*)\]$/)![1];
  const lines = body.map((line) => {
    const cut = line.indexOf(": ");
    return { speaker: line.slice(0, cut), text: line.slice(cut + 2) };
  });
  const attendees = source.participants!.attendees!;
  const names = [...new Set([...attendees.map((a) => a.name!), ...lines.map((l) => l.speaker)])];
  const participants = names.map((name, i) => (name === data.user.name ? signedin(i + 1, "Daniel Song (Meet 표시 이름)", `users/${ME_SUB}`) : signedin(i + 1, name)));
  const numberOf = (name: string) => names.indexOf(name) + 1;
  let second = 0;
  // 한 줄을 두 항목으로 쪼갠다: 같은 화자의 이어진 항목은 한 줄로 합쳐져야 한다
  const entries = lines.flatMap(({ speaker, text }) => {
    const words = text.split(" ");
    const cut = Math.ceil(words.length / 2);
    const parts = words.length > 1 ? [words.slice(0, cut).join(" "), words.slice(cut).join(" ")] : [text];
    return parts.map((part) => entry(numberOf(speaker), part, second++));
  });
  const event: MeetingEvent = { calendarEventId: "evt-1", title, start: "2026-09-30T01:00:00.000Z", end: "2026-09-30T02:00:00.000Z", attendees };
  return { data, source, entries, participants, event };
}

const MEET_GOLDEN: [string, string][] = [
  ["meet-speaker-commit", "meet-0930"],
  ["meet-korean-transcript", "meet-1014"],
  ["meet-long-transcript", "meet-1012"],
  ["seq-meet-after-notion", "meet-0930"],
  ["seq-notion-after-meet", "meet-0930"],
  ["seq-meet-others-item", "meet-1006"],
  ["seq-meet-then-email-extension", "meet-1012k"],
];

describe("transcriptToItem: 골든셋 파일과 글자까지 같다", () => {
  it.each(MEET_GOLDEN)("%s의 %s: 본문(머리줄 · 이름표 · 이어진 항목 합치기)과 관련자(사용자가 한 번, 먼저)", (file, sourceId) => {
    const { data, source, entries, participants, event } = reconstruct(file, sourceId);
    const item = transcriptToItem(input({ entries, participants, event, me: { name: data.user.name, email: data.user.emails[0], sub: ME_SUB } }));
    expect(item).not.toBeNull();
    expect(item!.text).toBe(source.text);
    expect(item!.participants).toEqual({ attendees: source.participants!.attendees });
    expect(item).toMatchObject({ kind: "meeting", externalVersion: "1", writtenByMe: null });
  });
});

describe("transcriptToItem: 원문 필드", () => {
  const base = () =>
    input({
      entries: [entry(2, "Could you revise the pricing section?"), entry(1, "Sure.", 10), entry(1, "I'll send it by Friday.", 20)],
      participants: [signedin(1, "Daniel Song", `users/${ME_SUB}`), signedin(2, "Jordan Lee")],
      event: {
        calendarEventId: "evt-9",
        title: "Proposal review — Acme",
        start: "2026-09-30T01:00:00.000Z",
        end: "2026-09-30T02:00:00.000Z",
        attendees: [{ name: "Alex Kim", email: "alex@lumenfield.example" }, { name: "Jordan Lee", email: "jordan@harborline.example" }],
      },
    });

  it("외부 id는 전사 리소스 이름, 시각은 전사 시작 · 끝, 링크는 전사 문서, 일정은 meeting으로", () => {
    expect(transcriptToItem(base())).toEqual({
      externalId: "conferenceRecords/c1/transcripts/t1",
      externalVersion: "1",
      kind: "meeting",
      title: "Proposal review — Acme",
      text: "[Google Meet · Proposal review — Acme]\nJordan Lee: Could you revise the pricing section?\nAlex Kim: Sure. I'll send it by Friday.",
      occurredAt: new Date("2026-09-30T01:00:05Z"),
      lastEditedAt: new Date("2026-09-30T01:58:00Z"),
      externalUrl: "https://docs.google.com/document/d/1kuceFZohVoCh6FulBHxwy6I15Ogpc4hP/view",
      participants: { attendees: [{ name: "Alex Kim", email: "alex@lumenfield.example" }, { name: "Jordan Lee", email: "jordan@harborline.example" }] },
      writtenByMe: null,
      meeting: { calendar_event_id: "evt-9", title: "Proposal review — Acme", start: "2026-09-30T01:00:00.000Z", end: "2026-09-30T02:00:00.000Z" },
    });
  });

  it("일정이 없으면 제목은 Google Meet · 한국 시간, meeting 없음, 관련자는 사용자 + Meet 참가자 이름", () => {
    const item = transcriptToItem({ ...base(), event: null })!;
    expect(item.title).toBe("Google Meet · 2026-09-30 10:00");
    expect(item.text.split("\n")[0]).toBe("[Google Meet · 2026-09-30 10:00]");
    expect(item.participants).toEqual({ attendees: [{ name: "Alex Kim", email: "alex@lumenfield.example" }, { name: "Jordan Lee" }] });
    expect("meeting" in item).toBe(false);
  });

  it("전사 문서 id가 Google 문서 id 모양이 아니면 링크를 남기지 않는다", () => {
    expect(transcriptToItem({ ...base(), transcript: { ...transcript, documentId: "../../evil?x=1" } })!.externalUrl).toBeNull();
    expect(transcriptToItem({ ...base(), transcript: { ...transcript, documentId: null } })!.externalUrl).toBeNull();
  });

  it("전사 시각이 없으면 회의 기록의 시각을 쓴다", () => {
    const item = transcriptToItem({ ...base(), transcript: { ...transcript, startTime: null, endTime: null } })!;
    expect(item.occurredAt).toEqual(record.startTime);
    expect(item.lastEditedAt).toEqual(record.endTime);
  });

  it("일정 제목의 ] · 줄바꿈은 머리줄이 깨지지 않게 뺀다", () => {
    const item = transcriptToItem({ ...base(), event: { ...base().event!, title: "Q4 [kickoff]\nweekly" } })!;
    expect(item.text.split("\n")[0]).toBe("[Google Meet · Q4 [kickoff weekly]");
  });

  it("전사 항목이 없거나 글이 모두 비었으면 null", () => {
    expect(transcriptToItem(input({ participants: [signedin(1, "Daniel Song", `users/${ME_SUB}`)] }))).toBeNull();
    expect(transcriptToItem(input({ entries: [entry(1, "   \n ")], participants: [signedin(1, "Daniel Song", `users/${ME_SUB}`)] }))).toBeNull();
  });

  it("원문 한도(20만 자)에서 자른다", () => {
    const item = transcriptToItem(input({ entries: [entry(1, "가".repeat(MAX_SOURCE_TEXT + 500))], participants: [signedin(1, "Daniel Song", `users/${ME_SUB}`)] }))!;
    expect(item.text.length).toBeLessThanOrEqual(MAX_SOURCE_TEXT);
  });
});

describe("transcriptToItem: 이름표", () => {
  it("사용자 줄은 Meet 표시 이름이 아니라 프로필 이름이다 (G5: 로그인 참가자의 users/{id}가 연결한 계정의 sub)", () => {
    const item = transcriptToItem(
      input({
        entries: [entry(1, "제가 정리해서 공유드릴게요.")],
        participants: [signedin(1, "Daniel Song", `users/${ME_SUB}`)],
        me: { ...ME, name: "송창훈" },
      }),
    )!;
    expect(item.text).toBe("[Google Meet · 2026-09-30 10:00]\n송창훈: 제가 정리해서 공유드릴게요.");
    expect(item.participants).toEqual({ attendees: [{ name: "송창훈", email: "alex@lumenfield.example" }] });
  });

  it("다른 로그인 참가자 · 익명 참가자는 표시 이름, 전화 참가자는 표시 이름(없으면 '전화 참가자')", () => {
    const participants: MeetParticipant[] = [
      signedin(1, "Daniel Song", `users/${ME_SUB}`),
      signedin(2, "Jordan Lee"),
      { name: pName(3), kind: "anonymous", user: null, displayName: "Guest" },
      { name: pName(4), kind: "phone", user: null, displayName: "+82 10-****-1234" },
      { name: pName(5), kind: "phone", user: null, displayName: null },
      { name: pName(6), kind: "anonymous", user: null, displayName: null },
    ];
    const labels = participantLabels(participants, ME);
    expect([...labels.values()].map((l) => l.label)).toEqual(["Alex Kim", "Jordan Lee", "Guest", "+82 10-****-1234", "전화 참가자", "참가자"]);
    expect(labels.get(pName(1))?.isMe).toBe(true);
    expect(labels.get(pName(2))?.isMe).toBe(false);
  });

  it("같은 로그인 사용자가 기기 둘로 들어와도 한 사람이다: 이름표가 같고 이어진 항목이 한 줄로 합쳐진다", () => {
    const participants = [signedin(1, "Jordan Lee", "users/222"), signedin(2, "Jordan Lee", "users/222"), signedin(3, "Daniel Song", `users/${ME_SUB}`)];
    const labels = participantLabels(participants, ME);
    expect(labels.get(pName(1))?.label).toBe("Jordan Lee");
    expect(labels.get(pName(2))?.label).toBe("Jordan Lee");
    const item = transcriptToItem(input({ participants, entries: [entry(1, "첫째."), entry(2, "둘째."), entry(3, "셋째.")] }))!;
    expect(item.text).toBe("[Google Meet · 2026-09-30 10:00]\nJordan Lee: 첫째. 둘째.\nAlex Kim: 셋째.");
  });

  it("표시 이름이 사용자 이름과 같은 다른 사람은 (2)를 붙인다: 다른 사람의 약속이 사용자의 것으로 읽히지 않게", () => {
    const participants = [signedin(1, "Daniel Song", `users/${ME_SUB}`), signedin(2, "Alex Kim", "users/222"), signedin(3, "alex  kim", "users/333")];
    const labels = participantLabels(participants, ME);
    expect(labels.get(pName(1))).toMatchObject({ label: "Alex Kim", isMe: true });
    expect(labels.get(pName(2))).toMatchObject({ label: "Alex Kim (2)", isMe: false });
    expect(labels.get(pName(3))).toMatchObject({ label: "alex kim (3)", isMe: false });
    const item = transcriptToItem(input({ participants, entries: [entry(2, "I'll send the deck.")] }))!;
    expect(item.text.split("\n")[1]).toBe("Alex Kim (2): I'll send the deck.");
  });

  it("사용자를 찾았으면 별칭 · 세 글자 한글 이름의 성을 뺀 부분도 사용자의 이름표로 보고, 다른 사람이 쓰면 (2)를 붙인다 (이름 · 별칭으로 사용자를 알아보므로)", () => {
    const me = { ...ME, name: "송창훈", aliases: ["Daniel Song"] };
    const participants = [signedin(1, "Chang-hoon Song", `users/${ME_SUB}`), signedin(2, "Daniel Song", "users/222"), signedin(3, "창훈", "users/333"), signedin(4, "Sam", "users/444")];
    const labels = participantLabels(participants, me);
    expect(labels.get(pName(1))).toMatchObject({ label: "송창훈", isMe: true });
    expect(labels.get(pName(2))).toMatchObject({ label: "Daniel Song (2)", isMe: false });
    expect(labels.get(pName(3))).toMatchObject({ label: "창훈 (2)", isMe: false });
    expect(labels.get(pName(4))).toMatchObject({ label: "Sam", isMe: false });
  });

  it("사용자를 참가자에서 못 찾았으면(G5 가정이 틀림) 별칭은 막지 않는다: 사용자 본인의 줄이 (2)로 바뀌지 않게", () => {
    const me = { ...ME, name: "송창훈", aliases: ["Daniel Song"] };
    const labels = participantLabels([signedin(1, "Daniel Song", "users/not-the-sub")], me);
    expect(labels.get(pName(1))).toMatchObject({ label: "Daniel Song", isMe: false });
  });

  it("같은 이름이 열 명이 넘어도 (2)…(11) 이름표가 30자 안에 든다 (이름표 읽기는 30자까지만 이름표로 본다)", () => {
    const long = "가".repeat(30);
    const participants = Array.from({ length: 12 }, (_, i) => signedin(i + 1, long, `users/${100 + i}`));
    const labels = [...participantLabels(participants, ME).values()].map((l) => l.label);
    expect(new Set(labels).size).toBe(12);
    expect(labels.every((label) => label.length <= 30)).toBe(true);
    expect(labels[11]).toMatch(/\(12\)$/);
  });

  it("이름표를 깨는 글자(: [ ] 줄바꿈)는 빼고 30자로 자른다", () => {
    const participants = [signedin(1, "Daniel Song", `users/${ME_SUB}`), signedin(2, "Lee: [PM]\nTeam"), signedin(3, "가".repeat(50))];
    const labels = participantLabels(participants, ME);
    expect(labels.get(pName(2))?.label).toBe("Lee PM Team");
    expect(labels.get(pName(3))?.label).toBe("가".repeat(30));
  });

  it("참가자 목록에 없는 화자는 '참가자'로 적는다", () => {
    const item = transcriptToItem(input({ participants: [signedin(1, "Daniel Song", `users/${ME_SUB}`)], entries: [entry(9, "Hello there everyone.")] }))!;
    expect(item.text.split("\n")[1]).toBe("참가자: Hello there everyone.");
  });

  it("G5 가정이 틀리면(참가자 id가 sub와 다르면) 사용자를 못 알아본다: 이름표는 Meet 표시 이름 그대로", () => {
    const item = transcriptToItem(input({ participants: [signedin(1, "Daniel Song", "users/other-id")], entries: [entry(1, "I'll send the deck by Friday.")] }))!;
    expect(item.text.split("\n")[1]).toBe("Daniel Song: I'll send the deck by Friday.");
    // 사용자는 그래도 관련자에 한 번 들어간다
    expect(item.participants!.attendees![0]).toEqual({ name: "Alex Kim", email: "alex@lumenfield.example" });
  });
});

describe("kstMinute", () => {
  it("한국 시간 분 단위", () => {
    expect(kstMinute(new Date("2026-10-05T01:00:00Z"))).toBe("2026-10-05 10:00");
    expect(kstMinute(new Date("2026-10-05T15:30:59Z"))).toBe("2026-10-06 00:30");
  });
});
