import { describe, expect, it } from "vitest";

import { isApiPath, isPublicPath } from "./proxy";

describe("isPublicPath", () => {
  it.each(["/login", "/auth/confirm", "/auth/signout"])("%s는 로그인 없이 열린다", (path) => {
    expect(isPublicPath(path)).toBe(true);
  });

  it.each(["/", "/actions/1", "/loginx", "/authx"])("%s는 로그인이 필요하다", (path) => {
    expect(isPublicPath(path)).toBe(false);
  });
});

describe("isApiPath", () => {
  it.each(["/api/v1/sources", "/api"])("%s는 Route Handler가 직접 인증한다", (path) => {
    expect(isApiPath(path)).toBe(true);
  });

  it.each(["/", "/apix", "/lab"])("%s는 API가 아니다", (path) => {
    expect(isApiPath(path)).toBe(false);
  });
});
