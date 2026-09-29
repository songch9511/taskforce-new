import { describe, expect, it, vi } from "vitest";

import { meetClient, MeetBudgetExhausted } from "./meet";
import type { GoogleAccess } from "./token";

// Meet REST API v2 클라이언트 (docs/go-live/google-integration.md 2-5). Google을 부르지 않고 fetch를 흉내 낸다.

type Route = (url: URL) => Response | undefined;

function fakeAccess(routes: Route[]) {
  const urls: URL[] = [];
  const access: GoogleAccess = {
    get: vi.fn(async (raw: string) => {
      const url = new URL(raw);
      urls.push(url);
      for (const route of routes) {
        const response = route(url);
        if (response) return response;
      }
      return new Response(JSON.stringify({ error: { status: "NOT_FOUND" } }), { status: 404 });
    }),
  };
  return { access, urls };
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });

describe("listRecords", () => {
  it("filter를 그대로 넘기고 끝난 회의 기록만 돌려준다 (pageSize 100, 끝까지)", async () => {
    const { access, urls } = fakeAccess([
      (url) =>
        url.pathname === "/v2/conferenceRecords" && !url.searchParams.get("pageToken")
          ? json({
              conferenceRecords: [
                { name: "conferenceRecords/c1", startTime: "2026-09-30T01:00:00Z", endTime: "2026-09-30T02:00:00Z", space: "spaces/s1" },
                { name: "conferenceRecords/live", startTime: "2026-09-30T03:00:00Z", space: "spaces/s2" },
              ],
              nextPageToken: "p2",
            })
          : undefined,
      (url) =>
        url.pathname === "/v2/conferenceRecords" && url.searchParams.get("pageToken") === "p2"
          ? json({ conferenceRecords: [{ name: "conferenceRecords/c2", startTime: "2026-09-30T04:00:00Z", endTime: "2026-09-30T05:00:00Z" }] })
          : undefined,
    ]);
    const records = await meetClient(access).listRecords('end_time>="2026-09-29T00:00:00.000Z"');
    expect(records.map((r) => r.name)).toEqual(["conferenceRecords/c1", "conferenceRecords/c2"]);
    expect(records[0]).toEqual({ name: "conferenceRecords/c1", startTime: new Date("2026-09-30T01:00:00Z"), endTime: new Date("2026-09-30T02:00:00Z"), space: "spaces/s1" });
    expect(records[1].space).toBeNull();
    expect(urls[0].searchParams.get("filter")).toBe('end_time>="2026-09-29T00:00:00.000Z"');
    expect(urls[0].searchParams.get("pageSize")).toBe("100");
    expect(urls).toHaveLength(2);
  });

  it("빈 응답은 빈 목록이고, 403은 던진다 (호출하는 쪽이 정한다)", async () => {
    expect(await meetClient(fakeAccess([() => json({})]).access).listRecords("x")).toEqual([]);
    const denied = fakeAccess([() => json({ error: { status: "PERMISSION_DENIED" } }, 403)]);
    await expect(meetClient(denied.access).listRecords("x")).rejects.toMatchObject({ name: "GoogleApiError", status: 403, reason: "PERMISSION_DENIED" });
  });

  it("응답 형식이 다르면 502 bad_response", async () => {
    await expect(meetClient(fakeAccess([() => json({ conferenceRecords: "x" })]).access).listRecords("x")).rejects.toMatchObject({ status: 502, reason: "bad_response" });
  });
});

describe("listTranscripts", () => {
  it("전사 상태 · 시각 · 문서 id를 읽는다. 기록이 만료됐으면(404) 빈 목록", async () => {
    const { access, urls } = fakeAccess([
      (url) =>
        url.pathname === "/v2/conferenceRecords/c1/transcripts"
          ? json({
              transcripts: [
                { name: "conferenceRecords/c1/transcripts/t1", state: "FILE_GENERATED", startTime: "2026-09-30T01:00:05Z", endTime: "2026-09-30T01:58:00Z", docsDestination: { document: "DOC_ID_1234567890", exportUri: "https://docs.google.com/x" } },
                { name: "conferenceRecords/c1/transcripts/t2", startTime: "bad", endTime: "2026-09-30T01:58:00Z" },
              ],
            })
          : undefined,
    ]);
    const client = meetClient(access);
    const transcripts = await client.listTranscripts("conferenceRecords/c1");
    expect(transcripts).toEqual([
      { name: "conferenceRecords/c1/transcripts/t1", state: "FILE_GENERATED", startTime: new Date("2026-09-30T01:00:05Z"), endTime: new Date("2026-09-30T01:58:00Z"), documentId: "DOC_ID_1234567890" },
      { name: "conferenceRecords/c1/transcripts/t2", state: "STATE_UNSPECIFIED", startTime: null, endTime: new Date("2026-09-30T01:58:00Z"), documentId: null },
    ]);
    expect(urls[0].searchParams.get("pageSize")).toBe("100");
    expect(await client.listTranscripts("conferenceRecords/expired")).toEqual([]);
  });
});

