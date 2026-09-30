# 베타 go live: 남은 일

관련 문서: [연동](INTEGRATIONS.md) · [플랫폼](PLATFORMS.md) · [바이브코딩 플랜](VIBE_CODING_PLAN.md) · [PRD](PRD.md)
관련 문서 (go live 준비): [런북 · 체크리스트](go-live/runbook.md) · [Google 심사](go-live/google-verification.md) · [Slack 앱](go-live/slack-app.md) · [App Store](go-live/app-store.md) · [처리방침 · 약관](legal/README.md)

작성: 2026-09-27. 브랜드 스코핑(문구 · 개인정보 처리방침 · 아이콘 · 강조색)을 마친 뒤, 외부 테스터를 받기 전에 남은 일을 정리한다.

## go live의 정의 (2026-09-27 확정)

> **go live** = TestFlight 공개 링크와 웹사이트를 여는 날. 그날부터 팀 밖의 테스터가 앱을 설치하고, 연결 화면에서 자기 약속이 오가는 곳(회의 · 메시지 · 메일 · 일정)을 직접 연결하고, 그 뒤로는 아무것도 넣지 않아도 할 일이 채워진다.

App Store 정식 출시가 아니다. "Notion만 연결할 수 있다"로는 go live가 아니다. 연동은 두 단계로 나눈다.

| 단계 | 연동 | go live와의 관계 |
|---|---|---|
| **1단계** | Notion · **Google**(Calendar · Meet 전사) · **Gmail** · **Slack** (Google 쪽 연결은 `google` · `gmail` 둘) | **go live 조건.** 회의에서 약속 → 메시지로 기한 변경 → 메일로 확인까지 PRD 핵심 시나리오를 모두 덮는다 |
| **2단계** | Microsoft 365(Outlook · 일정 · Teams를 연결 한 번으로) · Zoom · GitHub · Linear · Jira | go live 때 연결 화면에 **보이지만 아직 연결은 안 된다.** 누르면 "원해요"를 `connection_requests`에 남기고, 테스터 수요가 많은 순서로 붙인다 (원칙 6) |

1단계 연동마다 go live 전에 끝낼 것: 앱 연결 화면 · 서버 동기화 · 개인정보 처리방침의 "수집하는 정보"와 "처리 위탁" · **그 원문 종류의 골든셋과 eval**(메일 · Slack 메시지는 회의록과 문체가 달라 정확도를 따로 잰다).

## 결정: 원문은 자동 연동으로 받는다

- 공유 시트 · 붙여넣기는 **go live 조건이 아니다.** 메시지를 볼 때마다 "Taskforce로 보내야지"를 기억해야 한다면, 그것도 대상 사용자에게 없는 관리 여력을 요구하는 일이다.
  이 판단은 [INTEGRATIONS.md](INTEGRATIONS.md)의 "사용자는 원문을 직접 넣지 않는다"와 같다.
- go live 조건은 **테스터가 앱에서 1단계 연동(Notion · Google · Slack)을 직접 연결할 수 있는 것**이다. (2026-09-27 기준) 서버 쪽은 Notion만 동작하고, 연결 화면은 내부용 `/lab`에만 있다. 지금 테스터가 앱을 설치하면 원문을 넣을 방법이 없어서 빈 화면만 보게 된다.
- 카카오톡은 개인 채팅을 읽는 공개 API가 없어 자동 연동이 불가능하다. 이 공백이 실제로 문제인지는 7장의 기준으로 판단한다.

## 요약

