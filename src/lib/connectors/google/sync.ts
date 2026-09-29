import { z } from "zod";

import { ingestItems, type IngestDeps } from "../ingest";
import type { Connection, ConnectorSyncResult, IngestItem } from "../types";

import { CALENDAR_CODE_FIELDS, lookupMeetingEvent, type CalendarClient, type CalendarEvent, type MeetingEvent } from "./calendar";
import { MeetBudgetExhausted, type ConferenceRecord, type MeetClient, type MeetParticipant, type Transcript, type TranscriptEntry } from "./meet";
import { transcriptToItem, type TranscriptUser } from "./transcript";
import { GoogleApiError, GoogleReauthError } from "./token";
import { LIST_ATTENDED_MEETINGS } from "./unverified";

// google 연결 하나의 Meet 전사 동기화 (G2 · G3 · G5, docs/go-live/google-integration.md 2-5).
// 1) 끝난 회의 기록을 찾는다: ① 주최한 회의(`end_time`이 커서 이후) ② 참석한 회의(Calendar의 Meet 일정 회의 코드로, LIST_ATTENDED_MEETINGS).
// 2) 오래된 회의 기록부터 전사를 나열하고, 이미 넣은 전사는 항목 · 참가자 · 일정을 부르지 않는다. FILE_GENERATED만 넣는다(ENDED는 2시간까지 기다린다).
//    넣을 전사가 한 동기화 상한(20건)에 차거나 나열한 기록이 상한(150건)에 차면 거기서 멈추고 나머지는 다음에 본다.
// 3) 전사 항목 · 참가자 · 같은 회의의 일정을 받아 원문으로 넣는다 (일정 자체는 저장하지 않는다).
// 커서 = 이보다 먼저 끝난 회의 기록은 모두 결정됐다(넣음 · 전사 없음 · 파일이 안 생김 · 볼 수 없음). 아직 결정하지 못한 회의 기록이 있으면 그 끝 시각까지만 옮긴다.

export const googleCursorSchema = z.object({ after: z.iso.datetime() });
export type GoogleCursor = z.infer<typeof googleCursorSchema>;

export type GoogleSyncOptions = {
  now: Date;
  /** 첫 동기화 때 거슬러 올라갈 기간 */
  lookbackDays: number;
  /** 커서를 이보다 오래 뒤로 두지 않는다: 전사 항목은 회의가 끝난 뒤 30일에 지워진다 (9장) */
  maxGapDays: number;
  /** 커서를 지금보다 이만큼 앞에 둔다 (방금 끝난 회의가 목록에 늦게 나와도 놓치지 않게. 이미 넣은 전사는 외부 id로 걸러진다) */
  overlapMs: number;
  /** 회의가 끝난 뒤 이 시간이 지나도 전사 파일이 안 생기면(ENDED) 전사 항목으로 넣고, 그 밖의 상태는 포기한다 (파일 생성 시간은 Google이 정하지 않았다) */
  fileWaitMs: number;
  /** 한 동기화에서 넣는 최대 전사 수 (넣기 공통 상한과 같게) */
  maxItems: number;
  /** 한 동기화에서 전사를 나열하는 최대 회의 기록 수 (전사가 없는 회의가 많아도 요청 예산을 다 쓰지 않게) */
  maxRecordsListed: number;
  /** 한 동기화에서 참석한 회의 코드를 조회하는 최대 수 */
  maxAttendedCodes: number;
  /**
   * 참석한 회의를 Calendar 일정으로 찾을 때 커서보다 이만큼 앞의 일정부터 읽는다: 일정의 예정 끝 시각은 실제로 회의가 끝난 시각보다 빠를 수 있어
   * (회의가 예정보다 길어지거나 전사 파일을 기다리는 동안) 커서가 회의 끝 시각에 머물면 그 일정이 더는 목록에 나오지 않는다.
   */
  attendedLookbackMs: number;
  /** 일정 조회 쪽 크기와 최대 쪽 수 (참석한 회의 코드를 모을 때) */
  eventPageSize: number;
  maxEventPages: number;
  deadline?: number;
};

const DAY_MS = 86_400_000;

export const DEFAULT_GOOGLE_SYNC: Omit<GoogleSyncOptions, "now"> = {
  lookbackDays: 14,
  maxGapDays: 29,
  overlapMs: 30 * 60_000,
  fileWaitMs: 2 * 3_600_000,
  maxItems: 20,
  maxRecordsListed: 150,
  maxAttendedCodes: 40,
  attendedLookbackMs: DAY_MS,
  eventPageSize: 250,
  maxEventPages: 4,
};

