import { randomBytes } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";

import { accountRow, fakeAdmin, stubBillingEnv } from "@/lib/billing/testing";
import { budgetFetch } from "./budget";
import { completeJson, LlmError } from "./llm";
import { sealUserKey } from "./user-key";

vi.mock("server-only", () => ({}));

// 시험용 모양 값이다 (실제 키가 아니다).
const MANAGED = "sk-or-v1-managedmanagedmanagedmanagedmanagedmanagedmanagedmanagedman";
const ALICE_KEY = "sk-or-v1-alicealicealicealicealicealicealicealicealicealicealicealice";
const BOB_KEY = "sk-or-v1-bobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbobbo";
const ALICE = "11111111-1111-4111-8111-111111111111";
const BOB = "22222222-2222-4222-8222-222222222222";
const ENV_KEY = randomBytes(32).toString("base64");
const HOUR = 3_600_000;
const chat = "https://openrouter.ai/api/v1/chat/completions";
const provider = { only: ["p"], order: ["p"], zdr: true, data_collection: "deny", allow_fallbacks: false };
const requestWith = (over: Record<string, unknown> = {}, headers: HeadersInit = { Authorization: `Bearer ${MANAGED}`, "Content-Type": "application/json" }) => ({
  method: "POST",
  headers,
  body: JSON.stringify({ model: "m", max_tokens: 100, messages: [{ role: "user", content: "hi" }], provider, ...over }),
});
const endpointReply = () => new Response(JSON.stringify({ data: { endpoints: [{ tag: "p", context_length: 1000, pricing: { prompt: "0", completion: "0", discount: 0 } }] } }));
const modelsReply = () => new Response(JSON.stringify({ data: [{ id: "m", context_length: 200000, pricing: { prompt: "0.000001", completion: "0.000002" } }] }));

afterEach(() => vi.unstubAllEnvs());

const lifetime = (userId = ALICE) => accountRow({ user_id: userId, lifetime_status: "active", lifetime_order_id: `o-${userId}` });
const pro = (userId = ALICE) => accountRow({ user_id: userId, subscription_id: "s", status: "active", current_period_ends_at: new Date(Date.now() + 86_400_000).toISOString() });
const keyRow = (userId: string, plain: string, over: Record<string, unknown> = {}) => ({
  user_id: userId, sealed_key: sealUserKey(plain, userId, Buffer.from(ENV_KEY, "base64")), key_version: 1, status: "connected",
  last_ok_at: new Date().toISOString(), last_spend_error_at: null, ...over,
});

type Setup = {
  accounts?: Record<string, unknown>[];
  keys?: Record<string, unknown>[];
  reply?: (url: string, init: RequestInit | undefined) => Response | Promise<Response>;
  env?: Record<string, string>;
  rpcs?: Parameters<typeof fakeAdmin>[1];
};
function setup({ accounts = [lifetime()], keys = [keyRow(ALICE, ALICE_KEY)], reply, env = {}, rpcs = {} }: Setup = {}) {
  stubBillingEnv(env);
  vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", ENV_KEY);
  const f = fakeAdmin({ billing_accounts: accounts, user_ai_keys: keys }, {
    // the real functions flip the row; the double does the same so a following call sees it
    ai_key_mark_revoked: (args) => {
      const row = f.tables.get("user_ai_keys")!.find((r) => r.user_id === args.p_user_id && r.sealed_key === args.p_sealed_key && r.status === "connected");
      if (row) Object.assign(row, { status: "revoked" });
      return { data: !!row };
    },
    ...rpcs,
  });
  const send = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
    const u = String(url);
    if (u.endsWith("/endpoints")) return endpointReply();
    if (u.endsWith("/models")) return modelsReply();
    return reply ? reply(u, init) : new Response(JSON.stringify({ id: "gen-1", usage: { cost: 0.01, prompt_tokens: 3, completion_tokens: 4 } }));
  });
  return { ...f, send, as: (userId: string) => budgetFetch(f.admin, userId, send as unknown as typeof fetch) };
}
const authOf = (init: RequestInit | undefined) => (init?.headers ? new Headers(init.headers).get("authorization") : null);
const calls = (f: { send: { mock: { calls: unknown[][] } } }) => f.send.mock.calls as unknown as [string, RequestInit | undefined][];
const paidCalls = (f: Parameters<typeof calls>[0]) => calls(f).filter(([, init]) => init?.method === "POST");
const names = (f: { rpcCalls: [string, unknown][] }) => f.rpcCalls.map(([name]) => name);
const consoleSpies = () => (["log", "info", "warn", "error", "debug"] as const).map((level) => vi.spyOn(console, level).mockImplementation(() => undefined));
const printed = (spies: ReturnType<typeof consoleSpies>) => JSON.stringify(spies.map((spy) => spy.mock.calls));

