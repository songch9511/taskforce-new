# Taskforce 바이브코딩 플랜

## 핵심 전략 한 줄

**UI가 아니라 "추출 엔진 + 평가(eval)"부터 만든다.**
Taskforce의 성패는 화면이 아니라 "AI가 Action을 정확히 골라내는가"에 달려 있고,
이것이 PRD의 피벗 기준(지표 1)이다. 바이브코딩은 화면은 빠르게 만들어 주지만
LLM 품질은 측정 장치 없이는 "느낌"으로만 판단하게 된다.

## 바이브코딩 운영 원칙

1. **한 세션 = 한 단계 = 한 PR.** 아래 단계를 한 번에 시키지 말 것. 각 단계 끝의 "완료 기준"을 직접 확인하고 머지.
2. **먼저 계획, 다음 구현.** 각 단계는 plan 모드(또는 "코드 쓰지 말고 계획부터")로 시작해 데이터 모델·파일 구조를 합의한 뒤 구현.
3. **CLAUDE.md가 헌법.** 에이전트가 원칙을 어기면(근거 없는 Action, 수동 입력 폼 등) 코드만 고치지 말고 CLAUDE.md에 규칙을 추가.
4. **실제 데이터로 검증.** 인터뷰한 창업자의 실제 회의록·메시지(동의 받고 익명화) 20~50건이 최고의 자산. 가짜 예시로는 정확도를 알 수 없다.
5. **연동은 맨 나중.** Gmail/Slack OAuth는 시간이 많이 들고 가설 검증과 무관. 베타 초기에는 공유 시트·붙여넣기로 충분.
6. **엔진은 서버, 화면은 네이티브.** 사용자용 화면은 iOS·macOS 앱에만 만든다 ([`PLATFORMS.md`](PLATFORMS.md)).
   앱이 부를 서버 로직은 Server Action이 아니라 `/api/v1` Route Handler로 만든다.

## 두 갈래로 진행

```
서버 트랙 (클라우드 세션 가능)   Phase 1 엔진 → Phase 2 매칭 → Phase 3 API·반영 → Phase 4 핸드오프 → Phase 5 지표
Apple 트랙 (Mac에서)                     Phase A0 앱 뼈대 → Phase A1 화면 → Phase A2 입력 → Phase A3 알림
```

Phase A0은 Phase 1과 동시에 시작해도 된다. Phase A1은 Phase 3의 API가 나온 뒤에 붙인다.
Apple 트랙은 Xcode 빌드가 필요하므로 **Mac의 Claude Code**에서 진행한다.

---

## Phase 0 — 뼈대 (반나절) ✅ 완료

> 프롬프트:
> "CLAUDE.md와 docs/PRD.md를 읽어. Next.js(App Router, TS strict) + Tailwind + shadcn/ui + Supabase로 프로젝트를 초기화하고,
> PRD 4장의 데이터 모델로 Supabase 마이그레이션을 작성해. Vitest와 `npm run eval` 스크립트 자리도 만들어. 아직 기능은 만들지 마."

완료 기준: `npm run dev`, `npm run test` 동작 / 마이그레이션 적용 / 로그인(Supabase Auth, 매직링크)

## Phase 1 — 골든셋 + 추출 엔진 (가장 중요, 2~4일) ✅ 완료

진행 상황: 1~4 모두 완료. 골든셋은 합성 20건 + 실제 회의록 2건(익명화). 원문 수신 API `POST /api/v1/sources`와 시험대 `/lab`이 있다. 결과 기록은 `evals/golden/README.md`.
남은 숙제: 실제 원문 골든셋 늘리기(목표 20건 이상), 받아쓰기가 사용자 이름을 틀리는 경우(별칭) 처리.

1. `evals/golden/`에 실제 원문 + 기대 Action을 JSON으로 라벨링 (직접 20건 이상).
   각 케이스: 원문, 기대 Action 목록(제목·담당·기한·근거 인용), 추출하면 안 되는 함정(참고 정보, 남의 할 일).
2. 추출기 구현

> 프롬프트:
> "`src/lib/pipeline/extract.ts`에 Source 텍스트를 받아 Action 후보 배열을 돌려주는 순수 함수를 만들어.
> OpenRouter chat completions의 구조화 출력(JSON 스키마, zod로 검증)으로 받고, 각 후보에는 원문 인용(quote)과 owner/due 신뢰도를 포함해.
> '사용자가 맡았거나 약속한 것'만 추출하고 참고 정보와 타인의 할 일은 제외해.
> 그리고 `npm run eval`이 evals/golden 전체를 돌려 precision, recall, 담당 정확도, 기한 정확도를 표로 출력하게 해."

3. 검증 단계 추가 (`docs/TRUTH_RULES.md` 1장)

