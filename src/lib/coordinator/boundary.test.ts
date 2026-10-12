import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

// 권한 경계 (불변식 I01 · I04 · I14, ARCH06/07, D13): 코디네이터는 사건을 읽고 처리 결과를 기록할 뿐이다. 정책 · 승인 · 도구 · begin_call · resolve · 실행 순서의 입력이 아니고,
// Action 값 · Claim · run · 단계를 쓰지 않는다. 범위(work_contexts) · 기억 · version은 자료 후보에만 쓰인다. 반대 방향(실행 · 맥락층 · 원문 처리가 코디네이터를 가져오는 것)도 막는다.

const ROOT = path.resolve(__dirname, "../../..");
const strip = (text: string) => text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");
const sqlOf = (file: string) =>
  readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");

function files(dir: string, includeTests = false): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return files(full, includeTests);
    return /\.ts$/.test(name) && (includeTests || !/\.test\.ts$/.test(name)) ? [full] : [];
  });
}

const COORDINATOR_FILES = files(path.join(ROOT, "src/lib/coordinator"));
const MIGRATION = path.join(ROOT, "supabase/migrations/20261110000000_coordinator_core.sql");

describe("코디네이터 TS ↔ 실행 권한 경계", () => {
  it("모듈 구성: 계약의 다섯 모듈 + 저장 · 읽기 · 설정 · 결정 대기 · sweep · 깨우기", () => {
    expect(COORDINATOR_FILES.map((f) => path.basename(f)).sort()).toEqual(
      ["coordinate.ts", "coordinator.config.ts", "impact.ts", "inbox.ts", "judgments.ts", "pending.ts", "reads.ts", "routing.ts", "store.ts", "sweep.ts", "types.ts", "wake.ts"].sort(),
    );
  });

  it("실행 코드는 깨우기 주소 하나(@/lib/execution/wake의 wakeOrigin)만 가져온다: 정책 · 승인 · 도구 · 스위치 · 저장소 · 실행기 · 한도를 가져오지 않는다", () => {
    const imports = COORDINATOR_FILES.flatMap((file) => [...readFileSync(file, "utf8").matchAll(/from ["']([^"']*execution[^"']*)["']|import\(["']([^"']*execution[^"']*)["']\)/g)].map((m) => `${path.basename(file)} -> ${m[1] ?? m[2]}`));
    expect(imports).toEqual(["wake.ts -> @/lib/execution/wake"]);
    expect(readFileSync(path.join(ROOT, "src/lib/coordinator/wake.ts"), "utf8")).toMatch(/import \{ wakeOrigin \} from "@\/lib\/execution\/wake";/);
  });

  it("코드에 정책 · 승인 · begin_call · 크레딧 · Action 쓰기 함수 이름이 없다 (주석 제외). 읽는 execution_ 표는 run · step뿐이다", () => {
    const forbidden = /\b(begin_call|execution_policies|execution_controls|execution_tools|execution_actors|execution_recipient_allowlist|execution_connection_policies|execution_intents|execution_approvals|approval_hash|auto_allowed|prepare_step|create_run|append_step|stop_run|approve_step|write_action|set_action_progress|remember_memory_item|credit_[a-z]+|grant_credits)\b/;
    const offenders = COORDINATOR_FILES.filter((file) => forbidden.test(strip(readFileSync(file, "utf8")))).map((file) => path.basename(file));
    expect(offenders).toEqual([]);
    const tables = new Set(COORDINATOR_FILES.flatMap((file) => [...strip(readFileSync(file, "utf8")).matchAll(/\.from\("([a-z_]+)"\)/g)].map((m) => m[1])));
    expect([...tables].sort()).toEqual(["action_events", "actions", "claims", "context_members", "conversation_messages", "evidence", "execution_runs", "execution_steps", "sources", "work_contexts"]);
  });

  it("DB 쓰기는 모두 사건 큐 RPC 하나씩이다: insert · update · upsert · delete 호출이 없고, rpc는 coordinator_* 와 읽기 함수만 부른다", () => {
    for (const file of COORDINATOR_FILES) {
      const code = strip(readFileSync(file, "utf8"));
      expect(code, path.basename(file)).not.toMatch(/\.(insert|upsert|delete)\(/);
      // .update(는 결정 대기 묶음 version을 만드는 해시(createHash)뿐이고 그 파일은 표를 직접 읽지 않는다(.from 없음)
      if (/\.update\(/.test(code)) {
        expect(path.basename(file)).toBe("pending.ts");
        expect(code).not.toMatch(/\.from\(/);
        expect(code).toMatch(/createHash\("sha256"\)\.update\(/);
      }
    }
    const rpcs = new Set(COORDINATOR_FILES.flatMap((file) => [...strip(readFileSync(file, "utf8")).matchAll(/(?:rpc(?:<[^>]*>)?\(|rpc\(\s*)"([a-z_]+)"/g)].map((m) => m[1])));
    expect([...rpcs].sort()).toEqual([
      "coordinator_claim", "coordinator_enqueue", "coordinator_enqueue_due_timers", "coordinator_fail", "coordinator_finish", "coordinator_pending_inputs",
      "coordinator_recover_missing", "coordinator_reserve_jev_calls", "coordinator_reserve_model_call", "source_document_ids",
    ]);
  });

  it("AI 호출 모듈(llm · jev · embed · budget)을 직접 가져오지 않는다: 모델은 주입된 포트로만 닿고, 오류 클래스만 가져온다", () => {
    const imports = COORDINATOR_FILES.flatMap((file) => [...readFileSync(file, "utf8").matchAll(/from ["'](@\/lib\/ai\/[^"']+|@\/lib\/consent\/[^"']+)["']/g)].map((m) => `${path.basename(file)} -> ${m[1]}`));
    expect(imports.sort()).toEqual(["judgments.ts -> @/lib/ai/budget-error", "judgments.ts -> @/lib/consent/gate"]);
  });

  it("라우팅 표 · 영향 계산은 범위 · 기억 · 맥락층 모듈을 가져오지 않는다 (순수 모듈)", () => {
    for (const name of ["routing.ts", "impact.ts", "inbox.ts", "types.ts"]) {
      const text = strip(readFileSync(path.join(ROOT, "src/lib/coordinator", name), "utf8"));
      expect(text, name).not.toMatch(/@\/lib\/(context|conversation|execution|ai|supabase)/);
    }
  });
});

describe("반대 방향: 실행 · 맥락층 · 원문 처리 · 대화는 코디네이터를 가져오지 않는다", () => {
  it("src/lib/execution · context · conversation · sources · pipeline에 @/lib/coordinator import가 없다", () => {
    const dirs = ["execution", "context", "conversation", "sources", "pipeline", "actions"].map((d) => path.join(ROOT, "src/lib", d));
    const offenders = dirs.flatMap((dir) => files(dir, true)).filter((file) => /@\/lib\/coordinator|\.\.\/coordinator\//.test(readFileSync(file, "utf8"))).map((f) => path.relative(ROOT, f));
    expect(offenders).toEqual([]);
  });
});

describe("마이그레이션 20261110000000 ↔ 실행 · Action 표 경계", () => {
  const sql = sqlOf(MIGRATION);

  it("쓰는 표는 inbox_events 하나다: insert · update · delete 대상이 모두 inbox_events (트리거는 읽기 + 적재뿐)", () => {
    const targets = new Set([...sql.matchAll(/\b(?:insert into|update|delete from)\s+public\.([a-z_]+)/g)].map((m) => m[1]));
    expect([...targets]).toEqual(["inbox_events"]);
  });

  it("새 표를 만들지 않는다 (pending_decisions 표 없음). 바꾸는 기존 표는 inbox_events 하나, 새 트리거는 읽기 전용 AFTER 트리거 일곱 개", () => {
    expect(sql).not.toMatch(/create table/i);
    expect([...new Set([...sql.matchAll(/alter table public\.([a-z_]+)/g)].map((m) => m[1]))]).toEqual(["inbox_events"]);
    const triggers = [...sql.matchAll(/create trigger (\S+)\s+(before|after) ([^]*?)on public\.([a-z_]+)/g)].map((m) => `${m[1]} ${m[2]} ${m[4]}`).sort();
    expect(triggers).toEqual([
      "coordinator_on_action_decision after action_events",
      "coordinator_on_approval after execution_approvals",
      "coordinator_on_approval_revoked after execution_approvals",
      "coordinator_on_context_version after work_contexts",
      "coordinator_on_run_stop after execution_runs",
      "coordinator_on_source_done after sources",
      "coordinator_on_user_message after conversation_messages",
      "inbox_events_guard before inbox_events",
    ].sort());
  });

  it("기존 함수를 다시 만들지 않는다 (begin_call · approval_hash · create_run · append_step · write_action 등 그대로): create or replace 0, drop 0", () => {
    expect(sql).not.toMatch(/create or replace/i);
    expect(sql).not.toMatch(/\bdrop (function|trigger|table|constraint|index)\b/i);
    expect(sql).not.toMatch(/\b(begin_call|prepare_step|settle_step|complete_internal_step|mark_unknown|approve_step|show_plan|revoke_approval|create_run|append_step|write_action|grant_credits)\b/);
  });

  it("실행 정책 · 도구 · 스위치 · 크레딧 · 연결별 정책 표를 읽지도 쓰지도 않는다 (읽는 execution_ 표는 steps · runs · approvals뿐)", () => {
    const mentioned = new Set([...sql.matchAll(/\bpublic\.((?:execution|credit)_[a-z_]+)\b/g)].map((m) => m[1]));
    expect([...mentioned].sort()).toEqual(["execution_approvals", "execution_runs", "execution_steps"]);
    expect(sql).not.toMatch(/\b(execution_policies|execution_controls|execution_tools|execution_actors|execution_recipient_allowlist|execution_connection_policies|credit_[a-z]+)\b/);
  });
});
