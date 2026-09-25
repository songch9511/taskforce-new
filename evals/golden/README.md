# 골든셋

실제 원문(동의를 받고 익명화)과 사람이 정한 정답을 JSON으로 둡니다. `npm run eval`이 이 폴더를 읽습니다.
형식은 `src/lib/eval/golden.ts`의 `goldenCaseSchema`를 따르고, 예시는 `friday-to-monday.json`입니다.

- `origin`: `real`(실제 원문, 익명화) 또는 `synthetic`(개발용으로 지어낸 원문). eval은 둘을 나눠 보고합니다.
  지금 있는 케이스는 모두 `synthetic`입니다. 합성 원문은 실제보다 깔끔해서 점수가 높게 나오므로, 실제 원문이 들어오면 그 숫자를 기준으로 삼습니다.
- `sources`: 시간 순서대로 들어오는 원문. `occurred_at`은 발언 시점입니다.
- `expected_actions`: 모든 원문을 처리한 뒤 남아야 하는 Action. `evidence`의 `quote`는 원문 그대로 적습니다.
- `must_not_extract`: 뽑으면 오탐인 문장과 이유 (`NOT_MY_ACTION`, `INFO_ONLY`, `TENTATIVE`, `ALREADY_DONE`).

인용이 원문에 없거나 없는 source를 가리키면 `npm run eval`과 `npm run test`가 실패합니다.
실제 사용자 데이터를 커밋할 때는 이름·회사·금액 등을 반드시 바꿔 주세요.

## 채점

```bash
npm run eval                  # 라벨 검사 + 추출 채점 (.env.local의 OPENROUTER_API_KEY, LLM_MODEL 사용)
npm run eval -- --case <id>   # 한 케이스만
npm run eval -- --labels      # 라벨 검사만 (키가 없으면 CI도 여기까지만)
```

- 후보와 정답은 **인용 구절이 겹치는지**로 짝짓습니다 (공백·문장부호 무시). 제목은 비교하지 않습니다.
- precision = 맞음 / 뽑은 것 전체, recall = 맞음 / 정답 전체. 담당·기한 정확도는 맞게 짝지어진 것 중에서 셉니다.
- 오탐은 사유별로 셉니다: 함정 문장의 사유, 같은 정답을 두 번 뽑은 `DUPLICATE`, 라벨에 없는 문장 `UNLABELED`.
  `UNLABELED`가 많으면 라벨이 빠졌는지 먼저 확인합니다.
- Phase 1은 원문이 하나인 케이스만 채점합니다. 여러 원문이 이어지는 케이스(예: `friday-to-monday`)는 Phase 2 매칭에서 채점합니다.
- 결과는 `evals/results/`에 JSON으로 남습니다 (커밋하지 않음). 프롬프트를 바꾸면 `src/lib/ai/prompts/extract.ts`의 버전을 올리고 전후 숫자를 PR에 적습니다.

### 기록

| 날짜 | 모델 · 프롬프트 | 케이스 | precision | recall | 담당 | 기한 | 비고 |
|---|---|---|---|---|---|---|---|
| 2026-09-25 | claude-sonnet-5 · extract-v1 | 합성 20 | 94.9% | 94.9% | 100% | 100% | 누락 2는 `unknown` 담당(팀원이 "저희 쪽에서" 약속), 오탐은 TENTATIVE 1 · DUPLICATE 1 |
