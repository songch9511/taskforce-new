import { describe, expect, it, vi } from "vitest";

import { CALENDAR_CODE_FIELDS, CALENDAR_EVENT_FIELDS, calendarClient, eventPeople, lookupMeetingEvent, lookupWindow, pickMeetingEvent, usableEvents, type CalendarEvent } from "./calendar";
import type { GoogleAccess } from "./token";

// Calendar 조회 · 같은 회의 고르기 (G3 · G4, docs/go-live/google-integration.md 2-4).

const ME = { name: "Alex Kim", email: "alex@lumenfield.example" };

type RawEvent = Parameters<typeof usableEvents>[0][number];

/** Calendar API 응답 한 건 (시각이 있는 일정, 사용자 + 상대) */
function raw(id: string, extra: Partial<RawEvent> = {}): RawEvent {
  return {
    id,
    status: "confirmed",
    eventType: "default",
    summary: `회의 ${id}`,
    start: { dateTime: "2026-09-30T10:00:00+09:00" },
    end: { dateTime: "2026-09-30T11:00:00+09:00" },
    organizer: { email: "jordan@harborline.example", displayName: "Jordan Lee" },
    attendees: [
      { email: "alex@lumenfield.example", displayName: "Alex Song", self: true, responseStatus: "accepted" },
      { email: "jordan@harborline.example", displayName: "Jordan Lee", organizer: true, responseStatus: "accepted" },
    ],
    ...extra,
  };
}

const event = (id: string, extra: Partial<RawEvent> = {}): CalendarEvent => {
  const [parsed] = usableEvents([raw(id, extra)]);
  if (!parsed) throw new Error(`usableEvents가 ${id}를 버렸습니다`);
  return parsed;
};

describe("usableEvents: 일정 거르기", () => {
  it("취소된 일정 · eventType이 default가 아닌 것 · 종일 일정 · 사용자가 거절한 일정을 버린다", () => {
    const events = usableEvents([
      raw("ok"),
      raw("cancelled", { status: "cancelled" }),
      raw("focus", { eventType: "focusTime" }),
      raw("ooo", { eventType: "outOfOffice" }),
      raw("workloc", { eventType: "workingLocation" }),
      raw("birthday", { eventType: "birthday" }),
      raw("gmail", { eventType: "fromGmail" }),
      raw("allday", { start: { date: "2026-09-30" }, end: { date: "2026-10-01" } }),
      raw("declined", { attendees: [{ email: "alex@lumenfield.example", self: true, responseStatus: "declined" }, { email: "jordan@harborline.example" }] }),
      raw("no-type", { eventType: undefined }),
    ]);
    expect(events.map((e) => e.id)).toEqual(["ok", "no-type"]);
  });

  it("회의실 등 자원은 참석자에서 빼고, 이메일 없는 참석자는 이름으로 남긴다", () => {
    const [parsed] = usableEvents([
      raw("room", {
        attendees: [
          { email: "alex@lumenfield.example", self: true },
          { email: "room-3f@resource.calendar.google.com", displayName: "3F Room", resource: true },
          { displayName: "손님" },
        ],
      }),
    ]);
    expect(parsed.attendees).toEqual([
      { email: "alex@lumenfield.example", self: true, resource: false },
      { name: "손님", self: false, resource: false },
    ]);
  });

  it("주최자가 캘린더 주인이면 organizerSelf, Meet 회의 코드 · 종류를 읽는다", () => {
    const hosted = event("hosted", { organizer: { email: "alex@lumenfield.example", self: true }, conferenceData: { conferenceId: "abc-defg-hij", conferenceSolution: { key: { type: "hangoutsMeet" } } } });
    expect(hosted).toMatchObject({ organizerSelf: true, conferenceId: "abc-defg-hij", conferenceType: "hangoutsMeet" });
    expect(event("plain")).toMatchObject({ organizerSelf: false, conferenceId: null, conferenceType: null });
  });

  it("제목이 없으면 null, 200자로 자른다", () => {
    expect(event("untitled", { summary: undefined }).title).toBeNull();
    expect(event("long", { summary: "가".repeat(300) }).title).toHaveLength(200);
  });
});

