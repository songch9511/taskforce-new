import { randomBytes } from "node:crypto";
import { afterEach, describe, expect, it, vi } from "vitest";

import { fakeAdmin } from "@/lib/billing/testing";
import {
  checkKeyFormat,
  deleteUserKey,
  noteUserKeyOk,
  noteUserKeySpendError,
  markUserKeyRevoked,
  openUserKey,
  putUserKey,
  readUserKey,
  sealUserKey,
  userKeyEncryptionKey,
  userKeyStatus,
  verifyOpenRouterKey,
  UserKeyError,
} from "./user-key";

vi.mock("server-only", () => ({}));

// 시험용 모양 값이다 (실제 키가 아니다).
const FAKE = "sk-or-v1-fake-test-value-not-a-real-key-0000000000000000000000000";
const ALICE = "11111111-1111-4111-8111-111111111111";
const BOB = "22222222-2222-4222-8222-222222222222";
const ENV_KEY = randomBytes(32).toString("base64");

afterEach(() => vi.unstubAllEnvs());

const key = () => Buffer.from(ENV_KEY, "base64");

describe("봉인 (AES-256-GCM, AAD = openrouter:<user_id>)", () => {
  it("k1.<iv>.<tag>.<ct> 모양이고 평문이 보이지 않으며 왕복한다", () => {
    const sealed = sealUserKey(FAKE, ALICE, key());
    const parts = sealed.split(".");
    expect(parts).toHaveLength(4);
    expect(parts[0]).toBe("k1");
    expect(Buffer.from(parts[1], "base64")).toHaveLength(12);
    expect(Buffer.from(parts[2], "base64")).toHaveLength(16);
    expect(sealed).not.toContain(FAKE);
    expect(sealed).not.toContain("sk-or");
    expect(Buffer.from(parts[3], "base64").toString("utf8")).not.toContain("sk-or");
    expect(openUserKey(sealed, ALICE, key())).toBe(FAKE);
  });

  it("같은 키를 두 번 봉인해도 글자가 다르다 (iv)", () => {
    expect(sealUserKey(FAKE, ALICE, key())).not.toBe(sealUserKey(FAKE, ALICE, key()));
  });

  it("다른 사용자의 암호문을 옮겨 놓으면 열리지 않는다 (AAD)", () => {
    const sealed = sealUserKey(FAKE, BOB, key());
    expect(() => openUserKey(sealed, ALICE, key())).toThrow(UserKeyError);
    expect(() => openUserKey(sealed, ALICE, key())).toThrow(/user_key_open_failed/);
  });

  it("다른 env 키로는 열리지 않고, 바꾼 글자 · 잘린 글자 · 모르는 판도 열리지 않는다", () => {
    const sealed = sealUserKey(FAKE, ALICE, key());
    expect(() => openUserKey(sealed, ALICE, randomBytes(32))).toThrow(UserKeyError);
    const [v, iv, tag, ct] = sealed.split(".");
    const flipped = Buffer.from(ct, "base64");
    flipped[0] ^= 1;
    for (const bad of [
      `${v}.${iv}.${tag}.${flipped.toString("base64")}`,
      `${v}.${iv}.${Buffer.alloc(16).toString("base64")}.${ct}`,
      `${v}.${iv}.${Buffer.from(tag, "base64").subarray(0, 4).toString("base64")}.${ct}`,
      `${v}.${Buffer.alloc(8).toString("base64")}.${tag}.${ct}`,
      `k2.${iv}.${tag}.${ct}`,
      `${v}.${iv}.${tag}`,
      "v1.x.y.z",
      "",
    ])
      expect(() => openUserKey(bad, ALICE, key()), bad).toThrow(UserKeyError);
  });

  it("열기 실패 오류에는 암호문도 키도 담기지 않는다", () => {
    const sealed = sealUserKey(FAKE, BOB, key());
    try {
      openUserKey(sealed, ALICE, key());
      expect.unreachable();
    } catch (error) {
      const text = `${(error as Error).message} ${JSON.stringify(error)} ${(error as Error).stack}`;
      expect(text).not.toContain(FAKE);
      expect(text).not.toContain(sealed.split(".")[3]);
    }
  });
});

