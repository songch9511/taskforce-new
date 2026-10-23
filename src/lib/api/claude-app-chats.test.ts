import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

import { afterEach, describe, expect, it, vi } from "vitest";

import {
  CLAUDE_APP_CHAT_DAILY_LIMIT,
  CLAUDE_APP_CHAT_LIMIT,
  CLAUDE_APP_SENT_LIMIT,
  handleClaudeAppChatStatus,
  handleClaudeAppSent,
  handleDeleteClaudeAppChat,
  handleSaveClaudeAppChat,
  realClaudeAppChatsDeps,
  type ClaudeAppChatsDeps,
  type ClaudeAppChatSaveOutcome,
} from "./claude-app-chats";
import {
  apiErrorV2AgentCodeSchema,
  apiErrorV2ClaudeAppChatCodeSchema,
  claudeAppChatErrorCodeSchema,
  claudeAppChatSaveRequestSchema,
  claudeAppChatSaveResponseSchema,
  claudeAppChatStatusResponseSchema,
  claudeAppSentRequestSchema,
} from "./contract";

vi.mock("server-only", () => ({}));

// Claude 데스크톱 대화 저장 route 처리 (OA PR-D3s, 계약 25.3 · 25.11 · 26장). 인증 · gate · 저장을 인자로 받아 Route Handler 밖에서 테스트한다 (external-sessions.ts와 같은 방식).
// 본문(보낸 글 · 답 글 · 제목 · 도구 이름)은 어느 로그 · 오류 응답에도 담기지 않는다.

type TestUser = { user: { id: string } };
const USER = "11111111-0000-4000-8000-000000000001";
const BRIDGE = "b0b0b0b0-0000-4000-8000-000000000001";
const CHAT = "c0c0c0c0-0000-4000-8000-000000000001";
const ref = (n: number) => n.toString(16).padStart(64, "0");
const SAID = "2026-10-22T09:00:00Z";
const userRow = (n: number, over: Record<string, unknown> = {}) => ({ mac_ref: ref(n), role: "user", body: `보낸 글 ${n}`, truncated: false, said_at: SAID, ...over });
const asstRow = (n: number, reply: number, over: Record<string, unknown> = {}) => ({ mac_ref: ref(n), role: "assistant", reply_to_ref: ref(reply), body: `답 글 ${n}`, truncated: false, said_at: SAID, tool_names: ["Read", "Edit"], ...over });
const payload = (messages: unknown[] = [userRow(1), asstRow(2, 1)], over: Record<string, unknown> = {}) => ({ bridge_id: BRIDGE, session_ref: ref(900), title: "내 세션 제목", messages, ...over });

function deps(over: Partial<ClaudeAppChatsDeps<TestUser>> = {}) {
  const save = vi.fn(async (): Promise<ClaudeAppChatSaveOutcome> => ({ status: "ok", chat_id: CHAT, saved: 2, existing: 0, orphan: 0 }));
  const remove = vi.fn(async (): Promise<"deleted" | "not_found"> => "deleted");
  const recordSent = vi.fn(async () => {});
  const takeLimit = vi.fn(async (): Promise<Date | null> => null);
  const takeSentLimit = vi.fn(async (): Promise<Date | null> => null);
  const takeDailyLimit = vi.fn(async (): Promise<Date | null> => null);
  const authenticate = vi.fn(async () => ({ user: { id: USER } }));
  const betaAllowed = vi.fn(() => true);
  const value: ClaudeAppChatsDeps<TestUser> = { enabled: () => true, sentEnabled: () => true, authenticate, betaAllowed, takeLimit, takeDailyLimit, takeSentLimit, save, remove, recordSent, ...over };
  return { value, save, remove, recordSent, takeLimit, takeDailyLimit, takeSentLimit, authenticate, betaAllowed };
}

const put = (body: unknown, headers: Record<string, string> = {}) =>
  new Request("https://api.example.dev/api/v2/claude-app-chats", { method: "PUT", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
const get = () => new Request("https://api.example.dev/api/v2/claude-app-chats/status", { method: "GET" });
const del = () => new Request(`https://api.example.dev/api/v2/claude-app-chats/${CHAT}`, { method: "DELETE" });
const sent = (body: unknown) =>
  new Request("https://api.example.dev/api/v2/external-sessions/claude-app-sent", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });

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

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

// ───────────────────────── GET status ─────────────────────────

describe("GET /api/v2/claude-app-chats/status", () => {
  it("저장 플래그가 꺼져 있으면 404: 인증 · DB 0 (Mac은 글을 한 바이트도 보내지 않는다)", async () => {
    const d = deps({ enabled: () => false });
    const response = await handleClaudeAppChatStatus(get(), d.value);
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "not_found" } });
    expect(d.authenticate).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401, 베타 명단 밖이면 404", async () => {
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleClaudeAppChatStatus(get(), anonymous.value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleClaudeAppChatStatus(get(), outside.value)).status).toBe(404);
  });

  it("켜져 있으면 { save: true, max_batch: 20, max_bytes: 262144 }뿐이다 (max_bytes = 요청 본문 상한 256 KiB: Mac이 묶음을 이 크기로 나눈다)", async () => {
    const d = deps();
    const response = await handleClaudeAppChatStatus(get(), d.value);
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body).toEqual({ save: true, max_batch: 20, max_bytes: 262_144 });
    expect(claudeAppChatStatusResponseSchema.parse(body)).toEqual(body);
    expect(d.save).not.toHaveBeenCalled();
    expect(d.takeLimit).not.toHaveBeenCalled();
  });
});

// ───────────────────────── PUT ─────────────────────────

