import { z } from "zod";

import type { Person } from "@/lib/pipeline/identity";

import { storableText } from "../gmail/mime";

import { cleanPerson, mergeAttendees } from "./attendees";
import { GoogleApiError, googleErrorReason, type GoogleAccess } from "./token";
import { sameMeetingCode } from "./unverified";

// Google Calendar: 같은 회의 찾기 (G3 · G4, docs/go-live/google-integration.md 2-4).
// 일정은 저장하지 않고 필요할 때 조회한다. 고른 일정 하나의 제목 · 시각 · 참석자만 회의 원문에 붙는다 (일정 자체는 원문이 아니다).
// 순수 함수(usableEvents · pickMeetingEvent · eventPeople)와 fetch 한 겹(calendarClient)으로 나눴다.

const EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events";

/**
 * 받을 필드. **설명(description) · 첨부(attachments) · 위치(location) · 링크는 넣지 않는다** (처리방침 3장 "일정 설명과 첨부 파일은 읽지 않습니다").
 * 참석자는 이메일 · 이름 · 응답 상태만, 주최자는 "내가 주최했는가"(self)만, 화상 회의는 회의 코드와 종류만 받는다.
 * 주최자의 이메일 · 이름과 참석자의 주최자 표시(`organizer`)는 쓰지 않으므로 받지 않는다 (독립 검토 2026-09-30, 데이터 최소화).
 */
export const CALENDAR_EVENT_FIELDS =
  "items(id,status,eventType,summary,start,end,organizer(self),attendees(email,displayName,self,resource,responseStatus),conferenceData(conferenceId,conferenceSolution/key/type))";

/**
 * 참석한 회의의 회의 코드만 모을 때(G2 ②)의 필드: 제목 · 참석자 이메일 · 이름은 받지 않는다 (코드만 쓰고 저장하지 않는다, G3 데이터 최소화).
 * 거르기에 필요한 것(종류 · 취소 · 거절 · 종일 · 주최자 여부)과 회의 코드만.
 */
export const CALENDAR_CODE_FIELDS =
  "items(id,status,eventType,start,end,organizer(self),attendees(self,resource,responseStatus),conferenceData(conferenceId,conferenceSolution/key/type))";

const MAX_TITLE = 200;
const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;
/** Notion 회의록 (가): 페이지를 만든 시각이 일정 [시작 − 15분, 끝 + 15분] 안 */
const CREATED_MARGIN_MS = 15 * 60_000;
/** 제목 포함 비교에서 이보다 짧은 제목은 믿지 않는다 (한 글자 제목이 모든 제목에 들어 있다) */
const MIN_TITLE_MATCH = 2;
/** Meet 전사의 일정 조회 창: 전사 시작 앞뒤 */
const MEET_WINDOW_MS = 3 * HOUR_MS;

const personSchema = z.object({
  email: z.string().optional(),
  displayName: z.string().optional(),
  self: z.boolean().optional(),
  organizer: z.boolean().optional(),
  resource: z.boolean().optional(),
  responseStatus: z.string().optional(),
});
const timeSchema = z.object({ date: z.string().optional(), dateTime: z.string().optional() });
const eventSchema = z.object({
  id: z.string().min(1),
  status: z.string().optional(),
  eventType: z.string().optional(),
  summary: z.string().optional(),
  start: timeSchema.optional(),
  end: timeSchema.optional(),
  organizer: personSchema.optional(),
  attendees: z.array(personSchema).optional(),
  conferenceData: z
    .object({
      conferenceId: z.string().optional(),
      conferenceSolution: z.object({ key: z.object({ type: z.string().optional() }).optional() }).optional(),
    })
    .optional(),
});
const listSchema = z.object({ items: z.array(eventSchema).optional(), nextPageToken: z.string().optional() });

export type CalendarAttendee = { email?: string; name?: string; self: boolean; resource: boolean };