> 프롬프트:
> "docs/TRUTH_RULES.md 1장을 읽어. 추출 뒤에 ① 인용 실재 확인·날짜 재계산 같은 기계적 검증과
> ② Jev 판정 단계(`src/lib/pipeline/judge.ts`)를 추가해. Jev 호출은 `src/lib/ai/jev.ts`에 fetch로 직접 구현하고
> (OpenRouter Decisions API, 채팅 SDK 사용 금지), 응답은 zod로 검증해. 임계값은 설정 파일로 빼.
> eval에 Jev 적용 전후 precision/recall 비교, 질문별 사람 라벨 일치율, 확률 구간별 실제 정답률(보정 표)을 추가해."

4. 원문 수신 API와 내부 시험대

> 프롬프트:
> "docs/PLATFORMS.md 3장을 읽어. `POST /api/v1/sources` Route Handler를 만들어. Bearer 토큰과 웹 쿠키 세션을 모두 받고,
> 요청·응답 스키마는 `src/lib/api/contract.ts`에 zod로 정의해. 원문을 저장하고 202와 source_id를 돌려준 뒤 파이프라인을 백그라운드로 돌려.
> 웹에는 내부용 `/lab` 페이지를 만들어 원문을 붙여넣으면 추출·Jev 판정 결과를 표로 보여줘."

완료 기준: eval 표가 출력되고, **프롬프트를 고칠 때마다 숫자로 개선/퇴보를 확인**할 수 있음.
목표 예시: precision ≥ 0.9 (틀린 Action이 섞이는 게 누락보다 신뢰를 더 깎는다).

## Phase 2 — 매칭·병합 (2~3일)

"금요일 약속 → 월요일로 변경" 시나리오가 여기서 풀린다.

> 프롬프트:
> "docs/TRUTH_RULES.md 2장을 읽어. `src/lib/pipeline/match.ts`를 만들어. 새 후보마다 pgvector로 열린 Action top-5를 찾고,
> LLM이 new / update / duplicate / complete 중 하나로 판정하게 해. update는 Action을 직접 고치지 말고 필드별 Claim으로 저장해.
> 그다음 `src/lib/pipeline/resolve.ts`에 규칙 0~6을 구현한 순수 함수 `resolve(claims)`를 만들고, 규칙마다 단위 테스트를 작성해.
> 골든셋에 '여러 원문이 순서대로 들어오는' 시퀀스 케이스를 추가하고 eval에 병합 정확도를 넣어."

완료 기준: PRD 2장 핵심 시나리오 1~2와 TRUTH_RULES.md의 9/22~9/24 표가 테스트로 통과.

## Phase 3 — 반영 정책 + 쓰기 API + 알림 발송 (2~3일)

> 프롬프트:
> "docs/PLATFORMS.md 2~3장을 읽어. 파이프라인 결과를 DB에 반영하는 `apply.ts`를 만들어. 신뢰도 임계값 이상은 자동 반영하고 ActionEvent를 남기고,
> 담당/기한이 불확실하면 needs_confirmation으로 확인 큐에 보내. '지금 할 일' 순서(기한 임박·외부 약속·방치 기간)를 계산하는 순수 함수도 만들어.
> PLATFORMS.md 3장 표의 Phase 3 엔드포인트(수정·삭제·확정·착수·metric-events·devices)를 만들고, 각 쓰기마다 이벤트를 남겨.
> 새 마이그레이션으로 actions·claims·evidence·action_events의 클라이언트 쓰기 권한을 막고(읽기 전용 RLS), 서버는 service role로 써.
> 확인 요청이 생기거나 기한이 임박하면 APNs로 알림을 보내는 모듈을 만들어."

완료 기준: API로 원문을 보내고 30초 안에 DB에 Action이 생기며, 수정·삭제·확정이 모두 이벤트로 남음. RLS 테스트로 클라이언트 직접 쓰기가 막힌 것을 확인.

## Phase 4 — AI 핸드오프 (1~2일)

> 프롬프트:
> "`POST /api/v1/actions/:id/handoff`를 만들어. 목표, 합의된 범위, 기한, 상대방, 근거 원문 인용을 담은
> 마크다운 컨텍스트 번들을 돌려주고 handoff_used 이벤트를 남겨. (앱의 'AI에게 넘기기' 버튼은 Phase A1에서 이 API를 부른다.)"

확장: Taskforce를 MCP 서버로 노출하면 Claude/Claude Code가 "내 오늘 Action과 맥락"을 직접 조회해 작업할 수 있다.

## Phase 5 — 지표 (1일, 베타 배포 전 필수)

> 프롬프트:
> "PRD 6장의 세 지표를 계산하는 관리자용 `/admin/metrics` 페이지를 만들어.
> 사용자가 AI 생성 Action을 수정/삭제하면 어떤 필드를 바꿨는지 ActionEvent로 남기고, 오판율을 필드별·단계별(추출/매칭)로 보여줘."

