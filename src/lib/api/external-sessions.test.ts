import { afterEach, describe, expect, it, vi } from "vitest";

import { EXTERNAL_SESSION_STATES, externalSessionReportRequestSchema, metricEventRequestSchema } from "./contract";
import { EXTERNAL_SESSION_RETENTION_DAYS, handleReportExternalSessions, type ExternalSessionReportOutcome, type ExternalSessionsDeps } from "./external-sessions";

vi.mock("server-only", () => ({}));

const USER = "11111111-0000-4000-8000-000000000001";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const ref = (n: number) => n.toString(16).padStart(64, "0");
const session = (n: number, over: Record<string, unknown> = {}) => ({ id: ref(n), title: `제목 ${n}`, state: "available", last_activity_at: "2026-10-21T09:00:00Z", ...over });

function deps(over: Partial<ExternalSessionsDeps<{ user: { id: string } }>> = {}) {
  const report = vi.fn(async (): Promise<ExternalSessionReportOutcome> => ({ status: "ok", kept: 1, removed: 0 }));
  const authenticate = vi.fn(async () => ({ user: { id: USER } }));
  const value: ExternalSessionsDeps<{ user: { id: string } }> = { enabled: () => true, authenticate, betaAllowed: () => true, report, ...over };
  return { value, report, authenticate };
}

const put = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://api.example.dev/api/v2/external-sessions", { method: "PUT", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

afterEach(() => vi.restoreAllMocks());

describe("handleReportExternalSessions", () => {
  it("꺼져 있으면 404: 인증 · 저장 0", async () => {
    const d = deps({ enabled: () => false });
    expect((await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [] }), d.value)).status).toBe(404);
    expect(d.authenticate).not.toHaveBeenCalled();
    expect(d.report).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401, 베타 명단 밖이면 404 (저장 0)", async () => {
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [] }), anonymous.value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [] }), outside.value)).status).toBe(404);
    expect(anonymous.report).not.toHaveBeenCalled();
    expect(outside.report).not.toHaveBeenCalled();
  });

  it("검증한 본문을 그대로 저장 함수에 넘기고 개수만 돌려준다 (제목을 응답에 되돌리지 않는다)", async () => {
    const d = deps();
    const response = await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [session(1), session(2, { title: null, state: "running_claude_app" })] }), d.value);
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ kept: 1, removed: 0 });
    expect(text).not.toContain("제목");
    expect(d.report).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, { bridge_id: BRIDGE, sessions: [session(1), session(2, { title: null, state: "running_claude_app" })] });
  });

  it("빈 목록도 받는다 (이 Mac의 행을 모두 지운다)", async () => {
    const d = deps({ report: async () => ({ status: "ok", kept: 0, removed: 3 }) });
    const response = await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [] }), d.value);
    expect(await response.json()).toEqual({ kept: 0, removed: 3 });
  });

  it("모르는 · 남의 · 해제된 bridge는 404", async () => {
    const d = deps({ report: async () => ({ status: "not_found" }) });
    const response = await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [session(1)] }), d.value);
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "not_found" } });
  });

  it.each<[string, unknown]>([
    ["bridge_id가 uuid가 아님", { bridge_id: "nope", sessions: [] }],
    ["sessions 없음", { bridge_id: BRIDGE }],
    ["모르는 최상위 칸", { bridge_id: BRIDGE, sessions: [], path: "/Users/me" }],
    ["모르는 행 칸(경로)", { bridge_id: BRIDGE, sessions: [session(1, { cwd: "/Users/me/project" })] }],
    ["모르는 행 칸(폴더 이름)", { bridge_id: BRIDGE, sessions: [session(1, { folder: "taskforce" })] }],
    ["id가 Claude 세션 UUID 모양", { bridge_id: BRIDGE, sessions: [session(1, { id: "5e5e5e5e-0000-4000-8000-000000000001" })] }],
    ["id가 대문자 hex", { bridge_id: BRIDGE, sessions: [session(1, { id: "A".repeat(64) })] }],
    ["id가 63자", { bridge_id: BRIDGE, sessions: [session(1, { id: "a".repeat(63) })] }],
    ["제목이 빈 글자", { bridge_id: BRIDGE, sessions: [session(1, { title: "" })] }],
    ["제목이 201자", { bridge_id: BRIDGE, sessions: [session(1, { title: "가".repeat(201) })] }],
    ["제목에 제어 글자(개행)", { bridge_id: BRIDGE, sessions: [session(1, { title: "a\nb" })] }],
    ["제목에 방향 바꿈 글자", { bridge_id: BRIDGE, sessions: [session(1, { title: "a‮b" })] }],
    ["제목 앞뒤 공백", { bridge_id: BRIDGE, sessions: [session(1, { title: " a " })] }],
    ["모르는 상태(이어받음)", { bridge_id: BRIDGE, sessions: [session(1, { state: "in_taskforce" })] }],
    ["시각이 아님", { bridge_id: BRIDGE, sessions: [session(1, { last_activity_at: "yesterday" })] }],
    ["51개", { bridge_id: BRIDGE, sessions: Array.from({ length: 51 }, (_, n) => session(n + 1)) }],
    ["id 중복", { bridge_id: BRIDGE, sessions: [session(1), session(1, { title: "다른 제목" })] }],
  ])("잘못된 본문은 400이고 저장하지 않는다: %s", async (_name, body) => {
    const d = deps();
    const response = await handleReportExternalSessions(put(body), d.value);
    expect(response.status).toBe(400);
    expect(d.report).not.toHaveBeenCalled();
    // 오류 문구는 요청 값(제목 · 경로)을 담지 않는다
    expect(JSON.stringify(await response.json())).not.toMatch(/제목|\/Users|taskforce|가가가/);
  });

  it("50개 · 200자 제목 · 경계값은 받는다", async () => {
    const d = deps();
    const rows = Array.from({ length: 50 }, (_, n) => session(n + 1, { title: "가".repeat(200) }));
    expect((await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: rows }), d.value)).status).toBe(200);
  });

  it("본문이 크면 읽지 않고 400", async () => {
    const d = deps();
    const response = await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [] }, { "content-length": String(200 * 1024) }), d.value);
    expect(response.status).toBe(400);
    expect(d.report).not.toHaveBeenCalled();
  });

  it("저장이 실패하면 500이고 로그에 제목 · id가 없다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const failure = Object.assign(new Error("제목 제목 1 /Users/me"), { code: "XX000" });
    const d = deps({ report: async () => Promise.reject(failure) });
    const response = await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [session(1)] }), d.value);
    expect(response.status).toBe(500);
    const logged = log.mock.calls.map((call) => String(call[0])).join("\n");
    expect(logged).toContain("external_sessions_report_failed");
    expect(logged).not.toMatch(/제목|\/Users|0000000000000001/);
    expect(JSON.stringify(await response.json())).not.toMatch(/제목|\/Users/);
  });

  it("보관 기간은 14일(목록의 7일 창의 두 배)", () => {
    expect(EXTERNAL_SESSION_RETENTION_DAYS).toBe(14);
  });
});