| # | 할 일 | 종류 | go live 조건 |
|---|---|---|---|
| 1 | 앱의 연결 화면 + Notion 연결 | 코드 (서버 + 앱) | **필수** · ✅ 끝남 (2026-09-28, 로컬 서버로 확인) |
| 2 | 서버 배포 | 인프라 · 설정 | **필수** |
| 3 | 자동 동기화 주기 | 인프라 | 해결 (Vercel Pro) · 배포 뒤 확인만 |
| 4 | PRD · 계획 문서와 문구 정리 | 문서 | 권장 |
| 5 | Slack 연동 | 코드 · Slack 앱 설정 | **필수** (1단계) · 코드 ✅ 배포 (2026-09-29), 일반 이용자에게 열기 남음 |
| 6 | Google 연동 (Calendar · Gmail · Meet 전사) | 코드 · Google OAuth 설정 | **필수** (1단계) · 코드 ✅ 배포 (2026-09-30), 실제 회의 확인 · 처리방침 · 심사 · 열기 남음 |
| 7 | 공유 시트 · 붙여넣기 | 코드 | 보류 |
| 8 | 2단계 연동 자리와 "원해요" 이벤트 | 코드 (앱 + 이벤트) | **필수** (작음) · ✅ 끝남 (`connection_requests`) |
| — | 앱 모양: Mac 런처 + iPhone 목록으로 다시 만들지 | 결정 | **결정됨 · 끝남 (2026-09-28).** Mac은 ⌥Space 런처, iPhone은 한 화면 목록으로 다시 만들었다 |

## 현재 상태 (2026-09-30)

**1단계 연동 코드는 모두 main에 들어가 운영에 배포됐다.** 일반 이용자에게 여는 것은 플래그로 막혀 있고, 운영자(`ADMIN_EMAILS`)만 웹 /lab에서 연결해 시험할 수 있다.

