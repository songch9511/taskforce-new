# Taskforce — AI 프로젝트 매니저

AI 코딩 에이전트가 이 저장소에서 작업할 때 반드시 지켜야 할 규칙입니다.
제품 배경은 `docs/PRD.md`, 단계별 개발 계획은 `docs/VIBE_CODING_PLAN.md`를 보세요.

## 제품 원칙 (코드보다 우선)

1. **사용자는 할 일을 직접 적지 않는다.** Action은 원문(회의록·메시지·메일·문서)에서만 생성된다.
   "할 일 추가" 폼을 메인 흐름에 만들지 않는다. (수동 수정·삭제는 가능하지만, 그건 *오판 신호*로 기록된다.)
2. **모든 Action과 모든 변경에는 근거(Evidence)가 붙는다.** 원문 인용 구절 + 출처 링크 없이 생성·갱신되는 Action은 버그다.
3. **불확실하면 묻는다, 확실하면 조용히 반영한다.** 담당자나 기한의 신뢰도가 낮은 항목만 확인 큐로 보낸다.
   확인 요청이 많아지면 그 자체가 관리 비용이다 — 확인 요청 수를 늘리는 변경은 신중히.
4. **중복을 만들지 않는다.** 새 후보는 항상 기존 열린 Action과 먼저 매칭(신규 / 갱신 / 중복 / 완료)한 뒤 반영한다.
5. **측정할 수 없으면 출시하지 않는다.** 사용자의 수정·삭제, 착수 시간, 재방문은 모두 이벤트로 남긴다 (`docs/PRD.md` 성공 지표).

## 기술 스택

- Next.js (App Router) + TypeScript (strict) + Tailwind + shadcn/ui
- Supabase: Postgres, Auth, pgvector (Action 매칭용 임베딩)
- LLM: Anthropic Claude API — 추출·매칭은 tool use / 구조화 출력(JSON 스키마)으로만 받는다. 자유 텍스트를 파싱하지 않는다.
- 스키마 검증: zod
- 테스트: Vitest (단위), 추출 품질은 `evals/`의 골든셋으로 평가

## 코드 규칙

- LLM 호출은 `src/lib/ai/` 안에서만 한다. 프롬프트는 `src/lib/ai/prompts/`에 버전 관리되는 파일로 둔다.
- 추출 파이프라인(`src/lib/pipeline/`)은 UI·DB와 분리된 순수 함수로 작성해 eval 스크립트에서 그대로 돌릴 수 있게 한다.
- 프롬프트나 파이프라인을 바꿨으면 `npm run eval`을 돌리고 결과(precision / recall / 담당·기한 정확도)를 PR에 적는다.
- 사용자 데이터(회의록 원문 등)를 로그에 평문으로 남기지 않는다.

## 명령어

```bash
npm run dev      # 로컬 개발 서버
npm run test     # 단위 테스트
npm run eval     # 골든셋으로 추출 품질 평가
npm run lint
```
