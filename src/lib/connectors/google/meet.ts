import { z } from "zod";

import { GoogleApiError, googleErrorReason, type GoogleAccess } from "./token";

// Google Meet REST API v2 (읽기만, meetings.space.readonly): 회의 기록 · 전사 · 전사 항목 · 참가자 · 회의 공간 (docs/go-live/google-integration.md 2-5).
// 응답은 zod로 확인한다. 전사 본문 · 이름은 로그에 남기지 않는다 (오류 코드만).

const MEET_API = "https://meet.googleapis.com/v2";
/** 목록 한 쪽 크기 (API 최대: 회의 기록 · 전사 · 전사 항목 100) */
const PAGE_SIZE = 100;
/** 한 목록을 이만큼 쪽까지만 받는다 (전사 항목이 수천 개인 3시간 넘는 회의도 원문 한도 20만 자 안에서 끝난다) */
const MAX_PAGES = 100;

const timestamp = z.string().optional();
const recordSchema = z.object({ name: z.string().min(1), startTime: timestamp, endTime: timestamp, space: z.string().optional() });
const transcriptSchema = z.object({
  name: z.string().min(1),
  state: z.string().optional(),
  startTime: timestamp,
  endTime: timestamp,
  docsDestination: z.object({ document: z.string().optional() }).optional(),
});
const entrySchema = z.object({ participant: z.string().optional(), text: z.string().optional(), startTime: timestamp });
const participantSchema = z.object({
  name: z.string().min(1),
  signedinUser: z.object({ user: z.string().optional(), displayName: z.string().optional() }).optional(),
  anonymousUser: z.object({ displayName: z.string().optional() }).optional(),
  phoneUser: z.object({ displayName: z.string().optional() }).optional(),
});
const spaceSchema = z.object({ meetingCode: z.string().optional() });

/** 목록 응답 한 쪽: 항목 배열(키는 목록마다 다르다)과 다음 쪽 토큰 */
const pageOf = <S extends z.ZodType>(key: string, item: S) =>
  z.object({ [key]: z.array(item).optional(), nextPageToken: z.string().optional() }).transform((data) => {
    const record = data as Record<string, unknown>;
    return { items: (record[key] ?? []) as z.infer<S>[], next: record.nextPageToken as string | undefined };
  });

const date = (value: string | undefined): Date | null => {
  const parsed = value ? new Date(value) : null;
  return parsed && !Number.isNaN(parsed.getTime()) ? parsed : null;
};

/** 끝난 회의 기록 (진행 중이라 endTime이 없는 회의는 목록에서 빠지거나 여기서 거른다) */
export type ConferenceRecord = { name: string; startTime: Date; endTime: Date; space: string | null };
/** STARTED · ENDED(파일은 아직) · FILE_GENERATED (그 밖은 STATE_UNSPECIFIED) */
export type Transcript = { name: string; state: string; startTime: Date | null; endTime: Date | null; documentId: string | null };
export type TranscriptEntry = { participant: string | null; text: string; startTime: Date | null };
export type MeetParticipantKind = "signedin" | "anonymous" | "phone";
export type MeetParticipant = { name: string; kind: MeetParticipantKind; /** `users/{id}` (로그인 참가자만) */ user: string | null; displayName: string | null };

export type MeetClient = {
  /** 조건(filter)에 맞는 끝난 회의 기록 모두 */
  listRecords: (filter: string) => Promise<ConferenceRecord[]>;
  /** 회의 기록의 전사 (없거나 기록이 만료됐으면 빈 목록) */
  listTranscripts: (recordName: string) => Promise<Transcript[]>;
  /** 전사 항목 (시작 시각 순) */
  listEntries: (transcriptName: string) => Promise<TranscriptEntry[]>;
  listParticipants: (recordName: string) => Promise<MeetParticipant[]>;
  /** 회의 공간의 회의 코드. 공간을 볼 수 없으면 null */
  meetingCode: (spaceName: string) => Promise<string | null>;
};

/** 한 동기화에서 부를 수 있는 요청 수를 넘겼다 (Meet은 사용자당 분당 600건, 넘으면 429). 동기화가 여기서 멈추고 다음에 이어 간다 */
export class MeetBudgetExhausted extends Error {
  constructor() {
    super("Meet 요청 수 한도에 도달했습니다");
    this.name = "MeetBudgetExhausted";
  }
}

