import { randomUUID } from "node:crypto";

import { expect, it } from "vitest";

// 외부 세션 목록 (OA 외부 세션 PR1, 계약 16장): Mac이 보고한 제목 · 상태 · 마지막 활동 · 불투명 id. 글 본문 · 경로 · Claude 세션 id는 이 표에 없다.
// 표 · 함수 · 트리거 · 보관 함수를 PGlite로 본다 (tests/db/external-sessions-list.test.ts).

export type ExternalSessionsDb = {
  query: (sql: string, params?: unknown[]) => Promise<Record<string, unknown>[]>;
  asUser: <T>(user: string, fn: () => Promise<T>) => Promise<T>;
};

type Report = { id: string; title: string | null; state: string; last_activity_at: string };

const ref = (n: number) => n.toString(16).padStart(64, "0");
const at = (day: number) => `2026-10-${String(day).padStart(2, "0")}T09:00:00Z`;
const row = (n: number, over: Partial<Report> = {}): Report => ({ id: ref(n), title: `제목 ${n}`, state: "available", last_activity_at: at(10 + (n % 10)), ...over });

export function externalSessionsTests(db: () => ExternalSessionsDb) {
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);
  const one = async (sql: string, params?: unknown[]) => (await q(sql, params))[0];

  async function user() {
    const id = randomUUID();
    await q("insert into auth.users (id, email) values ($1, $2)", [id, `${id}@example.com`]);
    return id;
  }
  async function bridge(owner: string, status: "active" | "revoked" = "active") {
    const id = randomUUID();
    await q("insert into public.bridges (id, user_id, device_ref) values ($1, $2, $3)", [id, owner, `dev-${id}`]);
    if (status === "revoked") await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [id]);
    return id;
  }
  const report = (owner: string, bridgeId: string, sessions: unknown) =>
    one("select public.report_external_sessions($1, $2, $3::jsonb) as result", [owner, bridgeId, JSON.stringify(sessions)]).then((r) => r.result as Record<string, unknown>);
  const refs = async (bridgeId: string) => (await q("select session_ref from public.external_sessions where bridge_id = $1 order by session_ref", [bridgeId])).map((r) => r.session_ref);

  it("표는 RLS가 켜져 있고 앱은 자기 행을 읽기만 한다 (쓰기는 서버 함수뿐)", async () => {
    const alice = await user();
    const bob = await user();
    const aBridge = await bridge(alice);
    const bBridge = await bridge(bob);
    await report(alice, aBridge, [row(1), row(2)]);
    await report(bob, bBridge, [row(3)]);
    expect(await one("select relrowsecurity as enabled from pg_class where oid = 'public.external_sessions'::regclass")).toEqual({ enabled: true });
    expect(await one("select count(*)::int as n from pg_policies where schemaname = 'public' and tablename = 'external_sessions' and policyname = 'owner_all'")).toEqual({ n: 1 });
    for (const role of ["anon", "authenticated"]) {
      expect(await one("select has_table_privilege($1, 'public.external_sessions', 'INSERT,UPDATE,DELETE') as writes", [role])).toEqual({ writes: false });
    }
    expect(await one("select has_table_privilege('authenticated', 'public.external_sessions', 'SELECT') as reads")).toEqual({ reads: true });
    expect(await one("select has_table_privilege('anon', 'public.external_sessions', 'SELECT') as reads")).toEqual({ reads: false });
    await db().asUser(alice, async () => {
      expect((await q("select session_ref from public.external_sessions order by session_ref")).map((r) => r.session_ref)).toEqual([ref(1), ref(2)]);
      await expect(q("insert into public.external_sessions (bridge_id, session_ref, state, last_activity_at) values ($1, $2, 'available', now())", [aBridge, ref(9)])).rejects.toMatchObject({ code: "42501" });
      await expect(q("delete from public.external_sessions")).rejects.toMatchObject({ code: "42501" });
    });
    await db().asUser(bob, async () => {
      expect((await q("select session_ref from public.external_sessions")).map((r) => r.session_ref)).toEqual([ref(3)]);
    });
  });

  it("열 규칙: 불투명 id는 소문자 hex 64자, 제목은 null이거나 1–200자, 상태는 6개 말뿐", async () => {
    const owner = await user();
    const b = await bridge(owner);
    const insert = (over: Record<string, unknown>) => {
      const v = { session_ref: ref(1), title: "ok", state: "available", ...over };
      return q("insert into public.external_sessions (user_id, bridge_id, session_ref, title, state, last_activity_at) values ($1, $2, $3, $4, $5, now())", [owner, b, v.session_ref, v.title, v.state]);
    };
    await expect(insert({ session_ref: "0".repeat(63) })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ session_ref: "A".repeat(64) })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ session_ref: "0123456789abcdef0123456789abcdef-123456789abcdef0123456789abcdef" })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ title: "" })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ title: "가".repeat(201) })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ state: "in_taskforce" })).rejects.toMatchObject({ code: "23514" });
    await insert({ title: null, session_ref: ref(2) });
    await insert({ title: "가".repeat(200), session_ref: ref(3), state: "unavailable" });
    for (const state of ["available", "running_claude_app", "running_terminal", "running_elsewhere", "unknown", "unavailable"]) {
      await insert({ session_ref: ref(100 + state.length), state });
    }
  });

  it("남의 bridge를 가리킬 수 없다 (복합 외래키 (bridge_id, user_id))", async () => {
    const alice = await user();
    const bob = await user();
    const bBridge = await bridge(bob);
    await expect(q("insert into public.external_sessions (user_id, bridge_id, session_ref, state, last_activity_at) values ($1, $2, $3, 'available', now())", [alice, bBridge, ref(1)])).rejects.toMatchObject({ code: "23503" });
  });

  it("report_external_sessions: 스냅샷 교체. 새 것은 넣고, 있는 것은 고치고, 빠진 것은 지운다", async () => {
    const owner = await user();
    const b = await bridge(owner);
    expect(await report(owner, b, [row(1), row(2), row(3)])).toEqual({ status: "ok", kept: 3, removed: 0 });
    expect(await refs(b)).toEqual([ref(1), ref(2), ref(3)]);
    const second = await report(owner, b, [row(2, { title: "바뀐 제목", state: "running_claude_app" }), row(4, { title: null })]);
    expect(second).toEqual({ status: "ok", kept: 2, removed: 2 });
    expect(await refs(b)).toEqual([ref(2), ref(4)]);
    expect(await one("select title, state, last_activity_at from public.external_sessions where bridge_id = $1 and session_ref = $2", [b, ref(2)])).toMatchObject({ title: "바뀐 제목", state: "running_claude_app" });
    expect(await one("select title from public.external_sessions where bridge_id = $1 and session_ref = $2", [b, ref(4)])).toEqual({ title: null });
    expect(await report(owner, b, [])).toEqual({ status: "ok", kept: 0, removed: 2 });
    expect(await refs(b)).toEqual([]);
  });

  it("보고는 reported_at을 새로 한다 (같은 내용이어도 Mac이 살아 있다는 표시)", async () => {
    const owner = await user();
    const b = await bridge(owner);
    await report(owner, b, [row(1)]);
    await q("update public.external_sessions set reported_at = now() - interval '5 days' where bridge_id = $1", [b]);
    await report(owner, b, [row(1)]);
    expect(await one("select (reported_at > now() - interval '1 minute') as fresh from public.external_sessions where bridge_id = $1", [b])).toEqual({ fresh: true });
  });

  it("다른 Mac · 다른 사용자의 행은 건드리지 않는다", async () => {
    const alice = await user();
    const bob = await user();
    const a1 = await bridge(alice);
    const a2 = await bridge(alice);
    const b1 = await bridge(bob);
    await report(alice, a1, [row(1)]);
    await report(alice, a2, [row(1), row(2)]);
    await report(bob, b1, [row(1)]);
    await report(alice, a1, []);
    expect(await refs(a1)).toEqual([]);
    expect(await refs(a2)).toEqual([ref(1), ref(2)]);
    expect(await refs(b1)).toEqual([ref(1)]);
  });

  it("없는 bridge · 남의 bridge · 해제된 bridge는 not_found이고 아무것도 쓰지 않는다", async () => {
    const alice = await user();
    const bob = await user();
    const aBridge = await bridge(alice);
    const revoked = await bridge(alice, "revoked");
    expect(await report(alice, randomUUID(), [row(1)])).toEqual({ status: "not_found" });
    expect(await report(bob, aBridge, [row(1)])).toEqual({ status: "not_found" });
    expect(await report(alice, revoked, [row(1)])).toEqual({ status: "not_found" });
    expect((await one("select count(*)::int as n from public.external_sessions where user_id in ($1, $2)", [alice, bob])).n).toBe(0);
    await report(alice, aBridge, [row(1)]);
    expect(await report(bob, aBridge, [])).toEqual({ status: "not_found" });
    expect(await refs(aBridge)).toEqual([ref(1)]);
  });

  it("잘못된 본문은 거절하고 기존 행을 그대로 둔다 (배열 아님 · 50개 초과 · id 중복 · 모양 틀림)", async () => {
    const owner = await user();
    const b = await bridge(owner);
    await report(owner, b, [row(1)]);
    const bad: unknown[] = [
      { not: "an array" },
      "text",
      Array.from({ length: 51 }, (_, n) => row(n + 1)),
      [row(1), row(1, { title: "중복" })],
      [{ ...row(2), state: "nope" }],
      [{ ...row(2), id: "not-hex" }],
      [{ ...row(2), title: "" }],
      [{ ...row(2), last_activity_at: "not a time" }],
      [{ id: ref(2), state: "available" }],
      [null],
    ];
    for (const payload of bad) {
      await expect(report(owner, b, payload), JSON.stringify(payload).slice(0, 60)).rejects.toMatchObject({ code: expect.stringMatching(/^(22023|23514|22007|22P02|23502)$/) });
      expect(await refs(b)).toEqual([ref(1)]);
    }
    expect(await report(owner, b, Array.from({ length: 50 }, (_, n) => row(n + 1)))).toEqual({ status: "ok", kept: 50, removed: 0 });
  });

  it("함수는 service role만 부른다 (앱·익명 거절)", async () => {
    for (const role of ["anon", "authenticated"]) {
      expect(await one("select has_function_privilege($1, 'public.report_external_sessions(uuid,uuid,jsonb)', 'EXECUTE') as run", [role])).toEqual({ run: false });
      expect(await one("select has_function_privilege($1, 'public.purge_external_sessions(timestamptz,integer)', 'EXECUTE') as run", [role])).toEqual({ run: false });
    }
    for (const fn of ["report_external_sessions(uuid,uuid,jsonb)", "purge_external_sessions(timestamptz,integer)"]) {
      expect(await one(`select has_function_privilege('service_role', 'public.${fn}', 'EXECUTE') as run`)).toEqual({ run: true });
      expect(await one(`select proconfig from pg_proc where oid = 'public.${fn}'::regprocedure`)).toEqual({ proconfig: ["search_path=\"\""] });
    }
  });

  it("bridge를 해제하면 그 Mac의 행(제목)이 바로 지워지고 다른 Mac의 행은 남는다", async () => {
    const owner = await user();
    const a = await bridge(owner);
    const other = await bridge(owner);
    await report(owner, a, [row(1), row(2)]);
    await report(owner, other, [row(3)]);
    await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [a]);
    expect(await refs(a)).toEqual([]);
    expect(await refs(other)).toEqual([ref(3)]);
  });

  it("bridge를 지우면 행도 지워진다 (cascade)", async () => {
    const owner = await user();
    const b = await bridge(owner);
    await report(owner, b, [row(1)]);
    await q("delete from public.bridges where id = $1", [b]);
    expect((await one("select count(*)::int as n from public.external_sessions where user_id = $1", [owner])).n).toBe(0);
  });

  it("purge_external_sessions: 보고가 끊긴 지 오래된 행만 지우고 한도를 지킨다", async () => {
    const owner = await user();
    const b = await bridge(owner);
    await report(owner, b, [row(1), row(2), row(3), row(4)]);
    await q("update public.external_sessions set reported_at = now() - interval '20 days' where bridge_id = $1 and session_ref in ($2, $3, $4)", [b, ref(1), ref(2), ref(3)]);
    const purge = (limit: number) => one("select public.purge_external_sessions(now() - interval '14 days', $1) as n", [limit]).then((r) => r.n);
    // 앞선 시험이 남긴 행이 없어야 센다 (이 표는 시험마다 비우지 않는다)
    await q("delete from public.external_sessions where bridge_id <> $1", [b]);
    expect(await purge(2)).toBe(2);
    expect(await purge(500)).toBe(1);
    expect(await purge(500)).toBe(0);
    expect(await refs(b)).toEqual([ref(4)]);
    expect(await purge(0)).toBe(0);
  });
}
