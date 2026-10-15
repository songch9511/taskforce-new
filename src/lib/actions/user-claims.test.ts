import { describe, expect, it } from "vitest";

import { editActionRequestSchema } from "@/lib/api/contract";
import type { Claim } from "@/lib/pipeline/resolve";

import { projectAction } from "./project";
import { confirmChanges, editChanges, userChangePlan, userClaims, userCreatedAction } from "./user-claims";

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

// 사용자가 값을 바꾸는 쓰기 계획 (D4c-2): 삭제 · 병합 확인이 삭제 경로와 같은 쓰기를 만들도록 순수 함수로 뺐다. service.ts userChangeWrite가 이것을 부른다.
describe("userChangePlan", () => {
  const NOW = new Date("2026-10-15T01:00:00.000Z");
  const row = (over: Partial<{ title: string; confirm_reasons: string[]; needs_confirmation: boolean; version: number; status: "open" | "done" | "dropped"; started_at: string | null }> = {}) => ({
    title: "견적서 보내기",
    confirm_reasons: [],
    needs_confirmation: false,
    version: 3,
    status: "open" as const,
    started_at: null,
    ...over,
  });
  const base = [claim("scope", "견적서 보내기"), claim("owner", "me"), claim("status", "open")];
  const ids = () => {
    let i = 0;
    return () => `00000000-0000-4000-8000-${String(++i).padStart(12, "0")}`;
  };
  const drop = [{ field: "status" as const, value: "dropped" }];

  it("삭제: 읽은 version이 조건이고, 사용자 Claim 하나(status dropped, 지금 시각)와 user_deleted 이벤트 하나, 확인 이유는 비운다", () => {
    const plan = userChangePlan(row({ confirm_reasons: ["담당 확인"], needs_confirmation: true }), base, () => drop, "user_deleted", { clearReasons: true }, NOW, ids());
    expect(plan.expectedVersion).toBe(3);
    expect(plan.actor).toBe("user");
    expect(plan.evidence).toEqual({ sourceId: null, quote: null });
    expect(plan.action).toMatchObject({ title: "견적서 보내기", status: "dropped", needs_confirmation: false, confirm_reasons: [] });
    expect(plan.claims).toEqual([expect.objectContaining({ id: "00000000-0000-4000-8000-000000000001", field: "status", value: "dropped", origin: "user", occurredAt: NOW })]);
    expect(plan.events).toEqual([{ type: "user_deleted", before: { status: "open" }, after: { status: "dropped" }, rule: "user" }]);
  });

  it("다시 읽어도 같다: 같은 입력이면 같은 쓰기 (Claim id만 newId가 정한다)", () => {
    const run = () => userChangePlan(row(), base, () => drop, "user_deleted", { clearReasons: true }, NOW, ids());
    expect(run()).toEqual(run());
  });

  it("changes는 계산한 현재 판정을 받는다 (확인 한 번: 바뀐 게 없어도 user_confirmed 한 번)", () => {
    const plan = userChangePlan(row(), base, (current) => confirmChanges(current), "user_confirmed", { clearReasons: true }, NOW, ids());
    expect(plan.events).toEqual([expect.objectContaining({ type: "user_confirmed", rule: "user" })]);
    expect(plan.events).toHaveLength(1);
  });

  it("병합(into): 사라지는 쪽의 이벤트는 user_merged이고 after에 남는 쪽 id가 붙는다. 값은 삭제와 같다", () => {
    const INTO = "11111111-0000-4000-8000-000000000001";
    const merged = userChangePlan(row(), base, () => drop, "user_merged", { clearReasons: true, into: INTO }, NOW, ids());
    const deleted = userChangePlan(row(), base, () => drop, "user_deleted", { clearReasons: true }, NOW, ids());
    expect(merged.events).toEqual([{ type: "user_merged", before: { status: "open" }, after: { status: "dropped", into: INTO }, rule: "user" }]);
    expect({ ...merged, events: [] }).toEqual({ ...deleted, events: [] });
  });

  it("병합 Undo(undoneInto): 다시 여는 이벤트의 before에 into를 싣는다 (user_edited). 다른 이벤트는 그대로", () => {
    const INTO = "11111111-0000-4000-8000-000000000001";
    const dropped = [claim("scope", "견적서 보내기"), claim("owner", "me"), claim("status", "dropped", { origin: "user" })];
    const plan = userChangePlan(row({ status: "dropped" }), dropped, () => [{ field: "status", value: "open" }, { field: "scope", value: "견적서 v2 보내기" }], "user_edited", { undoneInto: INTO }, NOW, ids());
    const reopened = plan.events.find((e) => (e.after as { status?: string } | null)?.status === "open")!;
    expect(reopened).toMatchObject({ type: "user_edited", before: { status: "dropped", into: INTO } });
    const title = plan.events.find((e) => (e.after as { title?: string } | null)?.title)!;
    expect(title.before).toEqual({ title: "견적서 보내기" });
    // undoneInto가 없으면 into를 싣지 않는다 (v1 응답 · 이벤트 모양 그대로)
    const plain = userChangePlan(row({ status: "dropped" }), dropped, () => [{ field: "status", value: "open" }], "user_edited", {}, NOW, ids());
    expect(plain.events[0].before).toEqual({ status: "dropped" });
  });
});