describe("Lifetime + 저장된 키: 사용자 키로 가고 관리형 원가 장부는 쓰지 않는다", () => {
  it("유료 호출의 Authorization은 사용자 키이고, 관리형 키가 든 헤더는 버린다", async () => {
    const f = setup();
    const response = await f.as(ALICE)(chat, requestWith());
    expect(response.status).toBe(200);
    const [paid] = paidCalls(f);
    expect(authOf(paid[1])).toBe(`Bearer ${ALICE_KEY}`);
    expect(paid[1]?.headers && new Headers(paid[1].headers).get("content-type")).toBe("application/json");
    expect(JSON.stringify(calls(f))).not.toContain(MANAGED);
  });

  it.each([
    ["평범한 객체", { Authorization: `Bearer ${MANAGED}` }],
    ["소문자 이름", { authorization: `Bearer ${MANAGED}` }],
    ["Headers", new Headers({ Authorization: `Bearer ${MANAGED}` })],
    ["쌍 배열(중복)", [["Authorization", `Bearer ${MANAGED}`], ["authorization", `Bearer ${MANAGED}`]] as [string, string][]],
  ])("들어온 헤더 모양이 %s여도 관리형 키는 한 번도 나가지 않는다", async (_label, headers) => {
    const f = setup();
    await f.as(ALICE)(chat, requestWith({}, headers));
    expect(authOf(paidCalls(f)[0][1])).toBe(`Bearer ${ALICE_KEY}`);
    expect(JSON.stringify(calls(f).map(([, init]) => init?.headers ? [...new Headers(init.headers).entries()] : null))).not.toContain(MANAGED);
  });

  it("가격표 조회는 그대로이고 키를 싣지 않는다", async () => {
    const f = setup();
    await f.as(ALICE)(chat, requestWith());
    const catalog = calls(f).filter(([, init]) => init?.method !== "POST");
    expect(catalog.map(([url]) => url)).toEqual(["https://openrouter.ai/api/v1/models", "https://openrouter.ai/api/v1/models/m/endpoints"]);
    for (const [, init] of catalog) expect(authOf(init)).toBeNull();
  });

  it("예약 0 · 정산 0 · 토큰 기록 0 (관리형 장부에 아무것도 쓰지 않는다)", async () => {
    const f = setup();
    await f.as(ALICE)(chat, requestWith());
    for (const name of ["reserve_ai_spend", "reserve_billing_ai_spend_v2", "settle_ai_spend", "record_ai_spend_tokens"]) expect(names(f)).not.toContain(name);
  });

  it("max_price와 공급자 정책(ZDR · 고정 목록 · 대체 금지)은 그대로 붙는다", async () => {
    const f = setup();
    await f.as(ALICE)(chat, requestWith());
    const sent = JSON.parse(paidCalls(f)[0][1]?.body as string);
    expect(sent.provider).toEqual({ ...provider, max_price: { prompt: 1, completion: 2, request: 0, image: 0 } });
  });

  it.each([
    ["ZDR 없음", { provider: { ...provider, zdr: false } }],
    ["수집 거부 없음", { provider: { only: ["p"], order: ["p"], zdr: true, allow_fallbacks: false } }],
    ["대체 허용", { provider: { ...provider, allow_fallbacks: true } }],
    ["공급자 비움", { provider: { ...provider, only: [] } }],
    ["공급자 없음", { provider: undefined }],
  ])("사용자 키여도 공급자 정책이 약하면 보내지 않는다: %s", async (_label, over) => {
    const f = setup();
    await expect(f.as(ALICE)(chat, requestWith(over))).rejects.toMatchObject({ code: "ai_pricing_unavailable" });
    expect(f.send).not.toHaveBeenCalled();
  });

  it("임베딩 · Jev도 같은 길이다 (사용자 키, 장부 0)", async () => {
    const f = setup();
    f.send.mockImplementation(async (url) => {
      const u = String(url);
      if (u.endsWith("/endpoints")) return endpointReply();
      const free = (id: string) => ({ id, context_length: 8192, pricing: { prompt: "0.00000002", completion: "0" } });
      if (u.endsWith("/models") || u.includes("/models?") || u.endsWith("/embeddings/models")) return new Response(JSON.stringify({ data: [free("x"), free("typesafe/jev-1.13")] }));
      return new Response(JSON.stringify({ usage: { cost: 0.00001 } }));
    });
    await f.as(ALICE)("https://openrouter.ai/api/v1/embeddings", { method: "POST", headers: { Authorization: `Bearer ${MANAGED}` }, body: JSON.stringify({ model: "x", input: ["a"], provider }) });
    await f.as(ALICE)("https://openrouter.ai/api/alpha/decisions", { method: "POST", headers: { Authorization: `Bearer ${MANAGED}` }, body: JSON.stringify({ model: "typesafe/jev-1.13", state: {}, questions: {}, provider }) });
    const paid = paidCalls(f);
    expect(paid.map(([url]) => url)).toEqual(["https://openrouter.ai/api/v1/embeddings", "https://openrouter.ai/api/alpha/decisions"]);
    for (const [, init] of paid) expect(authOf(init)).toBe(`Bearer ${ALICE_KEY}`);
    expect(names(f)).not.toContain("reserve_billing_ai_spend_v2");
  });
});

