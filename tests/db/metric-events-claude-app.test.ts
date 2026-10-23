import { randomUUID } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// Claude 데스크톱 세션 보기 지표 (OA PR-D2): claude_app_session_opened는 route(서버 권한)가 남긴다 — 앱 insert 정책은 그대로(app_opened · assistant_opened)라
// 앱이 직접 이 종류를 쓸 수 없다. 하루 한 번(UTC 날짜별 부분 unique 인덱스). 종류 검사는 앞 목록 전체 + 이 type 하나다.

const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const NEW_MIGRATION = "20261206000000_claude_app_session_metrics.sql";
const PREVIOUS_MIGRATION = "20261204000000_agent_session_attach.sql";

let db: PGlite;
beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);
afterAll(async () => {
  await db?.close();
});

async function user() {
  const id = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [id, `${id}@example.com`]);
  return id;
}

const opened = (owner: string, at?: string) =>
  db.query("insert into public.metric_events (user_id, type, props, at) values ($1, 'claude_app_session_opened', '{}'::jsonb, coalesce($2::timestamptz, now()))", [owner, at ?? null]);

/** `check (type in ('a', 'b', …))`의 목록 (주석 줄을 지운 그 파일의 마지막 정의) */
function typeList(file: string): string[] {
  const text = readFileSync(path.join(MIGRATIONS, file), "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");
  const lists = [...text.matchAll(/constraint\s+metric_events_type_check\s+check\s*\(\s*type\s+in\s*\(([^)]*)\)\s*\)/gi)];
  const list = lists.at(-1)?.[1];
  if (list === undefined) throw new Error(`metric_events_type_check not found in ${file}`);
  return [...list.matchAll(/'([^']*)'/g)].map((m) => m[1]);
}

describe("metric_events: claude_app_session_opened", () => {
  it("종류 검사가 받고, 앞의 모든 종류(session_attached · external_sessions_shown 포함)는 그대로 받는다", async () => {
    const owner = await user();
    await opened(owner);
    for (const type of ["app_opened", "assistant_opened", "session_resumed", "billing_checkout_started", "ai_key_saved", "session_attached", "external_sessions_shown"]) {
      await db.query("insert into public.metric_events (user_id, type) values ($1, $2)", [owner, type]);
    }
    await expect(db.query("insert into public.metric_events (user_id, type) values ($1, 'claude_app_session_closed')", [owner])).rejects.toMatchObject({ code: "23514" });
  });

  it("앱(authenticated)은 이 종류를 직접 쓸 수 없다 (열 권한 · 정책은 그대로: app_opened · assistant_opened만)", async () => {
    const owner = await user();
    const other = await user();
    await asUser(db, owner, async () => {
      await db.query("insert into public.metric_events (type) values ('app_opened')");
      for (const type of ["claude_app_session_opened", "external_sessions_shown", "session_attached", "agent_message_sent"]) {
        await expect(db.query("insert into public.metric_events (type) values ($1)", [type]), type).rejects.toMatchObject({ code: expect.stringMatching(/^(42501|23514)$/) });
      }
      await expect(db.query("insert into public.metric_events (type, props) values ('app_opened', '{\"source\":\"rail\"}')")).rejects.toMatchObject({ code: "42501" });
      await expect(db.query("insert into public.metric_events (user_id, type) values ($1, 'app_opened')", [other])).rejects.toMatchObject({ code: "42501" });
    });
  });

  it("하루(UTC 날짜)에 한 번만 들어가고, 다른 날과 다른 사용자는 따로 센다", async () => {
    const owner = await user();
    const other = await user();
    await opened(owner, "2026-10-22T00:00:00Z");
    await expect(opened(owner, "2026-10-22T23:59:59Z")).rejects.toMatchObject({ code: "23505" });
    await opened(owner, "2026-10-23T00:00:00Z");
    await opened(other, "2026-10-22T12:00:00Z");
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where user_id = $1 and type = 'claude_app_session_opened'", [owner]);
    expect(rows[0].n).toBe(2);
  });

  it("같은 날 다른 종류는 막지 않고, external_sessions_shown과 하루 한 번 인덱스가 서로 섞이지 않는다", async () => {
    const owner = await user();
    await db.query("insert into public.metric_events (user_id, type) values ($1, 'app_opened'), ($1, 'app_opened')", [owner]);
    await db.query("insert into public.metric_events (user_id, type, props, at) values ($1, 'external_sessions_shown', $2::jsonb, '2026-10-22T01:00:00Z')", [owner, JSON.stringify({ rows_bucket: "1", held_bucket: "0" })]);
    await opened(owner, "2026-10-22T02:00:00Z");
    await expect(opened(owner, "2026-10-22T03:00:00Z")).rejects.toMatchObject({ code: "23505" });
  });

  it("props를 비워 두는 지표다: 이 종류의 행에는 어떤 값도 들어 있지 않다 (route가 비어 있는 객체만 쓴다)", async () => {
    const owner = await user();
    await opened(owner);
    const { rows } = await db.query<{ props: unknown }>("select props from public.metric_events where user_id = $1 and type = 'claude_app_session_opened'", [owner]);
    expect(rows).toEqual([{ props: {} }]);
  });
});

