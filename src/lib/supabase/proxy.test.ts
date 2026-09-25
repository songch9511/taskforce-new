import { describe, expect, it } from "vitest";

import { isPublicPath } from "./proxy";

describe("isPublicPath", () => {
  it.each(["/login", "/auth/confirm", "/auth/signout"])("%s는 로그인 없이 열린다", (path) => {
    expect(isPublicPath(path)).toBe(true);
  });

  it.each(["/", "/actions/1", "/loginx", "/authx"])("%s는 로그인이 필요하다", (path) => {
    expect(isPublicPath(path)).toBe(false);
  });
});
