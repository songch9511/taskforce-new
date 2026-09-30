# App Store Connect · TestFlight 준비

관련 문서: [go live](../GO_LIVE.md) · [런북](runbook.md) · [처리방침](../legal/privacy.ko.md) · [브랜드](../BRAND.md) · [플랫폼](../PLATFORMS.md)

작성: 2026-09-27. go live = TestFlight **공개 링크**를 여는 날이다. 외부 테스트는 첫 빌드마다 Apple의 베타 앱 심사를 받는다. 이 문서는 그 심사와 개인정보 라벨에 넣을 값, 그리고 심사 전에 앱이 갖춰야 할 것(동의 화면 · 계정 삭제)을 적는다.

| 항목 | 값 |
|---|---|
| 앱 이름 | Taskforce |
| 번들 ID | `dev.taskforcelabs.taskforce` (iOS · macOS 공통) |
| Team ID | `U9DWQKQFMW` |
| 카테고리 | Productivity |
| 처리방침 URL | `https://www.taskforcelabs.dev/en/privacy` (한국어 현지화: `/ko/privacy`) |
| 피드백 · 연락 이메일 | `privacy@taskforcelabs.dev` (문의 주소를 따로 만들면 바꾼다, `docs/legal/README.md` 결정 5) |

## 1. 심사 전에 앱이 갖출 것

| 요구 | 가이드라인 | 앱 상태 (2026-09-27) | 담당 |
|---|---|---|---|
| 외부 AI로 보내기 전 명시적 동의 | 5.1.2(i) | 서버 동의 API(`POST` · `DELETE /api/v1/consent`)와 앱 동의 화면(`apple/Taskforce/Shared/AccountViews.swift`) 작업 중 | 코드 (트랙 2-1 · 3-4). 문구를 5장과 맞춘다 |
| 동의 철회 방법 | 5.1.1(i) | 앱 계정 메뉴의 AI 동의 화면에서 철회 작업 중 | 코드 |
| 앱 안 계정 삭제 | 5.1.1(v) | 있음 (계정 메뉴 → 계정 삭제 → `DELETE /api/v1/account`) | — |
| 제3자 로그인(Google)을 두면 동등한 로그인 옵션 | 4.8 | Sign in with Apple이 먼저, 같은 크기 (2026-09-30 Sign in with Google 추가, PLATFORMS.md 4장) | — |
| 계정 삭제 때 Sign in with Apple 토큰 폐기 | 5.1.1(v), Apple 계정 삭제 안내 | 서버 구현됨. **앱이 authorization code를 아직 보내지 않는다** (6장) | 코드 (앱 한 단계) |
| 앱 안 처리방침 링크 | 5.1.1(i) | 없음 (2026-09-27 `apple/`에 링크 없음) | 코드 (계정 메뉴에 "Privacy Policy") |
| 심사원이 들어갈 수 있는 데모 계정 | 2.1 | Sign in with Apple만 있어 데모 계정으로 로그인할 수 없음 | **결정 + 코드** (3장) |
| 수출 규정 | — | HTTPS만 쓰면 면제 | `Info.plist`에 `ITSAppUsesNonExemptEncryption = NO` 확인 |

## 2. TestFlight 외부 테스트 정보

App Store Connect → 앱 → TestFlight → **Test Information** (현지화: English (U.S.), Korean).

### Beta App Description

BRAND.md 규칙: 핵심 메시지를 그대로 쓰고, App Store · TestFlight에서는 "Real AI Manager" 대신 **"AI 프로젝트 매니저"**를 쓴다.

한국어:
```
Taskforce는 AI 프로젝트 매니저로서 회의록·메시지·메일에서 내가 맡은 일을 찾아 알아서 정리하고 관리해주는 앱으로, 미팅이 많은 창업자와 컨설턴트가 직접 관리하지 않아도 약속한 일을 놓치지 않게 해 줍니다.

Notion · Google · Slack을 연결하면 새 회의록과 메시지, 메일을 읽고 내가 하겠다고 한 일만 골라 기한과 함께 목록에 넣습니다. 나중에 기한이 바뀌면 새로 만들지 않고 고치며, 모든 할 일에 원래 문장이 붙습니다. iPhone과 Mac에서 씁니다.
```

