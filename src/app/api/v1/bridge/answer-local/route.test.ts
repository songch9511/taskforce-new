import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { RateLimitedError } from "@/lib/api/rate-limit";
import { errorResponse } from "@/lib/api/respond";

vi.mock("server-only", () => ({}));
const mocks = vi.hoisted(() => ({ account: vi.fn(), auth: vi.fn(), limit: vi.fn(), answer: vi.fn(), cookie: vi.fn() }));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: mocks.account }));
vi.mock("@/lib/bridge/auth", () => ({ verifyBridgeDevice: mocks.auth }));
vi.mock("@/lib/api/rate-limit", async (original) => ({ ...await original<typeof import("@/lib/api/rate-limit")>(), takeBridgeRequestLimit: mocks.limit }));
vi.mock("@/lib/bridge/answer-local", () => ({ answerSecretLocally: mocks.answer }));
vi.mock("@/lib/supabase/server", () => ({ createClient: mocks.cookie }));

import { POST, maxDuration } from "./route";

// OA F2 U2: route 순서 · 값 거절. 값은 서버로 오지 않는다 — 본문이 닫힌 모양이 아니면 고정 문구로 거절하고, 카나리는 응답 · 로그 · 일 시키는 인자 어디에도 없다.
const CANARY = "DO_NOT_STORE_SECRET_F2";
const userId = "11111111-1111-4111-8111-111111111111";
const bridgeId = "22222222-2222-4222-8222-222222222222";
const taskId = "33333333-3333-4333-8333-333333333333";
const stepId = "44444444-4444-4444-8444-444444444444";
const secret = "A".repeat(43);
const digest = "b".repeat(64);
const account = { user: { id: userId } };
const admin = { admin: true };
const bridge = { id: bridgeId };
const body = { bridge_id: bridgeId, agent_task_id: taskId, request_digest: digest };
const FIXED_400 = { error: { code: "invalid_request", message: "Invalid local answer request." } };

const request = (payload: unknown = body, init: { headers?: Record<string, string>; url?: string } = {}) =>
  new Request(init.url ?? "https://api.example.test/api/v1/bridge/answer-local", {
    method: "POST", body: typeof payload === "string" ? payload : JSON.stringify(payload),
    headers: { "X-Taskforce-Bridge-Secret": secret, ...init.headers },
  });
const streamed = (chunks: Uint8Array[], cancel = vi.fn()) => {
  const stream = new ReadableStream<Uint8Array>({ start(controller) { for (const chunk of chunks) controller.enqueue(chunk); }, cancel });
  return { cancel, request: new Request("https://api.example.test/api/v1/bridge/answer-local", { method: "POST", body: stream, duplex: "half", headers: { "X-Taskforce-Bridge-Secret": secret } } as RequestInit) };
};
const logs = () => (["log", "info", "warn", "error", "debug"] as const).map((level) => vi.spyOn(console, level).mockImplementation(() => {}));

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("CONVERSATIONS_V2_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CODEX_ENABLED", "true");
  vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "");
  mocks.account.mockResolvedValue(account);
  mocks.auth.mockResolvedValue({ user: account.user, admin, bridge });
  mocks.limit.mockResolvedValue(undefined);
  mocks.answer.mockResolvedValue({ status: "answered", step_id: stepId });
});
afterEach(() => { vi.unstubAllEnvs(); vi.restoreAllMocks(); });

describe("gate: 꺼지면 404이고 인증 · DB가 없다", () => {
  const closed: [string, Record<string, string>][] = [
    ["아무것도 안 켬", { CONVERSATIONS_V2_ENABLED: "", AGENT_ADAPTER_CODEX_ENABLED: "" }],
    ["대화 v2만 켬", { AGENT_ADAPTER_CODEX_ENABLED: "" }],
    ["adapter만 켬", { CONVERSATIONS_V2_ENABLED: "" }],
    ["TRUE(대소문자)", { CONVERSATIONS_V2_ENABLED: "TRUE" }],
    ["1", { CONVERSATIONS_V2_ENABLED: "1" }],
  ];
  it.each(closed)("%s", async (_name, env) => {
    for (const [key, value] of Object.entries(env)) vi.stubEnv(key, value);
    const req = request();
    const response = await POST(req);
    expect(response.status).toBe(404);
    expect(await response.json()).toMatchObject({ error: { code: "not_found" } });
    expect(req.bodyUsed).toBe(false);
    expect(mocks.account).not.toHaveBeenCalled();
    expect(mocks.cookie).not.toHaveBeenCalled();
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.limit).not.toHaveBeenCalled();
    expect(mocks.answer).not.toHaveBeenCalled();
  });
});