describe("listEntries", () => {
  it("전사 항목을 시작 시각 순으로 돌려준다 (여러 쪽)", async () => {
    const { access } = fakeAccess([
      (url) =>
        url.pathname === "/v2/conferenceRecords/c1/transcripts/t1/entries" && !url.searchParams.get("pageToken")
          ? json({ transcriptEntries: [{ participant: "conferenceRecords/c1/participants/p2", text: "둘째", startTime: "2026-09-30T01:00:20Z" }], nextPageToken: "n2" })
          : undefined,
      (url) =>
        url.pathname === "/v2/conferenceRecords/c1/transcripts/t1/entries" && url.searchParams.get("pageToken") === "n2"
          ? json({ transcriptEntries: [{ participant: "conferenceRecords/c1/participants/p1", text: "첫째", startTime: "2026-09-30T01:00:10Z", languageCode: "ko" }, { text: "화자 없음" }] })
          : undefined,
    ]);
    const entries = await meetClient(access).listEntries("conferenceRecords/c1/transcripts/t1");
    expect(entries.map((e) => e.text)).toEqual(["화자 없음", "첫째", "둘째"]);
    expect(entries[0].participant).toBeNull();
  });
});

describe("listParticipants", () => {
  it("로그인 · 익명 · 전화 참가자를 가른다", async () => {
    const { access } = fakeAccess([
      (url) =>
        url.pathname === "/v2/conferenceRecords/c1/participants"
          ? json({
              participants: [
                { name: "conferenceRecords/c1/participants/p1", signedinUser: { user: "users/111", displayName: "Alex Kim" } },
                { name: "conferenceRecords/c1/participants/p2", anonymousUser: { displayName: "Guest" } },
                { name: "conferenceRecords/c1/participants/p3", phoneUser: { displayName: "+82 10-****-1234" } },
                { name: "conferenceRecords/c1/participants/p4" },
              ],
            })
          : undefined,
    ]);
    expect(await meetClient(access).listParticipants("conferenceRecords/c1")).toEqual([
      { name: "conferenceRecords/c1/participants/p1", kind: "signedin", user: "users/111", displayName: "Alex Kim" },
      { name: "conferenceRecords/c1/participants/p2", kind: "anonymous", user: null, displayName: "Guest" },
      { name: "conferenceRecords/c1/participants/p3", kind: "phone", user: null, displayName: "+82 10-****-1234" },
      { name: "conferenceRecords/c1/participants/p4", kind: "anonymous", user: null, displayName: null },
    ]);
  });
});

describe("meetingCode", () => {
  it("회의 공간의 회의 코드를 읽는다. 볼 수 없는 공간(403 · 404)은 null, 그 밖의 오류는 던진다", async () => {
    const { access } = fakeAccess([
      (url) => (url.pathname === "/v2/spaces/s1" ? json({ name: "spaces/s1", meetingCode: "abc-defg-hij", meetingUri: "https://meet.google.com/abc-defg-hij" }) : undefined),
      (url) => (url.pathname === "/v2/spaces/hidden" ? json({}, 403) : undefined),
      (url) => (url.pathname === "/v2/spaces/broken" ? json({ error: { status: "UNAVAILABLE" } }, 503) : undefined),
    ]);
    const client = meetClient(access);
    expect(await client.meetingCode("spaces/s1")).toBe("abc-defg-hij");
    expect(await client.meetingCode("spaces/gone")).toBeNull();
    expect(await client.meetingCode("spaces/hidden")).toBeNull();
    await expect(client.meetingCode("spaces/broken")).rejects.toMatchObject({ status: 503 });
  });
});

describe("요청 예산", () => {
  it("예산을 다 쓰면 다음 요청 전에 MeetBudgetExhausted를 던진다 (Google을 더 부르지 않는다)", async () => {
    const { access, urls } = fakeAccess([() => json({ transcripts: [] })]);
    const budget = { left: 2 };
    const client = meetClient(access, { budget });
    await client.listTranscripts("conferenceRecords/a");
    await client.listTranscripts("conferenceRecords/b");
    await expect(client.listTranscripts("conferenceRecords/c")).rejects.toBeInstanceOf(MeetBudgetExhausted);
    expect(urls).toHaveLength(2);
    expect(budget.left).toBe(0);
  });
});
