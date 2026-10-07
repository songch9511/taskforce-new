import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { ActionNotFoundError, handoffAction } from "./service";

const ACTION_ID = "11111111-1111-4111-8111-111111111111";
const USER_ID = "22222222-2222-4222-8222-222222222222";

function client(options: { action?: boolean; metricError?: boolean; onMetric?: () => void } = {}) {
  const calls: string[] = [];
  const data = {
    title: "Proposal",
    owner: "me",
    status: "open",
    due_date: null,
    counterpart: null,
    confirm_reasons: [],
    resolution: null,
  };
  const db = {
    from(table: string) {
      const query: Record<string, unknown> = {};
      for (const method of ["select", "eq", "order", "limit", "in", "insert", "maybeSingle"]) {
        query[method] = (...args: unknown[]) => {
          if (method === "insert") calls.push(`${table}:insert:${JSON.stringify(args[0])}`);
          if (method === "insert" && table === "metric_events") options.onMetric?.();
          return query;
        };
      }
      query.throwOnError = () => {
        calls.push(`${table}:read`);
        if (table === "actions") return Promise.resolve({ data: options.action === false ? null : data });
        if (table === "evidence") return Promise.resolve({ data: [], count: 0 });
        if (table === "claims") return Promise.resolve({ data: [] });
        if (table === "metric_events" && options.metricError) return Promise.reject(new Error("metric failed"));
        return Promise.resolve({ data: [] });
      };
      return query;
    },
  };
  return { db: db as unknown as SupabaseClient, calls };
}

describe("handoffAction assisted service ordering", () => {
  it("checks Action ownership through the RLS client before generation and writes the metric only after success", async () => {
    const user = client();
    const sequence: string[] = [];
    const admin = client({ onMetric: () => sequence.push("metric") });
    const result = await handoffAction(user.db, admin.db, USER_ID, ACTION_ID, async (markdown) => {
      sequence.push("generate");
      expect(markdown).toContain("# Proposal");
      return {
        markdown: "# Draft\n\n## Reference\n\n" + markdown,
        assessment: { effort: "low", difficulty: "medium", context: "sufficient", model: "typesafe/jev-1.13", rubric_version: "handoff-v1" },
      };
    });
    expect(user.calls[0]).toBe("actions:read");
    expect(sequence).toEqual(["generate", "metric"]);
    expect(admin.calls.some((call) => call.startsWith("metric_events:insert:"))).toBe(true);
    expect(result.markdown).toContain("## Reference");
    expect(result.assessment?.rubric_version).toBe("handoff-v1");
  });

  it("does not invoke AI or record handoff_used for an Action outside the RLS-visible set", async () => {
    const user = client({ action: false });
    const admin = client();
    const assist = vi.fn();
    await expect(handoffAction(user.db, admin.db, USER_ID, ACTION_ID, assist)).rejects.toBeInstanceOf(ActionNotFoundError);
    expect(assist).not.toHaveBeenCalled();
    expect(admin.calls.some((call) => call.startsWith("metric_events:insert:"))).toBe(false);
  });

  it("does not record handoff_used when assisted generation fails", async () => {
    const user = client();
    const admin = client();
    await expect(handoffAction(user.db, admin.db, USER_ID, ACTION_ID, async () => { throw new Error("generation failed"); })).rejects.toThrow();
    expect(admin.calls.some((call) => call.startsWith("metric_events:insert:"))).toBe(false);
  });
});
