# 대화 상담 골든셋 (B2)

대화 v2의 답(`src/lib/conversation/respond.ts` `respondToMessage`)을 실제 모델로 채점하는 케이스입니다. 형식은 `src/lib/eval/consult-golden.ts`의 `consultCaseSchema`, 라벨 검사는 `findConsultLabelErrors`, 채점은 `scoreConsultCase`입니다. 모두 합성(`synthetic`)입니다.

- 한 케이스 = 앞 대화(`history`) + 지금 메시지(`message`) + 등록된 할 일(`records`) · 기억(`memory`) · 원문(`sources`) + 기대(`expect`). DB 대신 케이스가 기록 읽기 결과입니다.
- `maps_to`: 대응하는 기준. `A##`는 0.2.0 개발 계획 5장 수용 기준, `ARCH##`는 아키텍처 13장 검증 기준입니다 (검증 계획의 A번호가 아닙니다).
- `expect`는 문장을 통째로 맞추지 않고 금지 표현(`reply_must_not_match`, 정규식) · 필수 정보(`reply_contains_any`) · 쓰기(기억 수 · 정정 대상 · 채택 · 제안) · 인용 원문 · 근거 등급 · 되묻기로 봅니다.

```bash
npm run eval -- --labels    # 형식 · 라벨만 (CI, 키 없음)
npm run eval -- --consult   # 실제 Jev(J1) + LLM(J2 · J7) 채점. OPENROUTER_API_KEY · LLM_MODEL · JEV_MODEL 필요, 결과는 evals/results/*-consult-*.json
npm run eval -- --consult --case a01-no-open-one-done
```

## 이슈 정리 케이스 (D4c-2, `org-*.json` · `neg-*.json`)

`organize` 의도(이슈를 프로젝트에 넣기 · 빼기 · 옮기기 · 삭제 · 병합)를 가리는 케이스입니다. 기준은 Assistant 계약 v3의 `AC-27`(이동) · `AC-29`(삭제 · 병합 확인) · `AC-30`(병합)입니다.

- 이슈 번호(`number`) · 상태 · 확인된 멤버십(`projects`) · 프로젝트(`projects` 최상위, `status` active · archived) · 앱이 붙인 프로젝트 칩(`selected_contexts`)이 `organize_lookup`의 결과를 대신합니다. 이슈는 칩(`selected`)이나 글의 `#번호`로만 가리킵니다 — 제목이 닮았다고 고르지 않는 규칙을 케이스가 확인합니다.
- `history[].proposal.kind`(`move` · `delete` · `merge`)로 앞 답의 확인 카드를, `history[].organize_pending`으로 앞 답이 한 번 물은 것을 만듭니다.
- `expect.organize = { op, targets, into?, project?, outcome }`: outcome은 `write`(바로 씀) · `move_ask`(글 질문) · `card`(삭제 · 병합 카드) · `ask`(한 번 더 물음) · `reply`(쓰기 없는 사실 답). `op: "none"`은 정리가 아니어야 하는 케이스(`neg-*`)입니다.
- 채점에 `organize_outcome · organize_op · organize_targets · organize_into · organize_project`와 `no_false_write`가 더해집니다. `no_false_write`는 쓰기를 기대하지 않았는데 이동을 쓰거나 채택을 기대하지 않았는데 채택하면 실패합니다 — **거짓 쓰기는 0이어야 합니다** (기존 상담 케이스에도 적용).
- `npm run eval -- --consult`는 끝에 요약 한 줄을 찍습니다: `organize: intent 정밀도 · 재현율 · op · 대상 · 남는 쪽 정확도 · 거짓 쓰기 · 기존 상담 회귀`. 기존 상담 회귀는 기준선(기준 SHA에서 돌린 `--consult` 결과 파일)을 `--baseline <파일>`로 주면 셉니다.
- 기대 수치(계약 5.3): 거짓 쓰기 0 · 기존 상담 회귀 0 · organize 재현율 ≥ 0.9 · 정밀도 ≥ 0.95 · op · 대상 정확도 ≥ 0.9 · 병합 남는 쪽은 전부.
- 독립 검토(Astra) 반영 케이스 셋: `org-move-pending-correction`(프로젝트를 묻는 질문 뒤 "아니 Launch에서 빼줘" — 정정이라 op를 다시 판정해 앞 이동 계획을 쓰지 않는다) · `org-merge-target-answer`("#144 합쳐줘" → 이슈를 묻는 질문 → "#139에" = 앞 이슈와 합쳐 병합 카드) · `org-move-from-mismatch`(출발을 묻는 질문에 이슈의 소속이 아닌 프로젝트를 답함 — 쓰지 않고 실제 소속을 후보로 다시 묻는다). 개수는 org 22 · neg 5.
- 실제 모델 없이도 `src/lib/eval/consult-golden.test.ts`가 기대한 판정(Jev)을 가짜로 주고 코드 규칙만으로 케이스가 모두 통과하는지 확인합니다 (케이스 데이터와 코드가 어긋나지 않게).

실제 모델 채점은 비용이 들고 외부 공급자를 부르므로 승인 뒤에만 돌립니다. 프롬프트(`src/lib/ai/prompts/{intent,organize,consult,memory-extract}.ts`)를 바꾸면 버전을 올리고 이 채점 결과를 PR에 적습니다.