describe("calendarClient: 요청", () => {
  function fakeAccess(body: unknown = { items: [raw("e1")] }, status = 200) {
    const urls: string[] = [];
    const access: GoogleAccess = {
      get: vi.fn(async (url: string) => {
        urls.push(url);
        return new Response(status === 204 ? null : JSON.stringify(body), { status });
      }),
    };
    return { access, urls };
  }

  it("설명 · 첨부 · 위치는 fields에 없다 (처리방침 3장)", async () => {
    const { access, urls } = fakeAccess();
    await calendarClient(access).list({ timeMin: new Date("2026-09-29T15:00:00Z"), timeMax: new Date("2026-09-30T15:00:00Z"), maxResults: 50 });
    const url = new URL(urls[0]);
    const fields = url.searchParams.get("fields") ?? "";
    for (const forbidden of ["description", "attachments", "location", "htmlLink", "hangoutLink", "entryPoints", "extendedProperties", "creator", "recurrence", "reminders"]) {
      expect(fields, forbidden).not.toContain(forbidden);
      expect(CALENDAR_EVENT_FIELDS, forbidden).not.toContain(forbidden);
    }
    // 쓰지 않는 값은 받지 않는다: 주최자는 self만(이메일 · 이름 없음), 참석자의 주최자 표시 없음 (독립 검토 2026-09-30)
    expect(CALENDAR_EVENT_FIELDS).toContain("organizer(self)");
    expect(CALENDAR_EVENT_FIELDS).not.toContain("organizer(email");
    expect(CALENDAR_EVENT_FIELDS).not.toMatch(/attendees\([^)]*organizer/);
    // 받는 것은 계획 2-4의 목록에서 위 두 가지를 뺀 것이다
    expect(CALENDAR_EVENT_FIELDS).toBe(
      "items(id,status,eventType,summary,start,end,organizer(self),attendees(email,displayName,self,resource,responseStatus),conferenceData(conferenceId,conferenceSolution/key/type))",
    );
    expect(fields).toBe(`nextPageToken,${CALENDAR_EVENT_FIELDS}`);
  });

  it("참석한 회의의 회의 코드만 모을 때는 제목 · 참석자 이메일 · 이름도 받지 않는다 (CALENDAR_CODE_FIELDS)", async () => {
    const { access, urls } = fakeAccess();
    await calendarClient(access).list({ timeMin: new Date(0), timeMax: new Date(1), maxResults: 250, fields: CALENDAR_CODE_FIELDS });
    const fields = new URL(urls[0]).searchParams.get("fields") ?? "";
    expect(fields).toBe(`nextPageToken,${CALENDAR_CODE_FIELDS}`);
    for (const forbidden of ["summary", "email", "displayName", "description", "attachments", "location", "htmlLink", "hangoutLink", "entryPoints", "creator"]) {
      expect(fields, forbidden).not.toContain(forbidden);
    }
    // 거르기와 회의 코드에 필요한 것은 그대로 있다
    for (const needed of ["status", "eventType", "start", "end", "organizer(self)", "attendees(self,resource,responseStatus)", "conferenceId", "conferenceSolution/key/type"]) {
      expect(fields, needed).toContain(needed);
    }
  });

  it("Postgres가 받지 않는 글자(NUL)는 일정 제목 · 참석자 이름에서 뺀다", () => {
    const [parsed] = usableEvents([raw("nul", { summary: "주간\u0000 회의", attendees: [{ email: "a@b.dev", displayName: "Jo\u0000rdan", self: false }, { email: "me@b.dev", self: true }] })]);
    expect(parsed.title).toBe("주간 회의");
    expect(eventPeople(parsed, ME)[1]).toEqual({ name: "Jordan", email: "a@b.dev" });
  });

  it("기본 캘린더의 일정을 시작 순으로 하나씩 펼쳐 받는다", async () => {
    const { access, urls } = fakeAccess();
    await calendarClient(access).list({ timeMin: new Date("2026-09-29T15:00:00Z"), timeMax: new Date("2026-09-30T15:00:00Z"), maxResults: 50, pageToken: "next-1" });
    const url = new URL(urls[0]);
    expect(url.origin + url.pathname).toBe("https://www.googleapis.com/calendar/v3/calendars/primary/events");
    expect(Object.fromEntries(url.searchParams)).toMatchObject({
      timeMin: "2026-09-29T15:00:00.000Z",
      timeMax: "2026-09-30T15:00:00.000Z",
      singleEvents: "true",
      orderBy: "startTime",
      maxResults: "50",
      pageToken: "next-1",
    });
  });

  it("일정 목록을 거른 결과로 돌려주고, 빈 응답(204)은 빈 목록이다", async () => {
    const { access } = fakeAccess({ items: [raw("a"), raw("b", { status: "cancelled" })], nextPageToken: "p2" });
    const page = await calendarClient(access).list({ timeMin: new Date(0), timeMax: new Date(1), maxResults: 50 });
    expect(page.events.map((e) => e.id)).toEqual(["a"]);
    expect(page.nextPageToken).toBe("p2");
    expect(await calendarClient(fakeAccess(null, 204).access).list({ timeMin: new Date(0), timeMax: new Date(1), maxResults: 50 })).toEqual({ events: [], nextPageToken: null });
  });

  it("오류는 상태와 이유만 담아 던진다 (본문은 담지 않는다)", async () => {
    const { access } = fakeAccess({ error: { errors: [{ reason: "rateLimitExceeded" }], message: "secret detail" } }, 403);
    await expect(calendarClient(access).list({ timeMin: new Date(0), timeMax: new Date(1), maxResults: 50 })).rejects.toMatchObject({
      name: "GoogleApiError",
      status: 403,
      reason: "rateLimitExceeded",
      message: "Calendar 요청 실패 (403 rateLimitExceeded)",
    });
    const bad = fakeAccess({ items: "nope" });
    await expect(calendarClient(bad.access).list({ timeMin: new Date(0), timeMax: new Date(1), maxResults: 50 })).rejects.toMatchObject({ status: 502, reason: "bad_response" });
  });
});

