import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { embed } from "@/lib/ai/embed";
import { ConsentRequiredError } from "@/lib/consent/gate";

import { conversationModelsFromEnv, finishTurn, loadConsultContext, loadConversation, postUserMessage, releaseLease, verifySelected } from "./store";

vi.mock("server-only", () => ({}));
// 임베딩은 결정적 가짜 (실제 모델 호출 없음)
vi.mock("@/lib/ai/embed", async (original) => ({
  ...(await original<typeof import("@/lib/ai/embed")>()),
  embed: vi.fn(async (_config: unknown, texts: string[]) => ({ vectors: texts.map(() => Array.from({ length: 1536 }, () => 0)) })),
}));

// 대화 v2의 DB 쪽: gate가 꺼진 맥락층(기억 · 범위 · 조각)은 읽지 않고 임베딩을 부르지 않는다. RPC 인자 모양. 동의 없으면 모델 호출 0.
// 실제 SQL에서의 동작은 tests/db/conversations-v2.scenarios.ts (handler → store → SQL).

type Call = { kind: "from" | "rpc"; name: string; ops: { op: string; args: unknown[] }[] };

function recordingAdmin(results: Record<string, unknown> = {}) {
  const calls: Call[] = [];
  const chain = (call: Call): unknown =>
    new Proxy(
      {},
      {
        get: (_target, prop: string) => {
          if (prop === "then") {
            return (resolve: (value: unknown) => void, reject: (error: unknown) => void) =>
              Promise.resolve({ data: results[call.name] ?? null, error: null, count: null }).then(resolve, reject);
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

const USER = "11111111-0000-4000-8000-000000000001";
const CONTEXT = "cdcdcdcd-0000-4000-8000-000000000001";
const ON = { MEMORY_ENABLED: "true", SOURCE_CHUNKS_ENABLED: "true" };

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("OPENROUTER_API_KEY", "test-key");
  vi.stubEnv("LLM_MODEL", "test/llm");
  vi.stubEnv("JEV_MODEL", "typesafe/jev-1.13");
  vi.stubEnv("EMBEDDING_MODEL", "test/embed");
});

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("맥락층 gate (B1 정책 그대로)", () => {
  it("MEMORY_ENABLED가 꺼져 있으면 대화의 범위를 읽지 않고 All work로 답한다", async () => {
    const { admin, calls } = recordingAdmin({ conversations: { id: "cccccccc-0000-4000-8000-000000000001", title: null, context_id: CONTEXT, created_at: "2026-10-10T00:00:00Z", last_message_at: null, last_read_at: null, archived_at: null, text_purged_at: null } });
    expect(await loadConversation(admin, USER, "cccccccc-0000-4000-8000-000000000001", {})).toMatchObject({ contextId: null, contextName: null });
    expect(calls.map((c) => c.name)).toEqual(["conversations"]);
  });

  it("MEMORY_ENABLED · SOURCE_CHUNKS_ENABLED가 꺼져 있으면 기억 · 범위 · 멤버 · 조각을 읽지 않고 임베딩을 부르지 않는다 (할 일 조건 조회만)", async () => {
    const { admin, calls } = recordingAdmin({ actions: [] });
    await loadConsultContext(admin, USER, { contextId: CONTEXT, query: "오늘 뭐 하지", chunks: true, deadline: Date.now() + 30_000, now: new Date() }, {});
    const names = calls.map((c) => c.name);
    expect(names.filter((n) => ["memory_items", "work_contexts", "context_members", "match_context_chunks", "source_chunks"].includes(n))).toEqual([]);
    expect(embed).not.toHaveBeenCalled();
    // 열린 할 일은 조건 조회 + 전체 수 (top-k 검색 RPC가 아니다)
    const open = calls.find((c) => c.name === "actions" && c.ops.some((o) => o.op === "eq" && o.args[0] === "status" && o.args[1] === "open"))!;
    expect(open.ops.find((o) => o.op === "select")!.args[1]).toEqual({ count: "exact" });
    expect(names).not.toContain("match_actions_for_ask");
  });

  it("켜져 있으면 범위 version을 먼저 읽고(기억 · 조각보다 앞), 조각 검색 임베딩에 마감을 넘긴다", async () => {
    const { admin, calls } = recordingAdmin({
      actions: [],
      work_contexts: { context_version: 4 },
      memory_items: [],
      context_members: [],
      match_context_chunks: [],
      profiles: { ai_consent_at: "2026-10-01T00:00:00Z" },
    });
    const deadline = Date.now() + 30_000;
    const context = await loadConsultContext(admin, USER, { contextId: CONTEXT, query: "디자인", chunks: true, deadline, now: new Date() }, ON);
    expect(context.contextVersion).toBe(4);
    const names = calls.map((c) => c.name);
    expect(names.indexOf("work_contexts")).toBeLessThan(names.indexOf("memory_items"));
    expect(names.indexOf("work_contexts")).toBeLessThan(names.indexOf("match_context_chunks"));
    expect(vi.mocked(embed).mock.calls[0][0]).toMatchObject({ deadline });
  });

  it("조각 검색은 요청이 원할 때만 (chunks false면 임베딩 0)", async () => {
    const { admin } = recordingAdmin({ actions: [], work_contexts: { context_version: 1 }, memory_items: [], context_members: [] });
    await loadConsultContext(admin, USER, { contextId: CONTEXT, query: "x", chunks: false, deadline: Date.now() + 30_000, now: new Date() }, ON);
    expect(embed).not.toHaveBeenCalled();
  });
});

describe("RPC 인자", () => {
  it("메시지 쓰기 · 처리 표시 풀기 · 한 번의 답 쓰기", async () => {
    const { admin, calls } = recordingAdmin({
      conversation_post_message: { status: "created", message_id: "m", seq: 1, reply_id: null },
      conversation_finish_turn: { status: "written", reply_id: "r", memory_ids: ["x"], action_id: null },
    });
    expect(await postUserMessage(admin, USER, "c", "client", "안녕")).toEqual({ status: "created", messageId: "m", seq: 1, replyId: null });
    await releaseLease(admin, USER, "m");
    const plan = {
      intent: { kind: "consult" as const, confidence: 0.9, judge_version: "intent-v1" },
      user: { refs: {} as never },
      reply: { text: "답", segments: [], citations: [], refs: {} as never, content: {} as never },
      memory: [],
      adopt: null,
    };
    expect(await finishTurn(admin, USER, "m", plan)).toEqual({ status: "written", replyId: "r", memoryIds: ["x"], actionId: null });
    expect(calls.map((c) => [c.name, c.ops[0].args[0]])).toEqual([
      ["conversation_post_message", { p_user_id: USER, p_conversation_id: "c", p_client_message_id: "client", p_text: "안녕", p_selected: { action_ids: [], run_ids: [], artifact_ids: [] }, p_lease_seconds: 75 }],
      ["conversation_release_lease", { p_user_id: USER, p_message_id: "m" }],
      ["conversation_finish_turn", { p_user_id: USER, p_message_id: "m", p_turn: { user: { intent: plan.intent, refs: {} }, reply: { text: "답", refs: {}, content: {} }, memory: [], adopt: null } }],
    ]);
  });

  it("앱이 보낸 대상은 이 사용자의 것만 센다: 하나라도 없으면 missing", async () => {
    const { admin, calls } = recordingAdmin({ actions: [{ id: "a1", title: "x" }] });
    expect(await verifySelected(admin, USER, { action_ids: ["a1", "a2"] })).toEqual({ missing: true });
    expect(calls[0].ops.filter((o) => o.op === "eq")).toEqual([{ op: "eq", args: ["user_id", USER] }]);
    expect(await verifySelected(admin, USER, undefined)).toEqual({ targets: [] });
  });
});

describe("모델 호출", () => {
  it("동의가 없으면 Jev · LLM 모두 공급자를 부르기 전에 멈춘다 (fetch 0)", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("network"));
    const { admin } = recordingAdmin({ profiles: { ai_consent_at: null } });
    const models = conversationModelsFromEnv(admin, USER, Date.now() + 30_000);
    await expect(models.decide({ state: {}, questions: {} })).rejects.toBeInstanceOf(ConsentRequiredError);
    await expect(models.complete({ system: "s", user: "u", schemaName: "x", schema: {} as never })).rejects.toBeInstanceOf(ConsentRequiredError);
    expect(fetchSpy).not.toHaveBeenCalled();
    fetchSpy.mockRestore();
  });
});
