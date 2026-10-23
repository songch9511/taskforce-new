import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), createSupabaseClient: vi.fn(), admin: vi.fn(), insert: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@supabase/supabase-js", async (original) => ({ ...(await original<typeof import("@supabase/supabase-js")>()), createClient: mocks.createSupabaseClient }));

import { POST as projectSessionsOpened } from "./project-sessions-opened/route";
import { POST as questionRedirected } from "./question-redirected/route";
import { POST as subagentOpened } from "./subagent-opened/route";
import { POST as turnUsed } from "./turn-used/route";

// 쿠키 CSRF · 인증 (T3s). 쿠키로 인증하는 쓰기는 같은 출처에서 온 것만 받는다: 다른 사이트에서 왔으면 로그인하지 않은 것으로 본다 (401).
// 거절되면 DB 클라이언트도 부르지 않는다.
const USER = "11111111-0000-4000-8000-000000000001";
const TASK = "c1c1c1c1-0000-4000-8000-000000000001";
const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];
const claims = () => vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });

const ROUTES = [
  { name: "project-sessions-opened", route: projectSessionsOpened, body: {} },
  { name: "subagent-opened", route: subagentOpened, body: {} },
  { name: "turn-used", route: turnUsed, body: { agent_task_id: TASK } },
  { name: "question-redirected", route: questionRedirected, body: { agent_task_id: TASK } },
] as const;

const post = (name: string, body: unknown, headers: Record<string, string>) =>
  new Request(`https://api.example.test/api/v2/agent-tree/${name}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

/** 턴 확인 세 단계(agent_tasks → agent_sessions → agent_connections)가 모두 이 사용자의 Claude Code 턴으로 답하고, metric_events insert는 mocks.insert로 간다 */
function admin() {
  const rows: Record<string, Record<string, unknown>> = {
    agent_tasks: { agent_session_id: "a1" },
    agent_sessions: { connection_id: "k1" },
    agent_connections: { adapter: "agent:claude-code" },
  };
  return {
    from: (table: string) => ({
      select: () => {
        const query = { eq: () => query, maybeSingle: () => ({ throwOnError: async () => ({ data: rows[table] ?? null, error: null }) }) };
        return query;
      },
      insert: mocks.insert,
    }),
  };
}

beforeEach(() => {
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
  vi.stubEnv("AGENT_BETA_USER_IDS", USER);
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.createSupabaseClient.mockReturnValue({ auth: { getClaims: claims() } } as unknown as SupabaseClient);
  mocks.insert.mockResolvedValue({ error: null });
  mocks.admin.mockImplementation(admin);
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe.each(ROUTES)("POST agent-tree/$name: 쿠키 CSRF · 인증", ({ name, route, body }) => {
  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 저장 0)", async () => {
    for (const headers of CROSS_SITE) expect((await route(post(name, body, headers))).status, JSON.stringify(headers)).toBe(401);
    expect(mocks.admin).not.toHaveBeenCalled();
    expect(mocks.insert).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키와 Bearer는 통과한다 (204)", async () => {
    expect((await route(post(name, body, { "sec-fetch-site": "same-origin" }))).status).toBe(204);
    expect((await route(post(name, body, { authorization: "Bearer token-123", "sec-fetch-site": "cross-site" }))).status).toBe(204);
    expect(mocks.insert).toHaveBeenCalledTimes(2);
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await route(post(name, body, { "sec-fetch-site": "same-origin" }))).status).toBe(401);
    expect(mocks.insert).not.toHaveBeenCalled();
  });
});