English:
```
Taskforce is an AI project manager that finds the work you committed to in your meeting notes, messages, and email, and organizes and tracks it for you, so founders and consultants in back-to-back meetings never miss what they promised without managing a list themselves.

Connect Notion, Google, and Slack. Taskforce reads new meeting notes, messages, and email, picks out only what you said you'd do, and adds it to your list with a due date. When a later message moves a deadline, it updates the task instead of adding a new one. Every task shows the line it came from. Works on iPhone and Mac.
```

1단계 연동 중 하나라도 go live 전에 빠지면 빠진 원문 종류를 문장에서 덜어낸다(BRAND.md).

### What to Test (빌드마다)

```
Please try:
1. Sign in with Apple, then enter your name and any nicknames people use for you.
2. Review the AI data screen and allow it, then connect Notion (pick your meeting-notes database itself, not a linked view), Google, and Slack.
3. Wait for your next meeting note or message. Tasks you committed to should appear under Now, each with the line it came from.
4. Check a task when it's done. Use Confirm or Dismiss on Review cards.
5. On Mac, press Option-Space to open the launcher.

Known limits in this beta:
- Gmail is invite-only while Google reviews it. Email your Google address to privacy@taskforcelabs.dev to be added, and reconnect Gmail every 7 days.
- Slack messages are read from the moment you connect; older messages are not imported.

Feedback: privacy@taskforcelabs.dev or the TestFlight screenshot feedback.
```

### 나머지 필드

| 필드 | 값 |
|---|---|
| Feedback Email | `privacy@taskforcelabs.dev` |
| Marketing URL | `https://www.taskforcelabs.dev` |
| Privacy Policy URL | `https://www.taskforcelabs.dev/en/privacy` |
| License Agreement | Apple 표준 EULA (이용약관은 앱 안 · 웹에 `https://www.taskforcelabs.dev/en/terms`) |
| 외부 그룹 | `Public beta` · 공개 링크 켬 |
| 테스터 수 한도 | 처음에는 100명으로 둔다. Gmail 테스트 사용자 한도(100명)와 맞춰, 초대한 사람이 모두 Gmail까지 연결할 수 있게 한다. 늘릴 때 Gmail은 "초대제"로 안내한다 |
| 빌드 유효기간 | 90일. 만료 전에 새 빌드를 올린다 |
| macOS | 같은 그룹에 macOS 빌드도 넣는다 (TestFlight for Mac) |

## 3. 심사원 정보와 데모 계정

### 결정: 데모 계정으로 어떻게 로그인하나 — 해결됨 (2026-09-27)

지금 앱은 Sign in with Apple만 있다. 심사원이 자기 Apple ID로 로그인하면 빈 계정이 되어 기능을 볼 수 없고, 이메일 6자리 코드는 심사원이 받을 수 없다.

검토했던 안:

| 안 | 방법 | 장단점 |
|---|---|---|
| **A (채택)** | 로그인 화면에 작은 "Sign in with email" → 이메일 + 비밀번호. **허용 목록(`review_accounts`)에 있는 주소만** 이메일로 가입할 수 있게 한다 | 만료 없는 계정. Apple 가입에는 영향을 주지 않는다(전체 이메일 가입을 막지 않아도 된다) |
| B | 심사원이 자기 Apple ID로 로그인 → 심사 메모의 절차대로 직접 Notion 등을 연결 | 코드 없음. 심사원이 연결할 계정이 없어 빈 화면 → 2.1(불완전한 앱) 거절 위험 |
| C | 심사 메모에 데모 Apple ID와 비밀번호 | Apple이 권하지 않는다. 2단계 인증 코드 문제 |

**구현 (A):** Supabase Auth의 **Before User Created** 훅으로 `public.hook_before_user_created`(마이그레이션 `20261007000000_review_account_signup_hook.sql`)를 켠다. 이 함수는 `provider = email`로 새로 가입하는 요청 중 `review_accounts` 표에 없는 주소를 403으로 거절한다. Apple 가입과 이미 있는 사용자는 그대로 통과한다. 대시보드 설정 · env는 `runbook.md` 4장.

데모 계정은 `scripts/create-review-account.ts`가 만든다: `REVIEW_ACCOUNT_EMAIL` · `REVIEW_ACCOUNT_PASSWORD`로 실행하면 (1) 그 주소를 `review_accounts`에 넣고, (2) 이메일 확인을 마친 사용자로 만들거나 비밀번호만 바꾸고, (3) 프로필 이름을 정하고 AI 처리에 동의한 상태로 두고, (4) "[Review] …" 합성 원문을 보통 파이프라인으로 처리해 근거가 붙은 할 일을 만든다(다시 실행해도 안전, `--reseed`로 다시 만들 수 있음).

