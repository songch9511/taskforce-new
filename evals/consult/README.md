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

실제 모델 채점은 비용이 들고 외부 공급자를 부르므로 승인 뒤에만 돌립니다. 프롬프트(`src/lib/ai/prompts/{intent,consult,memory-extract}.ts`)를 바꾸면 버전을 올리고 이 채점 결과를 PR에 적습니다.
