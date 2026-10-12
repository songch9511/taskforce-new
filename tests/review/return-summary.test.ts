import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { returnSummaryResponseSchema, type ReturnSummaryResponse } from "@/lib/api/contract";
import { encodeCursor } from "@/lib/review/cursor";
import { clearReturnSummary, loadReturnSummary } from "@/lib/review/return-summary";
import { RETURN_SUMMARY_MAX_WORKS } from "@/lib/review/review.config";

import { adminOf, createCoordinatorDb, seed, setClock } from "../coordinator/support";

// 복귀 요약 서버 (C3, A40 · ARCH25 · V04): 실제 SQL(PGlite) 위에서 운영 TS(loadReturnSummary · clearReturnSummary)를 그대로 돈다.
// 사건 시각은 직접 정한다(created_at) — 조회와 Clear 사이의 새 사건 · 같은 시각 tie · 마이크로초 · 늦은 commit을 재현하려는 것이다.

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
const clear = (user: string, cursor: string | null, client: SupabaseClient = admin) => clearReturnSummary(client, user, cursor!, NOW.toISOString());
const event = (user: string, action: string, type: string, actor: string, at: string, source: string | null = null) =>
  s.id(`insert into public.action_events (user_id, action_id, type, actor, created_at, source_id) values ($1, $2, $3, $4, $5, $6) returning id`, [user, action, type, actor, at, source]);
const setCleared = (user: string, at: string) => s.q(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2) on conflict (user_id) do update set cleared_through = excluded.cleared_through`, [user, at]);
const state = async (user: string) => (await s.one(`select to_char(cleared_through at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as at, version from public.return_summary_state where user_id = $1`, [user])) as { at: string; version: number } | undefined;

const fingerprint = async (userId: string) => {
  const tables = ["actions", "action_events", "claims", "evidence", "sources", "execution_runs", "execution_steps", "execution_approvals", "execution_intents", "execution_events", "inbox_events", "conversations", "conversation_messages", "suggestions"];
  const counts = await Promise.all(tables.map(async (t) => `${t}=${await s.count(`select 1 from public.${t} where user_id = $1`, [userId])}`));
  const rows = await Promise.all(
    ["actions", "execution_runs", "execution_steps", "execution_approvals", "execution_intents"].map(async (t) => JSON.stringify(await s.q(`select to_jsonb(x) as row from public.${t} x where user_id = $1 order by 1`, [userId]))),
  );
  return `${counts.join(",")}|${rows.join("|")}`;
};

const summary = (body: ReturnSummaryResponse) => returnSummaryResponseSchema.parse(body);

/** 사용자가 떠나 있던 하루: 서로 다른 종류의 변화 · 자기 수정 · 읽은 변화 · 결정 대기 · 실행 결과 · 안 읽은 메시지 */
async function awayDay() {
  const user = await s.user();
  await setCleared(user, "2026-10-12T08:00:00.000000Z");
  const a = await s.action(user, { title: "견적서 보내기" });
  const b = await s.action(user, { title: "디자인 확정" });
  const c = await s.action(user, { title: "내가 고친 일" });
  const d = await s.action(user, { title: "계약 완료 처리" });
  const e = await s.action(user, { title: "확인이 필요한 일", needsConfirmation: true });
  const f = await s.action(user, { title: "초안 작성" });
  await s.q(`update public.actions set started_at = '2026-10-12T07:00:00Z' where id = $1`, [f]);
  // A: 사용자가 09:00에 본 뒤 AI가 두 번 바꿨다 → 둘 다 안 읽은 변화
  await event(user, a, "user_seen", "user", "2026-10-12T09:00:00.000000Z");
  await event(user, a, "due_changed", "ai", "2026-10-12T10:00:00.000000Z");
  await event(user, a, "merged", "ai", "2026-10-12T11:00:00.000000Z");
  // B: AI가 바꾼 뒤 사용자가 직접 고쳤다 → 본 것
  await event(user, b, "due_changed", "ai", "2026-10-12T10:30:00.000000Z");
  await event(user, b, "user_edited", "user", "2026-10-12T10:40:00.000000Z");
  // C: 사용자 자기 수정 + AI가 새로 만들기만 함 → 변화가 아니다
  await event(user, c, "created", "ai", "2026-10-12T09:30:00.000000Z");
  await event(user, c, "user_edited", "user", "2026-10-12T10:00:00.000000Z");
  // D: AI가 완료로 바꿨고 근거 원문이 지워졌다
  const gone = await s.source(user);
  await event(user, d, "completed", "ai", "2026-10-12T12:00:00.000000Z", gone);
  await s.q(`delete from public.sources where id = $1`, [gone]);
  // F: 실행 결과(초안 준비됨)가 Clear 위치 뒤에 도착했다
  const run = await s.run(user, f);
  await setClock(db, new Date("2026-10-12T13:00:00Z"));
  await s.q(`update public.execution_runs set state = 'running' where id = $1`, [run]);
  await s.q(`update public.execution_runs set state = 'done', outcome = 'draft_ready' where id = $1`, [run]);
  await setClock(db, new Date("2026-10-12T00:00:00Z"));
  // A에 안 읽은 assistant 메시지
  const conversation = await s.conversation(user);
  await s.q(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, created_at) values ($1, $2, 1, 'assistant', '답', $3, '2026-10-12T14:00:00Z')`, [user, conversation, JSON.stringify({ action_ids: [a] })]);
  return { user, a, b, c, d, e, f };
}

