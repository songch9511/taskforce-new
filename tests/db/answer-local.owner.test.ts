import { createHash } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

// OA F2 T3 대조: 같은 fixture에서 TS 앞단(bridgeOwnsSession)과 SQL 래퍼가 같은 뜻으로 거르는지, 그리고 운영 TS(answerSecretLocally)가 실제 SQL(PGlite) 위에서 도는지.
vi.mock("server-only", () => ({}));
const holder = vi.hoisted(() => ({ admin: undefined as unknown }));
vi.mock("@/lib/supabase/admin", () => ({ createAdminClient: () => holder.admin }));

import { answerSecretLocally } from "@/lib/bridge/answer-local";
import { bridgeOwnsSession } from "@/lib/bridge/auth";

import { pgliteAgentAdmin } from "./agent-conversation-pglite-admin";
import { answerLocalFixtures, BOTH, REQUEST, sha256 } from "./answer-local.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

const SECRET = "A".repeat(43);
const SECRET_HASH = createHash("sha256").update(SECRET).digest("hex");
let db: PGlite;
let rpcs: string[];
const handle = () => ({ query: async (sql: string, params?: unknown[]) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: <T,>(user: string, fn: () => Promise<T>) => asUser(db, user, fn) });
const f = answerLocalFixtures(handle);
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
beforeEach(() => { rpcs = []; holder.admin = pgliteAgentAdmin(handle(), { before: async (name) => { rpcs.push(name); } }); });

/** 이 세계의 모든 bridge가 같은 기기 secret을 쓰는 것으로 둔다 (secret 비교 자체는 auth.test.ts가 본다) */
async function world() {
  const w = await f.secretWorld();
  await f.q("update public.bridges set secret_hash=$2 where id=$1", [w.bridge, SECRET_HASH]);
  return w;
}
async function otherBridge(user: string) {
  const bridge = await f.bridge(user);
  await f.q("update public.bridges set secret_hash=$2 where id=$1", [bridge, SECRET_HASH]);
  return bridge;
}

type World = Awaited<ReturnType<typeof world>>;
type Caller = { user: string; bridge: string };
/** [이름, 준비(부르는 쪽을 돌려줌), TS 앞단, SQL 래퍼] — 차이는 표로 단언한다 */
const table: [string, (w: World) => Promise<Partial<Caller>>, boolean, string][] = [
  ["주인 bridge", async () => ({}), true, "answered"],
  ["같은 사용자의 다른 bridge", async (w) => ({ bridge: await otherBridge(w.user) }), false, "not_found"],
  ["연결이 bridge에 묶여 있지 않음", async (w) => { await f.q("update public.agent_connections set bridge_id=null where id=$1", [w.connection]); return {}; }, false, "not_found"],
  ["bridge 폐기(secret 지움)", async (w) => { await f.q("update public.bridges set status='revoked', revoked_at=now(), secret_hash=null where id=$1", [w.bridge]); return {}; }, false, "not_found"],
  ["남의 사용자", async () => ({ user: await f.user() }), false, "not_found"],
  // TS는 닫힌(closed) · 외부(external) 세션을 앞단에서 거른다 → 404. SQL은 같은 세션을 잠근 채로 보고 stale로 답한다 (둘 다 쓰기 0)
  ["세션 closed", async (w) => { await f.updateRow("agent_sessions", w.session, { status: "closed" }); return {}; }, false, "stale"],
  ["세션 external", async (w) => { await f.updateRow("agent_sessions", w.session, { status: "external" }); return {}; }, false, "stale"],
  // TS는 연결 상태를 보지 않는다(통과). SQL은 answer_agent_question이 연결 active를 요구해 stale (QS:218)
  ["연결 error", async (w) => { await f.updateRow("agent_connections", w.connection, { status: "error" }); return {}; }, true, "stale"],
  ["연결 revoked(bridge는 active)", async (w) => { await f.updateRow("agent_connections", w.connection, { status: "revoked" }); return {}; }, true, "stale"],
];

