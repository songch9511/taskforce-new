import { afterEach, describe, expect, it, vi } from "vitest";

import {
  PROJECT_SESSIONS_OPENED,
  SUBAGENT_QUESTION_REDIRECTED,
  SUBAGENT_ROW_OPENED,
  SUBAGENT_TURN_USED,
  handleAgentTreeDayMetric,
  handleAgentTreeTurnMetric,
  type AgentTreeMetricsDeps,
} from "./agent-tree-metrics";
import { projectSessionsOpenedRequestSchema, subagentQuestionRedirectedRequestSchema, subagentRowOpenedRequestSchema, subagentTurnUsedRequestSchema } from "./contract";

vi.mock("server-only", () => ({}));

// 에이전트 트리 지표 네 종류의 handler (T3s): 인증 · gate · 저장을 인자로 받아 Route Handler 밖에서 시험한다 (external-sessions.ts와 같은 방식).
// 열기 둘(사용자 · UTC 날짜 하루 한 번)은 본문이 빈 객체뿐이고, T2 둘(턴 한 번)은 본문이 { agent_task_id } 하나뿐이다.

const USER = "11111111-0000-4000-8000-000000000001";
const TASK = "7a7a7a7a-0000-4000-8000-000000000001";
type User = { user: { id: string } };

function deps(over: Partial<AgentTreeMetricsDeps<User>> = {}) {
  const recordDay = vi.fn(async (): Promise<"recorded" | "duplicate"> => "recorded");
  const recordTurn = vi.fn(async (): Promise<"recorded" | "duplicate" | "not_found"> => "recorded");
  const authenticate = vi.fn(async () => ({ user: { id: USER } }));
  const value: AgentTreeMetricsDeps<User> = { enabled: () => true, authenticate, betaAllowed: () => true, recordDay, recordTurn, ...over };
  return { value, recordDay, recordTurn, authenticate };
}

const post = (path: string, body: unknown = {}, headers: Record<string, string> = {}) =>
  new Request(`https://api.example.dev/api/v2/agent-tree/${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

afterEach(() => vi.restoreAllMocks());

describe("요청 스키마 넷 (contract.ts)", () => {
  it("열기 둘은 빈 객체만 받는다 (칸이 하나라도 있으면 거절)", () => {
    for (const schema of [projectSessionsOpenedRequestSchema, subagentRowOpenedRequestSchema]) {
      expect(schema.safeParse({}).success).toBe(true);
      for (const body of [{ user_id: USER }, { agent_task_id: TASK }, { title: "x" }, { count: 2 }, null, [], "x"]) expect(schema.safeParse(body).success, JSON.stringify(body)).toBe(false);
    }
  });

  it("T2 둘은 agent_task_id(uuid) 하나만 받는다", () => {
    for (const schema of [subagentTurnUsedRequestSchema, subagentQuestionRedirectedRequestSchema]) {
      expect(schema.safeParse({ agent_task_id: TASK }).success).toBe(true);
      for (const body of [{}, { agent_task_id: "nope" }, { agent_task_id: 7 }, { agent_task_id: null }, { agent_task_id: TASK, extra: 1 }, { agent_task_id: TASK, title: "Fix" }, { task_id: TASK }]) {
        expect(schema.safeParse(body).success, JSON.stringify(body)).toBe(false);
      }
    }
  });
});

describe.each([
  { spec: PROJECT_SESSIONS_OPENED, path: "project-sessions-opened", type: "project_sessions_opened" },
  { spec: SUBAGENT_ROW_OPENED, path: "subagent-opened", type: "subagent_row_opened" },
])("handleAgentTreeDayMetric: $type", ({ spec, path, type }) => {
  it("종류 이름이 이 파일이 남기는 type과 같다", () => {
    expect(spec.type).toBe(type);
  });

  it("꺼져 있으면 404: 인증 · 저장 0. 로그인하지 않았으면 401, 베타 명단 밖이면 404 (저장 0)", async () => {
    const off = deps({ enabled: () => false });
    expect((await handleAgentTreeDayMetric(post(path), spec, off.value)).status).toBe(404);
    expect(off.authenticate).not.toHaveBeenCalled();
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleAgentTreeDayMetric(post(path), spec, anonymous.value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleAgentTreeDayMetric(post(path), spec, outside.value)).status).toBe(404);
    for (const d of [off, anonymous, outside]) expect(d.recordDay).not.toHaveBeenCalled();
  });

  it("본문 없이도 · 빈 객체로도 저장하고 204, 같은 날 두 번째도 204", async () => {
    const d = deps();
    const response = await handleAgentTreeDayMetric(post(path, {}), spec, d.value);
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    expect(d.recordDay).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, type);
    const empty = deps();
    expect((await handleAgentTreeDayMetric(new Request(`https://api.example.dev/api/v2/agent-tree/${path}`, { method: "POST" }), spec, empty.value)).status).toBe(204);
    expect(empty.recordDay).toHaveBeenCalledTimes(1);
    const again = deps({ recordDay: async () => "duplicate" });
    expect((await handleAgentTreeDayMetric(post(path), spec, again.value)).status).toBe(204);
  });

  it.each([{ agent_task_id: TASK }, { user_id: USER }, { title: "Fix launcher" }, { folder: "/Users/me/secret" }, { count: 3 }])("어떤 칸을 실어도 400 (저장 0): %j", async (body) => {
    const d = deps();
    expect((await handleAgentTreeDayMetric(post(path, body), spec, d.value)).status).toBe(400);
    expect(d.recordDay).not.toHaveBeenCalled();
  });

  it("본문은 1 KiB까지만 읽는다: 큰 본문은 400 (저장 0)", async () => {
    const d = deps();
    expect((await handleAgentTreeDayMetric(post(path, { pad: "x".repeat(2048) }), spec, d.value)).status).toBe(400);
    expect(d.recordDay).not.toHaveBeenCalled();
  });

  it("저장 오류는 500이고 로그에는 이벤트 이름 · 오류 이름 · code뿐이다 (오류 문구 · 사용자 id 0)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = deps({ recordDay: async () => Promise.reject(Object.assign(new Error(`secret detail ${USER}`), { code: "XX000" })) });
    const response = await handleAgentTreeDayMetric(post(path), spec, d.value);
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("secret detail");
    const logged = JSON.stringify(log.mock.calls);
    expect(logged).toContain(`${type}_failed`);
    expect(logged).toContain("XX000");
    expect(logged).not.toContain("secret detail");
    expect(logged).not.toContain(USER);
  });
});