describe("pickMeetingEvent: Meet 전사 (회의 코드)", () => {
  const meet = (id: string, code: string, start: string) =>
    event(id, { start: { dateTime: start }, end: { dateTime: new Date(Date.parse(start) + 3_600_000).toISOString() }, conferenceData: { conferenceId: code, conferenceSolution: { key: { type: "hangoutsMeet" } } } });
  const target = (code: string, start: string) => ({ kind: "meet" as const, meetingCode: code, start: new Date(start) });

  it("회의 코드가 같은 일정을 고른다 (대소문자 · 하이픈 무시)", () => {
    const pick = pickMeetingEvent([meet("a", "abc-defg-hij", "2026-09-30T01:00:00Z"), meet("b", "xyz-uvwx-rst", "2026-09-30T01:00:00Z")], target("ABC-defg-hij", "2026-09-30T01:00:40Z"));
    expect(pick).toMatchObject({ result: "attached", event: { id: "a" } });
  });

  it("같은 코드의 반복 일정이 여럿이면 시작 시각이 가장 가까운 하나", () => {
    const pick = pickMeetingEvent(
      [meet("mon", "abc-defg-hij", "2026-09-28T01:00:00Z"), meet("wed", "abc-defg-hij", "2026-09-30T01:00:00Z"), meet("fri", "abc-defg-hij", "2026-10-02T01:00:00Z")],
      target("abc-defg-hij", "2026-09-30T01:02:00Z"),
    );
    expect(pick).toMatchObject({ result: "attached", event: { id: "wed" } });
  });

  it("같은 거리에 같은 코드의 일정이 둘이면 애매하다", () => {
    const pick = pickMeetingEvent([meet("early", "abc-defg-hij", "2026-09-30T00:00:00Z"), meet("late", "abc-defg-hij", "2026-09-30T02:00:00Z")], target("abc-defg-hij", "2026-09-30T01:00:00Z"));
    expect(pick).toEqual({ result: "ambiguous" });
  });

  it("코드가 같은 일정이 없으면 잇지 않는다", () => {
    expect(pickMeetingEvent([meet("a", "abc-defg-hij", "2026-09-30T01:00:00Z")], target("zzz-zzzz-zzz", "2026-09-30T01:00:00Z"))).toEqual({ result: "none" });
    expect(pickMeetingEvent([], target("abc-defg-hij", "2026-09-30T01:00:00Z"))).toEqual({ result: "none" });
  });

  // 사용자 결정 2026-09-30: 회의 코드로 잇는 전사는 같은 회의가 확실하므로 혼자인 일정도 잇는다 (짐작으로 잇는 Notion 쪽은 아래에서 계속 뺀다)
  it("코드가 같으면 참석자가 사용자 한 명뿐인 일정도 잇는다 (참석자 없음 · 회의실만 있는 일정 포함)", () => {
    const soloSelf = event("solo-self", { attendees: [{ email: "alex@lumenfield.example", self: true }], conferenceData: { conferenceId: "abc-defg-hij" } });
    expect(pickMeetingEvent([soloSelf], target("abc-defg-hij", "2026-09-30T01:00:00Z"))).toMatchObject({ result: "attached", event: { id: "solo-self" } });

    const noAttendees = event("no-attendees", { attendees: undefined, conferenceData: { conferenceId: "abc-defg-hij" } });
    expect(pickMeetingEvent([noAttendees], target("abc-defg-hij", "2026-09-30T01:00:00Z"))).toMatchObject({ result: "attached", event: { id: "no-attendees" } });

    const roomOnly = event("room-only", {
      attendees: [{ email: "alex@lumenfield.example", self: true }, { email: "room@resource.calendar.google.com", resource: true }],
      conferenceData: { conferenceId: "abc-defg-hij" },
    });
    expect(pickMeetingEvent([roomOnly], target("abc-defg-hij", "2026-09-30T01:00:00Z"))).toMatchObject({ result: "attached", event: { id: "room-only" } });
  });

  it("코드가 같은 일정이 혼자인 것과 여럿인 것으로 둘이면 시작 시각이 가까운 쪽을 고른다 (혼자인 일정을 먼저 빼지 않는다)", () => {
    const soloNear = event("near", { start: { dateTime: "2026-09-30T01:00:00Z" }, end: { dateTime: "2026-09-30T02:00:00Z" }, attendees: [{ email: "alex@lumenfield.example", self: true }], conferenceData: { conferenceId: "abc-defg-hij" } });
    const groupFar = meet("far", "abc-defg-hij", "2026-10-02T01:00:00Z");
    expect(pickMeetingEvent([groupFar, soloNear], target("abc-defg-hij", "2026-09-30T01:01:00Z"))).toMatchObject({ result: "attached", event: { id: "near" } });
  });

  it("같은 혼자인 일정이라도 코드가 다르면 잇지 않는다", () => {
    const solo = event("solo", { attendees: [{ email: "alex@lumenfield.example", self: true }], conferenceData: { conferenceId: "abc-defg-hij" } });
    expect(pickMeetingEvent([solo], target("zzz-zzzz-zzz", "2026-09-30T01:00:00Z"))).toEqual({ result: "none" });
  });
});

