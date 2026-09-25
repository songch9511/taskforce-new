import { describe, expect, it } from "vitest";

import type { Profile } from "./contract";
import { handleGetProfile, handlePutProfile, resolveIdentity, type ProfileDeps } from "./profile";

const auth = { name: "doyun", email: "Doyun@Example.com" };

describe("resolveIdentity", () => {
  it("프로필이 없으면 계정 이름과 로그인 이메일", () => {
    expect(resolveIdentity(null, auth)).toEqual({ name: "doyun", aliases: [], emails: ["doyun@example.com"] });
  });

  it("프로필 이름 · 별칭 · 이메일을 쓴다", () => {
    const profile: Profile = { display_name: "도윤", aliases: ["도연", "Doyun"], emails: ["d@work.com"] };
    expect(resolveIdentity(profile, auth)).toEqual({
      name: "도윤",
      aliases: ["도연", "Doyun"],
      emails: ["doyun@example.com", "d@work.com"],
    });
  });

  it("요청에서 이름을 바꾸면 원래 이름은 별칭으로 남는다", () => {
    const profile: Profile = { display_name: "도윤", aliases: ["도연"], emails: [] };
    expect(resolveIdentity(profile, auth, "나").aliases).toEqual(["도윤", "도연"]);
    expect(resolveIdentity(profile, auth, "도윤").aliases).toEqual(["도연"]);
  });
});

type User = { id: string };

function deps(user: User | null, stored: Profile | null = null) {
  const saved: Profile[] = [];
  const d: ProfileDeps<User> = {
    authenticate: async () => user,
    load: async () => stored,
    save: async (_user, profile) => {
      saved.push(profile);
    },
  };
  return { d, saved };
}

const put = (body: unknown) => new Request("http://localhost/api/v1/profile", { method: "PUT", body: JSON.stringify(body) });

describe("profile API", () => {
  it("프로필이 없으면 빈 값을 돌려준다", async () => {
    const response = await handleGetProfile(new Request("http://localhost/api/v1/profile"), deps({ id: "u" }).d);
    expect(await response.json()).toEqual({ display_name: null, aliases: [], emails: [] });
  });

  it("저장할 때 중복과 대소문자를 정리한다", async () => {
    const { d, saved } = deps({ id: "u" });
    const response = await handlePutProfile(put({ display_name: "도윤", aliases: ["도연", " 도연 "], emails: ["A@x.com", "a@x.com"] }), d);
    expect(response.status).toBe(200);
    expect(saved).toEqual([{ display_name: "도윤", aliases: ["도연"], emails: ["a@x.com"] }]);
  });

  it("잘못된 값은 400, 로그인하지 않았으면 401", async () => {
    expect((await handlePutProfile(put({ display_name: "도윤", aliases: [], emails: ["nope"] }), deps({ id: "u" }).d)).status).toBe(400);
    expect((await handlePutProfile(put({ display_name: null, aliases: [], emails: [] }), deps(null).d)).status).toBe(401);
    expect((await handleGetProfile(new Request("http://localhost/api/v1/profile"), deps(null).d)).status).toBe(401);
  });
});