| 연동 | 코드 | 일반 이용자에게 열기 | 열기 전에 |
|---|---|---|---|
| Notion | ✅ | ✅ 열림 | — |
| Slack | ✅ (#4 ~ #15) | `SLACK_CONNECT_ENABLED` 비움 | Slack 확인 창 · 끊기 문구가 든 앱 빌드를 TestFlight에 올림 |
| Gmail | ✅ (#25 · #27 · #31) | `GMAIL_CONNECT_ENABLED` 비움 | 처리방침 재게시(BaseTen 삭제 · Gmail 절 · 재연결 알림을 한 버전으로) → 17장 고지 기간 → 새 앱 빌드 |
| Calendar · Meet | ✅ (#30 · #36) | `GOOGLE_CONNECT_ENABLED` 비움 | 녹화한 Meet 회의 둘로 dev 확인(google-integration.md 9장: G2 참석한 회의 · G5 · 회의 코드 · 초대 일정) → PR 5b(처리방침 Calendar · Meet 문장 · 전체 검증) → 민감 범위 심사(L4) 또는 프로젝트 A도 Testing |

2026-09-30에 더 고친 것: 출력 한도를 넘긴 추출은 추론량을 제한해 다시 묻기(#28), Gmail · Meet 파이프라인 보완(#31), 하루 넘게 멈춘 원문을 실패로 닫기(#33), 빠진 할 일 신고 · 물어보기를 60초 안에(#34), 연결 설정을 DB 함수로 한 번에 쓰기(#35, 운영 DB에 `20261017000000` 적용).

같은 날 OpenRouter 키가 사용 한도($10)에 닿아 모든 AI 호출이 403이었다(운영과 로컬 · eval이 같은 키). 한도를 올렸고, 운영 키(`taskforce-prod`, 하루 $5)와 개발 키를 나눴다(런북 I9).

남은 코드: PR 5b와 G2 결과에 따른 Meet 줄 한 줄. 나머지는 사용자 몫이다(런북 GO LIVE 체크리스트: 처리방침 재게시, TestFlight 빌드 · 외부 심사, Google 심사, cron · 2단계 인증 확인).

## 현재 상태와 진행 순서 (2026-09-28)

2026-09-28에 Mac 앱으로 로그인 → Notion 연결 → 동기화 → 할 일 확인 · 추가 · 상태 바꾸기 · 지우기까지 로컬 서버로 확인했다. 남은 일과 순서는 아래와 같다. 항목 번호는 [런북 체크리스트](go-live/runbook.md#go-live-체크리스트)와 같다.

**끝난 것**
- 앱(C6): iPhone 한 화면(Review 카드 · In Progress / To Do / Done Today · + 직접 추가), Mac ⌥Space 런처(검색 · 물어보기 · 직접 추가 · ⌘K 상태 · 지우기), 연결 · AI 동의 · 계정 메뉴, Liquid Glass(iOS 26 · macOS 26, 이전 OS는 기존 재질).
- 서버: 연결 틀 · 동의(C1), 계정 삭제 시 Apple 토큰 폐기(C2), 물어보기(C3), 공급자 고정(C7), 직접 추가(`POST /api/v1/actions`), 작업 상태(`POST /api/v1/actions/:id/progress`), 내가 쓴 Notion 문서 판정(`written_by_me`), Notion 할 일 DB 자동 확인.
- 실제 DB에 `20261008` ~ `20261010` 마이그레이션 적용.
- 운영 서버 설정(I1 ~ I3 · I5 ~ I9): Vercel 배포 · `api.taskforcelabs.dev` · 환경변수(Google · Slack 제외) · Supabase Auth URL · Notion 운영 redirect · APNs · Sign in with Apple 키 · OpenRouter 한도와 계정 ZDR. 알림 서버 코드는 PR #4가 배포되면 켜진다.

**진행 순서**

| 순서 | 할 일 | 체크리스트 | 담당 | 기간 |
|---|---|---|---|---|
| 1 | 배포 전 코드: 보안 헤더, 첫 동기화 진행 표시 · Sync Now 안내, 앱 알림 등록(Phase A3) | C8 · C10 · C11 | 코드 | 2~3일 |
| 2 | 서버 배포 + TestFlight 내부 빌드 → **1주 직접 써 보기** (자동 동기화 · iPhone 실기기 · 지표 1~5 첫 숫자) | I1 ~ I12 | 사용자(계정 · 키) + 코드(명령 · 확인) | 1주 |
| 2' | 오래 걸리는 외부 일정 바로 시작: Search Console → Google 브랜드 심사 → Calendar · Meet 민감 범위 심사, Slack 앱 · 공개 배포, 법률 자체 검토(docs/legal/self-review.md, 2026-09-29) | L2 ~ L4 · L7 · L9 | 사용자 | 2~4주 (기다림) |
| 3 | Slack 연동 (PRD 핵심 시나리오 2, Slack 골든셋 · eval). 계획: [go-live/slack-integration.md](go-live/slack-integration.md) | C5 | 코드 | 1~2주 |
| 4 | Google 연동 (Calendar · Meet 전사 · Gmail은 테스트 상태로, 7일 재연결 안내). 계획: [go-live/google-integration.md](go-live/google-integration.md) | C4 · L5 | 코드 | 2~3주 |
| 5 | 마무리: 전체 검증, TestFlight 외부 심사, 웹사이트 교체, 새 계정으로 끝까지 확인 → 공개 링크 | C9 · L8 · L1 · G1 ~ G4 | 사용자 + 코드 | 1주 |

go live 날짜는 코드보다 **Google 심사(L3 · L4)** 에 묶인다. 2'를 1과 같은 주에 시작한다.

**직접 써 보며 드러난 것 (2와 함께 처리)**
- 추출 품질의 기준이 합성 예시뿐이다. 실제 워크스페이스에서는 남이 쓴 문서 · 제각각인 할 일 DB · 태그 없는 회의록이 많았다. 1주 사용 데이터로 익명화한 골든셋을 더한다 (원문은 사용자 동의 아래 로컬에서만 가공).
- 첫 동기화가 연결 뒤 4분 넘게 걸리는데 진행 표시가 없고, 그 사이 Sync Now는 "이미 동기화 중"만 보인다. 테스터가 가장 먼저 겪는 화면이다 (C11). ✅ 끝남: "Syncing…" 진행 표시, 동기화 중 Sync Now는 오류 대신 안내.
- 확인 요청(Review) 수가 늘면 그 자체가 관리 비용이다(원칙 3). 1주 사용에서 하루 몇 건인지 본다.
- CI는 서버만 검사한다. Swift 테스트 · 빌드를 CI에 더한다 (C12). ✅ 끝남: PR마다 `swift test`와 iOS · macOS 빌드.
- 내부 도구 웹 로그인(매직 링크)은 링크를 요청한 브라우저에서 열어야 한다(PKCE). 운영자 안내에 적는다.

---

## 1. 앱의 연결 화면 + Notion 연결

연결 화면과 앱용 OAuth 흐름(서명된 `state`, `taskforce://` 복귀)은 **모든 연동이 같이 쓰는 틀**로 만든다. 아래는 Notion 기준으로 적었고, Google(6장)과 Slack(5장)은 같은 틀에 서비스만 더한다.

### 문제: 지금 연결 흐름은 웹 로그인에만 맞춰져 있다

- `GET /api/connectors/notion/start`([route.ts](../src/app/api/connectors/notion/start/route.ts))와 `callback`([route.ts](../src/app/api/connectors/notion/callback/route.ts))은 `authenticateRequest`로 사용자를 확인한다. `state`는 httpOnly 쿠키에 담는다.
- 앱은 `ASWebAuthenticationSession`으로 브라우저를 띄우게 된다. 이 브라우저에는 웹 로그인 쿠키가 없고, `Authorization` 헤더도 붙일 수 없다. 그래서 start는 `/login`으로 튕기고, callback에서도 사용자를 알 수 없다.
- callback이 끝나면 `/lab?notion=...`으로 돌아가는데, 앱으로 돌아오는 경로가 없다.

### 서버 변경

1. **연결 시작 API (새 Route Handler):** `POST /api/v1/connections/notion/start`
   - 인증: 다른 v1 라우트와 같다(`Authorization: Bearer` 또는 쿠키).
   - 응답: `{ url }`, 즉 Notion 권한 화면 주소. 스키마는 `src/lib/api/contract.ts`에 zod로 둔다.
   - `state`: 쿠키 대신 서명된 값을 쓴다. 내용은 `{ userId, provider, nonce, exp(10분) }`이고, HMAC-SHA256으로 서명한다. 서명 키는 `OAUTH_STATE_SECRET`(서버 전용, 32자 이상)이다.
2. **callback이 두 흐름을 모두 받는다.**
   - 쿠키 `state`가 있으면 지금처럼 웹(`/lab`) 흐름으로 처리한다.
   - 서명된 `state`면 서명(timing-safe 비교)과 만료를 확인하고, 사용자는 `state` 안의 `userId`로 정한다. 이 경우 세션이 없어도 된다.
   - 같은 `state`를 두 번 쓰지 못하게 `nonce`를 한 번만 쓴다 (서버만 쓰는 `oauth_nonces` 표, `tests/db/go-live-connections.test.ts`).
   - 끝나면 code를 완료 대기(handoff)로 남기고 `taskforce://connections/notion?handoff=<id>`로 보낸다. 앱이 `POST /api/v1/connections/notion/complete {handoff}`로 연결을 마치고 `status`(`connected`, `connected_empty`, `connected_no_meetings`)를 받는다. 권한 화면 단계의 실패는 바로 `?status=denied|error|invalid_state`로 보낸다 (아래 "구현 결과").
3. **첫 동기화를 바로 시작한다.** 연결 직후 한 번 동기화해 최근 14일의 회의록을 가져온다. 그래야 테스터가 연결하자마자 결과를 본다. 서버가 `complete` 응답 뒤(`after()`) 바로 시작한다.
4. **로그:** `state`, `code`, 토큰은 로그에 남기지 않는다. 지금처럼 오류 메시지만 남긴다.

**구현 결과 (2026-09-27, 처음 계획과 달라진 점. 위 본문은 2026-09-29에 이에 맞췄다).** 시작 API는 서비스마다 만들지 않고 `POST /api/v1/connections/{provider}/start` 하나로 모든 연동이 같이 쓴다. callback은 서명된 `state`(앱)와 쿠키 `state`(웹) 두 흐름을 그대로 받지만, 앱 흐름에서는 바로 `status=<값>`으로 돌려보내지 않는다: code를 암호화한 **완료 대기(handoff, `oauth_handoffs`, 2분 유효)** 로 남기고 `taskforce://connections/{provider}?handoff=<id>`로 보낸 뒤, 앱이 그 `handoff`로 **`POST /api/v1/connections/{provider}/complete`** 를 Bearer 토큰과 함께 불러야 연결이 끝난다(시작한 사용자만, 한 번만 쓸 수 있음, 성공하면 응답 뒤 첫 동기화 실행). 연결 시작에는 속도 제한(10분에 10번, `rate_limit_events` · `take_rate_limit`)이 붙었다.

### 앱 변경

1. **연결 화면:** 계정 메뉴의 "로그아웃" · "계정 삭제" 옆에 "연결"을 둔다.
   - 목록은 `connections`를 RLS로 직접 읽는다. 보여줄 것은 서비스 이름, 워크스페이스 이름(`display_name`), 상태, 마지막 동기화 시각이다.
   - 버튼 세 개:
     - **Notion 연결:** 1-1의 API로 주소를 받아 `ASWebAuthenticationSession`(callback scheme `taskforce`)으로 연다.
     - **지금 동기화:** `POST /api/v1/connections/sync`를 부른다. 429면 "방금 동기화했어요. 1분 뒤에 다시 해 주세요"를 보여준다.
     - **연결 끊기:** `DELETE /api/v1/connections/:id`를 부른다.
2. **돌아온 뒤 보여줄 말 (쉬운 말).** 앱이 `?handoff=<id>`로 돌아오면 `POST /api/v1/connections/notion/complete {handoff}`를 불러 아래 `status`를 받는다. 권한 화면 단계에서 실패하면 `complete`를 부르지 않고 곧바로 `?status=denied|error|invalid_state`로 돌아온다.

   | status | 언제 | 문구 |
   |---|---|---|
   | `connected` | `complete` 응답 | Notion을 연결했어요. 최근 2주의 회의록을 가져오는 중이에요. |
   | `connected_empty` | `complete` 응답 | Notion에서 고른 페이지가 없어요. 회의록 데이터베이스를 골라 다시 연결해 주세요. |
   | `connected_no_meetings` | `complete` 응답 | 회의록 데이터베이스가 빠져 있어요. 다시 연결할 때 함께 골라 주세요. |
   | `denied` | 돌아온 URL의 `status` | 연결을 취소했어요. |
   | `error`, `invalid_state` | 돌아온 URL의 `status`, 또는 `complete`의 404/409/502 | 연결하지 못했어요. 다시 시도해 주세요. |

3. **연결이 끊긴 데이터베이스 경고:** `settings.health.unreachable`이 있으면 "전에 읽던 데이터베이스를 더 이상 읽을 수 없어요. 다시 연결할 때 체크해 주세요"를 띄운다. 다시 연결할 때 선택이 빠지면 원문이 조용히 끊기기 때문이다([INTEGRATIONS.md](INTEGRATIONS.md) Notion 절).
4. **"지금 할 일"의 빈 화면:**
   - 연결이 없을 때: "Notion을 연결하면 회의록에서 내가 약속한 일을 찾아 드려요." 문구와 **연결** 버튼을 보여준다.
   - 연결은 됐는데 아직 할 일이 없을 때: "회의록은 마지막으로 고친 뒤 30분이 지나면 가져와요."([ingest 규칙](INTEGRATIONS.md))
5. **연결 전 안내 한 줄:** "회의록 데이터베이스를 직접 골라 주세요. 링크된 보기가 아니라 원본을 골라야 해요." Notion 권한 화면에서 가장 많이 틀리는 두 가지다([INTEGRATIONS.md](INTEGRATIONS.md) Notion 절).
6. 데이터베이스별 "가져오지 않음" 설정(`GET/PUT /api/v1/connections/:id/data-sources`)을 앱에 옮기는 일은 go live 뒤로 미룬다.

### 측정 (원칙 6)

- 설치에서 첫 결과까지의 흐름(연결 완료 → 첫 Action 생성)을 보려면 연결 완료를 이벤트로 남겨야 한다. 예: `metric_events`에 `connection_created`를 추가한다. 필수는 아니지만, 베타에서 이탈이 어디서 생기는지 볼 수 있다.

### 확인 방법

- 단위 테스트:
  - 서명된 `state`: 정상, 서명 변조, 만료, 재사용, 다른 사용자 id의 경우를 각각 확인한다.
  - callback: 쿠키 흐름(웹)과 서명 흐름(앱)을 모두 확인한다.
- 실제 기기: TestFlight 빌드로 연결 → 앱으로 돌아옴 → 연결 목록에 보임 → 동기화 → "지금 할 일"에 Action이 생기는지 확인한다. 이어서 연결을 끊으면 목록에서 사라지는지 확인한다.
- `/lab`의 기존 웹 연결도 그대로 되는지 확인한다.

---

## 2. 서버 배포

지금 앱의 `API_BASE_URL`은 `http://localhost:3000`이다(`apple/Config/Secrets.xcconfig`). 외부 테스터를 받으려면 다음이 필요하다.

- Vercel에 서버를 배포한다. 리전은 `vercel.json`에 `syd1`로 이미 지정되어 있어 Supabase(ap-southeast-2)와 같다. 도메인 예: `api.taskforcelabs.dev`.
- `.env.example`의 서버 환경변수를 모두 Vercel에 넣는다. 특히 `SUPABASE_SERVICE_ROLE_KEY`, `CONNECTOR_TOKEN_KEY`, `CRON_SECRET`, `NOTION_*`, `APNS_*`, `OAUTH_STATE_SECRET`가 필요하다 (`OAUTH_STATE_SECRET`이 없거나 32자보다 짧으면 앱 연결이 실패한다, `src/lib/env.ts`).
- Notion 연결 설정에 운영 callback 주소를 Redirect URI로 등록하고, `NOTION_REDIRECT_URI`도 같게 맞춘다.
- Supabase Auth의 Site URL과 Redirect URLs를 운영 주소로 바꾼다.
- 릴리스 빌드의 `API_BASE_URL`을 운영 주소로 바꾼다.
- 배포 뒤 테스트 계정으로 **계정 삭제**(`DELETE /api/v1/account`)를 한 번 실행해 본다. 실제 Supabase에서는 아직 확인하지 않았다.

## 3. 자동 동기화 주기

- `vercel.json`은 `/api/cron/sync`를 15분마다, `/api/cron/reminders`를 하루 1회 부른다.
- Vercel 계정(songch9511s-projects)이 **Pro 요금제라 설정 그대로 15분 주기로 돈다**(2026-09-27 사용자 확인). Hobby의 "cron 하루 1회" 제한은 해당하지 않는다.
- 남은 확인은 두 가지다.
  - 배포한 프로젝트가 Pro 팀(songch9511s-projects) 아래에 있는지 확인한다. 개인 Hobby 범위에 만들면 제한이 다시 걸린다.
  - 배포 뒤 Vercel의 Cron Jobs 기록에서 `/api/cron/sync`가 15분마다 성공하는지 확인한다. `CRON_SECRET`이 빠지면 401로 실패한다.

## 4. 문서와 문구 정리 (코드 아님)

- [PRD.md](PRD.md) 3장 MVP의 원문 입력을 1단계 연동(Notion · Google · Slack, 앱에서 연결)으로 고쳤다 (2026-09-27).
- [VIBE_CODING_PLAN.md](VIBE_CODING_PLAN.md)의 Phase A2(원문 입력)도 1장의 "앱에서 Notion 연결"로 바꾸거나, 보류로 표시한다.
- 스토어 설명과 TestFlight의 "테스트할 내용"에서 공유 시트 문장을 1단계 연동(Notion · Google · Slack) 기준으로 바꾼다.
- 연동이 늘 때마다 개인정보 처리방침의 "수집하는 정보"와 "처리 위탁"을 함께 고친다.

## 5. Slack 연동 (go live 조건)

PRD 핵심 시나리오 2("월요일에 받아도 괜찮아요" → 기한 갱신)는 메시지에서 일어난다. 회의록만으로는 이 시나리오를 자동으로 증명할 수 없다.

구현 전에 정할 것:

- **읽는 범위:** 사용자가 속한 DM, 그룹 DM, 채널 중 어디까지 읽을지. 사용자 토큰의 `*:history` 범위를 쓴다.
- **원문 단위:** 메시지 한 줄에는 맥락이 부족하다. 스레드 단위로 묶을지, 대화별로 일정 시간 단위로 묶을지 정한다. Notion의 "30분 안정화"처럼 대화가 멈춘 뒤에 넣는 규칙도 정한다.
- **관련자:** Slack 사용자 id를 이름으로 바꿔 `participants`에 넣는다. 화자를 알 수 있어서, Notion 전사로는 풀 수 없던 담당 판정이 쉬워진다.
- **배포:** 다른 워크스페이스에 설치하려면 Slack 앱의 공개 배포를 켜야 한다. 워크스페이스 관리자의 승인이 필요할 수 있다.
- **개인정보:** Slack 원문에는 다른 사람의 메시지가 들어 있다. 처리방침에 Slack을 추가하고, 테스터에게 무엇을 읽는지 연결 화면에서 먼저 알린다.
- **조회 속도 제한:** Slack은 2025년부터 Marketplace에 올리지 않은 채 배포하는 앱의 `conversations.history` · `replies` 호출을 크게 제한한다(분당 1회 수준). 베타 규모에서 동기화가 버티는지, Marketplace 등록이 필요한지 구현 전에 최신 문서로 확인한다.

## 6. Google 연동 (go live 조건)

Calendar · Meet 전사는 `google` 연결, Gmail은 `gmail` 연결로 **따로** 받는다(Gmail은 제한 범위라 Google 프로젝트를 나눈다, [google-verification.md](go-live/google-verification.md) 1장). 연결 화면에서는 무엇을 읽는지 연결마다 먼저 보여 준다.

| 서비스 | 가져올 것 | 쓰임 |
|---|---|---|
| Calendar | 내 일정의 제목 · 시각 · 참석자 | 원문이 아니라 **같은 회의를 잇는 열쇠**. Notion 회의록 · Meet 전사에 참석자를 붙여 담당 판정을 돕는다 |
| Gmail | 내가 보내거나 받은 메일 (한 통이 원문 하나) | 외부와의 약속 · 기한 변경. 뉴스레터 · 알림 메일은 거른다 |
| Meet 전사 | 발화자 이름이 있는 전사 | Notion 회의록에 없는 "누가 말했나"로 담당을 정한다 ([INTEGRATIONS.md](INTEGRATIONS.md) Notion 절) |

**go live 일정을 가장 크게 좌우하는 것은 Google 심사다. 코드보다 먼저 시작한다.**

- Gmail 읽기(`gmail.readonly`)는 **제한 범위**다. 정식 공개하려면 Google 심사와 매년 외부 보안 평가(CASA)가 필요하다.
- 심사 없이 "테스트" 상태로 두면 테스트 사용자를 100명까지 한 명씩 등록해야 한다. 그리고 **테스트 상태의 외부 앱은 갱신 토큰이 7일 뒤 만료된다.** 테스터가 매주 다시 연결해야 한다는 뜻이다. 구현 전에 최신 정책을 확인하고, 베타를 어느 방식으로 열지 정한다.
  - 테스트 상태로 연다: 7일마다 재연결 안내가 필요하다. 연결 화면과 알림에 넣는다.
  - 심사를 받는다: 몇 주가 걸린다. go live 날짜가 여기에 묶인다.
- Meet 전사의 API · 범위(Meet REST API의 전사 항목, 또는 Drive에 저장되는 전사 문서)와 심사 등급도 구현 전에 확인한다.
- 처리방침에 Google 사용자 데이터 정책(Limited Use) 문구를 넣어야 심사를 통과한다.

## 7. 보류: 공유 시트 · 붙여넣기

- go live 조건이 아니다. 자동 연동이 기본이다.
- 유일하게 자동으로 받을 수 없는 채널이 카카오톡이다. 공유 시트를 다시 검토할 때는 다음 두 가지를 본다.
  - 주간 질문 "Taskforce 밖에 따로 적어둔 할 일이 있나요?"의 '예' 비율(지표 5)이 높게 유지되는가.
  - 테스터 인터뷰에서 놓친 약속이 주로 카카오톡에서 나왔는가.
- 둘 다 그렇다면 공유 시트를 카카오톡 전용 보조 입구로 추가한다. 이때도 메인 흐름은 자동 연동이다.

## 8. 2단계 연동 자리와 "원해요"

- 연결 화면에 2단계 연동(Microsoft 365 · Zoom · GitHub · Linear · Jira)을 로고로 보여 주고, 연결 버튼 대신 "원해요"를 둔다.
- 누르면 `connection_requests` 표에 남긴다(`POST /api/v1/connection-requests`, 사용자 · 서비스마다 한 행). 한 사람이 같은 서비스를 여러 번 눌러도 한 번으로 센다.
- `/admin/metrics`에 서비스별 요청 수를 보이고, 2단계 연동은 이 순서대로 붙인다.
- 원해요를 누른 사람에게 따로 연락하지 않는다(처리방침에 없는 연락이다). 연동이 붙으면 앱 안에서 알린다.

## 9. go live 준비 문서 (2026-09-27)

이 문서의 할 일을 실제로 하는 방법과 값은 아래에 있다. 무엇이 남았는지는 런북의 **GO LIVE 체크리스트**(담당: 사용자 / 코드, 끝난 기준, 먼저 필요한 것)를 기준으로 본다.

| 문서 | 내용 |
|---|---|
| [go-live/runbook.md](go-live/runbook.md) | 서버 배포(Vercel Pro · `api.taskforcelabs.dev`), 환경변수 전체, 서비스별 redirect 주소, Supabase Auth · 마이그레이션, cron · 웹사이트 배포, **GO LIVE 체크리스트** |
| [go-live/google-verification.md](go-live/google-verification.md) | Google 프로젝트 둘(Calendar · Meet 정식 / Gmail 테스트 → 제한 심사 + CASA), 동의 화면 값, 범위별 필요성 문안, 시연 영상 대본, 심사 fixture, CASA 준비 |
| [go-live/slack-app.md](go-live/slack-app.md) | Slack 앱 매니페스트(사용자 토큰 + Events API), 권한을 고른 이유, 공개 배포, 2025-05 속도 제한, Slack 약관 · 보관 검토 |
| [go-live/slack-integration.md](go-live/slack-integration.md) | Slack 연동 구현 계획(C5): 정할 것 D1~D6, 이벤트 받기 · 묶기 · 넣기, 새 표, 골든셋, PR 순서, 끝난 기준 |
| [go-live/google-integration.md](go-live/google-integration.md) | Google 연동 구현 계획(C4): 정할 것 G1~G13(Meet 전사 경로 · Calendar 잇기 · Gmail 거르기), OAuth · `reauth`, 골든셋, PR 순서, 끝난 기준 |
| [go-live/app-store.md](go-live/app-store.md) | TestFlight 외부 테스트 정보, 심사 메모와 데모 계정, 개인정보 라벨, 외부 AI 동의 화면(5.1.2(i)), 계정 삭제 · Sign in with Apple 토큰 폐기 |
| [legal/README.md](legal/README.md) | 처리방침 · 약관 원본과 게시 규칙, 구현 대조표, 결정할 것, 법률 검토 항목 |
| [legal/privacy.ko.md](legal/privacy.ko.md) · [privacy.en.md](legal/privacy.en.md) | 개인정보 처리방침 (1단계 연동 기준) |
| [legal/terms.ko.md](legal/terms.ko.md) · [terms.en.md](legal/terms.en.md) | 이용약관 (베타) |
| [legal/connector-addenda.md](legal/connector-addenda.md) | 2단계 연동을 붙일 때 처리방침에 넣을 절 |

## 10. 남은 일 (go live 조건 아님)

2026-09-29 피처맵 정리([FEATURE_MAP.md](FEATURE_MAP.md) 6장)에서 옮겼다. 문서에 있다고 적었지만 코드에는 아직 없는 것이다.

- **Jev 사전 필터**: 추출 전에 약속이 없는 조각을 건너뛴다. 지금은 원문을 모두 추출로 보내고, Slack도 1자부터 받는다(`minTextLength: 1`). Slack 비용 · 품질을 보고 정한다 ([ARCHITECTURE.md](ARCHITECTURE.md) 2장).
- **알림 확장**(Notification Service Extension): 로그인 세션으로 할 일 제목을 받아 잠금 화면 알림에 채운다. 지금은 서버의 짧은 영어 문구("Review" · "Due today" · "Due tomorrow")만 보인다 ([PLATFORMS.md](PLATFORMS.md) 3장).
- **iPhone AI에게 넘기기 · 할 일 상세(변경 이력)**: 넘기기는 Mac 런처에만 있다. 두 앱 모두 상세 화면 없이 근거 펼치기만 있다 ([PLATFORMS.md](PLATFORMS.md) 1장).
- **공유 확장 · 위젯** (Phase A2): 타깃이 없다. 세션은 App Group 공유 Keychain에 있어 붙이면 같은 세션을 읽는다 ([PRD.md](PRD.md) "이후").
- **이메일 6자리 코드 로그인**: 앱에는 Sign in with Apple과 심사 계정용 이메일 · 비밀번호만 있다 ([PLATFORMS.md](PLATFORMS.md) 4장).
