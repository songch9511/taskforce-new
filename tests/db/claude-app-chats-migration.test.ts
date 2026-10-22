import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

// 마이그레이션 경계 (20261207000000_claude_app_chats, OA PR-D3s): 파일 글자만 본다 (DB 0). agent-session-attach.test.ts의 경계 시험과 같은 방식.

const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const FILE = "20261207000000_claude_app_chats.sql";
const PREVIOUS_RATE_LIMIT_MIGRATION = "20261204000000_agent_session_attach.sql";

const stripComments = (sql: string) => sql.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n");
const migration = readFileSync(path.join(MIGRATIONS, FILE), "utf8");
const code = stripComments(migration).trim();

/** `create [or replace] function public.take_rate_limit(...)`부터 `$$;`까지 (주석 없이, 공백을 하나로) */
function takeRateLimitBody(sql: string): string {
  const text = stripComments(sql);
  const from = text.search(/create (?:or replace )?function public\.take_rate_limit\(/);
  if (from < 0) throw new Error("take_rate_limit not found");
  const open = text.indexOf("$$", from);
  const close = text.indexOf("$$;", open + 2);
  return text.slice(from, close + 3).replace(/\s+/g, " ").trim();
}

describe("마이그레이션 경계 (20261207000000_claude_app_chats)", () => {
  it("한 트랜잭션, 짧은 lock_timeout", () => {
    expect(code.startsWith("begin;\nset local lock_timeout = '5s';")).toBe(true);
    expect(code.endsWith("commit;")).toBe(true);
    expect(code.match(/^begin;$/gm)).toHaveLength(1);
    expect(code.match(/^commit;$/gm)).toHaveLength(1);
  });

  it("만드는 것: 표 둘 · 도메인 하나 · 함수 둘(+ take_rate_limit 재정의) · 트리거 하나(updated_at)뿐이다", () => {
    expect([...code.matchAll(/create table ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.claude_app_chats", "public.claude_app_chat_messages"]);
    expect([...code.matchAll(/create domain ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.claude_app_tool_name"]);
    expect([...code.matchAll(/create (?:or replace )?function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["save_claude_app_chat", "delete_claude_app_chat", "take_rate_limit"]);
    expect([...code.matchAll(/create function public\.([a-z_]+)/g)].map((m) => m[1])).toEqual(["save_claude_app_chat", "delete_claude_app_chat"]);
    expect([...code.matchAll(/create trigger ([a-z_]+)/g)].map((m) => m[1])).toEqual(["claude_app_chats_set_updated_at"]);
    // 정책은 owner_all 둘뿐이고 기존 표의 정책(앱 insert 정책 포함)은 건드리지 않는다
    expect([...code.matchAll(/create policy "([a-z_]+)" on ([a-z_.]+)/g)].map((m) => [m[1], m[2]])).toEqual([
      ["owner_all", "public.claude_app_chats"],
      ["owner_all", "public.claude_app_chat_messages"],
    ]);
    expect(code).not.toMatch(/owner_insert_client_app_types|drop policy|alter policy/i);
    // 바꾸는 기존 표는 metric_events(종류 검사)와 rate_limit_events(종류 검사)뿐이다
    expect([...code.matchAll(/alter table ([a-z_.]+)/g)].map((m) => m[1])).toEqual([
      "public.claude_app_chats",
      "public.claude_app_chat_messages",
      "public.metric_events",
      "public.metric_events",
      "public.rate_limit_events",
      "public.rate_limit_events",
    ]);
  });

  it("자동 정리가 없다 (26장 Q-D3b): purge · retention · 만료 · 오래된 행을 지우는 문장이 없다", () => {
    expect(code).not.toMatch(/purge|retention|expire|interval\s+'/i);
    expect([...code.matchAll(/delete from ([a-z_.]+)/g)].map((m) => m[1])).toEqual(["public.claude_app_chats"]);
  });

  it("함수 권한: PUBLIC · anon · authenticated는 거두고 service_role에만 준다. invoker(security definer 아님) + search_path 빈 값", () => {
    for (const signature of ["save_claude_app_chat\\(uuid, uuid, text, text, jsonb\\)", "delete_claude_app_chat\\(uuid, uuid\\)"]) {
      expect(code).toMatch(new RegExp(`revoke all on function public\\.${signature} from public, anon, authenticated;`));
      expect(code).toMatch(new RegExp(`grant execute on function public\\.${signature} to service_role;`));
    }
    expect(code).toMatch(/revoke execute on function public\.take_rate_limit from public, anon, authenticated;/);
    expect(code).toMatch(/grant execute on function public\.take_rate_limit to service_role;/);
    expect(code).not.toMatch(/\bgrant\s+execute\b[^;]*\bto\s+(?:public|anon|authenticated)\b/i);
    expect(code).not.toMatch(/security definer/i);
    expect(code.match(/set search_path = ''/g)).toHaveLength(3);
  });

  it("표 권한: 앱 역할은 select만 받는다 (insert · update · delete · truncate를 준 적이 없다)", () => {
    expect(code).toMatch(/revoke all on public\.claude_app_chats from anon, authenticated;\s+grant select on public\.claude_app_chats to authenticated;/);
    expect(code).toMatch(/revoke all on public\.claude_app_chat_messages from anon, authenticated;\s+grant select on public\.claude_app_chat_messages to authenticated;/);
    expect([...code.matchAll(/grant ([a-z, ]+) on (?!function)([a-z_. ]+) to ([a-z_, ]+);/g)].map((m) => [m[1], m[2], m[3]])).toEqual([
      ["select", "public.claude_app_chats", "authenticated"],
      ["select", "public.claude_app_chat_messages", "authenticated"],
    ]);
  });

  it("두 표 모두 user_id + auth.users cascade + 부모와의 (id, user_id) 복합 외래키 + (chat_id, mac_ref) 멱등 열쇠", () => {
    expect(code).toMatch(/user_id uuid not null default auth\.uid\(\) references auth\.users \(id\) on delete cascade/g);
    expect(code.match(/user_id uuid not null default auth\.uid\(\) references auth\.users \(id\) on delete cascade/g)).toHaveLength(2);
    expect(code).toMatch(/foreign key \(bridge_id, user_id\)\s+references public\.bridges \(id, user_id\) on delete cascade/);
    expect(code).toMatch(/foreign key \(chat_id, user_id\)\s+references public\.claude_app_chats \(id, user_id\) on delete cascade/);
    expect(code).toMatch(/unique \(chat_id, mac_ref\)/);
    expect(code).toMatch(/unique \(bridge_id, session_ref\)/);
    // bridge 해제(revoke)는 대화를 지우지 않는다: 해제 트리거를 만들지 않는다
    expect(code).not.toMatch(/on_bridge_revoked|after update of status on public\.bridges/i);
  });

  it("바로 앞 속도 제한 정의의 집은 20261204다 (그 뒤 파일이 종류 검사 · take_rate_limit을 다시 만들지 않았다)", () => {
    const later = readdirSync(MIGRATIONS).filter(
      (name) => name > PREVIOUS_RATE_LIMIT_MIGRATION && name < FILE && /rate_limit_events_kind_check|function public\.take_rate_limit\(/i.test(stripComments(readFileSync(path.join(MIGRATIONS, name), "utf8"))),
    );
    expect(later).toEqual([]);
  });

  it("take_rate_limit 본문은 20261204의 정의에서 종류 claude_app_chat 하나만 더한다", () => {
    const before = takeRateLimitBody(readFileSync(path.join(MIGRATIONS, PREVIOUS_RATE_LIMIT_MIGRATION), "utf8"));
    const after = takeRateLimitBody(migration);
    expect(after).not.toBe(before);
    expect(after.replace(",'claude_app_chat'", "")).toBe(before);
    expect(after.match(/'claude_app_chat'/g)).toHaveLength(1);
  });

  it("이 파일 뒤에 같은 종류 검사를 다시 만드는 마이그레이션이 없다 (있으면 두 새 종류를 이어 가져와야 한다)", () => {
    const after = readdirSync(MIGRATIONS).filter((name) => name > FILE && name.endsWith(".sql"));
    for (const name of after) {
      const text = stripComments(readFileSync(path.join(MIGRATIONS, name), "utf8"));
      if (!/metric_events_type_check/i.test(text)) continue;
      expect(text, name).toContain("claude_app_message_sent");
      expect(text, name).toContain("claude_app_chat_deleted");
    }
  });
});
