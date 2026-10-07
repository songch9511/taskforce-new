import { beforeEach, describe, expect, it, vi } from "vitest";

import { WriteConflictError } from "@/lib/actions/db-store";
import { ActionNotFoundError, saveActionNotes } from "@/lib/actions/service";
import { authenticateRequest } from "@/lib/api/auth";
import { apiErrorSchema } from "@/lib/api/contract";
import { createAdminClient } from "@/lib/supabase/admin";

import { PUT } from "./route";

vi.mock("server-only", () => ({}));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn() }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn() }));
vi.mock("@/lib/actions/service", () => {
  class MockActionNotFoundError extends Error {
    constructor() {
      super("Action이 없습니다.");
      this.name = "ActionNotFoundError";
    }
  }
  return { ActionNotFoundError: MockActionNotFoundError, saveActionNotes: vi.fn() };
});

const ACTION = "11111111-1111-4111-8111-111111111111";
const request = (body: string) => new Request(`https://api.example.dev/api/v1/actions/${ACTION}/notes`, { method: "PUT", body });
const call = (req: Request, id = ACTION) => PUT(req, { params: Promise.resolve({ id }) });

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(authenticateRequest).mockResolvedValue({ user: { id: "user-1", email: null, name: "User" }, supabase: { user: true } as never });
  vi.mocked(createAdminClient).mockReturnValue({ admin: true } as never);
  vi.mocked(saveActionNotes).mockResolvedValue({ action_id: ACTION, markdown: "  # note\n", revision: 2 });
});

describe("PUT /api/v1/actions/:id/notes", () => {
  it("preserves Markdown whitespace and returns the saved notes revision", async () => {
    const markdown = "  # note\n";
    const response = await call(request(JSON.stringify({ markdown, expected_revision: 1 })));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ action_id: ACTION, markdown, revision: 2 });
    expect(saveActionNotes).toHaveBeenCalledWith({ user: true }, { admin: true }, "user-1", ACTION, { markdown, expected_revision: 1 });
  });

  it("rejects invalid ids, oversized UTF-16 content, and invalid revisions before saving", async () => {
    expect((await call(request(JSON.stringify({ markdown: "x", expected_revision: 0 })), "bad-id")).status).toBe(404);
    expect((await call(request(JSON.stringify({ markdown: "x".repeat(10_001), expected_revision: 0 })))).status).toBe(400);
    expect((await call(request(JSON.stringify({ markdown: "x", expected_revision: -1 })))).status).toBe(400);
    expect(saveActionNotes).not.toHaveBeenCalled();
  });

  it("keeps hidden ownership as 404 and reports stale revisions as 409 conflict", async () => {
    vi.mocked(saveActionNotes).mockRejectedValueOnce(new ActionNotFoundError());
    const hidden = await call(request(JSON.stringify({ markdown: "x", expected_revision: 0 })));
    expect(hidden.status).toBe(404);
    expect(apiErrorSchema.parse(await hidden.json()).error.code).toBe("not_found");

    vi.mocked(saveActionNotes).mockRejectedValueOnce(new WriteConflictError());
    const conflict = await call(request(JSON.stringify({ markdown: "x", expected_revision: 0 })));
    expect(conflict.status).toBe(409);
    expect(apiErrorSchema.parse(await conflict.json()).error.code).toBe("conflict");
  });
});
