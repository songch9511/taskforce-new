import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { IngestDeps } from "../ingest";
import type { Connection, IngestItem } from "../types";

import { CALENDAR_CODE_FIELDS, type CalendarClient, type CalendarEvent } from "./calendar";
import { MeetBudgetExhausted, type ConferenceRecord, type MeetClient, type MeetParticipant, type Transcript, type TranscriptEntry } from "./meet";
import { DEFAULT_GOOGLE_SYNC, MEET_REQUEST_BUDGET, parseGoogleCursor, syncGoogleMeet, type GoogleSyncInput, type GoogleSyncOptions } from "./sync";
import { GoogleApiError, GoogleReauthError } from "./token";

// google 연결의 Meet 전사 동기화 (G2 · G3 · G5, docs/go-live/google-integration.md 2-5). Google을 부르지 않고 가짜 클라이언트를 쓴다.

const NOW = new Date("2026-10-05T12:00:00.000Z");
const HOUR = 3_600_000;
const ME_SUB = "1000000000000000001";
const ME = { name: "Alex Kim", email: "alex@lumenfield.example", sub: ME_SUB };

const connection = (syncCursor: Connection["syncCursor"] = null): Connection => ({ id: "conn-1", userId: "user-1", provider: "google", settings: {}, syncCursor });
const options = (extra: Partial<GoogleSyncOptions> = {}): GoogleSyncOptions => ({ now: NOW, ...DEFAULT_GOOGLE_SYNC, ...extra });

/** 끝난 회의 기록: 종료 시각은 지금보다 hoursAgo 시간 전, 한 시간짜리 */
const record = (id: string, hoursAgo: number, space: string | null = `spaces/${id}`): ConferenceRecord => ({
  name: `conferenceRecords/${id}`,
  startTime: new Date(NOW.getTime() - (hoursAgo + 1) * HOUR),
  endTime: new Date(NOW.getTime() - hoursAgo * HOUR),
  space,
});
const transcriptOf = (rec: ConferenceRecord, state = "FILE_GENERATED"): Transcript => ({
  name: `${rec.name}/transcripts/t1`,
  state,
  startTime: new Date(rec.startTime.getTime() + 5_000),
  endTime: new Date(rec.endTime.getTime() - 60_000),
  documentId: "1kuceFZohVoCh6FulBHxwy6I15Ogpc4hP",
});

const PARTICIPANTS: MeetParticipant[] = [
  { name: "p1", kind: "signedin", user: `users/${ME_SUB}`, displayName: "Daniel Song" },
  { name: "p2", kind: "signedin", user: "users/222", displayName: "Jordan Lee" },
];
const ENTRIES: TranscriptEntry[] = [
  { participant: "p2", text: "Thanks for the draft. Could you revise the pricing section?", startTime: new Date("2026-10-05T10:00:10Z") },
  { participant: "p1", text: "Sure. I'll send the revised proposal to Jordan by Friday.", startTime: new Date("2026-10-05T10:00:20Z") },
];

type FakeMeet = MeetClient & { calls: string[] };

function fakeMeet(setup: {
  hosted?: ConferenceRecord[];
  /** 회의 코드 → 그 코드로 찾은 회의 기록 (참석한 회의) */
  byCode?: Record<string, ConferenceRecord[] | "denied" | "rate" | "error">;
  transcripts?: Record<string, Transcript[]>;
  codes?: Record<string, string | null>;
  listTranscriptsFails?: (recordName: string) => Error | undefined;
  listEntriesFails?: (transcriptName: string) => Error | undefined;
}): FakeMeet {
  const calls: string[] = [];
  return {
    calls,
    listRecords: vi.fn(async (filter: string) => {
      calls.push(`records:${filter}`);
      const code = filter.match(/space\.meeting_code = "([^"]+)"/)?.[1];
      if (!code) {
        // 주최한 회의: Google처럼 end_time 조건을 지킨다 (커서 앞에 끝난 기록은 돌려주지 않는다)
        const since = filter.match(/^end_time>="([^"]+)"$/)?.[1];
        return (setup.hosted ?? []).filter((r) => !since || r.endTime.getTime() >= Date.parse(since));
      }
      const found = setup.byCode?.[code];
      if (found === "denied") throw new GoogleApiError("Meet 요청 실패 (403 PERMISSION_DENIED)", 403, "PERMISSION_DENIED");
      if (found === "rate") throw new GoogleApiError("Meet 요청 실패 (429)", 429, "RESOURCE_EXHAUSTED");
      if (found === "error") throw new GoogleApiError("Meet 요청 실패 (503)", 503, "UNAVAILABLE");
      return found ?? [];
    }),
    listTranscripts: vi.fn(async (name: string) => {
      calls.push(`transcripts:${name}`);
      const failure = setup.listTranscriptsFails?.(name);
      if (failure) throw failure;
      return setup.transcripts?.[name] ?? [];
    }),
    listEntries: vi.fn(async (name: string) => {
      calls.push(`entries:${name}`);
      const failure = setup.listEntriesFails?.(name);
      if (failure) throw failure;
      return ENTRIES;
    }),
    listParticipants: vi.fn(async (name: string) => {
      calls.push(`participants:${name}`);
      return PARTICIPANTS;
    }),
    meetingCode: vi.fn(async (space: string) => {
      calls.push(`space:${space}`);
      return setup.codes && space in setup.codes ? setup.codes[space] : "abc-defg-hij";
    }),
  };
}

