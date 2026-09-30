import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";

import { connectedAt } from "@/lib/connectors/store";

import { processSource } from "./process";
import {
  EXPIRE_BATCH,
  expiredAttempt,
  RETRY_WINDOW_MS,
  retryDeps,
  retryPlan,
  retryStalledSources,
  STALE_PROCESSING_MS,
  type ExpiredCandidate,
  type RetryCandidate,
  type RetryDeps,
} from "./retry";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/connectors/store", () => ({ connectedAt: vi.fn(), loadIdentity: vi.fn() }));
vi.mock("./process", async (importOriginal) => ({ ...(await importOriginal<typeof import("./process")>()), processSource: vi.fn() }));

// 추출이 실패했거나(모델 시간 초과 · 출력 한도 등) 처리 도중 함수가 끊겨 "처리 중"에 멈춘 글 원문을 cron이 다시 처리한다.
// 그대로 두면 그 원문의 약속이 조용히 빠진다 (Slack은 대기 메시지 본문도 비운다).

const NOW = new Date("2026-09-29T12:00:00.000Z");
const minutesAgo = (m: number) => new Date(NOW.getTime() - m * 60_000).toISOString();

const row = (over: Partial<RetryCandidate> = {}): RetryCandidate => ({
  id: "s1",
  user_id: "u1",
  connection_id: null,
  kind: "message",
  raw_text: "금요일까지 보낼게요",
  occurred_at: minutesAgo(120),
  participants: null,
  written_by_me: null,
  processing_status: "failed",
  processing_summary: { attempt: 1, retryable: true, failed_at: minutesAgo(30) },
  processing_error: "빈 응답 (finish_reason: length)",
  created_at: minutesAgo(60),
  ...over,
});
const stalled = (attempt: number, minutes: number) => ({
  processing_status: "processing" as const,
  processing_summary: { attempt, started_at: minutesAgo(minutes) },
});
const DAY = 24 * 60;
/** 들어온 지 이틀, 3시간 전부터 처리 중에 멈춘 원문 (창을 지났다) */
const expiredRow = (over: Partial<ExpiredCandidate> = {}): ExpiredCandidate => ({
  id: "x1",
  user_id: "u1",
  kind: "message",
  processing_status: "processing",
  processing_summary: { attempt: 2, started_at: minutesAgo(180) },
  created_at: minutesAgo(2 * DAY),
  ...over,
});

beforeEach(() => vi.clearAllMocks());

describe("retryPlan: 다시 처리할 원문과 이번 시도 번호", () => {
  it("다시 해 볼 만한 실패는 기다린 뒤 다음 시도로: 첫 실패 뒤 30분, 두 번째 실패 뒤 3시간. 세 번째 시도가 마지막", () => {
    expect(retryPlan(row(), NOW)).toEqual({ kind: "retry", attempt: 2 });
    expect(retryPlan(row({ processing_summary: { attempt: 1, retryable: true, failed_at: minutesAgo(10) } }), NOW)).toBeNull();
    expect(retryPlan(row({ processing_summary: { attempt: 2, retryable: true, failed_at: minutesAgo(60) } }), NOW)).toBeNull();
    expect(retryPlan(row({ processing_summary: { attempt: 2, retryable: true, failed_at: minutesAgo(180) } }), NOW)).toEqual({ kind: "retry", attempt: 3 });
    expect(retryPlan(row({ processing_summary: { attempt: 3, retryable: true, failed_at: minutesAgo(600) } }), NOW)).toBeNull();
  });

  it("동의 철회 같은 다시 해도 안 되는 실패는 다시 하지 않는다", () => {
    expect(retryPlan(row({ processing_summary: { attempt: 1, retryable: false, failed_at: minutesAgo(60) } }), NOW)).toBeNull();
    // 이 기록이 생기기 전에 실패한 원문: 오류 문구로 가르고, 실패 시각 대신 들어온 시각으로 기다림을 잰다
    expect(retryPlan(row({ processing_summary: null, processing_error: CONSENT_WITHDRAWN_MESSAGE }), NOW)).toBeNull();
    expect(retryPlan(row({ processing_summary: null }), NOW)).toEqual({ kind: "retry", attempt: 2 });
    expect(retryPlan(row({ processing_summary: null, created_at: minutesAgo(10) }), NOW)).toBeNull();
  });

  it("처리 중 · 대기에 15분 넘게 멈춘 원문 (함수가 끊김)은 다시 한다. 아직 돌고 있을 수 있으면 두고 본다", () => {
    expect(retryPlan(row(stalled(1, 20)), NOW)).toEqual({ kind: "retry", attempt: 2 });
    expect(retryPlan(row(stalled(1, 5)), NOW)).toBeNull();
    // 시작 시각이 없으면 들어온 시각으로 본다
    expect(retryPlan(row({ processing_status: "processing", processing_summary: null, created_at: minutesAgo(60) }), NOW)).toEqual({ kind: "retry", attempt: 2 });
    expect(retryPlan(row({ processing_status: "pending", processing_summary: null, created_at: minutesAgo(20) }), NOW)).toEqual({ kind: "retry", attempt: 1 });
    expect(retryPlan(row({ processing_status: "pending", processing_summary: null, created_at: minutesAgo(5) }), NOW)).toBeNull();
  });

  it("마지막 시도에서 멈춘 원문은 실패로 닫는다 (처리 중으로 계속 남지 않게)", () => {
    expect(retryPlan(row(stalled(3, 20)), NOW)).toEqual({ kind: "give_up", attempt: 3 });
    expect(retryPlan(row(stalled(3, 5)), NOW)).toBeNull();
  });

  it("끝난 원문은 다시 하지 않는다", () => {
    expect(retryPlan(row({ processing_status: "done" }), NOW)).toBeNull();
  });
});