describe("순서: gate → 인증 → 본문 → 기기 → 한도 → 일", () => {
  it("성공: 200 · no-store · maxDuration 15, 일에는 사용자 · bridge · 기기 secret · 본문 · 열린 adapter만 간다", async () => {
    const req = request();
    const response = await POST(req);
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(maxDuration).toBe(15);
    expect(await response.json()).toEqual({ status: "answered", step_id: stepId });
    expect(mocks.account).toHaveBeenCalledExactlyOnceWith(req);
    expect(mocks.auth).toHaveBeenCalledExactlyOnceWith(expect.any(Request), bridgeId, account);
    expect(mocks.limit).toHaveBeenCalledExactlyOnceWith(admin, userId, bridgeId, "bridge_ack");
    expect(mocks.answer).toHaveBeenCalledExactlyOnceWith(admin, { userId, bridgeId, deviceSecret: secret, input: body, adapters: ["agent:codex"] });
    const order = [mocks.account, mocks.auth, mocks.limit, mocks.answer].map((mock) => mock.mock.invocationCallOrder[0]);
    expect([...order].sort((x, y) => x - y)).toEqual(order);
  });

  it("두 adapter가 모두 켜지면 둘 다 일에 간다", async () => {
    vi.stubEnv("AGENT_ADAPTER_CLAUDE_CODE_ENABLED", "true");
    await POST(request());
    expect(mocks.answer.mock.calls[0][1].adapters).toEqual(["agent:claude-code", "agent:codex"]);
  });

  it("토큰이 없으면 401이고 본문을 읽지 않으며 기기 · 일이 없다", async () => {
    mocks.account.mockResolvedValue(null);
    const req = request();
    expect((await POST(req)).status).toBe(401);
    expect(req.bodyUsed).toBe(false);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.answer).not.toHaveBeenCalled();
  });

  it("실제 쿠키 인증: 교차 사이트 POST는 401이고 본문 · 기기 · 일이 없다", async () => {
    const real = await vi.importActual<typeof import("@/lib/api/auth")>("@/lib/api/auth");
    mocks.account.mockImplementation(real.authenticateRequest);
    const req = request(body, { headers: { origin: "https://evil.test", cookie: "session=fake" } });
    expect((await POST(req)).status).toBe(401);
    expect(req.bodyUsed).toBe(false);
    expect(mocks.cookie).not.toHaveBeenCalled();
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.answer).not.toHaveBeenCalled();
  });

  it.each([401, 403, 404])("기기 %s는 그대로 돌려주고 한도 · 일이 없다", async (status) => {
    mocks.auth.mockResolvedValue({ error: errorResponse(status, status === 404 ? "not_found" : "unauthorized", "Denied") });
    expect((await POST(request())).status).toBe(status);
    expect(mocks.limit).not.toHaveBeenCalled();
    expect(mocks.answer).not.toHaveBeenCalled();
  });

  it("한도를 넘으면 429 + Retry-After이고 일이 없다 (기기 인증 뒤에만 한도를 쓴다)", async () => {
    mocks.limit.mockRejectedValue(new RateLimitedError(new Date(Date.now() + 30_000)));
    const response = await POST(request());
    expect(response.status).toBe(429);
    expect(Number(response.headers.get("retry-after"))).toBeGreaterThan(0);
    expect(await response.json()).toEqual({ error: { code: "rate_limited", message: "Please try again later." } });
    expect(mocks.answer).not.toHaveBeenCalled();
  });
});

describe("값 거절: 닫힌 모양이 아니면 고정 문구 400이고 아무것도 되돌려주지 않는다", () => {
  const cases: [string, unknown][] = [
    ["answers 키", { ...body, answers: { choice: CANARY } }],
    ["value 키", { ...body, value: CANARY }],
    ["secret 키", { ...body, secret: CANARY }],
    ["provider_request_id 키", { ...body, provider_request_id: CANARY }],
    ["answer_text 키", { ...body, answer_text: CANARY }],
    ["digest 자리에 카나리", { ...body, request_digest: CANARY }],
    ["digest 대문자 16진", { ...body, request_digest: digest.toUpperCase() }],
    ["digest 63자", { ...body, request_digest: digest.slice(1) }],
    ["bridge_id 자리에 카나리", { ...body, bridge_id: CANARY }],
    ["task id 자리에 카나리", { ...body, agent_task_id: CANARY }],
    ["키 빠짐", { bridge_id: bridgeId, agent_task_id: taskId }],
    ["배열", [body]],
    ["null", null],
    ["문자열", CANARY],
    ["깨진 JSON", `{"bridge_id": "${CANARY}`],
    ["빈 본문", ""],
  ];
  it.each(cases)("%s", async (_name, payload) => {
    const spies = logs();
    const response = await POST(request(typeof payload === "string" ? payload : payload === null ? "null" : payload));
    expect(response.status).toBe(400);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual(FIXED_400);
    for (const key of ["answers", "value", "secret", "provider_request_id", "answer_text", "request_digest", "bridge_id", "agent_task_id", CANARY]) expect(text).not.toContain(key);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.answer).not.toHaveBeenCalled();
    for (const spy of spies) expect(JSON.stringify(spy.mock.calls)).not.toContain(CANARY);
  });

  it("본문이 없으면(스트림 없음) 400", async () => {
    const response = await POST(new Request("https://api.example.test/api/v1/bridge/answer-local", { method: "POST" }));
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual(FIXED_400);
  });
});

