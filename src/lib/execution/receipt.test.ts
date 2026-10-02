import { describe, expect, it, vi } from "vitest";

import type { Claim } from "@/lib/pipeline/resolve";

import {
  artifactLink,
  assertReceiptKeepsAction,
  buildDraftReceipt,
  receiptTitle,
  ReceiptWriteError,
  writeDraftReceipt,
  writeMissingReceipts,
  type ReceiptAction,
  type ReceiptStore,
  type ReceiptTarget,
  type ReceiptWriteResult,
} from "./receipt";

// 실행 receipt → Claim/Evidence (docs/EXECUTION.md 9장). DB 쪽(write_execution_receipt · 제약 · 권한)은 tests/db/execution-receipts.test.ts

const ARTIFACT_ID = "7c2e5f0a-1b3d-4e6f-8a9b-0c1d2e3f4a5b";
const target: ReceiptTarget = {
  stepId: "step-1",
  runId: "run-1",
  userId: "user-1",
  actionId: "action-1",
  artifact: { id: ARTIFACT_ID, title: "제안서 초안", createdAt: new Date("2026-10-02T05:00:00Z") },
};

const sourceClaim = (field: Claim["field"], value: string, over: Partial<Claim> = {}): Claim => ({
  id: `${field}-${value}`,
  field,
  value,
  occurredAt: new Date("2026-10-01T01:00:00Z"),
  speakerRole: "me",
  certainty: "firm",
  directness: "first_hand",
  audience: "shared",
  channel: "meeting",
  origin: "source",
  ...over,
});
const openAction = (over: Partial<ReceiptAction> = {}): ReceiptAction => ({
  version: 3,
  title: "제안서 보내기",
  confirmReasons: [],
  claims: [sourceClaim("scope", "제안서 보내기"), sourceClaim("due", "2026-10-09"), sourceClaim("owner", "me"), sourceClaim("status", "open")],
  ...over,
});

describe("buildDraftReceipt", () => {
  it("receipt 글 = 인용 = \"초안 저장: <제목>\", 링크는 앱 안의 산출물, Claim은 origin execution · field artifact · 값 = 산출물 id (A55: user가 아니다)", () => {
    const { receipt, claim } = buildDraftReceipt(target, "claim-1");
    expect(receipt).toEqual({
      source: { title: "제안서 초안", raw_text: "초안 저장: 제안서 초안", external_url: `taskforce://artifacts/${ARTIFACT_ID}` },
      claim: { id: "claim-1", quote: "초안 저장: 제안서 초안", speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "private" },
    });
    expect(claim).toMatchObject({ id: "claim-1", field: "artifact", value: ARTIFACT_ID, origin: "execution", occurredAt: target.artifact.createdAt, state: "active" });
    expect(claim.origin).not.toBe("user");
    expect(receipt.source.raw_text).toContain(receipt.claim.quote);
    expect(artifactLink(ARTIFACT_ID)).toBe(receipt.source.external_url);
  });

  it("제목은 한 줄로, 길면 자르고, 비면 앞머리만 남긴다 (receipt 글에는 제목만 담는다)", () => {
    expect(receiptTitle("  제안서\n\t초안   (v2) ")).toBe("제안서 초안 (v2)");
    const long = receiptTitle("가".repeat(500))!;
    expect(long).toHaveLength(200);
    expect(long.endsWith("…")).toBe(true);
    expect(receiptTitle(" \n ")).toBeNull();
    // 글자 단위로 자른다: 이모지를 반으로 자르면 jsonb가 받지 않는 글이 된다
    const emoji = receiptTitle("📝".repeat(300))!;
    expect(Array.from(emoji)).toHaveLength(200);
    expect(emoji.isWellFormed()).toBe(true);
    const blank = buildDraftReceipt({ ...target, artifact: { ...target.artifact, title: "\n" } }, "c");
    expect(blank.receipt.source).toMatchObject({ title: null, raw_text: "초안 저장" });
    expect(blank.receipt.claim.quote).toBe("초안 저장");
  });
});

describe("assertReceiptKeepsAction: Claim을 더해 다시 판정해도 Action 값이 같은가", () => {
  it("artifact Claim은 필드를 바꾸지 않는다 (초안 ≠ 완료, A38)", () => {
    expect(() => assertReceiptKeepsAction(openAction(), buildDraftReceipt(target, "claim-1").claim)).not.toThrow();
  });

  it("사용자가 끝낸 할 일 · 저장된 확인 이유가 있는 할 일도 그대로 (A57)", () => {
    const done = openAction({
      claims: [...openAction().claims, sourceClaim("status", "done", { origin: "user", channel: "note", occurredAt: new Date("2026-10-02T01:00:00Z") })],
      confirmReasons: ["병합 확인 (55%)"],
    });
    expect(() => assertReceiptKeepsAction(done, buildDraftReceipt(target, "claim-1").claim)).not.toThrow();
  });

  it("더한 Claim이 필드를 바꾸면 쓰지 않는다 (changes_action): 실행 결과로 Action을 끝내는 길은 없다", () => {
    const completing = { ...buildDraftReceipt(target, "claim-1").claim, field: "status" as const, value: "done" };
    expect(() => assertReceiptKeepsAction(openAction(), completing)).toThrow(ReceiptWriteError);
    expect(() => assertReceiptKeepsAction(openAction(), completing)).toThrow(expect.objectContaining({ code: "changes_action" }));
  });
});

