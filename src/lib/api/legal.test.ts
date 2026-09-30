import { afterEach, describe, expect, it, vi } from "vitest";

import { legalResponseSchema } from "./contract";
import { handleGetLegal, type LegalDeps } from "./legal";

type User = { id: string };

const url = { ko: "https://www.taskforcelabs.dev/ko/privacy", en: "https://www.taskforcelabs.dev/en/privacy" };
const policy = { current: { version: "beta-1.1", effective_date: "2026-09-30", url }, upcoming: null };
const now = () => new Date("2026-10-01T03:00:00Z");
const get = () => new Request("http://localhost/api/v1/legal");

function deps(user: User | null, createdAt: () => Promise<Date>): LegalDeps<User> {
  return { authenticate: async () => user, accountCreatedAt: createdAt, policy, now };
}

describe("GET /api/v1/legal", () => {
  afterEach(() => vi.restoreAllMocks());

  it("로그인하지 않았으면 401", async () => {
    const response = await handleGetLegal(get(), deps(null, async () => new Date()));
    expect(response.status).toBe(401);
  });

  it("시행일 전에 가입한 계정에는 updated 안내를 계약 형식으로 돌려준다", async () => {
    const response = await handleGetLegal(get(), deps({ id: "u" }, async () => new Date("2026-09-20T00:00:00Z")));
    expect(response.status).toBe(200);
    const body = legalResponseSchema.parse(await response.json());
    expect(body.privacy.notice).toEqual({ ...policy.current, kind: "updated" });
    expect(body.privacy.current).toEqual(policy.current);
    expect(body.privacy.upcoming).toBeNull();
  });

  it("시행일 뒤에 가입한 계정에는 안내가 없다", async () => {
    const response = await handleGetLegal(get(), deps({ id: "u" }, async () => new Date("2026-09-30T02:00:00Z")));
    expect(legalResponseSchema.parse(await response.json()).privacy.notice).toBeNull();
  });

  it("가입 시각을 읽지 못하면 500", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const failed = await handleGetLegal(get(), deps({ id: "u" }, async () => Promise.reject(new Error("auth down"))));
    expect(failed.status).toBe(500);
    expect((await failed.json()).error.code).toBe("internal_error");
    const invalid = await handleGetLegal(get(), deps({ id: "u" }, async () => new Date("not a date")));
    expect(invalid.status).toBe(500);
    expect(log).toHaveBeenCalledTimes(2);
  });
});
