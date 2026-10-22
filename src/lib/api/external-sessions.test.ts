import { afterEach, describe, expect, it, vi } from "vitest";

import { EXTERNAL_SESSION_STATES, claudeAppSessionOpenedRequestSchema, externalSessionReportRequestSchema, externalSessionsShownRequestSchema, metricEventRequestSchema } from "./contract";
import {
  EXTERNAL_SESSION_RETENTION_DAYS,
  handleClaudeAppSessionOpened,
  handleExternalSessionsShown,
  handleReportExternalSessions,
  type ExternalSessionReportOutcome,
  type ExternalSessionsDeps,
} from "./external-sessions";

vi.mock("server-only", () => ({}));

const USER = "11111111-0000-4000-8000-000000000001";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const ref = (n: number) => n.toString(16).padStart(64, "0");
const session = (n: number, over: Record<string, unknown> = {}) => ({ id: ref(n), title: `제목 ${n}`, state: "available", last_activity_at: "2026-10-21T09:00:00Z", ...over });

function deps(over: Partial<ExternalSessionsDeps<{ user: { id: string } }>> = {}) {
  const report = vi.fn(async (): Promise<ExternalSessionReportOutcome> => ({ status: "ok", kept: 1, removed: 0 }));
  const recordShown = vi.fn(async (): Promise<"recorded" | "duplicate"> => "recorded");
  const recordClaudeAppOpened = vi.fn(async (): Promise<"recorded" | "duplicate"> => "recorded");
  const authenticate = vi.fn(async () => ({ user: { id: USER } }));
  const value: ExternalSessionsDeps<{ user: { id: string } }> = {
    enabled: () => true,
    reportEnabled: () => true,
    authenticate,
    betaAllowed: () => true,
    report,
    recordShown,
    recordClaudeAppOpened,
    ...over,
  };
  return { value, report, recordShown, recordClaudeAppOpened, authenticate };
}

const put = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://api.example.dev/api/v2/external-sessions", { method: "PUT", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

/** 끝나지 않는 본문: 한 번에 chunk 바이트씩 내고, 읽힌 횟수를 센다 */
function endless(chunk: number, pulled: { n: number }) {
  const bytes = new TextEncoder().encode(" ".repeat(chunk));
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      pulled.n += 1;
      if (pulled.n > 10_000) controller.close();
      else controller.enqueue(bytes);
    },
  });
}
const putStream = (body: ReadableStream<Uint8Array>) =>
  new Request("https://api.example.dev/api/v2/external-sessions", { method: "PUT", headers: { "content-type": "application/json" }, body, duplex: "half" } as RequestInit);
const postStream = (body: ReadableStream<Uint8Array>) =>
  new Request("https://api.example.dev/api/v2/external-sessions/shown", { method: "POST", headers: { "content-type": "application/json" }, body, duplex: "half" } as RequestInit);

afterEach(() => vi.restoreAllMocks());

