import { randomUUID } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase, supabaseSchemaScripts } from "./local-supabase";
import { openPglite } from "./pglite-template";

// 에이전트 트리 지표 넷 (T3s, 마이그레이션 20261209000000): 앱이 v2 route로 알리면 route가 서버 권한으로 남긴다 (claude_app_session_opened와 같은 모양).
//   · project_sessions_opened · subagent_row_opened: 사용자 · UTC 날짜 하루 한 번 (부분 unique 인덱스), props {}
//   · subagent_turn_used · subagent_question_redirected: 턴(agent_task_id) 한 번 (부분 unique 인덱스), props는 키 agent_task_id 하나(소문자 uuid)뿐 (전용 check)
// 종류 검사는 바로 앞 목록(20261207000000)의 전체 + 이 넷이다. 앱 insert 정책 · 열 권한은 그대로라 앱은 이 종류를 직접 넣지 못한다.

const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const NEW_MIGRATION = "20261209000000_agent_tree_metrics.sql";
const PREVIOUS_MIGRATION = "20261207000000_claude_app_chats.sql";
const D2_MIGRATION = "20261206000000_claude_app_session_metrics.sql";

const DAY_TYPES = ["project_sessions_opened", "subagent_row_opened"] as const;
const TURN_TYPES = ["subagent_turn_used", "subagent_question_redirected"] as const;
const NEW_TYPES = [...DAY_TYPES, ...TURN_TYPES];

/** 20261207000000_claude_app_chats.sql의 metric_events_type_check 목록 (글자 그대로) */
const LIST_20261207 = [
  "app_opened", "action_started", "handoff_used", "connection_created", "connection_reauth", "reconnect_notified", "source_failed",
  "assistant_opened", "context_attached", "agent_message_sent", "stop_requested",
  "project_created", "project_renamed", "project_archived", "project_icon_changed", "issue_moved",
  "message_resent", "question_answered", "session_renamed", "session_opened_external", "session_resumed",
  "tool_call_decided", "path_conflict_found", "path_conflict_resolved",
  "billing_checkout_started", "billing_trial_started", "billing_subscription_activated", "billing_payment_succeeded",
  "billing_payment_failed", "billing_plan_changed", "billing_subscription_cancelled", "billing_subscription_resumed",
  "billing_subscription_ended", "billing_lifetime_purchased", "billing_refund_requested", "billing_refunded",
  "billing_portal_opened", "billing_duplicate_purchase", "billing_review_needed", "billing_legacy_marked", "billing_notice_scheduled",
  "ai_key_saved", "ai_key_deleted", "ai_key_revoked",
  "external_sessions_shown",
  "session_attached",
  "claude_app_session_opened",
  "claude_app_message_sent", "claude_app_chat_deleted",
];

const stripComments = (sql: string) => sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ");
const read = (file: string) => readFileSync(path.join(MIGRATIONS, file), "utf8");
const code = (file: string) => stripComments(read(file)).trim();

/** `constraint metric_events_type_check check (type in (…))`의 목록 (주석을 지운 그 파일의 마지막 정의) */
function typeList(file: string): string[] {
  const lists = [...code(file).matchAll(/constraint\s+metric_events_type_check\s+check\s*\(\s*type\s+in\s*\(([^)]*)\)\s*\)/gi)];
  const list = lists.at(-1)?.[1];
  if (list === undefined) throw new Error(`metric_events_type_check not found in ${file}`);
  return [...list.matchAll(/'([^']*)'/g)].map((m) => m[1]);
}

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

const day = (owner: string, type: string, at?: string) =>
  db.query("insert into public.metric_events (user_id, type, props, at) values ($1, $2, '{}'::jsonb, coalesce($3::timestamptz, now()))", [owner, type, at ?? null]);
const turn = (owner: string, type: string, props: unknown) => db.query("insert into public.metric_events (user_id, type, props) values ($1, $2, $3::jsonb)", [owner, type, JSON.stringify(props)]);