const calendarEvent = (id: string, extra: Partial<CalendarEvent> = {}): CalendarEvent => ({
  id,
  title: "Proposal review — Acme",
  start: new Date("2026-10-05T10:00:00Z"),
  end: new Date("2026-10-05T11:00:00Z"),
  organizerSelf: false,
  attendees: [
    { email: "alex@lumenfield.example", name: "Alex Song", self: true, resource: false },
    { email: "jordan@harborline.example", name: "Jordan Lee", self: false, resource: false },
  ],
  conferenceId: "abc-defg-hij",
  conferenceType: "hangoutsMeet",
  ...extra,
});

/**
 * Calendar 가짜: Google처럼 창(timeMin 이후에 끝나고 timeMax 전에 시작하는 일정)만 돌려준다.
 * pages를 주면 쪽마다 나눠 돌려주고 마지막 쪽 앞에는 nextPageToken을 붙인다.
 */
function fakeCalendar(events: CalendarEvent[], fail?: () => Error | undefined, pages?: CalendarEvent[][]): CalendarClient & { list: ReturnType<typeof vi.fn> } {
  return {
    list: vi.fn(async (range: { timeMin: Date; timeMax: Date; pageToken?: string }) => {
      const failure = fail?.();
      if (failure) throw failure;
      const inWindow = (e: CalendarEvent) => e.end.getTime() > range.timeMin.getTime() && e.start.getTime() < range.timeMax.getTime();
      if (pages) {
        const index = range.pageToken ? Number(range.pageToken) : 0;
        return { events: (pages[index] ?? []).filter(inWindow), nextPageToken: index + 1 < pages.length ? String(index + 1) : null };
      }
      return { events: events.filter(inWindow), nextPageToken: null };
    }),
  };
}

function fakeDeps(already: string[] = []) {
  const inserted: IngestItem[] = [];
  const deps: IngestDeps = {
    // 이미 넣은 것: 시작할 때 있던 것과, 이 가짜에 넣은 것 (여러 동기화에 걸친 시험에서 같은 전사를 두 번 넣지 않는지 본다)
    ingestedIds: vi.fn(async (_c: Connection, ids: string[]) => new Set(ids.filter((id) => already.includes(id) || inserted.some((i) => i.externalId === id)))),
    insertSource: vi.fn(async (_c: Connection, item: IngestItem) => {
      inserted.push(item);
      return `src-${inserted.length}`;
    }),
    process: vi.fn(async () => {}),
  };
  return { deps, inserted };
}

const input = (meetApi: MeetClient, extra: Partial<GoogleSyncInput> = {}): GoogleSyncInput => ({ meet: true, calendar: null, meetApi, me: ME, ...extra });
const cursorAfter = (result: { cursor: { after: string } | null }) => result.cursor?.after;

describe("syncGoogleMeet: 주최한 회의", () => {
  it("끝난 회의의 FILE_GENERATED 전사를 원문으로 넣고, 커서를 지금 − 30분으로 옮긴다", async () => {
    const rec = record("c1", 3);
    const meet = fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec)] } });
    const { deps, inserted } = fakeDeps();

    const result = await syncGoogleMeet(connection(), input(meet), deps, options());

    expect(inserted).toHaveLength(1);
    expect(inserted[0]).toMatchObject({ externalId: "conferenceRecords/c1/transcripts/t1", kind: "meeting", externalVersion: "1" });
    expect(inserted[0].text).toContain("Alex Kim: Sure. I'll send the revised proposal to Jordan by Friday.");
    expect(result.created).toEqual(["src-1"]);
    expect(result.counts).toEqual({ meet_transcripts: 1 });
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
    expect(result.rateLimited).toBe(false);
  });

  it("회의 기록은 커서 이후에 끝난 것만 찾는다 (첫 동기화는 14일 전)", async () => {
    const meet = fakeMeet({});
    await syncGoogleMeet(connection(), input(meet), fakeDeps().deps, options());
    expect(meet.calls[0]).toBe('records:end_time>="2026-09-21T12:00:00.000Z"');
  });

  it("저장된 커서부터 찾고, 29일보다 오래됐으면 29일 전으로 당긴다 (전사 항목은 끝난 뒤 30일에 지워진다)", async () => {
    const recent = fakeMeet({});
    await syncGoogleMeet(connection({ after: "2026-10-04T00:00:00.000Z" }), input(recent), fakeDeps().deps, options());
    expect(recent.calls[0]).toBe('records:end_time>="2026-10-04T00:00:00.000Z"');

    const stale = fakeMeet({});
    const result = await syncGoogleMeet(connection({ after: "2026-08-01T00:00:00.000Z" }), input(stale), fakeDeps().deps, options());
    expect(stale.calls[0]).toBe('records:end_time>="2026-09-06T12:00:00.000Z"');
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("커서는 뒤로 가지 않는다 (지금 − 30분이 커서보다 앞이면 커서 그대로)", async () => {
    const result = await syncGoogleMeet(connection({ after: "2026-10-05T11:50:00.000Z" }), input(fakeMeet({})), fakeDeps().deps, options());
    expect(cursorAfter(result)).toBe("2026-10-05T11:50:00.000Z");
  });

  it("이미 넣은 전사는 항목 · 참가자 · 일정을 부르지 않는다", async () => {
    const rec = record("c1", 3);
    const meet = fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec)] } });
    const calendar = fakeCalendar([calendarEvent("evt-1")]);
    const { deps, inserted } = fakeDeps(["conferenceRecords/c1/transcripts/t1"]);

    const result = await syncGoogleMeet(connection(), input(meet, { calendar, listAttended: false }), deps, options());

    expect(inserted).toEqual([]);
    expect(meet.calls.filter((c) => /^(entries|participants|space):/.test(c))).toEqual([]);
    expect(calendar.list).not.toHaveBeenCalled();
    expect(result.skipped.alreadyIngested).toBe(1);
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("전사가 없는 회의는 결정한 것으로 보고 커서가 지나간다", async () => {
    const rec = record("c1", 1);
    const result = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [rec] })), fakeDeps().deps, options());
    expect(result.created).toEqual([]);
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("한 회의에 전사가 여럿이면(껐다 켬) 전사마다 원문 하나", async () => {
    const rec = record("c1", 3);
    const second = { ...transcriptOf(rec), name: `${rec.name}/transcripts/t2` };
    const { deps, inserted } = fakeDeps();
    await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec), second] } })), deps, options());
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/c1/transcripts/t1", "conferenceRecords/c1/transcripts/t2"]);
  });
});