/** 한 동기화의 Meet 요청 예산 (사용자당 분당 600건의 여유, 9장 "Meet 한도") */
export const MEET_REQUEST_BUDGET = 400;

/**
 * 이번 동기화의 개수 (연결 설정 stats에 더한다, 글자 · 주소 없이): 넣은 전사, 일정 잇기 결과(붙음 · 애매 · 없음 · 실패),
 * 참석한 회의 찾기 결과, 넣지 못한 전사(볼 수 없음 · 포기 · 너무 짧음)
 */
export type GoogleSyncCounts = Partial<
  Record<
    | "meet_transcripts"
    | "meet_transcripts_attended"
    | "meet_transcripts_abandoned"
    | "meet_transcripts_short"
    | "meet_link_attached"
    | "meet_link_ambiguous"
    | "meet_link_none"
    | "meet_link_failed"
    | "meet_attended_codes"
    | "meet_attended_denied"
    | "meet_attended_failed"
    | "meet_artifacts_denied",
    number
  >
>;

export type GoogleSyncResult = ConnectorSyncResult & { cursor: GoogleCursor | null; counts: GoogleSyncCounts; rateLimited: boolean };

export type GoogleSyncInput = {
  /** 이용자가 허용한 기능 (G10): 허용하지 않은 쪽은 부르지 않는다 */
  meet: boolean;
  /** 참석한 회의도 찾는가 (G2 ②, 기본 LIST_ATTENDED_MEETINGS). Calendar가 없으면 찾을 수 없다 */
  listAttended?: boolean;
  /** Calendar를 허용했으면 조회 클라이언트 (참석한 회의 코드 · 같은 회의 일정). 아니면 null */
  calendar: CalendarClient | null;
  meetApi: MeetClient;
  /** 사용자: 프로필 이름 · 별칭 · 연결한 Google 주소 · 연결한 계정의 sub */
  me: TranscriptUser;
};

/** 저장된 커서. 형식이 다르면 null: 첫 동기화처럼 */
export function parseGoogleCursor(cursor: Record<string, unknown> | null): GoogleCursor | null {
  const parsed = googleCursorSchema.safeParse(cursor);
  return parsed.success ? parsed.data : null;
}

/** 속도 제한: 429, 또는 403 + rateLimitExceeded · userRateLimitExceeded */
const isRateLimited = (error: unknown) =>
  error instanceof GoogleApiError &&
  (error.status === 429 || (error.status === 403 && ["rateLimitExceeded", "userRateLimitExceeded", "RESOURCE_EXHAUSTED"].includes(error.reason ?? "")));

/**
 * 이 회의 기록의 전사 · 항목 · 참가자, 또는 참석한 회의 목록을 볼 수 없다 (403 · 404: 참석자에게 주지 않는 자료, 만료된 기록).
 * 동기화를 실패시키지 않고 못 본 것으로 세고 결정한 것으로 넘어간다 (G2: 참석자가 볼 수 있는 자료가 어디까지인지는 dev 확인 전이다).
 */
const isNotVisible = (error: unknown) => error instanceof GoogleApiError && (error.status === 403 || error.status === 404) && !isRateLimited(error);

/** 일부러 잡지 않고 올리는 오류: 토큰 만료(연결을 reauth로), 속도 제한 · 요청 예산(여기서 멈춘다) */
const isFatal = (error: unknown) => error instanceof GoogleReauthError || error instanceof MeetBudgetExhausted || isRateLimited(error);

class Stop extends Error {}

/** Meet 회의 코드 모양 (aaa-bbbb-ccc) */
const MEETING_CODE_SHAPE = /^[A-Za-z0-9-]{3,64}$/;

type FoundRecord = { record: ConferenceRecord; via: "hosted" | "attended" };

