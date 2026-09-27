import { describe, expect, it } from "vitest";

import { renderSnapshot, sameForClaims, snapshotChanges, taskClaims, type TaskSnapshot } from "./structured";

const snap = (over: Partial<TaskSnapshot> = {}): TaskSnapshot => ({
  title: "UI 레이아웃 이미지 보내기",
  assignees: ["청혁"],
  owner: "me",
  due: "2026-09-30",
  status: "open",
  statusLabel: "Not started",
  ...over,
});

describe("renderSnapshot", () => {
  it("속성을 정해진 줄로 적는다 (근거 인용은 이 줄들)", () => {
    expect(renderSnapshot(snap())).toBe("# UI 레이아웃 이미지 보내기\n담당: 청혁\n기한: 2026-09-30\n상태: Not started");
    expect(renderSnapshot(snap({ assignees: [], due: null, statusLabel: null }))).toBe("# UI 레이아웃 이미지 보내기\n담당: 없음\n기한: 없음\n상태: open");
  });
});

describe("snapshotChanges", () => {
  it("처음 보는 할 일은 값이 있는 필드 전부", () => {
    expect(snapshotChanges(null, snap({ due: null })).map((c) => c.field)).toEqual(["scope", "owner", "status"]);
  });

  it("바뀐 필드만, 그 필드의 줄을 인용으로", () => {
    const changes = snapshotChanges(snap(), snap({ due: "2026-10-02", status: "done", statusLabel: "Done" }));
    expect(changes).toEqual([
      { field: "due", value: "2026-10-02", quote: "기한: 2026-10-02" },
      { field: "status", value: "done", quote: "상태: Done" },
    ]);
  });

  it("상태 이름만 바뀌거나(둘 다 open) 담당자 이름만 바뀐 것은 변화가 아니다", () => {
    const next = snap({ statusLabel: "Current", assignees: ["청혁", "Chan"] });
    expect(snapshotChanges(snap(), next)).toEqual([]);
    expect(sameForClaims(snap(), next)).toBe(true);
  });

  it("기한을 지우면 null Claim", () => {
    expect(snapshotChanges(snap(), snap({ due: null }))).toEqual([{ field: "due", value: null, quote: "기한: 없음" }]);
  });
});

describe("taskClaims", () => {
  const at = new Date("2026-09-26T05:00:00Z");
  let n = 0;
  const newId = () => `c${++n}`;
  const [change] = snapshotChanges(snap(), snap({ due: "2026-10-02" }));

  it("사용자가 고쳤으면 tracker (사용자가 할 일 도구에서 정한 값)", () => {
    expect(taskClaims([change], { editedByUser: true, occurredAt: at }, newId)[0]).toMatchObject({
      field: "due",
      value: "2026-10-02",
      origin: "tracker",
      speakerRole: "me",
      channel: "task",
      certainty: "firm",
      directness: "first_hand",
      audience: "shared",
      occurredAt: at,
    });
  });

  it("다른 사람이 고쳤으면 팀 기록을 관리하는 쪽(counterpart)의 결정", () => {
    expect(taskClaims([change], { editedByUser: false, occurredAt: at }, newId)[0]).toMatchObject({ origin: "source", speakerRole: "counterpart" });
  });
});