describe("expiredAttempt: 창을 지나서도 멈춘 원문 (다시 하지 않고 닫는다)", () => {
  it("들어온 지 하루가 지났고 처리 중 · 대기에 15분 넘게 멈춘 글 원문은 닫는다. 기록된 시도 횟수를 그대로 돌려준다 (기록이 없으면 대기 0, 처리 중 1)", () => {
    expect(expiredAttempt(expiredRow(), NOW)).toBe(2);
    expect(expiredAttempt(expiredRow({ processing_status: "pending", processing_summary: null }), NOW)).toBe(0);
    expect(expiredAttempt(expiredRow({ processing_status: "processing", processing_summary: null }), NOW)).toBe(1);
    // 마지막 시도에서 멈췄어도 창을 지났으면 같은 방식으로 닫는다
    expect(expiredAttempt(expiredRow({ processing_summary: { attempt: 3, started_at: minutesAgo(600) } }), NOW)).toBe(3);
  });

  it("창 안(하루 이내)의 원문은 얼마나 멈췄든 건드리지 않는다. 창의 경계는 candidates(created_at >= 창 시작)와 겹치지 않는다", () => {
    expect(expiredAttempt(expiredRow({ created_at: minutesAgo(23 * 60) }), NOW)).toBeNull();
    expect(expiredAttempt(expiredRow({ created_at: new Date(NOW.getTime() - RETRY_WINDOW_MS).toISOString() }), NOW)).toBeNull();
    expect(expiredAttempt(expiredRow({ created_at: new Date(NOW.getTime() - RETRY_WINDOW_MS - 1).toISOString() }), NOW)).toBe(2);
  });

  it("아직 돌고 있을 수 있으면(시작한 지 15분이 안 됨) 두고, 시작 시각이 없으면 들어온 시각으로 본다", () => {
    expect(expiredAttempt(expiredRow({ processing_summary: { attempt: 2, started_at: minutesAgo(5) } }), NOW)).toBeNull();
    expect(expiredAttempt(expiredRow({ processing_summary: { attempt: 2, started_at: new Date(NOW.getTime() - STALE_PROCESSING_MS + 1).toISOString() } }), NOW)).toBeNull();
    expect(expiredAttempt(expiredRow({ processing_summary: { attempt: 2 } }), NOW)).toBe(2);
  });

  it("할 일 DB 항목(task)과 처리가 끝난(완료 · 실패) 원문은 닫지 않는다", () => {
    expect(expiredAttempt(expiredRow({ kind: "task" }), NOW)).toBeNull();
    expect(expiredAttempt(expiredRow({ processing_status: "done" }), NOW)).toBeNull();
    expect(expiredAttempt(expiredRow({ processing_status: "failed" }), NOW)).toBeNull();
  });
});