/** 거르기를 마친 일정 한 건 (시각이 있는 일정만) */
export type CalendarEvent = {
  id: string;
  title: string | null;
  start: Date;
  end: Date;
  /** 일정을 만든 사람이 캘린더 주인(사용자)인가: 사용자가 주최한 회의 */
  organizerSelf: boolean;
  attendees: CalendarAttendee[];
  /** Meet 회의 코드 (conferenceData.conferenceId), 화상 회의가 아니면 null */
  conferenceId: string | null;
  /** 화상 회의 종류 (Meet은 hangoutsMeet) */
  conferenceType: string | null;
};

/**
 * 일정 목록 응답 → 쓸 수 있는 일정. 거른다: 취소된 일정, eventType이 default가 아닌 것(집중 시간 · 부재 · 근무 위치 · 생일 · 메일에서 만든 일정),
 * 종일 일정(시각이 없다), 사용자가 거절한 일정(self 참석자의 responseStatus = declined). 회의실 등 자원은 참석자에서 뺀다.
 */
export function usableEvents(items: z.infer<typeof eventSchema>[]): CalendarEvent[] {
  const events: CalendarEvent[] = [];
  for (const item of items) {
    if (item.status === "cancelled") continue;
    if (item.eventType !== undefined && item.eventType !== "default") continue;
    const start = item.start?.dateTime ? new Date(item.start.dateTime) : null;
    const end = item.end?.dateTime ? new Date(item.end.dateTime) : null;
    if (!start || !end || Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) continue;
    const attendees = item.attendees ?? [];
    if (attendees.some((a) => a.self && a.responseStatus === "declined")) continue;
    events.push({
      id: item.id,
      title: item.summary?.trim() ? storableText(item.summary.trim().slice(0, MAX_TITLE)) : null,
      start,
      end,
      organizerSelf: item.organizer?.self === true,
      attendees: attendees
        .filter((a) => !a.resource)
        .map((a) => ({ ...(a.email ? { email: a.email } : {}), ...(a.displayName ? { name: a.displayName } : {}), self: a.self === true, resource: false })),
      conferenceId: item.conferenceData?.conferenceId ?? null,
      conferenceType: item.conferenceData?.conferenceSolution?.key?.type ?? null,
    });
  }
  return events;
}

export type CalendarRange = {
  timeMin: Date;
  timeMax: Date;
  maxResults: number;
  pageToken?: string;
  /** 받을 필드 (기본 CALENDAR_EVENT_FIELDS). 회의 코드만 모을 때는 CALENDAR_CODE_FIELDS */
  fields?: string;
};
export type CalendarClient = {
  /** 기본 캘린더의 일정 한 쪽 (반복 일정은 하나씩 펼친다, 시작 순) */
  list: (range: CalendarRange) => Promise<{ events: CalendarEvent[]; nextPageToken: string | null }>;
};

export function calendarClient(access: GoogleAccess): CalendarClient {
  return {
    list: async ({ timeMin, timeMax, maxResults, pageToken, fields = CALENDAR_EVENT_FIELDS }) => {
      const params = new URLSearchParams({
        timeMin: timeMin.toISOString(),
        timeMax: timeMax.toISOString(),
        singleEvents: "true",
        orderBy: "startTime",
        maxResults: String(maxResults),
        fields: `nextPageToken,${fields}`,
      });
      if (pageToken) params.set("pageToken", pageToken);
      const response = await access.get(`${EVENTS_URL}?${params.toString()}`);
      if (!response.ok) {
        const reason = await googleErrorReason(response);
        throw new GoogleApiError(`Calendar 요청 실패 (${response.status}${reason ? ` ${reason}` : ""})`, response.status, reason);
      }
      // 결과가 없으면 fields가 모든 필드를 걸러 빈 본문이 올 수 있다
      const body = response.status === 204 ? {} : await response.json().catch(() => null);
      const parsed = listSchema.safeParse(body);
      if (!parsed.success) throw new GoogleApiError("Calendar 응답 형식이 예상과 다릅니다", 502, "bad_response");
      return { events: usableEvents(parsed.data.items ?? []), nextPageToken: parsed.data.nextPageToken ?? null };
    },
  };
}

