# 브랜드: 핵심 메시지와 비주얼

관련 문서: [PRD](PRD.md) · [플랫폼 전략](PLATFORMS.md) · [go live](GO_LIVE.md)

## 핵심 메시지 (2026-09-27 확정)

> Taskforce는 Real AI Manager로서 회의록·메시지·메일에서 내가 맡은 일을 찾아 알아서 정리하고 관리해주는 앱으로, 미팅이 많은 창업자와 컨설턴트가 직접 관리하지 않아도 약속한 일을 놓치지 않게 해 줍니다.

앱 소개, App Store 설명, 웹사이트 첫 화면, 프로필 소개 등 제품을 처음 설명하는 모든 곳에 이 문장을 그대로 쓴다.
짧게 줄여야 하면 이 문장에서 덜어내고, 새 약속을 더하지 않는다.

### 지금 쓰는 판 (go live, 2026-09-27)

go live 조건이 1단계 연동(Notion · Google · Slack)으로 바뀌어(2026-09-27, [GO_LIVE.md](GO_LIVE.md) "go live의 정의"), go live 때부터 회의록 · 메시지 · 메일이 모두 들어온다. 그래서 **위 완성형 문장을 그대로 쓴다.** 줄인 판("회의록에서")은 쓰지 않는다.

go live 전에 1단계 중 하나라도 빠지면, 빠진 원문 종류를 문장에서 덜어낸다(새 약속을 더하지 않는다는 규칙과 같다).

### 이름표: 자리에 따라 둘을 나눠 쓴다

문장 속 "Real AI Manager" 자리는 쓰는 곳에 따라 바꾼다. 나머지 문장은 그대로 둔다.