describe("복귀 요약: 기존 이벤트에서 계산 (A40 · ARCH25)", () => {
  it("떠나 있던 하루: 안 읽은 변화 · 필요한 결정 · 다음 행동만, 사용자 자기 수정 · 읽은 변화는 빠진다. 숫자 없음", async () => {
    const { user, a, d, e, f } = await awayDay();
    const body = summary(await load(user));
    expect(body).toMatchObject({ complete: true, empty: false, baseline: "cleared", since: "2026-10-12T08:00:00.000000Z", sources: { changes: "ok", decisions: "ok" } });
    // 답할 결정(E)이 맨 앞, 그다음 가장 최근 변화 순: A(메시지 14:00) → F(결과 13:00) → D(완료 12:00)
    expect(body.items.map((i) => i.action_id)).toEqual([e, a, f, d]);
    const byId = Object.fromEntries(body.items.map((i) => [i.action_id, i]));
    expect(byId[e]).toMatchObject({ title: "확인이 필요한 일", needs_answer: true, state: "to_do", changes: [], next: { kind: "answer", decision_kinds: ["confirm"] } });
    expect(byId[a].changes.map((c) => `${c.source}:${c.kind}`)).toEqual(["action_event:due_changed", "action_event:merged", "message:assistant"]);
    expect(byId[a].next).toEqual({ kind: "open", decision_kinds: [] });
    expect(byId[f]).toMatchObject({ state: "in_progress", next: { kind: "review_result", decision_kinds: [] } });
    expect(byId[f].changes).toEqual([{ source: "run", kind: "done", at: "2026-10-12T13:00:00.000000Z", detail: "draft_ready", source_state: null }]);
    expect(byId[d]).toMatchObject({ title: "계약 완료 처리", changes: [{ source: "action_event", kind: "completed", source_state: "deleted" }] });
    // 숫자가 없다
    expect(Object.keys(body).sort()).toEqual(["baseline", "complete", "cursor", "empty", "generated_at", "items", "since", "sources"]);
  });

  it("읽은 변화를 다시 올리지 않는다: 사용자가 본 뒤(user_seen) 그 변화는 Clear 없이도 사라지고, 본 뒤 새 변화만 남는다", async () => {
    const { user, a } = await awayDay();
    await event(user, a, "user_seen", "user", "2026-10-12T11:30:00.000000Z");
    const after = await load(user);
    const row = after.items.find((i) => i.action_id === a)!;
    expect(row.changes.map((c) => c.source)).toEqual(["message"]); // action_event 변화 둘은 본 것
    await event(user, a, "owner_changed", "ai", "2026-10-12T12:30:00.000000Z");
    expect((await load(user)).items.find((i) => i.action_id === a)!.changes.map((c) => c.kind)).toEqual(["owner_changed", "assistant"]);
  });

  it("옛 제목 · 원문 글 · 변경 전후 값을 되살리지 않는다: 응답에는 지금 제목뿐이다 (원문 삭제 · 접근 상실 · 보관 만료는 토큰)", async () => {
    const user = await s.user();
    await setCleared(user, "2026-10-12T00:00:00.000000Z");
    const action = await s.action(user, { title: "옛 제목: 비밀 원문 내용" });
    const [lost, purged, ok] = [await s.source(user), await s.source(user), await s.source(user)];
    await s.q(`update public.sources set access_lost_at = now() where id = $1`, [lost]);
    await s.q(`update public.sources set raw_text = '', raw_text_purged_at = now() where id = $1`, [purged]);
    await event(user, action, "scope_changed", "ai", "2026-10-12T01:00:00.000000Z", lost);
    await event(user, action, "owner_changed", "ai", "2026-10-12T02:00:00.000000Z", purged);
    await event(user, action, "merged", "ai", "2026-10-12T03:00:00.000000Z", ok);
    await s.q(`update public.action_events set before = '{"title":"과거 제목 — 지워진 원문"}', after = '{"quote":"금요일까지"}' where action_id = $1`, [action]);
    await s.q(`update public.actions set title = '바뀐 제목' where id = $1`, [action]);
    const body = await load(user);
    expect(body.items[0].title).toBe("바뀐 제목");
    expect(body.items[0].changes.map((c) => c.source_state)).toEqual(["access_lost", "text_expired", "available"]);
    const text = JSON.stringify(body);
    for (const leaked of ["옛 제목", "비밀 원문", "과거 제목", "지워진 원문", "금요일까지", "raw_text", "원문 본문"]) expect(text).not.toContain(leaked);
  });

  it("한 번도 Clear하지 않은 사용자: 작업 변화는 changed.ts대로 올리고, 실행 결과 · 메시지 이력은 변화로 올리지 않는다 (읽음 기준이 없다)", async () => {
    const user = await s.user();
    const action = await s.action(user, { title: "오래된 일" });
    await event(user, action, "due_changed", "ai", "2026-09-01T00:00:00.000000Z");
    const run = await s.run(user, action);
    await s.q(`update public.execution_runs set state = 'failed' where id = $1`, [run]);
    const conversation = await s.conversation(user);
    await s.q(`insert into public.conversation_messages (user_id, conversation_id, seq, role, text, refs, created_at) values ($1, $2, 1, 'event', 'x', $3, '2026-09-02T00:00:00Z')`, [user, conversation, JSON.stringify({ action_ids: [action] })]);
    const body = summary(await load(user));
    expect(body).toMatchObject({ baseline: "never_cleared", since: null, complete: true });
    expect(body.items).toHaveLength(1);
    expect(body.items[0].changes.map((c) => c.source)).toEqual(["action_event"]);
    // 읽음 기준이 생기면(마지막으로 읽은 시각) 그 뒤 메시지는 변화다
    await s.q(`update public.conversations set last_read_at = '2026-09-01T12:00:00Z' where id = $1`, [conversation]);
    expect((await load(user)).items[0].changes.map((c) => c.source)).toEqual(["action_event", "message"]);
  });

  it("남의 데이터는 보이지 않는다 (service role이어도 user_id로 좁힌다)", async () => {
    const [alice, bob] = [await s.user(), await s.user()];
    const bobAction = await s.action(bob, { needsConfirmation: true });
    await event(bob, bobAction, "completed", "ai", "2026-10-12T01:00:00.000000Z");
    expect(summary(await load(alice))).toMatchObject({ items: [], empty: true, complete: true });
  });
});