완료 기준: 베타 테스터 한 명의 하루치 사용으로 세 지표가 계산됨.

---

## Apple 트랙 (Mac의 Claude Code에서)

시작 전 준비: Apple Developer Program 가입, 번들 ID · App Group 결정, Sign in with Apple 설정 ([`PLATFORMS.md`](PLATFORMS.md) 6장).

### Phase A0 — 앱 뼈대 (1일, Phase 1과 동시 진행 가능) ✅ 완료

> 프롬프트:
> "CLAUDE.md와 docs/PLATFORMS.md를 읽어. `apple/`에 iOS·macOS 멀티플랫폼 SwiftUI 앱과 공유 Swift 패키지 `TaskforceKit`을 만들어.
> supabase-swift로 Sign in with Apple 로그인을 붙이고, 세션은 App Group 공유 Keychain에 저장해.
> 로그인 후 빈 '지금 할 일' 화면을 보여줘. Supabase URL과 키는 xcconfig로 빼고 커밋하지 마. TaskforceKit에 단위 테스트를 둬."

완료 기준: iPhone 시뮬레이터와 Mac에서 로그인 후 빈 화면이 뜸.

### Phase A1 — 화면 (2~3일, Phase 3 이후)

> 프롬프트:
> "TaskforceKit에 `src/lib/api/contract.ts`와 같은 모양의 Swift 모델과 API 클라이언트를 만들어.
> 화면: ① 지금 할 일 ② Action 상세(합의 범위, 근거 인용, 변경 이력, AI에게 넘기기) ③ 확인 요청(한 번 탭으로 확정/수정).
> 읽기는 Supabase에서 직접(RLS), 쓰기는 모두 /api/v1으로 보내. Realtime으로 새 Action이 생기면 바로 반영해.
> 앱이 열릴 때 app_opened 이벤트를 보내."

완료 기준: 웹 시험대에 원문을 넣으면 iPhone과 Mac 앱에 새 Action이 바로 뜸.

### Phase A2 — 원문 입력 (2일)

> 프롬프트:
> "iOS·macOS 공유 확장을 만들어 텍스트·URL·파일을 `POST /api/v1/sources`로 보내. 세션은 App Group Keychain에서 읽어.
> macOS에는 MenuBarExtra로 '지금 할 일'과 확인 요청을 보여주고, 전역 단축키로 클립보드 내용을 보내는 기능을 추가해."

완료 기준: 메일 앱에서 공유 → Taskforce, Mac에서 복사 후 단축키로 원문이 들어가 Action이 생김.

### Phase A3 — 알림 (1일)

> 프롬프트:
> "앱에서 알림 권한을 받고 기기 토큰을 `POST /api/v1/devices`로 등록해. 알림을 누르면 해당 Action 상세로 이동하게 해."

완료 기준: 확인 요청이 생기면 iPhone과 Mac에 알림이 오고, 누르면 해당 화면이 열림.

이후: 위젯 · 잠금화면 위젯, App Intents(Siri · 단축어).

---

## Phase 6 — 연동 (베타 반응을 본 뒤)

우선순위 제안: 회의록(Notion/Google Meet 등 AI 회의록 도구) → Gmail → Slack.
각 연동은 "Source를 만들어 파이프라인에 넣는 어댑터"일 뿐이어야 한다. 파이프라인은 건드리지 않는다.

---

## 모델 선택 팁

- Claim 추출은 품질이 제품 그 자체이므로 상위 생성형 모델로 시작하고, eval 숫자를 보며 비용을 낮춘다.
- 예/아니오·선택지·척도 판정(검증, 사전 필터, 매칭)은 Jev로 한다. 빠르고 싸고 확률이 보정되어 있어 임계값을 걸기 좋다.
- 모델을 바꾸면 반드시 `npm run eval`로 비교.

## 피해야 할 함정

- 연동부터 만들기 → 2주가 OAuth에 사라지고 핵심 가설은 검증 못 함
- 웹에 사용자용 화면 만들기 → 결국 앱에서 다시 만들어야 함. 웹은 시험대·지표까지만
- 앱에 판정 로직 복제하기 → 진실 판정이 두 군데서 달라짐. 앱은 서버 결과를 보여주기만
- 예쁜 대시보드부터 만들기 → 테스터가 반응한 건 "관리 안 해도 최신인 목록"이지 화면이 아님
- eval 없이 프롬프트 튜닝 → 한 케이스 고치면 다른 케이스가 깨지는 걸 모름
- 확인 요청 남발 → 불확실성을 사용자에게 떠넘기면 다시 관리 도구가 됨
