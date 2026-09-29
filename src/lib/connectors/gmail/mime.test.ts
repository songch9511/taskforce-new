import { describe, expect, it } from "vitest";

import { decodeCharset, decodeEncodedWords, emailDomain, firstEmail, headerParam, parseAddressList } from "./mime";

// 메일 글자 풀기 (docs/go-live/google-integration.md 2-6 본문 받기 · 관련자): 문자 집합 · RFC 2047 · 주소 목록.

const bytes = (...values: number[]) => Uint8Array.from(values);
/** "안녕"의 EUC-KR 바이트 */
const EUC_KR_HELLO = [0xbe, 0xc8, 0xb3, 0xe7];

describe("decodeCharset", () => {
  it("UTF-8 (이름이 없거나 대소문자 · 공백이 섞여도)", () => {
    const utf8 = new TextEncoder().encode("안녕 hello");
    expect(decodeCharset(utf8, "UTF-8")).toBe("안녕 hello");
    expect(decodeCharset(utf8, " utf8 ")).toBe("안녕 hello");
    expect(decodeCharset(utf8, null)).toBe("안녕 hello");
    expect(decodeCharset(utf8, undefined)).toBe("안녕 hello");
  });

  it("EUC-KR · ks_c_5601-1987 · cp949 별칭", () => {
    expect(decodeCharset(bytes(...EUC_KR_HELLO), "euc-kr")).toBe("안녕");
    expect(decodeCharset(bytes(...EUC_KR_HELLO), "ks_c_5601-1987")).toBe("안녕");
    expect(decodeCharset(bytes(...EUC_KR_HELLO), "CP949")).toBe("안녕");
    expect(decodeCharset(bytes(...EUC_KR_HELLO), "x-windows-949")).toBe("안녕");
  });

  it("ISO-2022-KR은 EUC-KR로 바꿔 푼다 (지정 순서는 버리고 SO~SI 사이만 한글)", () => {
    // ESC $ ) C, "Hi ", SO, 안녕, SI, "!"
    const iso = bytes(0x1b, 0x24, 0x29, 0x43, 0x48, 0x69, 0x20, 0x0e, 0x3e, 0x48, 0x33, 0x67, 0x0f, 0x21);
    expect(decodeCharset(iso, "ISO-2022-KR")).toBe("Hi 안녕!");
  });

  it("ISO-2022-KR에서 줄이 바뀌면 SI 없이도 한글 모드가 끝난다", () => {
    const iso = bytes(0x1b, 0x24, 0x29, 0x43, 0x0e, 0x3e, 0x48, 0x0a, 0x41);
    expect(decodeCharset(iso, "iso-2022-kr")).toBe("안\nA");
  });

  it("모르는 문자 집합이면 UTF-8로", () => {
    expect(decodeCharset(new TextEncoder().encode("café"), "x-unknown-charset")).toBe("café");
  });
});

describe("headerParam", () => {
  it("따옴표가 있든 없든, 이름의 대소문자와 상관없이 값을 읽는다", () => {
    expect(headerParam('text/plain; charset="EUC-KR"', "charset")).toBe("EUC-KR");
    expect(headerParam("text/plain; CHARSET=utf-8; format=flowed", "charset")).toBe("utf-8");
    expect(headerParam("text/plain;format=flowed;charset=iso-2022-kr", "charset")).toBe("iso-2022-kr");
  });

  it("없으면 null", () => {
    expect(headerParam("text/plain", "charset")).toBeNull();
    expect(headerParam(undefined, "charset")).toBeNull();
  });
});

