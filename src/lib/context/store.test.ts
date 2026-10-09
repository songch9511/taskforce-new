import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { embed } from "@/lib/ai/embed";

import {
  addContextMember,
  ContextGateOffError,
  createContext,
  deleteMemory,
  forgetMemory,
  indexSourceAfterIngest,
  loadScopeMemory,
  observePerson,
  recordOAuthIdentityLink,
  rememberMemory,
  searchContextChunks,
  setContextMemberByUser,
  setSourcesAccessLost,
} from "./store";

vi.mock("server-only", () => ({}));
// 임베딩은 결정적 가짜 (실제 모델 호출 없음)
vi.mock("@/lib/ai/embed", async (original) => ({
  ...(await original<typeof import("@/lib/ai/embed")>()),
  embed: vi.fn(async (_config: unknown, texts: string[]) => ({ vectors: texts.map(() => Array.from({ length: 1536 }, (_, i) => (i === 0 ? 1 : 0))) })),
}));

// 맥락층의 DB 쪽: gate가 꺼져 있으면 DB · 모델을 부르지 않는다 (MEMORY_ENABLED · SOURCE_CHUNKS_ENABLED 기본 꺼짐).
// 켜져 있으면 DB 함수(20261104000000_context_layer)에 맞는 인자로 부른다. 규칙 자체는 tests/db/context-layer.test.ts가 본다.

type Call = { kind: "from" | "rpc"; name: string; ops: { op: string; args: unknown[] }[] };