데모 계정: `review@taskforcelabs.dev` / 비밀번호는 비밀번호 관리자에만 두고 App Store Connect 칸에만 넣는다. 이 계정은 Google 심사 계정과 같은 주소를 쓴다(`google-verification.md` 6장).

### 데모 계정 준비 (연결을 건너뛰어도 기능이 보이게)

심사원은 Notion · Google · Slack 계정이 없다. 그래서 **연결과 데이터가 이미 채워진 계정**을 준다.

1. 데모 계정으로 로그인 → 프로필 이름 `Alex Kim`, 별칭 `Alex` → AI data 동의.
2. 심사용 가상 워크스페이스를 연결해 둔다: Notion(review 워크스페이스, 회의록 DB), Google(프로젝트 A, `review@` 계정), Slack(review 워크스페이스). Gmail은 테스트 상태라 7일 뒤 만료되므로 연결하지 않거나, 심사 제출 직전에 연결한다.
3. fixture(가상 회의록 · 메시지 · 메일, `google-verification.md` 6장)가 동기화되어 Now에 할 일 3~5개, Review 카드 1장, 끝낸 할 일 1개가 있게 한다. 연동이 아직 붙지 않은 원문 종류는 `POST /api/v1/sources`로 같은 가상 원문을 넣어 채운다.
4. 심사 기간에는 데모 계정의 데이터를 지우거나 동기화를 끄지 않는다. 심사원이 계정을 지우면(계정 삭제 시험) 다시 만든다 → 제출 전에 재생성 절차를 한 번 연습한다.
5. 지표: 데모 계정의 이벤트는 지표에서 뺀다(지금 `[E2E 테스트]` 원문을 빼는 것과 같은 방식, 코드).

`scripts/create-review-account.ts`가 1 · 3(프로필 · AI 동의 · "[Review] …" 합성 원문 처리)을 대신한다. 2(Notion · Google · Slack 실제 연결)는 Google 심사 영상 · 실기기 확인에 필요해 수동으로 한다.

### Beta App Review Information

| 필드 | 값 |
|---|---|
| Contact | Cheonghyeok Song · `privacy@taskforcelabs.dev` · {{전화번호}} |
| Sign-in required | 예 |
| User name / Password | `review@taskforcelabs.dev` / {{비밀번호}} |

Review Notes (붙여 넣을 영어):
```
Taskforce finds the work a user committed to in their meeting notes, messages, and email from services they connect (Notion, Google, Slack), and keeps the list up to date.

Demo account: tap "Sign in with email" below the Sign in with Apple and Sign in with Google buttons and use the credentials above. The account is already connected to fictional review workspaces (Notion, Google Calendar/Meet, Slack) and contains sample tasks, so you do not need your own accounts. Everything in it is fictional.

Where to look:
- Now: tasks found from connected sources. Tap a task to see the exact quote it came from; the source link opens the original.
- Review card at the top: a task whose owner or due date is uncertain. Confirm or Dismiss.
- Account menu: Connections (connect/disconnect services), AI data (consent to sending source text to third-party AI and how to withdraw it), Privacy Policy, Sign out, Delete account.

Third-party AI (Guideline 5.1.2(i)): before the first connection, the app shows which data is sent (source text and the names of people in it), who receives it (OpenRouter and the AI model providers it routes to, all with zero data retention and no training), and asks for explicit consent. Without consent, the server does not process connected sources. Consent can be withdrawn in Account > AI data.

Account deletion (Guideline 5.1.1(v)): Account > Delete account deletes all data immediately (no backups) and revokes Sign in with Apple tokens, the Google sign-in grant (for accounts that signed in with Google), and connected-service tokens. If you delete the demo account, please let us know and we will recreate it.

A demo video of connecting each service: {{Unlisted YouTube URL}}
```

## 4. 개인정보 라벨 (App Privacy)

App Store Connect → 앱 → App Privacy. 모든 항목: **Linked to the user = Yes**, **Used for tracking = No**. 추적(ATT)은 하지 않는다. 광고 · 제3자 분석 SDK가 없다.

