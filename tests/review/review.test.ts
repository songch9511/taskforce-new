import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { reviewResponseSchema } from "@/lib/api/contract";
import { loadReview } from "@/lib/review/review";
import { dismissSuggestion, snoozeSuggestion } from "@/lib/review/suggestions";

import { adminOf, createCoordinatorDb, queryOf, seed, setClock } from "../coordinator/support";

// Review 서버 (C3): 실제 SQL(PGlite) 위에서 운영 TS 코드(loadReview · suggestions)를 그대로 돌린다 (supabase-js 흉내는 tests/conversation/sql-admin.ts).
// 고정 시계 · 가짜 시간대 읽기만 주입한다. 모델 · 네트워크 · 실제 provider는 없다.

let db: PGlite;
let admin: SupabaseClient;
let s: ReturnType<typeof seed>;

beforeAll(async () => {
  db = await createCoordinatorDb();
  admin = adminOf(db);
  s = seed(db);
}, 60_000);
afterAll(() => db.close());

const SEOUL = async () => "Asia/Seoul";
const NEW_YORK = async () => "America/New_York";
const NO_ZONE = async () => null;
const options = (over: Partial<Parameters<typeof loadReview>[3]> = {}) => ({ coordinatorEnabled: false, timeZone: SEOUL, ...over });
const T = (iso: string) => new Date(iso);

/**
 * 서버가 쓰는 비긴급 제안 n개 (생산자 없이 직접. 하루 상한 시험용). 앱이 아는 종류(source_revised_run)로 쓰고, 주제가 계속 유효하도록
 * 그 Action의 살아 있는 run을 하나 둔다 (기한 · 닫힘 · run 종료 증거가 없으면 제안은 그대로 열려 있다).
 */
async function plainSuggestions(userId: string, actionId: string, n: number): Promise<string[]> {
  const run = await s.run(userId, actionId);
  const ids: string[] = [];
  for (let i = 0; i < n; i++) {
    ids.push(
      await s.id(
        `insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key, created_at)
         values ($1, 'source_revised_run', $2, $3, $4, $5, $6, now() + make_interval(secs => $7)) returning id`,
        [userId, actionId, run, `run:${run}:${i}`, `r${i}`, `source_revised_run:run:${run}:${i}:${randomUUID()}`, i],
      ),
    );
  }
  return ids;
}

const fingerprint = async (userId: string) => {
  const tables = ["actions", "action_events", "claims", "evidence", "sources", "execution_runs", "execution_steps", "execution_approvals", "execution_intents", "execution_events", "inbox_events", "conversations", "conversation_messages"];
  const counts = await Promise.all(tables.map(async (t) => `${t}=${await s.count(`select 1 from public.${t} where user_id = $1`, [userId])}`));
  const actions = await s.q(`select id, title, status, due_at, owner, version, needs_confirmation from public.actions where user_id = $1 order by id`, [userId]);
  return `${counts.join(",")}|${JSON.stringify(actions)}`;
};