describe("pickMeetingEvent: Notion 회의록 (시각 + 제목, 애매하면 잇지 않는다)", () => {
  /** 2026-09-30 10:00~11:00 KST 일정 (= 01:00~02:00Z) */
  const at = (id: string, title: string, start: string, end: string, extra: Partial<RawEvent> = {}) =>
    event(id, { summary: title, start: { dateTime: start }, end: { dateTime: end }, ...extra });
  const standup = at("standup", "Proposal review — Acme", "2026-09-30T10:00:00+09:00", "2026-09-30T11:00:00+09:00");
  const target = (createdAt: string, title: string | null, createdByUser = true) => ({ kind: "notion" as const, day: "2026-09-30", createdAt: new Date(createdAt), title, createdByUser });

  it("(가)(나) 모두: 만든 시각이 일정 안이고 제목이 같다 (공백 · 기호 · 대소문자 무시)", () => {
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "proposal review - acme"))).toMatchObject({ result: "attached", event: { id: "standup" } });
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "Proposal Review Acme"))).toMatchObject({ result: "attached" });
  });

  it("제목이 한쪽이 다른 쪽을 포함해도 (나)로 본다", () => {
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "Proposal review — Acme (weekly)"))).toMatchObject({ result: "attached", event: { id: "standup" } });
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "Proposal"))).toMatchObject({ result: "attached" });
  });

  it("시각 여유는 일정 앞뒤 15분이다", () => {
    expect(pickMeetingEvent([standup], target("2026-09-30T09:45:00+09:00", "Proposal review — Acme"))).toMatchObject({ result: "attached" });
    expect(pickMeetingEvent([standup], target("2026-09-30T11:15:00+09:00", "Proposal review — Acme"))).toMatchObject({ result: "attached" });
    // 시각이 15분 밖이고 제목만 맞으면 (나)만 맞는 일정이 그날 딱 하나라 이어진다
    expect(pickMeetingEvent([standup], target("2026-09-30T09:44:00+09:00", "Proposal review — Acme"))).toMatchObject({ result: "attached" });
  });

  it("(가)(나)를 모두 맞는 일정이 없으면 (가)만 맞는 일정이 딱 하나일 때 그것", () => {
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "Untitled"))).toMatchObject({ result: "attached", event: { id: "standup" } });
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", null))).toMatchObject({ result: "attached" });
  });

  it("만든 사람이 사용자가 아니면(다른 사람이 만들었거나 모르면) 시각만 맞는 일정은 잇지 않는다: 제목이 맞는 길은 그대로", () => {
    // 같은 시각에 다른 사람이 만든 페이지에 사용자의 일정을 붙이지 않는다
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "Untitled", false))).toEqual({ result: "none" });
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", null, false))).toEqual({ result: "none" });
    // 제목이 맞으면 (가)(나) 모두든 (나)만이든 만든 사람과 상관없이 잇는다
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "Proposal review — Acme", false))).toMatchObject({ result: "attached", event: { id: "standup" } });
    expect(pickMeetingEvent([standup], target("2026-09-30T15:00:00+09:00", "Proposal review — Acme", false))).toMatchObject({ result: "attached", event: { id: "standup" } });
    // 사용자가 만든 페이지는 (가)만 맞아도 이어진다
    expect(pickMeetingEvent([standup], target("2026-09-30T10:05:00+09:00", "Untitled", true))).toMatchObject({ result: "attached" });
  });

  it("(가)만 맞는 일정이 둘이면 애매하다 (같은 시각에 겹친 두 회의)", () => {
    const other = at("other", "Design sync", "2026-09-30T10:30:00+09:00", "2026-09-30T11:30:00+09:00");
    expect(pickMeetingEvent([standup, other], target("2026-09-30T10:35:00+09:00", "Untitled"))).toEqual({ result: "ambiguous" });
    // 제목이 하나만 맞으면 (가)(나) 모두인 그 일정을 고른다
    expect(pickMeetingEvent([standup, other], target("2026-09-30T10:35:00+09:00", "Design sync"))).toMatchObject({ result: "attached", event: { id: "other" } });
  });

  it("(가)(나) 모두 맞는 일정이 둘이면 애매하다 (같은 제목의 겹친 일정)", () => {
    const twin = at("twin", "Proposal review — Acme", "2026-09-30T10:30:00+09:00", "2026-09-30T11:30:00+09:00");
    expect(pickMeetingEvent([standup, twin], target("2026-09-30T10:35:00+09:00", "Proposal review — Acme"))).toEqual({ result: "ambiguous" });
  });

  it("(나)만 맞는 일정이 그날 딱 하나면 그것, 둘이면 애매하다 (같은 이름의 반복 회의)", () => {
    const morning = at("morning", "Weekly sync", "2026-09-30T09:00:00+09:00", "2026-09-30T09:30:00+09:00");
    const evening = at("evening", "Weekly sync", "2026-09-30T18:00:00+09:00", "2026-09-30T18:30:00+09:00");
    expect(pickMeetingEvent([morning], target("2026-09-30T13:00:00+09:00", "Weekly sync"))).toMatchObject({ result: "attached", event: { id: "morning" } });
    expect(pickMeetingEvent([morning, evening], target("2026-09-30T13:00:00+09:00", "Weekly sync"))).toEqual({ result: "ambiguous" });
  });

  it("시각도 제목도 맞지 않으면 잇지 않는다", () => {
    expect(pickMeetingEvent([standup], target("2026-09-30T15:00:00+09:00", "Lunch"))).toEqual({ result: "none" });
    expect(pickMeetingEvent([], target("2026-09-30T10:05:00+09:00", "Proposal review — Acme"))).toEqual({ result: "none" });
  });

  it("사용자 혼자인 일정(작업 시간)은 고르지 않는다: 시각 · 제목으로 짐작하는 길에만 적용한다 (회의 코드로 잇는 Meet 전사는 예외, 위)", () => {
    const work = at("work", "Proposal review — Acme", "2026-09-30T10:00:00+09:00", "2026-09-30T11:00:00+09:00", { attendees: [{ email: "alex@lumenfield.example", self: true }] });
    const alone = at("alone", "Proposal review — Acme", "2026-09-30T10:00:00+09:00", "2026-09-30T11:00:00+09:00", { attendees: undefined });
    expect(pickMeetingEvent([work, alone], target("2026-09-30T10:05:00+09:00", "Proposal review — Acme"))).toEqual({ result: "none" });
    // 회의실만 더한 일정도 혼자다
    const room = at("room", "Proposal review — Acme", "2026-09-30T10:00:00+09:00", "2026-09-30T11:00:00+09:00", {
      attendees: [{ email: "alex@lumenfield.example", self: true }, { email: "room@resource.calendar.google.com", resource: true }],
    });
    expect(pickMeetingEvent([room], target("2026-09-30T10:05:00+09:00", "Proposal review — Acme"))).toEqual({ result: "none" });
  });

  it("한 글자 제목은 제목이 맞는다고 보지 않는다", () => {
    const a = at("a", "A", "2026-09-30T10:00:00+09:00", "2026-09-30T11:00:00+09:00");
    expect(pickMeetingEvent([a], target("2026-09-30T15:00:00+09:00", "Abc"))).toEqual({ result: "none" });
  });
});

