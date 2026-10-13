import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

// 권한 경계 (불변식 I04 · I14, 아키텍처 5.3 · 7.2, D-13): 기억 · 범위 · 사람 · 묶음은 실행 권한(정책 · 도구 · 스위치 · 승인)을 읽거나 바꾸지 않는다.
// 맥락층 코드(src/lib/context)는 실행 코드를 가져오지 않고, 실행 표를 쓰는 문자열도 없다. 실행 쪽 정책 · 승인 코드도 맥락층을 가져오지 않는다
// (범위 · 기억이 gate · 판정의 입력이 되지 않게). eslint.config.mjs가 같은 import를 막는다.
// DB 쪽(맥락층 표 · 함수가 execution_* 표를 가리키거나 쓰지 않음)은 tests/db/context-layer.scenarios.ts "권한 · 경계".

const ROOT = path.resolve(__dirname, "../../..");

function files(dir: string, includeTests = false): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return files(full, includeTests);
    return /\.tsx?$/.test(name) && (includeTests || !/\.test\.tsx?$/.test(name)) ? [full] : [];
  });
}

function createsContext(file: string, source: string): boolean {
  // React의 createContext만 제외한다(react에서 createContext를 이름으로 가져온 파일). react에서 다른 것만 가져오는 파일은 제외하지 않는다
  const importsReactCreateContext = /import\s*\{[^}]*\bcreateContext\b[^}]*\}\s*from\s*["']react["']/.test(source);
  return /\.tsx?$/.test(file) && !/\.test\.tsx?$/.test(file) &&
    /\bcreateContext\b/.test(source) && !importsReactCreateContext;
}

const CONTEXT_FILES = files(path.join(ROOT, "src/lib/context"));
const CONTEXT_MIGRATIONS = [
  path.join(ROOT, "supabase/migrations/20261104000000_context_layer.sql"),
  // B3: 기억 잊기 · 범위 옮기기도 실행 표를 건드리지 않는다
  path.join(ROOT, "supabase/migrations/20261107000000_memory_writes.sql"),
  // S3b: 사용자 멤버십 쓰기(넣기 · 빼기 · 옮기기)도 실행 표를 건드리지 않는다
  path.join(ROOT, "supabase/migrations/20261108000000_context_member_user_writes.sql"),
  // D4c-1s: 프로젝트 쓰기도 서버 RPC 경계만 통과한다
  path.join(ROOT, "supabase/migrations/20261117000000_context_icon_version.sql"),
];

describe("맥락층 ↔ 실행 권한 경계 (I04 · I14)", () => {
  it("프로젝트 생성 경계 판정은 import 형태와 TSX 확장자를 놓치지 않는다", () => {
    expect(createsContext("src/lib/context/other.ts", 'import { createContext } from "./store";')).toBe(true);
    expect(createsContext("src/app/api/other.ts", 'import { createContext } from "../context/store";')).toBe(true);
    expect(createsContext("src/app/api/other.ts", 'import * as store from "@/lib/context/store"; store.createContext();')).toBe(true);
    expect(createsContext("src/app/api/other.ts", 'export { createContext } from "@/lib/context/store";')).toBe(true);
    expect(createsContext("src/app/example.tsx", 'import * as store from "./store"; store.createContext();')).toBe(true);
    expect(createsContext("src/app/provider.tsx", 'import { createContext } from "react"; createContext(null);')).toBe(false);
    expect(createsContext("src/app/provider.tsx", 'import {\n  createContext,\n} from "react";\ncreateContext(null);')).toBe(false);
    expect(createsContext("src/app/page.tsx", 'import { useState } from "react";\nimport * as store from "@/lib/context/store";\nstore.createContext();')).toBe(true);
  });

  it("src/lib/context는 실행 코드(정책 · 승인 · 도구 · 스위치 · 저장소 포함)를 가져오지 않는다", () => {
    expect(CONTEXT_FILES.map((f) => path.basename(f)).sort()).toEqual(
      ["bundle.ts", "chunks.ts", "contexts.ts", "identity-links.ts", "member-writes.ts", "memory-edit.ts", "memory-writes.ts", "memory.ts", "people.ts", "retrieve.ts", "store.ts"].sort(),
    );
    const offenders = CONTEXT_FILES.flatMap((file) => {
      const text = readFileSync(file, "utf8");
      return [/from ["']@\/lib\/execution/, /from ["'][^"']*\/execution(\/|["'])/, /import\(["'][^"']*execution/, /executionEnabled/].filter((m) => m.test(text)).map(
        (m) => `${path.relative(ROOT, file)}: ${m}`,
      );
    });
    expect(offenders).toEqual([]);
  });

  it("프로젝트 생성은 POST route의 store 호출로만 허용되고 테이블 직접 쓰기는 없다", () => {
    const sourceFiles = files(path.join(ROOT, "src"));
    const importsCreateContext = sourceFiles.filter((file) => createsContext(file, readFileSync(file, "utf8")));
    expect(importsCreateContext.map((file) => path.relative(ROOT, file)).sort()).toEqual([
      "src/app/api/v2/contexts/route.ts",
      "src/lib/context/store.ts",
    ].sort());

    const callsCreateRpc = sourceFiles.filter((file) => /\.rpc\(\s*["']create_work_context["']/.test(readFileSync(file, "utf8")));
    expect(callsCreateRpc.map((file) => path.relative(ROOT, file))).toEqual(["src/lib/context/store.ts"]);

    const directWrites = sourceFiles.filter((file) => {
      const text = readFileSync(file, "utf8");
      return /\.from\(\s*["']work_contexts["']\)(?:(?!;)[\s\S]){0,500}\.(?:insert|upsert)\s*\(/.test(text);
    });
    expect(directWrites.map((file) => path.relative(ROOT, file))).toEqual([]);
  });

  it("src/lib/context는 실행 정책 · 도구 · 스위치 · 승인 · 크레딧 표를 쓰거나 읽지 않는다", () => {
    const tables = /\b(execution_[a-z_]+|credit_(accounts|ledger|rates)|begin_call|create_run|grant_credits|prepare_step)\b/;
    // 주석의 설명(예: manifest를 실행 단계에 남긴다)은 코드가 아니다
    const code = (file: string) =>
      readFileSync(file, "utf8")
        .replace(/\/\*[\s\S]*?\*\//g, "")
        .replace(/(^|[^:])\/\/.*$/gm, "$1");
    const offenders = CONTEXT_FILES.filter((file) => tables.test(code(file))).map((file) => path.relative(ROOT, file));
    expect(offenders).toEqual([]);
  });

  it("맥락층 마이그레이션은 실행 표를 만들거나 고치거나 가리키지 않는다", () => {
    for (const migration of CONTEXT_MIGRATIONS) {
      const sql = readFileSync(migration, "utf8")
        .split("\n")
        .filter((line) => !line.trim().startsWith("--"))
        .join("\n");
      expect(sql, path.basename(migration)).not.toMatch(/execution_|credit_|approval/);
    }
  });

  it("실행 쪽 정책 · 승인 · 계획 코드는 맥락층(범위 · 기억)을 입력으로 가져오지 않는다 (범위는 어떤 gate · 판정에도 입력이 아니다)", () => {
    const executionFiles = files(path.join(ROOT, "src/lib/execution"));
    expect(executionFiles.length).toBeGreaterThan(5);
    const offenders = executionFiles.filter((file) => /@\/lib\/context|\.\.\/context\//.test(readFileSync(file, "utf8"))).map((file) => path.relative(ROOT, file));
    expect(offenders).toEqual([]);
  });
});