describe("PUT /api/v2/claude-app-chats: 문", () => {
  it("꺼져 있으면 404: 인증 · 속도 제한 · 저장 0", async () => {
    const d = deps({ enabled: () => false });
    const response = await handleSaveClaudeAppChat(put(payload()), d.value);
    expect(response.status).toBe(404);
    expect(d.authenticate).not.toHaveBeenCalled();
    expect(d.takeLimit).not.toHaveBeenCalled();
    expect(d.save).not.toHaveBeenCalled();
  });

  it("로그인하지 않았으면 401, 베타 명단 밖이면 404 (저장 0)", async () => {
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleSaveClaudeAppChat(put(payload()), anonymous.value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleSaveClaudeAppChat(put(payload()), outside.value)).status).toBe(404);
    expect(anonymous.save).not.toHaveBeenCalled();
    expect(outside.save).not.toHaveBeenCalled();
    expect(outside.takeLimit).not.toHaveBeenCalled();
  });
});

describe("PUT /api/v2/claude-app-chats: 저장", () => {
  it("검증한 본문을 그대로 저장 함수에 넘기고 { chat_id, saved, existing, orphan }만 돌려준다 (글 · 제목을 되돌리지 않는다)", async () => {
    const d = deps();
    const body = payload([userRow(1), asstRow(2, 1), asstRow(3, 1, { tool_names: [], truncated: true })]);
    const response = await handleSaveClaudeAppChat(put(body), d.value);
    expect(response.status).toBe(200);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ chat_id: CHAT, saved: 2, existing: 0, orphan: 0 });
    expect(claudeAppChatSaveResponseSchema.safeParse(JSON.parse(text)).success).toBe(true);
    expect(text).not.toMatch(/보낸 글|답 글|세션 제목|Read/);
    expect(d.takeLimit).toHaveBeenCalledTimes(1);
    expect(d.save).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, body);
    // 속도 제한이 저장보다 먼저다
    expect(d.takeLimit.mock.invocationCallOrder[0]).toBeLessThan(d.save.mock.invocationCallOrder[0]);
  });

  it("사용자 id는 인증에서만 온다: 본문의 user_id 칸은 400이다 (저장 0)", async () => {
    const d = deps();
    expect((await handleSaveClaudeAppChat(put(payload([userRow(1)], { user_id: "22222222-0000-4000-8000-000000000002" })), d.value)).status).toBe(400);
    expect(d.save).not.toHaveBeenCalled();
  });

  it("title과 tool_names는 선택이다 (title 없음 = 제목 없음 null, tool_names 없음 = 없음)", async () => {
    const d = deps();
    const { title: _title, ...noTitle } = payload([userRow(1), { ...asstRow(2, 1), tool_names: undefined }]);
    void _title;
    expect((await handleSaveClaudeAppChat(put(noTitle), d.value)).status).toBe(200);
    expect(d.save).toHaveBeenCalledTimes(1);
    expect((await handleSaveClaudeAppChat(put(payload([userRow(1)], { title: null })), d.value)).status).toBe(200);
  });

  it("채팅이 되살아나지 않은 묶음(chat_id null)도 200으로 개수를 알린다", async () => {
    const d = deps({ save: async () => ({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 1 }) });
    const response = await handleSaveClaudeAppChat(put(payload([asstRow(2, 1)])), d.value);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ chat_id: null, saved: 0, existing: 0, orphan: 1 });
  });

  it("없는 · 남의 · 해제된 bridge는 404 **bridge_not_found** — 저장 gate가 꺼진 404(not_found)와 코드가 다르다 (Mac이 둘을 헷갈리지 않는다). 존재를 알리지는 않는다", async () => {
    const d = deps({ save: async () => ({ status: "not_found" }) });
    const response = await handleSaveClaudeAppChat(put(payload()), d.value);
    expect(response.status).toBe(404);
    const body = await response.json();
    expect(body).toMatchObject({ error: { code: "bridge_not_found" } });
    expect(JSON.stringify(body)).not.toMatch(/b0b0b0b0|11111111/);
    // gate가 꺼진 404는 not_found 그대로다
    const off = await handleSaveClaudeAppChat(put(payload()), deps({ enabled: () => false }).value);
    expect(off.status).toBe(404);
    expect(await off.json()).toMatchObject({ error: { code: "not_found" } });
    const status = await handleClaudeAppChatStatus(get(), deps({ betaAllowed: () => false }).value);
    expect(await status.json()).toMatchObject({ error: { code: "not_found" } });
  });

  it("사용자별 한도(저장 본문 50 MiB · 채팅 2,000개)를 넘기면 413 quota_exceeded: 아무것도 되돌리지 않는다 (글 · 제목 · ref · id 0)", async () => {
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    const d = deps({ save: async () => ({ status: "quota_exceeded" }) });
    const response = await handleSaveClaudeAppChat(put(payload()), d.value);
    expect(response.status).toBe(413);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ error: { code: "quota_exceeded", message: expect.any(String) } });
    expect(text).not.toMatch(/보낸 글|답 글|세션 제목|Read|b0b0b0b0|11111111/);
    expect(JSON.stringify(info.mock.calls)).toContain("quota_exceeded");
    expect(JSON.stringify(info.mock.calls)).not.toMatch(/보낸 글|답 글|세션 제목/);
  });

  it("DB가 22023(인자 모양)을 던져도 500이 아니라 400 invalid_request다 (요청 값을 되돌리지 않는다)", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = deps({ save: async () => Promise.reject(Object.assign(new Error("save_claude_app_chat: invalid message 보낸 글"), { code: "22023" })) });
    const response = await handleSaveClaudeAppChat(put(payload()), d.value);
    expect(response.status).toBe(400);
    const text = await response.text();
    expect(JSON.parse(text)).toMatchObject({ error: { code: "invalid_request" } });
    expect(text).not.toMatch(/보낸 글|invalid message/);
    expect(JSON.stringify(error.mock.calls)).not.toMatch(/보낸 글|invalid message/);
  });

  it("속도 제한: 10분 한도에 찼으면 429 + Retry-After, 저장 0 (하루 한도는 건드리지 않는다)", async () => {
    const d = deps({ takeLimit: async () => new Date(Date.now() + 90_000) });
    const response = await handleSaveClaudeAppChat(put(payload()), d.value);
    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: { code: "rate_limited" } });
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThanOrEqual(89);
    expect(d.save).not.toHaveBeenCalled();
    expect(d.takeDailyLimit).not.toHaveBeenCalled();
  });

  it("하루 한도(claude_app_chat_day, 사용자별 하루 1,000번)에 찼으면 429 + Retry-After, 저장 0. 10분 한도를 먼저 세고 그 뒤에 하루 한도를 센다", async () => {
    const d = deps({ takeDailyLimit: async () => new Date(Date.now() + 3 * 3600_000) });
    const response = await handleSaveClaudeAppChat(put(payload()), d.value);
    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: { code: "rate_limited" } });
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThanOrEqual(3 * 3600 - 2);
    expect(d.save).not.toHaveBeenCalled();
    expect(d.takeLimit).toHaveBeenCalledTimes(1);
    const ok = deps();
    expect((await handleSaveClaudeAppChat(put(payload()), ok.value)).status).toBe(200);
    expect(ok.takeLimit.mock.invocationCallOrder[0]).toBeLessThan(ok.takeDailyLimit.mock.invocationCallOrder[0]);
    expect(ok.takeDailyLimit.mock.invocationCallOrder[0]).toBeLessThan(ok.save.mock.invocationCallOrder[0]);
  });

  it("잘못된 본문(400)은 하루 한도도 쓰지 않는다", async () => {
    const d = deps();
    expect((await handleSaveClaudeAppChat(put(payload([])), d.value)).status).toBe(400);
    expect(d.takeLimit).not.toHaveBeenCalled();
    expect(d.takeDailyLimit).not.toHaveBeenCalled();
  });

  it("속도 제한은 사용자별 10분에 120번 · 하루 1,000번이다", () => {
    expect(CLAUDE_APP_CHAT_LIMIT).toEqual({ max: 120, windowMs: 10 * 60_000 });
    expect(CLAUDE_APP_CHAT_DAILY_LIMIT).toEqual({ max: 1000, windowMs: 24 * 3600_000 });
  });

  it("잠금 경합(40001 · 40P01 · 55P03)은 409 busy_retry (500 아님), 그 밖의 오류는 500", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    for (const code of ["40001", "40P01", "55P03"]) {
      const d = deps({ save: async () => Promise.reject(Object.assign(new Error("x"), { code })) });
      const response = await handleSaveClaudeAppChat(put(payload()), d.value);
      expect(response.status, code).toBe(409);
      expect(await response.json()).toMatchObject({ error: { code: "busy_retry" } });
    }
    const failing = deps({ save: async () => Promise.reject(Object.assign(new Error("x"), { code: "XX000" })) });
    expect((await handleSaveClaudeAppChat(put(payload()), failing.value)).status).toBe(500);
  });
});