describe("Clear: 표시한 범위의 읽음 처리일 뿐 (해결 · 승인 · 완료 · 거절이 아니다)", () => {
  it("Clear 뒤에는 읽은 변화가 사라지고 since가 옮겨 간다. 답할 결정은 그대로 남는다 (읽음은 결정이 아니다)", async () => {
    const { user, e } = await awayDay();
    const before = await load(user);
    const fp = await fingerprint(user);
    const outcome = await clear(user, before.cursor);
    expect(outcome).toEqual({ status: "cleared", applied: true, clearedThrough: H });
    // 읽음 외에는 어느 표도 바뀌지 않는다 (Action · 이벤트 · run · 승인 · 사건함 · 제안), user_seen도 만들지 않는다
    expect(await fingerprint(user)).toBe(fp);
    expect(await s.count(`select 1 from public.action_events where user_id = $1 and type = 'user_seen'`, [user])).toBe(1); // 시드의 것 하나뿐
    const after = summary(await load(user, "2026-10-12T20:30:00.000000Z"));
    expect(after.since).toBe(H);
    expect(after.items.map((i) => [i.action_id, i.needs_answer])).toEqual([[e, true]]);
    expect(after.items[0].next).toEqual({ kind: "answer", decision_kinds: ["confirm"] });
  });

  it("조회와 Clear 사이에 생긴 새 변화는 읽음으로 삼키지 않는다 (지평 뒤)", async () => {
    const { user, d } = await awayDay();
    const first = await load(user);
    await event(user, d, "reopened", "ai", "2026-10-12T20:00:00.000001Z"); // 지평 1µs 뒤
    expect((await clear(user, first.cursor)).status).toBe("cleared");
    const after = await load(user, "2026-10-12T20:30:00.000000Z");
    expect(after.items.find((i) => i.action_id === d)!.changes.map((c) => c.kind)).toEqual(["reopened"]);
  });

  it("같은 시각 tie · 늦게 commit된 사건(지평 이전 시각)이 조회 뒤 Clear 전에 나타나면 409 상당(stale): 아무것도 읽음 처리하지 않고, 다시 조회하면 보인다", async () => {
    const { user, d } = await awayDay();
    const first = await load(user);
    await event(user, d, "scope_changed", "ai", H); // 지평과 정확히 같은 시각
    expect(await clear(user, first.cursor)).toEqual({ status: "stale" });
    expect((await state(user))?.at).toBe("2026-10-12T08:00:00.000000Z"); // 위치 그대로
    const second = await load(user);
    expect(second.items.find((i) => i.action_id === d)!.changes.map((c) => c.kind)).toEqual(["completed", "scope_changed"]);
    // 마지막 Clear 시각(08:00)보다 이른 시각의 늦은 사건도 시각으로 숨지 않는다: 두 번째 조회가 못 봤으니 stale이고, 세 번째 조회에 보인다
    await event(user, d, "owner_changed", "ai", "2026-10-12T05:00:00.000000Z");
    expect(await clear(user, second.cursor)).toEqual({ status: "stale" });
    const third = await load(user);
    expect(third.items.find((i) => i.action_id === d)!.changes.map((c) => c.kind)).toEqual(["owner_changed", "completed", "scope_changed"]);
    expect((await clear(user, third.cursor)).status).toBe("cleared");
  });

  it("DB 정밀도: 커서의 시각은 마이크로초 글자 그대로다 (밀리초로 잘리면 stale로 정직하게 거절)", async () => {
    const user = await s.user();
    const action = await s.action(user);
    await event(user, action, "due_changed", "ai", "2026-10-12T00:00:00.123400Z");
    await event(user, action, "merged", "ai", "2026-10-12T00:00:00.123700Z");
    const body = await load(user, "2026-10-12T00:00:00.123700Z");
    expect(body.cursor).not.toBeNull();
    const [, payload] = body.cursor!.split(".");
    const parsed = JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as [string, string, string];
    expect(parsed[1]).toBe("2026-10-12T00:00:00.123700Z");
    const naive = encodeCursor({ userId: user, horizon: new Date(parsed[1]).toISOString().replace(".123Z", ".123000Z"), digest: parsed[2] });
    expect(await clear(user, naive)).toEqual({ status: "stale" });
    expect((await clear(user, body.cursor)).status).toBe("cleared");
  });

  it("두 기기 · 겹친 읽기 · 늦은 Clear · 재시도(응답 유실): 위치는 뒤로 가지 않고, 같은 커서를 다시 보내도 성공이지만 새 쓰기는 없다", async () => {
    const { user, d } = await awayDay();
    const phone = await load(user, "2026-10-12T15:00:00.000000Z");
    await event(user, d, "owner_changed", "ai", "2026-10-12T15:30:00.000000Z");
    const mac = await load(user, "2026-10-12T16:00:00.000000Z");
    await event(user, d, "reopened", "ai", "2026-10-12T16:30:00.000000Z");
    expect(await clear(user, mac.cursor)).toMatchObject({ status: "cleared", applied: true, clearedThrough: "2026-10-12T16:00:00.000000Z" });
    // iPhone이 한참 뒤에 자기 커서로 Clear: 이미 더 앞 위치라 쓸 것이 없다 (성공, 뒤로 가지 않는다)
    expect(await clear(user, phone.cursor)).toMatchObject({ status: "cleared", applied: false, clearedThrough: "2026-10-12T16:00:00.000000Z" });
    // 응답 유실 뒤 재시도
    expect(await clear(user, mac.cursor)).toMatchObject({ status: "cleared", applied: false });
    expect((await state(user))?.version).toBe(2); // 시드 1 + 실제로 옮긴 한 번
    // 지평(16:00) 뒤 사건(16:30)은 남아 있다
    const after = await load(user, "2026-10-12T17:00:00.000000Z");
    expect(after.items.find((i) => i.action_id === d)!.changes.map((c) => c.kind)).toEqual(["reopened"]);
  });

  it("같은 UUID로 다시 로그인해도(새 세션 · 새 클라이언트) 위치는 계정에 붙어 있고, 이전 세션의 커서도 그대로 통한다", async () => {
    const { user } = await awayDay();
    const oldSession = await load(user);
    const newSessionClient = adminOf(db);
    expect((await clear(user, oldSession.cursor, newSessionClient)).status).toBe("cleared");
    expect((await load(user, "2026-10-12T20:30:00.000000Z", newSessionClient)).since).toBe(H);
  });

  it("남의 커서 · 꾸민 커서 · 깨진 커서: invalid(400) 또는 stale — 어느 경우에도 위치는 그대로다", async () => {
    const { user } = await awayDay();
    const other = await s.user();
    const mine = await load(user);
    expect(await clear(other, mine.cursor)).toEqual({ status: "invalid" }); // 사용자 id가 다른 커서
    expect(await clear(user, "c2.garbage")).toEqual({ status: "invalid" });
    expect(await clear(user, "")).toEqual({ status: "invalid" });
    const forgedFuture = encodeCursor({ userId: user, horizon: "2999-01-01T00:00:00.000000Z", digest: "a:0:0|r:0:0|m:0:0" });
    expect(await clear(user, forgedFuture)).toEqual({ status: "invalid" }); // 미래 지평
    const forgedDigest = encodeCursor({ userId: user, horizon: H, digest: "a:0:0|r:0:0|m:0:0" });
    expect(await clear(user, forgedDigest)).toEqual({ status: "stale" });
    expect((await state(user))?.at).toBe("2026-10-12T08:00:00.000000Z");
    expect(await s.count(`select 1 from public.return_summary_reads where user_id = $1`, [user])).toBe(0);
  });

  it("범위 안 작업이 지워지면 stale이다 (보지 못한 것을 읽음으로 삼키는 쪽이 아니라 다시 조회하게 한다)", async () => {
    const { user, d } = await awayDay();
    const body = await load(user);
    await s.q(`delete from public.actions where id = $1`, [d]);
    expect(await clear(user, body.cursor)).toEqual({ status: "stale" });
  });
});

