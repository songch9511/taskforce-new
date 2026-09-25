# 골든셋

실제 원문(동의를 받고 익명화)과 사람이 정한 정답을 JSON으로 둡니다. `npm run eval`이 이 폴더를 읽습니다.
형식은 `src/lib/eval/golden.ts`의 `goldenCaseSchema`를 따르고, 예시는 `friday-to-monday.json`입니다.

- `sources`: 시간 순서대로 들어오는 원문. `occurred_at`은 발언 시점입니다.
- `expected_actions`: 모든 원문을 처리한 뒤 남아야 하는 Action. `evidence`의 `quote`는 원문 그대로 적습니다.
- `must_not_extract`: 뽑으면 오탐인 문장과 이유 (`NOT_MY_ACTION`, `INFO_ONLY`, `TENTATIVE`, `ALREADY_DONE`).

인용이 원문에 없거나 없는 source를 가리키면 `npm run eval`과 `npm run test`가 실패합니다.
실제 사용자 데이터를 커밋할 때는 이름·회사·금액 등을 반드시 바꿔 주세요.