describe("env 키 USER_AI_KEY_ENCRYPTION_KEY", () => {
  it("32바이트 base64만 받는다", () => {
    expect(userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: ENV_KEY })).toEqual(key());
    for (const bad of [undefined, "", "short", randomBytes(31).toString("base64"), randomBytes(33).toString("base64"), `${ENV_KEY}!!`, ENV_KEY.slice(0, 20)])
      expect(() => userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: bad }), String(bad)).toThrow(/user_key_config/);
  });

  it("커넥터 토큰 키와 같은 값이면 거절한다 (따로 둔다)", () => {
    expect(() => userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: ENV_KEY, CONNECTOR_TOKEN_KEY: ENV_KEY })).toThrow(/user_key_config/);
    expect(() => userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: ENV_KEY, CONNECTOR_TOKEN_KEY: randomBytes(32).toString("base64") })).not.toThrow();
  });

  describe("같은 바이트는 글자 모양이 달라도 같은 키다 (connectors/crypto.ts와 같은 느슨한 base64 해석으로 견준다)", () => {
    // + 와 / 가 모두 나오고 끝에 = 가 붙는 32바이트: 표준 · url 안전 · 패딩 없는 모양이 서로 다르다
    const bytes = Buffer.from(Array.from({ length: 32 }, (_, i) => (i % 2 ? 0xff : 0xfb)));
    const standard = bytes.toString("base64");
    const urlSafe = standard.replace(/\+/g, "-").replace(/\//g, "_");
    const variants: [string, string][] = [
      ["표준", standard],
      ["패딩 없음", standard.replace(/=+$/, "")],
      ["앞 공백", ` ${standard}`],
      ["뒤 줄바꿈", `${standard}\n`],
      ["안쪽 줄바꿈", `${standard.slice(0, 12)}\n${standard.slice(12)}`],
      ["안쪽 탭 · 공백", `${standard.slice(0, 8)}\t ${standard.slice(8)}`],
      ["base64url", urlSafe],
      ["base64url 패딩 없음", urlSafe.replace(/=+$/, "")],
      ["base64url 줄바꿈", `${urlSafe}\r\n`],
    ];

    it("시험 값이 모양이 다른 변형을 실제로 만든다", () => {
      expect(standard).toMatch(/\+/);
      expect(standard).toMatch(/\//);
      expect(standard.endsWith("=")).toBe(true);
      expect(new Set(variants.map(([, v]) => v)).size).toBe(variants.length);
      for (const [label, v] of variants) expect(Buffer.from(v, "base64").equals(bytes), label).toBe(true);
    });

    it.each(variants)("커넥터 키가 %s 모양의 같은 바이트면 거절한다", (_label, connector) => {
      expect(() => userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: standard, CONNECTOR_TOKEN_KEY: connector })).toThrow(/user_key_config/);
    });

    it("다른 바이트는 모양이 비슷해도 거절하지 않는다 (한 바이트 차이 · 다른 길이 · 깨진 값 · 비어 있음)", () => {
      const flipped = Buffer.from(bytes);
      flipped[31] ^= 1;
      for (const connector of [flipped.toString("base64"), flipped.toString("base64").replace(/=+$/, ""), bytes.subarray(0, 31).toString("base64"), Buffer.concat([bytes, Buffer.from([1])]).toString("base64"), "not base64 at all !!", "", undefined])
        expect(() => userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: standard, CONNECTOR_TOKEN_KEY: connector }), String(connector)).not.toThrow();
    });

    it("우리 키의 모양 검사는 그대로 엄격하다 (변형 모양은 설정 오류)", () => {
      for (const [label, ours] of variants.slice(1)) expect(() => userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: ours }), label).toThrow(/user_key_config/);
    });
  });

  it("오류 글에 env 값이 담기지 않는다", () => {
    try {
      userKeyEncryptionKey({ USER_AI_KEY_ENCRYPTION_KEY: "not-the-right-length-but-secret-looking" });
      expect.unreachable();
    } catch (error) {
      expect((error as Error).message).not.toContain("secret-looking");
    }
  });
});

describe("키 모양 검사", () => {
  it("앞뒤 공백을 지우고 sk-or- 접두 · 길이 20–256 · 보이는 글자만 받는다", () => {
    expect(checkKeyFormat(`  ${FAKE}\n`)).toEqual({ ok: true, key: FAKE });
    const long = `sk-or-${"a".repeat(250)}`;
    expect(checkKeyFormat(long)).toEqual({ ok: true, key: long });
    expect(checkKeyFormat(`sk-or-${"a".repeat(14)}`).ok).toBe(true); // 정확히 20자
  });

  it.each([
    ["빈 글", ""],
    ["접두 없음", "x".repeat(40)],
    ["다른 접두", `sk-ant-${"a".repeat(40)}`],
    ["19자", `sk-or-${"a".repeat(13)}`],
    ["257자", `sk-or-${"a".repeat(251)}`],
    ["안에 공백", `sk-or-${"a".repeat(10)} ${"b".repeat(10)}`],
    ["줄바꿈", `sk-or-${"a".repeat(10)}\n${"b".repeat(10)}`],
    ["제어 문자", `sk-or-${"a".repeat(10)}\u0000${"b".repeat(10)}`],
    ["한글", `sk-or-${"가".repeat(20)}`],
  ])("거절: %s", (_label, raw) => {
    expect(checkKeyFormat(raw)).toEqual({ ok: false });
  });
});