export async function syncGoogleMeet(
  connection: Connection,
  input: GoogleSyncInput,
  deps: IngestDeps,
  options: GoogleSyncOptions,
): Promise<GoogleSyncResult> {
  const counts: GoogleSyncCounts = {};
  const count = (key: keyof GoogleSyncCounts, n = 1) => {
    if (n > 0) counts[key] = (counts[key] ?? 0) + n;
  };
  // Meet을 허용하지 않은 연결(Calendar만): 전사를 가져오지 않는다. 커서도 두지 않는다
  if (!input.meet) return { created: [], scanned: 0, skipped: {}, cursor: null, counts, rateLimited: false };

  const now = options.now.getTime();
  const saved = parseGoogleCursor(connection.syncCursor);
  const floor = now - options.maxGapDays * DAY_MS;
  const after = saved ? Math.max(Date.parse(saved.after), floor) : now - options.lookbackDays * DAY_MS;
  const timeUp = () => options.deadline !== undefined && Date.now() > options.deadline;

  /** 아직 결정하지 못한 것: 커서는 이 중 가장 이른 시각까지만 옮긴다 */
  const holds: number[] = [];
  let rateLimited = false;
  const records = new Map<string, FoundRecord>();
  const stopped = (error: unknown) => {
    if (error instanceof MeetBudgetExhausted) return true;
    if (isRateLimited(error)) {
      rateLimited = true;
      return true;
    }
    return false;
  };

  // 1) 회의 기록 찾기
  try {
    for (const record of await input.meetApi.listRecords(`end_time>="${new Date(after).toISOString()}"`)) records.set(record.name, { record, via: "hosted" });

    if ((input.listAttended ?? LIST_ATTENDED_MEETINGS) && input.calendar) {
      await findAttendedRecords(input.calendar, input.meetApi, { after, now, options, records, count, hold: (at) => holds.push(at), timeUp });
    }
  } catch (error) {
    if (!stopped(error)) throw error;
    // 찾기를 마치지 못했다: 이번에 찾은 것만 처리하고 커서는 옮기지 않는다
    holds.push(after);
  }

  const ordered = [...records.values()].sort((a, b) => a.record.endTime.getTime() - b.record.endTime.getTime());

  // 2) 전사 고르기: 오래된 회의 기록부터 전사를 나열한다. 넣을 전사가 상한에 차면 멈춘다 (전사가 없는 회의가 많아도 나열이 예산을 다 쓰지 않는다)
  const ready: { found: FoundRecord; transcript: Transcript }[] = [];
  let listed = 0;
  let scanned = 0;
  let alreadyIngested = 0;
  try {
    for (const found of ordered) {
      if (timeUp()) throw new Stop();
      if (listed >= options.maxRecordsListed || ready.length >= options.maxItems) {
        holds.push(found.record.endTime.getTime());
        break;
      }
      let transcripts: Transcript[];
      try {
        transcripts = await input.meetApi.listTranscripts(found.record.name);
      } catch (error) {
        if (!isNotVisible(error)) throw error;
        count("meet_artifacts_denied");
        transcripts = [];
      }
      scanned += transcripts.length;
      const already = transcripts.length > 0 ? await deps.ingestedIds(connection, transcripts.map((t) => t.name)) : new Set<string>();
      const endedAt = found.record.endTime.getTime();
      const waited = now - endedAt >= options.fileWaitMs;
      for (const transcript of transcripts) {
        if (already.has(transcript.name)) {
          alreadyIngested++;
        } else if (transcript.state === "FILE_GENERATED" || (transcript.state === "ENDED" && waited)) {
          // 파일이 생겼다. 또는 ENDED인데 2시간이 지나도 파일이 안 생겨 전사 항목으로 넣는다
          ready.push({ found, transcript });
        } else if (!waited) {
          holds.push(endedAt);
        } else {
          // STARTED · 알 수 없는 상태로 2시간이 지났다: 포기한다 (결정)
          count("meet_transcripts_abandoned");
        }
      }
      listed++;
    }
  } catch (error) {
    if (!(error instanceof Stop) && !stopped(error)) throw error;
    // 나열하지 못한 회의 기록은 다음에 다시 본다 (전사가 없는 회의 기록도 나열을 마친 것이다)
    if (ordered[listed]) holds.push(ordered[listed].record.endTime.getTime());
  }
  // 넣기 상한: 넘친 것은 다음에
  for (const overflow of ready.splice(options.maxItems)) holds.push(overflow.found.record.endTime.getTime());

  // 3) 전사 항목 · 참가자 · 같은 회의의 일정 → 원문
  const items: { item: IngestItem; found: FoundRecord; link: LinkResult }[] = [];
  const processed = new Set<string>();
  try {
    for (const { found, transcript } of ready) {
      if (timeUp()) throw new Stop();
      let entries: TranscriptEntry[];
      let participants: MeetParticipant[];
      try {
        [entries, participants] = await Promise.all([input.meetApi.listEntries(transcript.name), input.meetApi.listParticipants(found.record.name)]);
      } catch (error) {
        if (!isNotVisible(error)) throw error;
        count("meet_artifacts_denied");
        processed.add(transcript.name);
        continue;
      }
      const { event, link } = await findEvent(input, found.record, transcript);
      const item = transcriptToItem({ record: found.record, transcript, entries, participants, event, me: input.me });
      if (item) items.push({ item, found, link });
      else count("meet_transcripts_short");
      processed.add(transcript.name);
    }
  } catch (error) {
    if (!(error instanceof Stop) && !stopped(error)) throw error;
    for (const { found, transcript } of ready) {
      if (!processed.has(transcript.name)) holds.push(found.record.endTime.getTime());
    }
  }

  // 4) 넣기. 넣은 원문(insertSource가 저장한 것)만 센다
  const inserted = new Set<string>();
  const counted: IngestDeps = {
    ...deps,
    insertSource: async (c, item) => {
      const id = await deps.insertSource(c, item);
      if (id) inserted.add(item.externalId);
      return id;
    },
  };
  const result = await ingestItems(
    connection,
    items.map(({ item }) => item),
    counted,
    { now: options.now, settleMinutes: 0, maxItems: options.maxItems, minTextLength: 30, deadline: options.deadline },
  );
  const notReached = new Set(result.notReached);
  for (const { item, found } of items) {
    // 시간 한도로 넣지 못했거나, 서버 시계보다 뒤의 시각이라 안정화 중으로 건너뛴 전사는 다음에 다시 본다
    if (notReached.has(item.externalId) || item.lastEditedAt > options.now) holds.push(found.record.endTime.getTime());
  }

  count("meet_transcripts", inserted.size);
  count("meet_transcripts_short", result.skipped.tooShort);
  for (const { item, found, link } of items) {
    if (!inserted.has(item.externalId)) continue;
    if (found.via === "attended") count("meet_transcripts_attended");
    if (link) count(`meet_link_${link}`);
  }

  const next = holds.length > 0 ? Math.min(...holds) : now - options.overlapMs;
  return {
    created: result.created,
    scanned,
    skipped: { alreadyIngested: alreadyIngested + result.skipped.alreadyIngested, tooShort: result.skipped.tooShort, overLimit: result.skipped.overLimit },
    // 뒤로 가지 않는다
    cursor: { after: new Date(Math.max(next, after)).toISOString() },
    counts,
    rateLimited,
  };
}

