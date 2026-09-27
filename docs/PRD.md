# Taskforce PRD — AI 프로젝트 매니저

## 1. 문제

다맥락 업무(짧은 시간 안에 서로 다른 맥락으로 계속 전환하는 일)를 하는 스타트업 창업자·컨설턴트는

- **관리 비용**: 할 일을 적고 상태를 갱신할 여력이 없어 목록이 방치된다.
- **맥락의 휘발**: 미팅 중 생긴 할 일과 합의 내용이 다음 우선순위에 밀려 사라지고,
  목록을 열 때마다 맥락을 복기해야 한다.

결과는 "지저분한 목록"이 아니라 **약속한 일을 놓치는 것**이다.

## 2. 해결 — 좋은 PM의 두 능력

| 능력 | 기능 |
|---|---|
| 묻지 않아도 상태를 안다 | 원문에서 사용자가 맡았거나 약속한 Action만 추출, 중복 병합, 기한·범위 변경 자동 반영. 불확실한 담당/기한만 확인 요청 |
| 설명하지 않아도 맥락을 안다 | Action마다 합의 범위·근거 원문을 함께 보여줌. 그 맥락을 묶어 AI에 핸드오프 |

### 핵심 시나리오 (수용 기준)

1. 회의록: "금요일까지 제안서 보내드릴게요" → Action `제안서 발송` (기한: 금, 근거: 회의록 인용) 생성
2. 이후 메시지: "제안서는 월요일에 받아도 괜찮아요" → **새 Action을 만들지 않고** 기존 Action의 기한을 월요일로 갱신, 변경 이력에 메시지 인용
3. 월요일 아침 "지금 할 일" 화면 최상단에 노출, 펼치면 합의된 범위 + 두 원문 근거
4. "AI에게 넘기기" → 맥락이 담긴 프롬프트/문서가 생성되어 바로 작업 위임 가능

## 3. 범위

### 플랫폼

- 사용자용 앱: **iOS + macOS 네이티브** (SwiftUI). 웹은 서버 API와 내부 도구(시험대 · eval · 지표)로만 쓴다.
- 상세는 [`PLATFORMS.md`](PLATFORMS.md).

### MVP (베타)
- 원문 입력 (외부 서비스 연동 없이)
  - iOS: 공유 시트로 보내기
  - macOS: 메뉴 막대 앱 · 단축키로 클립보드 보내기 · 공유 메뉴
  - 붙여넣기 / 파일 업로드
- Action 추출 + 기존 Action과 매칭(신규·갱신·중복·완료)
- 확인 큐 (담당·기한 불확실 항목)
- "지금 할 일" 뷰 + Action 상세(근거·변경 이력)
- AI 핸드오프 (복사 가능한 컨텍스트 번들)
- 지표 이벤트 로깅
- 누락 신고 (Source 상세에서 원문 구절 선택)
- 알림: 확인 요청 발생, 기한 임박
- 로그인: Sign in with Apple (보조: 이메일 코드)

### 이후
- iOS 위젯 · 잠금화면 위젯, Siri · 단축어 (App Intents)
- 연동: Gmail, Google Calendar/회의록(Notion·Google Meet 등), Slack
- MCP 서버: Claude 등 AI 도구가 내 Action과 맥락을 직접 조회
- 완료 자동 감지 (예: "보냈습니다" 메일 → 완료 처리)

### 하지 않는 것
- 팀 협업/권한/칸반 보드 — 개인의 "제2의 뇌"가 먼저
- 사용자용 웹 앱, Android · Windows 앱
- 미팅 녹음 · 받아쓰기 (AI 회의록 도구 연동으로 대신)
- 수동 할 일 작성 중심 UX

## 4. 데이터 모델 (초안)

```
Source        id, user_id, kind(meeting|message|email|doc|note), title, raw_text, occurred_at, external_url
Action        id, user_id, title, scope_summary, owner(me|other|unknown), counterpart,
              due_at, due_confidence, owner_confidence, status(open|done|dropped),
              needs_confirmation, embedding, created_at, updated_at
Evidence      id, action_id, source_id, quote, role(created|updated|completed)
Claim         id, action_id, field(due|scope|owner|status), value, source_id, quote, occurred_at,
              speaker_role(me|counterpart|third_party), certainty(firm|tentative),
              directness(first_hand|reported), audience(shared|private), state(active|superseded|disputed)
ActionEvent   id, action_id, type(created|due_changed|scope_changed|merged|completed|
              user_edited|user_deleted|user_confirmed|user_reported_missing), before, after, source_id, actor(ai|user)
MetricEvent   id, user_id, type(app_opened|action_started|handoff_used), action_id, at
```

## 5. 추출 파이프라인

