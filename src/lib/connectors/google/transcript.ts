import { MAX_SOURCE_TEXT } from "@/lib/api/contract";
import { userNameForms, type Person } from "@/lib/pipeline/identity";

import { storableText } from "../gmail/mime";
import type { IngestItem } from "../types";

import { cleanPerson, mergeAttendees } from "./attendees";
import type { MeetingEvent, MeetingUser } from "./calendar";
import type { ConferenceRecord, MeetParticipant, Transcript, TranscriptEntry } from "./meet";
import { isConnectedAccount } from "./unverified";

// Meet 전사 → 원문 (docs/go-live/google-integration.md 2-5, 순수 함수). 본문 형식은 골든셋(evals/golden/meet-*.json)과 글자까지 같다:
//   [Google Meet · 일정 제목]
//   이름: 글
// - 사용자 줄은 Meet 표시 이름이 아니라 Taskforce 프로필 이름으로 쓴다 (Slack과 같은 규칙: identity.ts가 이름으로 알아본다).
// - 같은 화자의 이어진 전사 항목은 한 줄로 합친다. 시각(타임스탬프)은 넣지 않는다 (추출 프롬프트 · 전사 골든셋이 시각 없는 모양을 전제한다).

const UNKNOWN_PARTICIPANT = "참가자";
const PHONE_PARTICIPANT = "전화 참가자";
const MAX_TITLE = 200;
/** 화자 이름표 한도: 이보다 길면 identity.ts의 이름표 읽기(quoteSpeaker)가 이름표로 보지 않는다 */
const MAX_LABEL = 30;
const KST_OFFSET_MS = 9 * 3_600_000;

/** `2026-10-05 10:00` (한국 시간) */
export function kstMinute(date: Date): string {
  return new Date(date.getTime() + KST_OFFSET_MS).toISOString().slice(0, 16).replace("T", " ");
}

/** 이름표에서 이름표 읽기를 깨는 글자(: [ ] 줄바꿈)를 빼고 30자로 자른다 */
function speakerLabel(name: string): string {
  return storableText(name.replace(/[:[\]\r\n]+/g, " ").replace(/\s+/g, " ").trim().slice(0, MAX_LABEL)).trim();
}

/** 사용자: 프로필 이름 · 별칭 · 연결한 Google 주소 · 연결한 계정의 sub (Meet 참가자 알아보기, G5) */
export type TranscriptUser = MeetingUser & { sub: string | null; aliases?: string[] };

export type TranscriptInput = {
  record: ConferenceRecord;
  transcript: Transcript;
  entries: TranscriptEntry[];
  participants: MeetParticipant[];
  /** 같은 회의의 Calendar 일정 (못 찾았으면 null) */
  event: MeetingEvent | null;
  me: TranscriptUser;
};

type Speaker = { label: string; isMe: boolean; /** 같은 사람(여러 기기로 들어온 같은 로그인 사용자)이면 같은 값 */ person: string };

/**
 * 참가자 이름표 (participant 리소스 이름 → 이름표): 사용자는 프로필 이름, 그 밖의 로그인 · 익명 참가자는 표시 이름, 전화 참가자는 표시 이름(없으면 "전화 참가자").
 * 같은 로그인 사용자가 기기 둘로 들어와 참가자가 둘이어도 한 사람이다(같은 이름표).
 * 서로 다른 사람의 이름표가 같으면(같은 이름 · 사용자와 같은 표시 이름) 뒤 사람에게 (2)를 붙인다: 이름으로 사용자를 알아보므로,
 * 표시 이름이 사용자 이름과 같은 다른 사람의 약속이 사용자의 것으로 읽히지 않게. 사용자를 참가자에서 찾았으면(G5) 사용자의 별칭 ·
 * 세 글자 한글 이름의 성을 뺀 부분(identity.ts `userNameForms`)도 사용자의 이름표로 보고 다른 사람이 쓰면 (2)를 붙인다.
 * 사용자를 못 찾았으면 별칭은 막지 않는다: 사용자 본인의 줄이 (2)로 바뀔 수 있다.
 */