type LinkResult = "attached" | "ambiguous" | "none" | "failed" | null;

/**
 * 같은 회의의 일정을 찾는다 (G3). Calendar를 허용하지 않았으면 찾지 않는다(null). 조회가 실패하면(서버 오류 · 네트워크 · 시간 초과) 일정 없이 넣는다(2-4 6).
 * 속도 제한 · 요청 예산은 멈추고(여기서 일정 없이 넣으면 그 전사는 일정을 다시 붙일 수 없다), 토큰 만료는 연결을 reauth로 보낸다.
 */
async function findEvent(input: GoogleSyncInput, record: ConferenceRecord, transcript: Transcript): Promise<{ event: MeetingEvent | null; link: LinkResult }> {
  if (!input.calendar || !record.space) return { event: null, link: null };
  try {
    const meetingCode = await input.meetApi.meetingCode(record.space);
    if (!meetingCode) return { event: null, link: "none" };
    const lookup = await lookupMeetingEvent(input.calendar, { kind: "meet", meetingCode, start: transcript.startTime ?? record.startTime }, input.me);
    return { event: lookup.result === "attached" ? lookup.event : null, link: lookup.result };
  } catch (error) {
    if (isFatal(error)) throw error;
    // 상태와 이유만 남긴다 (본문 · 주소 없음)
    console.error(error instanceof GoogleApiError ? `Meet 전사의 일정 조회 실패 (${error.status}${error.reason ? ` ${error.reason}` : ""})` : "Meet 전사의 일정 조회 실패 (네트워크)");
    return { event: null, link: "failed" };
  }
}