describe("eventPeople: 관련자", () => {
  it("사용자는 일정의 self 참석자 대신 프로필 이름 + 연결한 주소로 먼저 한 번, 다음이 일정 참석자다 (자원 제외)", () => {
    const e = event("x", {
      attendees: [
        { email: "alex@lumenfield.example", displayName: "Alex Song", self: true },
        { email: "Jordan@Harborline.example", displayName: "Jordan Lee" },
        { email: "room@resource.calendar.google.com", displayName: "Room", resource: true },
        { email: "noah@lumenfield.example" },
      ],
    });
    expect(eventPeople(e, ME)).toEqual([
      { name: "Alex Kim", email: "alex@lumenfield.example" },
      { name: "Jordan Lee", email: "jordan@harborline.example" },
      { email: "noah@lumenfield.example" },
    ]);
  });

  it("연결한 주소를 모르면 이름만 넣는다", () => {
    expect(eventPeople(event("y"), { name: "송창훈", email: null })[0]).toEqual({ name: "송창훈" });
  });
});

describe("lookupWindow", () => {
  it("Notion은 그 한국 날짜 하루, Meet은 전사 시작 앞뒤 3시간", () => {
    const day = lookupWindow({ kind: "notion", day: "2026-09-30", createdAt: new Date(), title: null, createdByUser: true });
    expect(day.timeMin.toISOString()).toBe("2026-09-29T15:00:00.000Z");
    expect(day.timeMax.toISOString()).toBe("2026-09-30T15:00:00.000Z");
    const meet = lookupWindow({ kind: "meet", meetingCode: "abc-defg-hij", start: new Date("2026-09-30T01:00:00Z") });
    expect(meet.timeMin.toISOString()).toBe("2026-09-29T22:00:00.000Z");
    expect(meet.timeMax.toISOString()).toBe("2026-09-30T04:00:00.000Z");
  });
});