describe("본문 크기: 512바이트를 넘으면 읽기를 끊는다", () => {
  const pad = (size: number) => {
    const json = JSON.stringify(body);
    return json + " ".repeat(size - Buffer.byteLength(json));
  };
  it("정확히 512바이트는 통과한다 (Content-Length를 속여도 센 바이트가 기준)", async () => {
    const response = await POST(request(pad(512), { headers: { "Content-Length": "1" } }));
    expect(response.status).toBe(200);
  });

  it("513바이트는 400이고 리더를 끊는다: 파싱 · 기기 · 일 0", async () => {
    const text = pad(513);
    const { cancel, request: req } = streamed([new TextEncoder().encode(text)]);
    const parse = vi.spyOn(JSON, "parse");
    const response = await POST(req);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual(FIXED_400);
    expect(cancel).toHaveBeenCalled();
    expect(parse.mock.calls.some(([arg]) => typeof arg === "string" && arg.includes("bridge_id"))).toBe(false);
    expect(mocks.auth).not.toHaveBeenCalled();
    expect(mocks.answer).not.toHaveBeenCalled();
  });

  it("여러 조각이 합쳐 넘어도 첫 넘는 조각에서 끊는다", async () => {
    const chunk = new TextEncoder().encode("x".repeat(300));
    const { cancel, request: req } = streamed([chunk, chunk, chunk]);
    expect((await POST(req)).status).toBe(400);
    expect(cancel).toHaveBeenCalled();
    expect(mocks.answer).not.toHaveBeenCalled();
  });

  it("카나리를 크게 부풀린 본문도 응답 · 로그에 카나리가 없다", async () => {
    const spies = logs();
    const response = await POST(request(JSON.stringify({ ...body, value: CANARY.repeat(100) })));
    expect(response.status).toBe(400);
    expect(await response.text()).not.toContain(CANARY);
    for (const spy of spies) expect(JSON.stringify(spy.mock.calls)).not.toContain(CANARY);
  });
});

describe("쿼리 문자열 · 헤더는 값이 될 수 없다", () => {
  it("쿼리의 카나리는 무시된다: 일 · 응답 · 로그 어디에도 없다", async () => {
    const spies = logs();
    const url = `https://api.example.test/api/v1/bridge/answer-local?value=${CANARY}&secret=${CANARY}&answers=${CANARY}&provider_request_id=${CANARY}`;
    const response = await POST(request(body, { url }));
    expect(response.status).toBe(200);
    expect(JSON.stringify(await response.json())).not.toContain(CANARY);
    expect(JSON.stringify(mocks.answer.mock.calls)).not.toContain(CANARY);
    expect(JSON.stringify(mocks.auth.mock.calls)).not.toContain(CANARY);
    for (const spy of spies) expect(JSON.stringify(spy.mock.calls)).not.toContain(CANARY);
  });

  it("route는 기기 secret 헤더만 일에 넘긴다 (다른 헤더의 카나리는 닿지 않는다)", async () => {
    await POST(request(body, { headers: { "X-Answer-Value": CANARY, "X-Secret": CANARY } }));
    expect(JSON.stringify(mocks.answer.mock.calls)).not.toContain(CANARY);
    expect(mocks.answer.mock.calls[0][1].deviceSecret).toBe(secret);
  });
});

describe("결과 → 응답 (3A.3)", () => {
  it.each([
    [{ status: "answered", step_id: stepId }],
    [{ status: "duplicate", step_id: stepId }],
    [{ status: "stale", reason: "question_closed" }],
    [{ status: "stale", reason: "not_live" }],
    [{ status: "stale", reason: "not_secret" }],
  ])("%j → 200 그대로", async (result) => {
    mocks.answer.mockResolvedValue(result);
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual(result);
  });

  it("not_found → 404 고정 문구", async () => {
    mocks.answer.mockResolvedValue({ status: "not_found" });
    const response = await POST(request());
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({ error: { code: "not_found", message: "Local answer target not found." } });
  });

  it("invalid → 400 고정 문구", async () => {
    mocks.answer.mockResolvedValue({ status: "invalid" });
    const response = await POST(request());
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual(FIXED_400);
  });

  it("busy → 409 conflict (다시 보내도 된다)", async () => {
    mocks.answer.mockResolvedValue({ status: "busy" });
    const response = await POST(request());
    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({ error: { code: "conflict", message: "Busy, retry." } });
  });

  it("그 밖의 오류 → 500, 로그는 {event} 한 줄이고 id · digest · 오류 글이 없다", async () => {
    const spies = logs();
    mocks.answer.mockRejectedValue(new Error(`private ${CANARY} ${taskId} ${digest} ${bridgeId}`));
    const response = await POST(request());
    expect(response.status).toBe(500);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ error: { code: "internal_error", message: "Bridge request failed." } });
    for (const needle of [CANARY, taskId, digest, bridgeId, "private"]) expect(text).not.toContain(needle);
    const called = spies.filter((spy) => spy.mock.calls.length > 0);
    expect(called).toHaveLength(1);
    expect(called[0].mock.calls).toEqual([[JSON.stringify({ event: "bridge_answer_local_failed" })]]);
    expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "bridge_answer_local_failed" }));
  });
});