describe("metric_events: 종류 검사 (20261209000000)", () => {
  it("앞 목록(20261207)의 모든 종류를 그대로 받고, 새 종류 넷도 받고, 모르는 종류는 거절한다", async () => {
    const owner = await user();
    for (const type of LIST_20261207) {
      // 하루 한 번 · 턴 한 번 인덱스가 걸린 종류가 아닌 것만 한 줄씩 넣는다 (앞 종류의 인덱스 시험은 각자 파일에 있다)
      if (type === "claude_app_session_opened") continue;
      await db.query("insert into public.metric_events (user_id, type) values ($1, $2)", [owner, type]);
    }
    await day(owner, "claude_app_session_opened");
    for (const type of DAY_TYPES) await day(owner, type);
    for (const type of TURN_TYPES) await turn(owner, type, { agent_task_id: randomUUID() });
    await expect(db.query("insert into public.metric_events (user_id, type) values ($1, 'subagent_tree_opened')", [owner])).rejects.toMatchObject({ code: "23514" });
  });

  it("앱(authenticated)은 이 넷을 직접 남기지 못한다 (insert 정책은 app_opened · assistant_opened만, 열 권한은 type · action_id만)", async () => {
    const owner = await user();
    await asUser(db, owner, async () => {
      for (const type of NEW_TYPES) {
        await expect(db.query("insert into public.metric_events (type) values ($1)", [type]), type).rejects.toMatchObject({ code: expect.stringMatching(/^(42501|23514)$/) });
        await expect(db.query("insert into public.metric_events (type, props) values ($1, $2::jsonb)", [type, JSON.stringify({ agent_task_id: randomUUID() })]), `${type} props`).rejects.toMatchObject({ code: "42501" });
      }
      await db.query("insert into public.metric_events (type) values ('app_opened')");
    });
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where user_id = $1 and type = any($2)", [owner, NEW_TYPES]);
    expect(rows[0].n).toBe(0);
  });

  it("앱은 자기 행을 읽지만 남의 행은 읽지 못한다 (기존 owner 정책 그대로)", async () => {
    const owner = await user();
    const other = await user();
    await day(owner, "project_sessions_opened");
    await day(other, "project_sessions_opened");
    await asUser(db, owner, async () => {
      const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where type = 'project_sessions_opened'");
      expect(rows[0].n).toBe(1);
    });
  });
});

describe("열기 둘: 사용자 · UTC 날짜 하루 한 번", () => {
  it.each(DAY_TYPES)("%s: 같은 날(UTC) 두 번째는 23505, 다른 날 · 다른 사용자는 따로 센다", async (type) => {
    const owner = await user();
    const other = await user();
    await day(owner, type, "2026-10-22T00:00:00Z");
    await expect(day(owner, type, "2026-10-22T23:59:59Z")).rejects.toMatchObject({ code: "23505" });
    await day(owner, type, "2026-10-23T00:00:00Z");
    await day(other, type, "2026-10-22T12:00:00Z");
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where user_id = $1 and type = $2", [owner, type]);
    expect(rows[0].n).toBe(2);
  });

  it("UTC 날짜 기준이다: KST 자정 전후(UTC로는 같은 날)는 한 번, UTC 자정 전후는 두 번", async () => {
    const owner = await user();
    await day(owner, "subagent_row_opened", "2026-10-22T14:59:59Z");
    await expect(day(owner, "subagent_row_opened", "2026-10-22T15:00:01Z")).rejects.toMatchObject({ code: "23505" });
    await day(owner, "subagent_row_opened", "2026-10-23T00:00:01Z");
  });

  it("두 종류는 서로 막지 않고, 같은 날 다른 종류(앞 지표 포함)도 막지 않는다", async () => {
    const owner = await user();
    await day(owner, "project_sessions_opened", "2026-10-22T01:00:00Z");
    await day(owner, "subagent_row_opened", "2026-10-22T02:00:00Z");
    await day(owner, "claude_app_session_opened", "2026-10-22T03:00:00Z");
    await db.query("insert into public.metric_events (user_id, type, at) values ($1, 'app_opened', '2026-10-22T04:00:00Z'), ($1, 'app_opened', '2026-10-22T05:00:00Z')", [owner]);
    await expect(day(owner, "project_sessions_opened", "2026-10-22T06:00:00Z")).rejects.toMatchObject({ code: "23505" });
    await expect(day(owner, "subagent_row_opened", "2026-10-22T06:00:00Z")).rejects.toMatchObject({ code: "23505" });
  });
});

