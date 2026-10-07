import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { ActionNotFoundError, saveActionNotes } from "./service";
import { WriteConflictError } from "./db-store";

const ACTION_ID = "11111111-1111-4111-8111-111111111111";
const USER_ID = "22222222-2222-4222-8222-222222222222";

function userClient(visible = true) {
  const calls: string[] = [];
  const query: Record<string, unknown> = {};
  for (const method of ["select", "eq", "maybeSingle"]) {
    query[method] = (...args: unknown[]) => {
      calls.push(`${method}:${args.join(",")}`);
      return query;
    };
  }
  query.throwOnError = async () => ({ data: visible ? { id: ACTION_ID } : null });
  return { client: { from: vi.fn(() => query) } as unknown as SupabaseClient, calls };
}

function adminClient(result: unknown) {
  const rpc = vi.fn(() => ({ throwOnError: async () => ({ data: result }) }));
  return { client: { rpc } as unknown as SupabaseClient, rpc };
}

describe("saveActionNotes", () => {
  it("checks ownership with the user RLS client, then preserves the exact Markdown through the CAS RPC", async () => {
    const user = userClient();
    const admin = adminClient([{ status: "saved", action_id: ACTION_ID, markdown: "  \n## Note\n\n", revision: 1 }]);
    const input = { markdown: "  \n## Note\n\n", expected_revision: 0 };

    await expect(saveActionNotes(user.client, admin.client, USER_ID, ACTION_ID, input)).resolves.toEqual({
      action_id: ACTION_ID,
      markdown: input.markdown,
      revision: 1,
    });
    expect(user.calls).toEqual(["select:id", `eq:id,${ACTION_ID}`, "maybeSingle:"]);
    expect(admin.rpc).toHaveBeenCalledWith("save_action_notes", {
      p_user_id: USER_ID,
      p_action_id: ACTION_ID,
      p_markdown: input.markdown,
      p_expected_revision: 0,
    });
  });

  it("returns 404 semantics for an Action hidden by RLS without calling the RPC", async () => {
    const user = userClient(false);
    const admin = adminClient([]);
    await expect(saveActionNotes(user.client, admin.client, USER_ID, ACTION_ID, { markdown: "x", expected_revision: 0 })).rejects.toBeInstanceOf(ActionNotFoundError);
    expect(admin.rpc).not.toHaveBeenCalled();
  });

  it("maps a stale revision to the existing conflict error and hides an Action deleted between lookup and RPC", async () => {
    const user = userClient();
    const conflict = adminClient([{ status: "conflict", action_id: ACTION_ID, markdown: null, revision: 3 }]);
    await expect(saveActionNotes(user.client, conflict.client, USER_ID, ACTION_ID, { markdown: "x", expected_revision: 2 })).rejects.toBeInstanceOf(WriteConflictError);

    const missing = adminClient([{ status: "not_found", action_id: null, markdown: null, revision: null }]);
    await expect(saveActionNotes(user.client, missing.client, USER_ID, ACTION_ID, { markdown: "x", expected_revision: 2 })).rejects.toBeInstanceOf(ActionNotFoundError);
  });
});
