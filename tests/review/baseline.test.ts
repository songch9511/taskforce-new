import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { returnSummaryResponseSchema, type ReturnSummaryResponse } from "@/lib/api/contract";
import { encodeCursor } from "@/lib/review/cursor";
import { encodeInitToken } from "@/lib/review/init-token";
import { clearReturnSummary, initializeReturnSummaryBaseline, loadReturnSummary } from "@/lib/review/return-summary";
import { RETURN_SUMMARY_MAX_WORKS } from "@/lib/review/review.config";

import { adminOf, createCoordinatorDb, seed, setClock } from "../coordinator/support";

// 복귀 요약의 첫 정상 표시 기준점 (A–D 후속 C): 실제 SQL(PGlite) 위에서 운영 TS(loadReturnSummary · initializeReturnSummaryBaseline)를 그대로 돈다.
// GET은 읽기만 한다. 기준점은 서버가 발급한 토큰의 별도 확정 쓰기로만 생긴다: 그때까지의 run 결과 · 읽은 시각이 없는 대화 메시지 이력만 (사건, 작업) 쌍으로 읽음 처리하고,
// 미열람 Action 변화 · 미결정은 건드리지 않는다. 기준점 뒤에는 Clear를 한 번도 누르지 않아도 새 run 결과 · 메시지가 나온다.
// 실제 Postgres 두 연결 경합(commit 사이 · 두 기기)은 tests/pg/review-summary.test.ts.

let db: PGlite;
let admin: SupabaseClient;
let s: ReturnType<typeof seed>;

beforeAll(async () => {
  db = await createCoordinatorDb();
  admin = adminOf(db);
  s = seed(db);
}, 60_000);
afterAll(() => db.close());

const NOW = new Date("2026-10-12T21:00:00Z");
const H = "2026-10-12T20:00:00.000000Z";
const load = (user: string, horizon = H, client: SupabaseClient = admin) => loadReturnSummary(client, user, NOW, { horizon });
const confirm = (user: string, token: string | null, client: SupabaseClient = admin) => initializeReturnSummaryBaseline(client, user, token!, NOW.toISOString());
const clear = (user: string, cursor: string | null) => clearReturnSummary(admin, user, cursor!, NOW.toISOString());
const summary = (body: ReturnSummaryResponse) => returnSummaryResponseSchema.parse(body);
const event = (user: string, action: string, type: string, actor: string, at: string) =>
  s.id(`insert into public.action_events (user_id, action_id, type, actor, created_at) values ($1, $2, $3, $4, $5) returning id`, [user, action, type, actor, at]);
const reads = (user: string) => s.count(`select 1 from public.return_summary_reads where user_id = $1`, [user]);
const baselineRows = (user: string) => s.count(`select 1 from public.return_summary_baseline where user_id = $1`, [user]);
const kinds = (body: ReturnSummaryResponse, action: string) => body.items.find((i) => i.action_id === action)?.changes.map((c) => `${c.source}:${c.kind}`) ?? null;

