import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createCookieClient: vi.fn(), admin: vi.fn() }));

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.createCookieClient }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: mocks.admin }));
vi.mock("@/lib/context/memory-writes", () => ({ confirmMemoryItem: vi.fn(), editMemoryItem: vi.fn(), forgetMemoryItem: vi.fn(), moveMemoryItem: vi.fn() }));
vi.mock("@/lib/conversation/store", () => ({ setConversationContext: vi.fn() }));

import * as memoryWrites from "@/lib/context/memory-writes";
import * as conversationStore from "@/lib/conversation/store";

import { PATCH as patchConversation } from "../conversations/[id]/route";

import { PATCH as editMemory } from "./[id]/route";
import { POST as confirmMemory } from "./[id]/confirm/route";
import { POST as forgetMemory } from "./[id]/forget/route";
import { POST as moveMemory } from "./[id]/scope/route";

// 인증 거부 · 쿠키 CSRF (B3): 진짜 authenticateRequest로 부른다. 쿠키로 인증하는 쓰기 요청은 같은 출처에서 온 것만 받고(PATCH 포함),
// Bearer는 쿠키 CSRF 검사 대상이 아니다. 거절되면 쓰기도 DB 클라이언트도 부르지 않는다.
const ID = "aaaaaaaa-0000-4000-8000-000000000001";
const USER = "11111111-0000-4000-8000-000000000001";
const CONTEXT = "a6a6a6a6-0000-4000-8000-000000000001";

const ROUTES: [string, string, (request: Request) => Promise<Response>, unknown][] = [
  ["POST confirm", "POST", (request) => confirmMemory(request, { params: Promise.resolve({ id: ID }) }), { expected_version: 1 }],
  ["PATCH memory", "PATCH", (request) => editMemory(request, { params: Promise.resolve({ id: ID }) }), { expected_version: 1, statement: "x" }],
  ["POST forget", "POST", (request) => forgetMemory(request, { params: Promise.resolve({ id: ID }) }), { expected_version: 1 }],
  ["POST scope", "POST", (request) => moveMemory(request, { params: Promise.resolve({ id: ID }) }), { expected_version: 1, scope_kind: "global" }],
  ["PATCH conversation", "PATCH", (request) => patchConversation(request, { params: Promise.resolve({ id: ID }) }), { context_id: CONTEXT }],
];

const writes = () =>
  [
    vi.mocked(memoryWrites.confirmMemoryItem),
    vi.mocked(memoryWrites.editMemoryItem),
    vi.mocked(memoryWrites.forgetMemoryItem),
    vi.mocked(memoryWrites.moveMemoryItem),
    vi.mocked(conversationStore.setConversationContext),
  ] as unknown as ReturnType<typeof vi.fn>[];

const CROSS_SITE: Record<string, string>[] = [{ "sec-fetch-site": "cross-site" }, { "sec-fetch-site": "same-site" }, { origin: "https://evil.example" }];

beforeEach(() => {
  vi.stubEnv("MEMORY_ENABLED", "true");
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.example.test");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "sb_publishable_local-test");
  const getClaims = vi.fn().mockResolvedValue({ data: { claims: { sub: USER, email: "me@example.test", user_metadata: {} } }, error: null });
  mocks.createCookieClient.mockResolvedValue({ auth: { getClaims } } as unknown as SupabaseClient);
  mocks.admin.mockReturnValue({ admin: true });
  for (const write of writes()) write.mockResolvedValue({ status: "not_found" });
});
afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe.each(ROUTES)("%s: 쿠키 CSRF · 인증", (_name, method, call, body) => {
  const request = (headers: Record<string, string>) =>
    new Request("https://api.example.test/api/v2/x", { method, headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

  it("다른 사이트에서 온 쿠키 쓰기는 로그인하지 않은 것으로 본다 (401, 쓰기 0 · DB 클라이언트 0)", async () => {
    for (const headers of CROSS_SITE) {
      expect((await call(request(headers))).status, JSON.stringify(headers)).toBe(401);
    }
    expect(mocks.admin).not.toHaveBeenCalled();
    for (const write of writes()) expect(write).not.toHaveBeenCalled();
  });

  it("같은 출처의 쿠키 쓰기는 통과한다", async () => {
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(404); // 가짜 쓰기가 없는 기억/대화로 답했다 (인증 통과의 증거)
    expect(writes().filter((write) => write.mock.calls.length > 0)).toHaveLength(1);
  });

  it("로그인하지 않은 요청(쿠키 클레임 없음)은 401이다", async () => {
    mocks.createCookieClient.mockResolvedValue({ auth: { getClaims: vi.fn().mockResolvedValue({ data: null, error: new Error("no session") }) } } as unknown as SupabaseClient);
    expect((await call(request({ "sec-fetch-site": "same-origin" }))).status).toBe(401);
    for (const write of writes()) expect(write).not.toHaveBeenCalled();
  });
});