describe.each([
  { spec: SUBAGENT_TURN_USED, path: "turn-used", type: "subagent_turn_used" },
  { spec: SUBAGENT_QUESTION_REDIRECTED, path: "question-redirected", type: "subagent_question_redirected" },
])("handleAgentTreeTurnMetric: $type", ({ spec, path, type }) => {
  it("종류 이름이 이 파일이 남기는 type과 같다", () => {
    expect(spec.type).toBe(type);
  });

  it("꺼져 있으면 404: 인증 · 저장 0. 로그인하지 않았으면 401, 베타 명단 밖이면 404 (저장 0)", async () => {
    const off = deps({ enabled: () => false });
    expect((await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK }), spec, off.value)).status).toBe(404);
    expect(off.authenticate).not.toHaveBeenCalled();
    const anonymous = deps({ authenticate: async () => null });
    expect((await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK }), spec, anonymous.value)).status).toBe(401);
    const outside = deps({ betaAllowed: () => false });
    expect((await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK }), spec, outside.value)).status).toBe(404);
    for (const d of [off, anonymous, outside]) expect(d.recordTurn).not.toHaveBeenCalled();
  });

  it("agent_task_id로 저장하고 204, 같은 턴 두 번째도 204", async () => {
    const d = deps();
    const response = await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK }), spec, d.value);
    expect(response.status).toBe(204);
    expect(await response.text()).toBe("");
    expect(d.recordTurn).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, type, TASK);
    const again = deps({ recordTurn: async () => "duplicate" });
    expect((await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK }), spec, again.value)).status).toBe(204);
  });

  it("대문자 uuid도 소문자로 바꿔 저장한다: 같은 턴을 대소문자로 두 번 세지 못한다", async () => {
    const d = deps();
    expect((await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK.toUpperCase() }), spec, d.value)).status).toBe(204);
    expect(d.recordTurn).toHaveBeenCalledExactlyOnceWith({ user: { id: USER } }, type, TASK);
  });

  it("이 사용자의 Claude Code 턴이 아니면(없음 · 남의 것 · Codex) 404 not_found (같은 문구, 저장 0, 어느 쪽인지 알리지 않는다)", async () => {
    const d = deps({ recordTurn: async () => "not_found" });
    const response = await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK }), spec, d.value);
    expect(response.status).toBe(404);
    const body = await response.json();
    expect(body).toEqual({ error: { code: "not_found", message: expect.any(String) } });
    expect(JSON.stringify(body)).not.toContain(TASK);
  });

  it.each([{}, { agent_task_id: "nope" }, { agent_task_id: 5 }, { agent_task_id: TASK, extra: true }, { agent_task_id: TASK, user_id: USER }, { agent_task_id: TASK, title: "Fix" }, { user_id: USER }])("잘못된 본문은 400 (저장 0): %j", async (body) => {
    const d = deps();
    expect((await handleAgentTreeTurnMetric(post(path, body), spec, d.value)).status).toBe(400);
    expect(d.recordTurn).not.toHaveBeenCalled();
  });

  it("JSON이 아닌 본문 · 본문 없음은 400, 큰 본문도 400 (저장 0)", async () => {
    const d = deps();
    expect((await handleAgentTreeTurnMetric(new Request(`https://api.example.dev/api/v2/agent-tree/${path}`, { method: "POST", body: "not json" }), spec, d.value)).status).toBe(400);
    expect((await handleAgentTreeTurnMetric(new Request(`https://api.example.dev/api/v2/agent-tree/${path}`, { method: "POST" }), spec, d.value)).status).toBe(400);
    expect((await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK, pad: "x".repeat(2048) }), spec, d.value)).status).toBe(400);
    expect(d.recordTurn).not.toHaveBeenCalled();
  });

  it("저장 오류는 500이고 로그에는 이벤트 이름 · 오류 이름 · code뿐이다 (턴 id · 오류 문구 · 사용자 id 0)", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const d = deps({ recordTurn: async () => Promise.reject(Object.assign(new Error(`secret detail ${TASK}`), { code: "XX000" })) });
    const response = await handleAgentTreeTurnMetric(post(path, { agent_task_id: TASK }), spec, d.value);
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain(TASK);
    const logged = JSON.stringify(log.mock.calls);
    expect(logged).toContain(`${type}_failed`);
    expect(logged).toContain("XX000");
    for (const secret of ["secret detail", TASK, USER]) expect(logged).not.toContain(secret);
  });
});
