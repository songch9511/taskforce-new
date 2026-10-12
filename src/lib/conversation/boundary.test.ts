import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

// 권한 경계 (불변식 I04, DR10, 아키텍처 5.6 · 7.2): 대화 · 기억 · 제안은 실행 권한(정책 · 도구 · 스위치 · 승인 · 크레딧)을 읽거나 바꾸지 않고,
// consult · inform · correct가 Action · run을 만들지 않는다. Action은 채택(conversation_finish_turn → write_action)으로만, 기억은 remember_memory_item으로만 쓴다.
// eslint.config.mjs가 같은 import를 막는다. DB 쪽은 tests/db/conversations-v2.scenarios.ts.

const ROOT = path.resolve(__dirname, "../../..");

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return files(full);
    return /\.ts$/.test(name) && !/\.test\.ts$/.test(name) ? [full] : [];
  });
}

/** 주석을 뺀 코드 */
const code = (file: string) =>
  readFileSync(file, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:])\/\/.*$/gm, "$1");

const CONVERSATION_FILES = files(path.join(ROOT, "src/lib/conversation"));
const ROUTE_FILES = files(path.join(ROOT, "src/app/api/v2/conversations"));
const API_FILE = path.join(ROOT, "src/lib/api/conversations.ts");
const MIGRATION = path.join(ROOT, "supabase/migrations/20261106000000_conversations_v2.sql");

describe("대화 v2 ↔ 실행 권한 경계 (I04)", () => {
  it("src/lib/conversation 파일 목록 (새 파일이 생기면 이 경계를 다시 본다)", () => {
    expect(CONVERSATION_FILES.map((f) => path.basename(f)).sort()).toEqual(
      ["conversation.config.ts", "intent.config.ts", "intent.ts", "memory.ts", "proposal.ts", "referent.ts", "respond.ts", "store.ts"].sort(),
    );
  });

  it("대화 코드(모듈 · handler · route)는 실행 코드를 가져오지 않는다", () => {
    const offenders = [...CONVERSATION_FILES, ...ROUTE_FILES, API_FILE].flatMap((file) =>
      [/from ["']@\/lib\/execution/, /from ["'][^"']*\/execution(\/|["'])/, /import\(["'][^"']*execution/, /executionEnabled/]
        .filter((m) => m.test(readFileSync(file, "utf8")))
        .map((m) => `${path.relative(ROOT, file)}: ${m}`),
    );
    expect(offenders).toEqual([]);
  });

  it("실행 정책 · 도구 · 스위치 · 승인 · 단계 · 크레딧 표와 실행 RPC를 가리키지 않는다 (run · 산출물은 앱이 보낸 id의 소유 확인 읽기만)", () => {
    const forbidden = /\b(execution_(policies|tools|controls|approvals|intents|steps|actors|recipient_allowlist|events|usage)|credit_(accounts|ledger|rates)|begin_call|create_run|prepare_step|complete_internal_step|grant_credits)\b/;
    const offenders = [...CONVERSATION_FILES, ...ROUTE_FILES, API_FILE].filter((file) => forbidden.test(code(file))).map((file) => path.relative(ROOT, file));
    expect(offenders).toEqual([]);
    const store = code(path.join(ROOT, "src/lib/conversation/store.ts"));
    expect(store.match(/from\("execution_[a-z_]+"\)\.select\("id"\)/g)?.length).toBe(2);
    expect(store).not.toMatch(/from\("execution_[a-z_]+"\)\s*\.\s*(insert|update|upsert|delete)/);
  });

  it("consult · inform · correct는 Action · run을 직접 쓰지 않는다: Action은 채택 RPC로만, 기억은 remember_memory_item(finish_turn 안)으로만", () => {
    const all = [...CONVERSATION_FILES, ...ROUTE_FILES, API_FILE].map(code).join("\n");
    expect(all).not.toMatch(/from\("(actions|claims|evidence|action_events|memory_items)"\)\s*\.\s*(insert|update|upsert|delete)/);
    expect(all).not.toMatch(/rpc\("(write_action|set_action_progress|start_action|remember_memory_item|create_run)"/);
    const rpcs = [...all.matchAll(/rpc\("([a-z_]+)"/g)].map((m) => m[1]).sort();
    expect([...new Set(rpcs)]).toEqual(["conversation_finish_turn", "conversation_post_message", "conversation_release_lease"]);
  });

  it("대화 마이그레이션은 실행 · 크레딧 표를 만들거나 고치거나 가리키지 않는다 (Action은 기존 write_action으로만)", () => {
    const sql = readFileSync(MIGRATION, "utf8")
      .split("\n")
      .filter((line) => !line.trim().startsWith("--"))
      .join("\n");
    expect(sql).not.toMatch(/execution_|credit_|approval/);
    expect(sql).not.toMatch(/insert into public\.(actions|claims|evidence|action_events)\b/);
    expect(sql).toMatch(/public\.write_action\(/);
  });

  it("실행 쪽 코드는 대화 모듈을 입력으로 가져오지 않는다", () => {
    const executionFiles = files(path.join(ROOT, "src/lib/execution"));
    expect(executionFiles.length).toBeGreaterThan(5);
    const offenders = executionFiles.filter((file) => /@\/lib\/conversation|\.\.\/conversation\//.test(readFileSync(file, "utf8"))).map((file) => path.relative(ROOT, file));
    expect(offenders).toEqual([]);
  });
});