type AttendedContext = {
  after: number;
  now: number;
  options: GoogleSyncOptions;
  records: Map<string, FoundRecord>;
  count: (key: keyof GoogleSyncCounts, n?: number) => void;
  hold: (at: number) => void;
  timeUp: () => boolean;
};

/**
 * G2 ②: 커서 앞 하루부터 지금까지의 Calendar 일정 중 사용자가 주최하지 않은 Meet 일정의 회의 코드로 회의 기록을 찾는다
 * (일정의 예정 끝이 실제 회의 끝보다 빠를 수 있어 앞을 넉넉히 읽는다). 회의 코드만 쓰고 일정은 저장하지 않는다(G3): 제목 · 참석자 이메일은 받지도 않는다.
 * 참석자에게 회의 기록을 안 주면(403 · 404) 못 본 것으로 세고 넘어간다: 처리방침 문구를 "내가 주최한 회의"로 적는다.
 * 일정 목록 · 회의 코드 조회가 그 밖의 이유로 실패하면 실패로 세고 ① 주최한 회의는 그대로 넣는다: 커서는 그 앞에 두어 다음에 다시 찾는다.
 */
async function findAttendedRecords(calendar: CalendarClient, meetApi: MeetClient, context: AttendedContext): Promise<void> {
  const { after, now, options, records, count, hold, timeUp } = context;
  const events: CalendarEvent[] = [];
  let pageToken: string | undefined;
  try {
    for (let n = 0; n < options.maxEventPages; n++) {
      const page = await calendar.list({
        timeMin: new Date(after - options.attendedLookbackMs),
        timeMax: new Date(now),
        maxResults: options.eventPageSize,
        pageToken,
        fields: CALENDAR_CODE_FIELDS,
      });
      events.push(...page.events);
      pageToken = page.nextPageToken ?? undefined;
      if (!pageToken) break;
    }
  } catch (error) {
    if (isFatal(error)) throw error;
    console.error(error instanceof GoogleApiError ? `참석한 회의 일정 목록 실패 (${error.status}${error.reason ? ` ${error.reason}` : ""})` : "참석한 회의 일정 목록 실패 (네트워크)");
    count("meet_attended_failed");
    hold(after);
    return;
  }
  // 못 다 읽었으면 읽은 마지막 일정 뒤는 다음에 다시 본다 (읽은 일정이 없으면 커서 그대로)
  if (pageToken) hold(events.length > 0 ? events[events.length - 1].start.getTime() : after);

  // 회의 코드마다 가장 이른 일정 하나 (반복 일정은 같은 코드): 회의 기록은 그 일정 시작 하루 전부터 찾는다
  const codes = new Map<string, CalendarEvent>();
  for (const event of events) {
    if (event.organizerSelf || event.conferenceType !== "hangoutsMeet" || !event.conferenceId) continue;
    // 초대한 사람이 정하는 값이 목록 조건(filter)에 들어가므로 회의 코드 모양(영문자 · 숫자 · 하이픈)만 쓴다
    if (!MEETING_CODE_SHAPE.test(event.conferenceId)) continue;
    const key = event.conferenceId.toLowerCase();
    if (!codes.has(key)) codes.set(key, event);
  }

  let looked = 0;
  for (const [code, event] of codes) {
    if (looked >= options.maxAttendedCodes || timeUp()) {
      hold(event.start.getTime());
      continue;
    }
    looked++;
    try {
      const found = await meetApi.listRecords(`space.meeting_code = "${code}" AND start_time>="${new Date(event.start.getTime() - DAY_MS).toISOString()}"`);
      for (const record of found) {
        // 커서 뒤에 끝난 회의 기록만 (목록 조건은 시작 시각이다). 주최한 회의로 이미 찾았으면 그대로 둔다
        if (record.endTime.getTime() >= after && !records.has(record.name)) records.set(record.name, { record, via: "attended" });
      }
    } catch (error) {
      if (isFatal(error)) {
        hold(event.start.getTime());
        count("meet_attended_codes", looked);
        throw error;
      }
      if (isNotVisible(error)) {
        count("meet_attended_denied");
      } else {
        console.error(error instanceof GoogleApiError ? `참석한 회의 기록 조회 실패 (${error.status}${error.reason ? ` ${error.reason}` : ""})` : "참석한 회의 기록 조회 실패 (네트워크)");
        count("meet_attended_failed");
        hold(event.start.getTime());
      }
    }
  }
  count("meet_attended_codes", looked);
}