describe("PUT /api/v2/claude-app-chats: 본문 검증", () => {
  const long = (n: number, ch = "a") => ch.repeat(n);
  const cases: [string, unknown][] = [
    ["모르는 최상위 칸", { ...payload(), path: "/Users/me" }],
    ["bridge_id가 uuid가 아님", payload(undefined, { bridge_id: "nope" })],
    ["session_ref가 Claude 세션 UUID 모양", payload(undefined, { session_ref: "5e5e5e5e-0000-4000-8000-000000000001" })],
    ["session_ref가 대문자 hex", payload(undefined, { session_ref: "A".repeat(64) })],
    ["제목이 201자", payload(undefined, { title: long(201, "가") })],
    ["제목이 빈 글자", payload(undefined, { title: "" })],
    ["제목에 제어 글자", payload(undefined, { title: "a\nb" })],
    ["제목에 방향 바꿈 글자", payload(undefined, { title: "a‮b" })],
    ["제목에 짝 없는 서로게이트(높은 쪽)", payload(undefined, { title: "a\uD800b" })],
    ["제목에 짝 없는 서로게이트(낮은 쪽)", payload(undefined, { title: "a\uDC00b" })],
    ["messages 없음", { bridge_id: BRIDGE, session_ref: ref(900) }],
    ["messages 빈 배열", payload([])],
    ["21행", payload(Array.from({ length: 21 }, (_, n) => userRow(n + 1)))],
    ["mac_ref 대문자", payload([userRow(1, { mac_ref: "A".repeat(64) })])],
    ["mac_ref 63자", payload([userRow(1, { mac_ref: "a".repeat(63) })])],
    ["mac_ref가 사용자 글 id 모양(UUID)", payload([userRow(1, { mac_ref: "5e5e5e5e-0000-4000-8000-000000000001" })])],
    ["mac_ref 중복", payload([userRow(1), userRow(1, { body: "다른 글" })])],
    ["role 모름", payload([userRow(1, { role: "system" })])],
    ["role 도구(tool)", payload([userRow(1, { role: "tool" })])],
    ["모르는 행 칸(경로)", payload([userRow(1, { cwd: "/Users/me/project" })])],
    ["모르는 행 칸(도구 입력)", payload([userRow(1), asstRow(2, 1, { tool_input: { command: "ls" } })])],
    ["모르는 행 칸(도구 결과)", payload([userRow(1), asstRow(2, 1, { tool_result: "x" })])],
    ["모르는 행 칸(Claude 세션 id)", payload([userRow(1, { session_id: "5e5e5e5e-0000-4000-8000-000000000001" })])],
    ["본문이 글이 아님", payload([userRow(1, { body: 5 })])],
    ["본문이 빈 글", payload([userRow(1, { body: "" })])],
    ["본문에 NUL", payload([userRow(1, { body: "a\u0000b" })])],
    ["사용자 글 16,001자", payload([userRow(1, { body: long(16_001, "가") })])],
    ["답 글이 64 KiB 초과(바이트)", payload([userRow(1), asstRow(2, 1, { body: long(21_846, "가") })])],
    ["truncated가 불리언이 아님", payload([userRow(1, { truncated: "false" })])],
    ["said_at이 시각이 아님", payload([userRow(1, { said_at: "yesterday" })])],
    ["said_at에 시간대 없음", payload([userRow(1, { said_at: "2026-10-22T09:00:00" })])],
    ["답 글에 reply_to_ref 없음", payload([userRow(1), { ...asstRow(2, 1), reply_to_ref: undefined }])],
    ["사용자 글에 reply_to_ref", payload([userRow(1, { reply_to_ref: ref(1) })])],
    ["reply_to_ref 대문자", payload([userRow(1), asstRow(2, 1, { reply_to_ref: "B".repeat(64) })])],
    ["사용자 글에 tool_names", payload([userRow(1, { tool_names: ["Read"] })])],
    ["도구 이름 41개", payload([userRow(1), asstRow(2, 1, { tool_names: Array.from({ length: 41 }, (_, i) => `T${i}`) })])],
    ["도구 이름이 경로", payload([userRow(1), asstRow(2, 1, { tool_names: ["/Users/me/project/a.ts"] })])],
    ["도구 이름이 명령", payload([userRow(1), asstRow(2, 1, { tool_names: ["Bash(git status)"] })])],
    ["도구 이름에 공백", payload([userRow(1), asstRow(2, 1, { tool_names: ["Read file"] })])],
    ["도구 이름이 129자", payload([userRow(1), asstRow(2, 1, { tool_names: [long(129)] })])],
    ["도구 이름이 빈 글", payload([userRow(1), asstRow(2, 1, { tool_names: [""] })])],
    ["도구 이름이 객체(입력 포함)", payload([userRow(1), asstRow(2, 1, { tool_names: [{ name: "Bash", input: { command: "ls" } }] })])],
    ["tool_names가 문자열", payload([userRow(1), asstRow(2, 1, { tool_names: "Read" })])],
  ];

  it.each(cases)("잘못된 본문은 400이고 저장하지 않는다: %s", async (_name, body) => {
    const d = deps();
    const response = await handleSaveClaudeAppChat(put(body), d.value);
    expect(response.status).toBe(400);
    expect(d.save).not.toHaveBeenCalled();
    expect(d.takeLimit).not.toHaveBeenCalled();
    // 오류 문구는 요청 값(글 · 제목 · 경로)을 담지 않는다
    expect(JSON.stringify(await response.json())).not.toMatch(/보낸 글|답 글|세션 제목|\/Users|가가가|git status/);
  });

  it("JSON \\ud800 같은 짝 없는 서로게이트는 400 (저장 함수에서 jsonb가 깨지지 않게)", async () => {
    const d = deps();
    const raw = JSON.stringify(payload([userRow(1, { body: "XX" })])).replace('"XX"', '"\\ud800"');
    const response = await handleSaveClaudeAppChat(new Request("https://api.example.dev/api/v2/claude-app-chats", { method: "PUT", headers: { "content-type": "application/json" }, body: raw }), d.value);
    expect(response.status).toBe(400);
    expect(d.save).not.toHaveBeenCalled();
    const ok = JSON.stringify(payload([userRow(1, { body: "😀 이모지 한글 \\n 줄바꿈" })]));
    expect((await handleSaveClaudeAppChat(new Request("https://api.example.dev/api/v2/claude-app-chats", { method: "PUT", headers: { "content-type": "application/json" }, body: ok }), d.value)).status).toBe(200);
  });

  it("실제 Claude Code MCP 도구 이름은 64자를 넘는다 (mcp__<uuid 36자>__<도구>: 83자 등) — 128자까지 받는다", async () => {
    const d = deps();
    const mcpLong = "mcp__2efc4ad4-301d-4293-82c1-3118287aa3b4__notion-show-advanced-analysis-next-steps";
    expect(mcpLong.length).toBeGreaterThan(64);
    expect((await handleSaveClaudeAppChat(put(payload([userRow(1), asstRow(2, 1, { tool_names: [mcpLong, long(128)] })])), d.value)).status).toBe(200);
    expect(d.save).toHaveBeenCalledTimes(1);
  });

  it("said_at의 소수 초는 자릿수 제한 없이 받는다 (SQL이 같은 모양을 받는다)", async () => {
    const d = deps();
    const response = await handleSaveClaudeAppChat(put(payload([userRow(1, { said_at: "2026-10-22T09:00:00.123456789012Z" }), userRow(2, { said_at: `2026-10-22T09:00:00.${"1".repeat(30)}+09:00` })])), d.value);
    expect(response.status).toBe(200);
  });

  it("경계값은 받는다: 20행 · 사용자 글 16,000자 · 답 글 64 KiB · 도구 이름 40개 · 제목 200자 · 줄바꿈 · 탭", async () => {
    const d = deps();
    const rows = [
      userRow(1, { body: long(16_000, "가") }),
      asstRow(2, 1, { body: long(65_536), tool_names: Array.from({ length: 40 }, (_, i) => `mcp__server_${i}__tool-name`.slice(0, 128)) }),
      ...Array.from({ length: 17 }, (_, n) => asstRow(3 + n, 1, { body: "줄1\n줄2\t탭\r\n" })),
      asstRow(20, 1, { body: long(21_845, "가") }),
    ];
    expect(rows).toHaveLength(20);
    const response = await handleSaveClaudeAppChat(put(payload(rows, { title: long(200, "가") })), d.value);
    expect(response.status).toBe(200);
    expect(d.save).toHaveBeenCalledTimes(1);
  });

  it("본문 상한 256 KiB: Content-Length가 크면 읽지 않고 400, 없어도 상한까지만 읽고 400 (끝없는 본문을 다 읽지 않는다)", async () => {
    const d = deps();
    expect((await handleSaveClaudeAppChat(put(payload(), { "content-length": String(300 * 1024) }), d.value)).status).toBe(400);
    const pulled = { n: 0 };
    const stream = new Request("https://api.example.dev/api/v2/claude-app-chats", { method: "PUT", headers: { "content-type": "application/json" }, body: endless(32 * 1024, pulled), duplex: "half" } as RequestInit);
    expect((await handleSaveClaudeAppChat(stream, d.value)).status).toBe(400);
    expect(pulled.n).toBeLessThanOrEqual(10);
    // 256 KiB를 넘는 정상 모양의 본문도 거절한다 (3 × 64 KiB 답 글 + 사용자 글)
    const big = payload([userRow(1), ...Array.from({ length: 5 }, (_, n) => asstRow(2 + n, 1, { body: "a".repeat(65_536) }))]);
    expect(JSON.stringify(big).length).toBeGreaterThan(256 * 1024);
    expect((await handleSaveClaudeAppChat(put(big), d.value)).status).toBe(400);
    expect(d.save).not.toHaveBeenCalled();
    // 상한 안(4 × 64 KiB 미만)은 받는다
    const fits = payload([userRow(1), ...Array.from({ length: 3 }, (_, n) => asstRow(2 + n, 1, { body: "a".repeat(65_536) }))]);
    expect(JSON.stringify(fits).length).toBeLessThan(256 * 1024);
    expect((await handleSaveClaudeAppChat(put(fits), d.value)).status).toBe(200);
  });
});

