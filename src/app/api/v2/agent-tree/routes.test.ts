import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

type Row = Record<string, unknown>;
const mocks = vi.hoisted(() => ({ admin: vi.fn(), auth: vi.fn(), insert: vi.fn(), lookup: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.auth }));

import { POST as projectSessionsOpened } from "./project-sessions-opened/route";
import { POST as questionRedirected } from "./question-redirected/route";
import { POST as subagentOpened } from "./subagent-opened/route";
import { POST as turnUsed } from "./turn-used/route";

// 에이전트 트리 지표 네 route (T3s): gate · 베타 명단 · 서버 권한 insert (사용자 id는 인증에서만 온다) · 같은 날 / 같은 턴 두 번째(23505)는 조용히 204.
// T2 둘은 서버가 그 id가 "이 사용자의 Claude Code 턴"인지 같은 요청 안에서 확인한다 (agent_tasks → agent_sessions → agent_connections, 모두 user_id 일치).
const USER = "11111111-0000-4000-8000-000000000001";
const OTHER = "22222222-0000-4000-8000-000000000002";
const CLAUDE_TASK = "c1c1c1c1-0000-4000-8000-000000000001";
const CODEX_TASK = "c2c2c2c2-0000-4000-8000-000000000002";
const OTHER_TASK = "c3c3c3c3-0000-4000-8000-000000000003";
const ORPHAN_TASK = "c4c4c4c4-0000-4000-8000-000000000004";
const MISSING_TASK = "c5c5c5c5-0000-4000-8000-000000000005";

const tables: Record<string, Row[]> = {
  agent_tasks: [
    { id: CLAUDE_TASK, user_id: USER, agent_session_id: "a1" },
    { id: CODEX_TASK, user_id: USER, agent_session_id: "a2" },
    { id: OTHER_TASK, user_id: OTHER, agent_session_id: "a3" },
    { id: ORPHAN_TASK, user_id: USER, agent_session_id: "a4" },
  ],
  agent_sessions: [
    { id: "a1", user_id: USER, connection_id: "k1" },
    { id: "a2", user_id: USER, connection_id: "k2" },
    { id: "a3", user_id: OTHER, connection_id: "k3" },
    { id: "a4", user_id: USER, connection_id: "k-gone" },
  ],
  agent_connections: [
    { id: "k1", user_id: USER, adapter: "agent:claude-code" },
    { id: "k2", user_id: USER, adapter: "agent:codex" },
    { id: "k3", user_id: OTHER, adapter: "agent:claude-code" },
  ],
};

/** supabase-js의 from().select().eq()….maybeSingle().throwOnError()와 from().insert()만 흉내 낸 서버 권한 클라이언트 */
function fakeAdmin() {
  return {
    from: (table: string) => ({
      select: (columns: string) => {
        const filters: [string, unknown][] = [];
        const query = {
          eq: (column: string, value: unknown) => {
            filters.push([column, value]);
            return query;
          },
          maybeSingle: () => ({
            throwOnError: async () => {
              mocks.lookup(table, columns, filters);
              const row = (tables[table] ?? []).find((candidate) => filters.every(([column, value]) => candidate[column] === value));
              return { data: row ? Object.fromEntries(columns.split(",").map((name) => [name.trim(), row[name.trim()]])) : null, error: null };
            },
          }),
        };
        return query;
      },
      insert: (row: unknown) => mocks.insert(table, row),
    }),
  };
}