describe("Review: 결정 대기(C2 계산) + 열린 제안", () => {
  it("긴급 제안(기한이 24시간 안)은 처음 불러도 보이고, 응답은 계약 모양이며 개수가 없다", async () => {
    const user = await s.user();
    const now = T("2026-10-12T00:00:00Z");
    const action = await s.action(user, { dueAt: "2026-10-12T20:00:00Z" });
    const review = await loadReview(admin, user, now, options());
    expect(reviewResponseSchema.parse(review)).toEqual(review);
    expect(review).toMatchObject({ complete: true, empty: false, sources: { decisions: "ok", suggestions: "ok" }, suggestion_batch: { state: "ready", local_day: "2026-10-12", size: 3 } });
    expect(review.suggestions).toHaveLength(1);
    expect(review.suggestions![0]).toMatchObject({ kind: "due_window", action_id: action, run_id: null, urgent: true, state: "open", version: 1, offered_on: null });
    expect(Object.keys(review).sort()).toEqual(["complete", "decisions", "empty", "generated_at", "sources", "suggestion_batch", "suggestions"]);
  });

  it("아무것도 없고 모두 읽었을 때만 empty다", async () => {
    const user = await s.user();
    const review = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(review).toMatchObject({ complete: true, empty: true, decisions: [], suggestions: [] });
  });

  it("A08: 같은 계기를 몇 번을 다시 받아도(재시작 · 두 기기 · 다음 날) 제안은 늘지 않는다. 날짜가 dedup이 아니다", async () => {
    const user = await s.user();
    await s.action(user, { dueAt: "2026-10-13T18:00:00Z" }); // 기한까지 36시간 → 창(24시간) 밖
    const hits: number[] = [];
    for (const when of ["2026-10-12T09:00:00Z", "2026-10-12T09:00:00Z", "2026-10-13T00:30:00Z", "2026-10-13T00:30:00Z", "2026-10-13T08:00:00Z", "2026-10-13T17:00:00Z"]) {
      hits.push((await loadReview(admin, user, T(when), options())).suggestions!.length);
    }
    // 창에 들어온 뒤(2026-10-12T18:00Z부터)부터 하나, 이후 몇 번을 불러도 하나
    expect(hits).toEqual([0, 0, 1, 1, 1, 1]);
    expect(await s.count(`select 1 from public.suggestions where user_id = $1`, [user])).toBe(1);
  });

  it("A09: 비긴급은 하루 한 묶음 3개 — 같은 날 몇 번을 불러도 같고, 사용자 현지 날짜가 바뀌면 다음 묶음(서울)", async () => {
    const user = await s.user();
    const action = await s.action(user);
    const ids = await plainSuggestions(user, action, 5);
    const day1 = await loadReview(admin, user, T("2026-10-12T03:00:00Z"), options()); // 서울 12:00, 10-12
    const day1again = await loadReview(admin, user, T("2026-10-12T14:59:59Z"), options()); // 서울 23:59:59, 10-12
    expect(day1.suggestions!.map((x) => x.id)).toEqual(ids.slice(0, 3));
    expect(day1again.suggestions!.map((x) => x.id)).toEqual(ids.slice(0, 3));
    expect(day1.suggestions!.every((x) => x.offered_on === "2026-10-12")).toBe(true);
    const day2 = await loadReview(admin, user, T("2026-10-12T15:00:00Z"), options()); // 서울 00:00, 10-13
    expect(day2.suggestion_batch.local_day).toBe("2026-10-13");
    expect(day2.suggestions!.map((x) => x.id)).toEqual(ids); // 어제 3개(처리 전) + 새로 2개
    expect(day2.suggestions!.filter((x) => x.offered_on === "2026-10-13")).toHaveLength(2);
  });

  it("A09 + DST: 뉴욕 2026-11-01(25시간짜리 하루)에 같은 하루로 센다. 11-02 현지 자정에 새 묶음", async () => {
    const user = await s.user();
    const action = await s.action(user);
    const ids = await plainSuggestions(user, action, 6);
    const seen = async (iso: string) => (await loadReview(admin, user, T(iso), options({ timeZone: NEW_YORK }))).suggestions!;
    const a = await seen("2026-11-01T04:30:00Z"); // 00:30 EDT
    const b = await seen("2026-11-01T06:30:00Z"); // 01:30 EST (두 번째 01:30)
    const c = await seen("2026-11-02T04:30:00Z"); // 23:30 EST 11-01: 첫 순간에서 24시간이 지났어도 아직 같은 날
    expect([a.length, b.length, c.length]).toEqual([3, 3, 3]);
    expect(c.map((x) => x.id)).toEqual(ids.slice(0, 3));
    const d = await seen("2026-11-02T05:00:00Z"); // 00:00 EST 11-02
    expect(d.map((x) => x.id)).toEqual(ids);
  });

  it("시간대를 모르면(저장 없음) 새 비긴급은 내지 않는다 (needs_time_zone). 긴급은 보인다. 완전한 읽기다", async () => {
    const user = await s.user();
    const action = await s.action(user, { dueAt: "2026-10-12T20:00:00Z" });
    await plainSuggestions(user, action, 4);
    const review = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options({ timeZone: NO_ZONE }));
    expect(review.suggestion_batch).toEqual({ state: "needs_time_zone", local_day: null, size: 3 });
    expect(review.sources).toEqual({ decisions: "ok", suggestions: "ok", time_zone: "ok" });
    expect(review).toMatchObject({ complete: true, empty: false });
    expect(review.suggestions!.map((x) => [x.kind, x.urgent])).toEqual([["due_window", true]]);
  });

  it("P2-B: 시간대 읽기가 예상 못한 오류로 실패하면(57014 등) 정상 needs_time_zone · empty가 아니라 time_zone unavailable · complete false · empty false다", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    // 열린 비긴급 제안 1개 · 결정 0: 시간대를 알았다면 보였을 제안이다
    const user = await s.user();
    const action = await s.action(user);
    const [hidden] = await plainSuggestions(user, action, 1);
    const failing = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options({ timeZone: async () => { throw Object.assign(new Error("canceling statement due to statement timeout"), { code: "57014" }); } }));
    expect(reviewResponseSchema.parse(failing)).toEqual(failing);
    expect(failing).toMatchObject({
      complete: false,
      empty: false,
      sources: { decisions: "ok", suggestions: "ok", time_zone: "unavailable" },
      suggestion_batch: { state: "unavailable", local_day: null, size: 3 },
    });
    expect(failing.suggestions).toEqual([]); // 새 비긴급을 시간대 없이 지어서 내지 않는다
    // 같은 데이터에 정상 읽기면 같은 제안이 보인다 (실패 때문에 지워진 것이 아니다)
    const ok = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(ok).toMatchObject({ complete: true, empty: false, sources: { time_zone: "ok" } });
    expect(ok.suggestions!.map((x) => x.id)).toEqual([hidden]);
    vi.restoreAllMocks();
  });

  it("P2-B: 시간대 읽기 실패 중에도 긴급과 이미 노출한 제안은 그대로 보인다 (새 비긴급만 안 낸다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const user = await s.user();
    const action = await s.action(user, { dueAt: "2026-10-12T20:00:00Z" });
    const ids = await plainSuggestions(user, action, 5);
    const day1 = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(day1.suggestions!.map((x) => x.id)).toEqual(expect.arrayContaining(ids.slice(0, 3)));
    const failing = await loadReview(admin, user, T("2026-10-13T00:00:00Z"), options({ timeZone: async () => { throw new Error("down"); } }));
    expect(failing).toMatchObject({ complete: false, empty: false, sources: { time_zone: "unavailable" } });
    // 어제 낸 3개 + 긴급 1개는 그대로, 나머지 2개는 시간대를 알 수 없어 아직 내지 않았다
    expect(failing.suggestions!.map((x) => x.id).sort()).toEqual([...day1.suggestions!.map((x) => x.id)].sort());
    vi.restoreAllMocks();
  });

  it("이 코드가 모르는 종류의 열린 제안(더 새 서버가 쓴 것)은 지어 보이지 않고, 목록이 일부라고 알린다 — 비었다고 하지 않는다", async () => {
    const user = await s.user();
    const action = await s.action(user);
    await s.q(
      `insert into public.suggestions (user_id, kind, action_id, subject_key, revision, dedup_key, urgent) values ($1, 'from_the_future', $2, $3, 'r1', $4, true)`,
      [user, action, `action:${action}`, `from_the_future:action:${action}:r1`],
    );
    const review = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(review).toMatchObject({ complete: false, empty: false, suggestions: [], sources: { decisions: "ok", suggestions: "unavailable", time_zone: "ok" } });
  });

  it("긴급은 상한 밖: 비긴급 묶음이 찬 날에도 긴급 4개가 모두 보인다", async () => {
    const user = await s.user();
    const actions: string[] = [];
    for (let i = 0; i < 4; i++) actions.push(await s.action(user, { dueAt: `2026-10-12T0${i + 1}:00:00Z` }));
    await plainSuggestions(user, actions[0], 5);
    const review = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(review.suggestions!.filter((x) => x.urgent)).toHaveLength(4);
    expect(review.suggestions!.filter((x) => !x.urgent)).toHaveLength(3);
    expect(review.suggestions!.slice(0, 4).every((x) => x.urgent)).toBe(true);
  });

  it("C2 결정 대기에는 다시 상한을 씌우지 않는다: 201개를 모두 내고, 제안 상한(3)과 따로 센다 (숨긴 항목을 gone으로 만들지 않는다)", async () => {
    const user = await s.user();
    await s.q(
      `insert into public.actions (user_id, title, needs_confirmation, last_activity_at) select $1, '확인 ' || g, true, now() - make_interval(mins => g) from generate_series(1, 201) g`,
      [user],
    );
    const action = await s.action(user);
    await plainSuggestions(user, action, 5);
    const review = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(review.decisions).toHaveLength(201);
    expect(review.decisions!.every((g) => g.kind === "confirm")).toBe(true);
    expect(review.suggestions).toHaveLength(3);
    expect(review.complete).toBe(true);
    expect(review.empty).toBe(false);
  });

  it("A39: 처리된 항목은 다음 조회에서 version 불일치로 사라진다 (다른 기기에서 처리). 읽기는 해결이 아니다", async () => {
    const user = await s.user();
    const action = await s.action(user, { needsConfirmation: true });
    const first = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(first.decisions!.map((g) => [g.kind, g.action_id])).toEqual([["confirm", action]]);
    const before = await fingerprint(user);
    await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(await fingerprint(user)).toBe(before); // Action · run · Claim은 만들지 않았다 (제안 생산 · 노출 표시는 suggestions에만 쓴다)
    await s.q(`update public.actions set needs_confirmation = false, version = version + 1 where id = $1`, [action]);
    expect((await loadReview(admin, user, T("2026-10-12T00:00:01Z"), options())).decisions).toEqual([]);
  });

  it("제안을 보는 것만으로 Action · run · Claim은 생기지 않는다 (제안 생산 · 노출은 suggestions만 쓴다)", async () => {
    const user = await s.user();
    const action = await s.action(user, { dueAt: "2026-10-12T20:00:00Z" });
    await s.q(`update public.execution_runs set state = 'failed' where id = $1`, [await s.run(user, action)]);
    const before = await fingerprint(user);
    const review = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    expect(review.suggestions!.map((x) => x.kind).sort()).toEqual(["due_window", "run_failed"]);
    expect(await fingerprint(user)).toBe(before);
  });

  it("COORDINATOR_ENABLED가 꺼져 있으면 C2 처리 결과(inbox_events)를 읽는 제안 종류는 만들지 않는다. 켜져 있으면 만든다", async () => {
    const user = await s.user();
    const action = await s.action(user);
    const run = await s.run(user, action);
    const source = await s.source(user);
    const event = await s.event(user, "source_revised", `source:${source}`, { source_id: source });
    await s.q(`update public.inbox_events set processed_at = now(), result_kind = 'impact_recorded', result_ids = $2 where id = $1`, [event, JSON.stringify({ run_ids: [run] })]);
    const off = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options({ coordinatorEnabled: false }));
    expect(off.suggestions).toEqual([]);
    const on = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options({ coordinatorEnabled: true }));
    expect(on.suggestions!.map((x) => [x.kind, x.run_id, x.urgent])).toEqual([["source_revised_run", run, false]]);
    expect(on.suggestions![0].offered_on).toBe("2026-10-12");
  });

  it("원천 읽기 실패는 비었다고 하지 않는다: 결정 대기 실패 → decisions null · unavailable · complete false · empty false (제안은 그대로)", async () => {
    const user = await s.user();
    await s.action(user, { dueAt: "2026-10-12T20:00:00Z" });
    vi.spyOn(console, "error").mockImplementation(() => {});
    const failing = new Proxy(admin, {
      get: (target, prop) =>
        prop === "rpc"
          ? (fn: string, args: Record<string, unknown>) => {
              if (fn === "coordinator_pending_inputs") throw new Error("permission denied for function coordinator_pending_inputs");
              return target.rpc(fn, args);
            }
          : Reflect.get(target, prop),
    });
    const review = await loadReview(failing, user, T("2026-10-12T00:00:00Z"), options());
    expect(review).toMatchObject({ complete: false, empty: false, decisions: null, sources: { decisions: "unavailable", suggestions: "ok" } });
    expect(review.suggestions).toHaveLength(1);
    vi.restoreAllMocks();
  });

  it("제안 생산 · 노출 실패는 suggestions null · unavailable로 표시한다 (결정 대기는 그대로)", async () => {
    const user = await s.user();
    await s.action(user, { needsConfirmation: true });
    vi.spyOn(console, "error").mockImplementation(() => {});
    const failing = new Proxy(admin, {
      get: (target, prop) =>
        prop === "rpc"
          ? (fn: string, args: Record<string, unknown>) => {
              if (fn === "suggestions_produce") throw new Error("boom");
              return target.rpc(fn, args);
            }
          : Reflect.get(target, prop),
    });
    const review = await loadReview(failing, user, T("2026-10-12T00:00:00Z"), options());
    expect(review).toMatchObject({ complete: false, empty: false, suggestions: null, sources: { decisions: "ok", suggestions: "unavailable" } });
    expect(review.decisions).toHaveLength(1);
    vi.restoreAllMocks();
  });

  it("남의 데이터는 보이지 않는다 (service role이어도 user_id로 좁힌다)", async () => {
    const [alice, bob] = [await s.user(), await s.user()];
    await s.action(bob, { needsConfirmation: true, dueAt: "2026-10-12T20:00:00Z" });
    const review = await loadReview(admin, alice, T("2026-10-12T00:00:00Z"), options());
    expect(review).toMatchObject({ decisions: [], suggestions: [], empty: true });
  });
});

