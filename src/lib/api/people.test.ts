import { describe, expect, it } from "vitest";

import { parseList, parsePeople } from "./people";

describe("parsePeople", () => {
  it("이름 <이메일>, 이메일, 이름을 모두 받는다", () => {
    expect(parsePeople(`김대표 <ceo@x.com>, me@x.com; 태오\n"Kim J" <j@x.com>`)).toEqual([
      { name: "김대표", email: "ceo@x.com" },
      { email: "me@x.com" },
      { name: "태오" },
      { name: "Kim J", email: "j@x.com" },
    ]);
  });

  it("<이메일>만 있으면 이메일만", () => {
    expect(parsePeople("<a@x.com>")).toEqual([{ email: "a@x.com" }]);
  });

  it("빈 입력은 빈 목록", () => {
    expect(parsePeople("  ,  ")).toEqual([]);
  });
});

describe("parseList", () => {
  it("쉼표로 나누고 빈 값은 버린다", () => {
    expect(parseList("도연, Doyun,, ")).toEqual(["도연", "Doyun"]);
  });
});
