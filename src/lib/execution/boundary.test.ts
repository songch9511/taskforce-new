import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

// 과금 경계 (A37 · A44). 실행(크레딧 · run)은 따로 켜는 유료 기능이고, 할 일 직접 추가 · 수정 · 완료와 원문 처리는 크레딧 · 실행 확인 없이 돈다.
// 경계를 코드로 고정한다: 아래 경로는 실행 모듈 · 크레딧 표 · 실행 RPC를 가리키지 않는다 (원문 처리 쪽은 eslint 규칙도 막는다, eslint.config.mjs).
// 동의 없이 임베딩을 만들지 않는 것은 src/lib/api/create-action.test.ts "외부 AI 처리 동의 전이면 임베딩 없이 만든다"가 본다.

const ROOT = path.resolve(__dirname, "../../..");

function files(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (statSync(full).isDirectory()) return files(full);
    return /\.ts$/.test(name) && !/\.test\.ts$/.test(name) ? [full] : [];
  });
}

const FREE_PATHS = [
  // 직접 추가 · 수정 · 삭제 · 확정 · 착수 · 작업 상태 · 넘기기
  ...files(path.join(ROOT, "src/app/api/v1/actions")),
  path.join(ROOT, "src/lib/api/create-action.ts"),
  path.join(ROOT, "src/lib/api/action-routes.ts"),
  ...files(path.join(ROOT, "src/lib/actions")),
  // 원문 처리 · 파이프라인 (A44)
  ...files(path.join(ROOT, "src/lib/sources")),
  ...files(path.join(ROOT, "src/lib/pipeline")),
];

const EXECUTION_MARKERS = [/@\/lib\/execution/, /from ["'][^"']*\/execution(\/|["'])/, /credit_(accounts|ledger|rates)/, /\b(begin_call|create_run|grant_credits|take_rate_limit\([^)]*run_create)/, /executionEnabled/];

describe("과금 경계 (A37 · A44)", () => {
  it("할 일 쓰기 · 원문 처리 경로는 실행 · 크레딧을 확인하지도 부르지도 않는다", () => {
    expect(FREE_PATHS.length).toBeGreaterThan(10);
    const offenders = FREE_PATHS.flatMap((file) => {
      const text = readFileSync(file, "utf8");
      return EXECUTION_MARKERS.filter((marker) => marker.test(text)).map((marker) => `${path.relative(ROOT, file)}: ${marker}`);
    });
    expect(offenders).toEqual([]);
  });
});
