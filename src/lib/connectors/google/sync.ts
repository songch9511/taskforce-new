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
// 커서 = 이보다 먼저 끝난 회의 기록은 모두 결정됐다(넣음 · 전사 없음 · 파일이 안 생김 · 볼 수 없음 · 읽지 못함). 아직 결정하지 못한 회의 기록이 있으면 그 끝 시각까지만 옮긴다.
// 결정한 것(seen)은 커서에 남겨 다음 동기화가 다시 세거나 다시 부르지 않는다:
//   r:{회의 기록} 전사를 모두 결정한 기록 · t:{전사} 넣지 않기로 한 전사(포기 · 짧음 · 볼 수 없음 · 읽지 못함) · e:{일정} 회의 코드 조회를 마친 참석 일정.
// 오류는 갈래대로 다룬다: 토큰 만료 · 속도 제한 · 요청 예산은 멈춤(fatal), 403 · 404는 볼 수 없는 자료(not visible), 그 밖의 400번대는 다시 해도 같은 결과(permanent, 커서를 붙잡지 않는다),
// 서버 오류 · 네트워크 오류는 일시 오류(transient, 다음에 다시 보되 커서를 붙잡는 시간에 상한이 있다).

export const googleCursorSchema = z.object({
  after: z.iso.datetime(),
  /** 결정한 것 → 그 항목이 목록에 다시 나올 수 있는 마지막 시각(ms). 커서가 그 시각을 지나면 지운다 */
  seen: z.record(z.string(), z.number()).default({}),
  /** 일시 오류가 난 회의 기록 · 전사: 실패 횟수(n) · 처음 센 실패의 시각(first) · 지울 시각(until) */
  fails: z.record(z.string(), z.object({ n: z.number(), first: z.number(), until: z.number() })).default({}),
});
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
  /**
   * 일정이 끝난 뒤 이 시간이 지나야 그 일정의 회의 코드 조회를 마친 것으로 본다(seen): 그 전에는 매 동기화가 다시 조회한다
   * (예정보다 길어진 회의가 늦게 끝나 목록에 나올 수 있다). 예정보다 이보다 더 길어진 회의는 이 길로 찾지 못한다.
   */
  attendedSettleMs: number;
  /** 일정 조회 쪽 크기와 최대 쪽 수 (참석한 회의 코드를 모을 때) */
  eventPageSize: number;
  maxEventPages: number;
  /**
   * 서버 오류 · 네트워크 오류로 미룬 것이 커서를 붙잡는 최대 시간: 처음 실패한 때부터 이 시간이 지나면 더 붙잡지 않는다
   * (회의 기록 · 전사 · 참석 일정은 읽지 못한 것으로 결정하고, 일정 목록은 ① 주최한 회의만 진행한다). Google 서버 장애는 대개 몇 시간 안에 끝나고,
   * 붙잡는 동안에도 새 전사는 계속 넣으며(커서는 다시 훑는 시작점일 뿐이다) 참석한 회의는 일정을 하루 앞부터 읽으므로 그만큼 더 견딘다.
   */
  holdCapMs: number;
  /** 같은 전사 · 회의 기록이 일시 오류로 이만큼 여러 동기화에서 실패하고 처음 실패에서 failureSpanMs가 지나면(파일 기다림 뒤) 읽지 못한 것으로 결정한다 */
  failureTries: number;
  failureSpanMs: number;
  /** 커서에 남기는 결정 표시(seen) 최대 수: 넘으면 오래된 것부터 뺀다 */
  maxSeen: number;
  deadline?: number;
};

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;

export const DEFAULT_GOOGLE_SYNC: Omit<GoogleSyncOptions, "now"> = {
  lookbackDays: 14,
  maxGapDays: 29,
  overlapMs: 30 * 60_000,
  fileWaitMs: 2 * HOUR_MS,
  maxItems: 20,
  maxRecordsListed: 150,
  maxAttendedCodes: 40,
  attendedLookbackMs: DAY_MS,
  attendedSettleMs: 3 * HOUR_MS,
  eventPageSize: 250,
  maxEventPages: 4,
  holdCapMs: 6 * HOUR_MS,
  failureTries: 3,
  failureSpanMs: HOUR_MS,
  maxSeen: 500,
};