describe("OpenRouter에 키 검사 (GET /api/v1/key, 비용 0)", () => {
  const reply = (status: number, body: unknown) => vi.fn(async () => new Response(typeof body === "string" ? body : JSON.stringify(body), { status }));

  it("200이고 관리 키가 아니면 ok. 고정 주소에 그 키 하나만 헤더로 보낸다", async () => {
    const send = reply(200, { data: { label: "sk-or-v1-abc...xyz", is_management_key: false, limit: null, usage: 0 } });
    expect(await verifyOpenRouterKey(FAKE, send as unknown as typeof fetch)).toBe("ok");
    expect(send).toHaveBeenCalledTimes(1);
    const [url, init] = send.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://openrouter.ai/api/v1/key");
    expect(init.method ?? "GET").toBe("GET");
    expect(new Headers(init.headers).get("authorization")).toBe(`Bearer ${FAKE}`);
    expect(init.body).toBeUndefined();
    expect(init.signal).toBeInstanceOf(AbortSignal);
    expect(init.redirect).toBe("error");
  });

  it("관리 키 표시가 둘 중 하나라도 false로 오면 ok (옛 이름만 와도 된다)", async () => {
    expect(await verifyOpenRouterKey(FAKE, reply(200, { data: { is_provisioning_key: false } }) as unknown as typeof fetch)).toBe("ok");
    expect(await verifyOpenRouterKey(FAKE, reply(200, { data: { is_management_key: false } }) as unknown as typeof fetch)).toBe("ok");
    expect(await verifyOpenRouterKey(FAKE, reply(200, { data: { is_management_key: false, is_provisioning_key: false } }) as unknown as typeof fetch)).toBe("ok");
  });

  it("관리 키(is_management_key 또는 옛 is_provisioning_key)는 거절한다", async () => {
    expect(await verifyOpenRouterKey(FAKE, reply(200, { data: { is_management_key: true } }) as unknown as typeof fetch)).toBe("management");
    expect(await verifyOpenRouterKey(FAKE, reply(200, { data: { is_provisioning_key: true } }) as unknown as typeof fetch)).toBe("management");
  });

  it("401은 invalid", async () => {
    expect(await verifyOpenRouterKey(FAKE, reply(401, { error: { message: `bad ${FAKE}` } }) as unknown as typeof fetch)).toBe("invalid");
  });

  it.each([
    ["5xx", () => reply(503, "down")],
    ["429", () => reply(429, "slow down")],
    ["403", () => reply(403, "no")],
    ["404", () => reply(404, "no")],
    ["200인데 JSON이 아님", () => reply(200, "<html>")],
    ["200인데 모양이 다름", () => reply(200, { ok: true })],
    ["200인데 관리 키 표시가 둘 다 없음 (확인하지 못한 것은 받지 않는다)", () => reply(200, { data: { label: "sk-or-v1-abc...xyz", usage: 0 } })],
    ["200인데 data가 비어 있음", () => reply(200, { data: {} })],
    ["200인데 관리 키 표시가 null", () => reply(200, { data: { is_management_key: null, is_provisioning_key: null } })],
    ["200인데 관리 키 표시가 글자", () => reply(200, { data: { is_management_key: "false" } })],
    ["네트워크 오류", () => vi.fn(async () => { throw new Error(`connect failed ${FAKE}`); })],
    ["시간 초과", () => vi.fn(async () => { throw new DOMException("timeout", "TimeoutError"); })],
    ["리디렉션", () => vi.fn(async () => { throw new TypeError("redirect mode is set to error"); })],
  ])("확인할 수 없으면 unavailable: %s", async (_label, make) => {
    expect(await verifyOpenRouterKey(FAKE, make() as unknown as typeof fetch)).toBe("unavailable");
  });

  it("오류가 나도 키가 console에 새지 않는다", async () => {
    const spies = (["log", "info", "warn", "error", "debug"] as const).map((level) => vi.spyOn(console, level).mockImplementation(() => undefined));
    await verifyOpenRouterKey(FAKE, vi.fn(async () => { throw new Error(`boom ${FAKE}`); }) as unknown as typeof fetch);
    await verifyOpenRouterKey(FAKE, reply(401, `no ${FAKE}`) as unknown as typeof fetch);
    for (const spy of spies) expect(JSON.stringify(spy.mock.calls)).not.toContain("sk-or");
    spies.forEach((spy) => spy.mockRestore());
  });
});