| Apple 데이터 유형 | 수집 | 목적 | 무엇인가 (처리방침 1장) |
|---|---|---|---|
| Contact Info → **Name** | 예 | App Functionality | 이용자가 입력한 표시 이름 · 별칭, Google로 로그인하면 Google 계정 이름(프로필 이름이 비어 있으면 처음 한 번 채운다) |
| Contact Info → **Email Address** | 예 | App Functionality | 로그인 이메일(Apple 전달 주소 · Google 주소 포함), 프로필의 추가 이메일 |
| User Content → **Emails or Text Messages** | 예 | App Functionality | Gmail 메일, Slack 메시지 (제목 · 보낸 사람 · 받는 사람 · 본문) |
| User Content → **Other User Content** | 예 | App Functionality | Notion 회의록 · 문서 · 할 일 DB 항목, Meet 전사, 일정 제목 · 참석자, 할 일 · 근거 인용, 주간 질문 응답 |
| Identifiers → **User ID** | 예 | App Functionality | 계정 id, Apple · Google 사용자 식별자, 연결한 서비스의 워크스페이스 · 계정 id |
| Usage Data → **Product Interaction** | 예 | Analytics, App Functionality | 앱 열기, 착수 · 완료 · 수정 · 삭제 · 확인, "Hand off to AI" 사용 |
| Identifiers → Device ID | 아니오 (판단) | — | APNs 기기 토큰은 앱 설치마다 다른 알림 전달용 값이라 Apple 정의("advertising identifier, or other device-level ID")에 해당하지 않는다고 본다. 보수적으로 가려면 "예 · App Functionality" |
| Diagnostics | 아니오 | — | 충돌 · 성능 수집 SDK가 없다. 서버 요청 기록은 1일 보관하고 콘텐츠를 담지 않는다 |
| Contacts | 아니오 | — | 주소록을 읽지 않는다. 원문 속 사람 이름은 User Content에 포함 |
| Search History | 아니오 | — | 런처 검색은 기기 안에서 거른다. 물어보기 질문은 서버가 처리만 하고 저장하지 않는다(속도 제한만 `rate_limit_events`에 시각으로 남음, 질문 · 답 내용은 없음) |
| Photos or Videos | 아니오 (판단) | — | Google로 로그인하면 Supabase가 계정 정보에 Google 프로필 사진 **주소**(`picture` · `avatar_url`)를 함께 저장한다. 앱은 쓰지 않고 사진 자체를 받지 않는다. 처리방침에 적을지는 처리방침 쪽에서 정한다 |
| Location · Health · Financial · Sensitive Info · Browsing History · Purchases · Other Data | 아니오 | — | 수집하지 않는다 |

- 처리방침이 바뀌어 수집 항목이 늘면 이 표도 함께 고친다. 새 SDK를 넣기 전에 라벨과 처리방침을 먼저 본다.
- "Emails or Text Messages"와 "Other User Content"를 수집한다고 답하면 앱 페이지에 "Data Linked to You"로 보인다. 제품 성격상 숨길 수 없고 숨기면 안 된다.

## 5. 외부 AI 동의 화면 (5.1.2(i))

2025-11 개정 가이드라인 5.1.2(i): "You must clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission before doing so."

### 언제 · 어떻게

- **첫 연결 전에 한 번.** 연결 화면에서 어느 서비스든 Connect를 누르면, AI 동의가 없을 때 이 화면이 먼저 뜬다. 서버도 동의가 없으면 연결 시작 · 동기화 · 원문 보내기 · 물어보기에 `409 conflict`("외부 AI 처리 동의가 필요해요")를 돌려준다(`src/lib/api/consent.ts`). 앱은 이 응답을 받으면 이 화면을 띄운다.
- **Allow를 눌러야만** `POST /api/v1/consent {"ai_processing": true}`. 미리 체크된 상자 · 스크롤만으로 동의 처리를 하지 않는다.
- **Not now**면 연결을 시작하지 않고 연결 화면으로 돌아간다. 앱의 다른 기능(이미 있는 할 일 보기)은 막지 않는다.
- **철회:** 계정 메뉴 → AI data → Withdraw → `DELETE /api/v1/consent`. 철회 뒤에는 새 원문을 처리하지 않는다는 한 줄을 보여 준다.
- 동의한 시각은 `profiles.ai_consent_at`에 남는다. 문안을 바꾸면(받는 곳이 늘어나는 등) 다시 동의를 받는다 → 문안 버전을 함께 남길지 트랙 2-1에서 정한다.

### 문안