describe("handleReportExternalSessions", () => {
  it("꺼져 있으면 404: 인증 · 저장 0", async () => {
    const d = deps({ enabled: () => false });
    expect((await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [] }), d.value)).status).toBe(404);
    expect(d.authenticate).not.toHaveBeenCalled();
    expect(d.report).not.toHaveBeenCalled();
  });

  it("제목 보고 전용 gate(EXTERNAL_SESSIONS_REPORT_ENABLED)가 꺼져 있으면 404: 인증 · 저장 0, 목록 gate가 켜져 있어도", async () => {
    const d = deps({ reportEnabled: () => false });
    const response = await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [session(1)] }), d.value);
    expect(response.status).toBe(404);
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

  it("Content-Length가 없어도 본문을 상한(128 KiB)까지만 읽고 400: 끝없는 본문을 다 읽지 않는다", async () => {
    const d = deps();
    const pulled = { n: 0 };
    const response = await handleReportExternalSessions(putStream(endless(16 * 1024, pulled)), d.value);
    expect(response.status).toBe(400);
    expect(d.report).not.toHaveBeenCalled();
    expect(pulled.n).toBeLessThanOrEqual(12);
  });

  it("Content-Length가 없는 큰 문자열 본문도 400, 상한 안의 본문은 그대로 받는다", async () => {
    const d = deps();
    const big = new Request("https://api.example.dev/api/v2/external-sessions", { method: "PUT", headers: { "content-type": "application/json" }, body: " ".repeat(200 * 1024) + JSON.stringify({ bridge_id: BRIDGE, sessions: [] }) });
    expect(big.headers.get("content-length")).toBeNull();
    expect((await handleReportExternalSessions(big, d.value)).status).toBe(400);
    expect(d.report).not.toHaveBeenCalled();
    expect((await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [session(1)] }), d.value)).status).toBe(200);
  });

  it("저장이 실패하면 500이고 로그에 제목 · id가 없다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const failure = Object.assign(new Error("제목 제목 1 /Users/me"), { code: "XX000" });
    const d = deps({ report: async () => Promise.reject(failure) });
    const response = await handleReportExternalSessions(put({ bridge_id: BRIDGE, sessions: [session(1)] }), d.value);
    expect(response.status).toBe(500);
    const logged = JSON.stringify(log.mock.calls);
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

  it("v1 metric-events 스키마는 동결 그대로다: app_opened만 받는다 (새 지표는 v2)", () => {
    expect(metricEventRequestSchema.safeParse({ type: "app_opened" }).success).toBe(true);
    expect(metricEventRequestSchema.safeParse({ type: "app_opened", action_id: "5e5e5e5e-0000-4000-8000-000000000001" }).success).toBe(true);
    for (const bad of [
      { type: "external_sessions_shown", props: { rows_bucket: "2-5", held_bucket: "0" } },
      { type: "session_attached" },
      { type: "agent_message_sent" },
      { type: "claude_app_session_opened" },
    ]) {
      expect(metricEventRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("claude_app_session_opened 본문은 비어 있다: 종류만이고 어떤 칸도 받지 않는다 (strict)", () => {
    expect(claudeAppSessionOpenedRequestSchema.safeParse({}).success).toBe(true);
    for (const bad of [
      { title: "x" },
      { user_id: "11111111-0000-4000-8000-000000000001" },
      { session_id: "5e5e5e5e-0000-4000-8000-000000000001" },
      { type: "claude_app_session_opened" },
      { source: "rail" },
      [],
      null,
      "x",
    ]) {
      expect(claudeAppSessionOpenedRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("external_sessions_shown 본문은 구간 값 둘뿐이다", () => {
    expect(externalSessionsShownRequestSchema.safeParse({ rows_bucket: "2-5", held_bucket: "0" }).success).toBe(true);
    for (const bad of [
      {},
      { rows_bucket: "2-5" },
      { rows_bucket: "7", held_bucket: "0" },
      { rows_bucket: "1", held_bucket: "9" },
      { rows_bucket: "1", held_bucket: "0", title: "x" },
      { rows_bucket: "1", held_bucket: "0", user_id: "x" },
      { type: "external_sessions_shown", rows_bucket: "1", held_bucket: "0" },
    ]) {
      expect(externalSessionsShownRequestSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });
});

describe("handleExternalSessionsShown", () => {
  const post = (body: unknown) =>
    new Request("https://api.example.dev/api/v2/external-sessions/shown", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const shown = { rows_bucket: "2-5", held_bucket: "1-2" };

  it("꺼져 있으면 404 · 로그인 없으면 401 · 베타 명단 밖이면 404 (저장 0)", async () => {
    const off = deps({ enabled: () => false });
    expect((await handleExternalSessionsShown(post(shown), off.value)).status).toBe(404);
    expect(off.authenticate).not.toHaveBeenCalled();
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleExternalSessionsShown(post(shown), anonymous.value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleExternalSessionsShown(post(shown), outside.value)).status).toBe(404);
    expect(off.recordShown).not.toHaveBeenCalled();
    expect(anonymous.recordShown).not.toHaveBeenCalled();
    expect(outside.recordShown).not.toHaveBeenCalled();
  });

  it("구간 값만으로 저장하고 204, 같은 날 두 번째도 204", async () => {
    const d = deps();
    const response = await handleExternalSessionsShown(post(shown), d.value);
    expect(response.status).toBe(204);
    expect(d.recordShown).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, shown);
    const again = deps({ recordShown: async () => "duplicate" });
    expect((await handleExternalSessionsShown(post(shown), again.value)).status).toBe(204);
  });

  it.each([{}, { rows_bucket: "12", held_bucket: "0" }, { rows_bucket: "1", held_bucket: "0", title: "x" }])("잘못된 본문은 400 (저장 0): %j", async (body) => {
    const d = deps();
    expect((await handleExternalSessionsShown(post(body), d.value)).status).toBe(400);
    expect(d.recordShown).not.toHaveBeenCalled();
  });

  it("제목 보고 gate가 꺼져 있어도 열린다: 구간 값만 받는 지표라 제목 보고와 따로 간다", async () => {
    const d = deps({ reportEnabled: () => false });
    expect((await handleExternalSessionsShown(post(shown), d.value)).status).toBe(204);
    expect(d.recordShown).toHaveBeenCalledTimes(1);
  });

  it("본문은 1 KiB까지만 읽는다: Content-Length가 없어도 끝없는 본문에 400 (저장 0)", async () => {
    const d = deps();
    const pulled = { n: 0 };
    expect((await handleExternalSessionsShown(postStream(endless(512, pulled)), d.value)).status).toBe(400);
    expect(d.recordShown).not.toHaveBeenCalled();
    expect(pulled.n).toBeLessThanOrEqual(6);
    const big = new Request("https://api.example.dev/api/v2/external-sessions/shown", { method: "POST", headers: { "content-type": "application/json" }, body: " ".repeat(4096) + JSON.stringify(shown) });
    expect((await handleExternalSessionsShown(big, d.value)).status).toBe(400);
    expect(d.recordShown).not.toHaveBeenCalled();
  });

  it("저장이 실패하면 500이고 로그에 오류 이름과 코드뿐이다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = deps({ recordShown: async () => Promise.reject(Object.assign(new Error("secret detail"), { code: "XX000" })) });
    expect((await handleExternalSessionsShown(post(shown), d.value)).status).toBe(500);
    expect(JSON.stringify(log.mock.calls)).not.toContain("secret detail");
    expect(JSON.stringify(log.mock.calls)).toContain("external_sessions_shown_failed");
  });
});

// 데스크톱 세션 보기를 연 날의 지표 claude_app_session_opened (OA PR-D2): 종류만 (본문 · 칸 0), 하루 한 번, 목록 gate · 베타 명단은 `shown`과 같다
describe("handleClaudeAppSessionOpened", () => {
  const post = (body: unknown = {}) =>
    new Request("https://api.example.dev/api/v2/external-sessions/claude-app-opened", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

  it("꺼져 있으면 404 · 로그인 없으면 401 · 베타 명단 밖이면 404 (저장 0)", async () => {
    const off = deps({ enabled: () => false });
    expect((await handleClaudeAppSessionOpened(post(), off.value)).status).toBe(404);
    expect(off.authenticate).not.toHaveBeenCalled();
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleClaudeAppSessionOpened(post(), anonymous.value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleClaudeAppSessionOpened(post(), outside.value)).status).toBe(404);
    for (const d of [off, anonymous, outside]) expect(d.recordClaudeAppOpened).not.toHaveBeenCalled();
  });

  it("본문 없이도 · 빈 객체로도 저장하고 204, 같은 날 두 번째도 204", async () => {
    const d = deps();
    const response = await handleClaudeAppSessionOpened(post({}), d.value);
    expect(response.status).toBe(204);
    expect(d.recordClaudeAppOpened).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } });
    const empty = deps();
    const noBody = new Request("https://api.example.dev/api/v2/external-sessions/claude-app-opened", { method: "POST" });
    expect((await handleClaudeAppSessionOpened(noBody, empty.value)).status).toBe(204);
    expect(empty.recordClaudeAppOpened).toHaveBeenCalledTimes(1);
    const again = deps({ recordClaudeAppOpened: async () => "duplicate" });
    expect((await handleClaudeAppSessionOpened(post(), again.value)).status).toBe(204);
  });

  it.each([{ title: "x" }, { session_id: "5e5e5e5e-0000-4000-8000-000000000001" }, { user_id: USER }, { source: "rail" }])("어떤 칸을 실어도 400 (저장 0): %j", async (body) => {
    const d = deps();
    expect((await handleClaudeAppSessionOpened(post(body), d.value)).status).toBe(400);
    expect(d.recordClaudeAppOpened).not.toHaveBeenCalled();
  });

  it("제목 보고 gate가 꺼져 있어도 열린다: 제목을 보내지 않는 지표라 따로 간다", async () => {
    const d = deps({ reportEnabled: () => false });
    expect((await handleClaudeAppSessionOpened(post(), d.value)).status).toBe(204);
    expect(d.recordClaudeAppOpened).toHaveBeenCalledTimes(1);
  });

  it("본문은 1 KiB까지만 읽는다: 끝없는 본문에 400 (저장 0)", async () => {
    const d = deps();
    const pulled = { n: 0 };
    const stream = new Request("https://api.example.dev/api/v2/external-sessions/claude-app-opened", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: endless(512, pulled),
      duplex: "half",
    } as RequestInit);
    expect((await handleClaudeAppSessionOpened(stream, d.value)).status).toBe(400);
    expect(d.recordClaudeAppOpened).not.toHaveBeenCalled();
    expect(pulled.n).toBeLessThanOrEqual(6);
  });

  it("저장이 실패하면 500이고 로그에 오류 이름과 코드뿐이다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = deps({ recordClaudeAppOpened: async () => Promise.reject(Object.assign(new Error("secret detail"), { code: "XX000" })) });
    expect((await handleClaudeAppSessionOpened(post(), d.value)).status).toBe(500);
    expect(JSON.stringify(log.mock.calls)).not.toContain("secret detail");
    expect(JSON.stringify(log.mock.calls)).toContain("claude_app_session_opened_failed");
  });
});