```
Source 입력
  → ① 후보 추출 (LLM, 구조화 출력)
       - 사용자가 맡았거나 약속한 것만. 참고 정보·남의 할 일은 제외
       - 각 후보: title, owner, counterpart, due(원문 표현 + 정규화 날짜), 신뢰도, 근거 인용
  → ② 기계적 검증 (인용 실재 확인, 날짜 재계산, 스키마 검증)
  → ③ Jev 판정 (후보별 검증 확률 + Claim 속성 분류)
  → ④ 매칭 (임베딩으로 열린 Action top-k 검색 → LLM 판정)
       - new | update(기한/범위 변경) | duplicate | complete
       - update는 Action을 직접 고치지 않고 필드별 Claim으로 저장
  → ⑤ 진실 판정 (코드, 규칙 기반) → Action 현재 값 계산
  → ⑥ 반영 정책
       - 신뢰도 높음 → 자동 반영 + ActionEvent 기록
       - 담당/기한 신뢰도 낮음 → 확인 큐
  → ⑦ "지금 할 일" 랭킹 (기한 임박, 외부와의 약속, 방치 기간)
```

Jev 판정과 진실 판정 규칙의 상세는 [`TRUTH_RULES.md`](TRUTH_RULES.md)를 보세요.

## 6. 성공 지표 (베타)

| # | 지표 | 계산 | 의미 |
|---|---|---|---|
| 1 | **AI 오판율** | (사용자가 수정·삭제한 AI 생성 Action) / (AI 생성 Action) | 높으면 AI PM 접근 자체를 재검토 → 피벗 기준 |
| 2 | 착수 시간 | app_opened → 첫 action_started / handoff_used | 복기 비용이 사라졌는지 |
| 3 | 리텐션 | N주 후 주간 활성 여부 | 계속 쓸 가치가 있는지 |
| 4 | **AI 누락률** | (사용자가 신고한 누락 Action) / (AI 생성 Action + 신고한 누락 Action) | 높으면 사용자가 목록을 믿지 못함 → 지표 1과 함께 피벗 기준 |
| 5 | 그림자 목록 비율 | 주간 질문 "Taskforce 밖에 따로 적어둔 할 일이 있나요?"에 '예'라고 답한 활성 사용자 비율 | Taskforce가 기존 목록을 대체했는지, 목록이 하나 더 늘었을 뿐인지 |

지표 1은 필드 단위로도 쪼개 본다 (제목/기한/담당/삭제). 어느 단계(추출 vs 매칭)가 틀렸는지 알아야 고칠 수 있다.

### 왜 누락을 따로 재는가

지표 1은 **정밀도**(만든 것 중 틀린 것)만 본다. 추출을 줄이면 지표 1은 좋아지지만 놓치는 약속이 늘어난다. 그래서 지표 1과 4는 항상 같이 본다.

잘못 만든 Action은 눈에 보여서 지우면 끝나지만, 놓친 약속은 보이지 않는다. 사용자는 한 번 놓친 경험 뒤에 따로 백업 목록을 쓰기 시작하고, 그 순간 Taskforce는 목록을 대체하는 도구가 아니라 하나 더 늘어난 도구가 된다. 지표 5는 그 상태를 직접 잰다.

### 누락 신호를 모으는 방법

- **누락 신고**: Source 상세에서 원문 구절을 골라 "이 할 일이 빠졌어요"를 누른다. 구절이 곧 근거가 되므로 원칙 1·2를 지킨다 (빈 폼으로 할 일을 적는 흐름이 아니다).
  신고된 구절은 일반 파이프라인(매칭 → Claim → resolve)을 그대로 거치고 `ActionEvent(type=user_reported_missing, actor=user)`로 남는다.
- **원인 분석**: 신고 건마다 어느 단계에서 빠졌는지 분류한다 — 사전 필터에서 건너뜀 / 추출 안 됨 / 기계적 검증 탈락 / Jev 기각(`JudgeLog`) / 매칭에서 duplicate로 잘못 흡수. 지표 1처럼 단계별로 봐야 고칠 수 있다.
- **그림자 목록 질문**: 주 1회, 앱을 연 사용자에게만 묻는다. 확인 요청이 늘어나는 비용(원칙 3)을 고려해 베타 기간에만 둔다.
- **오프라인 재현율**: 골든셋 eval의 recall은 계속 본다. 누락 신고로 들어온 구절은 (사용자 동의 하에, 개인정보를 지운 뒤) 골든셋 후보로 쌓는다.

한계: 사용자가 누락을 알아채지 못하면 신고도 없다. 지표 4는 실제 누락률의 **하한**이므로 지표 5와 오프라인 재현율로 보완한다.