describe("T3 대조: TS bridgeOwnsSession ↔ SQL 래퍼", () => {
  it.each(table)("%s", async (_name, arrange, ts, sql) => {
    const w = await world();
    const caller = { user: w.user, bridge: w.bridge, ...(await arrange(w)) };
    expect(await bridgeOwnsSession(caller.user, caller.bridge, SECRET, w.session)).toBe(ts);
    const result = await f.local(w, caller);
    expect(result.status).toBe(sql);
    // 불변식: TS가 거르면 SQL은 어떤 경우에도 쓰지 않는다 (answered가 아니다)
    if (!ts) expect(result.status).not.toBe("answered");
    // SQL이 not_found면 TS도 거른다 (SQL 앞단은 TS보다 넓게 거르지 않는다)
    if (result.status === "not_found") expect(ts).toBe(false);
  });
});

describe("answerSecretLocally: 운영 TS를 실제 SQL 위에서", () => {
  const input = (w: World, over: Partial<{ bridge_id: string; agent_task_id: string; request_digest: string }> = {}) => ({
    bridge_id: w.bridge, agent_task_id: w.task, request_digest: sha256(REQUEST), ...over,
  });
  const run = (w: World, over: Parameters<typeof input>[1] = {}, secret = SECRET, adapters: string[] = BOTH) =>
    answerSecretLocally(holder.admin as never, { userId: w.user, bridgeId: over.bridge_id ?? w.bridge, deviceSecret: secret, input: input(w, over), adapters });

  it("주인 Mac: answered → 같은 요청을 다시 보내면 duplicate(같은 step), 답 단계는 하나", async () => {
    const w = await world();
    const first = await run(w);
    expect(first).toEqual({ status: "answered", step_id: expect.any(String) });
    expect(await run(w)).toEqual({ status: "duplicate", step_id: (first as { step_id: string }).step_id });
    expect(await f.answerSteps(w.task)).toHaveLength(1);
    expect(rpcs.filter((name) => name === "answer_agent_question_locally")).toHaveLength(2);
  });

  it("다른 Mac · 틀린 secret · 폐기된 bridge: not_found이고 RPC를 부르지 않는다", async () => {
    const w = await world();
    const before = await f.all(w.user);
    const stranger = await otherBridge(w.user);
    expect(await run(w, { bridge_id: stranger })).toEqual({ status: "not_found" });
    expect(await run(w, {}, "B".repeat(43))).toEqual({ status: "not_found" });
    await f.q("update public.bridges set status='revoked', revoked_at=now(), secret_hash=null where id=$1", [w.bridge]);
    expect(await run(w)).toEqual({ status: "not_found" });
    expect(rpcs).toEqual([]);
    expect(await f.all(w.user)).toEqual(before);
  });

  it("없는 작업 · 남의 작업: not_found이고 RPC를 부르지 않는다", async () => {
    const w = await world();
    expect(await run(w, { agent_task_id: "00000000-0000-4000-8000-000000000000" })).toEqual({ status: "not_found" });
    const other = await world();
    expect(await run(w, { agent_task_id: other.task })).toEqual({ status: "not_found" });
    expect(rpcs).toEqual([]);
  });

  it("adapter 목록 밖: TS 앞단은 통과해도 SQL이 not_found", async () => {
    const w = await world();
    expect(await run(w, {}, SECRET, ["agent:claude-code"])).toEqual({ status: "not_found" });
    expect(rpcs).toEqual(["answer_agent_question_locally"]);
  });
});

describe("answerSecretLocally 결과 모양", () => {
  it("stale은 이유와 함께 그대로 돌려준다", async () => {
    const w = await world();
    const result = await answerSecretLocally(holder.admin as never, {
      userId: w.user, bridgeId: w.bridge, deviceSecret: SECRET, adapters: BOTH,
      input: { bridge_id: w.bridge, agent_task_id: w.task, request_digest: sha256("other") },
    });
    expect(result).toEqual({ status: "stale", reason: "question_closed" });
  });
});
