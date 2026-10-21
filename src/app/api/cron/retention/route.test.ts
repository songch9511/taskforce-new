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
function fakeAdmin({ busy = false, artifacts = 0, execution = 0, bridge = 0, paths = 0, signups = 0, external = 0 }: { busy?: boolean; artifacts?: number | Error; execution?: number | Error; bridge?: number | Error; paths?: number | Error; signups?: number | Error; external?: number | Error } = {}) {
  const calls: string[] = [];
  const args: Record<string, unknown> = {};
  const n = busy ? 5000 : 0;
  const call = async (fn: string) => {
    calls.push(fn);
    now += 2_000;
    if (fn === "purge_expired_artifacts" || fn === "purge_expired_execution_text" || fn === "purge_bridge_commands" || fn === "purge_agent_path_leases" || fn === "purge_unconfirmed_email_signups" || fn === "purge_external_sessions") {
      const result = fn === "purge_expired_artifacts" ? artifacts : fn === "purge_bridge_commands" ? bridge : fn === "purge_agent_path_leases" ? paths : fn === "purge_unconfirmed_email_signups" ? signups : fn === "purge_external_sessions" ? external : execution;
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
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_bridge_commands", "purge_agent_path_leases", "purge_unconfirmed_email_signups", "purge_external_sessions", "purge_expired_source_text", "purge_slack_buffers"]);
    expect(await response.json()).toMatchObject({ artifacts_purged: 3, execution_text_purged: 2, sources_purged: 0, calls: 8 });
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
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_bridge_commands", "purge_agent_path_leases", "purge_unconfirmed_email_signups", "purge_external_sessions", "purge_expired_source_text", "purge_slack_buffers"]);
    expect(await response.json()).toMatchObject({ artifacts_purged: null, execution_text_purged: 0, sources_purged: 0 });
    expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
    expect(error).toHaveBeenCalledWith("실행 산출물 본문 정리 실패:", "function public.purge_expired_artifacts() does not exist");
  });

  it("실행 글 정리가 실패해도 산출물 · 원문 · Slack 정리와 토큰 확인은 하고 500 (그 칸만 null, 로그에는 오류 메시지만)", async () => {
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const { calls } = fakeAdmin({ artifacts: 1, execution: new Error("function public.purge_expired_execution_text(timestamp with time zone, integer) does not exist") });

    const response = await cron();

    expect(response.status).toBe(500);
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_bridge_commands", "purge_agent_path_leases", "purge_unconfirmed_email_signups", "purge_external_sessions", "purge_expired_source_text", "purge_slack_buffers"]);
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
    expect(calls).toEqual(["purge_expired_artifacts", "purge_expired_execution_text", "purge_bridge_commands", "purge_agent_path_leases", "purge_unconfirmed_email_signups", "purge_external_sessions", "purge_expired_source_text", "purge_slack_buffers"]);
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

it("purges only the bounded 30-day bridge command batch", async () => {
  const { args } = fakeAdmin({ bridge: 3 });
  const response = await cron();
  expect(await response.json()).toMatchObject({ bridge_commands_purged: 3 });
  const { p_before, p_limit } = args.purge_bridge_commands as { p_before: string; p_limit: number };
  expect(Math.abs(new Date(p_before).getTime() - retentionCutoff(new Date(), 30).getTime())).toBeLessThan(60_000);
  expect(p_limit).toBe(5000);
});
it("contains bridge purge errors without logging exception content", async () => {
  vi.spyOn(console, "error").mockImplementation(() => {});
  const { calls } = fakeAdmin({ bridge: new Error("PRIVATE-BRIDGE-TEXT") });
  const response = await cron();
  expect(response.status).toBe(500);
  expect(await response.json()).toMatchObject({ bridge_commands_purged: null });
  expect(calls).toContain("purge_slack_buffers");
  expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
  expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain("PRIVATE-BRIDGE-TEXT");
});

it("U6 purges a bounded 30-day path lease batch", async () => {
  const { args } = fakeAdmin({ paths: 4 });
  const response = await cron();
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ path_leases_purged: 4 });
  const { p_before, p_limit } = args.purge_agent_path_leases as { p_before: string; p_limit: number };
  expect(Math.abs(new Date(p_before).getTime() - retentionCutoff(new Date(), 30).getTime())).toBeLessThan(60_000);
  expect(p_limit).toBe(5000);
});
it("U6 contains path purge errors, preserves remaining cleanup and records retry HTTP 500", async () => {
  vi.spyOn(console, "error").mockImplementation(() => {});
  const { calls } = fakeAdmin({ paths: new Error("PRIVATE-PATH-TEXT") });
  const response = await cron();
  expect(response.status).toBe(500);
  expect(await response.json()).toMatchObject({ path_leases_purged: null });
  expect(calls).toContain("purge_slack_buffers");
  expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
  expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "path_lease_purge_failed" }));
});

