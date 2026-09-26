@AGENTS.md

# Taskforce — AI 프로젝트 매니저

AI 코딩 에이전트가 이 저장소에서 작업할 때 반드시 지켜야 할 규칙입니다.
제품 배경은 `docs/PRD.md`, 구조는 `docs/ARCHITECTURE.md`, 플랫폼 전략은 `docs/PLATFORMS.md`, 단계별 개발 계획은 `docs/VIBE_CODING_PLAN.md`를 보세요.

## 제품 원칙 (코드보다 우선)

1. **사용자는 할 일을 직접 적지 않는다.** Action은 원문(회의록·메시지·메일·문서)에서만 생성된다.
   "할 일 추가" 폼을 메인 흐름에 만들지 않는다. (수동 수정·삭제는 가능하지만, 그건 *오판 신호*로 기록된다.)
2. **모든 Action과 모든 변경에는 근거(Evidence)가 붙는다.** 원문 인용 구절 + 출처 링크 없이 생성·갱신되는 Action은 버그다.
3. **불확실하면 묻는다, 확실하면 조용히 반영한다.** 담당자나 기한의 신뢰도가 낮은 항목만 확인 큐로 보낸다.
   확인 요청이 많아지면 그 자체가 관리 비용이다 — 확인 요청 수를 늘리는 변경은 신중히.
4. **중복을 만들지 않는다.** 새 후보는 항상 기존 열린 Action과 먼저 매칭(신규 / 갱신 / 중복 / 완료)한 뒤 반영한다.
5. **LLM은 Claim(누가 언제 무엇을 말했나)만 뽑고, 무엇이 사실인지는 코드가 정한다.**
   Action 필드 값은 `docs/TRUTH_RULES.md`의 규칙을 구현한 순수 함수로만 계산한다. Claim은 지우지 않는다.
6. **측정할 수 없으면 출시하지 않는다.** 사용자의 수정·삭제, 착수 시간, 재방문은 모두 이벤트로 남긴다 (`docs/PRD.md` 성공 지표).

## 플랫폼

- 사용자용 앱은 **iOS · macOS 네이티브**(SwiftUI, `apple/`)다. Next.js는 서버 API와 내부 도구(시험대 · eval · 지표)만 담당한다. 웹에 사용자용 화면을 만들지 않는다.
- 추출 · 판정 · 진실 판정 · 랭킹은 서버에만 둔다. Swift 앱에 같은 로직을 다시 구현하지 않는다.
- 앱이 부를 서버 로직은 Server Action이 아니라 `src/app/api/v1/` Route Handler로 만든다. 인증은 `Authorization: Bearer` 토큰과 웹 쿠키 둘 다 받는다.
- API 요청·응답 스키마는 `src/lib/api/contract.ts`에 zod로 둔다. 호환이 깨지는 변경은 새 버전 경로(`/api/v2`)로 낸다.
- 앱은 읽기를 Supabase에서 직접(RLS), 쓰기를 서버 API로만 한다. 모든 쓰기는 이벤트를 남긴다.

## 기술 스택

- Next.js 16 (App Router) + TypeScript (strict) + Tailwind v4 + shadcn/ui
  - Next.js 16에서는 middleware가 `src/proxy.ts`로 바뀌었고 `cookies()`, `params`, `searchParams`가 비동기다. 모르는 API는 `node_modules/next/dist/docs/`를 먼저 읽는다.
- Supabase: Postgres, Auth(이메일 매직 링크), pgvector (Action 매칭용 임베딩)
  - 스키마 변경은 `supabase/migrations/`에 새 파일로 추가한다. 기존 마이그레이션 파일은 고치지 않는다.
  - 새 테이블은 `user_id` + RLS(`owner_all` 정책) + 부모와의 `(id, user_id)` 복합 외래키 패턴을 따르고, `tests/db/`에 RLS 테스트를 추가한다.
  - 서버에서 사용자를 확인할 때는 `requireUser()`(`src/lib/auth.ts`)를 쓴다. proxy의 확인만 믿지 않는다.
- AI 호출은 모두 OpenRouter 키 하나로 한다 (`OPENROUTER_API_KEY`, `.env.local`에만 두고 절대 커밋하지 않는다).
  - 생성형 LLM (Claim 추출): OpenRouter chat completions. 구조화 출력(JSON 스키마)으로만 받는다. 자유 텍스트를 파싱하지 않는다. 모델 id는 환경변수로.
  - Jev (검증·분류·매칭 판정): OpenRouter Decisions API `POST /api/alpha/decisions`, 모델 `typesafe/jev-1.13` 고정. 상세는 `docs/TRUTH_RULES.md` 1장.
  - 글 생성이 필요 없는 판정(예/아니오, 선택지 고르기, 척도)은 LLM이 아니라 Jev로 한다.
- Apple 앱: SwiftUI 멀티플랫폼 + Swift Concurrency, 공유 로직은 `apple/Packages/TaskforceKit`, Supabase는 `supabase-swift`
  - 로그인은 Sign in with Apple(보조: 이메일 6자리 코드). 세션은 App Group 공유 Keychain에 저장한다 (공유 확장 · 위젯과 공유).
  - Supabase URL · 키는 xcconfig로 빼고 커밋하지 않는다.
- 스키마 검증: zod
- 테스트: Vitest (단위), 추출 품질은 `evals/`의 골든셋으로 평가

## 코드 규칙

- AI 호출은 `src/lib/ai/` 안에서만 한다 (`llm.ts`, `jev.ts`). 외부 응답은 모두 zod로 검증한다. 프롬프트는 `src/lib/ai/prompts/`에 버전 관리되는 파일로 둔다.
- 추출 파이프라인(`src/lib/pipeline/`)은 UI·DB와 분리된 순수 함수로 작성해 eval 스크립트에서 그대로 돌릴 수 있게 한다.
- 프롬프트나 파이프라인을 바꿨으면 `npm run eval`을 돌리고 결과(precision / recall / 담당·기한 정확도)를 PR에 적는다.
- 사용자 데이터(회의록 원문 등)를 로그에 평문으로 남기지 않는다.

## 명령어

```bash
npm run dev        # 로컬 개발 서버
npm run lint
npm run typecheck  # 라우트 타입 생성 후 tsc
npm run test       # 단위 테스트 + DB 마이그레이션·RLS 테스트 (PGlite)
npm run eval       # 골든셋으로 추출 품질 평가
npm run build
```

커밋 전에 lint, typecheck, test, eval을 모두 통과시킨다 (CI와 같은 순서).
