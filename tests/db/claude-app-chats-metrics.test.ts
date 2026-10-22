import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 대화 저장 마이그레이션(20261207000000)이 다시 만드는 두 목록 (OA PR-D3s, 계약 25.2.1 · 25.11):
//   · metric_events_type_check = 바로 앞 목록(20261206000000, PR-D2) 전체 + claude_app_message_sent · claude_app_chat_deleted
//   · rate_limit_events_kind_check · take_rate_limit = 20261204000000 본문 그대로 + claude_app_chat
// 이 PR은 PR-D2(20261206000000)보다 **늦게** 병합된다. D2가 아직 이 브랜치에 없어도 시험이 돌도록 20261206의 목록을 글자 그대로 아래에 두고,
// D2의 파일이 있으면(병합 뒤) 그 파일의 목록과 이 글자 그대로의 목록이 같은지도 본다.

const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const NEW_FILE = "20261207000000_claude_app_chats.sql";
const D2_FILE = "20261206000000_claude_app_session_metrics.sql";
const ATTACH_FILE = "20261204000000_agent_session_attach.sql";

/** 20261206000000_claude_app_session_metrics.sql의 metric_events_type_check 목록 (= 20261204000000의 목록 + claude_app_session_opened) */
const LIST_20261206 = [
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
];
const NEW_TYPES = ["claude_app_message_sent", "claude_app_chat_deleted"];
/** 20261204000000의 rate_limit_events 종류 목록 */
const KINDS_20261204 = ["ask", "connection_start", "action_create", "run_create", "bridge_register", "bridge_events", "bridge_ack", "bridge_poll", "bridge_decide", "ai_key", "agent_attach"];

const read = (file: string) => readFileSync(path.join(MIGRATIONS, file), "utf8");
const stripComments = (sql: string) => sql.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/--[^\n]*/g, " ");
function list(file: string, pattern: RegExp): string[] {
  const text = stripComments(read(file));
  const found = [...text.matchAll(pattern)].at(-1)?.[1];
  if (found === undefined) throw new Error(`${file}: 목록을 찾지 못했다`);
  return [...found.matchAll(/'([^']*)'/g)].map((m) => m[1]);
}
const typeList = (file: string) => list(file, /constraint\s+metric_events_type_check\s+check\s*\(\s*type\s+in\s*\(([^)]*)\)\s*\)/gi);
const kindList = (file: string) => list(file, /constraint\s+rate_limit_events_kind_check\s+check\s*\(\s*kind\s+in\s*\(([^)]*)\)\s*\)/gi);

describe("metric_events 종류 검사 (20261207000000)", () => {
  it("20261206의 전체 목록 + 새 종류 둘과 정확히 같다 (순서 · 중복 포함)", () => {
    expect(typeList(NEW_FILE)).toEqual([...LIST_20261206, ...NEW_TYPES]);
    expect(new Set(typeList(NEW_FILE)).size).toBe(typeList(NEW_FILE).length);
  });

  it("바로 앞 목록(20261204)의 모든 종류를 이어 가져온다 (빠뜨리면 옛 행 · 옛 코드가 거절된다)", () => {
    const next = typeList(NEW_FILE);
    for (const type of typeList(ATTACH_FILE)) expect(next, type).toContain(type);
  });

  it("D2의 파일이 있으면 그 목록이 위 글자 그대로의 목록과 같다 (D2 병합 뒤 어긋남을 잡는다)", () => {
    if (!existsSync(path.join(MIGRATIONS, D2_FILE))) return;
    expect(typeList(D2_FILE)).toEqual(LIST_20261206);
  });

  it("D2가 병합되기 전에도 D2 종류를 거절하지 않는다: 20261207이 가장 나중 정의이고 D2 종류를 담는다", () => {
    expect(typeList(NEW_FILE)).toContain("claude_app_session_opened");
  });
});

describe("rate_limit_events 종류 · take_rate_limit (20261207000000)", () => {
  it("종류 목록 = 20261204 목록 + claude_app_chat + claude_app_sent + claude_app_chat_day", () => {
    expect(kindList(NEW_FILE)).toEqual([...KINDS_20261204, "claude_app_chat", "claude_app_sent", "claude_app_chat_day"]);
    expect(kindList(ATTACH_FILE)).toEqual(KINDS_20261204);
  });
});

