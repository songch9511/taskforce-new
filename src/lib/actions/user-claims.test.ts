import { describe, expect, it } from "vitest";

import { editActionRequestSchema } from "@/lib/api/contract";
import type { Claim } from "@/lib/pipeline/resolve";

import { projectAction } from "./project";
import { confirmChanges, editChanges, userClaims } from "./user-claims";

let n = 0;
const claim = (field: Claim["field"], value: string | null, over: Partial<Claim> = {}): Claim => ({
  id: `c${++n}`,
  field,
  value,
  occurredAt: new Date("2025-09-22T10:00:00+09:00"),
  speakerRole: "me",
  certainty: "firm",
  directness: "first_hand",
  audience: "shared",
  channel: "meeting",
  ...over,
});

describe("editChanges", () => {
  it("요청 필드를 Claim 필드로 옮긴다", () => {
    expect(editChanges({ title: "제안서 v2 발송", due_date: null, status: "done" })).toEqual([
      { field: "scope", value: "제안서 v2 발송" },
      { field: "due", value: null },
      { field: "status", value: "done" },
    ]);
  });

  it("빈 수정 요청은 계약에서 막는다", () => {
    expect(editActionRequestSchema.safeParse({}).success).toBe(false);
    expect(editActionRequestSchema.safeParse({ status: "dropped" }).success).toBe(false);
  });
});

describe("confirmChanges → userClaims", () => {
  it("담당 불확실 · 전언 기한을 확인하면 확인 요청이 사라진다", () => {
    const claims = [
      claim("scope", "제안서 발송"),
      claim("owner", "unknown"),
      claim("due", "2025-09-26"),
      claim("due", "2025-09-29", { occurredAt: new Date("2025-09-23T10:00:00+09:00"), directness: "reported", speakerRole: "third_party" }),
    ];
    const before = projectAction("t", claims);
    expect(before.confirm_reasons).toEqual(["담당 확인", "기한 확인"]);

    const changes = confirmChanges(before);
    expect(changes).toEqual([
      { field: "owner", value: "me" },
      { field: "due", value: "2025-09-26" },
    ]);
    const now = new Date("2025-09-24T10:00:00+09:00");
    const after = projectAction("t", [...claims, ...userClaims(changes, now, () => `u${++n}`)]);
    expect(after).toMatchObject({ owner: "me", due_date: "2025-09-26", needs_confirmation: false, confirm_reasons: [] });
  });

  it("담당 확인은 지금 보이는 담당을 그대로 확정한다 (나로 바꾸지 않는다)", () => {
    const claims = [
      claim("scope", "견적서 회신"),
      claim("owner", "other", { speakerRole: "third_party" }),
      claim("owner", "me", { occurredAt: new Date("2025-09-23T10:00:00+09:00"), directness: "reported", speakerRole: "third_party" }),
    ];
    const before = projectAction("t", claims);
    expect(before.resolution.owner.needsConfirmation).toBe(true);
    const changes = confirmChanges(before);
    expect(changes).toContainEqual({ field: "owner", value: before.resolution.owner.value });
    const after = projectAction("t", [...claims, ...userClaims(changes, new Date("2025-09-24T10:00:00+09:00"), () => `u${++n}`)]);
    expect(after.owner).toBe(before.owner);
    expect(after.resolution.owner.needsConfirmation).toBe(false);
  });
});