describe("syncGoogleMeet: 전사 파일이 생길 때까지 (ENDED)", () => {
  it("끝난 지 2시간 안에 ENDED면 다음 동기화에서 다시 본다: 넣지 않고 커서를 그 회의의 끝 시각에 둔다", async () => {
    const rec = record("c1", 1);
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec, "ENDED")] } })), deps, options());
    expect(inserted).toEqual([]);
    expect(cursorAfter(result)).toBe(rec.endTime.toISOString());
  });

  it("2시간이 지나도 ENDED면 전사 항목으로 넣는다", async () => {
    const rec = record("c1", 2);
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec, "ENDED")] } })), deps, options());
    expect(inserted).toHaveLength(1);
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("STARTED로 남은 전사는 2시간 동안 기다리고, 그래도 안 끝나면 포기한다 (결정: 커서가 지나간다)", async () => {
    const waiting = record("c1", 1);
    const first = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [waiting], transcripts: { [waiting.name]: [transcriptOf(waiting, "STARTED")] } })), fakeDeps().deps, options());
    expect(cursorAfter(first)).toBe(waiting.endTime.toISOString());

    const stuck = record("c2", 3);
    const { deps, inserted } = fakeDeps();
    const second = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [stuck], transcripts: { [stuck.name]: [transcriptOf(stuck, "STARTED")] } })), deps, options());
    expect(inserted).toEqual([]);
    expect(cursorAfter(second)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("아직 기다리는 회의가 있으면 커서는 그 회의의 끝까지만 가고, 그보다 나중 회의는 이미 넣었어도 다음에 외부 id로 걸러진다", async () => {
    const early = record("c1", 5);
    const waiting = record("c2", 1);
    const meet = fakeMeet({ hosted: [early, waiting], transcripts: { [early.name]: [transcriptOf(early)], [waiting.name]: [transcriptOf(waiting, "ENDED")] } });
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet), deps, options());
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/c1/transcripts/t1"]);
    expect(cursorAfter(result)).toBe(waiting.endTime.toISOString());
  });
});

describe("syncGoogleMeet: 넣기 상한", () => {
  it("한 동기화에 maxItems개까지 넣고, 넘친 회의는 다음에 (커서가 그 회의의 끝에 남는다)", async () => {
    const records = [record("c1", 6), record("c2", 5), record("c3", 4)];
    const transcripts = Object.fromEntries(records.map((r) => [r.name, [transcriptOf(r)]]));
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: records, transcripts })), deps, options({ maxItems: 2 }));
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/c1/transcripts/t1", "conferenceRecords/c2/transcripts/t1"]);
    expect(cursorAfter(result)).toBe(records[2].endTime.toISOString());
    expect(result.skipped.overLimit).toBe(0);
  });
});