export function participantLabels(participants: MeetParticipant[], me: TranscriptInput["me"]): Map<string, Speaker> {
  const personOf = (p: MeetParticipant) => (p.kind === "signedin" && p.user ? p.user : p.name);
  const byPerson = new Map<string, { label: string; isMe: boolean }>();
  const used = new Set<string>();
  const key = (label: string) => label.replace(/\s+/g, "").toLowerCase();
  const claim = (label: string) => {
    let candidate = label;
    // " (99)"까지 30자 안에 들어오게 (넘으면 이름표 읽기가 이름표로 보지 않는다)
    for (let n = 2; used.has(key(candidate)); n++) candidate = `${label.slice(0, MAX_LABEL - 6).trim()} (${n})`;
    used.add(key(candidate));
    return candidate;
  };

  // 사용자를 먼저 정해 프로필 이름을 그대로 쓴다
  const myLabel = speakerLabel(me.name) || UNKNOWN_PARTICIPANT;
  for (const p of participants) {
    if (p.kind === "signedin" && isConnectedAccount(p.user ?? undefined, me.sub) && !byPerson.has(personOf(p))) {
      byPerson.set(personOf(p), { label: claim(myLabel), isMe: true });
    }
  }
  if (byPerson.size > 0) {
    for (const form of userNameForms({ name: me.name, aliases: me.aliases ?? [], emails: [] })) used.add(form);
  }
  for (const p of participants) {
    if (byPerson.has(personOf(p))) continue;
    const shown = speakerLabel(p.displayName ?? "") || (p.kind === "phone" ? PHONE_PARTICIPANT : UNKNOWN_PARTICIPANT);
    byPerson.set(personOf(p), { label: claim(shown), isMe: false });
  }
  return new Map(participants.map((p) => [p.name, { ...byPerson.get(personOf(p))!, person: personOf(p) }]));
}

/** 전사 → 원문. 전사 항목이 없으면 null */
export function transcriptToItem(input: TranscriptInput): IngestItem | null {
  const { record, transcript, entries, participants, event, me } = input;
  const labels = participantLabels(participants, me);

  // 같은 화자의 이어진 항목을 한 줄로
  const lines: { speaker: string; texts: string[]; person: string | null }[] = [];
  for (const entry of entries) {
    const text = entry.text.replace(/\s+/g, " ").trim();
    if (!text) continue;
    const known = entry.participant ? labels.get(entry.participant) : undefined;
    // 참가자 목록에 없는 항목의 화자는 참가자 리소스 이름으로 가른다
    const person = known?.person ?? entry.participant;
    const last = lines[lines.length - 1];
    if (last && last.person === person) {
      last.texts.push(text);
      continue;
    }
    lines.push({ speaker: known?.label ?? UNKNOWN_PARTICIPANT, texts: [text], person });
  }
  if (lines.length === 0) return null;

  const startedAt = transcript.startTime ?? record.startTime;
  const endedAt = transcript.endTime ?? record.endTime;
  // 제목: 일정 제목, 없으면 "Google Meet · 2026-10-05 10:00". 머리줄의 [ ]가 깨지지 않게 ] · 줄바꿈은 뺀다
  const eventTitle = event?.title?.replace(/[\]\r\n]+/g, " ").replace(/\s+/g, " ").trim() || null;
  const heading = eventTitle ?? kstMinute(startedAt);
  const body = [`[Google Meet · ${heading}]`, ...lines.map((line) => `${line.speaker}: ${line.texts.join(" ")}`)].join("\n");

  // 관련자: 사용자(프로필 이름 + 연결한 주소)가 한 번, 일정 참석자, Meet 참가자(이름이 같으면 합침)
  const meetPeople: Person[] = [];
  for (const p of participants) {
    const known = labels.get(p.name);
    if (!known || known.isMe) continue;
    const person = cleanPerson({ name: known.label });
    if (person) meetPeople.push(person);
  }
  const attendees = mergeAttendees(event?.attendees ?? [cleanPerson(me) ?? { name: me.name }], meetPeople);

  return {
    // 전사 리소스 이름이 외부 id다: conferenceRecords/{c}/transcripts/{t}. 전사 항목은 생성 뒤 바뀌지 않는다
    externalId: transcript.name,
    externalVersion: "1",
    kind: "meeting",
    title: (eventTitle ?? `Google Meet · ${kstMinute(startedAt)}`).slice(0, MAX_TITLE),
    text: storableText(body.slice(0, MAX_SOURCE_TEXT)),
    occurredAt: startedAt,
    lastEditedAt: endedAt,
    externalUrl: transcriptUrl(transcript.documentId),
    participants: { attendees },
    // 전사에는 여러 사람의 말이 담긴다: "직접 쓴 문서"가 아니다
    writtenByMe: null,
    ...(event ? { meeting: { calendar_event_id: event.calendarEventId, title: event.title, start: event.start, end: event.end } } : {}),
  };
}

/** 전사 문서 링크 (주최자의 Drive 문서): 문서 id가 Google 문서 id 모양일 때만 */
function transcriptUrl(documentId: string | null): string | null {
  return documentId && /^[A-Za-z0-9_-]{10,200}$/.test(documentId) ? `https://docs.google.com/document/d/${documentId}/view` : null;
}