describe("키를 쓸 수 없으면 네트워크 호출 0", () => {
  it.each([
    ["키 없음", { keys: [] }, "ai_key_missing"],
    ["폐기됨", { keys: [keyRow(ALICE, ALICE_KEY, { status: "revoked" })] }, "ai_key_revoked"],
    ["열리지 않는 봉인 글자", { keys: [keyRow(ALICE, ALICE_KEY, { sealed_key: sealUserKey(ALICE_KEY, BOB, Buffer.from(ENV_KEY, "base64")) })] }, "ai_key_missing"],
  ])("%s", async (_label, over, reason) => {
    const f = setup(over);
    const error = await f.as(ALICE)(chat, requestWith()).catch((e: Error) => e);
    expect(error).toMatchObject({ message: reason, code: "billing_required" });
    expect(f.send).not.toHaveBeenCalled();
    expect(names(f)).toEqual([]);
  });

  it("BYOK_ENABLED가 꺼져 있으면 Lifetime의 AI는 닫힌 쪽으로 멈춘다 (관리형으로 새지 않는다)", async () => {
    const f = setup({ env: { BYOK_ENABLED: "false" } });
    await expect(f.as(ALICE)(chat, requestWith())).rejects.toMatchObject({ code: "billing_required" });
    expect(f.send).not.toHaveBeenCalled();
    expect(names(f)).toEqual([]);
  });

  it("USER_AI_KEY_ENCRYPTION_KEY가 없으면 설정 오류로 닫힌다 (닫힌 코드, 네트워크 0)", async () => {
    const f = setup();
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", "");
    await expect(f.as(ALICE)(chat, requestWith())).rejects.toMatchObject({ code: "ai_budget_unavailable" });
    expect(f.send).not.toHaveBeenCalled();
  });

  it("키 표를 읽지 못하면 닫힌다", async () => {
    const f = setup();
    const broken = {
      ...f.admin,
      from: (table: string) => (table === "user_ai_keys" ? { select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: { message: "down" } }) }) }) } : f.admin.from(table)),
    } as never;
    await expect(budgetFetch(broken, ALICE, f.send as unknown as typeof fetch)(chat, requestWith())).rejects.toMatchObject({ code: "ai_budget_unavailable" });
    expect(f.send).not.toHaveBeenCalled();
  });

  it("관리형으로 새지 않는다: 키 없는 Lifetime의 요청에 어떤 Authorization도 나가지 않는다", async () => {
    const f = setup({ keys: [] });
    await f.as(ALICE)(chat, requestWith()).catch(() => undefined);
    expect(calls(f).filter(([, init]) => authOf(init) !== null)).toEqual([]);
  });
});

