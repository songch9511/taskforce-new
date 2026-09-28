import { describe, expect, it } from "vitest";

import type { TaskSnapshot } from "@/lib/pipeline/structured";

import { ingestTaskItems, type PendingTask, type TaskIngestDeps, type TaskItem, type TaskState } from "./tasks-ingest";
import type { Connection } from "./types";

const now = new Date("2026-09-26T12:00:00.000Z");
const minutesAgo = (m: number) => new Date(now.getTime() - m * 60_000);
const connection: Connection = { id: "c1", userId: "u1", provider: "notion", settings: {}, syncCursor: null };
const options = { now, settleMinutes: 5, maxItems: 10 };

const snap = (over: Partial<TaskSnapshot> = {}): TaskSnapshot => ({
  title: "UI 레이아웃 이미지 보내기",
  assignees: ["청혁"],
  owner: "me",
  due: null,
  status: "open",
  statusLabel: "Not started",
  ...over,
});

const item = (id: string, editedMinutesAgo: number, snapshot = snap()): TaskItem => ({
  externalId: id,
  externalVersion: minutesAgo(editedMinutesAgo).toISOString(),
  snapshot,
  editedByUser: false,
  lastEditedAt: minutesAgo(editedMinutesAgo),
  externalUrl: null,
});

function fakeDeps(states: Record<string, TaskState> = {}, pending: PendingTask[] = []) {
  const processed: { id: string; sourceId: string; prev: TaskSnapshot | null }[] = [];
  const deps: TaskIngestDeps = {
    taskStates: async (_c, ids) => new Map(ids.filter((id) => states[id]).map((id) => [id, states[id]])),
    insertTaskSource: async (_c, i) => `src-${i.externalId}`,
    processTask: async (_c, sourceId, i, prev) => void processed.push({ id: i.externalId, sourceId, prev }),
    pendingTasks: async () => pending,
  };
  return { deps, processed };
}

describe("ingestTaskItems", () => {
  it("막 고친 항목은 미루고, 처음 보는 할 일은 내 열린 할 일만 넣는다", async () => {
    const { deps, processed } = fakeDeps();
    const result = await ingestTaskItems(
      connection,
      [item("editing", 2), item("mine", 30), item("theirs", 30, snap({ owner: "other" })), item("closed", 30, snap({ status: "done" }))],
      deps,
      options,
    );
    expect(processed).toEqual([{ id: "mine", sourceId: "src-mine", prev: null }]);
    expect(result.deferred).toEqual(["editing"]);
    expect(result.skipped).toMatchObject({ settling: 1, notMine: 2 });
  });

  it("Action과 이어진 항목은 내 담당에서 빠지거나 끝나도 넣고, 직전 스냅샷과 비교하게 한다", async () => {
    const prev = snap();
    const { deps, processed } = fakeDeps({ page: { done: { version: "v1", snapshot: prev }, linked: true } });
    await ingestTaskItems(connection, [item("page", 30, snap({ owner: "other", assignees: ["Chan"] }))], deps, options);
    expect(processed).toEqual([{ id: "page", sourceId: "src-page", prev }]);
  });

  it("같은 버전이거나 판정에 쓰는 값이 같으면 넣지 않는다", async () => {
    const same = item("page", 30, snap({ statusLabel: "Next" }));
    const { deps, processed } = fakeDeps({ page: { done: { version: "v1", snapshot: snap() }, linked: true } });
    const result = await ingestTaskItems(connection, [same], deps, options);
    expect(processed).toEqual([]);
    expect(result.skipped.unchanged).toBe(1);
  });

  it("보관 기간이 지나 스냅샷이 비워졌으면(null) 값을 비교하지 않고 바뀐 것으로 보아 처리한다", async () => {
    const { deps, processed } = fakeDeps({ page: { done: { version: "v1", snapshot: null }, linked: true } });
    const result = await ingestTaskItems(connection, [item("page", 30, snap({ owner: "other" }))], deps, options);
    expect(processed).toEqual([{ id: "page", sourceId: "src-page", prev: null }]);
    expect(result.skipped.unchanged).toBe(0);
  });

  it("오래된 변경부터, 상한을 넘은 것은 다음으로 미룬다", async () => {
    const { deps, processed } = fakeDeps();
    const result = await ingestTaskItems(connection, [item("a", 10), item("b", 30), item("c", 20)], deps, { ...options, maxItems: 2 });
    expect(processed.map((p) => p.id)).toEqual(["b", "c"]);
    expect(result.deferred).toEqual(["a"]);
  });

  it("처리에 실패한 버전이 다시 오면 새로 저장하지 않고 그 원문을 다시 처리한다", async () => {
    const failed = item("page", 30);
    const { deps, processed } = fakeDeps({ page: { retry: { sourceId: "src-failed", version: failed.externalVersion }, linked: false } });
    const result = await ingestTaskItems(connection, [failed], deps, options);
    expect(processed).toEqual([{ id: "page", sourceId: "src-failed", prev: null }]);
    expect(result).toMatchObject({ created: [], retried: 1 });
  });

  it("실패한 버전 뒤의 새 버전은 마지막으로 처리를 마친 버전과 비교한다 (실패한 완료도 함께 반영)", async () => {
    const baseline = snap();
    const { deps, processed } = fakeDeps({
      page: { done: { version: "v1", snapshot: baseline }, retry: { sourceId: "src-v2", version: "v2" }, linked: true },
    });
    await ingestTaskItems(connection, [item("page", 30, snap({ status: "done", due: "2026-10-01" }))], deps, options);
    expect(processed).toEqual([{ id: "page", sourceId: "src-page", prev: baseline }]);
  });

  it("커서가 지나가 다시 보이지 않는 실패도 저장한 스냅샷으로 다시 처리한다 (이번에 본 항목은 제외)", async () => {
    const baseline = snap();
    const pending: PendingTask[] = [
      { sourceId: "src-old", item: item("old", 600, snap({ status: "done" })), prev: baseline },
      { sourceId: "src-seen", item: item("seen", 600), prev: null },
    ];
    const { deps, processed } = fakeDeps({}, pending);
    const result = await ingestTaskItems(connection, [item("seen", 30)], deps, options);
    expect(processed).toEqual([
      { id: "seen", sourceId: "src-seen", prev: null },
      { id: "old", sourceId: "src-old", prev: baseline },
    ]);
    expect(result.retried).toBe(1);
  });

  it("같은 버전이 이미 있어 넣지 못한 항목은 다음에 다시 보도록 미룬다 (처음 훑기를 끝났다고 표시하지 않게)", async () => {
    const { deps, processed } = fakeDeps();
    deps.insertTaskSource = async () => null;
    const result = await ingestTaskItems(connection, [item("page", 30)], deps, options);
    expect(processed).toEqual([]);
    expect(result).toMatchObject({ deferred: ["page"], skipped: { conflict: 1 } });
  });

  it("다른 실행이 처리 중인 할 일은 이번에 건너뛰고 다음에 다시 본다", async () => {
    const { deps, processed } = fakeDeps({ page: { inFlight: true, linked: true } });
    const result = await ingestTaskItems(connection, [item("page", 30)], deps, options);
    expect(processed).toEqual([]);
    expect(result.deferred).toEqual(["page"]);
  });
});