describe("lookupMeetingEvent", () => {
  function fakeClient(events: CalendarEvent[]) {
    const list = vi.fn(async () => ({ events, nextPageToken: null }));
    return { client: { list }, list };
  }

  it("창 안의 일정 한 쪽(50건)을 읽고 고른 일정의 제목 · 시각 · 관련자를 돌려준다", async () => {
    const { client, list } = fakeClient([event("standup", { summary: "Proposal review — Acme" })]);
    const found = await lookupMeetingEvent(client, { kind: "notion", day: "2026-09-30", createdAt: new Date("2026-09-30T10:05:00+09:00"), title: "Proposal review — Acme", createdByUser: true }, ME);
    expect(list).toHaveBeenCalledWith({ timeMin: new Date("2026-09-29T15:00:00.000Z"), timeMax: new Date("2026-09-30T15:00:00.000Z"), maxResults: 50 });
    expect(found).toEqual({
      result: "attached",
      event: {
        calendarEventId: "standup",
        title: "Proposal review — Acme",
        start: "2026-09-30T01:00:00.000Z",
        end: "2026-09-30T02:00:00.000Z",
        attendees: [{ name: "Alex Kim", email: "alex@lumenfield.example" }, { name: "Jordan Lee", email: "jordan@harborline.example" }],
      },
    });
  });

  it("혼자인 일정: 회의 코드로 찾는 Meet 전사에는 붙고(관련자는 사용자만), 시각 · 제목으로 찾는 Notion 회의록에는 붙지 않는다", async () => {
    const solo = event("solo", {
      summary: "Proposal review — Acme",
      attendees: [{ email: "alex@lumenfield.example", displayName: "Alex Song", self: true }],
      conferenceData: { conferenceId: "abc-defg-hij" },
    });
    const { client } = fakeClient([solo]);

    const meet = await lookupMeetingEvent(client, { kind: "meet", meetingCode: "abc-defg-hij", start: new Date("2026-09-30T01:00:30Z") }, ME);
    expect(meet).toMatchObject({ result: "attached", event: { calendarEventId: "solo", title: "Proposal review — Acme", attendees: [{ name: "Alex Kim", email: "alex@lumenfield.example" }] } });

    const notion = await lookupMeetingEvent(client, { kind: "notion", day: "2026-09-30", createdAt: new Date("2026-09-30T10:05:00+09:00"), title: "Proposal review — Acme", createdByUser: true }, ME);
    expect(notion).toEqual({ result: "none" });
  });

  it("못 고르면 애매 · 없음만 돌려주고, 조회가 실패하면 던진다", async () => {
    expect(await lookupMeetingEvent(fakeClient([]).client, { kind: "notion", day: "2026-09-30", createdAt: new Date(), title: null, createdByUser: true }, ME)).toEqual({ result: "none" });
    const failing = { list: vi.fn(async () => Promise.reject(new Error("boom"))) };
    await expect(lookupMeetingEvent(failing, { kind: "notion", day: "2026-09-30", createdAt: new Date(), title: null, createdByUser: true }, ME)).rejects.toThrow("boom");
  });
});