describe("저장된 키 읽기 (요청마다, 캐시 없음)", () => {
  const setup = (rows: Record<string, unknown>[] = []) => {
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", ENV_KEY);
    return fakeAdmin({ user_ai_keys: rows });
  };
  const row = (userId: string, over: Record<string, unknown> = {}) => ({
    user_id: userId, sealed_key: sealUserKey(FAKE, userId, key()), key_version: 1, status: "connected",
    last_ok_at: new Date().toISOString(), last_spend_error_at: null, ...over,
  });

  it("행이 없으면 missing, 폐기됐으면 revoked. 둘 다 env 키를 보지 않는다", async () => {
    const f = fakeAdmin({ user_ai_keys: [row(BOB, { status: "revoked" })] });
    expect(await readUserKey(f.admin, ALICE)).toEqual({ status: "missing" });
    expect(await readUserKey(f.admin, BOB)).toEqual({ status: "revoked" });
  });

  it("connected면 열어서 키 · 봉인 글자 · 갱신 필요 여부를 준다", async () => {
    const f = setup([row(ALICE)]);
    const own = await readUserKey(f.admin, ALICE);
    expect(own).toMatchObject({ status: "connected", key: FAKE, stale: false });
    if (own.status === "connected") expect(own.sealed).toBe((await f.admin.from("user_ai_keys").select("*").eq("user_id", ALICE).maybeSingle()).data!.sealed_key);
  });

  it("한도 오류 표시가 있거나 성공 기록이 없거나 한 시간 넘었으면 stale", async () => {
    const hour = 3_600_000;
    for (const [over, stale] of [
      [{ last_spend_error_at: new Date().toISOString() }, true],
      [{ last_ok_at: null }, true],
      [{ last_ok_at: new Date(Date.now() - hour - 1000).toISOString() }, true],
      [{ last_ok_at: new Date(Date.now() - hour + 60_000).toISOString() }, false],
    ] as const) {
      const f = setup([row(ALICE, over)]);
      expect(await readUserKey(f.admin, ALICE), JSON.stringify(over)).toMatchObject({ status: "connected", stale });
    }
  });

  it("남의 암호문이 이 행에 있으면 열리지 않아 unreadable", async () => {
    const f = setup([row(ALICE, { sealed_key: sealUserKey(FAKE, BOB, key()) })]);
    expect(await readUserKey(f.admin, ALICE)).toEqual({ status: "unreadable" });
  });

  it("env 키가 바뀌었거나 없으면: 바뀐 키는 unreadable, 없으면 설정 오류", async () => {
    const f = setup([row(ALICE)]);
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", randomBytes(32).toString("base64"));
    expect(await readUserKey(f.admin, ALICE)).toEqual({ status: "unreadable" });
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", "");
    await expect(readUserKey(f.admin, ALICE)).rejects.toThrow(/user_key_config/);
  });

  it("두 사용자를 번갈아 읽어도 섞이지 않는다", async () => {
    const other = "sk-or-v1-otherotherotherotherotherotherotherotherotherotherotherother";
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", ENV_KEY);
    const f = fakeAdmin({ user_ai_keys: [row(ALICE), row(BOB, { sealed_key: sealUserKey(other, BOB, key()) })] });
    for (const [who, expected] of [[ALICE, FAKE], [BOB, other], [ALICE, FAKE], [BOB, other]] as const)
      expect(await readUserKey(f.admin, who)).toMatchObject({ key: expected });
  });

  it("행을 읽다 실패하면 던진다 (닫힌 쪽)", async () => {
    const admin = { from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: { message: "db down" } }) }) }) }) } as never;
    await expect(readUserKey(admin, ALICE)).rejects.toThrow(/user_key_store_unavailable/);
  });
});