describe("로그에 글이 없다", () => {
  it("성공 · 실패 어느 경로에서도 로그는 이벤트 이름 · 결과 코드 · 오류 이름 · 코드뿐이다 (글 · 제목 · ref · id 0)", async () => {
    const info = vi.spyOn(console, "info").mockImplementation(() => {});
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const secret = Object.assign(new Error(`보낸 글 1 내 세션 제목 /Users/me ${ref(1)} ${BRIDGE}`), { code: "XX000" });
    await handleSaveClaudeAppChat(put(payload()), deps().value);
    await handleSaveClaudeAppChat(put(payload()), deps({ save: async () => ({ status: "not_found" }) }).value);
    await handleSaveClaudeAppChat(put(payload()), deps({ takeLimit: async () => new Date(Date.now() + 1000) }).value);
    await handleSaveClaudeAppChat(put(payload()), deps({ save: async () => Promise.reject(secret) }).value);
    await handleSaveClaudeAppChat(put(payload()), deps({ save: async () => ({ status: "quota_exceeded" }) }).value);
    await handleSaveClaudeAppChat(put(payload()), deps({ takeDailyLimit: async () => new Date(Date.now() + 1000) }).value);
    await handleSaveClaudeAppChat(put(payload()), deps({ save: async () => Promise.reject(Object.assign(secret, { code: "22023" })) }).value);
    Object.assign(secret, { code: "XX000" });
    await handleSaveClaudeAppChat(put(payload([userRow(1, { body: "" })])), deps().value);
    await handleDeleteClaudeAppChat(del(), CHAT, deps().value);
    await handleDeleteClaudeAppChat(del(), CHAT, deps({ remove: async () => Promise.reject(secret) }).value);
    await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), deps().value);
    await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), deps({ recordSent: async () => Promise.reject(secret) }).value);
    await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), deps({ takeSentLimit: async () => new Date(Date.now() + 1000) }).value);
    await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), deps({ takeSentLimit: async () => Promise.reject(secret) }).value);
    const logged = JSON.stringify([info.mock.calls, error.mock.calls, warn.mock.calls, log.mock.calls]);
    expect(logged).toContain("claude_app_chat_save");
    expect(logged).toContain("claude_app_chat_save_failed");
    expect(logged).not.toMatch(/보낸 글|답 글|세션 제목|\/Users|0000000000000001|b0b0b0b0|c0c0c0c0|11111111|Read|Edit/);
    // 구조화된 한 줄 JSON이다
    for (const [line] of [...info.mock.calls, ...error.mock.calls]) expect(() => JSON.parse(String(line))).not.toThrow();
  });
});