export function meetClient(access: GoogleAccess, options: { budget?: { left: number } } = {}): MeetClient {
  async function call<T>(path: string, params: [string, string][], schema: z.ZodType<T>, notFound: "empty" | "throw"): Promise<T | null> {
    if (options.budget) {
      if (options.budget.left <= 0) throw new MeetBudgetExhausted();
      options.budget.left--;
    }
    const query = params.length > 0 ? `?${new URLSearchParams(params).toString()}` : "";
    const response = await access.get(`${MEET_API}/${path}${query}`);
    if (response.status === 404 && notFound === "empty") return null;
    if (!response.ok) {
      const reason = await googleErrorReason(response);
      throw new GoogleApiError(`Meet 요청 실패 (${response.status}${reason ? ` ${reason}` : ""})`, response.status, reason);
    }
    const parsed = schema.safeParse(await response.json().catch(() => null));
    if (!parsed.success) throw new GoogleApiError("Meet 응답 형식이 예상과 다릅니다", 502, "bad_response");
    return parsed.data;
  }

  /** 목록을 끝까지(MAX_PAGES까지) 받는다. 404면(기록이 만료됨) 빈 목록 */
  async function all<S extends z.ZodType>(path: string, key: string, item: S, extra: [string, string][] = [], notFound: "empty" | "throw" = "empty"): Promise<z.infer<S>[]> {
    const items: z.infer<S>[] = [];
    const schema = pageOf(key, item);
    let pageToken: string | undefined;
    for (let n = 0; n < MAX_PAGES; n++) {
      const params: [string, string][] = [["pageSize", String(PAGE_SIZE)], ...extra];
      if (pageToken) params.push(["pageToken", pageToken]);
      const data = await call(path, params, schema, notFound);
      if (!data) return items;
      items.push(...data.items);
      pageToken = data.next;
      if (!pageToken) break;
    }
    return items;
  }

  return {
    listRecords: async (filter) => {
      const records = await all("conferenceRecords", "conferenceRecords", recordSchema, [["filter", filter]], "throw");
      return records.flatMap((r) => {
        const startTime = date(r.startTime);
        const endTime = date(r.endTime);
        return startTime && endTime ? [{ name: r.name, startTime, endTime, space: r.space ?? null }] : [];
      });
    },
    listTranscripts: async (recordName) => {
      const transcripts = await all(`${recordName}/transcripts`, "transcripts", transcriptSchema);
      return transcripts.map((t) => ({
        name: t.name,
        state: t.state ?? "STATE_UNSPECIFIED",
        startTime: date(t.startTime),
        endTime: date(t.endTime),
        documentId: t.docsDestination?.document ?? null,
      }));
    },
    listEntries: async (transcriptName) => {
      const entries = await all(`${transcriptName}/entries`, "transcriptEntries", entrySchema);
      return entries
        .map((e) => ({ participant: e.participant ?? null, text: e.text ?? "", startTime: date(e.startTime) }))
        .sort((a, b) => (a.startTime?.getTime() ?? 0) - (b.startTime?.getTime() ?? 0));
    },
    listParticipants: async (recordName) => {
      const participants = await all(`${recordName}/participants`, "participants", participantSchema);
      return participants.map((p): MeetParticipant => {
        if (p.signedinUser) return { name: p.name, kind: "signedin", user: p.signedinUser.user ?? null, displayName: p.signedinUser.displayName ?? null };
        if (p.phoneUser) return { name: p.name, kind: "phone", user: null, displayName: p.phoneUser.displayName ?? null };
        return { name: p.name, kind: "anonymous", user: null, displayName: p.anonymousUser?.displayName ?? null };
      });
    },
    meetingCode: async (spaceName) => {
      try {
        const space = await call(spaceName, [], spaceSchema, "empty");
        return space?.meetingCode ?? null;
      } catch (error) {
        // 볼 수 없는 공간(권한 · 삭제)은 회의 코드를 모르는 것으로 본다. 그 밖의 오류(속도 제한 · 서버 오류)는 그대로 올린다
        if (error instanceof GoogleApiError && (error.status === 403 || error.status === 404)) return null;
        throw error;
      }
    },
  };
}