describe("syncGoogleMeet: 같은 회의의 일정 (G3)", () => {
  const rec = record("c1", 3);
  const setup = () => fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec)] } });

  it("회의 공간의 회의 코드로 일정을 찾아 제목 · 관련자 · meeting을 붙이고, 붙음을 센다", async () => {
    const meet = setup();
    const calendar = fakeCalendar([calendarEvent("evt-1")]);
    const { deps, inserted } = fakeDeps();

    const result = await syncGoogleMeet(connection(), input(meet, { calendar, listAttended: false }), deps, options());

    expect(meet.calls).toContain("space:spaces/c1");
    expect(inserted[0]).toMatchObject({
      title: "Proposal review — Acme",
      meeting: { calendar_event_id: "evt-1", title: "Proposal review — Acme", start: "2026-10-05T10:00:00.000Z", end: "2026-10-05T11:00:00.000Z" },
      participants: { attendees: [{ name: "Alex Kim", email: "alex@lumenfield.example" }, { name: "Jordan Lee", email: "jordan@harborline.example" }] },
    });
    expect(inserted[0].text.startsWith("[Google Meet · Proposal review — Acme]\n")).toBe(true);
    expect(result.counts).toEqual({ meet_transcripts: 1, meet_link_attached: 1 });
  });

  it("참석자가 사용자 한 명뿐인 일정도 회의 코드가 같으면 붙는다 (코드로 잇는 전사는 예외, 2026-09-30 결정)", async () => {
    const solo = calendarEvent("solo", { attendees: [{ email: "alex@lumenfield.example", name: "Alex Song", self: true, resource: false }] });
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(setup(), { calendar: fakeCalendar([solo]), listAttended: false }), deps, options());
    expect(inserted[0]).toMatchObject({
      title: "Proposal review — Acme",
      meeting: { calendar_event_id: "solo" },
      participants: { attendees: [{ name: "Alex Kim", email: "alex@lumenfield.example" }, { name: "Jordan Lee" }] },
    });
    expect(result.counts).toEqual({ meet_transcripts: 1, meet_link_attached: 1 });
  });

  it("일정이 없으면 없음 · 코드가 다르면 없음, 일정 조회가 실패하면 일정 없이 넣고 실패로 센다", async () => {
    const none = await syncGoogleMeet(connection(), input(setup(), { calendar: fakeCalendar([calendarEvent("evt-1", { conferenceId: "zzz-zzzz-zzz" })]), listAttended: false }), fakeDeps().deps, options());
    expect(none.counts).toEqual({ meet_transcripts: 1, meet_link_none: 1 });

    const noCode = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec)] }, codes: { "spaces/c1": null } }), { calendar: fakeCalendar([]), listAttended: false }), fakeDeps().deps, options());
    expect(noCode.counts).toEqual({ meet_transcripts: 1, meet_link_none: 1 });

    vi.spyOn(console, "error").mockImplementation(() => {});
    const { deps, inserted } = fakeDeps();
    const failed = await syncGoogleMeet(
      connection(),
      input(setup(), { calendar: fakeCalendar([], () => new GoogleApiError("Calendar 요청 실패 (500)", 500)), listAttended: false }),
      deps,
      options(),
    );
    expect(inserted).toHaveLength(1);
    expect(inserted[0].meeting).toBeUndefined();
    expect(inserted[0].title).toBe("Google Meet · 2026-10-05 17:00");
    expect(failed.counts).toEqual({ meet_transcripts: 1, meet_link_failed: 1 });
    vi.restoreAllMocks();
  });

  it("Calendar를 허용하지 않았으면(Meet만) 일정을 찾지 않는다: 회의 공간도 부르지 않는다", async () => {
    const meet = setup();
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet, { calendar: null }), deps, options());
    expect(meet.calls.some((c) => c.startsWith("space:"))).toBe(false);
    expect(inserted[0].meeting).toBeUndefined();
    expect(result.counts).toEqual({ meet_transcripts: 1 });
  });

  it("일정 조회가 속도 제한이면 멈춘다: 일정 없이 넣으면 그 전사는 일정을 다시 붙일 수 없다", async () => {
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(
      connection(),
      input(setup(), { calendar: fakeCalendar([], () => new GoogleApiError("Calendar 요청 실패 (429)", 429, "rateLimitExceeded")), listAttended: false }),
      deps,
      options(),
    );
    expect(inserted).toEqual([]);
    expect(result.rateLimited).toBe(true);
    expect(cursorAfter(result)).toBe(rec.endTime.toISOString());
  });

  it("토큰 만료(GoogleReauthError)는 그대로 올린다 (연결이 reauth가 된다)", async () => {
    await expect(
      syncGoogleMeet(connection(), input(setup(), { calendar: fakeCalendar([], () => new GoogleReauthError()), listAttended: false }), fakeDeps().deps, options()),
    ).rejects.toBeInstanceOf(GoogleReauthError);
  });
});

