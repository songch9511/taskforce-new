import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
vi.mock("server-only", () => ({}));
vi.mock("@/lib/api/auth", () => ({ authenticateRequest: vi.fn() }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: vi.fn() }));
import { verifyBridgeSecret } from "./auth";

describe("bridge device credential", () => {
  const secret = "A".repeat(43);
  const hash = createHash("sha256").update(secret).digest("hex");
  it("compares a digest, never the stored hash as a credential", () => {
    expect(verifyBridgeSecret(secret, hash)).toBe(true);
    expect(verifyBridgeSecret(hash, hash)).toBe(false);
    expect(verifyBridgeSecret("B".repeat(43), hash)).toBe(false);
  });
  it.each([null, "", "bad", "x".repeat(64)])("rejects malformed digest %s", (stored) => {
    expect(verifyBridgeSecret(secret, stored)).toBe(false);
  });
});

import { authenticateRequest } from "@/lib/api/auth";
import { createAdminClient } from "@/lib/supabase/admin";
import { authenticateBridge, bridgeOwnsSession } from "./auth";
import type { SupabaseClient } from "@supabase/supabase-js";
const id = "10000000-0000-4000-8000-000000000001";
function db(bridge: unknown, connection: unknown = { bridge_id: id }) {
  const from = vi.fn((table: string) => {
    const query = { select: vi.fn().mockReturnThis(), eq: vi.fn().mockReturnThis(), maybeSingle: vi.fn().mockReturnThis(),
      throwOnError: vi.fn(async () => ({ data: table === "bridges" ? bridge : table === "agent_sessions" ? { connection_id: id, status: "bound" } : connection })) };
    return query;
  });
  const admin = { from } as unknown as SupabaseClient;
  vi.mocked(createAdminClient).mockReturnValue(admin);
  vi.mocked(authenticateRequest).mockResolvedValue({ user: { id, email: null, name: "Test" }, supabase: admin });
  return admin;
}
describe("account and bridge authority", () => {
  const secret = "A".repeat(43);
  const bridge = { id, status: "active", secret_hash: createHash("sha256").update(secret).digest("hex"), capabilities: {} };
  const request = () => new Request("https://test/", { headers: { "X-Taskforce-Bridge-Secret": secret } });
  it.each([[null, 404], [{ ...bridge, status: "revoked" }, 403], [{ ...bridge, secret_hash: "0".repeat(64) }, 401]] as const)("rejects unavailable device %#", async (row, status) => {
    db(row);
    const result = await authenticateBridge(request(), id);
    expect("error" in result && result.error.status).toBe(status);
  });
  it("requires user authentication before an admin read", async () => {
    db(bridge);
    vi.mocked(createAdminClient).mockClear();
    vi.mocked(authenticateRequest).mockResolvedValue(null);
    expect(await authenticateBridge(request(), id)).toHaveProperty("error.status", 401);
    expect(createAdminClient).not.toHaveBeenCalled();
  });
  it("requires credential and the exact session connection bridge for local secrets", async () => {
    db(bridge);
    expect(await bridgeOwnsSession(id, id, secret, id)).toBe(true);
    expect(await bridgeOwnsSession(id, id, "wrong", id)).toBe(false);
    db(bridge, { bridge_id: "10000000-0000-4000-8000-000000000002" });
    expect(await bridgeOwnsSession(id, id, secret, id)).toBe(false);
  });
});
