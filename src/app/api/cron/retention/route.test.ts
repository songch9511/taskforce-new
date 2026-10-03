import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { checkSlackConnectionTokens } from "@/lib/connectors/slack/run";
import { EXECUTION_TEXT_RETENTION_DAYS, retentionCutoff } from "@/lib/retention";
import { createAdminClient } from "@/lib/supabase/admin";

import { GET } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn() }));
vi.mock("@/lib/connectors/slack/run", () => ({ checkSlackConnectionTokens: vi.fn() }));

// 원문 정리가 밀려도(매번 한도만큼 지움) Slack 토큰 확인에 떼어 둔 시간은 남는다 (D3: 앱 해제 이벤트를 놓쳤을 때의 안전망).
// 실행 산출물 본문(보관 기간이 지난 것)과 만든 지 90일이 지난 끝난 run의 글도 같은 cron이 지운다. 실패해도 나머지는 하고 500.

let now = 0;

/**
 * 부를 때마다 2초가 걸리는 가짜 service role 클라이언트. busy면 원문 · Slack 정리가 매번 한도(5000건)만큼 지워 밀린 것이 남는다.
 * artifacts · execution: purge_expired_artifacts · purge_expired_execution_text가 돌려줄 수, Error면 실패. args: RPC마다 받은 인자
 */
function fakeAdmin({ busy = false, artifacts = 0, execution = 0 }: { busy?: boolean; artifacts?: number | Error; execution?: number | Error } = {}) {
  const calls: string[] = [];
  const args: Record<string, unknown> = {};
  const n = busy ? 5000 : 0;
  const call = async (fn: string) => {
    calls.push(fn);
    now += 2_000;
    if (fn === "purge_expired_artifacts" || fn === "purge_expired_execution_text") {
      const result = fn === "purge_expired_artifacts" ? artifacts : execution;
      if (result instanceof Error) throw result;
      return { data: result };
    }
    return fn === "purge_expired_source_text"
      ? { data: { sources_purged: n, judge_logs_deleted: 0, rate_limit_events_deleted: 0, missing_reports_deleted: 0 } }
      : { data: { messages_deleted: n, threads_deleted: 0, sources_repurged: 0 } };
  };
  const admin = {
    rpc: (fn: string, params?: unknown) => {
      args[fn] = params;
      return { single: () => ({ throwOnError: () => call(fn) }), throwOnError: () => call(fn) };
    },
  } as unknown as SupabaseClient;
  vi.mocked(createAdminClient).mockReturnValue(admin as ReturnType<typeof createAdminClient>);
  return { calls, args };
}

const cron = (authorization = "Bearer s3cret") => GET(new Request("https://api.example.dev/api/cron/retention", { headers: { authorization } }));

beforeEach(() => {
  vi.clearAllMocks();
  now = 1_000_000;
  vi.spyOn(Date, "now").mockImplementation(() => now);
  vi.stubEnv("CRON_SECRET", "s3cret");
  vi.mocked(checkSlackConnectionTokens).mockResolvedValue({ checked: 0, revoked: 0, failed: 0 });
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /api/cron/retention", () => {
  it("CRON_SECRET이 맞지 않으면 401", async () => {
    const { calls } = fakeAdmin();
    const response = await cron("Bearer wrong!");
    expect(response.status).toBe(401);
    expect(calls).toEqual([]);
    expect(checkSlackConnectionTokens).not.toHaveBeenCalled();
  });

  it("보관 기간이 지난 실행 산출물 본문을 맨 먼저, 이어서 만든 지 90일이 지난 끝난 run의 글을 한 번씩 지우고 수를 응답에 남긴다", async () => {
    const { calls, args } = fakeAdmin({ artifacts: 3, execution: 2 });

    const response = await cron();

    expect(response.status).toBe(200);
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_expired_source_text", "purge_slack_buffers"]);
    expect(await response.json()).toMatchObject({ artifacts_purged: 3, execution_text_purged: 2, sources_purged: 0, calls: 4 });
    expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
    // 기준 시각 = 지금 - EXECUTION_TEXT_RETENTION_DAYS (run을 만든 시각과 비교한다), 한 번에 5000개 run
    expect(EXECUTION_TEXT_RETENTION_DAYS).toBe(90);
    const { p_before, p_limit } = args.purge_expired_execution_text as { p_before: string; p_limit: number };
    const cutoff = new Date(p_before).getTime();
    expect(Math.abs(cutoff - retentionCutoff(new Date(), EXECUTION_TEXT_RETENTION_DAYS).getTime())).toBeLessThan(60_000);
    expect(p_limit).toBe(5000);
  });

  it("산출물 정리가 실패해도 원문 · Slack 정리와 토큰 확인은 하고 500 (로그에는 오류 메시지만)", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { calls } = fakeAdmin({ artifacts: new Error("function public.purge_expired_artifacts() does not exist") });

    const response = await cron();

    expect(response.status).toBe(500);
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_expired_source_text", "purge_slack_buffers"]);
    expect(await response.json()).toMatchObject({ artifacts_purged: null, execution_text_purged: 0, sources_purged: 0 });
    expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
    expect(error).toHaveBeenCalledWith("실행 산출물 본문 정리 실패:", "function public.purge_expired_artifacts() does not exist");
  });

  it("실행 글 정리가 실패해도 산출물 · 원문 · Slack 정리와 토큰 확인은 하고 500 (그 칸만 null, 로그에는 오류 메시지만)", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { calls } = fakeAdmin({ artifacts: 1, execution: new Error("function public.purge_expired_execution_text(timestamp with time zone, integer) does not exist") });

    const response = await cron();

    expect(response.status).toBe(500);
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_expired_source_text", "purge_slack_buffers"]);
    expect(await response.json()).toMatchObject({ artifacts_purged: 1, execution_text_purged: null, sources_purged: 0 });
    expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
    expect(error).toHaveBeenCalledWith(
      "실행 글 정리 실패:",
      "function public.purge_expired_execution_text(timestamp with time zone, integer) does not exist",
    );
  });

  it("산출물 · 실행 글 정리가 둘 다 실패해도 원문 · Slack 정리와 토큰 확인은 하고 500 (두 칸 모두 null)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { calls } = fakeAdmin({ artifacts: new Error("a"), execution: new Error("b") });

    const response = await cron();

    expect(response.status).toBe(500);
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_expired_source_text", "purge_slack_buffers"]);
    expect(await response.json()).toMatchObject({ artifacts_purged: null, execution_text_purged: null, sources_purged: 0 });
    expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
  });

  it("정리가 밀려도 Slack 토큰 확인에 떼어 둔 시간(15초 이상)을 남긴다", async () => {
    const { calls } = fakeAdmin({ busy: true });
    const started = now;

    const response = await cron();

    expect(response.status).toBe(200);
    expect(calls).toContain("purge_expired_source_text");
    expect(calls).toContain("purge_slack_buffers");
    const [, options] = vi.mocked(checkSlackConnectionTokens).mock.calls[0];
    const calledAt = now;
    expect(options?.deadline).toBeDefined();
    expect(options!.deadline! - calledAt).toBeGreaterThanOrEqual(15_000);
    // 한도 직전에 시작한 Slack 호출(최대 10초)까지 실행 한도(60초) 안에서 끝나고 응답할 시간을 남긴다
    expect(options!.deadline! - started).toBeLessThanOrEqual(40_000);
  });
});