// ───────────────────────── DELETE ─────────────────────────

describe("DELETE /api/v2/claude-app-chats/{id}", () => {
  // 저장된 데이터를 지우는 길은 늘 열려 있다 (BYOK 키 DELETE와 같다: gate · 베타 명단을 보지 않고, 로그인 · 쿠키 CSRF · 자기 행만).
  it("로그인하지 않았으면 401: 아무것도 지우지 않는다 (인증이 첫 검사다)", async () => {
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleDeleteClaudeAppChat(del(), CHAT, anonymous.value)).status).toBe(401);
    expect(anonymous.remove).not.toHaveBeenCalled();
    // 로그인하지 않은 요청은 id 모양도 알려 주지 않는다 (401이 404보다 먼저다)
    expect((await handleDeleteClaudeAppChat(del(), "nope", anonymous.value)).status).toBe(401);
  });

  it("저장 플래그 · 대화 v2 · adapter 플래그가 모두 꺼져 있어도 지운다 (enabled · sentEnabled 모두 false) — 저장된 데이터는 늘 지울 수 있다", async () => {
    const d = deps({ enabled: () => false, sentEnabled: () => false });
    const response = await handleDeleteClaudeAppChat(del(), CHAT, d.value);
    expect(response.status).toBe(204);
    expect(d.authenticate).toHaveBeenCalledTimes(1);
    expect(d.remove).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, CHAT);
  });

  it("베타 명단을 보지 않는다: 명단 밖 사용자도 자기 대화를 지운다 (명단은 새 저장을 여는 문이지 지우는 문이 아니다)", async () => {
    const d = deps({ betaAllowed: () => false });
    expect((await handleDeleteClaudeAppChat(del(), CHAT, d.value)).status).toBe(204);
    expect(d.betaAllowed).not.toHaveBeenCalled();
    expect(d.remove).toHaveBeenCalledTimes(1);
  });

  it("지우면 204 + Cache-Control no-store(BYOK 키 DELETE와 같다). 지우는 것은 인증된 사용자의 채팅뿐이다", async () => {
    const d = deps();
    const response = await handleDeleteClaudeAppChat(del(), CHAT, d.value);
    expect(response.status).toBe(204);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.text()).toBe("");
    expect(d.remove).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, CHAT);
  });

  it("없는 · 남의 id는 404, uuid가 아닌 id도 404 (함수를 부르지 않는다)", async () => {
    const missing = deps({ remove: async () => "not_found" });
    const response = await handleDeleteClaudeAppChat(del(), CHAT, missing.value);
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "not_found" } });
    const d = deps();
    for (const id of ["nope", "", "../status", "c0c0c0c0-0000-4000-8000-00000000000g", `${CHAT}x`, "%20"]) {
      expect((await handleDeleteClaudeAppChat(del(), id, d.value)).status, id).toBe(404);
    }
    expect(d.remove).not.toHaveBeenCalled();
  });

  it("실패하면 500 (잠금 경합은 409 busy_retry)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect((await handleDeleteClaudeAppChat(del(), CHAT, deps({ remove: async () => Promise.reject(new Error("x")) }).value)).status).toBe(500);
    const busy = deps({ remove: async () => Promise.reject(Object.assign(new Error("x"), { code: "55P03" })) });
    expect((await handleDeleteClaudeAppChat(del(), CHAT, busy.value)).status).toBe(409);
  });
});

