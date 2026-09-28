import { describe, expect, it } from "vitest";

import { syncEach, type SyncAllDeps } from "./sync-all";
import type { Connection } from "./types";

const NOW = Date.parse("2026-09-27T01:00:00Z");

const connection = (id: string, userId: string, lastSyncedAt: Date | null = null): Connection => ({
  id,
  userId,
  provider: "notion",
  settings: {},
  syncCursor: null,
  lastSyncedAt,
});

function setup(connections: Connection[], consented: string[], onSync?: (c: Connection) => void) {
  const synced: string[] = [];
  const asked: string[] = [];
  const consentedNow = new Set(consented);
  const deps: SyncAllDeps = {
    connections: async () => connections,
    consented: async (userId) => {
      asked.push(userId);
      return consentedNow.has(userId);
    },
    sync: async (c) => {
      synced.push(c.id);
      onSync?.(c);
      return { connectionId: c.id, ok: true, result: { created: [], scanned: 0, skipped: {} } };
    },
    now: () => NOW,
  };
  return { deps, synced, asked, consentedNow };
}

describe("syncEach — 외부 AI 처리 동의", () => {
  it("동의하지 않은 사용자의 연결은 가져오지 않고(동기화를 부르지 않고) 건너뛴 수만 센다", async () => {
    const { deps, synced } = setup([connection("c-alice", "alice"), connection("c-bob", "bob"), connection("c-alice-2", "alice")], ["alice"]);
    const result = await syncEach(deps);
    expect(synced).toEqual(["c-alice", "c-alice-2"]);
    expect(result.withoutConsent).toBe(1);
    expect(result.outcomes.map((o) => o.connectionId)).toEqual(["c-alice", "c-alice-2"]);
  });

  it("아무도 동의하지 않았으면 아무것도 동기화하지 않는다 (cron)", async () => {
    const { deps, synced } = setup([connection("c-alice", "alice"), connection("c-bob", "bob")], []);
    expect(await syncEach(deps)).toEqual({ outcomes: [], withoutConsent: 2 });
    expect(synced).toEqual([]);
  });

  it("연결이 없으면 동의를 묻지 않는다", async () => {
    const { deps, asked } = setup([], []);
    expect(await syncEach(deps)).toEqual({ outcomes: [], withoutConsent: 0 });
    expect(asked).toEqual([]);
  });

  it("도중에 철회하면 그 사용자의 남은 연결은 시작하지 않는다 (연결마다 시작 직전에 다시 확인)", async () => {
    const setupResult = setup([connection("c-alice", "alice"), connection("c-bob", "bob"), connection("c-alice-2", "alice")], ["alice", "bob"], (c) => {
      if (c.id === "c-alice") setupResult.consentedNow.delete("alice");
    });
    const result = await syncEach(setupResult.deps);
    expect(setupResult.synced).toEqual(["c-alice", "c-bob"]);
    expect(result.withoutConsent).toBe(1);
    expect(setupResult.asked).toEqual(["alice", "bob", "alice"]);
  });
});

describe("syncEach — 간격 · 시간 한도", () => {
  it("수동 동기화는 방금 동기화한 연결을 다시 돌리지 않는다", async () => {
    const { deps, synced } = setup([connection("c-1", "alice", new Date(NOW - 30_000)), connection("c-2", "alice", new Date(NOW - 120_000))], ["alice"]);
    const result = await syncEach(deps, { minIntervalMs: 60_000 });
    expect(synced).toEqual(["c-2"]);
    expect(result.outcomes[0]).toMatchObject({ connectionId: "c-1", ok: false, busy: true });
  });

  it("시간 한도를 넘기면 남은 연결은 다음 차례로 미룬다", async () => {
    const { deps, synced } = setup([connection("c-1", "alice"), connection("c-2", "alice")], ["alice"]);
    expect((await syncEach(deps, { deadline: NOW - 1 })).outcomes).toEqual([]);
    expect(synced).toEqual([]);
  });
});