describe("마이그레이션 경계 (20261206000000_claude_app_session_metrics)", () => {
  const text = readFileSync(path.join(MIGRATIONS, NEW_MIGRATION), "utf8");
  const code = text
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n")
    .trim();

  it("한 트랜잭션, 짧은 lock_timeout. 종류 검사와 인덱스 하나뿐이다 (새 표 · 함수 · 정책 · 트리거 · 열 0)", () => {
    expect(code.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    expect(code.endsWith("commit;")).toBe(true);
    expect(code.match(/^begin;$/gm)).toHaveLength(1);
    expect(code.match(/^commit;$/gm)).toHaveLength(1);
    expect(code).not.toMatch(/create\s+(or\s+replace\s+)?(table|function|trigger|policy|view)/i);
    expect(code).not.toMatch(/alter\s+table\s+public\.metric_events\s+(add|drop)\s+column/i);
    expect(code.match(/create\s+unique\s+index/gi)).toHaveLength(1);
    expect(code).not.toMatch(/\bgrant\b|\brevoke\b/i);
  });

  it("종류 검사 = 바로 앞 마이그레이션의 목록 전체 + claude_app_session_opened 하나 (순서도 그대로)", () => {
    const previous = typeList(PREVIOUS_MIGRATION);
    expect(previous.at(-1)).toBe("session_attached");
    expect(typeList(NEW_MIGRATION)).toEqual([...previous, "claude_app_session_opened"]);
  });

  it("이 파일 다음에 종류 검사를 다시 만드는 파일은 PR-D3s의 20261207 · D3v-s의 20261208 · 에이전트 트리 T3s의 20261209 셋뿐이고(각 파일이 앞 파일의 목록을 모두 이어 가져온다), 이 파일은 앞 목록의 type을 하나도 잃지 않는다", () => {
    const files = readdirSync(MIGRATIONS)
      .filter((name) => name.endsWith(".sql"))
      .sort();
    const touching = files.filter((name) => /metric_events_type_check/.test(readFileSync(path.join(MIGRATIONS, name), "utf8").split("\n").filter((l) => !l.trim().startsWith("--")).join("\n")));
    expect(touching.slice(touching.indexOf(NEW_MIGRATION))).toEqual([NEW_MIGRATION, "20261207000000_claude_app_chats.sql", "20261208000000_claude_app_chats_delete_all.sql", "20261209000000_agent_tree_metrics.sql"]);
    // 20261207 · 20261208 · 20261209의 목록이 이 파일의 목록 전체를 담는지는 tests/db/claude-app-chats-metrics.test.ts · claude-app-chats-delete-all-migration.test.ts · agent-tree-metrics.test.ts가 고정한다 (여기서는 같은 사실을 한 번 더 본다)
    for (const later of ["20261207000000_claude_app_chats.sql", "20261208000000_claude_app_chats_delete_all.sql", "20261209000000_agent_tree_metrics.sql"]) {
      const list = new Set(typeList(later));
      for (const type of typeList(NEW_MIGRATION)) expect(list.has(type), `${later} ${type}`).toBe(true);
    }
    const newest = new Set(typeList(NEW_MIGRATION));
    for (const type of typeList(PREVIOUS_MIGRATION)) expect(newest.has(type), type).toBe(true);
  });

  it("하루 한 번 인덱스는 이 종류만, UTC 날짜별로 건다", () => {
    expect(code).toMatch(/create unique index metric_events_claude_app_opened_day_idx\s+on public\.metric_events \(user_id, \(\("at" at time zone 'UTC'\)::date\)\)\s+where type = 'claude_app_session_opened';/);
  });
});