const URLS = { openedSessions: "project-sessions-opened", rowOpened: "subagent-opened", turnUsed: "turn-used", redirected: "question-redirected" } as const;
const call = (route: (request: Request) => Promise<Response>, path: string, body: unknown = {}) =>
  route(new Request(`https://api.example.dev/api/v2/agent-tree/${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));

function open() {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
  vi.stubEnv("AGENT_BETA_USER_IDS", USER);
}

beforeEach(() => {
  mocks.auth.mockResolvedValue({ user: { id: USER } });
  mocks.insert.mockResolvedValue({ error: null });
  mocks.admin.mockImplementation(fakeAdmin);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

const DAY_ROUTES = [
  { name: "project-sessions-opened", route: projectSessionsOpened, path: URLS.openedSessions, type: "project_sessions_opened" },
  { name: "subagent-opened", route: subagentOpened, path: URLS.rowOpened, type: "subagent_row_opened" },
] as const;
const TURN_ROUTES = [
  { name: "turn-used", route: turnUsed, path: URLS.turnUsed, type: "subagent_turn_used" },
  { name: "question-redirected", route: questionRedirected, path: URLS.redirected, type: "subagent_question_redirected" },
] as const;
const ALL_ROUTES = [...DAY_ROUTES, ...TURN_ROUTES];

describe.each(ALL_ROUTES)("POST /api/v2/agent-tree/$name: 문", ({ route, path }) => {
  const body = path === URLS.turnUsed || path === URLS.redirected ? { agent_task_id: CLAUDE_TASK } : {};

  it("플래그가 꺼져 있으면 404: 인증 · DB 0 (둘 중 하나만 꺼져도)", async () => {
    expect((await call(route, path, body)).status).toBe(404);
    vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
    vi.stubEnv("AGENT_BETA_USER_IDS", USER);
    expect((await call(route, path, body)).status).toBe(404);
    vi.unstubAllEnvs();
    vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
    vi.stubEnv("AGENT_BETA_USER_IDS", USER);
    expect((await call(route, path, body)).status).toBe(404);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("베타 명단 밖 사용자는 404 · 로그인하지 않았으면 401 (저장 0, DB 호출 0)", async () => {
    open();
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call(route, path, body)).status).toBe(404);
    mocks.auth.mockResolvedValue(null);
    expect((await call(route, path, body)).status).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.insert).not.toHaveBeenCalled();
  });
});

describe.each(DAY_ROUTES)("POST /api/v2/agent-tree/$name", ({ route, path, type }) => {
  it("인증된 사용자 id만으로 서버 권한 insert, props는 비어 있고 응답은 204 (턴 조회 없음)", async () => {
    open();
    const response = await call(route, path);
    expect(response.status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type, props: {} });
    expect(mocks.lookup).not.toHaveBeenCalled();
  });

  it("본문이 어떤 칸(사용자 id · 턴 id · 제목)을 실어도 받지 않는다 (strict)", async () => {
    open();
    for (const body of [{ user_id: OTHER }, { agent_task_id: CLAUDE_TASK }, { title: "Fix launcher" }, { session_id: "5e5e5e5e-0000-4000-8000-000000000001" }]) {
      expect((await call(route, path, body)).status, JSON.stringify(body)).toBe(400);
    }
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("같은 날 두 번째(23505)는 조용히 204, 그 밖의 저장 오류는 500 (로그에 값 0)", async () => {
    open();
    mocks.insert.mockResolvedValueOnce({ error: { code: "23505" } });
    expect((await call(route, path)).status).toBe(204);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.insert.mockResolvedValueOnce({ error: { code: "XX000" } });
    expect((await call(route, path)).status).toBe(500);
    expect(JSON.stringify(log.mock.calls)).toContain(`${type}_failed`);
    expect(JSON.stringify(log.mock.calls)).not.toContain(USER);
    log.mockRestore();
  });
});

describe.each(TURN_ROUTES)("POST /api/v2/agent-tree/$name", ({ route, path, type }) => {
  it("이 사용자의 Claude Code 턴이면 서버 권한 insert (props는 턴 id 하나), 응답은 204", async () => {
    open();
    const response = await call(route, path, { agent_task_id: CLAUDE_TASK });
    expect(response.status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type, props: { agent_task_id: CLAUDE_TASK } });
  });

  it("확인은 같은 요청 안에서 세 단계이고 모두 user_id를 건다: agent_tasks → agent_sessions → agent_connections (사용자 글은 읽지 않는다)", async () => {
    open();
    await call(route, path, { agent_task_id: CLAUDE_TASK });
    expect(mocks.lookup.mock.calls).toEqual([
      ["agent_tasks", "agent_session_id", [["user_id", USER], ["id", CLAUDE_TASK]]],
      ["agent_sessions", "connection_id", [["user_id", USER], ["id", "a1"]]],
      ["agent_connections", "adapter", [["user_id", USER], ["id", "k1"]]],
    ]);
  });

  it("남의 턴 id · Codex 턴 id · 연결이 사라진 세션의 턴 · 없는 id는 모두 404 (저장 0, 같은 응답)", async () => {
    open();
    const responses: string[] = [];
    for (const task of [OTHER_TASK, CODEX_TASK, ORPHAN_TASK, MISSING_TASK]) {
      const response = await call(route, path, { agent_task_id: task });
      expect(response.status, task).toBe(404);
      responses.push(JSON.stringify(await response.json()));
    }
    expect(new Set(responses).size).toBe(1);
    for (const task of [OTHER_TASK, CODEX_TASK, ORPHAN_TASK, MISSING_TASK]) expect(responses[0]).not.toContain(task);
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("남의 턴 id는 남의 행을 읽지 않는다: 첫 조회의 user_id가 인증된 사용자라 남의 task 행이 아예 안 보인다", async () => {
    open();
    await call(route, path, { agent_task_id: OTHER_TASK });
    expect(mocks.lookup).toHaveBeenCalledTimes(1);
    expect(mocks.lookup).toHaveBeenCalledWith("agent_tasks", "agent_session_id", [["user_id", USER], ["id", OTHER_TASK]]);
  });

  it("다른 사용자로 로그인한 같은 요청은 그 사용자의 턴만 센다 (명단에 있는 두 번째 사용자)", async () => {
    open();
    vi.stubEnv("AGENT_BETA_USER_IDS", `${USER},${OTHER}`);
    mocks.auth.mockResolvedValue({ user: { id: OTHER } });
    expect((await call(route, path, { agent_task_id: CLAUDE_TASK })).status).toBe(404);
    expect((await call(route, path, { agent_task_id: OTHER_TASK })).status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: OTHER, type, props: { agent_task_id: OTHER_TASK } });
  });

  it("대문자 uuid로 와도 소문자로 확인하고 소문자로 남긴다", async () => {
    open();
    expect((await call(route, path, { agent_task_id: CLAUDE_TASK.toUpperCase() })).status).toBe(204);
    expect(mocks.lookup.mock.calls[0]).toEqual(["agent_tasks", "agent_session_id", [["user_id", USER], ["id", CLAUDE_TASK]]]);
    expect(mocks.insert).toHaveBeenCalledExactlyOnceWith("metric_events", { user_id: USER, type, props: { agent_task_id: CLAUDE_TASK } });
  });

  it("잘못된 본문(키 더함 · uuid 아님 · 비어 있음)은 400이고 확인도 저장도 하지 않는다", async () => {
    open();
    for (const body of [{}, { agent_task_id: "not-a-uuid" }, { agent_task_id: CLAUDE_TASK, count: 2 }, { agent_task_id: CLAUDE_TASK, title: "Fix launcher" }, { agent_task_id: CLAUDE_TASK, user_id: OTHER }, { user_id: USER }]) {
      expect((await call(route, path, body)).status, JSON.stringify(body)).toBe(400);
    }
    expect(mocks.lookup).not.toHaveBeenCalled();
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("같은 턴 두 번째(23505)는 조용히 204, 그 밖의 저장 오류는 500 (로그에 턴 id · 사용자 id 0)", async () => {
    open();
    mocks.insert.mockResolvedValueOnce({ error: { code: "23505" } });
    expect((await call(route, path, { agent_task_id: CLAUDE_TASK })).status).toBe(204);
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    mocks.insert.mockResolvedValueOnce({ error: { code: "XX000" } });
    expect((await call(route, path, { agent_task_id: CLAUDE_TASK })).status).toBe(500);
    const logged = JSON.stringify(log.mock.calls);
    expect(logged).toContain(`${type}_failed`);
    for (const secret of [CLAUDE_TASK, USER]) expect(logged).not.toContain(secret);
    log.mockRestore();
  });

  it("확인 조회가 실패하면 500이고 아무것도 저장하지 않는다", async () => {
    open();
    mocks.lookup.mockImplementationOnce(() => {
      throw Object.assign(new Error(`db down ${CLAUDE_TASK}`), { code: "08006" });
    });
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    expect((await call(route, path, { agent_task_id: CLAUDE_TASK })).status).toBe(500);
    expect(mocks.insert).not.toHaveBeenCalled();
    expect(JSON.stringify(log.mock.calls)).not.toContain(CLAUDE_TASK);
    log.mockRestore();
  });
});

describe("T2 두 route는 서로 다른 종류로 같은 턴을 각각 남긴다", () => {
  it("turn-used와 question-redirected가 같은 턴에 둘 다 insert한다 (종류별 unique라 서로 막지 않는다)", async () => {
    open();
    expect((await call(turnUsed, URLS.turnUsed, { agent_task_id: CLAUDE_TASK })).status).toBe(204);
    expect((await call(questionRedirected, URLS.redirected, { agent_task_id: CLAUDE_TASK })).status).toBe(204);
    expect(mocks.insert.mock.calls.map(([, row]) => (row as { type: string }).type)).toEqual(["subagent_turn_used", "subagent_question_redirected"]);
  });
});
