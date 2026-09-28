import { describe, expect, it } from "vitest";

import { editActionRequestSchema } from "@/lib/api/contract";
import type { Claim } from "@/lib/pipeline/resolve";

import { projectAction } from "./project";
import { confirmChanges, editChanges, userClaims, userCreatedAction } from "./user-claims";

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

describe("userCreatedAction (직접 추가)", () => {
  const now = new Date("2026-09-28T10:00:00+09:00");

  it("제목 · 기한 · 담당(나) · 상태(열림)를 사용자 Claim으로 적고, 확인 요청 없이 판정한다", () => {
    const { claims, projected } = userCreatedAction({ title: "견적서 보내기", dueDate: "2026-10-02", sourceId: null }, now, () => `u${++n}`);
    expect(claims.map(({ field, value, origin, occurredAt }) => ({ field, value, origin, occurredAt }))).toEqual([
      { field: "scope", value: "견적서 보내기", origin: "user", occurredAt: now },
      { field: "owner", value: "me", origin: "user", occurredAt: now },
      { field: "status", value: "open", origin: "user", occurredAt: now },
      { field: "due", value: "2026-10-02", origin: "user", occurredAt: now },
    ]);
    expect(projected).toMatchObject({
      title: "견적서 보내기",
      owner: "me",
      status: "open",
      due_date: "2026-10-02",
      due_at: "2026-10-02T23:59:59+09:00",
      needs_confirmation: false,
      confirm_reasons: [],
    });
    expect(projected.resolution.scope.reason).toBe("사용자가 직접 정함");
  });

  it("기한이 없으면 기한 Claim을 적지 않는다", () => {
    const { claims, projected } = userCreatedAction({ title: "견적서 보내기", dueDate: null, sourceId: null }, now, () => `u${++n}`);
    expect(claims.map((c) => c.field)).toEqual(["scope", "owner", "status"]);
    expect(projected).toMatchObject({ due_date: null, needs_confirmation: false });
  });

  it("created 대신 user_created 하나를 남긴다 (관련 원문 포함)", () => {
    const withSource = userCreatedAction({ title: "견적서 보내기", dueDate: null, sourceId: "s1" }, now, () => `u${++n}`);
    expect(withSource.event).toEqual({
      type: "user_created",
      before: null,
      after: { title: "견적서 보내기", due: null, owner: "me", status: "open", needs_confirmation: false, source_id: "s1" },
      rule: "user",
    });
    expect(userCreatedAction({ title: "견적서 보내기", dueDate: null, sourceId: null }, now, () => `u${++n}`).event.after).toMatchObject({ source_id: null });
  });
});
