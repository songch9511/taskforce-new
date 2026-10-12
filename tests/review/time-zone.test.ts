import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import { loadReview } from "@/lib/review/review";
import { loadUserTimeZone } from "@/lib/review/time-zone";

import { adminOf, createCoordinatorDb, seed } from "../coordinator/support";

// 사용자 시간대 읽기 (P2-B): "저장된 것이 없다 / 이 스택에 보고 설정 표가 없다"는 정당한 모름(null)이고, 그 밖의 읽기 오류는 모름이 아니라 읽지 못한 것이다.
// 표가 있는 경우는 H1(report_preferences)의 모양을 시험 안에서만 흉내 낸다 — H1은 별도 스택이고 이 스택의 마이그레이션에는 없다.

let db: PGlite;
let admin: SupabaseClient;
let s: ReturnType<typeof seed>;

beforeAll(async () => {
  db = await createCoordinatorDb();
  admin = adminOf(db);
  s = seed(db);
}, 60_000);
afterAll(() => db.close());

const NOW = new Date("2026-10-12T03:00:00Z");

/** report_preferences만 지정한 오류로 실패하는 admin (나머지는 실제 SQL) */
const failingReports = (code: string): SupabaseClient =>
  new Proxy(admin, {
    get: (target, prop) => {
      if (prop !== "from") return Reflect.get(target, prop);
      return (table: string) => {
        if (table !== "report_preferences") return target.from(table);
        const builder: Record<string, unknown> = {};
        for (const method of ["select", "eq", "maybeSingle", "throwOnError"]) builder[method] = () => builder;
        builder.then = (_resolve: unknown, reject: (e: unknown) => unknown) => reject(Object.assign(new Error("canceling statement due to statement timeout"), { code }));
        return builder;
      };
    },
  });

describe("loadUserTimeZone: 모름과 읽지 못함", () => {
  it("이 스택에 보고 설정 표가 없으면 모름(null)이다 (정당한 부재: 오류가 아니다)", async () => {
    expect(await s.count(`select 1 from information_schema.tables where table_name = 'report_preferences'`)).toBe(0);
    expect(await loadUserTimeZone(admin, await s.user())).toBeNull();
  });

  it("표가 있어도 그 사용자의 행이 없으면 모름 · 쓸 수 없는 이름이면 모름 · 유효한 IANA 이름이면 그 이름", async () => {
    await s.q(`create table if not exists public.report_preferences (user_id uuid primary key references auth.users (id) on delete cascade, time_zone text not null)`);
    try {
      const [none, bad, good] = [await s.user(), await s.user(), await s.user()];
      await s.q(`insert into public.report_preferences (user_id, time_zone) values ($1, 'Mars/Olympus'), ($2, 'Asia/Seoul')`, [bad, good]);
      expect(await loadUserTimeZone(admin, none)).toBeNull();
      expect(await loadUserTimeZone(admin, bad)).toBeNull();
      expect(await loadUserTimeZone(admin, good)).toBe("Asia/Seoul");
    } finally {
      await s.q(`drop table public.report_preferences`);
    }
  });

  it("그 밖의 읽기 오류(statement timeout 57014 · 권한 · 연결)는 삼키지 않고 던진다", async () => {
    for (const code of ["57014", "42501", "08006", "XX000"]) {
      await expect(loadUserTimeZone(failingReports(code), await s.user()), code).rejects.toMatchObject({ code });
    }
  });
});

describe("loadReview 기본 시간대 읽기 (주입 없이): 완전성이 정직하다", () => {
  const seedOneSuggestion = async () => {
    const user = await s.user();
    const action = await s.action(user, { dueAt: "2026-10-12T20:00:00Z" });
    const run = await s.run(user, action);
    // 비긴급 제안 1개 (살아 있는 run을 가리켜 주제가 유효하다)
    await s.q(
      `insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key) values ($1, 'source_revised_run', $2, $3, $4, 'r1', $5)`,
      [user, action, run, `run:${run}`, `source_revised_run:run:${run}:r1`],
    );
    return user;
  };

  it("표 부재(정당한 모름): needs_time_zone이지만 완전한 읽기다 — 긴급만 보인다", async () => {
    const user = await seedOneSuggestion();
    const review = await loadReview(admin, user, NOW, { coordinatorEnabled: false });
    expect(review).toMatchObject({
      complete: true,
      empty: false,
      sources: { decisions: "ok", suggestions: "ok", time_zone: "ok" },
      suggestion_batch: { state: "needs_time_zone", local_day: null },
    });
    expect(review.suggestions!.map((x) => x.kind)).toEqual(["due_window"]);
  });

  it("표가 있고 행이 있으면 ready: 같은 제안이 하루 묶음으로 보인다", async () => {
    await s.q(`create table if not exists public.report_preferences (user_id uuid primary key references auth.users (id) on delete cascade, time_zone text not null)`);
    try {
      const user = await seedOneSuggestion();
      await s.q(`insert into public.report_preferences (user_id, time_zone) values ($1, 'Asia/Seoul')`, [user]);
      const review = await loadReview(admin, user, NOW, { coordinatorEnabled: false });
      expect(review).toMatchObject({ complete: true, empty: false, suggestion_batch: { state: "ready", local_day: "2026-10-12" } });
      expect(review.suggestions!.map((x) => x.kind).sort()).toEqual(["due_window", "source_revised_run"]);
    } finally {
      await s.q(`drop table public.report_preferences`);
    }
  });

  it("P2-B: 표 조회가 statement timeout(57014)으로 실패하면 time_zone unavailable · complete false · empty false (정상 empty로 승격하지 않는다)", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const user = await s.user();
    const action = await s.action(user);
    const run = await s.run(user, action);
    await s.q(`insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key) values ($1, 'source_revised_run', $2, $3, $4, 'r1', $5)`, [user, action, run, `run:${run}`, `source_revised_run:run:${run}:r1`]);
    const review = await loadReview(failingReports("57014"), user, NOW, { coordinatorEnabled: false });
    expect(review).toMatchObject({
      complete: false,
      empty: false,
      sources: { decisions: "ok", suggestions: "ok", time_zone: "unavailable" },
      suggestion_batch: { state: "unavailable", local_day: null },
      suggestions: [],
    });
    vi.restoreAllMocks();
  });
});
