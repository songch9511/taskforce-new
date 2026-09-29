import type { SupabaseClient } from "@supabase/supabase-js";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { CONSENT_WITHDRAWN_MESSAGE, ConsentRequiredError } from "@/lib/consent/gate";

import { connectedAt } from "@/lib/connectors/store";

import { processSource } from "./process";
import { RETRY_WINDOW_MS, retryDeps, retryPlan, retryStalledSources, type RetryCandidate, type RetryDeps } from "./retry";

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
    } = {},
  ) {
    let now = NOW.getTime();
    const processed: { id: string; attempt: number }[] = [];
    const repurged: string[] = [];
    const gaveUp: { id: string; attempt: number }[] = [];
    const since: Date[] = [];
    const claimed: string[] = [];
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
      repurge: async (candidate) => {
        repurged.push(candidate.id);
      },
      clock: () => now,
    };
    return { d, processed, repurged, gaveUp, since, claimed };
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
    expect(result).toEqual({ due: 2, retried: 2, failed: 0, gaveUp: 0, skippedForTime: 0 });
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