describe("syncGoogleMeet: 참석한 회의 (G2 ②)", () => {
  const attended = record("a1", 3);
  const setup = (byCode: Record<string, ConferenceRecord[] | "denied" | "rate" | "error">, hosted: ConferenceRecord[] = []) =>
    fakeMeet({ hosted, byCode, transcripts: { [attended.name]: [transcriptOf(attended)] } });

  it("Calendar에서 사용자가 주최하지 않은 Meet 일정의 회의 코드로 회의 기록을 찾아 전사를 넣는다 (회의 코드만 쓴다)", async () => {
    const meet = setup({ "abc-defg-hij": [attended] });
    const calendar = fakeCalendar([
      calendarEvent("guest"),
      calendarEvent("mine", { organizerSelf: true, conferenceId: "own-code-xyz" }),
      calendarEvent("plain", { conferenceId: null, conferenceType: null }),
      calendarEvent("zoom", { conferenceId: "12345", conferenceType: "addOn" }),
    ]);
    const { deps, inserted } = fakeDeps();

    const result = await syncGoogleMeet(connection(), input(meet, { calendar }), deps, options());

    const codeQueries = meet.calls.filter((c) => c.includes("space.meeting_code"));
    expect(codeQueries).toEqual([`records:space.meeting_code = "abc-defg-hij" AND start_time>="2026-10-04T10:00:00.000Z"`]);
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/a1/transcripts/t1"]);
    expect(result.counts).toMatchObject({ meet_transcripts: 1, meet_transcripts_attended: 1, meet_attended_codes: 1, meet_link_attached: 1 });
    // 일정 목록은 커서 하루 앞부터 지금까지를 한 쪽 250건으로 읽고, 제목 · 참석자 이메일은 받지 않는다 (회의 코드만 쓴다)
    expect(calendar.list).toHaveBeenCalledWith({
      timeMin: new Date("2026-09-20T12:00:00.000Z"),
      timeMax: NOW,
      maxResults: 250,
      pageToken: undefined,
      fields: CALENDAR_CODE_FIELDS,
    });
    expect(CALENDAR_CODE_FIELDS).not.toMatch(/summary|email|displayName|description|attachments|location/);
  });

  it("주최한 회의로 이미 찾은 회의 기록은 그대로 두고, 커서보다 먼저 끝난 기록은 버린다", async () => {
    const old = { ...record("old", 24 * 20) };
    const meet = setup({ "abc-defg-hij": [attended, old] }, [attended]);
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet, { calendar: fakeCalendar([calendarEvent("guest")]) }), deps, options({ lookbackDays: 3 }));
    expect(inserted).toHaveLength(1);
    expect(result.counts.meet_transcripts_attended).toBeUndefined();
    expect(meet.calls.filter((c) => c === "transcripts:conferenceRecords/old")).toEqual([]);
  });

  it("참석자에게 회의 기록을 안 주면(403) 못 본 것으로 세고 넘어간다: 동기화는 실패하지 않는다", async () => {
    const meet = setup({ "abc-defg-hij": "denied" });
    const result = await syncGoogleMeet(connection(), input(meet, { calendar: fakeCalendar([calendarEvent("guest")]) }), fakeDeps().deps, options());
    expect(result.counts).toEqual({ meet_attended_codes: 1, meet_attended_denied: 1 });
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("빈 목록이면 회의 코드 조회만 세고 넘어간다", async () => {
    const result = await syncGoogleMeet(connection(), input(setup({}), { calendar: fakeCalendar([calendarEvent("guest")]) }), fakeDeps().deps, options());
    expect(result.counts).toEqual({ meet_attended_codes: 1 });
  });

  it("초대한 사람이 넣은 회의 코드가 코드 모양이 아니면 목록 조건에 쓰지 않는다 (filter 주입 방지)", async () => {
    const meet = setup({});
    const events = [calendarEvent("bad", { conferenceId: 'abc" OR space.name = "spaces/x' }), calendarEvent("ok", { conferenceId: "abc-defg-hij" })];
    await syncGoogleMeet(connection(), input(meet, { calendar: fakeCalendar(events) }), fakeDeps().deps, options());
    expect(meet.calls.filter((c) => c.includes("space.meeting_code"))).toEqual([expect.stringContaining('"abc-defg-hij"')]);
  });

  it("같은 회의 코드의 반복 일정은 한 번만 조회한다", async () => {
    const meet = setup({ "abc-defg-hij": [] });
    await syncGoogleMeet(connection(), input(meet, { calendar: fakeCalendar([calendarEvent("w1"), calendarEvent("w2", { start: new Date("2026-10-06T10:00:00Z") })]) }), fakeDeps().deps, options());
    expect(meet.calls.filter((c) => c.includes("space.meeting_code"))).toHaveLength(1);
  });

  it("조회 한도(maxAttendedCodes)를 넘은 일정은 다음에: 커서가 그 일정의 시작에 남는다", async () => {
    const meet = setup({});
    const events = [calendarEvent("e1", { conferenceId: "aaa-aaaa-aaa" }), calendarEvent("e2", { conferenceId: "bbb-bbbb-bbb", start: new Date("2026-10-05T08:00:00Z") })];
    const result = await syncGoogleMeet(connection(), input(meet, { calendar: fakeCalendar(events) }), fakeDeps().deps, options({ maxAttendedCodes: 1 }));
    expect(meet.calls.filter((c) => c.includes("space.meeting_code"))).toHaveLength(1);
    expect(cursorAfter(result)).toBe("2026-10-05T08:00:00.000Z");
  });

  it("속도 제한이면 멈추고 커서를 옮기지 않는다", async () => {
    const result = await syncGoogleMeet(connection({ after: "2026-10-04T00:00:00.000Z" }), input(setup({ "abc-defg-hij": "rate" }), { calendar: fakeCalendar([calendarEvent("guest")]) }), fakeDeps().deps, options());
    expect(result.rateLimited).toBe(true);
    expect(cursorAfter(result)).toBe("2026-10-04T00:00:00.000Z");
  });

  it("LIST_ATTENDED_MEETINGS를 끄면(listAttended: false) 일정 목록도 회의 코드 조회도 하지 않는다", async () => {
    const meet = setup({ "abc-defg-hij": [attended] });
    const calendar = fakeCalendar([calendarEvent("guest")]);
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet, { calendar, listAttended: false }), deps, options());
    expect(calendar.list).not.toHaveBeenCalled();
    expect(meet.calls.some((c) => c.includes("space.meeting_code"))).toBe(false);
    expect(inserted).toEqual([]);
    expect(result.created).toEqual([]);
  });

  it("Calendar를 허용하지 않았으면(Meet만) 참석한 회의는 건너뛴다", async () => {
    const meet = setup({ "abc-defg-hij": [attended] });
    await syncGoogleMeet(connection(), input(meet, { calendar: null }), fakeDeps().deps, options());
    expect(meet.calls.some((c) => c.includes("space.meeting_code"))).toBe(false);
  });
});