/** 한 동기화의 Meet 요청 예산 (사용자당 분당 600건의 여유, 9장 "Meet 한도") */
export const MEET_REQUEST_BUDGET = 400;

/**
 * 이번 동기화의 개수 (연결 설정 stats에 더한다, 글자 · 주소 없이): 넣은 전사, 일정 잇기 결과(붙음 · 애매 · 없음 · 실패),
 * 참석한 회의 찾기 결과, 넣지 못한 전사(볼 수 없음 · 읽지 못함 · 포기 · 너무 짧음). 넣지 않기로 결정한 것은 한 번만 센다(결정 표시 seen).
 */
export type GoogleSyncCounts = Partial<
  Record<
    | "meet_transcripts"
    | "meet_transcripts_attended"
    | "meet_transcripts_abandoned"
    | "meet_transcripts_short"
    | "meet_transcripts_failed"
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

/**
 * 다시 해도 같은 결과인 요청 오류: 400번대(속도 제한 429 · 시간 초과 408 · 토큰 401은 제외). 403 · 404(볼 수 없음)도 여기 든다.
 * Calendar API를 켜지 않았거나(accessNotConfigured) 권한이 없으면 몇 번을 다시 해도 같으므로 커서를 붙잡지 않는다.
 * 401은 토큰 창구가 한 번 갱신해 다시 불러도 나온 것이지만 Google 쪽 일시 문제일 수 있어 일시 오류로 본다(6시간 상한이 붙잡는 시간을 막는다).
 * 토큰이 정말 거둬졌으면 갱신이 실패해 GoogleReauthError가 되므로 여기까지 오지 않는다. 409(충돌)는 다시 해도 같은 것으로 본다.
 */
const isPermanent = (error: unknown) =>
  error instanceof GoogleApiError &&
  error.status >= 400 &&
  error.status < 500 &&
  error.status !== 401 &&
  error.status !== 408 &&
  error.status !== 429 &&
  !isRateLimited(error);

/** 일부러 잡지 않고 올리는 오류: 토큰 만료(연결을 reauth로), 속도 제한 · 요청 예산(여기서 멈춘다) */
const isFatal = (error: unknown) => error instanceof GoogleReauthError || error instanceof MeetBudgetExhausted || isRateLimited(error);

/** 로그에 남기는 오류 설명: 상태와 이유만 (본문 · 주소 없음) */
const errorLabel = (error: unknown) => (error instanceof GoogleApiError ? `${error.status}${error.reason ? ` ${error.reason}` : ""}` : "네트워크");

class Stop extends Error {}

/** Meet 회의 코드 모양 (aaa-bbbb-ccc) */
const MEETING_CODE_SHAPE = /^[A-Za-z0-9-]{3,64}$/;

type FoundRecord = { record: ConferenceRecord; via: "hosted" | "attended" };
type Listed = { found: FoundRecord; transcripts: Transcript[] };
/** Meet 읽기의 종류: 회의 기록의 전사 목록(list) · 전사의 항목 + 참가자(entries) */
type ReadKind = "list" | "entries";
type Ready = { found: FoundRecord; transcript: Transcript };

