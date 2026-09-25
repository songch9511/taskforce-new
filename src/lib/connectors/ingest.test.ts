import { describe, expect, it } from "vitest";

import { ingestItems, type IngestDeps } from "./ingest";
import type { Connection, IngestItem } from "./types";

const now = new Date("2026-09-25T12:00:00Z");
const connection: Connection = { id: "c1", userId: "u1", provider: "notion", settings: {}, syncCursor: null };
const options = { now, settleMinutes: 30, maxItems: 2, minTextLength: 10 };

const item = (id: string, minutesAgo: number, text = "태오: 금요일까지 도면 보내드릴게요"): IngestItem => ({
  externalId: id,
  externalVersion: `v-${minutesAgo}`,
  kind: "meeting",
  title: id,
  text,
  occurredAt: new Date(now.getTime() - minutesAgo * 60_000),
  lastEditedAt: new Date(now.getTime() - minutesAgo * 60_000),
  externalUrl: null,
});

function deps(already: string[] = [], conflict: string[] = []) {
  const processed: string[] = [];
  const d: IngestDeps = {
    ingestedIds: async (_c, ids) => new Set(ids.filter((id) => already.includes(id))),
    insertSource: async (_c, i) => (conflict.includes(i.externalId) ? null : `src-${i.externalId}`),
    process: async (_c, sourceId) => {
      processed.push(sourceId);
    },
  };
  return { d, processed };
}

describe("ingestItems", () => {
  it("안정된 새 항목만 오래된 순서로 넣고 처리한다", async () => {
    const { d, processed } = deps(["old"]);
    const result = await ingestItems(
      connection,
      [item("b", 60), item("a", 120), item("editing", 5), item("old", 300), item("empty", 90, "  ")],
      d,
      options,
    );
    expect(result.created).toEqual(["src-a", "src-b"]);
    expect(processed).toEqual(["src-a", "src-b"]);
    expect(result.skipped).toEqual({ tooShort: 1, settling: 1, alreadyIngested: 1, overLimit: 0 });
  });

  it("상한을 넘으면 나머지는 다음 동기화로 미룬다", async () => {
    const { d } = deps();
    const result = await ingestItems(connection, [item("a", 100), item("b", 90), item("c", 80)], d, options);
    expect(result.created).toEqual(["src-a", "src-b"]);
    expect(result.skipped.overLimit).toBe(1);
  });

  it("저장 순간 충돌(동시 동기화)은 이미 넣은 것으로 센다", async () => {
    const { d, processed } = deps([], ["a"]);
    const result = await ingestItems(connection, [item("a", 100)], d, options);
    expect(result.created).toEqual([]);
    expect(result.skipped.alreadyIngested).toBe(1);
    expect(processed).toEqual([]);
  });
});

describe("ingestItems 시간 한도", () => {
  it("한도를 넘기면 남은 항목은 처리하지 않고 알려준다", async () => {
    const { d, processed } = deps();
    const result = await ingestItems(connection, [item("a", 100), item("b", 90)], d, { ...options, deadline: Date.now() - 1 });
    expect(processed).toEqual([]);
    expect(result.notReached).toEqual(["a", "b"]);
  });
});
