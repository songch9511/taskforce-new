import { describe, expect, it } from "vitest";

import { cleanPerson, MAX_ATTENDEES, mergeAttendees } from "./attendees";

// 회의 원문의 관련자 합치기 (google-integration.md 2-4 5 · 2-5 관련자).

describe("cleanPerson", () => {
  it("이메일은 소문자로, 이름은 공백을 다듬는다. 둘 다 비면 null", () => {
    expect(cleanPerson({ name: "  Jordan   Lee ", email: " Jordan@Harborline.EXAMPLE " })).toEqual({ name: "Jordan Lee", email: "jordan@harborline.example" });
    expect(cleanPerson({ email: "a@b.dev" })).toEqual({ email: "a@b.dev" });
    expect(cleanPerson({ name: " ", email: null })).toBeNull();
  });
});

describe("mergeAttendees", () => {
  it("이메일이 같으면 같은 사람이고 빠진 이름만 채운다", () => {
    expect(mergeAttendees([{ name: "Alex Kim", email: "alex@lumenfield.example" }], [{ email: "ALEX@lumenfield.example", name: "Alex" }, { email: "jordan@harborline.example" }])).toEqual([
      { name: "Alex Kim", email: "alex@lumenfield.example" },
      { email: "jordan@harborline.example" },
    ]);
    expect(mergeAttendees([{ email: "jordan@harborline.example" }], [{ name: "Jordan Lee", email: "jordan@harborline.example" }])).toEqual([{ email: "jordan@harborline.example", name: "Jordan Lee" }]);
  });

  it("한쪽에 이메일이 없으면 이름이 같을 때(공백 · 대소문자 무시) 같은 사람이고 이메일을 채운다", () => {
    expect(mergeAttendees([{ name: "송창훈" }, { name: "Jordan Lee" }], [{ name: "송 창훈", email: "daniel@taskforcelabs.dev" }, { name: "jordan lee" }])).toEqual([
      { name: "송창훈", email: "daniel@taskforcelabs.dev" },
      { name: "Jordan Lee" },
    ]);
  });

  it("이메일이 서로 다르면 이름이 같아도 다른 사람이다 (같은 표시 이름의 두 계정)", () => {
    expect(mergeAttendees([{ name: "Daniel Song", email: "a@x.dev" }], [{ name: "Daniel Song", email: "b@y.dev" }])).toHaveLength(2);
  });

  it("base가 먼저다. 200명을 넘는 새 사람은 버리고, 이미 있는 사람의 빠진 칸은 채운다", () => {
    const base = Array.from({ length: MAX_ATTENDEES }, (_, i) => ({ email: `p${i}@x.dev` }));
    const merged = mergeAttendees(base, [{ email: "extra@x.dev" }, { email: "p0@x.dev", name: "First" }]);
    expect(merged).toHaveLength(MAX_ATTENDEES);
    expect(merged.some((p) => p.email === "extra@x.dev")).toBe(false);
    expect(merged[0]).toEqual({ email: "p0@x.dev", name: "First" });
  });

  it("빈 사람은 건너뛴다", () => {
    expect(mergeAttendees([], [{}, { name: "  " }, { name: "A" }])).toEqual([{ name: "A" }]);
  });
});