// ───────────────────────── POST claude-app-sent ─────────────────────────

describe("POST /api/v2/external-sessions/claude-app-sent", () => {
  it("저장 플래그와 무관하다: 저장이 꺼져 있어도(enabled false) 기본 gate(sentEnabled)만 켜져 있으면 열린다", async () => {
    const d = deps({ enabled: () => false, sentEnabled: () => true });
    const response = await handleClaudeAppSent(sent({ result: "not_sent", reason: "session_closed" }), d.value);
    expect(response.status).toBe(204);
    expect(d.recordSent).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, { result: "not_sent", reason: "session_closed" });
  });

  it("기본 gate가 꺼져 있으면 404: 인증 · 저장 0, 로그인하지 않았으면 401, 베타 명단 밖이면 404", async () => {
    const off = deps({ sentEnabled: () => false });
    expect((await handleClaudeAppSent(sent({ result: "received" }), off.value)).status).toBe(404);
    expect(off.authenticate).not.toHaveBeenCalled();
    expect((await handleClaudeAppSent(sent({ result: "received" }), deps({ authenticate: async () => null }).value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleClaudeAppSent(sent({ result: "received" }), outside.value)).status).toBe(404);
    expect(off.recordSent).not.toHaveBeenCalled();
    expect(outside.recordSent).not.toHaveBeenCalled();
    expect(off.takeSentLimit).not.toHaveBeenCalled();
    expect(outside.takeSentLimit).not.toHaveBeenCalled();
  });

  it("속도 제한은 사용자별 10분에 120번이고 저장(claude_app_chat)과 따로 센다", () => {
    expect(CLAUDE_APP_SENT_LIMIT).toEqual({ max: 120, windowMs: 10 * 60_000 });
    expect(CLAUDE_APP_CHAT_LIMIT).toEqual({ max: 120, windowMs: 10 * 60_000 });
  });

  it("지표를 남기기 전에 속도 제한을 센다 (저장 속도 제한 takeLimit은 쓰지 않는다): 한도에 찼으면 429 + Retry-After, 지표 0", async () => {
    const d = deps({ takeSentLimit: async () => new Date(Date.now() + 90_000) });
    const response = await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), d.value);
    expect(response.status).toBe(429);
    expect(await response.json()).toMatchObject({ error: { code: "rate_limited" } });
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThanOrEqual(89);
    expect(d.recordSent).not.toHaveBeenCalled();
    expect(d.takeLimit).not.toHaveBeenCalled();
    const ok = deps();
    expect((await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), ok.value)).status).toBe(204);
    expect(ok.takeSentLimit).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } });
    expect(ok.takeSentLimit.mock.invocationCallOrder[0]).toBeLessThan(ok.recordSent.mock.invocationCallOrder[0]);
    expect(ok.takeLimit).not.toHaveBeenCalled();
  });

  it("아무것도 쓰지 않는 호출(저장이 켜져 있을 때의 received · 잘못된 본문)은 속도 제한도 쓰지 않는다", async () => {
    const on = deps({ enabled: () => true });
    expect((await handleClaudeAppSent(sent({ result: "received" }), on.value)).status).toBe(204);
    expect(on.takeSentLimit).not.toHaveBeenCalled();
    const bad = deps();
    expect((await handleClaudeAppSent(sent({ result: "queued" }), bad.value)).status).toBe(400);
    expect(bad.takeSentLimit).not.toHaveBeenCalled();
  });

  it("not_sent는 이유와 함께(또는 이유 없이) 지표로 남기고 204", async () => {
    for (const reason of ["session_closed", "not_received", "bypass", "two_writers", "relay_failed"]) {
      const d = deps();
      expect((await handleClaudeAppSent(sent({ result: "not_sent", reason }), d.value)).status, reason).toBe(204);
      expect(d.recordSent).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, { result: "not_sent", reason });
    }
    const bare = deps();
    expect((await handleClaudeAppSent(sent({ result: "not_sent" }), bare.value)).status).toBe(204);
    expect(bare.recordSent).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, { result: "not_sent" });
  });

  it("received: 저장이 꺼져 있으면 지표로 남기고, 저장이 켜져 있으면 남기지 않는다 (save_claude_app_chat이 남기므로 두 번 세지 않는다)", async () => {
    const off = deps({ enabled: () => false });
    expect((await handleClaudeAppSent(sent({ result: "received" }), off.value)).status).toBe(204);
    expect(off.recordSent).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, { result: "received" });
    const on = deps({ enabled: () => true });
    expect((await handleClaudeAppSent(sent({ result: "received" }), on.value)).status).toBe(204);
    expect(on.recordSent).not.toHaveBeenCalled();
    // not_sent는 저장이 켜져 있어도 남긴다
    expect((await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), on.value)).status).toBe(204);
    expect(on.recordSent).toHaveBeenCalledTimes(1);
  });

  it("received + uploaded:false = Mac이 올리기를 포기했다(10분 재시도 끝에 버림): 저장이 켜져 있어도 지표로 센다 (저장 함수가 못 센 받은 글). uploaded true · 생략은 저장이 켜져 있으면 세지 않는다", async () => {
    const on = deps({ enabled: () => true });
    expect((await handleClaudeAppSent(sent({ result: "received", uploaded: false }), on.value)).status).toBe(204);
    expect(on.recordSent).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, { result: "received" });
    expect(on.takeSentLimit).toHaveBeenCalledTimes(1);
    on.recordSent.mockClear();
    for (const body of [{ result: "received", uploaded: true }, { result: "received" }]) expect((await handleClaudeAppSent(sent(body), on.value)).status).toBe(204);
    expect(on.recordSent).not.toHaveBeenCalled();
    // 저장이 꺼져 있으면 uploaded 값과 상관없이 센다 (props에는 result만 남는다)
    const off = deps({ enabled: () => false });
    for (const body of [{ result: "received", uploaded: false }, { result: "received", uploaded: true }, { result: "received" }]) expect((await handleClaudeAppSent(sent(body), off.value)).status).toBe(204);
    expect((off.recordSent.mock.calls as unknown[][]).map((call) => call[1])).toEqual([{ result: "received" }, { result: "received" }, { result: "received" }]);
  });

  it.each<[string, unknown]>([
    ["본문 없음", {}],
    ["result 모름", { result: "queued" }],
    ["result sent", { result: "sent" }],
    ["이유 모름", { result: "not_sent", reason: "network" }],
    ["received에 이유", { result: "received", reason: "bypass" }],
    ["uploaded가 불리언이 아님", { result: "received", uploaded: "no" }],
    ["not_sent에 uploaded", { result: "not_sent", reason: "bypass", uploaded: false }],
    ["글 칸", { result: "not_sent", reason: "bypass", body: "보낸 글" }],
    ["제목 칸", { result: "received", title: "세션 제목" }],
    ["session_ref 칸", { result: "received", session_ref: ref(1) }],
    ["user_id 칸", { result: "received", user_id: USER }],
  ])("잘못된 본문은 400이고 지표를 남기지 않는다: %s", async (_name, body) => {
    const d = deps({ enabled: () => false });
    const response = await handleClaudeAppSent(sent(body), d.value);
    expect(response.status).toBe(400);
    expect(d.recordSent).not.toHaveBeenCalled();
    expect(JSON.stringify(await response.json())).not.toMatch(/보낸 글|세션 제목/);
  });

  it("본문은 1 KiB까지만 읽는다: Content-Length가 없어도 끝없는 본문에 400", async () => {
    const d = deps({ enabled: () => false });
    const pulled = { n: 0 };
    const stream = new Request("https://api.example.dev/api/v2/external-sessions/claude-app-sent", { method: "POST", headers: { "content-type": "application/json" }, body: endless(512, pulled), duplex: "half" } as RequestInit);
    expect((await handleClaudeAppSent(stream, d.value)).status).toBe(400);
    expect(pulled.n).toBeLessThanOrEqual(6);
    expect(d.recordSent).not.toHaveBeenCalled();
  });

  it("지표를 남기지 못하면 500이고 로그에 오류 이름과 코드뿐이다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = deps({ recordSent: async () => Promise.reject(Object.assign(new Error("secret detail"), { code: "XX000" })) });
    expect((await handleClaudeAppSent(sent({ result: "not_sent", reason: "bypass" }), d.value)).status).toBe(500);
    expect(JSON.stringify(error.mock.calls)).not.toContain("secret detail");
    expect(JSON.stringify(error.mock.calls)).toContain("claude_app_sent_failed");
  });
});