describe("완전성: 일부를 못 읽거나 잘렸는데 비었다 · 모두 처리됐다고 하지 않는다", () => {
  const failing = (fn: string): SupabaseClient =>
    new Proxy(admin, {
      get: (target, prop) =>
        prop === "rpc" ? (name: string, args: Record<string, unknown>) => { if (name === fn) throw new Error(`permission denied for function ${fn}`); return target.rpc(name, args); } : Reflect.get(target, prop),
    });

  it("변화 원천 읽기 실패 → changes unavailable, 커서 없음, empty 아님 (결정 대기는 그대로 보인다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { user, e } = await awayDay();
    const body = summary(await loadReturnSummary(failing("return_summary_scan"), user, NOW, { horizon: H }));
    expect(body).toMatchObject({ complete: false, empty: false, baseline: "unknown", cursor: null, since: null, sources: { changes: "unavailable", decisions: "ok" } });
    expect(body.items.map((i) => i.action_id)).toEqual([e]);
    vi.restoreAllMocks();
  });

  it("결정 대기 읽기 실패 → decisions unavailable (변화는 그대로, Clear는 가능), empty 아님", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const user = await s.user();
    await s.action(user, { needsConfirmation: true });
    const body = summary(await loadReturnSummary(failing("coordinator_pending_inputs"), user, NOW, { horizon: H }));
    expect(body).toMatchObject({ complete: false, empty: false, items: [], sources: { changes: "ok", decisions: "unavailable" } });
    expect(body.cursor).not.toBeNull();
    vi.restoreAllMocks();
  });

  it("둘 다 실패해도 200 모양이고 비었다고 하지 않는다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const failBoth = new Proxy(admin, { get: (target, prop) => (prop === "rpc" ? () => { throw new Error("down"); } : Reflect.get(target, prop)) });
    const body = summary(await loadReturnSummary(failBoth, await s.user(), NOW, { horizon: H }));
    expect(body).toMatchObject({ complete: false, empty: false, items: [], cursor: null, sources: { changes: "unavailable", decisions: "unavailable" } });
    vi.restoreAllMocks();
  });

  it("결정이 있는 작업의 제목을 읽지 못하면 그 결정들을 없다고 하지 않고 decisions를 unavailable로 표시한다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const user = await s.user();
    await s.action(user, { needsConfirmation: true });
    const brokenActions = new Proxy(admin, { get: (target, prop) => (prop === "from" ? (table: string) => { if (table === "actions") throw new Error("down"); return target.from(table); } : Reflect.get(target, prop)) });
    const body = await loadReturnSummary(brokenActions, user, NOW, { horizon: H });
    expect(body).toMatchObject({ complete: false, empty: false, sources: { decisions: "unavailable" } });
    vi.restoreAllMocks();
  });

  it(`작업이 ${RETURN_SUMMARY_MAX_WORKS}개를 넘으면 truncated: 커서 없음(Clear 불가), 일부를 전체처럼 내지 않는다`, async () => {
    const user = await s.user();
    await s.q(
      `with a as (insert into public.actions (user_id, title) select $1, '일 ' || g from generate_series(1, $2::int) g returning id)
       insert into public.action_events (user_id, action_id, type, actor, created_at) select $1, id, 'merged', 'ai', '2026-10-12T01:00:00Z' from a`,
      [user, RETURN_SUMMARY_MAX_WORKS + 1],
    );
    const body = summary(await load(user));
    expect(body.items).toHaveLength(RETURN_SUMMARY_MAX_WORKS);
    expect(body).toMatchObject({ complete: false, empty: false, cursor: null, sources: { changes: "truncated" } });
  });
});

