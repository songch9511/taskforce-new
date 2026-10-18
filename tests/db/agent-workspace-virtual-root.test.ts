import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { agentPathLeaseFixtures } from "./agent-path-leases.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// OA D4a-2 (13.11): Mac은 서버로 가는 모든 경로 칸을 가상 루트 `/taskforce/<ws_id>/…`로 보낸다 (`session_bound.workspace_ref`도 같은 값).
// 서버 도구 판정은 `normalize(workspace_ref)`와 `workspace_real_path`를 비교하고(agent_path_leases.sql), 경로 lease는 bridge별 `path_key`로 충돌을 잡는다 —
// 가상 루트가 그 둘 모두에서 실제 경로와 똑같이 동작하는지 본다. 서버 변경 0.
let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });

describe("agent workspace virtual root (PGlite)", () => {
  const f = agentPathLeaseFixtures(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
  const newRoot = () => `/taskforce/ws_${randomUUID()}`;
  const decision = (root: string, rel = "pricing.mdx", extra: Record<string, unknown> = {}) =>
    ({ workspace_real_path: root, targets: [{ real_path: `${root}/${rel}`, rel_path: rel }], ...extra });

  /** `session_bound`가 가상 루트를 서버에 적은 뒤의 세션 */
  async function liveAt(root: string) {
    const w = await f.world();
    await f.lease(w);
    await f.apply(w.user, f.event(w, "accepted"));
    expect(await f.apply(w.user, f.event(w, "session_bound", { agent_task_id: undefined, turn_seq: undefined, payload: { external_session_id: `ext-${randomUUID()}`, workspace_ref: root } }))).toMatchObject({ applied: true });
    expect(await f.one("select workspace_ref from public.agent_sessions where id=$1", [w.session])).toEqual({ workspace_ref: root });
    return w;
  }

  it("V1 a session bound to the virtual root is judged without workspace_mismatch and its lease key is the virtual path", async () => {
    const root = newRoot();
    const w = await liveAt(root);
    const result = await f.decide(w, decision(root));
    expect(result).toMatchObject({ status: "decided", decision: "defer", reason: "manual_write" });
    expect(result.lease_ids).toHaveLength(1);
    expect((await f.leases(w.run))[0]).toMatchObject({ workspace_ref: root, path_key: `${root}/pricing.mdx`, rel_path: "pricing.mdx", source: "requested" });
  });

  it("V2 a raw absolute path no longer matches the bound virtual root (why the Mac virtualises every path field)", async () => {
    const w = await liveAt(newRoot());
    expect(await f.decide(w)).toMatchObject({ decision: "deny", reason: "workspace_mismatch" });
    expect(await f.leases(w.run)).toEqual([]);
  });

  it("V3 before session_bound (pending) the two-component virtual root passes the pending shape check", async () => {
    const root = newRoot();
    const w = await f.world();
    await f.lease(w);
    await f.apply(w.user, f.event(w, "accepted"));
    expect(String((await f.one("select workspace_ref from public.agent_sessions where id=$1", [w.session])).workspace_ref)).toMatch(/^pending:/);
    expect(await f.decide(w, decision(root))).toMatchObject({ decision: "defer", reason: "manual_write" });
    // 가상 루트가 아닌 한 성분 경로는 pending에서도 거절이다
    expect(await f.decide(w, { workspace_real_path: "/taskforce", targets: [{ real_path: "/taskforce/x", rel_path: "x" }] })).toMatchObject({ decision: "deny", reason: "workspace_mismatch" });
  });

  it("V4 a target outside the virtual root is not leased (the Mac sends the fixed outside placeholder for anything else)", async () => {
    const root = newRoot();
    const w = await liveAt(root);
    const result = await f.decide(w, { workspace_real_path: root, targets: [{ real_path: "/taskforce-outside", rel_path: "x" }] });
    expect(result.lease_ids).toEqual([]);
    expect(await f.leases(w.run)).toEqual([]);
  });

  it("V5 two sessions on the same folder id collide on the same relative path", async () => {
    const root = newRoot();
    const a = await liveAt(root);
    const b = await f.competitor(a);
    await f.updateRow("agent_sessions", b.session, { workspace_ref: root });
    expect(await f.decide(a, decision(root, "pricing.mdx", { lease_op: "acquire" }))).toMatchObject({ decision: "defer" });
    // 대소문자만 다른 같은 경로도 같은 열쇠다 (path_key 접기)
    expect(await f.decide(b, decision(root, "Pricing.mdx"))).toMatchObject({ decision: "deny", reason: "path_in_use", holder: { rel_path: "pricing.mdx" } });
    expect(await f.leases(b.run)).toEqual([]);
  });

  it("V6 sessions on different folder ids do not collide", async () => {
    const a = await liveAt(newRoot());
    const b = await f.competitor(a);
    const other = newRoot();
    await f.updateRow("agent_sessions", b.session, { workspace_ref: other });
    const rootA = String((await f.one("select workspace_ref from public.agent_sessions where id=$1", [a.session])).workspace_ref);
    await f.decide(a, decision(rootA, "pricing.mdx", { lease_op: "acquire" }));
    expect(await f.decide(b, decision(other))).toMatchObject({ decision: "defer", reason: "manual_write" });
  });

  it("V7 observed leases from artifacts use the same virtual key, so a same-folder conflict between two sessions is caught", async () => {
    const root = newRoot();
    const a = await liveAt(root);
    const b = await f.competitor(a);
    await f.updateRow("agent_sessions", b.session, { workspace_ref: root });
    await f.decide(a, decision(root, "pricing.mdx", { lease_op: "acquire" }));
    await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')", [b.user, b.run, b.task, b.turn]);
    const lease = (await f.leases(a.run))[0];
    expect(lease).toMatchObject({ path_key: `${root}/pricing.mdx`, conflict_run_id: b.run });
    expect(await f.q("select props from public.metric_events where user_id=$1 and type='path_conflict_found'", [a.user])).toEqual([{ props: { adapter: "agent:codex" } }]);
  });

  it("V8 an observed artifact of a session on another folder id does not conflict", async () => {
    const root = newRoot();
    const a = await liveAt(root);
    const b = await f.competitor(a);
    await f.updateRow("agent_sessions", b.session, { workspace_ref: newRoot() });
    await f.decide(a, decision(root, "pricing.mdx", { lease_op: "acquire" }));
    await f.q("insert into public.agent_artifacts(user_id,run_id,agent_task_id,turn_seq,path,content_hash,summary) values($1,$2,$3,$4,'pricing.mdx','hash','Changed')", [b.user, b.run, b.task, b.turn]);
    expect((await f.leases(a.run))[0]).toMatchObject({ conflict_run_id: null });
  });

  it("V9 a tool-config path under the virtual root is still caught by relative-name rules", async () => {
    const root = newRoot();
    const w = await liveAt(root);
    expect(await f.decide(w, decision(root, ".git/config", { decision: "allow", reason: "policy_auto", lease_op: "acquire" }))).toMatchObject({ decision: "defer", reason: "tool_config_write" });
  });
});