describe("retryStalledSources", () => {
  function deps(
    candidates: RetryCandidate[],
    options: {
      consented?: string[];
      msPerItem?: number;
      fail?: string[];
      notOk?: string[];
      withdraw?: string[];
      taken?: string[];
      closedElsewhere?: string[];
      noIdentity?: string[];
      /** 창을 지나 멈춘 원문 (닫으면 다음 조회에서 빠진다) */
      expired?: ExpiredCandidate[];
      expireElsewhere?: string[];
      expireFails?: string[];
      expiredLookupFails?: boolean;
    } = {},
  ) {
    let now = NOW.getTime();
    const processed: { id: string; attempt: number }[] = [];
    const repurged: string[] = [];
    const gaveUp: { id: string; attempt: number }[] = [];
    const since: Date[] = [];
    const claimed: string[] = [];
    const ranges: { createdBefore: Date; startedBefore: Date; limit: number }[] = [];
    const expiredClosed: { id: string; attempt: number }[] = [];
    const d: RetryDeps = {
      candidates: async (from) => {
        since.push(from);
        return candidates;
      },
      consentedUsers: async (ids) => new Set(ids.filter((id) => (options.consented ?? ["u1", "u2"]).includes(id))),
      identity: async (userId) => {
        if (options.noIdentity?.includes(userId)) throw new Error("프로필 읽기 실패");
        return { name: userId, aliases: [], emails: [] };
      },
      claim: async (candidate) => {
        claimed.push(candidate.id);
        return !options.taken?.includes(candidate.id);
      },
      process: async (candidate, _identity, attempt) => {
        now += options.msPerItem ?? 10_000;
        processed.push({ id: candidate.id, attempt });
        if (options.withdraw?.includes(candidate.id)) throw new ConsentRequiredError();
        if (options.fail?.includes(candidate.id)) throw new Error("처리 실패");
        return !options.notOk?.includes(candidate.id);
      },
      giveUp: async (candidate, attempt) => {
        gaveUp.push({ id: candidate.id, attempt });
        return !options.closedElsewhere?.includes(candidate.id);
      },
      // 실제 조회처럼 이미 닫은 것은 빼고 들어온 순서로 limit건까지만 돌려준다 (창 · 시각 조건은 일부러 보지 않는다: 부르는 쪽이 다시 확인한다)
      expired: async (range) => {
        ranges.push(range);
        if (options.expiredLookupFails) throw new Error("조회 실패");
        const done = new Set(expiredClosed.map((c) => c.id));
        return (options.expired ?? []).filter((e) => !done.has(e.id)).slice(0, range.limit);
      },
      expire: async (candidate, attempt) => {
        if (options.expireFails?.includes(candidate.id)) throw new Error("닫기 실패");
        if (options.expireElsewhere?.includes(candidate.id)) return false;
        expiredClosed.push({ id: candidate.id, attempt });
        return true;
      },
      repurge: async (candidate) => {
        repurged.push(candidate.id);
      },
      clock: () => now,
    };
    return { d, processed, repurged, gaveUp, since, claimed, ranges, expiredClosed };
  }
  const run = (d: RetryDeps, itemBudgetMs = 200_000) => retryStalledSources(d, { now: NOW, deadline: NOW.getTime() + 280_000, itemBudgetMs });

  it("하루 안에 들어온 원문 중 다시 할 것을 들어온 순서대로, 이번 시도 번호와 함께 처리하고 Slack 글자 재삭제를 확인한다", async () => {
    const { d, processed, repurged, since } = deps([
      row({ id: "a" }),
      row({ id: "b", processing_status: "done" }),
      row({ id: "c", user_id: "u3" }),
      row({ id: "d", ...stalled(2, 30) }),
    ]);
    const result = await run(d);
    expect(since).toEqual([new Date(NOW.getTime() - RETRY_WINDOW_MS)]);
    // b는 끝남, c는 동의하지 않은 사용자
    expect(processed).toEqual([
      { id: "a", attempt: 2 },
      { id: "d", attempt: 3 },
    ]);
    expect(repurged).toEqual(["a", "d"]);
    expect(result).toEqual({ due: 2, retried: 2, failed: 0, gaveUp: 0, expired: 0, skippedForTime: 0 });
  });

  it("다른 실행이 먼저 가져간 원문은 건너뛴다", async () => {
    const { d, processed, repurged } = deps([row({ id: "a" }), row({ id: "d" })], { taken: ["a"] });
    const result = await run(d);
    expect(processed.map((p) => p.id)).toEqual(["d"]);
    expect(repurged).toEqual(["d"]);
    expect(result).toMatchObject({ due: 2, retried: 1 });
  });

  it("마지막 시도에서 멈춘 원문은 모델을 부르지 않고 실패로 닫는다 (동의와 상관없이). 다른 실행이 먼저 바꿨으면 세지 않는다", async () => {
    const { d, processed, gaveUp } = deps(
      [row({ id: "a", user_id: "u3", ...stalled(3, 30) }), row({ id: "b", ...stalled(3, 30) }), row({ id: "d" })],
      { closedElsewhere: ["b"] },
    );
    const result = await run(d);
    expect(gaveUp).toEqual([
      { id: "a", attempt: 3 },
      { id: "b", attempt: 3 },
    ]);
    expect(processed.map((p) => p.id)).toEqual(["d"]);
    expect(result).toMatchObject({ due: 1, retried: 1, gaveUp: 1 });
  });

  it("처리 준비(원문 속 나)가 실패하면 가져가지 않는다 (모델을 부르지도 않고 시도를 쓰지 않게)", async () => {
    const { d, processed, claimed } = deps([row({ id: "a" }), row({ id: "b", user_id: "u2" })], { noIdentity: ["u1"] });
    const result = await run(d);
    expect(claimed).toEqual(["b"]);
    expect(processed.map((p) => p.id)).toEqual(["b"]);
    expect(result).toMatchObject({ due: 2, retried: 1, failed: 1 });
  });

  it("남은 시간이 한 건의 처리 시간 예산보다 적으면 새로 시작하지 않는다", async () => {
    const { d, processed } = deps([row({ id: "a" }), row({ id: "d" }), row({ id: "e" })], { msPerItem: 50_000 });
    const result = await run(d);
    // 0초에 a 시작(끝 50초), 50초에 d 시작(250초까지 가능, 끝 100초), 100초에는 300초가 되어 멈춘다
    expect(processed.map((p) => p.id)).toEqual(["a", "d"]);
    expect(result.skippedForTime).toBe(1);
  });

  it("한 건이 실패해도 다음 원문을 처리한다. 처리가 실패로 끝난 것도 실패로 센다", async () => {
    const { d, processed, repurged } = deps([row({ id: "a" }), row({ id: "d" }), row({ id: "e" })], { fail: ["a"], notOk: ["d"] });
    const result = await run(d, 60_000);
    expect(processed.map((p) => p.id)).toEqual(["a", "d", "e"]);
    expect(repurged).toEqual(["a", "d", "e"]);
    expect(result).toMatchObject({ retried: 3, failed: 2 });
  });

  it("도중에 동의를 철회한 사용자의 남은 원문은 멈추고, 다른 사용자는 이어 간다", async () => {
    const { d, processed, repurged } = deps([row({ id: "a" }), row({ id: "b", user_id: "u2" }), row({ id: "c" })], { withdraw: ["a"] });
    const result = await run(d, 60_000);
    expect(processed.map((p) => p.id)).toEqual(["a", "b"]);
    expect(repurged).toEqual(["a", "b"]);
    expect(result).toMatchObject({ due: 3, retried: 2, failed: 1 });
  });

  it("창을 지나 멈춘 원문은 동의와 상관없이 실패로 닫고 센다. 조회에는 창 시작 · 15분 전 · 한 번의 상한을 넘긴다", async () => {
    const { d, expiredClosed, ranges } = deps([], {
      expired: [
        expiredRow({ id: "a" }),
        // 동의하지 않은 사용자 · 대기 상태 · 시도 기록 없음
        expiredRow({ id: "b", user_id: "u3", processing_status: "pending", processing_summary: null }),
      ],
    });
    const result = await run(d);
    expect(ranges).toEqual([
      { createdBefore: new Date(NOW.getTime() - RETRY_WINDOW_MS), startedBefore: new Date(NOW.getTime() - STALE_PROCESSING_MS), limit: EXPIRE_BATCH },
    ]);
    expect(expiredClosed).toEqual([
      { id: "a", attempt: 2 },
      { id: "b", attempt: 0 },
    ]);
    expect(result).toEqual({ due: 0, retried: 0, failed: 0, gaveUp: 0, expired: 2, skippedForTime: 0 });
  });

  it("창 안 · 아직 돌고 있을 수 있는 · 할 일 DB 항목 · 끝난 원문은 조회가 잘못 돌려줘도 닫지 않는다", async () => {
    const { d, expiredClosed } = deps([], {
      expired: [
        expiredRow({ id: "in-window", created_at: minutesAgo(23 * 60) }),
        expiredRow({ id: "running", processing_summary: { attempt: 2, started_at: minutesAgo(5) } }),
        expiredRow({ id: "task", kind: "task" }),
        expiredRow({ id: "done", processing_status: "done" }),
        expiredRow({ id: "real" }),
      ],
    });
    const result = await run(d);
    expect(expiredClosed.map((c) => c.id)).toEqual(["real"]);
    expect(result.expired).toBe(1);
  });

  it("읽은 뒤 다른 실행이 바꿨으면(닫기가 false) 덮어쓰지 않고 세지도 않는다", async () => {
    const { d, expiredClosed } = deps([], { expired: [expiredRow({ id: "a" }), expiredRow({ id: "b" })], expireElsewhere: ["a"] });
    const result = await run(d);
    expect(expiredClosed.map((c) => c.id)).toEqual(["b"]);
    expect(result.expired).toBe(1);
  });

  it("한 건을 닫지 못해도 다음 원문을 닫고, 조회가 실패해도 다시 처리는 막지 않는다", async () => {
    const failing = deps([], { expired: [expiredRow({ id: "a" }), expiredRow({ id: "b" })], expireFails: ["a"] });
    expect((await run(failing.d)).expired).toBe(1);
    expect(failing.expiredClosed.map((c) => c.id)).toEqual(["b"]);

    const lookup = deps([row({ id: "r" })], { expired: [expiredRow({ id: "a" })], expiredLookupFails: true });
    const result = await run(lookup.d);
    expect(lookup.processed.map((p) => p.id)).toEqual(["r"]);
    expect(result).toEqual({ due: 1, retried: 1, failed: 0, gaveUp: 0, expired: 0, skippedForTime: 0 });
  });

  it("한 번에 EXPIRE_BATCH건까지만 오래된 것부터 닫고, 남은 것은 다음 실행이 이어서 닫는다", async () => {
    const rows = Array.from({ length: EXPIRE_BATCH * 2 + 30 }, (_, i) => expiredRow({ id: `e${i}` }));
    const { d, expiredClosed } = deps([], { expired: rows });
    expect((await run(d)).expired).toBe(EXPIRE_BATCH);
    expect(expiredClosed.map((c) => c.id)).toEqual(rows.slice(0, EXPIRE_BATCH).map((r) => r.id));
    expect((await run(d)).expired).toBe(EXPIRE_BATCH);
    expect((await run(d)).expired).toBe(30);
    expect((await run(d)).expired).toBe(0);
    expect(expiredClosed.map((c) => c.id)).toEqual(rows.map((r) => r.id));
  });

  it("창 안의 원문 처리는 그대로다: 동의하지 않은 사용자의 창 안 원문은 닫지 않고 남긴다", async () => {
    const { d, expiredClosed, processed } = deps([row({ id: "mine" }), row({ id: "theirs", user_id: "u3" })], { expired: [expiredRow({ id: "old" })] });
    const result = await run(d);
    expect(processed.map((p) => p.id)).toEqual(["mine"]);
    expect(expiredClosed.map((c) => c.id)).toEqual(["old"]);
    expect(result).toMatchObject({ due: 1, retried: 1, expired: 1 });
  });
});