화면 틀은 BRAND.md 규칙대로 짧은 영어로 쓴다. 이 화면은 법적 고지라 설명 문장이 필요한 예외다. 받는 곳은 처리방침 7장 표와 **같은 이름**을 쓴다(모델 공급자 목록을 고정한 뒤 채운다).

```
AI data

To find your tasks, Taskforce sends text from the services you connect to third-party AI models.

What's sent
Meeting notes, messages, email, and calendar details you connect, including the names and email addresses of people in them. Your name and nicknames, so the AI can recognize you.

Who receives it
OpenRouter (USA), which routes each request to an AI model provider: {{공급자 목록}}.

How it's protected
Only providers that keep no data. Never used to train AI models. Stored on our servers in Sydney. Delete your account to delete it all.

You can withdraw anytime in Account > AI data. Without this, Taskforce can't create tasks from your connected services.

[Allow]   [Not now]
Privacy Policy
```

한국어 화면을 따로 둘지는 앱 전체의 현지화 결정을 따른다. 둔다면 처리방침 4장 문장을 줄여 쓴다.

## 6. 계정 삭제와 Sign in with Apple 토큰 폐기 (5.1.1(v))

### 지금 (2026-09-27 작업 중인 코드 기준)

- 앱: 계정 메뉴 → 계정 삭제 → 확인 → `DELETE /api/v1/account` → 서버가 폐기를 먼저 하고 `auth.admin.deleteUser` → 모든 사용자 표가 cascade로 지워진다(`tests/db/account-deletion.test.ts`).
- 연결 서비스 토큰 폐기: `src/lib/connectors/registry.ts`의 `revokeConnectorTokens`(Notion `POST /v1/oauth/revoke`). Google(`https://oauth2.googleapis.com/revoke`) · Slack(`auth.revoke`)은 각 연동을 붙일 때 `revokeToken`으로 더한다.
- **Sign in with Apple 토큰 폐기: 서버는 구현됨, 앱이 남았다.** `src/lib/apple/sign-in.ts`가 아래 4번을 그대로 한다. 하지만 앱의 `APIClient.deleteAccount()`가 본문 없이 부르므로 서버는 code를 받지 못해 폐기를 건너뛰고 로그에 "토큰 없음"만 남긴다. 폐기하지 않으면 이용자의 설정 → Apple ID → Sign in with Apple 목록에 Taskforce가 남는다.

### 명세 (남은 일은 1 · 3 · 6)

1. **키 발급 (사용자):** Apple Developer → Certificates, IDs & Profiles → Keys → + → 이름 `Taskforce SIWA` → **Sign in with Apple** 체크 → Configure → Primary App ID `dev.taskforcelabs.taskforce` → Register → `.p8` 내려받기(한 번만 받을 수 있다). `.env.example`은 APNs 키와 같은 키여도 된다고 적지만, 권한을 나눠 두려면 따로 만든다.
2. **환경변수 (서버 전용, `.env.example`에 있음):** `APPLE_TEAM_ID=U9DWQKQFMW`, `APPLE_KEY_ID=<키 ID>`, `APPLE_PRIVATE_KEY=<.p8 내용, 줄바꿈은 \n>`, `APPLE_CLIENT_ID`(비우면 `dev.taskforcelabs.taskforce`). 비워 두면 폐기를 건너뛰고 삭제는 그대로 한다.
3. **앱 (코드, 남음):** 계정 삭제 확인 화면에서 Sign in with Apple을 한 번 더 받아(`ASAuthorizationAppleIDProvider`, 범위 없음) 새 `authorizationCode`를 얻는다(5분 안에 한 번만 쓸 수 있다). `DELETE /api/v1/account` 본문 `{"apple_authorization_code": "…"}`로 보낸다(`contract.ts`의 `deleteAccountRequestSchema`). 이메일 · Google로 가입한 계정은 이 단계를 건너뛴다(2026-09-30부터 Apple 로그인이 붙은 계정만, `SignInMethods`).
   - **Google 로그인 계정 (2026-09-30):** Supabase는 Google 토큰을 갖고 있지 않아 서버가 폐기할 것이 없다. 앱이 삭제가 끝난 뒤 `GIDSignIn.disconnect()`로 이 앱의 Google 권한을 폐기한다(기다리지 않고, 실패해도 삭제는 끝났다). 이 기기에 Google 토큰이 없으면 폐기하지 못한다(PLATFORMS.md 4장).
