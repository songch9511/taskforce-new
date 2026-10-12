import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Override default ignores of eslint-config-next.
  globalIgnores([
    // Default ignores of eslint-config-next:
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    // Apple 앱 빌드 산출물 (Swift 패키지 체크아웃에 TS 예제가 들어 있음)
    "apple/**",
    // 도구 폴더: .claude/worktrees에 다른 세션의 작업 트리 사본(빌드 산출물 포함)이 들어 있다
    ".claude/**",
    ".omc/**",
  ]),
  {
    // 과금 경계 (A44): 무료 발견(원문 처리 · 추출 파이프라인)은 유료 실행 코드(src/lib/execution, U2 PR6에서 생김)를 부르지 못한다
    files: ["src/lib/pipeline/**", "src/lib/sources/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              group: ["@/lib/execution", "@/lib/execution/**", "**/execution", "**/execution/**"],
              message: "원문 처리 · 파이프라인(무료 발견)은 실행(src/lib/execution)을 부르지 않는다 (A44 과금 경계).",
            },
          ],
        },
      ],
      // 동적 import도 같다 (no-restricted-imports는 import()를 보지 않는다). 경로 조각이 정확히 execution인 문자열만 본다
      // (esquery 정규식에는 /를 못 써서 \x2F로 적는다). 템플릿 문자열로 만든 import()는 잡지 못한다
      "no-restricted-syntax": [
        "error",
        {
          selector: "ImportExpression[source.value=/(^|\\x2F)execution(\\x2F|$)/]",
          message: "원문 처리 · 파이프라인(무료 발견)은 실행(src/lib/execution)을 부르지 않는다 (A44 과금 경계).",
        },
      ],
    },
  },
  {
    // 권한 경계 (불변식 I01 · I04 · I14, 0.2.0 C2): 코디네이터는 실행 정책 · 승인 · 도구 · 저장소를 가져오지 않는다. 깨우기 주소(@/lib/execution/wake의 wakeOrigin)만 예외다
    // (src/lib/coordinator/boundary.test.ts). 반대 방향(실행 · 맥락층 · 원문 처리가 코디네이터를 가져오는 것)도 같은 테스트가 본다.
    files: ["src/lib/coordinator/**"],
    ignores: ["src/lib/coordinator/**/*.test.ts"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              // @/lib/execution과 그 아래 전부, 단 정확히 @/lib/execution/wake만 예외 (gitignore식 !는 부모 폴더가 막히면 다시 허용하지 못해 정규식으로 쓴다). 상대 경로의 execution도 막는다
              regex: "^(@/lib/execution(/(?!wake$).*)?|(\\.{1,2}/)+(.*/)?execution(/.*)?)$",
              message: "코디네이터(src/lib/coordinator)는 실행(src/lib/execution)을 가져오지 않는다. 깨우기 주소(wake)만 예외다 (I04 · I14 권한 경계).",
            },
          ],
        },
      ],
    },
  },
  {
    // 권한 경계 (불변식 I04 · I14, 0.2.0 C3): Review · 복귀 요약 · 제안(src/lib/review)은 실행 정책 · 승인 · 도구 · 저장소를 가져오지 않는다. 결정 대기 계산(코디네이터)은 읽기만 가져온다
    // (src/lib/review/boundary.test.ts)
    files: ["src/lib/review/**"],
    ignores: ["src/lib/review/**/*.test.ts"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              group: ["@/lib/execution", "@/lib/execution/**", "**/execution", "**/execution/**"],
              message: "Review · 복귀 요약 · 제안(src/lib/review)은 실행(src/lib/execution)을 가져오지 않는다 (I04 · I14 권한 경계).",
            },
          ],
        },
      ],
      "no-restricted-syntax": [
        "error",
        {
          selector: "ImportExpression[source.value=/(^|\\x2F)execution(\\x2F|$)/]",
          message: "Review · 복귀 요약 · 제안(src/lib/review)은 실행(src/lib/execution)을 가져오지 않는다 (I04 · I14 권한 경계).",
        },
      ],
    },
  },
  {
    // 권한 경계 (불변식 I04 · I14): 맥락층(기억 · 범위 · 사람 · 묶음)과 대화 v2(의도 · 제안 · 기억 쓰기)는 실행 정책 · 도구 · 승인을 읽거나 바꾸지 못한다
    // (src/lib/context/boundary.test.ts · src/lib/conversation/boundary.test.ts)
    files: ["src/lib/context/**", "src/lib/conversation/**"],
    rules: {
      "no-restricted-imports": [
        "error",
        {
          patterns: [
            {
              group: ["@/lib/execution", "@/lib/execution/**", "**/execution", "**/execution/**"],
              message: "맥락층(src/lib/context) · 대화(src/lib/conversation)는 실행(src/lib/execution)을 가져오지 않는다 (I04 · I14 권한 경계).",
            },
          ],
        },
      ],
      "no-restricted-syntax": [
        "error",
        {
          selector: "ImportExpression[source.value=/(^|\\x2F)execution(\\x2F|$)/]",
          message: "맥락층(src/lib/context) · 대화(src/lib/conversation)는 실행(src/lib/execution)을 가져오지 않는다 (I04 · I14 권한 경계).",
        },
      ],
    },
  },
]);

export default eslintConfig;