describe("T2 둘: 턴(agent_task_id) 한 번 · props 모양", () => {
  it.each(TURN_TYPES)("%s: 같은 턴 두 번째는 23505, 다른 턴 · 다른 사용자는 따로 센다", async (type) => {
    const owner = await user();
    const other = await user();
    const task = randomUUID();
    await turn(owner, type, { agent_task_id: task });
    await expect(turn(owner, type, { agent_task_id: task })).rejects.toMatchObject({ code: "23505" });
    await turn(owner, type, { agent_task_id: randomUUID() });
    await turn(other, type, { agent_task_id: task });
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where user_id = $1 and type = $2", [owner, type]);
    expect(rows[0].n).toBe(2);
  });

  it("같은 턴이 두 종류에 모두 남는 것은 막지 않는다 (turn_used와 question_redirected는 따로 센다)", async () => {
    const owner = await user();
    const task = randomUUID();
    await turn(owner, "subagent_turn_used", { agent_task_id: task });
    await turn(owner, "subagent_question_redirected", { agent_task_id: task });
    await expect(turn(owner, "subagent_turn_used", { agent_task_id: task })).rejects.toMatchObject({ code: "23505" });
    await expect(turn(owner, "subagent_question_redirected", { agent_task_id: task })).rejects.toMatchObject({ code: "23505" });
  });

  it("하루 한 번이 아니다: 같은 날 서로 다른 턴은 여러 번 남는다", async () => {
    const owner = await user();
    for (let i = 0; i < 3; i++) await turn(owner, "subagent_turn_used", { agent_task_id: randomUUID() });
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where user_id = $1 and type = 'subagent_turn_used'", [owner]);
    expect(rows[0].n).toBe(3);
  });

  const bad: [string, unknown][] = [
    ["props가 비어 있다", {}],
    ["키가 없고 다른 키만 있다", { task: randomUUID() }],
    ["키를 더했다", { agent_task_id: randomUUID(), count: 2 }],
    ["키를 더했다 (글)", { agent_task_id: randomUUID(), title: "Fix launcher" }],
    ["값이 null이다", { agent_task_id: null }],
    ["값이 숫자다", { agent_task_id: 123 }],
    ["값이 배열이다", { agent_task_id: [randomUUID()] }],
    ["값이 객체다", { agent_task_id: { id: randomUUID() } }],
    ["값이 uuid 글자가 아니다", { agent_task_id: "not-a-uuid" }],
    ["값이 빈 글자다", { agent_task_id: "" }],
    ["값 앞뒤에 글자가 붙었다", { agent_task_id: ` ${randomUUID()}` }],
    ["값 뒤에 글자가 붙었다", { agent_task_id: `${randomUUID()}x` }],
    ["값에 줄바꿈이 붙었다", { agent_task_id: `${randomUUID()}\n` }],
    ["값이 대문자 uuid다 (같은 턴을 대소문자로 두 번 세지 못하게 소문자만 받는다)", { agent_task_id: randomUUID().toUpperCase() }],
    ["값이 중괄호 uuid다", { agent_task_id: `{${randomUUID()}}` }],
    ["값이 하이픈 없는 uuid다", { agent_task_id: randomUUID().replaceAll("-", "") }],
  ];
  it.each(TURN_TYPES)("%s: props 모양이 틀리면 23514로 거절한다", async (type) => {
    const owner = await user();
    for (const [label, props] of bad) await expect(turn(owner, type, props), label).rejects.toMatchObject({ code: "23514" });
    await expect(turn(owner, type, [randomUUID()])).rejects.toMatchObject({ code: "23514" });
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where user_id = $1 and type = $2", [owner, type]);
    expect(rows[0].n).toBe(0);
  });

  it("전용 check는 T2 두 종류에만 걸린다: 다른 종류는 props 모양이 지금처럼 자유롭다 (객체이기만 하면)", async () => {
    const owner = await user();
    await db.query("insert into public.metric_events (user_id, type, props) values ($1, 'external_sessions_shown', $2::jsonb)", [owner, JSON.stringify({ rows_bucket: "1", held_bucket: "0" })]);
    await day(owner, "project_sessions_opened");
    await expect(db.query("insert into public.metric_events (user_id, type, props) values ($1, 'app_opened', '[]'::jsonb)", [owner])).rejects.toMatchObject({ code: "23514" });
    const { rows } = await db.query<{ names: string[] }>(
      "select array_agg(conname order by conname) as names from pg_constraint where conrelid = 'public.metric_events'::regclass and contype = 'c' and conname like 'metric_events_%'",
    );
    expect(rows[0].names).toContain("metric_events_props_shape");
    expect(rows[0].names).toContain("metric_events_subagent_turn_props");
  });
});