/** 모든 호출을 기록하는 가짜 service role 클라이언트. results[이름]이 await 결과의 data다 */
function recordingAdmin(results: Record<string, unknown> = {}) {
  const calls: Call[] = [];
  const chain = (call: Call): unknown =>
    new Proxy(
      {},
      {
        get: (_target, prop: string) => {
          if (prop === "then") {
            return (resolve: (value: unknown) => void, reject: (error: unknown) => void) =>
              Promise.resolve({ data: results[call.name] ?? null, error: null }).then(resolve, reject);
          }
          return (...args: unknown[]) => {
            call.ops.push({ op: prop, args });
            return chain(call);
          };
        },
      },
    );
  const admin = {
    from: (name: string) => {
      const call: Call = { kind: "from", name, ops: [] };
      calls.push(call);
      return chain(call);
    },
    rpc: (name: string, args: unknown) => {
      const call: Call = { kind: "rpc", name, ops: [{ op: "args", args: [args] }] };
      calls.push(call);
      return chain(call);
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

const MEMORY = { MEMORY_ENABLED: "true" };
const CHUNKS = { SOURCE_CHUNKS_ENABLED: "true" };
const CONTEXT = "aaaaaaaa-0000-4000-8000-000000000001";
const ACTION = "bbbbbbbb-0000-4000-8000-000000000001";
const longText = "출시 준비 회의에서 디자인 확정 일정을 정했다.\n\n".repeat(120);

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("OPENROUTER_API_KEY", "test-key");
});

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("gate 꺼짐: 아무것도 쓰거나 부르지 않는다", () => {
  it("기억 · 범위 · 사람 쓰기는 ContextGateOffError, DB 호출 0", async () => {
    const { admin, calls } = recordingAdmin();
    const write = { kind: "fact" as const, scope: { kind: "global" as const }, statement: "금요일 배포", origin: "explicit" as const };
    await expect(rememberMemory(admin, "u1", write, {}, {})).rejects.toBeInstanceOf(ContextGateOffError);
    await expect(forgetMemory(admin, "u1", "m1", 1, {})).rejects.toBeInstanceOf(ContextGateOffError);
    await expect(deleteMemory(admin, "u1", "m1", {})).rejects.toBeInstanceOf(ContextGateOffError);
    await expect(createContext(admin, "u1", { name: "Shape", kind: "project" }, {})).rejects.toBeInstanceOf(ContextGateOffError);
    await expect(addContextMember(admin, "u1", CONTEXT, { kind: "action", actionId: ACTION }, { kind: "auto" }, {})).rejects.toBeInstanceOf(ContextGateOffError);
    await expect(setContextMemberByUser(admin, "u1", CONTEXT, { kind: "action", actionId: ACTION }, false, {})).rejects.toBeInstanceOf(ContextGateOffError);
    await expect(observePerson(admin, "u1", { provider: "slack", accountRef: "T1:U2", displayName: "지훈", email: null }, null, {})).rejects.toBeInstanceOf(
      ContextGateOffError,
    );
    await recordOAuthIdentityLink(admin, { userId: "u1", connectionId: "c1", provider: "slack", accountRef: "T1:U1", email: null }, {});
    expect(await loadScopeMemory(admin, "u1", { contextId: CONTEXT }, {})).toEqual([]);
    await setSourcesAccessLost(admin, "u1", ["s1"], true, new Date(), {});
    expect(calls).toEqual([]);
  });

  it("조각: 수집 뒤 만들기 · 범위 검색 모두 DB · 임베딩 호출 0 (MEMORY_ENABLED만 켜도 조각은 꺼져 있다)", async () => {
    const { admin, calls } = recordingAdmin();
    const source = { userId: "u1", sourceId: "s1", text: longText, provider: "notion", externalUrl: null };
    expect(await indexSourceAfterIngest(admin, source, MEMORY)).toEqual({ status: "gate_off", chunks: 0 });
    expect(await searchContextChunks(admin, "u1", CONTEXT, "디자인", 5, MEMORY)).toEqual([]);
    expect(calls).toEqual([]);
    expect(embed).not.toHaveBeenCalled();
  });
});

describe("gate 켜짐: DB 함수 인자", () => {
  it("기억 쓰기는 remember_memory_item 하나 (주제 정규화 · 범위 열 · 정정 대상)", async () => {
    const { admin, calls } = recordingAdmin({ remember_memory_item: { status: "written", id: "m2", superseded: ["m1"], superseded_by: null } });
    const result = await rememberMemory(
      admin,
      "u1",
      { kind: "fact", scope: { kind: "context", contextId: CONTEXT }, subject: " Deploy  DAY ", statement: "목요일 배포", origin: "explicit" },
      { corrects: { id: "m1", expectedVersion: 3 } },
      MEMORY,
    );
    expect(result).toEqual({ status: "written", id: "m2", superseded: ["m1"], supersededBy: null });
    expect(calls).toHaveLength(1);
    expect(calls[0].name).toBe("remember_memory_item");
    expect(calls[0].ops[0].args[0]).toMatchObject({
      p_user_id: "u1",
      p_corrects: "m1",
      p_expected_version: 3,
      p_item: { kind: "fact", scope_kind: "context", context_id: CONTEXT, subject: "deploy day", statement: "목요일 배포", origin: "explicit" },
    });
    const conflict = recordingAdmin({ remember_memory_item: { status: "conflict", id: null, superseded: [], superseded_by: null } });
    expect(await rememberMemory(conflict.admin, "u1", { kind: "fact", scope: { kind: "global" }, statement: "x", origin: "explicit" }, {}, MEMORY)).toEqual({
      status: "conflict",
    });
  });

  it("자동 멤버는 사용자의 선택을 덮지 않는다(충돌하면 그대로), 사용자의 빼기는 origin user + removed_at", async () => {
    const { admin, calls } = recordingAdmin();
    await addContextMember(admin, "u1", CONTEXT, { kind: "action", actionId: ACTION }, { kind: "auto" }, MEMORY);
    await setContextMemberByUser(admin, "u1", CONTEXT, { kind: "action", actionId: ACTION }, false, MEMORY);
    const [auto, user] = calls.map((c) => c.ops.find((o) => o.op === "upsert")!.args);
    expect(auto[0]).toMatchObject({ context_id: CONTEXT, member_kind: "action", action_id: ACTION, origin: "auto", confidence: null });
    expect(auto[1]).toEqual({ onConflict: "context_id,action_id", ignoreDuplicates: true });
    expect(user[0]).toMatchObject({ origin: "user", removed_at: expect.any(String) });
    expect(user[1]).toEqual({ onConflict: "context_id,action_id" });
  });

  it("oauth 신원 링크: 같은 계정의 추정 링크는 oauth로 올리고, 그 밖에 이미 있는 링크(사용자가 확인한 링크)는 바꾸지 않는다", async () => {
    const { admin, calls } = recordingAdmin();
    await recordOAuthIdentityLink(admin, { userId: "u1", connectionId: "c1", provider: "slack", accountRef: "T1:U1", email: null }, MEMORY);
    expect(calls.map((c) => c.name)).toEqual(["identity_links", "identity_links"]);
    const promote = calls[0].ops;
    // 연결 결과에 주소가 없으면(Slack) 추정 링크의 주소를 지우지 않는다
    expect(promote.find((o) => o.op === "update")!.args[0]).toEqual({ verified_via: "oauth", connection_id: "c1" });
    expect(promote.filter((o) => o.op === "eq").map((o) => o.args)).toEqual([
      ["user_id", "u1"],
      ["provider", "slack"],
      ["account_ref", "T1:U1"],
      ["verified_via", "inferred"],
    ]);
    const upsert = calls[1].ops.find((o) => o.op === "upsert")!.args;
    expect(upsert[0]).toMatchObject({ user_id: "u1", provider: "slack", account_ref: "T1:U1", connection_id: "c1", verified_via: "oauth" });
    expect(upsert[1]).toEqual({ onConflict: "user_id,provider,account_ref", ignoreDuplicates: true });
  });

  it("접근 상실 표시는 맥락층 gate 하나라도 켜져 있을 때 그 사용자의 원문에만", async () => {
    const { admin, calls } = recordingAdmin();
    await setSourcesAccessLost(admin, "u1", ["s1", "s2"], true, new Date("2026-10-10T00:00:00Z"), CHUNKS);
    expect(calls).toHaveLength(1);
    expect(calls[0].ops.map((o) => [o.op, ...o.args])).toEqual([
      ["update", { access_lost_at: "2026-10-10T00:00:00.000Z" }],
      ["eq", "user_id", "u1"],
      ["in", "id", ["s1", "s2"]],
      ["throwOnError"],
    ]);
  });

  it("범위 기억 읽기: 전체 + 요청 대상만 (id 모양이 아닌 값은 필터에 넣지 않는다)", async () => {
    const { admin, calls } = recordingAdmin({ memory_items: [] });
    await loadScopeMemory(admin, "u1", { contextId: CONTEXT, actionIds: [ACTION, "bad,id"], agentAdapter: "agent:claude-code" }, MEMORY);
    const or = calls[0].ops.find((o) => o.op === "or")!.args[0];
    expect(or).toBe(`scope_kind.eq.global,context_id.eq.${CONTEXT},action_id.in.(${ACTION}),agent_adapter.eq.agent:claude-code`);
    expect(calls[0].ops.filter((o) => o.op === "is").map((o) => o.args)).toEqual([
      ["superseded_at", null],
      ["revoked_at", null],
    ]);
  });

  it("수집 뒤 조각: 동의를 확인하고 임베딩한 뒤 replace_source_chunks 한 번. 동의가 없으면 임베딩도 저장도 없다", async () => {
    const source = { userId: "u1", sourceId: "s1", text: longText, provider: "notion", externalUrl: null };
    const consented = recordingAdmin({ profiles: { ai_consent_at: "2026-10-01T00:00:00Z" }, replace_source_chunks: { status: "replaced", chunks: 3 } });
    expect(await indexSourceAfterIngest(consented.admin, source, CHUNKS)).toEqual({ status: "replaced", chunks: 3 });
    expect(consented.calls.map((c) => c.name)).toEqual(["profiles", "replace_source_chunks"]);
    const args = consented.calls[1].ops[0].args[0] as { p_texts: string[]; p_embeddings: string[] };
    expect(args.p_texts.length).toBeGreaterThan(1);
    expect(args.p_embeddings).toHaveLength(args.p_texts.length);
    expect(args.p_embeddings[0].startsWith("[1,0,0")).toBe(true);
    expect(embed).toHaveBeenCalledTimes(1);

    vi.mocked(embed).mockClear();
    const withdrawn = recordingAdmin({ profiles: { ai_consent_at: null } });
    expect(await indexSourceAfterIngest(withdrawn.admin, source, CHUNKS)).toEqual({ status: "no_consent", chunks: 0 });
    expect(withdrawn.calls.map((c) => c.name)).toEqual(["profiles"]);
    expect(embed).not.toHaveBeenCalled();

    // Slack 원문은 동의 확인 · 임베딩도 하지 않는다
    const slack = recordingAdmin();
    expect(await indexSourceAfterIngest(slack.admin, { ...source, provider: "slack" }, CHUNKS)).toEqual({ status: "slack", chunks: 0 });
    expect(slack.calls).toEqual([]);
  });

  it("수집 뒤 조각이 실패해도 던지지 않는다 (원문 처리 · 동기화를 막지 않는다)", async () => {
    vi.mocked(embed).mockRejectedValueOnce(new Error("임베딩 요청 실패 (500)"));
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    const { admin } = recordingAdmin({ profiles: { ai_consent_at: "2026-10-01T00:00:00Z" } });
    expect(await indexSourceAfterIngest(admin, { userId: "u1", sourceId: "s1", text: longText, provider: null, externalUrl: null }, CHUNKS)).toEqual({
      status: "failed",
      chunks: 0,
    });
    // 로그에 원문 글을 남기지 않는다
    expect(JSON.stringify(errors.mock.calls)).not.toContain("디자인 확정");
    errors.mockRestore();
  });
});