describe("syncGoogleMeet: 멈추는 경우", () => {
  it("Meet을 허용하지 않았으면(Calendar만) 아무것도 부르지 않고 커서도 두지 않는다", async () => {
    const meet = fakeMeet({});
    const result = await syncGoogleMeet(connection(), input(meet, { meet: false, calendar: fakeCalendar([]) }), fakeDeps().deps, options());
    expect(meet.calls).toEqual([]);
    expect(result).toMatchObject({ created: [], scanned: 0, cursor: null, counts: {}, rateLimited: false });
  });

  it("전사 나열이 속도 제한이면 거기까지 결정한 것만 넣고 커서를 나열하지 못한 첫 회의의 끝에 둔다", async () => {
    const records = [record("c1", 6), record("c2", 5), record("c3", 4)];
    const meet = fakeMeet({
      hosted: records,
      transcripts: { [records[0].name]: [transcriptOf(records[0])] },
      listTranscriptsFails: (name) => (name === records[1].name ? new GoogleApiError("Meet 요청 실패 (429)", 429, "RESOURCE_EXHAUSTED") : undefined),
    });
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet), deps, options());
    expect(result.rateLimited).toBe(true);
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/c1/transcripts/t1"]);
    expect(cursorAfter(result)).toBe(records[1].endTime.toISOString());
  });

  it("요청 예산을 다 쓰면 멈춘다 (속도 제한으로 세지 않는다)", async () => {
    const records = [record("c1", 6), record("c2", 5)];
    const meet = fakeMeet({
      hosted: records,
      listTranscriptsFails: (name) => (name === records[1].name ? new MeetBudgetExhausted() : undefined),
    });
    const result = await syncGoogleMeet(connection(), input(meet), fakeDeps().deps, options());
    expect(result.rateLimited).toBe(false);
    expect(cursorAfter(result)).toBe(records[1].endTime.toISOString());
  });

  it("전사를 나열하지 못하는 그 밖의 오류(서버 오류)는 올린다: 연결이 error가 되고 커서는 그대로", async () => {
    const rec = record("c1", 3);
    const meet = fakeMeet({ hosted: [rec], listTranscriptsFails: () => new GoogleApiError("Meet 요청 실패 (500)", 500) });
    await expect(syncGoogleMeet(connection(), input(meet), fakeDeps().deps, options())).rejects.toMatchObject({ status: 500 });
  });

  it("시간 한도(deadline)가 지났으면 나열을 시작하지 않고 커서를 옮기지 않는다", async () => {
    const rec = record("c1", 3);
    const meet = fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec)] } });
    const { inserted, deps } = fakeDeps();
    const result = await syncGoogleMeet(connection({ after: "2026-10-04T00:00:00.000Z" }), input(meet), deps, options({ deadline: Date.now() - 1 }));
    expect(inserted).toEqual([]);
    expect(meet.calls.some((c) => c.startsWith("transcripts:"))).toBe(false);
    expect(cursorAfter(result)).toBe(rec.endTime.toISOString());
  });

  it("서버 시계보다 뒤의 시각으로 끝난 전사(시계 차이)는 안정화 중으로 건너뛰므로 다음에 다시 본다", async () => {
    const rec = record("c1", 3);
    const skewed = { ...transcriptOf(rec), endTime: new Date(NOW.getTime() + 60_000) };
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [skewed] } })), deps, options());
    expect(inserted).toEqual([]);
    expect(cursorAfter(result)).toBe(rec.endTime.toISOString());
  });

  it("전사 항목이 너무 짧으면(30자 미만) 넣지 않지만 결정한 것으로 본다", async () => {
    const rec = record("c1", 3);
    const meet = fakeMeet({ hosted: [rec], transcripts: { [rec.name]: [transcriptOf(rec)] } });
    vi.mocked(meet.listEntries).mockResolvedValueOnce([]);
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet), deps, options());
    expect(inserted).toEqual([]);
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });
});

// 독립 검토(2026-09-29)에서 찾은 것들의 회귀 시험
describe("syncGoogleMeet: 참석한 회의를 여러 동기화에 걸쳐 (일정의 예정 끝 < 회의 끝)", () => {
  it("회의가 예정보다 길어지고 전사 파일이 늦게 생겨도 다음 동기화에서 넣는다: 커서가 회의 끝에 있어도 그 일정을 다시 읽는다", async () => {
    const scheduled = calendarEvent("guest", { start: new Date("2026-10-05T10:00:00Z"), end: new Date("2026-10-05T10:30:00Z") });
    const rec: ConferenceRecord = { name: "conferenceRecords/a1", startTime: new Date("2026-10-05T10:00:00Z"), endTime: new Date("2026-10-05T10:40:00Z"), space: "spaces/a1" };
    const transcripts: Record<string, Transcript[]> = { [rec.name]: [transcriptOf(rec, "ENDED")] };
    const meet = fakeMeet({ byCode: { "abc-defg-hij": [rec] }, transcripts });
    const calendar = fakeCalendar([scheduled]);
    const { deps, inserted } = fakeDeps();

    // 10:50: 전사 파일이 아직 없다 → 기다린다. 커서는 회의 끝(10:40)에 남는다
    const first = await syncGoogleMeet(connection(), input(meet, { calendar }), deps, options({ now: new Date("2026-10-05T10:50:00Z") }));
    expect(inserted).toEqual([]);
    expect(cursorAfter(first)).toBe("2026-10-05T10:40:00.000Z");

    // 나중에 파일이 생겼다. 일정의 예정 끝(10:30)은 커서(10:40)보다 앞이지만 다시 읽어 회의 기록을 찾는다
    transcripts[rec.name] = [transcriptOf(rec, "FILE_GENERATED")];
    const second = await syncGoogleMeet(connection({ after: cursorAfter(first) }), input(meet, { calendar }), deps, options({ now: new Date("2026-10-05T11:20:00Z") }));
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/a1/transcripts/t1"]);
    expect(second.counts).toMatchObject({ meet_transcripts: 1, meet_transcripts_attended: 1 });
  });

  it("예정보다 30분 넘게 길어진 회의도 놓치지 않는다 (창은 지금 − 30분이 아니라 커서 하루 앞부터)", async () => {
    const scheduled = calendarEvent("guest", { start: new Date("2026-10-05T09:00:00Z"), end: new Date("2026-10-05T09:30:00Z") });
    const rec: ConferenceRecord = { name: "conferenceRecords/a1", startTime: new Date("2026-10-05T09:00:00Z"), endTime: new Date("2026-10-05T11:10:00Z"), space: "spaces/a1" };
    const meet = fakeMeet({ byCode: { "abc-defg-hij": [rec] }, transcripts: { [rec.name]: [transcriptOf(rec)] } });
    const { deps, inserted } = fakeDeps();
    // 지난 동기화가 11:30에 커서를 지금 − 30분으로 옮긴 뒤(11:00), 회의가 끝난 11:10 기록이 이번에 처음 목록에 나왔다
    await syncGoogleMeet(connection({ after: "2026-10-05T11:00:00.000Z" }), input(meet, { calendar: fakeCalendar([scheduled]) }), deps, options({ now: new Date("2026-10-05T11:35:00Z") }));
    expect(inserted).toHaveLength(1);
  });
});