describe("인덱스 · 제약 이름과 모양", () => {
  it("부분 unique 인덱스 넷이 있다 (열기 둘은 UTC 날짜, T2 둘은 agent_task_id)", async () => {
    const { rows } = await db.query<{ indexname: string; indexdef: string }>(
      "select indexname, indexdef from pg_indexes where schemaname = 'public' and tablename = 'metric_events' and indexname like any (array['metric_events_project_sessions_opened%', 'metric_events_subagent_%']) order by indexname",
    );
    expect(rows.map((r) => r.indexname)).toEqual([
      "metric_events_project_sessions_opened_day_idx",
      "metric_events_subagent_question_redirected_task_idx",
      "metric_events_subagent_row_opened_day_idx",
      "metric_events_subagent_turn_used_task_idx",
    ]);
    for (const row of rows) expect(row.indexdef).toMatch(/^CREATE UNIQUE INDEX/);
    // 괄호 · 따옴표를 지우고 비교한다 (pg_get_indexdef가 식을 감싸는 괄호 개수는 버전마다 다르다)
    const flat = Object.fromEntries(rows.map((r) => [r.indexname, r.indexdef.replace(/[()"]/g, "").replace(/\s+/g, " ")]));
    expect(flat.metric_events_project_sessions_opened_day_idx).toContain("user_id, at AT TIME ZONE 'UTC'::text::date WHERE type = 'project_sessions_opened'::text");
    expect(flat.metric_events_subagent_row_opened_day_idx).toContain("user_id, at AT TIME ZONE 'UTC'::text::date WHERE type = 'subagent_row_opened'::text");
    expect(flat.metric_events_subagent_turn_used_task_idx).toContain("user_id, props ->> 'agent_task_id'::text WHERE type = 'subagent_turn_used'::text");
    expect(flat.metric_events_subagent_question_redirected_task_idx).toContain("user_id, props ->> 'agent_task_id'::text WHERE type = 'subagent_question_redirected'::text");
  });

  it("기존 props 검사(metric_events_props_shape: 객체인지만)는 그대로다", async () => {
    const { rows } = await db.query<{ def: string }>("select pg_get_constraintdef(oid) as def from pg_constraint where conname = 'metric_events_props_shape'");
    expect(rows).toHaveLength(1);
    expect(rows[0].def).toBe("CHECK ((jsonb_typeof(props) = 'object'::text))");
  });
});

describe("마이그레이션 경계 (20261209000000_agent_tree_metrics)", () => {
  const sql = code(NEW_MIGRATION);

  it("한 트랜잭션, 짧은 lock_timeout. 종류 검사 · props 검사 · 인덱스 넷뿐이다 (새 표 · 함수 · 정책 · 트리거 · 열 · 권한 변경 0)", () => {
    expect(sql.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    expect(sql.endsWith("commit;")).toBe(true);
    expect(sql.match(/^begin;$/gm)).toHaveLength(1);
    expect(sql.match(/^commit;$/gm)).toHaveLength(1);
    expect(sql).not.toMatch(/create\s+(or\s+replace\s+)?(table|function|trigger|policy|view|domain|type)\b/i);
    expect(sql).not.toMatch(/alter\s+table\s+public\.metric_events\s+(add|drop)\s+column/i);
    expect(sql).not.toMatch(/\bgrant\b|\brevoke\b/i);
    expect(sql).not.toMatch(/\b(insert|update|delete)\b/i);
    expect(sql.match(/create\s+unique\s+index/gi)).toHaveLength(4);
    expect(sql.match(/add\s+constraint/gi)).toHaveLength(2);
    // 기존 props 검사는 건드리지 않는다
    expect(sql).not.toMatch(/metric_events_props_shape/);
  });

  it("종류 검사 = 바로 앞 마이그레이션(20261207)의 목록 전체 + 새 넷 (순서도 그대로, 중복 없음)", () => {
    expect(typeList(PREVIOUS_MIGRATION)).toEqual(LIST_20261207);
    expect(typeList(NEW_MIGRATION)).toEqual([...LIST_20261207, ...NEW_TYPES]);
    expect(new Set(typeList(NEW_MIGRATION)).size).toBe(typeList(NEW_MIGRATION).length);
  });

  it("20261207 · 20261206 목록의 종류를 하나도 잃지 않는다", () => {
    const next = new Set(typeList(NEW_MIGRATION));
    for (const type of typeList(PREVIOUS_MIGRATION)) expect(next.has(type), type).toBe(true);
    for (const type of typeList(D2_MIGRATION)) expect(next.has(type), type).toBe(true);
  });

  it("20261207과 20261209 사이에 종류 검사를 다시 만드는 파일이 있으면 그 목록을 이어 가져온다 (20261208 같은 파일이 새 종류를 더하면 이 파일 목록을 고친다)", () => {
    const between = readdirSync(MIGRATIONS).filter((name) => name.endsWith(".sql") && name > PREVIOUS_MIGRATION && name < NEW_MIGRATION);
    const mine = new Set(typeList(NEW_MIGRATION));
    for (const name of between) {
      if (!/metric_events_type_check/i.test(code(name))) continue;
      for (const type of typeList(name)) expect(mine.has(type), `${name} ${type}`).toBe(true);
    }
  });

  it("이 파일 뒤에 종류 검사를 다시 만드는 마이그레이션은 이 넷을 이어 가져온다", () => {
    for (const name of readdirSync(MIGRATIONS).filter((n) => n.endsWith(".sql") && n > NEW_MIGRATION)) {
      if (!/metric_events_type_check/i.test(code(name))) continue;
      const later = new Set(typeList(name));
      for (const type of NEW_TYPES) expect(later.has(type), `${name} ${type}`).toBe(true);
    }
  });

  it("props 검사는 T2 두 종류에만 걸고, 키 agent_task_id 하나 · 문자열 · 소문자 uuid 글자를 요구한다", () => {
    expect(sql).toMatch(/add constraint metric_events_subagent_turn_props\s+check \(\s*type not in \('subagent_turn_used', 'subagent_question_redirected'\)\s+or \(/);
    expect(sql).toMatch(/coalesce\(jsonb_typeof\(props -> 'agent_task_id'\), ''\) = 'string'/);
    expect(sql).toMatch(/\(props - 'agent_task_id'\) = '\{\}'::jsonb/);
    expect(sql).toMatch(/props ->> 'agent_task_id' ~ '\^\[0-9a-f\]\{8\}-\[0-9a-f\]\{4\}-\[0-9a-f\]\{4\}-\[0-9a-f\]\{4\}-\[0-9a-f\]\{12\}\$'/);
  });

  it("인덱스는 종류마다 하나씩, 열기 둘은 UTC 날짜별 T2 둘은 agent_task_id별이다", () => {
    for (const type of DAY_TYPES) {
      expect(sql).toMatch(new RegExp(`create unique index metric_events_${type}_day_idx\\s+on public\\.metric_events \\(user_id, \\(\\("at" at time zone 'UTC'\\)::date\\)\\)\\s+where type = '${type}';`));
    }
    for (const type of TURN_TYPES) {
      expect(sql).toMatch(new RegExp(`create unique index metric_events_${type}_task_idx\\s+on public\\.metric_events \\(user_id, \\(props ->> 'agent_task_id'\\)\\)\\s+where type = '${type}';`));
    }
  });
});

// 적용 순서 가드: 이 파일은 종류 검사를 "20261207의 목록 + 넷"으로 다시 만든다. 20261207보다 먼저 적용하면 20261207이 나중에 검사를 다시 만들면서 이 넷이 조용히 빠진다
// (운영 DB는 파일을 하나씩 적용하므로 순서를 사람이 지킨다). 그래서 맨 앞에서 20261207의 새 종류가 검사에 있는지 보고, 없으면 예외로 멈춘다.
describe("적용 순서 가드 (20261209 → 20261207 → 20261206)", () => {
  const APPLY = { timeout: 300_000 };
  const mineSql = read(NEW_MIGRATION);
  const typeCheckHas = async (target: PGlite, type: string) =>
    (await target.query<{ has: boolean }>("select pg_get_constraintdef(oid) like $1 as has from pg_constraint where conname = 'metric_events_type_check'", [`%'${type}'%`])).rows[0].has;

  it("맨 앞(begin · lock_timeout 바로 뒤, 어떤 DDL보다 먼저)에서 종류 검사에 20261207의 새 종류가 있는지 보고 없으면 20261207을 먼저 적용하라는 예외를 던진다", () => {
    const body = code(NEW_MIGRATION);
    const afterLock = body.slice("begin;\nset local lock_timeout = '5s';".length).trimStart();
    expect(afterLock.startsWith("do $$")).toBe(true);
    const guard = afterLock.slice(0, afterLock.indexOf("$$;") + 3);
    expect(guard).toMatch(/metric_events_type_check/);
    for (const type of ["claude_app_session_opened", "claude_app_message_sent", "claude_app_chat_deleted"]) expect(guard, type).toContain(type);
    expect(guard).toMatch(/raise exception[^;]*20261207000000_claude_app_chats/);
    // 가드보다 앞에 표 · 인덱스 · 제약을 만들거나 바꾸는 문장이 없다
    const before = body.slice(0, body.indexOf(guard));
    expect(before).not.toMatch(/\b(create|alter|drop|insert|update|delete)\b/i);
  });

  it("20261207 없이 20261209를 적용하면 거절되고 아무것도 남지 않는다 (실제 적용)", APPLY, async () => {
    const empty = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [PREVIOUS_MIGRATION, NEW_MIGRATION] })) await empty.exec(script);
      expect(await typeCheckHas(empty, "claude_app_session_opened")).toBe(true);
      expect(await typeCheckHas(empty, "claude_app_chat_deleted")).toBe(false);
      await expect(empty.exec(mineSql)).rejects.toThrow(/20261207/);
      await empty.exec("rollback").catch(() => undefined);
      expect(await typeCheckHas(empty, "project_sessions_opened")).toBe(false);
      const { rows } = await empty.query<{ n: number }>("select count(*)::int as n from pg_indexes where tablename = 'metric_events' and indexname like 'metric_events_%_idx' and (indexname like '%project_sessions%' or indexname like '%subagent%')");
      expect(rows[0].n).toBe(0);
      const { rows: cons } = await empty.query<{ n: number }>("select count(*)::int as n from pg_constraint where conname = 'metric_events_subagent_turn_props'");
      expect(cons[0].n).toBe(0);
    } finally {
      await empty.close();
    }
  });

  it("20261206 · 20261207 둘 다 없는 DB에서도 같다: 멈춘다", APPLY, async () => {
    const empty = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [D2_MIGRATION, PREVIOUS_MIGRATION, NEW_MIGRATION] })) await empty.exec(script);
      expect(await typeCheckHas(empty, "claude_app_session_opened")).toBe(false);
      await expect(empty.exec(mineSql)).rejects.toThrow(/20261207|claude_app/);
    } finally {
      await empty.close();
    }
  });

  it("20261207까지 적용한 뒤에는 통과한다 (정상 순서): 앞 종류가 모두 남고 새 넷이 더해진다", APPLY, async () => {
    const fresh = await openPglite();
    try {
      for (const script of await supabaseSchemaScripts({ without: [NEW_MIGRATION] })) await fresh.exec(script);
      expect(await typeCheckHas(fresh, "claude_app_chat_deleted")).toBe(true);
      expect(await typeCheckHas(fresh, "project_sessions_opened")).toBe(false);
      await fresh.exec(mineSql);
      for (const type of [...LIST_20261207, ...NEW_TYPES]) expect(await typeCheckHas(fresh, type), type).toBe(true);
    } finally {
      await fresh.close();
    }
  });
});