// ───────────────────────── 스키마 ─────────────────────────

describe("계약 스키마", () => {
  it("요청 모양: 위 사례 외에도 strict(모르는 칸 400) · 반드시 배열 1–20", () => {
    expect(claudeAppChatSaveRequestSchema.safeParse(payload()).success).toBe(true);
    expect(claudeAppChatSaveRequestSchema.safeParse(payload([])).success).toBe(false);
    expect(claudeAppChatSaveRequestSchema.safeParse({ ...payload(), extra: 1 }).success).toBe(false);
    expect(claudeAppSentRequestSchema.safeParse({ result: "received" }).success).toBe(true);
    expect(claudeAppSentRequestSchema.safeParse({ result: "received", uploaded: false }).success).toBe(true);
  });

  it("오류 코드: bridge_not_found · quota_exceeded는 이 route의 오류 코드 목록(v2 에이전트 코드 + 둘)에 든다 (not_found와 따로: Mac이 gate 꺼짐과 bridge 모름을 구별한다). 옛 v2 에이전트 코드 목록(길이를 고정하는 시험이 있다)은 그대로다", () => {
    expect([...claudeAppChatErrorCodeSchema.options]).toEqual(["bridge_not_found", "quota_exceeded"]);
    for (const code of claudeAppChatErrorCodeSchema.options) expect(apiErrorV2ClaudeAppChatCodeSchema.options).toContain(code);
    for (const code of apiErrorV2AgentCodeSchema.options) expect(apiErrorV2ClaudeAppChatCodeSchema.options).toContain(code);
    expect(apiErrorV2ClaudeAppChatCodeSchema.options).toHaveLength(apiErrorV2AgentCodeSchema.options.length + claudeAppChatErrorCodeSchema.options.length);
    for (const code of claudeAppChatErrorCodeSchema.options) expect(apiErrorV2AgentCodeSchema.options).not.toContain(code);
    expect(apiErrorV2AgentCodeSchema.options).toContain("not_found");
  });

  it("응답 모양: chat_id는 uuid이거나 null, 개수는 0 이상 정수", () => {
    expect(claudeAppChatSaveResponseSchema.safeParse({ chat_id: CHAT, saved: 1, existing: 0, orphan: 0 }).success).toBe(true);
    expect(claudeAppChatSaveResponseSchema.safeParse({ chat_id: null, saved: 0, existing: 0, orphan: 2 }).success).toBe(true);
    for (const bad of [{ chat_id: "x", saved: 0, existing: 0, orphan: 0 }, { chat_id: CHAT, saved: -1, existing: 0, orphan: 0 }, { chat_id: CHAT, saved: 1, existing: 0, orphan: 0, body: "x" }]) {
      expect(claudeAppChatSaveResponseSchema.safeParse(bad).success, JSON.stringify(bad)).toBe(false);
    }
  });
});