describe("syncGoogleMeet: 회의 기록이 많을 때 (요청 예산)", () => {
  it("넣을 전사가 상한(20)에 차면 나열을 멈춘다: 기록이 수백 개여도 예산을 나열에 다 쓰지 않고 매번 앞으로 나아간다", async () => {
    const records = Array.from({ length: 420 }, (_, i) => record(`c${i}`, 330 - i / 2));
    const transcripts = Object.fromEntries(records.map((r) => [r.name, [transcriptOf(r)]]));
    const meet = fakeMeet({ hosted: records, transcripts });
    const { deps, inserted } = fakeDeps();

    const first = await syncGoogleMeet(connection(), input(meet), deps, options());

    expect(inserted).toHaveLength(20);
    expect(meet.calls.filter((c) => c.startsWith("transcripts:"))).toHaveLength(20);
    expect(cursorAfter(first)).toBe(records[20].endTime.toISOString());

    // 다음 동기화는 그 커서부터 이어서 20건을 더 넣는다 (같은 자리에 머물지 않는다)
    const second = await syncGoogleMeet(connection({ after: cursorAfter(first) }), input(meet), deps, options());
    expect(inserted).toHaveLength(40);
    expect(cursorAfter(second)).toBe(records[40].endTime.toISOString());
  });

  it("전사가 없는 회의가 많으면 한 동기화에 나열하는 기록 수(maxRecordsListed)에서 멈추고 커서를 그 다음 기록의 끝에 둔다", async () => {
    const records = Array.from({ length: 5 }, (_, i) => record(`n${i}`, 50 - i));
    const meet = fakeMeet({ hosted: records });
    const first = await syncGoogleMeet(connection(), input(meet), fakeDeps().deps, options({ maxRecordsListed: 3 }));
    expect(meet.calls.filter((c) => c.startsWith("transcripts:"))).toHaveLength(3);
    expect(cursorAfter(first)).toBe(records[3].endTime.toISOString());

    const second = await syncGoogleMeet(connection({ after: cursorAfter(first) }), input(meet), fakeDeps().deps, options({ maxRecordsListed: 3 }));
    expect(cursorAfter(second)).toBe("2026-10-05T11:30:00.000Z");
  });
});

describe("syncGoogleMeet: 볼 수 없는 자료 (403 · 404)", () => {
  const forbidden = () => new GoogleApiError("Meet 요청 실패 (403 PERMISSION_DENIED)", 403, "PERMISSION_DENIED");

  it("전사 목록을 볼 수 없는 회의 기록(참석자에게 안 주는 자료)은 못 본 것으로 세고 넘어간다: 다른 회의의 전사는 넣고 커서도 나아간다", async () => {
    const hidden = record("hidden", 6);
    const visible = record("visible", 5);
    const meet = fakeMeet({
      hosted: [hidden, visible],
      transcripts: { [visible.name]: [transcriptOf(visible)] },
      listTranscriptsFails: (name) => (name === hidden.name ? forbidden() : undefined),
    });
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet), deps, options());
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/visible/transcripts/t1"]);
    expect(result.counts).toEqual({ meet_transcripts: 1, meet_artifacts_denied: 1 });
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("전사 항목을 볼 수 없어도 같다 (그 전사만 결정한 것으로 본다)", async () => {
    const rec = record("c1", 3);
    const meet = fakeMeet({
      hosted: [rec],
      transcripts: { [rec.name]: [transcriptOf(rec)] },
      listEntriesFails: () => forbidden(),
    });
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet), deps, options());
    expect(inserted).toEqual([]);
    expect(result.counts).toEqual({ meet_artifacts_denied: 1 });
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });

  it("속도 제한 403(rateLimitExceeded)은 볼 수 없는 자료가 아니라 멈춘다", async () => {
    const rec = record("c1", 3);
    const meet = fakeMeet({
      hosted: [rec],
      listTranscriptsFails: () => new GoogleApiError("Meet 요청 실패 (403 rateLimitExceeded)", 403, "rateLimitExceeded"),
    });
    const result = await syncGoogleMeet(connection(), input(meet), fakeDeps().deps, options());
    expect(result.rateLimited).toBe(true);
    expect(result.counts.meet_artifacts_denied).toBeUndefined();
    expect(cursorAfter(result)).toBe(rec.endTime.toISOString());
  });
});