/** run 결과를 정해진 DB 시각에 만든다 (done · draft_ready) */
async function finishRun(user: string, action: string, at: string, outcome = "draft_ready"): Promise<string> {
  await setClock(db, new Date("2026-10-12T00:00:00Z"));
  const run = await s.run(user, action);
  await setClock(db, new Date(at));
  await s.q(`update public.execution_runs set state = 'running' where id = $1`, [run]);
  await s.q(`update public.execution_runs set state = 'done', outcome = $2 where id = $1`, [run, outcome]);
  await setClock(db, new Date("2026-10-12T00:00:00Z"));
  return run;
}
const message = async (user: string, conversation: string, seq: number, action: string, at: string, role = "assistant") =>
  s.q(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, created_at) values ($1, $2, $3, $4, '답', $5, $6)`, [user, conversation, seq, role, JSON.stringify({ action_ids: [action] }), at]);

/** 첫 사용: 옛 run 결과 · 옛 메시지(읽은 시각 없음) 이력, 미열람 Action 변화 하나, 미결정(확인 요청) 하나. Clear한 적도 기준점도 없다 */
async function firstUse() {
  const user = await s.user();
  const worked = await s.action(user, { title: "초안 작성" });
  const changed = await s.action(user, { title: "견적서 보내기" });
  const asked = await s.action(user, { title: "확인이 필요한 일", needsConfirmation: true });
  await finishRun(user, worked, "2026-10-12T10:00:00Z");
  const conversation = await s.conversation(user);
  await message(user, conversation, 1, worked, "2026-10-12T11:00:00Z");
  await event(user, changed, "due_changed", "ai", "2026-10-12T12:00:00.000000Z");
  return { user, worked, changed, asked, conversation };
}

describe("첫 정상 표시 기준점: GET은 읽기만, 토큰으로 확정", () => {
  it("never_cleared 첫 GET은 init_token을 준다 (읽기만: 아무것도 쓰지 않는다). 옛 run · 메시지는 변화로 오르지 않고 미열람 Action 변화 · 미결정은 보인다", async () => {
    const { user, worked, changed, asked } = await firstUse();
    const before = await s.count(`select 1 from public.return_summary_reads`) + (await baselineRows(user));
    const body = summary(await load(user));
    expect(body).toMatchObject({ baseline: "never_cleared", since: null, complete: true, sources: { changes: "ok", decisions: "ok" } });
    expect(body.init_token).toMatch(/^i1\./);
    expect(kinds(body, changed)).toEqual(["action_event:due_changed"]);
    expect(kinds(body, asked)).toEqual([]);
    expect(kinds(body, worked)).toBeNull(); // 옛 run 결과 · 옛 메시지 이력은 변화가 아니다
    expect(await s.count(`select 1 from public.return_summary_reads`) + (await baselineRows(user))).toBe(before);
    await load(user); // 몇 번을 읽어도 같다
    expect(await baselineRows(user)).toBe(0);
  });

  it("확정하면 initialized + applied: 그때까지의 run · 메시지 이력만 (사건, 작업) 쌍으로 읽음이고 Action 변화 · 미결정은 그대로다", async () => {
    const { user, worked, changed, asked } = await firstUse();
    const first = summary(await load(user));
    expect(await confirm(user, first.init_token)).toEqual({ status: "initialized", applied: true });
    expect(await baselineRows(user)).toBe(1);
    expect(await s.q(`select source from public.return_summary_reads where user_id = $1 order by 1`, [user])).toEqual([{ source: "message" }, { source: "run_event" }]);
    const second = summary(await load(user, "2026-10-12T20:30:00.000000Z"));
    expect(second).toMatchObject({ baseline: "initialized", since: null, init_token: null, complete: true });
    // 미열람 Action 변화 · 미결정은 확정 뒤에도 그대로
    expect(kinds(second, changed)).toEqual(["action_event:due_changed"]);
    expect(second.items.find((i) => i.action_id === asked)).toMatchObject({ needs_answer: true });
    expect(kinds(second, worked)).toBeNull(); // 옛 이력은 계속 과거다
  });

  it("확정 뒤에는 Clear를 한 번도 누르지 않아도 새 run 결과 · 새 메시지가 요약에 나온다", async () => {
    const { user, worked, conversation } = await firstUse();
    const first = summary(await load(user));
    expect(await confirm(user, first.init_token)).toMatchObject({ applied: true });
    await finishRun(user, worked, "2026-10-12T20:10:00Z", "needs_input");
    await message(user, conversation, 2, worked, "2026-10-12T20:20:00.000000Z", "event");
    const later = summary(await load(user, "2026-10-12T20:30:00.000000Z"));
    expect(later.baseline).toBe("initialized");
    expect(kinds(later, worked)).toEqual(["run:done", "message:event"]);
    expect(later.items.find((i) => i.action_id === worked)!.changes[0]).toMatchObject({ detail: "needs_input" });
    expect(await s.count(`select 1 from public.return_summary_state where user_id = $1`, [user])).toBe(0); // Clear는 하지 않았다
  });

  it("기준점이 없던 때는 같은 새 결과가 보이지 않는다 (대조): 확정 전에는 Clear 없이 run · 메시지가 오르지 않는다", async () => {
    const { user, worked, conversation } = await firstUse();
    await finishRun(user, worked, "2026-10-12T20:10:00Z");
    await message(user, conversation, 2, worked, "2026-10-12T20:20:00.000000Z");
    expect(kinds(summary(await load(user, "2026-10-12T20:30:00.000000Z")), worked)).toBeNull();
  });

  it("빈 첫 화면에도 토큰이 나오고 확정된다 (읽은 쌍 0, 기준점 행 1). 확정 뒤 새 결과가 나온다", async () => {
    const user = await s.user();
    const first = summary(await load(user));
    expect(first).toMatchObject({ complete: true, empty: true, baseline: "never_cleared" });
    expect(first.init_token).toMatch(/^i1\./);
    expect(await confirm(user, first.init_token)).toEqual({ status: "initialized", applied: true });
    expect(await reads(user)).toBe(0);
    expect(await baselineRows(user)).toBe(1);
    const action = await s.action(user);
    await finishRun(user, action, "2026-10-12T20:10:00Z");
    expect(kinds(summary(await load(user, "2026-10-12T20:30:00.000000Z")), action)).toEqual(["run:done"]);
  });

  it("작업이 많아 잘린 첫 화면(truncated)에도 토큰이 나온다: 확정은 run · 메시지 이력만 다루고 Action 변화는 읽음이 아니다", async () => {
    const user = await s.user();
    await s.q(
      `with a as (insert into public.actions (user_id, title) select $1, '일 ' || g from generate_series(1, $2::int) g returning id)
       insert into public.action_events (user_id, action_id, type, actor, created_at) select $1, id, 'merged', 'ai', '2026-10-12T01:00:00Z' from a`,
      [user, RETURN_SUMMARY_MAX_WORKS + 3],
    );
    const first = summary(await load(user));
    expect(first).toMatchObject({ complete: false, sources: { changes: "truncated" }, baseline: "never_cleared" });
    expect(first.init_token).toMatch(/^i1\./);
    expect(first.cursor).not.toBeNull();
    expect(await confirm(user, first.init_token)).toMatchObject({ status: "initialized" });
    expect(await reads(user)).toBe(0);
    expect(summary(await load(user)).items).toHaveLength(RETURN_SUMMARY_MAX_WORKS);
  });
});

describe("토큰은 한 번만 효력이 있고, 두 기기 · 재시도는 아무것도 다시 쓰지 않는다", () => {
  it("같은 토큰을 다시 보내면(응답 유실 재시도) already_initialized · applied false이고 아무것도 쓰지 않는다", async () => {
    const { user } = await firstUse();
    const first = summary(await load(user));
    expect(await confirm(user, first.init_token)).toMatchObject({ applied: true });
    const rows = [await reads(user), await baselineRows(user)];
    expect(await confirm(user, first.init_token)).toEqual({ status: "already_initialized", applied: false });
    expect([await reads(user), await baselineRows(user)]).toEqual(rows);
  });

  it("두 기기가 다른 시점의 토큰으로 확정: 먼저 온 쪽만 applied이고 뒤는 already_initialized. 두 지평 사이에 생긴 결과는 읽음이 아니다 (표시된 적이 없다)", async () => {
    const { user, worked } = await firstUse();
    const deviceA = summary(await load(user, "2026-10-12T15:00:00.000000Z"));
    await finishRun(user, worked, "2026-10-12T16:00:00Z");
    const deviceB = summary(await load(user, "2026-10-12T17:00:00.000000Z"));
    expect(await confirm(user, deviceA.init_token)).toEqual({ status: "initialized", applied: true });
    expect(await confirm(user, deviceB.init_token)).toEqual({ status: "already_initialized", applied: false });
    // 기준점은 A의 지평(15:00)이다: 16:00의 run 결과는 새 변화로 보인다
    expect(kinds(summary(await load(user, "2026-10-12T20:00:00.000000Z")), worked)).toEqual(["run:done"]);
  });

  it("이미 Clear한 사용자(업그레이드 이전 사용자 포함)는 초기화된 것으로 본다: baseline cleared · 토큰 없음, 어떤 토큰으로도 쓰지 않고 기존 읽음은 그대로", async () => {
    const { user, changed } = await firstUse();
    const first = summary(await load(user));
    expect(first.cursor).not.toBeNull();
    expect((await clear(user, first.cursor)).status).toBe("cleared"); // 기준점 확정 전에 Clear: 기준점도 함께 만든다
    const afterClear = summary(await load(user, "2026-10-12T20:30:00.000000Z"));
    expect(afterClear).toMatchObject({ baseline: "cleared", init_token: null });
    const rows = [await reads(user), await baselineRows(user)];
    expect(await confirm(user, first.init_token)).toEqual({ status: "already_initialized", applied: false });
    expect([await reads(user), await baselineRows(user)]).toEqual(rows);
    expect(kinds(afterClear, changed)).toBeNull(); // Clear로 읽은 변화는 그대로 읽음
  });

  it("기준점 뒤 Clear는 기준점 이력을 다시 다루지 않는다: 읽음 쌍은 기준점 때 것이 그대로이고 Clear한 변화만 더해진다", async () => {
    const { user, worked, changed } = await firstUse();
    const first = summary(await load(user));
    expect(await confirm(user, first.init_token)).toMatchObject({ applied: true });
    const baselineReads = await reads(user);
    const second = summary(await load(user, "2026-10-12T20:30:00.000000Z"));
    expect(second.cursor).not.toBeNull();
    expect((await clear(user, second.cursor)).status).toBe("cleared");
    expect(await reads(user)).toBe(baselineReads + 1); // 미열람 Action 변화 하나만 새로 읽음
    const third = summary(await load(user, "2026-10-12T20:40:00.000000Z"));
    expect(third.baseline).toBe("cleared");
    expect(kinds(third, changed)).toBeNull();
    expect(kinds(third, worked)).toBeNull();
  });
});

describe("확정은 본 집합이 그대로일 때만 (digest), 늦은 commit · tie · 마이크로초", () => {
  it("조회 뒤 확정 전에 기준점 범위의 사건이 늦게 commit되면(지평 이전 시각) conflict이고 아무것도 쓰지 않는다. 다시 조회해 확정하면 그 사건도 기준점이다", async () => {
    const { user, worked } = await firstUse();
    const first = summary(await load(user));
    await finishRun(user, worked, "2026-10-12T13:00:00Z"); // 지평(20:00)보다 이른 시각의 늦은 run 결과
    expect(await confirm(user, first.init_token)).toEqual({ status: "stale" });
    expect([await reads(user), await baselineRows(user)]).toEqual([0, 0]);
    const second = summary(await load(user));
    expect(await confirm(user, second.init_token)).toMatchObject({ status: "initialized", applied: true });
    expect(kinds(summary(await load(user)), worked)).toBeNull();
  });

  it("같은 시각 tie: 지평과 정확히 같은 시각의 사건이 조회 뒤에 보이면 conflict, 지평보다 1µs 뒤면 범위 밖이라 확정되고 기준점 뒤 새 변화로 보인다", async () => {
    const { user, worked, conversation } = await firstUse();
    const first = summary(await load(user));
    await message(user, conversation, 2, worked, H); // 지평과 같은 시각
    expect(await confirm(user, first.init_token)).toEqual({ status: "stale" });
    const second = summary(await load(user));
    await message(user, conversation, 3, worked, "2026-10-12T20:00:00.000001Z"); // 1µs 뒤
    expect(await confirm(user, second.init_token)).toMatchObject({ status: "initialized", applied: true });
    expect(kinds(summary(await load(user, "2026-10-12T20:30:00.000000Z")), worked)).toEqual(["message:assistant"]);
  });

  it("범위 안 작업이 지워져도 conflict (다시 조회하면 확정된다: 영구히 잠기지 않는다)", async () => {
    const { user, worked } = await firstUse();
    const first = summary(await load(user));
    await s.q(`delete from public.actions where id = $1`, [worked]);
    expect(await confirm(user, first.init_token)).toEqual({ status: "stale" });
    expect(await confirm(user, summary(await load(user)).init_token)).toMatchObject({ status: "initialized" });
  });
});

describe("토큰 위조 · 읽기 실패", () => {
  it("남의 토큰 · 깨진 토큰 · 다른 종류의 글자(Clear 커서) · 옛 형식 · 미래 지평은 invalid이고 아무것도 쓰지 않는다. digest가 틀리면 conflict", async () => {
    const { user } = await firstUse();
    const other = await s.user();
    const mine = summary(await load(user));
    expect(await confirm(other, mine.init_token)).toEqual({ status: "invalid" });
    for (const bad of ["", "i1.garbage", "c3.AAAA", "i0.AAAA", "토큰"]) expect(await confirm(user, bad), bad).toEqual({ status: "invalid" });
    const future = encodeInitToken({ userId: user, horizon: "2999-01-01T00:00:00.000000Z", digest: "a:0:0|r:0:0|m:0:0" });
    expect(await confirm(user, future)).toEqual({ status: "invalid" });
    const cursor = encodeCursor({ userId: user, horizon: H, digest: "a:0:0|r:0:0|m:0:0", page: null, baseline: true });
    expect(await confirm(user, cursor)).toEqual({ status: "invalid" }); // Clear 커서는 토큰이 아니다
    const forged = encodeInitToken({ userId: user, horizon: H, digest: "a:0:0|r:0:0|m:0:0" });
    expect(await confirm(user, forged)).toEqual({ status: "stale" });
    expect([await reads(user), await baselineRows(user)]).toEqual([0, 0]);
  });

  it("변화 원천 읽기가 실패하면 토큰이 없다 (baseline unknown). 결정 대기 읽기만 실패하면 변화는 정상이라 토큰은 나온다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { user } = await firstUse();
    const failing = (fn: string): SupabaseClient =>
      new Proxy(admin, { get: (target, prop) => (prop === "rpc" ? (name: string, args: Record<string, unknown>) => { if (name === fn) throw new Error("down"); return target.rpc(name, args); } : Reflect.get(target, prop)) });
    const noChanges = summary(await load(user, H, failing("return_summary_scan")));
    expect(noChanges).toMatchObject({ baseline: "unknown", init_token: null, complete: false, sources: { changes: "unavailable" } });
    const noDecisions = summary(await load(user, H, failing("coordinator_pending_inputs")));
    expect(noDecisions.init_token).toMatch(/^i1\./);
    expect(noDecisions).toMatchObject({ complete: false, sources: { changes: "ok", decisions: "unavailable" } });
    vi.restoreAllMocks();
  });

  it("확정 쓰기가 실패하면 예외로 알린다 (성공으로 꾸미지 않는다)", async () => {
    const { user } = await firstUse();
    const first = summary(await load(user));
    const failing = new Proxy(admin, { get: (target, prop) => (prop === "rpc" ? () => { throw new Error("down"); } : Reflect.get(target, prop)) });
    await expect(confirm(user, first.init_token, failing)).rejects.toThrow();
    expect(await baselineRows(user)).toBe(0);
  });
});

describe("확정은 읽음 표시일 뿐이다 (Claim · Action · run · 승인 · 정책 · 제안을 건드리지 않는다)", () => {
  it("확정 전후 업무 · 실행 · 사건 표가 한 글자도 같다", async () => {
    const { user, worked } = await firstUse();
    await s.q(`insert into public.suggestions (user_id, kind, action_id, subject_key, revision, dedup_key, urgent) values ($1, 'due_window', $2, 'action:x', '1', $3, true)`, [user, worked, `due_window:action:${worked}:1`]);
    const tables = ["actions", "action_events", "claims", "evidence", "sources", "execution_runs", "execution_steps", "execution_approvals", "execution_intents", "execution_events", "inbox_events", "conversations", "conversation_messages", "suggestions"];
    const snapshot = async () => JSON.stringify(await Promise.all(tables.map((t) => s.q(`select to_jsonb(x) as row from public.${t} x where user_id = $1 order by 1`, [user]))));
    const first = summary(await load(user));
    const before = await snapshot();
    expect(await confirm(user, first.init_token)).toMatchObject({ applied: true });
    expect(await snapshot()).toBe(before);
  });
});