it("purges unconfirmed email sign-ups once a day with no arguments and reports only the count", async () => {
  const { calls, args } = fakeAdmin({ signups: 7 });
  const response = await cron();
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ unconfirmed_email_signups_deleted: 7 });
  expect(calls.filter((fn) => fn === "purge_unconfirmed_email_signups")).toHaveLength(1);
  expect(args.purge_unconfirmed_email_signups).toBeUndefined();
});
it("contains the sign-up purge error without logging exception content, keeps cleaning and records retry HTTP 500", async () => {
  vi.spyOn(console, "error").mockImplementation(() => {});
  const { calls } = fakeAdmin({ signups: new Error("PRIVATE-EMAIL someone@example.com") });
  const response = await cron();
  expect(response.status).toBe(500);
  expect(await response.json()).toMatchObject({ unconfirmed_email_signups_deleted: null });
  expect(calls).toContain("purge_slack_buffers");
  expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
  expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "unconfirmed_email_signup_purge_failed" }));
  expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain("someone@example.com");
});

// 정리 함수가 아직 없는 동안(마이그레이션 20261201000000을 여는 날 적용한다, 코드는 먼저 배포된다)에는 cron이 매일 500을 내지 않는다 (준비 여부 게이트).
// PostgREST는 없는 함수를 PGRST202(스키마 캐시에 없음), Postgres는 42883(undefined_function)로 알린다. 그 밖의 실제 오류는 그대로 500으로 보고한다.
const withCode = (code: string, message: string) => Object.assign(new Error(message), { code });

it("does not fail the whole cron while the sign-up purge function does not exist yet (PGRST202), and logs nothing", async () => {
  const error = vi.spyOn(console, "error").mockImplementation(() => {});
  const { calls } = fakeAdmin({
    signups: withCode("PGRST202", "Could not find the function public.purge_unconfirmed_email_signups without parameters in the schema cache"),
  });
  const response = await cron();
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ unconfirmed_email_signups_deleted: 0, unconfirmed_email_signups_ready: false });
  expect(calls).toContain("purge_slack_buffers");
  expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
  expect(error).not.toHaveBeenCalled();
});

it("does not treat Postgres undefined_function (42883) as not ready: it may be a bug inside the function, so it warns and stays a failure (HTTP 500)", async () => {
  const error = vi.spyOn(console, "error").mockImplementation(() => {});
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  const { calls } = fakeAdmin({ signups: withCode("42883", "function pg_catalog.PRIVATE-EMAIL someone@example.com(text) does not exist") });
  const response = await cron();
  expect(response.status).toBe(500);
  expect(await response.json()).toMatchObject({ unconfirmed_email_signups_deleted: null, unconfirmed_email_signups_ready: true });
  expect(calls).toContain("purge_slack_buffers");
  expect(warn).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "unconfirmed_email_signup_purge_undefined_function" }));
  expect(error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "unconfirmed_email_signup_purge_failed" }));
  expect(JSON.stringify([...warn.mock.calls, ...error.mock.calls])).not.toContain("someone@example.com");
});