describe("ARCH06/07 · I04 · I14 · D13: 읽음과 제안은 실행 · 정책 · 승인 · Claim을 건드리지 않는다", () => {
  it("승인 대기 단계가 있어도 조회 · Clear 전후 run · 단계 · 승인 · intent · 정책 행이 한 글자도 같다 (승인 hash 포함)", async () => {
    const user = await s.user();
    const action = await s.action(user, { title: "견적서 보내기" });
    await s.q(`insert into public.execution_policies (user_id, mode, auto_recipients) values ($1, 'manual', '[]') on conflict (user_id) do update set mode = 'manual'`, [user]);
    const run = randomUUID();
    await s.q(`insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request) select $1, $2, $3, p.id, 'draft', '견적서 보내 줘' from public.execution_policies p where p.user_id = $2`, [run, user, action]);
    const step = randomUUID();
    await s.q(
      `insert into public.execution_steps (id, user_id, run_id, seq, kind, provider, tool, purpose, recipients, body, args)
       values ($1, $2, $3, 1, 'external', 'fake', 'send', 'send-1', $4::jsonb, '견적서 보내드립니다', '{"subject": "견적"}')`,
      [step, user, run, JSON.stringify([{ address: "other@example.com", origin: "user" }])],
    );
    const version = (await s.one(`select version from public.execution_steps where id = $1`, [step])).version;
    expect((await s.one(`select public.prepare_step($1, $2) as ok`, [step, version])).ok).toBe(true);
    await event(user, action, "due_changed", "ai", "2026-10-12T01:00:00.000000Z");
    const policy = JSON.stringify(await s.q(`select to_jsonb(p) as row from public.execution_policies p where user_id = $1`, [user]));
    const hash = async () => (await s.one(`select public.approval_hash($1, $2::timestamptz) as h`, [step, "2026-10-13T00:00:00Z"])).h;
    const [fp, hashBefore] = [await fingerprint(user), await hash()];
    const body = await load(user);
    expect(body.items[0]).toMatchObject({ needs_answer: true, next: { kind: "answer", decision_kinds: ["approval"] } });
    expect((await clear(user, body.cursor)).status).toBe("cleared");
    await load(user, "2026-10-12T21:00:00.000000Z");
    expect(await fingerprint(user)).toBe(fp);
    expect(await hash()).toBe(hashBefore);
    expect(JSON.stringify(await s.q(`select to_jsonb(p) as row from public.execution_policies p where user_id = $1`, [user]))).toBe(policy);
    // Clear 뒤에도 승인 대기는 그대로 답할 결정이다
    expect((await load(user, "2026-10-12T21:30:00.000000Z")).items.map((i) => i.next.decision_kinds)).toEqual([["approval"]]);
  });
});