describe("decodeEncodedWords", () => {
  it("B 인코딩 (UTF-8)", () => {
    expect(decodeEncodedWords("=?UTF-8?B?7JWI64WV?=")).toBe("안녕");
  });

  it("Q 인코딩 (밑줄은 공백, =XX는 바이트)", () => {
    expect(decodeEncodedWords("=?utf-8?Q?caf=C3=A9_ok?=")).toBe("café ok");
    expect(decodeEncodedWords("=?EUC-KR?Q?=BE=C8=B3=E7?=")).toBe("안녕");
  });

  it("이어진 두 인코딩 낱말 사이의 공백은 버리고, 일반 글과의 공백은 둔다", () => {
    expect(decodeEncodedWords("=?UTF-8?B?7JWI?= =?UTF-8?B?64WV?=")).toBe("안녕");
    expect(decodeEncodedWords("=?UTF-8?B?7JWI?=\r\n =?UTF-8?Q?=EB=85=95?=")).toBe("안녕");
    expect(decodeEncodedWords("RE: =?UTF-8?B?7JWI64WV?= there")).toBe("RE: 안녕 there");
  });

  it("인코딩 낱말이 없으면 그대로", () => {
    expect(decodeEncodedWords("Signed contract")).toBe("Signed contract");
  });
});

describe("parseAddressList", () => {
  it("이름 <주소>, 주소만: 주소는 소문자로", () => {
    expect(parseAddressList("Jordan Lee <Jordan@Example.com>, alex@EXAMPLE.com")).toEqual([
      { name: "Jordan Lee", email: "jordan@example.com" },
      { email: "alex@example.com" },
    ]);
  });

  it("따옴표 안의 쉼표 · 이스케이프는 가르지 않는다", () => {
    expect(parseAddressList('"Lee, Jordan" <jordan@example.com>, "Kim \\"K\\" Min" <min@example.com>')).toEqual([
      { name: "Lee, Jordan", email: "jordan@example.com" },
      { name: 'Kim "K" Min', email: "min@example.com" },
    ]);
  });

  it("주소 (이름) 표기", () => {
    expect(parseAddressList("jordan@example.com (Jordan Lee)")).toEqual([{ name: "Jordan Lee", email: "jordan@example.com" }]);
  });

  it("그룹 표기는 그룹 이름을 버리고 주소만 남긴다", () => {
    expect(parseAddressList("Team: a@x.com, b@y.com;")).toEqual([{ email: "a@x.com" }, { email: "b@y.com" }]);
    expect(parseAddressList("undisclosed-recipients:;")).toEqual([]);
    expect(parseAddressList("Team: a@x.com;, Jordan <jordan@example.com>")).toEqual([{ email: "a@x.com" }, { name: "Jordan", email: "jordan@example.com" }]);
  });

  it("주소 형식이 아니면 이름만 남기고, 이름도 없으면 뺀다", () => {
    expect(parseAddressList("Jordan Lee <not-an-email>")).toEqual([{ name: "Jordan Lee" }]);
    expect(parseAddressList("<not-an-email>, just-text")).toEqual([]);
  });

  it("이름이 주소와 같으면 이름을 뺀다", () => {
    expect(parseAddressList('"jordan@example.com" <Jordan@example.com>')).toEqual([{ email: "jordan@example.com" }]);
  });

  it("인코딩된 이름을 푼다", () => {
    expect(parseAddressList("=?UTF-8?B?7JWI64WV?= <hi@example.com>")).toEqual([{ name: "안녕", email: "hi@example.com" }]);
  });

  it("비었거나 없으면 빈 목록", () => {
    expect(parseAddressList(undefined)).toEqual([]);
    expect(parseAddressList("")).toEqual([]);
  });
});

describe("firstEmail · emailDomain", () => {
  it("첫 주소(소문자). 주소가 없으면 null", () => {
    expect(firstEmail("Broken <nope>, Jordan <Jordan@Example.com>")).toBe("jordan@example.com");
    expect(firstEmail("Broken <nope>")).toBeNull();
    expect(firstEmail(undefined)).toBeNull();
  });

  it("도메인은 마지막 @ 뒤 (소문자)", () => {
    expect(emailDomain("me@Mail.Company.DEV")).toBe("mail.company.dev");
  });
});