/**
 * 찾을 회의: Meet 전사는 회의 코드와 시작 시각, Notion 회의록은 회의 날짜(한국 날짜) · 페이지를 만든 시각 · 제목 ·
 * 만든 사람이 연결한 사용자인가(createdByUser: 페이지의 `created_by`가 사용자의 Notion id일 때만 true, 모르면 false)
 */
export type LookupTarget =
  | { kind: "meet"; meetingCode: string; start: Date }
  | { kind: "notion"; day: string; createdAt: Date; title: string | null; createdByUser: boolean };

export type MeetingPick = { result: "attached"; event: CalendarEvent } | { result: "ambiguous" } | { result: "none" };

/**
 * 사용자 말고 다른 참석자가 있는 일정인가: 혼자 잡은 작업 시간은 회의가 아니다.
 * 시각 · 제목으로 짐작해 잇는 Notion 회의록에만 적용한다. 회의 코드가 같은 Meet 전사는 같은 회의가 확실하므로 혼자인 일정이어도 잇는다
 * (사용자 결정 2026-09-30, google-integration.md 2-4).
 */
const hasOtherAttendees = (event: CalendarEvent) => event.attendees.some((a) => !a.self && !a.resource);

/** 공백 · 기호 · 대소문자를 뺀 제목 */
const titleKey = (title: string | null) => (title ?? "").toLowerCase().replace(/[\s\p{P}\p{S}]/gu, "");

/** 제목이 같거나 한쪽이 다른 쪽을 포함한다 (공백 · 기호 · 대소문자 무시) */
function titleMatches(eventTitle: string | null, pageTitle: string | null): boolean {
  const a = titleKey(eventTitle);
  const b = titleKey(pageTitle);
  if (a.length < MIN_TITLE_MATCH || b.length < MIN_TITLE_MATCH) return false;
  return a === b || a.includes(b) || b.includes(a);
}

/**
 * 같은 회의의 일정을 고른다 (순수 함수, G4: 애매하면 잇지 않는다).
 * - Meet 전사: 일정의 회의 코드가 같은 것. 같은 코드가 여럿(같은 회의 공간의 반복 일정)이면 시작 시각이 가장 가까운 하나, 같은 거리면 애매.
 *   코드로 이으므로 참석자가 사용자 한 명뿐인 일정도 잇는다.
 * - Notion 회의록: (가) 페이지를 만든 시각이 일정 [시작 − 15분, 끝 + 15분] 안, (나) 제목이 같거나 한쪽이 다른 쪽을 포함.
 *   (가)(나) 모두 맞는 일정 → (가)만 맞는 일정 → (나)만 맞는 일정 순으로 보고, 처음으로 비지 않은 단계에서 딱 하나면 그것, 둘 이상이면 애매.
 *   짐작으로 잇는 길이라 참석자가 사용자 한 명뿐인 일정(혼자 잡은 작업 시간)은 후보에서 뺀다.
 *   **(가)만 맞는 단계(제목은 안 맞고 시각만 맞음)는 페이지를 만든 사람이 연결한 사용자일 때만 쓴다** (독립 검토 2026-09-30):
 *   여러 사람이 함께 쓰는 회의록 DB에서 동료가 만든 회의록의 생성 시각이 마침 사용자의 다른 회의와 겹치면, 그 회의를 동료의 회의록에 붙여
 *   관련자가 틀리고 사용자가 "참석자"로 읽히는 문제(G4가 피하려는 것)가 생긴다. 제목이 맞는 단계는 만든 사람과 상관없이 그대로다.
 */