describe("관리형 사용자는 그대로", () => {
  it("Pro: 헤더는 들어온 그대로, 예약 1 · 정산 1, 키 표는 읽지 않는다", async () => {
    const f = setup({ accounts: [pro()], keys: [keyRow(ALICE, ALICE_KEY)] });
    await f.as(ALICE)(chat, requestWith());
    expect(authOf(paidCalls(f)[0][1])).toBe(`Bearer ${MANAGED}`);
    expect(names(f)).toEqual(["reserve_billing_ai_spend_v2", "settle_ai_spend", "record_ai_spend_tokens"]);
    expect(JSON.stringify(calls(f))).not.toContain(ALICE_KEY);
  });

  it("Lifetime이 아니면 표에 키 행이 남아 있어도 쓰지 않는다 (환불 뒤 등)", async () => {
    const f = setup({ accounts: [accountRow({ user_id: ALICE, lifetime_status: "refunded", lifetime_order_id: "o", subscription_id: null })], keys: [keyRow(ALICE, ALICE_KEY)] });
    await expect(f.as(ALICE)(chat, requestWith())).rejects.toMatchObject({ code: "billing_required" });
    expect(f.send).not.toHaveBeenCalled();
  });

  it("결제가 꺼져 있으면 저장된 키가 있는 Lifetime 계정도 관리형 베타 그대로 (관리형 키 · 옛 예약, 사용자 키는 쓰이지도 지워지지도 않는다): 키 표 · 계정 표를 읽지 않는다", async () => {
    const f = setup({ env: { BILLING_ENABLED: "false" } });
    expect(f.tables.get("billing_accounts")?.[0]).toMatchObject({ lifetime_status: "active" });
    await f.as(ALICE)(chat, requestWith());
    expect(authOf(paidCalls(f)[0][1])).toBe(`Bearer ${MANAGED}`);
    expect(JSON.stringify(calls(f))).not.toContain(ALICE_KEY);
    expect(names(f)).toEqual(["reserve_ai_spend", "settle_ai_spend"]);
    expect(f.tables.get("user_ai_keys")).toHaveLength(1);
    expect(f.tables.get("user_ai_keys")![0]).toMatchObject({ status: "connected" });
    expect(f.writes).toEqual([]);
  });
});

describe("제공자 응답에 따른 키 상태", () => {
  it("401: 그 봉인 글자를 폐기 표시하고 응답은 그대로 돌려준다. 다음 호출부터는 네트워크 0", async () => {
    const f = setup({ reply: () => new Response("no", { status: 401 }) });
    const response = await f.as(ALICE)(chat, requestWith());
    expect(response.status).toBe(401);
    expect(f.rpcNamed("ai_key_mark_revoked")).toEqual([{ p_user_id: ALICE, p_sealed_key: f.tables.get("user_ai_keys")![0].sealed_key }]);
    const before = f.send.mock.calls.length;
    await expect(f.as(ALICE)(chat, requestWith())).rejects.toMatchObject({ message: "ai_key_revoked", code: "billing_required" });
    expect(f.send.mock.calls.length).toBe(before);
  });

  it.each([402, 403])("%i: 한도 오류 시각만 남기고 상태는 connected 그대로. 응답을 그대로 돌려주고 다음 호출은 다시 시도한다", async (status) => {
    const f = setup({ reply: () => new Response("pay", { status }) });
    expect((await f.as(ALICE)(chat, requestWith())).status).toBe(status);
    expect(f.rpcNamed("ai_key_note_spend_error")).toHaveLength(1);
    expect(names(f)).not.toContain("ai_key_mark_revoked");
    const before = paidCalls(f).length;
    await f.as(ALICE)(chat, requestWith());
    expect(paidCalls(f).length).toBe(before + 1);
  });

  it.each([429, 500, 502, 503])("%i: 키 상태를 건드리지 않는다", async (status) => {
    const f = setup({ reply: () => new Response("x", { status }) });
    expect((await f.as(ALICE)(chat, requestWith())).status).toBe(status);
    expect(names(f).filter((name) => name.startsWith("ai_key_"))).toEqual([]);
  });

  it("성공: 오래된 표시(한도 오류 · 한 시간 넘은 성공 기록)가 있을 때만 성공을 적는다", async () => {
    const stale = setup({ keys: [keyRow(ALICE, ALICE_KEY, { last_spend_error_at: new Date().toISOString() })] });
    await stale.as(ALICE)(chat, requestWith());
    expect(stale.rpcNamed("ai_key_note_ok")).toHaveLength(1);
    const old = setup({ keys: [keyRow(ALICE, ALICE_KEY, { last_ok_at: new Date(Date.now() - 2 * HOUR).toISOString() })] });
    await old.as(ALICE)(chat, requestWith());
    expect(old.rpcNamed("ai_key_note_ok")).toHaveLength(1);
    const fresh = setup();
    await fresh.as(ALICE)(chat, requestWith());
    expect(names(fresh).filter((name) => name.startsWith("ai_key_"))).toEqual([]);
  });

  it("상태를 적는 데 실패해도 응답은 그대로이고, 로그에는 키 없는 고정 글자뿐이다", async () => {
    const spies = consoleSpies();
    const f = setup({ reply: () => new Response("no", { status: 401 }), rpcs: { ai_key_mark_revoked: () => ({ error: { message: `db down ${ALICE_KEY}` } }) } });
    expect((await f.as(ALICE)(chat, requestWith())).status).toBe(401);
    expect(printed(spies)).not.toContain("sk-or");
    spies.forEach((spy) => spy.mockRestore());
  });
});