| 이름표 | 쓰는 곳 | 이유 |
|---|---|---|
| **AI 프로젝트 매니저** | App Store 앱 이름 · 부제 · 설명, TestFlight, 앱 안, 웹 `<title>`, 개인정보 처리방침 | 제품이 무엇인지 알려 주는 자리다. 한국어로 바로 읽히고, 비교 주장이 없어 근거를 붙이지 않아도 된다 |
| **Real AI Manager** | 웹사이트 첫 화면, 피칭 · 소개 자료, 프로필 소개 | 다른 AI 도구와 다르다고 주장하는 자리다. 아래 ["Real"의 근거](#real의-근거)를 같은 화면이나 바로 다음 문단에 함께 둔다 |

App Store 설명에는 "Real"을 쓰지 않는다. 확인할 수 없는 비교 주장으로 읽힐 수 있다.

| 요소 | 문장 속 표현 | 근거 (PRD) |
|---|---|---|
| 무엇인가 | Real AI Manager / AI 프로젝트 매니저 (자리에 따라) | 좋은 PM의 두 능력: 묻지 않아도 상태를 알고, 설명하지 않아도 맥락을 안다 |
| 무엇을 하나 | 회의록·메시지·메일에서 내가 맡은 일을 찾아 알아서 정리하고 관리 | 원문에서 사용자가 맡았거나 약속한 Action만 추출, 중복 병합, 기한·범위 변경 자동 반영 |
| 누구를 위해 | 미팅이 많은 창업자와 컨설턴트 | 다맥락 업무를 하는 스타트업 창업자·컨설턴트 |
| 왜 중요한가 | 직접 관리하지 않아도 약속한 일을 놓치지 않게 | 문제의 결과는 "지저분한 목록"이 아니라 약속한 일을 놓치는 것 |

## 표현을 이렇게 고른 이유

- **"내가 맡은 일"**: "나의 할 일"이라고 하면 또 하나의 할 일 앱으로 읽힌다. 남의 할 일과 참고 정보는 빼고 내가 약속하거나 떠맡은 일만 고른다는 점이 이 제품의 차이다.
- **"관리해주는"**: 한 번 뽑고 끝나는 게 아니라 기한이 바뀌면 갱신하고 중복은 합친다는 뜻이다.
- **"미팅이 많은"**: "다맥락", "맥락이 많은"은 내부 용어라 처음 보는 사람이 바로 이해하지 못한다.
- **"약속한 일을 놓치지 않게"**: "집중"은 모든 생산성 앱이 하는 약속이다. 설치 계기는 "지난주에 약속한 걸 놓쳤다"는 경험이다. 집중·복기 없는 착수는 보조 문구에서 푼다.

## 쓰지 않는 표현

| 쓰지 않는 표현 | 이유 |
|---|---|
| 할 일을 "실행해 준다", "대신 처리한다" | 앱은 실행하지 않는다. "AI에게 넘기기"는 맥락을 묶어 줄 뿐이다 |
| 아직 붙지 않은 원문을 "자동으로 가져온다" | 원문은 자동 연동으로 받는다 ([GO_LIVE.md](GO_LIVE.md)). go live 때 자동으로 들어오는 것은 1단계 연동(Notion 회의록 · Slack 메시지 · Gmail 메일 · Google 일정 · Meet 전사)이다. 2단계 연동(Microsoft 365 · Zoom · GitHub · Linear · Jira)은 붙기 전에 말하지 않는다. 공유 시트 · 붙여넣기는 보류라 안내하지 않는다 |
| 다맥락, Action, Claim, Evidence, 추출 | 내부 용어다. 사용자에게는 "맡은 일", "약속", "원문"으로 말한다 |
| Real AI "Manger" | 오타. "manger"는 구유라는 뜻이다. 항상 "Manager"로 쓴다 |

## "Real"의 근거

"Real AI Manager"는 다른 AI 도구와 비교하는 주장이라 근거와 함께 써야 한다. 지금 제품으로 보여줄 수 있는 근거:

- 모든 할 일에 원문 인용이 붙는다 (제품 원칙 2).
- 기한·범위가 바뀐 원문이 오면 새 할 일을 만들지 않고 기존 것을 갱신한다 (핵심 시나리오 2). go live 때부터 Slack 메시지로 기한이 바뀌는 장면(PRD 핵심 시나리오 2)을 그대로 보여 줄 수 있다.
- 불확실한 담당·기한만 묻고, 확실한 건 조용히 반영한다 (제품 원칙 3).

## 비주얼 키트 (2026-09-27)

원본은 Figma 디자인 시스템 v1이다: <https://www.figma.com/design/jDMRGHWMRXeNUILfi11xvf>. 값이 다르면 Figma 변수가 기준이다.
정교한 디자인 시스템이 아니라 지금 필요한 최소 범위다. 일반 부품(버튼, 토글, 목록 틀)은 Apple 기본 부품을 쓰고, Taskforce에만 있는 부품만 만든다.

### 색

| 역할 | 라이트 | 다크 | 쓰는 곳 |
|---|---|---|---|
| **Primary · Ink** | `#1D1D1F` | `#FFFFFF` | 로고, 제목·본문 글자, 주 버튼 |
| **Accent · Off-blue** | `#4A6FA5` | `#6A8CC7` | 한 화면에 한 곳만 (Mac 런처의 선택 행). 로고에는 쓰지 않는다 |
| 보조 글자 | `#636366` | `#9A9AA0` | 기한, 날짜, 출처 |
| 기한 지남 | `#D70015` | `#FF453A` | 기한 글자에만 |
| 바탕 · 카드 | `#FFFFFF` · `#F5F5F7` | `#000000` · `#1C1C1E` | 화면 바탕 · Review card |
| 헤어라인 | `#E0E0E0` | `#3A3A3C` | 구분선, 카드 테두리 |
| 누르는 요소 테두리 | `#636366` | `#9A9AA0` | 체크 원 (배경 대비 3:1 이상) |

- 앱 아이콘 바탕은 모드와 상관없이 `#000000`이다.
- 글자는 모두 배경 대비 4.5:1 이상이다. 보조 회색과 빨강은 이 기준 때문에 정했다.

### 글꼴

| 트랙 | 글꼴 | 쓰는 곳 |
|---|---|---|
| App | SF Pro (시스템) | iOS · macOS 앱 화면. 사용자 글자 크기(Dynamic Type)를 따른다 |
| Brand | IBM Plex Sans KR + IBM Plex Mono (Google Fonts) | 웹사이트, App Store 이미지, 소개 자료. 앱 화면에는 쓰지 않는다 |

- 굵기는 400과 600만 쓴다.
- 17pt 이상은 음수 트래킹을 준다 (17pt −0.374px).
- 웹 본문은 17/25, 제목은 56/60과 40/44.
- Mono는 단축키 · 날짜 · 숫자에만 쓰고 한글에는 쓰지 않는다.

### 로고

- **마크**: 앱 아이콘의 두 획이다. 위 선은 회의에서 오간 말, 아래 선은 내 할 일 목록, 곡선은 둘을 끊기지 않게 잇는다는 뜻이다.
- **조합**: 마크 높이 = 워드마크 대문자 높이 × 1.4, 간격 = 마크 획 두께 × 2. 워드마크는 IBM Plex Sans KR SemiBold, 자간 −1%.
- **종류**: 가로형, 워드마크만, 마크만, 앱 아이콘 4가지.
- **색**: 로고는 항상 한 색이다. 흰 배경에는 Ink, 검정 배경에는 흰색.
- **금지**: Accent 색, 그라데이션, 그림자, 회전·변형, "AI" 배지.
- **최소 크기**: 마크 16px, 가로형 높이 24px.

### 모양

- **모서리**: 네 가지만 쓴다. 칩 5 · 행 8 · 카드 18 · 창 26, 버튼은 캡슐.
- **간격**: 4pt 단위.
- **그림자**: 카드 · 버튼 · 글자에는 쓰지 않는다. 창 그림자는 macOS가 그린다.
- **Mac 런처**: 반투명 유리 재질. macOS 26부터 Liquid Glass(`NSGlassEffectView`), 그 전은 `NSVisualEffectView`. 밝은 바탕화면과 어두운 바탕화면 위에서 글자 대비를 확인한다.
- **Liquid Glass (iOS 26 · macOS 26)**: 내용 위에 떠 있는 면과 컨트롤(런처 창 · Review card · 툴바 버튼 · 시트)에만 쓴다. 할 일 행 같은 내용은 평평하게 둔다. 유리 위 주 버튼은 잉크 유리(accent 아님). 유리 자체의 그림자는 시스템이 그린다.
- **구분선**: iOS 목록처럼 글자 시작점부터 긋는다.

### UI 문구

화면 틀은 짧은 영어 표준 용어로 쓰고, 사용자 내용(할 일 제목, 인용, 문서 이름)은 원문 언어 그대로 둔다.

| 쓴다 | 쓰지 않는다 |
|---|---|
| Review · Confirm · Dismiss | 맞나요? · 맞아요 · 아니에요 |
| Sources 2 · Open | 근거 2 · 열기 · 외 2곳 |
| In Progress · To Do · Done Today · Search · Actions | 지금 할 일 · 할 일 찾기, 내 약속 물어보기… · 동작 |
| Today · Yesterday 18:00 · Sep 22 | 오늘 마감 · 어제 18:00 지남 · 9월 22일 |

- 필요 없는 부제, 캡션, 설명 문장을 붙이지 않는다. 아이콘 · 값 · 위치가 이미 보여 주는 것은 글로 다시 쓰지 않는다.
- 서비스(Notion, Slack, Gmail, Google Meet)는 실제 로고로 보여 주고, 이름을 글자로 쓰지 않는다. 로고는 Simple Icons(CC0)의 단색 벡터다.
- 위 [쓰지 않는 표현](#쓰지-않는-표현)의 내부 용어 규칙은 그대로다. 화면에서는 Evidence 대신 Sources라고 쓴다.

### 부품

| 부품 | 규칙 |
|---|---|
| Task status | 할 일 행 왼쪽의 상태 표시(iPhone · Mac 공용): ○ To Do(border/control) · ◉ In Progress(잉크 테두리 + 안쪽 잉크 원) · ✓ Done(잉크 원 + 흰 체크) · 점선 원 Review. 잉크만 쓰고 accent는 쓰지 않는다. ○ · ◉를 누르면 Done, ✓는 끝내기 전 상태로(Review는 누를 수 없음). 상태를 옮기는 동작 이름은 To Do · In Progress · Done 세 가지뿐이다 |
| Task row (iPhone) | 상태 표시 + 제목 + 기한. 기한 지남은 기한 글자만 빨강. 완료는 검정 체크 + 회색 글자(취소선 없음). 상대 이름은 기본으로 끈다 |
| Review card (iPhone) | 제목 + 확인할 값 + 근거 1줄 + Confirm / Dismiss 캡슐. 목록 위에 한 번에 한 장만 보인다("Review  1 / 3"). 인용은 3줄까지 |
| Evidence | 출처 로고 + 원문 인용 + "날짜 · 문서". 날짜는 항상 보이고 문서 이름만 …로 줄인다. 출처가 여럿이면 맨 앞 로고는 인용의 출처 하나, 나머지는 줄 끝에 작게 겹친다 |
| Sources group (Mac) | 겹친 로고 + "Sources N" 제목 아래에 근거를 줄마다 두고 Open을 붙인다 |
| Launcher row (Mac) | 제목 + 오른쪽에 기한 하나. 기한 지남 · 오늘은 빨강. 선택 행만 파란 바탕 + return 키캡. 부제는 기본으로 끈다 |
| Keycap | 단축키 표시. 앱에서는 ↩ 등을 SF Symbol로 그린다 |

### 스트레스 테스트로 정한 것

Figma의 Stress test 페이지에서 긴 글, 빠진 값, 320pt 폭, 큰 글자를 시험했다. 발견한 문제 14건 중 12건은 부품에서 고쳤고, 나머지 2건은 구현할 때 확인한다.

- 가장 작은 iPhone(320×568)에서는 Review card 두 장이면 할 일 목록이 화면 밖으로 밀려난다. 그래서 카드는 한 번에 한 장만 보여 준다.
- 한글이 단어 중간에서 줄바꿈되지 않는지 실제 기기에서 확인한다 (Figma는 글자 단위로 줄바꿈한다).
- 출처 로고 타일은 큰 글자에서 함께 커져야 한다 (`@ScaledMetric`).

## 웹사이트 (2026-09-27, 첫 안)

taskforcelabs.dev 첫 화면을 한 페이지로 만든다. 메뉴는 없다. 사이트는 영어로 만든다. Figma의 Website 페이지에 데스크톱(1440)과 모바일(390) 화면이 있다.
UI 다듬기는 보류 중이다. 제품 화면이 구현되면 다시 채운다.

### 구조

| # | 섹션 | 바탕 | 내용 |
|---|---|---|---|
| 0 | Nav | 흰색 | 로고 가로형만 |
| 1 | Hero | 흰색 | 헤드라인 + 부제 + CTA + 요건 한 줄 + 제품 화면(유리 재질 Mac 런처와 iPhone. 모바일은 iPhone만) |
| 2 | Context | `#F5F5F7` | 맥락 한 문단 |
| 3 | Proof | 검정 (다크 모드) | 주장 3개. 칸마다 실제 부품을 넣는다. 그 아래 개인정보 한 줄과 Privacy 링크 |
| 4 | CTA | 흰색 | 같은 CTA를 한 번 더 |
| 5 | Footer | `#F5F5F7` | 마크 · © 2026 Taskforce Labs · Privacy · Contact |

바탕색이 바뀌는 것이 섹션 구분이다. 구분선을 따로 긋지 않는다. Accent는 Privacy 링크 한 곳에만 쓰고, 버튼은 Ink 캡슐이다.

### 문구

| 자리 | 문구 |
|---|---|
| 헤드라인 | Never miss what you promised. |
| 부제 | The Real AI Manager for founders and consultants in back-to-back meetings. Taskforce finds what you committed to in your meeting notes, Slack, and email, then organizes and tracks it for you. |
| CTA | Join the TestFlight beta |
| 요건 | iPhone · Mac + Notion · Google · Slack 로고 |
| 맥락 | After a meeting, your to-dos are scattered across the notes. Connect Notion, and Taskforce reads each new meeting note, picks out only what you said you'd do, and adds it to your list with a due date. When a later meeting moves a deadline, it updates the task instead of adding a new one. Every task carries the exact line it came from. |
| 주장 1 | Every task shows the line it came from. (Evidence 부품) |
| 주장 2 | Changes update the task. No duplicates. (Sources group 부품) |
| 주장 3 | Asks only when it isn't sure. (Review card 부품) |
| 개인정보 | AI calls go only to providers that keep no data. Your data stays in Sydney, and deleting your account deletes it right away. |
| 마지막 CTA | Start with your next meeting. |

- 헤드라인과 부제를 합치면 핵심 메시지(go live 판)와 같은 내용이다. 헤드라인은 "왜 중요한가", 부제는 "누구를 위해 · 무엇을"을 맡는다.
- "Real AI Manager"를 쓰는 자리라서, 그 근거(주장 3개)를 같은 페이지의 Proof 섹션에 둔다.
- 요건 한 줄은 캡션을 줄이는 원칙의 예외다. 1단계 연동(Notion · Google · Slack)을 하나도 쓰지 않는 사람이 설치했다가 빈 화면을 보는 일을 막는다. 서비스는 로고로 보여 준다(UI 문구 규칙).
- **맥락 문단은 아직 Notion 기준이다.** go live 전에 회의록 · Slack · 메일을 아우르도록 다시 쓴다(카피 작업).
- 연동이 늘면 부제와 맥락의 "meeting notes"를 함께 넓힌다(위 [지금 쓰는 판](#지금-쓰는-판-go-live-2026-09-27) 규칙).
- 개인정보 한 줄은 개인정보 처리방침에 이미 적은 약속만 쓴다. 방침이 바뀌면 이 줄도 고친다.

### CTA와 측정

- 동작은 하나다: TestFlight 공개 링크.
- 대기 명단(이메일 받기)은 쓰지 않는다. 개인정보 처리방침에 없는 수집이라서다.
- 사이트에는 분석 도구와 쿠키를 넣지 않는다(개인정보 처리방침의 약속). 유입은 App Store Connect의 공개 링크 설치 수로 본다.

### 공개 전에 할 일

- 사이트는 go live와 같은 날 연다. 앱에서 Notion 연결과 서버 배포가 끝나기 전에 CTA를 열면, 설치한 사람이 원문을 넣을 방법이 없다([GO_LIVE.md](GO_LIVE.md) 1 · 2장).
- TestFlight 외부 테스트 심사를 통과해 공개 링크를 받는다.
- Contact 주소를 정한다. 지금 확인된 주소는 `privacy@taskforcelabs.dev`뿐이다.
- 제품 화면을 실제 앱 스크린샷으로 바꾼다. 지금은 Figma 부품으로 만든 목업이다.
- 신뢰 요소(초기 성과, 만드는 과정)는 제품을 만든 뒤 다시 정한다. 그때 실제 회의로 돌린 평가 수치를 쓴다.
