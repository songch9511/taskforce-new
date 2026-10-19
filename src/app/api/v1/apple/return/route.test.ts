import { afterEach, describe, expect, it, vi } from "vitest";

import { GET, POST } from "./route";

// POST /api/v1/apple/return — Mac의 Apple 웹 로그인이 form_post로 돌아오는 곳. 로그인 없이 부르고, 결과를 taskforce://auth/apple로 넘기기만 한다.
// 저장 · 기록 0: 어떤 경우에도 console을 부르지 않는다.

const STATE = "Abcdefghijklmnop_-0123456789";
const URL_ = "https://api.example.test/api/v1/apple/return";
const FORM_HEADERS = { "content-type": "application/x-www-form-urlencoded" };
const post = (body: string, headers: Record<string, string> = FORM_HEADERS) => POST(new Request(URL_, { method: "POST", headers, body }));
const form = (entries: Record<string, string>) => new URLSearchParams(entries).toString();

const spies = (["log", "info", "warn", "error", "debug", "trace"] as const).map((method) => vi.spyOn(console, method).mockImplementation(() => {}));
afterEach(() => spies.forEach((spy) => spy.mockClear()));
const consoleCalls = () => spies.reduce((total, spy) => total + spy.mock.calls.length, 0);

describe("POST /api/v1/apple/return", () => {
  it("정상 응답은 303이고 Location이 taskforce://auth/apple? 에 state · code · id_token을 싣는다", async () => {
    const response = await post(form({ state: STATE, code: "c1.0.abc", id_token: "aaa.bbb.ccc" }));
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(`taskforce://auth/apple?state=${STATE}&code=c1.0.abc&id_token=aaa.bbb.ccc`);
    expect(await response.text()).toBe("");
  });

  it("no-store · no-referrer 헤더를 붙인다", async () => {
    const response = await post(form({ state: STATE, code: "c1" }));
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
  });

  it("user(이름 · 이메일 JSON)는 버린다", async () => {
    const user = JSON.stringify({ name: { firstName: "길동", lastName: "홍" }, email: "gildong@example.com" });
    const response = await post(form({ state: STATE, code: "c1", id_token: "a.b.c", user }));
    const location = response.headers.get("location")!;
    expect(location).toBe(`taskforce://auth/apple?state=${STATE}&code=c1&id_token=a.b.c`);
    expect(decodeURIComponent(location)).not.toContain("gildong");
    expect(decodeURIComponent(location)).not.toContain("길동");
  });

  it("Apple의 error(취소)를 state와 함께 넘긴다", async () => {
    const response = await post(form({ state: STATE, error: "user_cancelled_authorize" }));
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe(`taskforce://auth/apple?state=${STATE}&error=user_cancelled_authorize`);
  });

  it("state 모양이 틀리면 state 없이 error=invalid_response로 앱에 돌려준다", async () => {
    const response = await post(form({ state: "short", code: "c1", id_token: "a.b.c" }));
    expect(response.status).toBe(303);
    expect(response.headers.get("location")).toBe("taskforce://auth/apple?error=invalid_response");
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("state는 맞지만 내용이 없으면 state와 함께 invalid_response", async () => {
    const response = await post(form({ state: STATE }));
    expect(response.headers.get("location")).toBe(`taskforce://auth/apple?state=${STATE}&error=invalid_response`);
  });

  it("charset이 붙은 content-type도 받는다", async () => {
    const response = await post(form({ state: STATE, code: "c1" }), { "content-type": "application/x-www-form-urlencoded; charset=UTF-8" });
    expect(response.status).toBe(303);
  });

  it("form이 아닌 content-type은 415이고 앱 주소로 보내지 않는다", async () => {
    for (const type of ["application/json", "text/plain", "multipart/form-data; boundary=x"]) {
      const response = await post(form({ state: STATE, code: "c1" }), { "content-type": type });
      expect(response.status).toBe(415);
      expect(response.headers.get("location")).toBeNull();
    }
    expect((await POST(new Request(URL_, { method: "POST", body: "state=x" }))).status).toBe(415);
  });

  it("16KB를 넘으면 413: content-length만 보고도 본문을 읽기 전에 거절한다", async () => {
    const response = await post("x", { ...FORM_HEADERS, "content-length": String(16 * 1024 + 1) });
    expect(response.status).toBe(413);
    expect(response.headers.get("location")).toBeNull();
  });

  it("content-length가 없거나 거짓이어도 실제 본문이 16KB를 넘으면 413", async () => {
    const big = form({ state: STATE, user: "u".repeat(16 * 1024) });
    const response = await post(big);
    expect(response.status).toBe(413);
    expect(response.headers.get("location")).toBeNull();
    const lying = await post(big, { ...FORM_HEADERS, "content-length": "10" });
    expect(lying.status).toBe(413);
  });

  it("정확히 16KB까지는 받는다", async () => {
    const head = form({ state: STATE, code: "c1", user: "" });
    const body = `${head}${"a".repeat(16 * 1024 - head.length)}`;
    expect(body.length).toBe(16 * 1024);
    const response = await post(body);
    expect(response.status).toBe(303);
  });

  it("GET은 405이고 POST만 허용한다고 알린다", async () => {
    const response = await GET();
    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("POST");
    expect(response.headers.get("location")).toBeNull();
  });

  it("console을 한 번도 부르지 않는다: 정상 · 취소 · 오류 · 413 · 415 어느 경우에도", async () => {
    await post(form({ state: STATE, code: "SECRET-CODE", id_token: "SECRET.ID.TOKEN", user: '{"email":"a@b.c"}' }));
    await post(form({ state: STATE, error: "user_cancelled_authorize" }));
    await post(form({ state: "bad", code: "SECRET-CODE" }));
    await post("%%%");
    await post("x", { ...FORM_HEADERS, "content-length": "999999" });
    await post(form({ state: STATE, code: "SECRET-CODE" }), { "content-type": "application/json" });
    await GET();
    expect(consoleCalls()).toBe(0);
  });
});
