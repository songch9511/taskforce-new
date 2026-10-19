import { describe, expect, it } from "vitest";

import { APPLE_APP_CALLBACK, appleReturnLocation } from "./web-return";

// Apple 웹 로그인 중계 (POST /api/v1/apple/return)가 앱으로 돌려줄 주소를 만드는 순수 함수.
// 목적지는 상수 하나라 어떤 입력도 다른 주소로 보낼 수 없다(열린 리다이렉트 0).

const STATE = "Abcdefghijklmnop_-0123456789";
const form = (entries: Record<string, string>) => new URLSearchParams(entries).toString();
const query = (location: string) => new URL(location).searchParams;

describe("appleReturnLocation", () => {
  it("state · code · id_token을 앱 주소로 그대로 넘긴다", () => {
    const location = appleReturnLocation(form({ state: STATE, code: "c1.0.abc.def", id_token: "aaa.bbb.ccc" }));
    expect(location).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&code=c1.0.abc.def&id_token=aaa.bbb.ccc`);
  });

  it("목적지 상수는 taskforce://auth/apple 하나다", () => {
    expect(APPLE_APP_CALLBACK).toBe("taskforce://auth/apple");
  });

  it("재확인(code만)은 id_token 없이 넘긴다", () => {
    expect(appleReturnLocation(form({ state: STATE, code: "c1" }))).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&code=c1`);
  });

  it("user(첫 로그인 때 오는 이름 · 이메일 JSON)는 버린다", () => {
    const user = JSON.stringify({ name: { firstName: "길동", lastName: "홍" }, email: "gildong@example.com" });
    const location = appleReturnLocation(form({ state: STATE, code: "c1", id_token: "a.b.c", user }));
    expect(location).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&code=c1&id_token=a.b.c`);
    expect(decodeURIComponent(location)).not.toContain("gildong");
    expect(decodeURIComponent(location)).not.toContain("길동");
    expect(query(location).has("user")).toBe(false);
  });

  it("error는 state와 함께 넘기고, 같이 온 code · id_token은 싣지 않는다", () => {
    expect(appleReturnLocation(form({ state: STATE, error: "user_cancelled_authorize" }))).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&error=user_cancelled_authorize`);
    const both = appleReturnLocation(form({ state: STATE, error: "invalid_request", code: "c1", id_token: "a.b.c" }));
    expect(both).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&error=invalid_request`);
  });

  it("state가 없거나 모양이 틀리면 state 없이 invalid_response만 돌려준다 (틀린 state를 되돌려 싣지 않는다)", () => {
    const expected = `${APPLE_APP_CALLBACK}?error=invalid_response`;
    expect(appleReturnLocation(form({ code: "c1", id_token: "a.b.c" }))).toBe(expected);
    expect(appleReturnLocation(form({ state: "short", code: "c1" }))).toBe(expected);
    expect(appleReturnLocation(form({ state: "x".repeat(129), code: "c1" }))).toBe(expected);
    expect(appleReturnLocation(form({ state: `${STATE}&evil=1`, code: "c1" }))).toBe(expected);
    expect(appleReturnLocation(form({ state: "taskforce://evil.example/aaaaaaaa", code: "c1" }))).toBe(expected);
    expect(appleReturnLocation("")).toBe(expected);
  });

  it("code · id_token · error가 하나도 없으면 state와 함께 invalid_response", () => {
    expect(appleReturnLocation(form({ state: STATE }))).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&error=invalid_response`);
    expect(appleReturnLocation(form({ state: STATE, user: "{}" }))).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&error=invalid_response`);
    expect(appleReturnLocation(form({ state: STATE, code: "" }))).toBe(`${APPLE_APP_CALLBACK}?state=${STATE}&error=invalid_response`);
  });

  it("필드 길이 상한: code 2,000 · id_token 8,000 · error 100 (넘으면 invalid_response)", () => {
    const invalid = `${APPLE_APP_CALLBACK}?state=${STATE}&error=invalid_response`;
    expect(appleReturnLocation(form({ state: STATE, code: "c".repeat(2000) }))).toContain("code=");
    expect(appleReturnLocation(form({ state: STATE, code: "c".repeat(2001) }))).toBe(invalid);
    expect(appleReturnLocation(form({ state: STATE, id_token: "t".repeat(8000) }))).toContain("id_token=");
    expect(appleReturnLocation(form({ state: STATE, id_token: "t".repeat(8001) }))).toBe(invalid);
    expect(appleReturnLocation(form({ state: STATE, error: "e".repeat(100) }))).toContain("error=");
    expect(appleReturnLocation(form({ state: STATE, error: "e".repeat(101) }))).toBe(invalid);
  });

  it("같은 이름이 두 번 오면(파라미터 오염) invalid_response", () => {
    const invalid = `${APPLE_APP_CALLBACK}?state=${STATE}&error=invalid_response`;
    expect(appleReturnLocation(`state=${STATE}&code=a&code=b`)).toBe(invalid);
    expect(appleReturnLocation(`state=${STATE}&id_token=a.b.c&id_token=d.e.f`)).toBe(invalid);
    expect(appleReturnLocation(`state=${STATE}&state=${STATE}&code=a`)).toBe(`${APPLE_APP_CALLBACK}?error=invalid_response`);
  });

  it("값은 퍼센트 인코딩해서 싣는다: 앱이 읽으면 원래 값이 나온다", () => {
    const code = "c+1 &=#%?/ü";
    const location = appleReturnLocation(form({ state: STATE, code, id_token: "a.b-c_d" }));
    expect(location.startsWith(`${APPLE_APP_CALLBACK}?`)).toBe(true);
    expect(location).not.toContain(" ");
    expect(query(location).get("code")).toBe(code);
    expect(query(location).get("id_token")).toBe("a.b-c_d");
  });

  it("어떤 입력이어도 목적지는 taskforce://auth/apple 하나다 (error에 주소를 실어도 값일 뿐)", () => {
    const bodies = [
      form({ state: STATE, error: "https://evil.example/steal" }),
      form({ state: STATE, code: "https://evil.example", id_token: "taskforce://auth/other" }),
      form({ state: STATE, error: "x\r\nLocation: https://evil.example" }),
      form({ state: STATE, code: "a\nb", id_token: "c\rd" }),
      "%%%not-form%%%",
      `state=${STATE}&code=%E0%A4%A`,
      "\u0000\u0001",
    ];
    for (const body of bodies) {
      const location = appleReturnLocation(body);
      expect(location.startsWith(`${APPLE_APP_CALLBACK}?`)).toBe(true);
      expect(location).not.toMatch(/[\r\n]/);
      const url = new URL(location);
      expect(`${url.protocol}//${url.host}${url.pathname}`).toBe("taskforce://auth/apple");
    }
  });
});