/** 결정 표시(seen)의 열쇠 */
const recordKey = (record: ConferenceRecord) => `r:${record.name}`;
const transcriptKey = (transcript: Transcript) => `t:${transcript.name}`;
const eventKey = (event: CalendarEvent) => `e:${event.id}`;
/** 일정 목록 실패 기록의 열쇠 (fails) */
const LIST_FAILURE_KEY = "l:events";

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
  const seen = new Map(Object.entries(saved?.seen ?? {}));
  const fails = new Map(Object.entries(saved?.fails ?? {}));
  const timeUp = () => options.deadline !== undefined && Date.now() > options.deadline;

  /** 아직 결정하지 못한 것: 커서는 이 중 가장 이른 시각까지만 옮긴다 */
  const holds: number[] = [];
  /** 결정하지 못한 회의 기록: 이 기록을 찾아 준 일정은 조회를 마친 것으로 보지 않는다 */
  const heldNames = new Set<string>();
  const holdRecord = (found: FoundRecord) => {
    heldNames.add(found.record.name);
    holds.push(found.record.endTime.getTime());
  };
  /**
   * 서버 오류 · 네트워크 오류(일시 오류)를 기록한다: 처음 실패한 시각 · 횟수는 커서(fails)에 남는다. 처음 실패한 지 holdCapMs가 지났으면 stale:
   * 더 붙잡지 않는다. 횟수를 세지 않는 실패(장애로 본 것)는 시각만 남긴다. until = 커서가 이 시각을 지나면 기록을 지운다
   */
  const noteFailure = (key: string, until: number, counted = true) => {
    const previous = fails.get(key);
    const entry = { n: (previous?.n ?? 0) + (counted ? 1 : 0), first: previous?.first ?? now, until };
    fails.set(key, entry);
    return { ...entry, stale: now - entry.first >= options.holdCapMs };
  };
  let rateLimited = false;
  const records = new Map<string, FoundRecord>();
  const attendedLookups: AttendedLookup[] = [];
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
      await findAttendedRecords(input.calendar, input.meetApi, {
        after,
        now,
        options,
        records,
        seen,
        lookups: attendedLookups,
        fails,
        noteFailure,
        count,
        hold: (at) => holds.push(at),
        timeUp,
      });
    }
  } catch (error) {
    if (!stopped(error)) throw error;
    // 찾기를 마치지 못했다: 이번에 찾은 것만 처리하고 커서는 옮기지 않는다
    holds.push(after);
  }

  // 전사를 모두 결정한 기록(r:)은 다시 나열하지 않는다
  const todo = [...records.values()]
    .filter(({ record }) => !seen.has(recordKey(record)))
    .sort((a, b) => a.record.endTime.getTime() - b.record.endTime.getTime());

  // 2) 전사 고르기: 오래된 회의 기록부터 전사를 나열한다. 넣을 전사가 상한에 차면 멈춘다 (전사가 없는 회의가 많아도 나열이 예산을 다 쓰지 않는다)
  const ready: Ready[] = [];
  const listedRecords: Listed[] = [];
  /** 일시 오류로 읽지 못한 회의 기록(list) · 전사(entries): 3) 뒤에 다시 시도할지 포기할지 정한다 */
  const failures: { kind: ReadKind; key: string; found: FoundRecord }[] = [];
  /** 성공한 Meet 읽기: 같은 종류의 읽기가 하나도 성공하지 못하면 개별 문제가 아니라 장애로 본다 */
  const readsOk: Record<ReadKind, number> = { list: 0, entries: 0 };
  let next = 0;
  let scanned = 0;
  let alreadyIngested = 0;

  /** 한 회의 기록의 전사를 나열한다. 오류는 갈래대로 다루고(볼 수 없음 · 읽지 못함은 결정), 멈춰야 하는 오류만 던진다 */
  const listTranscripts = async (found: FoundRecord): Promise<Transcript[]> => {
    const { record } = found;
    try {
      const transcripts = await input.meetApi.listTranscripts(record.name);
      readsOk.list++;
      fails.delete(recordKey(record));
      return transcripts;
    } catch (error) {
      if (isFatal(error)) throw error;
      if (isNotVisible(error)) {
        count("meet_artifacts_denied");
        seen.set(recordKey(record), record.endTime.getTime());
      } else if (isPermanent(error)) {
        console.error(`Meet 전사 목록 실패 (${errorLabel(error)})`);
        count("meet_transcripts_failed");
        seen.set(recordKey(record), record.endTime.getTime());
      } else {
        console.error(`Meet 전사 목록 실패 (${errorLabel(error)}): 다음에 다시 봅니다`);
        failures.push({ kind: "list", key: recordKey(record), found });
      }
      return [];
    }
  };

  /** 한 회차에 나열한 전사를 이미 넣은 것과 대 본다 (넣은 전사를 한 번에 묻는다) → 넣을 것 · 기다릴 것 · 포기할 것 */
  const classify = async (round: Listed[]) => {
    const names = round.flatMap(({ transcripts }) => transcripts.filter((t) => !seen.has(transcriptKey(t))).map((t) => t.name));
    const already = names.length > 0 ? await deps.ingestedIds(connection, names) : new Set<string>();
    for (const { found, transcripts } of round) {
      scanned += transcripts.length;
      const endedAt = found.record.endTime.getTime();
      const waited = now - endedAt >= options.fileWaitMs;
      for (const transcript of transcripts) {
        if (seen.has(transcriptKey(transcript))) {
          // 전에 넣지 않기로 결정했다
        } else if (already.has(transcript.name)) {
          alreadyIngested++;
        } else if (transcript.state === "FILE_GENERATED" || (transcript.state === "ENDED" && waited)) {
          // 파일이 생겼다. 또는 ENDED인데 2시간이 지나도 파일이 안 생겨 전사 항목으로 넣는다
          ready.push({ found, transcript });
        } else if (!waited) {
          holdRecord(found);
        } else {
          // STARTED · 알 수 없는 상태로 2시간이 지났다: 포기한다 (결정)
          count("meet_transcripts_abandoned");
          seen.set(transcriptKey(transcript), endedAt);
        }
      }
    }
  };

  try {
    while (next < todo.length) {
      if (timeUp()) throw new Stop();
      if (next >= options.maxRecordsListed || ready.length >= options.maxItems) break;
      // 넣을 자리가 남은 만큼의 회의 기록을 나열한 뒤 이미 넣은 전사를 한 번에 묻는다 (기록마다 묻지 않는다)
      const round: Listed[] = [];
      const room = Math.min(options.maxItems - ready.length, options.maxRecordsListed - next);
      let interrupted: unknown = null;
      try {
        while (round.length < room && next < todo.length) {
          if (timeUp()) throw new Stop();
          const found = todo[next];
          round.push({ found, transcripts: await listTranscripts(found) });
          next++;
        }
      } catch (error) {
        interrupted = error;
      }
      await classify(round);
      listedRecords.push(...round);
      if (interrupted) throw interrupted;
    }
  } catch (error) {
    if (!(error instanceof Stop) && !stopped(error)) throw error;
  }
  // 나열하지 못한 회의 기록은 다음에 다시 본다 (전사가 없는 회의 기록도 나열을 마친 것이다)
  const unreached = todo.slice(next);
  if (unreached.length > 0) {
    holdRecord(unreached[0]);
    for (const { record } of unreached) heldNames.add(record.name);
  }
  // 넣기 상한: 넘친 것은 다음에
  for (const overflow of ready.splice(options.maxItems)) holdRecord(overflow.found);

  // 3) 전사 항목 · 참가자 · 같은 회의의 일정 → 원문
  const items: { item: IngestItem; found: FoundRecord; link: LinkResult }[] = [];
  const processed = new Set<string>();
  try {
    for (const { found, transcript } of ready) {
      if (timeUp()) throw new Stop();
      const endedAt = found.record.endTime.getTime();
      let entries: TranscriptEntry[];
      let participants: MeetParticipant[];
      try {
        [entries, participants] = await Promise.all([input.meetApi.listEntries(transcript.name), input.meetApi.listParticipants(found.record.name)]);
        readsOk.entries++;
        fails.delete(transcriptKey(transcript));
      } catch (error) {
        if (isFatal(error)) throw error;
        if (isNotVisible(error)) {
          count("meet_artifacts_denied");
          seen.set(transcriptKey(transcript), endedAt);
        } else if (isPermanent(error)) {
          console.error(`Meet 전사 항목 실패 (${errorLabel(error)})`);
          count("meet_transcripts_failed");
          seen.set(transcriptKey(transcript), endedAt);
        } else {
          console.error(`Meet 전사 항목 실패 (${errorLabel(error)}): 다음에 다시 봅니다`);
          failures.push({ kind: "entries", key: transcriptKey(transcript), found });
        }
        processed.add(transcript.name);
        continue;
      }
      const { event, link } = await findEvent(input, found.record, transcript);
      const item = transcriptToItem({ record: found.record, transcript, entries, participants, event, me: input.me });
      if (item) {
        items.push({ item, found, link });
      } else {
        // 본문이 비었거나 너무 짧다: 넣지 않기로 결정한다
        count("meet_transcripts_short");
        seen.set(transcriptKey(transcript), endedAt);
      }
      processed.add(transcript.name);
    }
  } catch (error) {
    if (!(error instanceof Stop) && !stopped(error)) throw error;
    for (const { found, transcript } of ready) {
      if (!processed.has(transcript.name)) holdRecord(found);
    }
  }

  // 일시 오류로 읽지 못한 것: 다시 시도하되 계속 안 되면 읽지 못한 것으로 결정한다
  // - 처음 실패한 지 holdCapMs가 지났으면 결정한다 (커서를 더는 붙잡지 않는다)
  // - 같은 것이 여러 동기화에서 반복해 실패하고(failureTries) 처음 센 실패에서 failureSpanMs가 지났으면(파일 기다림 뒤) 그것 하나가 문제인 것으로 보고 결정한다.
  //   같은 종류의 다른 Meet 읽기가 이번 동기화에서 하나라도 성공했을 때만 센다: 하나도 성공하지 못했으면(대기 전사가 하나뿐인 흔한 경우 포함) 그것 하나의 문제인지
  //   Google 장애인지 알 수 없으므로 횟수를 세지 않고 6시간 상한(holdCapMs)만 적용한다 (장애 때 멀쩡한 전사를 포기하지 않게)
  const outageOf = (kind: ReadKind) => readsOk[kind] === 0;
  for (const { kind, key, found } of failures) {
    const outage = outageOf(kind);
    const endedAt = found.record.endTime.getTime();
    const failure = noteFailure(key, endedAt, !outage);
    const repeated = !outage && now - endedAt >= options.fileWaitMs && failure.n >= options.failureTries && now - failure.first >= options.failureSpanMs;
    if (failure.stale || repeated) {
      count("meet_transcripts_failed");
      seen.set(key, endedAt);
      fails.delete(key);
    } else {
      holdRecord(found);
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
  // 너무 짧은 전사는 transcriptToItem이 머리줄을 뺀 본문으로 걸러 이미 결정했다
  const result = await ingestItems(
    connection,
    items.map(({ item }) => item),
    counted,
    { now: options.now, settleMinutes: 0, maxItems: options.maxItems, minTextLength: 1, deadline: options.deadline },
  );
  const notReached = new Set(result.notReached);
  for (const { item, found } of items) {
    // 시간 한도로 넣지 못했거나, 서버 시계보다 뒤의 시각이라 안정화 중으로 건너뛴 전사는 다음에 다시 본다
    if (notReached.has(item.externalId) || item.lastEditedAt > options.now) holdRecord(found);
  }

  count("meet_transcripts", inserted.size);
  for (const { item, found, link } of items) {
    if (!inserted.has(item.externalId)) continue;
    if (found.via === "attended") count("meet_transcripts_attended");
    if (link) count(`meet_link_${link}`);
  }

  // 전사를 모두 결정한 회의 기록은 다시 나열하지 않는다. 전사가 없는 기록은 끝난 지 파일 기다림(fileWaitMs)이 지난 뒤에 표시한다:
  // 그 전에는 커서가 지나갈 때까지 목록에 다시 나올 수 있다. 표시하지 않으면 커서가 앞의 미룬 전사에 머무는 동안 나열 상한(150건)을 매번 쓴다
  for (const { found, transcripts } of listedRecords) {
    const waited = now - found.record.endTime.getTime() >= options.fileWaitMs;
    if ((transcripts.length > 0 || waited) && !heldNames.has(found.record.name)) seen.set(recordKey(found.record), found.record.endTime.getTime());
  }
  // 회의 코드 조회를 마친 참석 일정: 그 코드의 회의 기록을 모두 결정했고, 일정이 끝난 지 attendedSettleMs가 지났으면 다시 조회하지 않는다
  for (const { events, names } of attendedLookups) {
    if (names.some((name) => heldNames.has(name))) continue;
    for (const event of events) {
      if (now - event.end.getTime() < options.attendedSettleMs) continue;
      seen.set(eventKey(event), event.end.getTime() + options.attendedLookbackMs);
      count("meet_attended_codes");
    }
  }

  // 뒤로 가지 않는다
  const cursorAt = Math.max(holds.length > 0 ? Math.min(...holds) : now - options.overlapMs, after);
  // 커서가 지나간 것의 표시는 지운다. 너무 많으면 최근 것만 남긴다
  const recent = [...seen].filter(([, until]) => until >= cursorAt).sort((a, b) => b[1] - a[1]).slice(0, options.maxSeen);
  const pending = [...fails].filter(([, failure]) => failure.until >= cursorAt);
  return {
    created: result.created,
    scanned,
    skipped: { alreadyIngested: alreadyIngested + result.skipped.alreadyIngested, tooShort: result.skipped.tooShort, overLimit: result.skipped.overLimit },
    cursor: { after: new Date(cursorAt).toISOString(), seen: Object.fromEntries(recent), fails: Object.fromEntries(pending) },
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
    console.error(`Meet 전사의 일정 조회 실패 (${errorLabel(error)})`);
    return { event: null, link: "failed" };
  }
}

/** 회의 코드 조회에 성공한 참석 일정: 찾은 회의 기록을 모두 결정하면(끝난 지 attendedSettleMs 뒤) 조회를 마친 것으로 표시한다 */
type AttendedLookup = { events: CalendarEvent[]; names: string[] };

type AttendedContext = {
  after: number;
  now: number;
  options: GoogleSyncOptions;
  records: Map<string, FoundRecord>;
  seen: Map<string, number>;
  fails: Map<string, { n: number; first: number; until: number }>;
  noteFailure: (key: string, until: number, counted?: boolean) => { stale: boolean };
  lookups: AttendedLookup[];
  count: (key: keyof GoogleSyncCounts, n?: number) => void;
  hold: (at: number) => void;
  timeUp: () => boolean;
};

/**
 * G2 ②: 커서 앞 하루부터 지금까지의 Calendar 일정 중 사용자가 주최하지 않은 Meet 일정의 회의 코드로 회의 기록을 찾는다
 * (일정의 예정 끝이 실제 회의 끝보다 빠를 수 있어 앞을 넉넉히 읽는다). 회의 코드만 쓰고 일정은 저장하지 않는다(G3): 제목 · 참석자 이메일은 받지도 않는다.
 * 조회를 마친 일정(seen)은 다시 조회하지 않는다. 마치는 시점: 참석자에게 회의 기록을 안 주거나(403 · 404) 다시 해도 같은 오류(그 밖의 400번대)면 바로,
 * 조회에 성공하면 찾은 회의 기록을 모두 결정하고 일정이 끝난 지 attendedSettleMs가 지났을 때(호출한 쪽이 정한다).
 * 일정 목록 · 회의 코드 조회가 서버 오류 · 네트워크 오류면 ① 주최한 회의는 그대로 넣고 커서는 그 앞에 둔다(처음 실패한 때부터 holdCapMs까지, 그 뒤에는 실패로 결정).
 * 일정 목록이 400번대 오류면(Calendar API를 켜지 않음 등) 다시 해도 같으므로 실패로 세되 커서를 붙잡지 않는다: 동기화마다 센다.
 */
async function findAttendedRecords(calendar: CalendarClient, meetApi: MeetClient, context: AttendedContext): Promise<void> {
  const { after, now, options, records, seen, fails, noteFailure, lookups, count, hold, timeUp } = context;
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
    console.error(`참석한 회의 일정 목록 실패 (${errorLabel(error)})`);
    count("meet_attended_failed");
    // 서버 오류 · 네트워크 오류는 커서를 그 앞에 둬 다음에 다시 찾되 처음 실패한 지 holdCapMs가 지나면 그만 붙잡는다
    if (!isPermanent(error) && !noteFailure(LIST_FAILURE_KEY, now + options.holdCapMs).stale) hold(after);
    return;
  }
  fails.delete(LIST_FAILURE_KEY);
  // 못 다 읽었으면 읽은 마지막 일정 뒤는 다음에 다시 본다 (읽은 일정이 없으면 커서 그대로)
  if (pageToken) hold(events.length > 0 ? events[events.length - 1].start.getTime() : after);

  const decide = (group: CalendarEvent[]) => {
    for (const event of group) seen.set(eventKey(event), event.end.getTime() + options.attendedLookbackMs);
  };

  // 회의 코드마다 아직 조회를 마치지 않은 일정들 (반복 일정은 같은 코드): 회의 기록은 그중 가장 이른 일정 시작 하루 전부터 찾는다
  const codes = new Map<string, CalendarEvent[]>();
  for (const event of events) {
    if (event.organizerSelf || event.conferenceType !== "hangoutsMeet" || !event.conferenceId) continue;
    // 초대한 사람이 정하는 값이 목록 조건(filter)에 들어가므로 회의 코드 모양(영문자 · 숫자 · 하이픈)만 쓴다
    if (!MEETING_CODE_SHAPE.test(event.conferenceId)) continue;
    if (seen.has(eventKey(event))) continue;
    const key = event.conferenceId.toLowerCase();
    codes.set(key, [...(codes.get(key) ?? []), event]);
  }

  let looked = 0;
  for (const [code, group] of codes) {
    const earliest = Math.min(...group.map((event) => event.start.getTime()));
    if (looked >= options.maxAttendedCodes || timeUp()) {
      hold(earliest);
      continue;
    }
    looked++;
    try {
      const found = await meetApi.listRecords(`space.meeting_code = "${code}" AND start_time>="${new Date(earliest - DAY_MS).toISOString()}"`);
      const names: string[] = [];
      for (const record of found) {
        // 커서 뒤에 끝난 회의 기록만 (목록 조건은 시작 시각이다). 주최한 회의로 이미 찾았으면 그대로 둔다
        if (record.endTime.getTime() < after) continue;
        names.push(record.name);
        if (!records.has(record.name)) records.set(record.name, { record, via: "attended" });
      }
      for (const event of group) fails.delete(eventKey(event));
      lookups.push({ events: group, names });
    } catch (error) {
      if (isFatal(error)) {
        hold(earliest);
        throw error;
      }
      if (isNotVisible(error)) {
        count("meet_attended_denied", group.length);
        decide(group);
      } else if (isPermanent(error)) {
        console.error(`참석한 회의 기록 조회 실패 (${errorLabel(error)})`);
        count("meet_attended_failed", group.length);
        decide(group);
      } else {
        console.error(`참석한 회의 기록 조회 실패 (${errorLabel(error)}): 다음에 다시 봅니다`);
        // 일정마다: 처음 실패한 지 holdCapMs가 지났으면 더 붙잡지 않고 실패로 결정한다
        for (const event of group) {
          if (noteFailure(eventKey(event), event.end.getTime() + options.attendedLookbackMs).stale) {
            count("meet_attended_failed");
            decide([event]);
            fails.delete(eventKey(event));
          } else {
            hold(event.start.getTime());
          }
        }
      }
    }
  }
}
