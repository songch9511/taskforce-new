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
  // 위 경로가 읽는 공유 계약: 여기서 실행 모듈을 가져오면 무료 경로가 건너서 의존한다
  path.join(ROOT, "src/lib/api/contract.ts"),
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

// 맥락 경계 (ARCH06 · ARCH07, 불변식 I04 · I14): execution_runs의 conversation_id · context_id · bundle_context_version · directive_version(0.2.0 C1)은 "어느 대화 · 범위에서
// 시작했나"의 기록이다. 실행 코드(run 만들기 · 실행기 · sweep · 판단 함수를 부르는 곳)와 Action 판정(resolve)은 범위 · 대화 · 기억 · 그 버전을 읽지도 쓰지도 않는다.
// 이 열을 읽거나 쓰는 코드는 이 묶음에 없다(코디네이터 C2 · 게이트웨이 D1). DB 쪽(begin_call · 승인 hash · 정책 · Action이 범위를 바꿔도 그대로)은 tests/db/execution-additive-contract.scenarios.ts.
describe("맥락 경계 (ARCH06 · ARCH07)", () => {
  const CONTEXT_IDENTIFIERS = /\b(context_id|bundle_context_version|conversation_id|context_version|directive_version|work_contexts|context_members|memory_items|conversations)\b/;
  const EXECUTION_PATHS = [
    ...files(path.join(ROOT, "src/lib/execution")),
    ...files(path.join(ROOT, "src/app/api/v1/runs")),
    ...files(path.join(ROOT, "src/app/api/cron")).filter((file) => /execution-/.test(file)),
    path.join(ROOT, "src/lib/api/runs.ts"),
    // Action 판정: 값은 Claim에서만 나온다 (원칙 5, I01)
    path.join(ROOT, "src/lib/pipeline/resolve.ts"),
    path.join(ROOT, "src/lib/actions/project.ts"),
  ];

  it("실행 코드 · run API · Action 판정은 범위 · 대화 · 기억 · 그 버전을 가리키지 않는다", () => {
    expect(EXECUTION_PATHS.length).toBeGreaterThan(20);
    const offenders = EXECUTION_PATHS.filter((file) => CONTEXT_IDENTIFIERS.test(readFileSync(file, "utf8"))).map((file) => path.relative(ROOT, file));
    expect(offenders).toEqual([]);
  });
});