it("PGRST202 stays silent: no warning, no error", async () => {
  const error = vi.spyOn(console, "error").mockImplementation(() => {});
  const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
  fakeAdmin({ signups: withCode("PGRST202", "Could not find the function public.purge_unconfirmed_email_signups without parameters in the schema cache") });
  const response = await cron();
  expect(response.status).toBe(200);
  expect(warn).not.toHaveBeenCalled();
  expect(error).not.toHaveBeenCalled();
});

it("reports the sign-up purge as ready once the function exists", async () => {
  fakeAdmin({ signups: 3 });
  const response = await cron();
  expect(await response.json()).toMatchObject({ unconfirmed_email_signups_deleted: 3, unconfirmed_email_signups_ready: true });
});

it("still reports a real sign-up purge error (timeout, permission) as HTTP 500 with the event log", async () => {
  for (const [code, message] of [
    ["57014", "canceling statement due to statement timeout"],
    ["42501", "permission denied for table users"],
    ["XX000", "PRIVATE-EMAIL someone@example.com"],
    ["PGRST301", "JWT expired"],
  ]) {
    vi.restoreAllMocks();
    vi.spyOn(Date, "now").mockImplementation(() => now);
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.mocked(checkSlackConnectionTokens).mockResolvedValue({ checked: 0, revoked: 0, failed: 0 });
    const { calls } = fakeAdmin({ signups: withCode(code, message) });
    const response = await cron();
    expect(response.status, code).toBe(500);
    expect(await response.json(), code).toMatchObject({ unconfirmed_email_signups_deleted: null });
    expect(calls, code).toContain("purge_slack_buffers");
    expect(console.error, code).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "unconfirmed_email_signup_purge_failed" }));
    expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain("someone@example.com");
  }
});

// 외부 세션 목록(제목)의 보관 정리 (OA 외부 세션 PR1, 마이그레이션 20261203000000): 마지막 보고 뒤 14일, 한 번에 5000개
it("purges stale external session titles after 14 days in a bounded batch and reports only the count", async () => {
  const { calls, args } = fakeAdmin({ external: 5 });
  const response = await cron();
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ external_sessions_purged: 5, external_sessions_ready: true });
  expect(calls.filter((fn) => fn === "purge_external_sessions")).toHaveLength(1);
  const { p_before, p_limit } = args.purge_external_sessions as { p_before: string; p_limit: number };
  expect(Math.abs(new Date(p_before).getTime() - retentionCutoff(new Date(), 14).getTime())).toBeLessThan(60_000);
  expect(p_limit).toBe(5000);
});

it("contains the external session purge error without logging exception content, keeps cleaning and records retry HTTP 500", async () => {
  vi.spyOn(console, "error").mockImplementation(() => {});
  const { calls } = fakeAdmin({ external: new Error("PRIVATE-TITLE Fix launcher focus") });
  const response = await cron();
  expect(response.status).toBe(500);
  expect(await response.json()).toMatchObject({ external_sessions_purged: null });
  expect(calls).toContain("purge_slack_buffers");
  expect(checkSlackConnectionTokens).toHaveBeenCalledOnce();
  expect(console.error).toHaveBeenCalledExactlyOnceWith(JSON.stringify({ event: "external_session_purge_failed" }));
  expect(JSON.stringify(vi.mocked(console.error).mock.calls)).not.toContain("Fix launcher");
});

it("does not fail the whole cron while the external session purge function does not exist yet (PGRST202)", async () => {
  const error = vi.spyOn(console, "error").mockImplementation(() => {});
  fakeAdmin({ external: withCode("PGRST202", "Could not find the function public.purge_external_sessions(p_before, p_limit) in the schema cache") });
  const response = await cron();
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ external_sessions_purged: 0, external_sessions_ready: false });
  expect(error).not.toHaveBeenCalled();
});