describe("retryDeps: DB 조건", () => {
  /** 쿼리마다 부른 메서드를 기록하고, 차례로 준비한 응답을 돌려주는 가짜 service role 클라이언트 */
  function fakeAdmin(responses: unknown[] = []) {
    const queries: string[][] = [];
    let current: string[] = [];
    const format = (value: unknown) => (typeof value === "string" ? value : JSON.stringify(value));
    const builder: object = new Proxy(
      {},
      {
        get: (_target, method) =>
          method === "throwOnError"
            ? async () => ({ data: responses.length > 0 ? responses.shift() : [] })
            : (...args: unknown[]) => {
                current.push([String(method), ...args.map(format)].join(" "));
                return builder;
              },
      },
    );
    const start = (first: string) => {
      current = [first];
      queries.push(current);
      return builder;
    };
    const admin = { from: (table: string) => start(`from ${table}`), rpc: (name: string, args: unknown) => start(`rpc ${name} ${format(args)}`) };
    return { admin: admin as unknown as SupabaseClient, queries };
  }

  it("후보: 하루 안에 들어온, 끝나지 않은 글 원문 중 글이 남아 있고 더 하지 않기로 한 실패가 아닌 것을 오래된 순서로", async () => {
    const { admin, queries } = fakeAdmin([[row({ id: "a" })]]);
    const since = new Date(NOW.getTime() - RETRY_WINDOW_MS);
    expect((await retryDeps(admin).candidates(since)).map((c) => c.id)).toEqual(["a"]);
    expect(queries[0].slice(2)).toEqual([
      'in processing_status ["pending","processing","failed"]',
      "neq kind task",
      "is raw_text_purged_at null",
      `gte created_at ${since.toISOString()}`,
      "or processing_summary->>retryable.is.null,processing_summary->>retryable.eq.true",
      'order created_at {"ascending":true}',
      "limit 50",
    ]);
  });

  it("가져가기: 읽은 뒤 상태 · 처리 기록이 그대로일 때만 이번 시도로 바꾼다", async () => {
    const { admin, queries } = fakeAdmin([[{ id: "s1" }], []]);
    const deps = retryDeps(admin);
    const failed = row();
    expect(await deps.claim(failed, 2)).toBe(true);
    expect(queries[0]).toContain(`contains processing_summary ${JSON.stringify(failed.processing_summary)}`);
    expect(queries[0]).toContain("eq processing_status failed");
    expect(queries[0][1]).toMatch(/^update \{"processing_status":"processing","processing_summary":\{"attempt":2,"started_at":"/);

    // 기록이 없던 원문은 여전히 없을 때만. 다른 실행이 먼저 바꿨으면(0행) 가져가지 않는다
    expect(await deps.claim(row({ processing_status: "pending", processing_summary: null }), 1)).toBe(false);
    expect(queries[1]).toContain("is processing_summary null");
    expect(queries[1]).toContain("eq processing_status pending");
  });

  it("닫기: 마지막 시도에서 멈춘 원문을 더 다시 하지 않는 실패로", async () => {
    const { admin, queries } = fakeAdmin([[{ id: "s1" }]]);
    await retryDeps(admin).giveUp(row(stalled(3, 30)), 3);
    const update = JSON.parse(queries[0][1].slice("update ".length));
    expect(update).toMatchObject({
      processing_status: "failed",
      processing_error: "처리 중 오류가 발생했습니다.",
      processing_summary: { attempt: 3, retryable: false },
    });
    expect(queries[0]).toContain("eq processing_status processing");
  });

  it("창을 지난 원문 조회: 글은 읽지 않고, 창 전에 들어와 처리 중 · 대기에 멈춘 글 원문을 오래된 순서로 한 번의 상한까지", async () => {
    const { admin, queries } = fakeAdmin([[expiredRow({ id: "a" })]]);
    const createdBefore = new Date(NOW.getTime() - RETRY_WINDOW_MS);
    const startedBefore = new Date(NOW.getTime() - STALE_PROCESSING_MS);
    expect((await retryDeps(admin).expired({ createdBefore, startedBefore, limit: EXPIRE_BATCH })).map((r) => r.id)).toEqual(["a"]);
    expect(queries[0]).toEqual([
      "from sources",
      "select id, user_id, kind, processing_status, processing_summary, created_at",
      'in processing_status ["pending","processing"]',
      "neq kind task",
      `lt created_at ${createdBefore.toISOString()}`,
      `or processing_summary->>started_at.is.null,processing_summary->>started_at.lt.${startedBefore.toISOString()}`,
      'order created_at {"ascending":true}',
      `limit ${EXPIRE_BATCH}`,
    ]);
  });

  it("창을 지난 원문 닫기: 실패로 닫고 더 다시 하지 않으며 까닭을 남긴다. 읽은 뒤 상태 · 기록이 그대로일 때만", async () => {
    const { admin, queries } = fakeAdmin([[{ id: "x1" }], []]);
    const deps = retryDeps(admin);
    const stuck = expiredRow();
    expect(await deps.expire(stuck, 2)).toBe(true);
    const update = JSON.parse(queries[0][1].slice("update ".length));
    expect(update).toMatchObject({
      processing_status: "failed",
      processing_error: "처리 중 오류가 발생했습니다.",
      processing_summary: { attempt: 2, retryable: false, closed: "expired" },
    });
    expect(typeof update.processed_at).toBe("string");
    expect(typeof update.processing_summary.failed_at).toBe("string");
    expect(queries[0]).toContain("eq processing_status processing");
    expect(queries[0]).toContain("eq user_id u1");
    expect(queries[0]).toContain(`contains processing_summary ${JSON.stringify(stuck.processing_summary)}`);

    // 그 사이 다른 실행이 바꿨으면(0행) 닫지 않는다. 기록이 없던 원문은 여전히 없을 때만
    expect(await deps.expire(expiredRow({ processing_status: "pending", processing_summary: null }), 0)).toBe(false);
    expect(queries[1]).toContain("is processing_summary null");
    expect(queries[1]).toContain("eq processing_status pending");
  });

  it("마지막 시도에서 멈춰 닫는 것(giveUp)에는 창을 지나 닫는 까닭이 붙지 않는다 (둘을 가를 수 있게)", async () => {
    const { admin, queries } = fakeAdmin([[{ id: "s1" }]]);
    await retryDeps(admin).giveUp(row(stalled(3, 30)), 3);
    expect(JSON.parse(queries[0][1].slice("update ".length)).processing_summary).not.toHaveProperty("closed");
  });

  it("처리: 연결 전 시각의 연동 원문은 알림 없이 처리한다 (동기화가 한꺼번에 가져온 옛 원문)", async () => {
    const { admin } = fakeAdmin();
    const deps = retryDeps(admin);
    const identity = { name: "나", aliases: [], emails: [] };
    vi.mocked(connectedAt).mockResolvedValue(new Date(minutesAgo(90)));
    vi.mocked(processSource).mockResolvedValue({ ok: true, needsConfirmation: [] });

    await deps.process(row({ connection_id: "c1", occurred_at: minutesAgo(120) }), identity, 2);
    await deps.process(row({ id: "s2", connection_id: "c1", occurred_at: minutesAgo(30) }), identity, 2);
    expect(vi.mocked(processSource).mock.calls.map(([, source]) => source.notify)).toEqual([false, true]);
    // 연결 시각은 연결마다 한 번만 읽는다
    expect(connectedAt).toHaveBeenCalledTimes(1);
    expect(connectedAt).toHaveBeenCalledWith(admin, { id: "c1", userId: "u1" });
  });

  it("처리: 다시 처리임과 시도 번호를 넘기고 결과를 돌려준다. 동의를 철회했으면 원문은 지우지 않는다 (다시 얻을 수 없다)", async () => {
    const { admin, queries } = fakeAdmin();
    const deps = retryDeps(admin);
    const identity = { name: "나", aliases: [], emails: [] };
    vi.mocked(processSource).mockResolvedValueOnce({ ok: false, needsConfirmation: [] });
    expect(await deps.process(row(), identity, 2)).toBe(false);
    expect(vi.mocked(processSource).mock.calls[0][1]).toEqual({ id: "s1", userId: "u1", attempt: 2, retry: true, notify: true });

    vi.mocked(processSource).mockRejectedValueOnce(new ConsentRequiredError());
    await expect(deps.process(row(), identity, 2)).rejects.toBeInstanceOf(ConsentRequiredError);
    expect(queries).toEqual([]);
  });
});