4. **서버 (구현됨):**
   - `client_secret`: ES256 JWT. 헤더 `kid=APPLE_KEY_ID`, 클레임 `iss=APPLE_TEAM_ID`, `iat=지금`, `exp=지금+5분`, `aud=https://appleid.apple.com`, `sub=APPLE_CLIENT_ID`.
   - `POST https://appleid.apple.com/auth/token` (`grant_type=authorization_code`, `code`, `client_id`, `client_secret`) → 토큰.
   - `POST https://appleid.apple.com/auth/revoke` (`client_id`, `client_secret`, `token`, `token_type_hint`) → 200.
   - 이어서 `revokeConnectorTokens` → `deleteUser`. 폐기가 실패해도 삭제는 진행한다(이용자의 삭제 요청이 우선). 로그에는 이유만 남기고 code · 토큰은 남기지 않는다.
5. **테스트:** 서버 쪽은 `src/lib/api/account.test.ts` 등. 앱 쪽은 code를 본문에 담는지 `APIClient` 테스트를 더한다.
6. **실기기 확인 (사용자):** TestFlight 빌드로 계정 삭제 → iPhone 설정 → Apple ID → 로그인 및 보안 → Sign in with Apple 목록에서 Taskforce가 사라지는지, Notion 설정 → 연결에서 Taskforce가 사라지는지 확인한다.

### 삭제 확인 화면 문구

```
Delete account

This deletes your tasks, sources, and connections right away. It can't be undone.
You'll confirm with Apple so we can remove Taskforce from your Apple ID.

[Delete account]   [Cancel]
```

## 7. 사용자가 누르는 순서

1. **데모 계정 만들기** — Supabase 대시보드 → Authentication → Hooks → **Before User Created** → Postgres function `public.hook_before_user_created` → Enable(runbook 4장). 그 뒤 `REVIEW_ACCOUNT_EMAIL=review@taskforcelabs.dev REVIEW_ACCOUNT_PASSWORD=… npx tsx --conditions react-server scripts/create-review-account.ts --yes`로 계정을 만든다(3장).
2. **SIWA 키 발급** — 6장 1번 → 비밀번호 관리자 → Vercel env 4개(runbook).
3. **앱 빌드 조건 확인** — 1장 표의 코드 항목이 모두 끝났는지. 특히 동의 화면 · 철회 · 앱 안 처리방침 링크 · SIWA 폐기 · 릴리스 `API_BASE_URL = https://api.taskforcelabs.dev`.
4. **데모 계정 채우기** — 3장 "데모 계정 준비" 1~5.
5. **App Privacy 입력** — 4장 표 그대로. Publish.
6. **빌드 업로드** — Xcode → Product → Archive(iOS · macOS 각각) → Distribute → App Store Connect.
7. **Test Information 입력** — 2장 값, 3장 Beta App Review Information.
7-1. **배포 국가** — App Store Connect → 앱 → Pricing and Availability → App Availability → **유럽경제지역(EU 27개국 · 아이슬란드 · 리히텐슈타인 · 노르웨이)과 영국을 뺀다**(처리방침 16장, `docs/legal/self-review.md` 5번). TestFlight 공개 링크는 이 설정과 상관없이 어디서나 열린다(Apple: TestFlight에는 국가 제한이 없다) — 그 지역에는 링크를 알리지 않는다.
8. **외부 그룹 · 제출** — TestFlight → External Testing → `Public beta` 그룹 → 빌드 추가 → Submit for Review. 끝: 심사 통과 메일.
9. **공개 링크** — 그룹 → Public Link → Enable, 테스터 한도 100. 이 링크가 웹사이트 CTA("Join the TestFlight beta")에 들어간다(BRAND.md). **서버 배포 · 1단계 연동이 끝나기 전에는 웹사이트에 걸지 않는다.**
10. **Gmail 초대 처리** — 테스터가 보낸 Google 주소를 프로젝트 B의 Test users에 넣는다(`google-verification.md` 9장 9번).

## 출처

- App Review Guidelines 5.1.1 · 5.1.2(i) · 4.8: <https://developer.apple.com/app-store/review/guidelines/>
- Sign in with Apple 토큰 폐기(REST API `revoke_tokens`): <https://developer.apple.com/documentation/sign_in_with_apple/revoke_tokens>
- App 개인정보 라벨 정의: <https://developer.apple.com/app-store/app-privacy-details/>