describe("상태 (GET /api/v2/billing의 ai_key)", () => {
  it("없음 → missing, connected → connected, revoked → revoked. 한도 오류 시각은 connected일 때만", async () => {
    const at = "2026-10-19T10:00:00.000Z";
    const f = fakeAdmin({ user_ai_keys: [
      { user_id: BOB, status: "connected", last_spend_error_at: at },
      { user_id: "33333333-3333-4333-8333-333333333333", status: "revoked", last_spend_error_at: at },
    ] });
    expect(await userKeyStatus(f.admin, ALICE)).toEqual({ ai_key: "missing", spend_error_at: null });
    expect(await userKeyStatus(f.admin, BOB)).toEqual({ ai_key: "connected", spend_error_at: at });
    expect(await userKeyStatus(f.admin, "33333333-3333-4333-8333-333333333333")).toEqual({ ai_key: "revoked", spend_error_at: null });
  });

  it("읽기 실패는 던진다 (모른다고 missing으로 말하지 않는다)", async () => {
    const admin = { from: () => ({ select: () => ({ eq: () => ({ maybeSingle: async () => ({ data: null, error: { message: "x" } }) }) }) }) } as never;
    await expect(userKeyStatus(admin, ALICE)).rejects.toThrow(/user_key_store_unavailable/);
  });
});

describe("저장 · 지우기 · 표시 (SQL 함수 호출)", () => {
  it("저장: 봉인한 글자만 DB 함수에 보낸다 (평문 · AAD 값은 가지 않는다)", async () => {
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", ENV_KEY);
    const f = fakeAdmin({}, { ai_key_put: () => ({ data: false }) });
    expect(await putUserKey(f.admin, ALICE, FAKE)).toEqual({ replaced: false });
    const [args] = f.rpcNamed("ai_key_put");
    expect(args).toEqual({ p_user_id: ALICE, p_sealed_key: expect.stringMatching(/^k1\./), p_key_version: 1 });
    expect(JSON.stringify(f.rpcCalls)).not.toContain(FAKE);
    expect(openUserKey(args.p_sealed_key as string, ALICE, key())).toBe(FAKE);
  });

  it("저장: 이전 키를 바꿨는지 그대로 돌려준다", async () => {
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", ENV_KEY);
    const f = fakeAdmin({}, { ai_key_put: () => ({ data: true }) });
    expect(await putUserKey(f.admin, ALICE, FAKE)).toEqual({ replaced: true });
  });

  it("저장: 권한이 없으면 not_entitled, 그 밖의 DB 오류는 던진다. 어느 쪽도 키가 오류에 없다", async () => {
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", ENV_KEY);
    const denied = fakeAdmin({}, { ai_key_put: () => ({ error: { message: "byok_not_entitled" } }) });
    await expect(putUserKey(denied.admin, ALICE, FAKE)).rejects.toThrow(/^byok_not_entitled$/);
    const down = fakeAdmin({}, { ai_key_put: () => ({ error: { message: `db down ${FAKE}` } }) });
    const error = await putUserKey(down.admin, ALICE, FAKE).catch((e: Error) => e);
    expect((error as Error).message).toBe("user_key_store_unavailable");
    expect(JSON.stringify(error)).not.toContain(FAKE);
  });

  it("저장: env 키가 없으면 DB를 부르지 않는다", async () => {
    vi.stubEnv("USER_AI_KEY_ENCRYPTION_KEY", "");
    const f = fakeAdmin();
    await expect(putUserKey(f.admin, ALICE, FAKE)).rejects.toThrow(/user_key_config/);
    expect(f.rpcCalls).toEqual([]);
  });

  it("지우기 · 폐기 · 한도 오류 · 성공 표시는 사용자와 봉인 글자를 그대로 넘긴다", async () => {
    const f = fakeAdmin({}, { ai_key_delete: () => ({ data: true }), ai_key_mark_revoked: () => ({ data: true }) });
    expect(await deleteUserKey(f.admin, ALICE)).toBe(true);
    await markUserKeyRevoked(f.admin, ALICE, "k1.a.b.c");
    await noteUserKeySpendError(f.admin, ALICE, "k1.a.b.c");
    await noteUserKeyOk(f.admin, ALICE, "k1.a.b.c");
    expect(f.rpcCalls).toEqual([
      ["ai_key_delete", { p_user_id: ALICE }],
      ["ai_key_mark_revoked", { p_user_id: ALICE, p_sealed_key: "k1.a.b.c" }],
      ["ai_key_note_spend_error", { p_user_id: ALICE, p_sealed_key: "k1.a.b.c" }],
      ["ai_key_note_ok", { p_user_id: ALICE, p_sealed_key: "k1.a.b.c" }],
    ]);
  });

  it("지우기가 실패하면 던진다", async () => {
    const f = fakeAdmin({}, { ai_key_delete: () => ({ error: { message: "x" } }) });
    await expect(deleteUserKey(f.admin, ALICE)).rejects.toThrow(/user_key_store_unavailable/);
  });
});