describe("syncGoogleMeet: 참석한 회의 찾기가 실패해도 주최한 회의는 넣는다", () => {
  const hosted = record("h1", 3);
  const setup = (byCode: Record<string, ConferenceRecord[] | "denied" | "rate" | "error"> = {}) => fakeMeet({ hosted: [hosted], byCode, transcripts: { [hosted.name]: [transcriptOf(hosted)] } });

  beforeEach(() => {
    vi.spyOn(console, "error").mockImplementation(() => {});
  });
  afterEach(() => vi.restoreAllMocks());

  it.each([
    ["Calendar 5xx", () => new GoogleApiError("Calendar 요청 실패 (503)", 503)],
    ["Calendar 403 (API를 켜지 않음)", () => new GoogleApiError("Calendar 요청 실패 (403 accessNotConfigured)", 403, "accessNotConfigured")],
    ["네트워크 오류", () => new TypeError("fetch failed")],
  ])("일정 목록 실패(%s): ① 주최한 회의는 넣고, 실패로 세고, 커서는 그 앞(다음에 다시 찾음)에 둔다", async (_name, failure) => {
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection({ after: "2026-10-04T00:00:00.000Z" }), input(setup(), { calendar: fakeCalendar([], () => failure()) }), deps, options());
    expect(inserted).toHaveLength(1);
    expect(result.counts).toMatchObject({ meet_transcripts: 1, meet_attended_failed: 1 });
    expect(cursorAfter(result)).toBe("2026-10-04T00:00:00.000Z");
    expect(result.rateLimited).toBe(false);
  });

  it("회의 코드 하나의 조회가 서버 오류여도 나머지 코드는 조회하고 그 일정은 다음에 다시 본다", async () => {
    const events = [calendarEvent("bad", { conferenceId: "bad-code-one", start: new Date("2026-10-05T07:00:00Z") }), calendarEvent("ok", { conferenceId: "abc-defg-hij" })];
    const attended = record("a1", 2);
    const meet = fakeMeet({ hosted: [], byCode: { "bad-code-one": "error", "abc-defg-hij": [attended] }, transcripts: { [attended.name]: [transcriptOf(attended)] } });
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet, { calendar: fakeCalendar(events) }), deps, options());
    expect(inserted).toHaveLength(1);
    expect(result.counts).toMatchObject({ meet_attended_codes: 2, meet_attended_failed: 1, meet_transcripts_attended: 1 });
    expect(cursorAfter(result)).toBe("2026-10-05T07:00:00.000Z");
  });

  it("일정을 다 읽지 못했으면(다음 쪽이 남음) 읽은 마지막 일정 시작에, 읽은 일정이 없으면 커서에 둔다", async () => {
    const e1 = calendarEvent("e1", { conferenceId: "aaa-aaaa-aaa", start: new Date("2026-10-05T08:00:00Z"), end: new Date("2026-10-05T08:30:00Z") });
    const e2 = calendarEvent("e2", { conferenceId: "bbb-bbbb-bbb", start: new Date("2026-10-05T09:00:00Z"), end: new Date("2026-10-05T09:30:00Z") });
    const partial = await syncGoogleMeet(connection(), input(setup(), { calendar: fakeCalendar([], undefined, [[e1, e2], [calendarEvent("e3")]]) }), fakeDeps().deps, options({ maxEventPages: 1 }));
    expect(cursorAfter(partial)).toBe("2026-10-05T09:00:00.000Z");

    // 첫 쪽에 쓸 수 있는 일정이 하나도 없어도 다음 쪽이 남았으면 커서는 지나가지 않는다
    const empty = await syncGoogleMeet(connection({ after: "2026-10-04T00:00:00.000Z" }), input(setup(), { calendar: fakeCalendar([], undefined, [[], [e1]]) }), fakeDeps().deps, options({ maxEventPages: 1 }));
    expect(cursorAfter(empty)).toBe("2026-10-04T00:00:00.000Z");
  });

  it("전사에 붙일 일정 조회가 네트워크 오류(fetch 실패 · 시간 초과)여도 동기화를 멈추지 않는다: 일정 없이 넣고 실패로 센다", async () => {
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(setup(), { calendar: fakeCalendar([], () => new TypeError("fetch failed")), listAttended: false }), deps, options());
    expect(inserted).toHaveLength(1);
    expect(inserted[0].meeting).toBeUndefined();
    expect(result.counts).toEqual({ meet_transcripts: 1, meet_link_failed: 1 });
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).toContain("네트워크");
  });

  it("회의 공간 조회(spaces.get)가 서버 오류여도 마찬가지다", async () => {
    const meet = setup();
    vi.mocked(meet.meetingCode).mockRejectedValueOnce(new GoogleApiError("Meet 요청 실패 (503)", 503));
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet, { calendar: fakeCalendar([]), listAttended: false }), deps, options());
    expect(inserted).toHaveLength(1);
    expect(result.counts).toEqual({ meet_transcripts: 1, meet_link_failed: 1 });
  });
});

describe("syncGoogleMeet: 넣지 못한 전사의 개수", () => {
  it("포기한 전사(STARTED로 2시간 넘게 남음)와 항목이 빈 전사를 센다", async () => {
    const abandoned = record("stuck", 5);
    const empty = record("empty", 4);
    const normal = record("normal", 3);
    const meet = fakeMeet({
      hosted: [abandoned, empty, normal],
      transcripts: { [abandoned.name]: [transcriptOf(abandoned, "STARTED")], [empty.name]: [transcriptOf(empty)], [normal.name]: [transcriptOf(normal)] },
    });
    vi.mocked(meet.listEntries).mockResolvedValueOnce([]);
    const { deps, inserted } = fakeDeps();
    const result = await syncGoogleMeet(connection(), input(meet), deps, options());
    expect(inserted.map((i) => i.externalId)).toEqual(["conferenceRecords/normal/transcripts/t1"]);
    expect(result.counts).toEqual({ meet_transcripts: 1, meet_transcripts_abandoned: 1, meet_transcripts_short: 1 });
    expect(cursorAfter(result)).toBe("2026-10-05T11:30:00.000Z");
  });
});

describe("parseGoogleCursor · 예산", () => {
  it("커서 형식이 다르면 null (첫 동기화처럼)", () => {
    expect(parseGoogleCursor({ after: "2026-10-05T00:00:00.000Z" })).toEqual({ after: "2026-10-05T00:00:00.000Z" });
    expect(parseGoogleCursor({ after: "yesterday" })).toBeNull();
    expect(parseGoogleCursor(null)).toBeNull();
  });

  it("한 동기화의 Meet 요청 예산은 분당 600건 안이다", () => {
    expect(MEET_REQUEST_BUDGET).toBeLessThan(600);
  });
});