describe("제안 snooze · dismiss: 사용자가 고른 시점 · topic 억제 · version 조건부", () => {
  async function oneSuggestion() {
    const user = await s.user();
    const action = await s.action(user, { dueAt: "2026-10-12T20:00:00Z" });
    const review = await loadReview(admin, user, T("2026-10-12T00:00:00Z"), options());
    return { user, action, suggestion: review.suggestions![0] };
  }

  it("snooze: 사용자가 고른 시점까지 숨고, 그 시점이 지나면 같은 제안이 다시 열린다 (새 제안이 아니다)", async () => {
    const { user, suggestion } = await oneSuggestion();
    const snoozed = await snoozeSuggestion(admin, user, suggestion.id, suggestion.version, T("2026-10-12T06:00:00Z"), T("2026-10-12T01:00:00Z"));
    expect(snoozed).toMatchObject({ status: "ok", suggestion: { state: "snoozed", version: 2, snooze_until: "2026-10-12T06:00:00.000Z" } });
    expect((await loadReview(admin, user, T("2026-10-12T05:59:59Z"), options())).suggestions).toEqual([]);
    const back = await loadReview(admin, user, T("2026-10-12T06:00:00Z"), options());
    expect(back.suggestions!.map((x) => [x.id, x.state, x.version])).toEqual([[suggestion.id, "open", 3]]);
    expect(await s.count(`select 1 from public.suggestions where user_id = $1`, [user])).toBe(1);
  });

  it("snooze 시점이 지금 이전이면 invalid이고 상태는 그대로다", async () => {
    const { user, suggestion } = await oneSuggestion();
    expect(await snoozeSuggestion(admin, user, suggestion.id, suggestion.version, T("2026-10-11T00:00:00Z"), T("2026-10-12T01:00:00Z"))).toEqual({ status: "invalid" });
    expect((await loadReview(admin, user, T("2026-10-12T01:00:00Z"), options())).suggestions![0].version).toBe(1);
  });

  it("dismiss topic: 같은 종류 + 주제의 새 계기(기한이 바뀜)도 다시 제안하지 않는다. this는 새 계기를 막지 않는다", async () => {
    const { user, action, suggestion } = await oneSuggestion();
    expect((await dismissSuggestion(admin, user, suggestion.id, 1, "this", T("2026-10-12T01:00:00Z"))).status).toBe("ok");
    await s.q(`update public.actions set due_at = '2026-10-12T21:00:00Z' where id = $1`, [action]);
    const afterThis = await loadReview(admin, user, T("2026-10-12T02:00:00Z"), options());
    expect(afterThis.suggestions).toHaveLength(1); // this 거절은 새 계기를 막지 않는다
    const second = afterThis.suggestions![0];
    expect((await dismissSuggestion(admin, user, second.id, second.version, "topic", T("2026-10-12T03:00:00Z"))).status).toBe("ok");
    await s.q(`update public.actions set due_at = '2026-10-12T22:00:00Z' where id = $1`, [action]);
    expect((await loadReview(admin, user, T("2026-10-12T04:00:00Z"), options())).suggestions).toEqual([]);
    expect(await s.count(`select 1 from public.suggestions where user_id = $1`, [user])).toBe(2);
  });

  it("두 기기: 먼저 처리한 쪽이 이긴다 — 늦은 쪽은 conflict이고 아무것도 쓰지 않는다 (자동 재시도 없음)", async () => {
    const { user, suggestion } = await oneSuggestion();
    expect((await snoozeSuggestion(admin, user, suggestion.id, 1, T("2026-10-13T00:00:00Z"), T("2026-10-12T01:00:00Z"))).status).toBe("ok");
    expect(await dismissSuggestion(admin, user, suggestion.id, 1, "topic", T("2026-10-12T01:00:01Z"))).toEqual({ status: "conflict" });
    const row = await s.one(`select state, dismiss_scope, version from public.suggestions where id = $1`, [suggestion.id]);
    expect(row).toEqual({ state: "snoozed", dismiss_scope: null, version: 2 });
  });

  it("다른 사용자의 제안 id로는 처리할 수 없다 (not_found)", async () => {
    const { suggestion } = await oneSuggestion();
    const other = await s.user();
    expect(await dismissSuggestion(admin, other, suggestion.id, suggestion.version, "topic", T("2026-10-12T01:00:00Z"))).toEqual({ status: "not_found" });
    expect(await s.count(`select 1 from public.suggestions where id = $1 and state = 'open'`, [suggestion.id])).toBe(1);
  });

  it("처리는 Action · run · 승인 · 정책을 건드리지 않는다 (새 결정 outcome · Undo 없음)", async () => {
    const { user, suggestion } = await oneSuggestion();
    const before = await fingerprint(user);
    await dismissSuggestion(admin, user, suggestion.id, 1, "topic", T("2026-10-12T01:00:00Z"));
    expect(await fingerprint(user)).toBe(before);
  });
});

describe("시계와 함께 유지되는 하루 경계 (고정 시계 · 실제 시스템 시계/시간대를 쓰지 않는다)", () => {
  it("DB 시험 시계를 움직여도 TS가 넘긴 시각이 하루를 정한다 (서버 시각 기준)", async () => {
    const user = await s.user();
    const action = await s.action(user);
    await plainSuggestions(user, action, 4);
    await setClock(db, new Date("2030-01-01T00:00:00Z"));
    const r1 = await loadReview(admin, user, T("2026-10-12T03:00:00Z"), options());
    await setClock(db, new Date("2026-10-12T00:00:00Z"));
    expect(r1.suggestions).toHaveLength(3);
    expect(queryOf(db)).toBeTruthy();
  });
});
