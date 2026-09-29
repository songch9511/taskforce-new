import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { loadIdentity, loadToken, saveToken } from "../store";

import { googleCalendarLookup } from "./lookup";

vi.mock("server-only", () => ({}));
vi.mock("../store", () => ({ loadIdentity: vi.fn(), loadToken: vi.fn(), saveToken: vi.fn() }));

// Notion 회의록에 붙일 Calendar 일정 조회를 만드는 곳 (docs/go-live/google-integration.md 2-2 notion/sync.ts · 2-4).

const CALENDAR = "https://www.googleapis.com/auth/calendar.events.owned.readonly";
const MEET = "https://www.googleapis.com/auth/meetings.space.readonly";
const EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events";

/** connections 조회를 흉내 내는 admin: 어떤 조건으로 물었는지 기록한다 */
function fakeAdmin(rows: { id: string; settings: unknown }[] | Error) {
  const filters: [string, unknown][] = [];
  const query: Record<string, unknown> = {};
  for (const method of ["select", "eq", "in", "order", "limit"]) {
    query[method] = (...args: unknown[]) => {
      filters.push([method, args]);
      return query;
    };
  }
  query.throwOnError = async () => {
    if (rows instanceof Error) throw rows;
    return { data: rows };
  };
  return { admin: { from: () => query } as unknown as SupabaseClient, filters };
}

const settings = (scopes: string[]) => ({ googleUserId: "sub-1", email: "me@company.dev", scopes });
const stored = () => ({ access_token: "old-access", refresh_token: "fake-refresh", expires_at: Date.now() + 600_000, scope: CALENDAR });

const event = (extra: object = {}) => ({
  id: "evt-1",
  summary: "Proposal review — Acme",
  start: { dateTime: "2026-09-30T10:00:00+09:00" },
  end: { dateTime: "2026-09-30T11:00:00+09:00" },
  attendees: [
    { email: "me@company.dev", displayName: "Alex Song", self: true },
    { email: "jordan@harborline.example", displayName: "Jordan Lee" },
  ],
  ...extra,
});

beforeEach(() => {
  vi.resetAllMocks();
  vi.stubEnv("GOOGLE_CLIENT_ID", "fake-google-client-id");
  vi.stubEnv("GOOGLE_CLIENT_SECRET", "fake-google-client-secret");
  vi.stubEnv("GOOGLE_REDIRECT_URI", "https://api.example.dev/api/connectors/google/callback");
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.mocked(loadIdentity).mockResolvedValue({ name: "Alex Kim", aliases: [], emails: ["me@company.dev"] });
  vi.mocked(loadToken).mockResolvedValue(stored());
  vi.mocked(saveToken).mockResolvedValue();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("googleCalendarLookup: 만들 수 있는가", () => {
  it("google 연결이 없으면 null: Google을 부르지 않는다", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    expect(await googleCalendarLookup(fakeAdmin([]).admin, "u1")).toBeNull();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("이 사용자의 google 연결 중 쓸 수 있는 상태(active · error)만 본다", async () => {
    const { admin, filters } = fakeAdmin([]);
    await googleCalendarLookup(admin, "u1");
    expect(filters).toContainEqual(["eq", ["user_id", "u1"]]);
    expect(filters).toContainEqual(["eq", ["provider", "google"]]);
    expect(filters).toContainEqual(["in", ["status", ["active", "error"]]]);
  });

  it("Calendar를 허용하지 않았으면(Meet만, G10) null", async () => {
    expect(await googleCalendarLookup(fakeAdmin([{ id: "g1", settings: settings(["openid", MEET]) }]).admin, "u1")).toBeNull();
  });

  it("설정을 읽을 수 없으면 null", async () => {
    expect(await googleCalendarLookup(fakeAdmin([{ id: "g1", settings: { scopes: "x" } }]).admin, "u1")).toBeNull();
    expect(await googleCalendarLookup(fakeAdmin([{ id: "g1", settings: null }]).admin, "u1")).toBeNull();
  });

  it("준비 중 오류(연결 조회 실패 · env 누락)는 Notion 동기화를 막지 않도록 null로 삼키고 로그만 남긴다", async () => {
    expect(await googleCalendarLookup(fakeAdmin(new Error("db down")).admin, "u1")).toBeNull();
    vi.stubEnv("GOOGLE_CLIENT_SECRET", "");
    expect(await googleCalendarLookup(fakeAdmin([{ id: "g1", settings: settings([CALENDAR]) }]).admin, "u1")).toBeNull();
    expect(vi.mocked(console.error).mock.calls).toHaveLength(2);
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toMatch(/fake-refresh|old-access/);
  });
});

describe("googleCalendarLookup: 조회", () => {
  const target = { day: "2026-09-30", createdAt: new Date("2026-09-30T10:05:00+09:00"), title: "Proposal review — Acme", createdByUser: true };

  it("Calendar를 허용한 연결이면 연결 id와 조회 함수를 돌려주고, 그 연결의 토큰으로 그 한국 날짜의 일정을 읽는다", async () => {
    const urls: { url: string; auth?: string }[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string, init: RequestInit) => {
        urls.push({ url, auth: (init.headers as Record<string, string>).Authorization });
        return new Response(JSON.stringify({ items: [event()] }));
      }),
    );
    const lookup = await googleCalendarLookup(fakeAdmin([{ id: "g1", settings: settings([CALENDAR, MEET]) }]).admin, "u1");

    expect(lookup?.connectionId).toBe("g1");
    // 토큰 · 프로필 이름은 처음 조회할 때 읽는다 (붙일 회의록이 없는 동기화는 읽지 않는다)
    expect(loadToken).not.toHaveBeenCalled();
    expect(loadIdentity).not.toHaveBeenCalled();
    const found = await lookup!.lookup(target);
    await lookup!.lookup(target);
    expect(loadIdentity).toHaveBeenCalledTimes(1);

    expect(loadToken).toHaveBeenCalledWith(expect.anything(), "g1");
    expect(urls).toHaveLength(2);
    const url = new URL(urls[0].url);
    expect(url.origin + url.pathname).toBe(EVENTS_URL);
    expect(url.searchParams.get("timeMin")).toBe("2026-09-29T15:00:00.000Z");
    expect(url.searchParams.get("timeMax")).toBe("2026-09-30T15:00:00.000Z");
    expect(urls[0].auth).toBe("Bearer old-access");
    expect(found).toEqual({
      result: "attached",
      event: {
        calendarEventId: "evt-1",
        title: "Proposal review — Acme",
        start: "2026-09-30T01:00:00.000Z",
        end: "2026-09-30T02:00:00.000Z",
        // 사용자는 프로필 이름 + 연결한 주소로 한 번 (일정의 Google 이름 Alex Song이 아니다)
        attendees: [{ name: "Alex Kim", email: "me@company.dev" }, { name: "Jordan Lee", email: "jordan@harborline.example" }],
      },
    });
  });

  it("Google 호출이 실패하면 던진다 (notion/sync.ts가 그 동기화의 남은 회의록을 붙이지 않는다)", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 503 })));
    const lookup = await googleCalendarLookup(fakeAdmin([{ id: "g1", settings: settings([CALENDAR]) }]).admin, "u1");
    await expect(lookup!.lookup(target)).rejects.toMatchObject({ name: "GoogleApiError", status: 503 });
  });

  it("일정이 없으면 none", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({}))));
    const lookup = await googleCalendarLookup(fakeAdmin([{ id: "g1", settings: settings([CALENDAR]) }]).admin, "u1");
    expect(await lookup!.lookup(target)).toEqual({ result: "none" });
  });
});