describe("사용자 사이에 섞이지 않는다", () => {
  it("두 Lifetime 사용자를 번갈아 · 동시에 불러도 각자 자기 키만 쓴다", async () => {
    const f = setup({ accounts: [lifetime(ALICE), lifetime(BOB)], keys: [keyRow(ALICE, ALICE_KEY), keyRow(BOB, BOB_KEY)] });
    const alice = f.as(ALICE);
    const bob = f.as(BOB);
    await alice(chat, requestWith());
    await bob(chat, requestWith());
    await Promise.all([alice(chat, requestWith()), bob(chat, requestWith()), bob(chat, requestWith()), alice(chat, requestWith())]);
    const keys = paidCalls(f).map(([, init]) => authOf(init));
    expect(keys.filter((key) => key === `Bearer ${ALICE_KEY}`)).toHaveLength(3);
    expect(keys.filter((key) => key === `Bearer ${BOB_KEY}`)).toHaveLength(3);
  });

  it("한 사용자의 401이 다른 사용자의 키를 폐기하지 않는다", async () => {
    const f = setup({
      accounts: [lifetime(ALICE), lifetime(BOB)], keys: [keyRow(ALICE, ALICE_KEY), keyRow(BOB, BOB_KEY)],
      reply: (_url, init) => new Response("x", { status: authOf(init) === `Bearer ${ALICE_KEY}` ? 401 : 200 }),
    });
    await f.as(ALICE)(chat, requestWith());
    expect((await f.as(BOB)(chat, requestWith())).status).toBe(200);
    expect(f.tables.get("user_ai_keys")!.map((row) => [row.user_id, row.status])).toEqual([[ALICE, "revoked"], [BOB, "connected"]]);
  });

  it("호출이 도는 동안 사용자가 키를 바꾸면 늦게 온 401은 새 키를 폐기하지 않는다 (봉인 글자로 맞춘다)", async () => {
    const f = setup({ reply: () => new Response("no", { status: 401 }) });
    const used = f.tables.get("user_ai_keys")![0].sealed_key;
    await f.as(ALICE)(chat, requestWith());
    expect(f.rpcNamed("ai_key_mark_revoked")[0].p_sealed_key).toBe(used);
  });
});

describe("키가 어디에도 남지 않는다", () => {
  it("성공 · 401 · 402 · 실패 · 네트워크 오류 동안 console에 키가 없다", async () => {
    const spies = consoleSpies();
    for (const reply of [
      () => new Response("ok"), () => new Response(`bad ${ALICE_KEY}`, { status: 401 }), () => new Response(`pay ${ALICE_KEY}`, { status: 402 }),
      () => new Response(`${ALICE_KEY}`, { status: 500 }), () => { throw new Error(`socket ${ALICE_KEY}`); },
    ]) {
      const f = setup({ reply });
      await f.as(ALICE)(chat, requestWith()).catch(() => undefined);
    }
    expect(printed(spies)).not.toContain("sk-or");
    spies.forEach((spy) => spy.mockRestore());
  });

  it("관리형 키가 든 헤더 · 사용자 키는 던지는 AiBudgetError 글에 없다", async () => {
    for (const over of [{ keys: [] }, { keys: [keyRow(ALICE, ALICE_KEY, { status: "revoked" })] }, { env: { BYOK_ENABLED: "false" } }]) {
      const f = setup(over);
      const error = await f.as(ALICE)(chat, requestWith()).catch((e: Error) => e);
      expect(JSON.stringify({ message: (error as Error).message, user: (error as { userMessage?: string }).userMessage })).not.toMatch(/sk-or/);
    }
  });

  it("completeJson이 받은 401 본문 속 키는 오류의 detail에서 가려진다 (사용자 키 경로 끝에서 끝까지)", async () => {
    const f = setup({ reply: () => new Response(JSON.stringify({ error: { message: `Invalid key ${ALICE_KEY}` } }), { status: 401 }) });
    const error = await completeJson({ apiKey: MANAGED, model: "m", providers: ["p"], fetch: f.as(ALICE) }, { system: "s", user: "u", schemaName: "t", schema: z.object({ ok: z.boolean() }) }).catch((e: Error) => e);
    expect(error).toBeInstanceOf(LlmError);
    expect(JSON.stringify([(error as Error).message, (error as LlmError).detail])).not.toContain("sk-or-v1");
    expect(f.rpcNamed("ai_key_mark_revoked")).toHaveLength(1);
  });
});
