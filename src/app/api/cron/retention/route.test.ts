import type { SupabaseClient } from "@supabase/supabase-js";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { checkSlackConnectionTokens } from "@/lib/connectors/slack/run";
import { createAdminClient } from "@/lib/supabase/admin";

import { GET } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn() }));
vi.mock("@/lib/connectors/slack/run", () => ({ checkSlackConnectionTokens: vi.fn() }));

// 원문 정리가 밀려도(매번 한도만큼 지움) Slack 토큰 확인에 떼어 둔 시간은 남는다 (D3: 앱 해제 이벤트를 놓쳤을 때의 안전망).

let now = 0;

/** 부를 때마다 2초가 걸리고, 매번 한도(5000건)만큼 지워 밀린 것이 남는 가짜 service role 클라이언트 */
function busyAdmin() {
  const calls: string[] = [];
  const admin = {
    rpc: (fn: string) => ({
      single: () => ({
        throwOnError: async () => {
          calls.push(fn);
          now += 2_000;
          return fn === "purge_expired_source_text"
            ? { data: { sources_purged: 5000, judge_logs_deleted: 0, rate_limit_events_deleted: 0, missing_reports_deleted: 0 } }
            : { data: { messages_deleted: 5000, threads_deleted: 0, sources_repurged: 0 } };
        },
      }),
    }),
  } as unknown as SupabaseClient;
  vi.mocked(createAdminClient).mockReturnValue(admin as ReturnType<typeof createAdminClient>);
  return calls;
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
    busyAdmin();
    const response = await cron("Bearer wrong!");
    expect(response.status).toBe(401);
    expect(checkSlackConnectionTokens).not.toHaveBeenCalled();
  });

  it("정리가 밀려도 Slack 토큰 확인에 떼어 둔 시간(15초 이상)을 남긴다", async () => {
    const calls = busyAdmin();
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
