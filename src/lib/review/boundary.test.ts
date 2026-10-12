import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

// 권한 경계 (불변식 I04 · I14 · D13, 아키텍처 ARCH06 · ARCH07): 제안 · 읽음(Clear) · 복귀 요약은 Claim · Action 완료 · 기한 · resolve · 정책 · begin_call · 승인 hash ·
// intent · lease · unknown_outcome · 크레딧 · stopped/action_closed를 읽어 판단하거나 바꾸지 않는다. 코드(src/lib/review)는 실행 코드를 가져오지 않고,
// 마이그레이션은 실행 표를 읽기만 한다(execution_runs · execution_events: 상태 · 시각). eslint.config.mjs가 같은 import를 막는다.
// 실행 쪽이 이 모듈을 가져오는 것도 막는다 (제안 · 읽음이 gate · 판정의 입력이 되지 않게).

const ROOT = path.resolve(__dirname, "../../..");

function files(dir: string, includeTests = false): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return files(full, includeTests);
    return /\.ts$/.test(name) && (includeTests || !/\.test\.ts$/.test(name)) ? [full] : [];
  });
}

const code = (file: string) =>
  readFileSync(file, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/(^|[^:])\/\/.*$/gm, "$1");

const REVIEW_FILES = files(path.join(ROOT, "src/lib/review"));
const MIGRATION = path.join(ROOT, "supabase/migrations/20261111000000_review_summary.sql");
// 후속(A–D 승인, C): 첫 정상 표시 기준점. 같은 경계를 지킨다 (return_summary_scan을 create or replace하지만 후보 계산은 11의 함수에 있다)
const BASELINE_MIGRATION = path.join(ROOT, "supabase/migrations/20261112000000_review_summary_baseline.sql");

const sqlOf = (file: string) =>
  readFileSync(file, "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");

describe("Review · 복귀 요약 · 제안 ↔ 실행 권한 경계 (I04 · I14 · D13)", () => {
  it("src/lib/review는 실행 코드(정책 · 승인 · 도구 · 스위치 · 저장소)를 가져오지 않는다", () => {
    expect(REVIEW_FILES.map((f) => path.basename(f)).sort()).toEqual(
      ["cursor.ts", "day.ts", "dto.ts", "init-token.ts", "return-summary.ts", "review.config.ts", "review.ts", "suggestions.ts", "time-zone.ts"].sort(),
    );
    const offenders = REVIEW_FILES.flatMap((file) => {
      const text = readFileSync(file, "utf8");
      return [/from ["']@\/lib\/execution/, /from ["'][^"']*\/execution(\/|["'])/, /import\(["'][^"']*execution/, /executionEnabled/]
        .filter((m) => m.test(text))
        .map((m) => `${path.relative(ROOT, file)}: ${m}`);
    });
    expect(offenders).toEqual([]);
  });

  it("src/lib/review는 실행 정책 · 도구 · 스위치 · 승인 · 크레딧 표와 실행 함수를 쓰거나 읽지 않는다 (코드에 이름이 없다)", () => {
    const tables = /\b(execution_[a-z_]+|credit_(accounts|ledger|rates)|begin_call|create_run|grant_credits|prepare_step|approval_hash|stop_run)\b/;
    expect(REVIEW_FILES.filter((file) => tables.test(code(file))).map((file) => path.relative(ROOT, file))).toEqual([]);
  });

  it("마이그레이션은 실행 표를 읽기만 한다: execution_runs · execution_events 외의 실행 · 크레딧 표를 가리키지 않고, 어떤 실행 표에도 쓰지 않는다", () => {
    const sql = sqlOf(MIGRATION);
    const mentioned = [...new Set(sql.match(/\bexecution_[a-z_]+/g) ?? [])].sort();
    expect(mentioned).toEqual(["execution_events", "execution_runs"]);
    expect(sql).not.toMatch(/\b(insert\s+into|update|delete\s+from)\s+(public\.)?(execution_|credit_|actions\b|claims\b|evidence\b|action_events\b|inbox_events\b|sources\b|conversations\b|conversation_messages\b)/i);
    expect(sql).not.toMatch(/\b(begin_call|approval_hash|auto_allowed|create_run|append_step|prepare_step|stop_run|write_action|grant_credits)\b/);
    // 쓰는 곳은 새 표 셋뿐이다
    const written = [...sql.matchAll(/\b(?:insert\s+into|update|delete\s+from)\s+(?:only\s+)?(?:public\.)?([a-z_]+)/gi)].map((m) => m[1].toLowerCase()).filter((name) => name !== "set" && name !== "on"); // "do update set" · "before update on"은 표 쓰기가 아니다
    expect([...new Set(written)].sort()).toEqual(["return_summary_reads", "return_summary_state", "suggestions"]);
  });

  it("기준점 마이그레이션도 같은 경계다: 실행 표를 직접 가리키지 않고(후보는 11의 함수가 읽는다) 쓰는 곳은 읽음 표 · 기준점 표뿐이다", () => {
    const sql = sqlOf(BASELINE_MIGRATION);
    expect([...new Set(sql.match(/\bexecution_[a-z_]+/g) ?? [])].sort()).toEqual([]);
    expect(sql).not.toMatch(/\b(insert\s+into|update|delete\s+from)\s+(public\.)?(execution_|credit_|actions\b|claims\b|evidence\b|action_events\b|inbox_events\b|sources\b|conversations\b|conversation_messages\b|suggestions\b|return_summary_state\b)/i);
    expect(sql).not.toMatch(/\b(begin_call|approval_hash|auto_allowed|create_run|append_step|prepare_step|stop_run|write_action|grant_credits)\b/);
    const written = [...sql.matchAll(/\b(?:insert\s+into|update|delete\s+from)\s+(?:only\s+)?(?:public\.)?([a-z_]+)/gi)].map((m) => m[1].toLowerCase()).filter((name) => name !== "set" && name !== "on");
    expect([...new Set(written)].sort()).toEqual(["return_summary_baseline", "return_summary_reads"]);
  });

  it("실행 · 코디네이터 · 원문 처리 쪽 코드는 Review 모듈(제안 · 읽음)을 가져오지 않는다 (제안 · 읽음은 어떤 gate · 판정에도 입력이 아니다)", () => {
    const others = ["src/lib/execution", "src/lib/coordinator", "src/lib/sources", "src/lib/pipeline", "src/lib/actions"].flatMap((dir) => files(path.join(ROOT, dir)));
    expect(others.length).toBeGreaterThan(20);
    const offenders = others.filter((file) => /@\/lib\/review|\.\.\/review\//.test(readFileSync(file, "utf8"))).map((file) => path.relative(ROOT, file));
    expect(offenders).toEqual([]);
  });
});