describe("DB: 새 종류가 받아들여진다", () => {
  let db: PGlite;
  beforeAll(async () => {
    db = await createLocalSupabase();
  }, 60_000);
  afterAll(async () => {
    await db?.close();
  });
  const user = async () => {
    const id = randomUUID();
    await db.query("insert into auth.users (id, email) values ($1, $2)", [id, `${id}@example.com`]);
    return id;
  };

  it("metric_events: 새 종류 둘과 이어 받은 종류가 모두 들어가고, 모르는 종류는 거절된다", async () => {
    const owner = await user();
    for (const type of [...NEW_TYPES, ...LIST_20261206]) await db.query("insert into public.metric_events (user_id, type) values ($1, $2)", [owner, type]);
    await expect(db.query("insert into public.metric_events (user_id, type) values ($1, 'claude_app_chat_read')", [owner])).rejects.toMatchObject({ code: "23514" });
    const { rows } = await db.query<{ def: string }>("select pg_get_constraintdef(oid) as def from pg_constraint where conname = 'metric_events_type_check'");
    for (const type of NEW_TYPES) expect(rows[0].def).toContain(type);
  });

  it("앱(authenticated)은 이 종류를 직접 남기지 못한다 (route가 서버 권한으로 남긴다)", async () => {
    const owner = await user();
    await asUser(db, owner, async () => {
      for (const type of NEW_TYPES) {
        await expect(db.query("insert into public.metric_events (type) values ($1)", [type]), type).rejects.toMatchObject({ code: expect.stringMatching(/^(42501|23514)$/) });
      }
    });
  });

  it("take_rate_limit: claude_app_chat을 센다 (사용자별), 앞 종류도 그대로 센다, 모르는 종류는 거절한다", async () => {
    const a = await user();
    const b = await user();
    const take = async (owner: string, kind: string, max = 3) => (await db.query<{ at: Date | null }>("select public.take_rate_limit($1, $2, $3, 600) as at", [owner, kind, max])).rows[0].at;
    for (let i = 0; i < 3; i++) expect(await take(a, "claude_app_chat")).toBeNull();
    const retry = await take(a, "claude_app_chat");
    expect(retry).toBeInstanceOf(Date);
    expect(retry!.getTime() - Date.now()).toBeGreaterThan(9 * 60_000);
    expect(await take(b, "claude_app_chat")).toBeNull();
    // 종류마다 따로 센다
    expect(await take(a, "agent_attach")).toBeNull();
    for (const kind of ["ask", "connection_start", "action_create", "run_create", "bridge_register", "ai_key", "agent_attach"]) expect(await take(b, kind), kind).toBeNull();
    await expect(take(a, "claude_app_read")).rejects.toThrow(/모르는 종류|rate_limit/);
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.rate_limit_events where user_id = $1 and kind = 'claude_app_chat'", [a]);
    expect(rows[0].n).toBe(3);
    await expect(db.query("insert into public.rate_limit_events (user_id, kind) values ($1, 'claude_app_other')", [a])).rejects.toMatchObject({ code: "23514" });
    // bridge 종류는 여전히 bridge id가 있어야 한다 (본문을 그대로 이어 받았다)
    await expect(take(a, "bridge_poll")).rejects.toThrow(/invalid bridge/);
  });

  it("take_rate_limit: claude_app_sent(보내기 결과 지표)는 claude_app_chat(저장)과 따로 센다 — 한쪽이 차도 다른 쪽은 열려 있다", async () => {
    const a = await user();
    const b = await user();
    const take = async (owner: string, kind: string, max = 3) => (await db.query<{ at: Date | null }>("select public.take_rate_limit($1, $2, $3, 600) as at", [owner, kind, max])).rows[0].at;
    for (let i = 0; i < 3; i++) expect(await take(a, "claude_app_sent")).toBeNull();
    const retry = await take(a, "claude_app_sent");
    expect(retry).toBeInstanceOf(Date);
    expect(retry!.getTime() - Date.now()).toBeGreaterThan(9 * 60_000);
    // 저장 종류는 영향이 없다 (그리고 반대도 같다)
    for (let i = 0; i < 3; i++) expect(await take(a, "claude_app_chat")).toBeNull();
    expect(await take(a, "claude_app_chat")).toBeInstanceOf(Date);
    expect(await take(b, "claude_app_sent")).toBeNull();
    for (const kind of ["claude_app_chat", "agent_attach", "ask"]) expect(await take(b, kind), kind).toBeNull();
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.rate_limit_events where user_id = $1 and kind = 'claude_app_sent'", [a]);
    expect(rows[0].n).toBe(3);
    // 종류 검사가 받는다 (take_rate_limit 밖의 직접 insert도)
    await db.query("insert into public.rate_limit_events (user_id, kind) values ($1, 'claude_app_sent')", [b]);
  });

  it("take_rate_limit: claude_app_chat_day(저장 PUT의 하루 한도)는 하루(86,400초) 창으로 세고 10분 한도 종류와 따로 센다", async () => {
    const a = await user();
    const take = async (owner: string, kind: string, max: number, windowSeconds: number) =>
      (await db.query<{ at: Date | null }>("select public.take_rate_limit($1, $2, $3, $4) as at", [owner, kind, max, windowSeconds])).rows[0].at;
    for (let i = 0; i < 3; i++) expect(await take(a, "claude_app_chat_day", 3, 86_400)).toBeNull();
    const retry = await take(a, "claude_app_chat_day", 3, 86_400);
    expect(retry).toBeInstanceOf(Date);
    expect(retry!.getTime() - Date.now()).toBeGreaterThan(23 * 3600_000);
    // 10분 한도 종류는 영향 없다
    for (let i = 0; i < 3; i++) expect(await take(a, "claude_app_chat", 3, 600)).toBeNull();
    // 하루 창 밖(25시간 전)의 시도는 세지 않는다
    await db.query("update public.rate_limit_events set created_at = now() - interval '25 hours' where user_id = $1 and kind = 'claude_app_chat_day'", [a]);
    expect(await take(a, "claude_app_chat_day", 3, 86_400)).toBeNull();
  });
});