// ───────────────────────── 실제 deps · 서버가 시작하는 보내기 길 0 ─────────────────────────

describe("realClaudeAppChatsDeps: gate", () => {
  const FLAGS = { CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true", CLAUDE_APP_CHATS_ENABLED: "true" };
  const stub = (env: Record<string, string>) => {
    for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
  };

  it("저장 gate = 대화 v2 ∧ Claude Code adapter ∧ CLAUDE_APP_CHATS_ENABLED (기본 꺼짐): 하나라도 빠지면 꺼진다", () => {
    expect(realClaudeAppChatsDeps().enabled()).toBe(false);
    stub(FLAGS);
    expect(realClaudeAppChatsDeps().enabled()).toBe(true);
    for (const flag of Object.keys(FLAGS)) {
      vi.stubEnv(flag, "false");
      expect(realClaudeAppChatsDeps().enabled(), flag).toBe(false);
      vi.stubEnv(flag, "true");
    }
    for (const value of ["TRUE", "1", " true", "yes", ""]) {
      vi.stubEnv("CLAUDE_APP_CHATS_ENABLED", value);
      expect(realClaudeAppChatsDeps().enabled(), value).toBe(false);
    }
  });

  it("보내기 결과 gate는 저장 플래그와 무관하다: 대화 v2 ∧ adapter만", () => {
    stub({ CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" });
    expect(realClaudeAppChatsDeps().sentEnabled()).toBe(true);
    expect(realClaudeAppChatsDeps().enabled()).toBe(false);
    vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "false");
    expect(realClaudeAppChatsDeps().sentEnabled()).toBe(false);
  });

  it("CLAUDE_APP_CHATS_ENABLED만으로는 열리지 않는다 (다른 gate가 필요하다)", () => {
    stub({ CLAUDE_APP_CHATS_ENABLED: "true" });
    expect(realClaudeAppChatsDeps().enabled()).toBe(false);
    expect(realClaudeAppChatsDeps().sentEnabled()).toBe(false);
  });
});

describe("서버가 시작하는 보내기 길이 없다 (DT3, 25.3)", () => {
  const root = path.resolve(import.meta.dirname, "../../..");
  const here = path.resolve(import.meta.dirname);
  function walk(dir: string): string[] {
    return readdirSync(dir).flatMap((entry) => {
      const full = path.join(dir, entry);
      return statSync(full).isDirectory() ? walk(full) : [full];
    });
  }

  it("저장 코드 · route는 bridge 명령 · 대화 · 에이전트 작업을 만드는 함수와 이어지지 않는다", () => {
    const files = [path.join(here, "claude-app-chats.ts"), ...walk(path.join(root, "src/app/api/v2/claude-app-chats")), path.join(root, "src/app/api/v2/external-sessions/claude-app-sent/route.ts")].filter(
      (file) => /\.ts$/.test(file) && !/\.test\.ts$/.test(file),
    );
    expect(files.length).toBeGreaterThanOrEqual(5);
    for (const file of files) {
      const code = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "");
      expect(code, path.relative(root, file)).not.toMatch(/bridge_commands|start_agent_turn|startAgentTurn|conversation_post_message|agent_tasks|agent_sessions|enqueue|fetch\(/);
    }
  });

  it("route는 요청 메서드만 낸다: status는 GET, 목록은 PUT, 지우기는 DELETE, 보내기 결과는 POST — 서버가 대화를 시작하는 POST는 없다", () => {
    const methods = (file: string) =>
      [...readFileSync(path.join(root, file), "utf8").matchAll(/export async function (GET|POST|PUT|PATCH|DELETE)\b/g)].map((m) => m[1]);
    expect(methods("src/app/api/v2/claude-app-chats/status/route.ts")).toEqual(["GET"]);
    expect(methods("src/app/api/v2/claude-app-chats/route.ts")).toEqual(["PUT"]);
    expect(methods("src/app/api/v2/claude-app-chats/[id]/route.ts")).toEqual(["DELETE"]);
    expect(methods("src/app/api/v2/external-sessions/claude-app-sent/route.ts")).toEqual(["POST"]);
  });

  it("저장된 대화는 AI · 추출 파이프라인 · 코디네이터가 읽지 않는다 (사용자 글이 Claim · Action의 원문이 되지 않는다)", () => {
    const code = ["src/lib/ai", "src/lib/pipeline", "src/lib/coordinator", "src/lib/review", "src/lib/sources", "src/lib/execution"].flatMap((dir) => {
      try {
        return walk(path.join(root, dir)).filter((file) => /\.ts$/.test(file) && !/\.test\.ts$/.test(file));
      } catch {
        return [];
      }
    });
    expect(code.length).toBeGreaterThan(10);
    for (const file of code) expect(readFileSync(file, "utf8"), path.relative(root, file)).not.toMatch(/claude_app_chat/);
  });
});