/** 가짜 store: 결과를 차례로 돌려주고 받은 인자를 기록한다 */
function fakeStore(over: { target?: ReceiptTarget | null; action?: ReceiptAction | null; results?: ReceiptWriteResult[]; missing?: string[] } = {}) {
  const results = [...(over.results ?? ["written"])];
  const writes: { stepId: string; expectedVersion: number }[] = [];
  let version = (over.action ?? openAction()).version;
  const store: ReceiptStore = {
    receiptTarget: vi.fn(async () => (over.target === undefined ? target : over.target)),
    // 읽을 때마다 지금 버전을 돌려준다 (conflict 뒤에는 다른 쓰기가 버전을 올렸다)
    loadAction: vi.fn(async () => (over.action === null ? null : { ...(over.action ?? openAction()), version })),
    writeReceipt: vi.fn(async (stepId, expectedVersion) => {
      writes.push({ stepId, expectedVersion });
      const result = results.shift() ?? "written";
      if (result === "conflict") version++;
      return result;
    }),
    missingReceipts: vi.fn(async () => over.missing ?? []),
  };
  return { store, writes };
}

describe("writeDraftReceipt", () => {
  it("읽은 버전으로 receipt를 쓴다", async () => {
    const { store, writes } = fakeStore();
    expect(await writeDraftReceipt(store, "step-1", () => "claim-1")).toBe("written");
    expect(writes).toEqual([{ stepId: "step-1", expectedVersion: 3 }]);
    expect(store.writeReceipt).toHaveBeenCalledWith("step-1", 3, buildDraftReceipt(target, "claim-1").receipt);
  });

  it("버전이 어긋나면 다시 읽고 다시 써서 붙이고, 이미 붙었으면 exists", async () => {
    const retried = fakeStore({ results: ["conflict", "written"] });
    expect(await writeDraftReceipt(retried.store, "step-1")).toBe("written");
    expect(retried.writes.map((w) => w.expectedVersion)).toEqual([3, 4]);
    // 같은 Claim id로 다시 쓴다 (receipt는 한 번 만든다)
    expect(new Set(vi.mocked(retried.store.writeReceipt).mock.calls.map((call) => call[2].claim.id)).size).toBe(1);

    expect(await writeDraftReceipt(fakeStore({ results: ["exists"] }).store, "step-1")).toBe("exists");
  });

  it("세 번 모두 어긋나면 conflict 오류, 끝낸 초안 단계 · Action이 없으면 not_found (아무것도 쓰지 않는다)", async () => {
    const busy = fakeStore({ results: ["conflict", "conflict", "conflict"] });
    await expect(writeDraftReceipt(busy.store, "step-1")).rejects.toMatchObject({ code: "conflict" });
    expect(busy.writes).toHaveLength(3);

    for (const missing of [fakeStore({ target: null }), fakeStore({ action: null })]) {
      await expect(writeDraftReceipt(missing.store, "step-1")).rejects.toMatchObject({ name: "ReceiptWriteError", code: "not_found" });
      expect(missing.writes).toHaveLength(0);
    }
  });
});

describe("writeMissingReceipts (sweep 보조 안전망)", () => {
  it("receipt가 없는 단계마다 붙이고, 하나가 실패해도 다음을 한다. 로그에는 단계 id와 오류 코드만 남긴다", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const { store } = fakeStore({ missing: ["a", "b", "c"] });
      vi.mocked(store.receiptTarget).mockImplementation(async (stepId) => (stepId === "b" ? null : { ...target, stepId }));
      vi.mocked(store.writeReceipt).mockResolvedValueOnce("written").mockResolvedValueOnce("exists");
      expect(await writeMissingReceipts(store, 5)).toEqual({ written: 1, failed: 1 });
      expect(store.missingReceipts).toHaveBeenCalledWith(5);
      expect(error.mock.calls.map((call) => JSON.parse(String(call[0])))).toEqual([{ event: "execution_receipt_failed", step: "b", reason: "not_found" }]);
    } finally {
      error.mockRestore();
    }
  });
});