export function pickMeetingEvent(events: CalendarEvent[], target: LookupTarget): MeetingPick {
  if (target.kind === "meet") {
    const distance = (event: CalendarEvent) => Math.abs(event.start.getTime() - target.start.getTime());
    const same = events.filter((event) => sameMeetingCode(event.conferenceId ?? undefined, target.meetingCode)).sort((a, b) => distance(a) - distance(b));
    if (same.length === 0) return { result: "none" };
    if (same.length > 1 && distance(same[0]) === distance(same[1])) return { result: "ambiguous" };
    return { result: "attached", event: same[0] };
  }

  const candidates = events.filter(hasOtherAttendees);
  const created = target.createdAt.getTime();
  const timeMatches = (event: CalendarEvent) => created >= event.start.getTime() - CREATED_MARGIN_MS && created <= event.end.getTime() + CREATED_MARGIN_MS;
  const tiers = [
    candidates.filter((e) => timeMatches(e) && titleMatches(e.title, target.title)),
    target.createdByUser ? candidates.filter((e) => timeMatches(e) && !titleMatches(e.title, target.title)) : [],
    candidates.filter((e) => !timeMatches(e) && titleMatches(e.title, target.title)),
  ];
  for (const tier of tiers) {
    if (tier.length === 1) return { result: "attached", event: tier[0] };
    if (tier.length > 1) return { result: "ambiguous" };
  }
  return { result: "none" };
}

/** 회의 원문에 붙는 일정: 앱 근거 줄의 제목 · 시각과 관련자 */
export type MeetingEvent = {
  calendarEventId: string;
  title: string | null;
  /** ISO 시각 */
  start: string;
  end: string;
  /** 관련자: 사용자(프로필 이름 + 연결한 Google 주소)가 먼저, 다음이 일정 참석자 (회의실 등 자원 제외) */
  attendees: Person[];
};

export type MeetingLookup = { result: "attached"; event: MeetingEvent } | { result: "ambiguous" } | { result: "none" };

/** 원문 속 사용자: Taskforce 프로필 이름 + 연결한 Google 주소 (주소를 모르면 이름만) */
export type MeetingUser = { name: string; email: string | null };

/**
 * 일정의 참석자를 관련자로: 사용자는 일정의 self 참석자 대신 프로필 이름 + 연결한 주소로 한 번만 넣는다.
 * 일정에 사용자의 Google 이름(Daniel Song)이 그대로 들어가면 프로필 이름(송창훈)과 달라 "다른 사람"으로 읽히기 때문이다.
 */
export function eventPeople(event: CalendarEvent, me: MeetingUser): Person[] {
  const others = event.attendees.filter((a) => !a.self && !a.resource).map((a) => cleanPerson(a));
  return mergeAttendees([cleanPerson(me) ?? { name: me.name }], others.filter((p): p is Person => p !== null));
}

export function meetingEvent(event: CalendarEvent, me: MeetingUser): MeetingEvent {
  return { calendarEventId: event.id, title: event.title, start: event.start.toISOString(), end: event.end.toISOString(), attendees: eventPeople(event, me) };
}

/** 찾을 일정이 있을 수 있는 시간 창. Notion은 그 한국 날짜 하루 (날짜만 있는 속성은 0시로 읽히므로 앞뒤 몇 시간으로는 놓친다), Meet은 전사 시작 앞뒤 3시간 */
export function lookupWindow(target: LookupTarget): { timeMin: Date; timeMax: Date } {
  if (target.kind === "meet") return { timeMin: new Date(target.start.getTime() - MEET_WINDOW_MS), timeMax: new Date(target.start.getTime() + MEET_WINDOW_MS) };
  const dayStart = new Date(`${target.day}T00:00:00+09:00`);
  return { timeMin: dayStart, timeMax: new Date(dayStart.getTime() + DAY_MS) };
}

/**
 * 같은 회의의 일정을 조회한다: 창 안의 일정을 한 쪽(50건) 읽고 pickMeetingEvent로 고른다. 조회가 실패하면 던진다 (부르는 쪽이 정한다:
 * Notion은 그 동기화에서 남은 페이지를 붙이지 않고, Meet 전사는 일정 없이 넣는다).
 */
export async function lookupMeetingEvent(client: CalendarClient, target: LookupTarget, me: MeetingUser): Promise<MeetingLookup> {
  const { timeMin, timeMax } = lookupWindow(target);
  const { events } = await client.list({ timeMin, timeMax, maxResults: 50 });
  const pick = pickMeetingEvent(events, target);
  return pick.result === "attached" ? { result: "attached", event: meetingEvent(pick.event, me) } : { result: pick.result };
}