describe("계약 스키마", () => {
  it("상태는 6개 말뿐이다 (이어받은 세션 · 폴더 이유는 서버에 가지 않는다)", () => {
    expect([...EXTERNAL_SESSION_STATES]).toEqual(["available", "running_claude_app", "running_terminal", "running_elsewhere", "unknown", "unavailable"]);
    expect(externalSessionReportRequestSchema.safeParse({ bridge_id: BRIDGE, sessions: [session(1, { state: "worktree" })] }).success).toBe(false);
  });

  it("metric-events: app_opened는 예전 모양 그대로 받고, external_sessions_shown은 구간 값만 받는다", () => {
    expect(metricEventRequestSchema.safeParse({ type: "app_opened" }).success).toBe(true);
    expect(metricEventRequestSchema.safeParse({ type: "app_opened", action_id: "5e5e5e5e-0000-4000-8000-000000000001" }).success).toBe(true);
    expect(metricEventRequestSchema.safeParse({ type: "external_sessions_shown", props: { rows_bucket: "2-5", held_bucket: "0" } }).success).toBe(true);
    for (const bad of [
      { type: "external_sessions_shown" },
      { type: "external_sessions_shown", props: { rows_bucket: "7", held_bucket: "0" } },
      { type: "external_sessions_shown", props: { rows_bucket: "1", held_bucket: "9" } },
      { type: "external_sessions_shown", props: { rows_bucket: "1", held_bucket: "0", title: "x" } },
      { type: "external_sessions_shown", props: { rows_bucket: "1", held_bucket: "0" }, action_id: "5e5e5e5e-0000-4000-8000-000000000001" },
      { type: "session_attached" },
      { type: "agent_message_sent" },
    ]) {
      expect(metricEventRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });
});
