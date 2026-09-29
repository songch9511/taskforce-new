# Google OAuth 심사 준비

관련 문서: [go live](../GO_LIVE.md) 6장 · [런북](runbook.md) · [처리방침](../legal/privacy.en.md) · [법률 문서 README](../legal/README.md)

작성: 2026-09-27. 9/13에 만든 심사 묶음(`Side Kick worktrees/lean-mvp/Docs/google-oauth-review-2026-09-13/`)을 지금 제품 구조로 다시 썼다. 콘솔 설정 · 제출은 하지 않았다.

**9/13 묶음과 달라진 것.** 그 묶음은 이전 제품(로컬 Mac 앱이 Google을 직접 읽고, Codex로 OpenAI에 보내고, 서버는 토큰 교환만 하는 iad1 브로커, Gmail 중지) 기준이다. 지금 제품은 다르다.

| 항목 | 9/13 (이전 제품) | 지금 |
|---|---|---|
| Google 데이터를 읽는 곳 | Mac 앱 (로컬) | **서버** (Vercel `syd1`), 15분마다 동기화 |
| 저장 | Mac의 SQLCipher | **Supabase** (시드니, 백업 없음) |
| AI | Codex CLI → OpenAI | **OpenRouter** → ZDR 공급자, 학습 금지, 앱 안 동의 뒤 |
| 범위 | calendarlist · events · gmail (한 프로젝트) | 프로젝트 둘로 나눔 (아래) |
| 재사용하는 것 | 사업자 정보, 시연 영상 원칙, fixture 방식, CASA 문의 틀 | 그대로 가져와 고쳤다 |

---

## 1. 프로젝트 둘로 나눈다

| | A. **Taskforce** (정식) | B. **Taskforce Gmail beta** |
|---|---|---|
| 범위 | `openid` · `email` (비민감, 아래 결정) · `https://www.googleapis.com/auth/calendar.events.owned.readonly` (민감, 아래 결정) · `https://www.googleapis.com/auth/meetings.space.readonly` (민감) | `openid` · `email` (비민감) · `https://www.googleapis.com/auth/gmail.readonly` (**제한**) |
| 앱의 연결 | `google` (Calendar + Meet 전사) | `gmail` |
| 게시 상태 | In production + 브랜드 · 민감 범위 심사 | **Testing**으로 시작 → 제한 범위 심사 + CASA를 함께 진행 → 통과하면 In production |
| 심사 기간 (Google FAQ 추정치) | 브랜드 2~3 영업일, 민감 범위 10 영업일 | 제한 범위 약 6주 + CASA. 전체 2~3개월로 잡는다 |
| 베타 동안 이용자에게 | 경고 없이 연결 (심사 통과 뒤) | "확인되지 않은 앱" 경고 화면, 테스트 사용자 100명까지, **7일마다 다시 연결** |
| redirect URI | `https://api.taskforcelabs.dev/api/connectors/google/callback` | `https://api.taskforcelabs.dev/api/connectors/gmail/callback` |
| 서버 환경변수 | `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET` | `GMAIL_CLIENT_ID` · `GMAIL_CLIENT_SECRET` |

**왜 나누나.** 한 프로젝트에 제한 범위(Gmail)가 들어가면 그 프로젝트 전체가 제한 범위 심사와 CASA가 끝날 때까지 정식으로 열리지 않는다. Calendar · Meet은 민감 범위라 1~2주면 끝나므로 따로 연다. 두 프로젝트는 기능과 동의가 다르고 둘 다 심사를 받는다(심사를 피하려고 프로젝트를 늘리는 것이 아니다).

redirect 경로는 서버의 연결 틀(`src/lib/connectors/callback.ts`, `/api/connectors/{provider}/callback`)을 따른 것이다. Google 연동(트랙 2-3)이 다른 경로를 쓰면 이 표와 콘솔을 함께 고친다.

### 결정: `openid` · `email`을 넣을지

- **넣는 것을 권장한다.** 비민감이라 심사 부담이 없고, 두 가지에 쓴다: 연결 화면에 어느 Google 계정을 연결했는지 보여 주기(`connections.display_name`), 참석자 · 받는 사람 목록에서 이용자 본인을 이메일로 확실히 알아보기(`src/lib/pipeline/identity.ts`의 `isUser`).
- 빼면 Calendar 기본 캘린더 id로 이메일을 짐작해야 하고, Gmail은 `users.getProfile`로 받을 수 있다. 어느 쪽이든 앱에 쓰는 범위를 적은 그대로 콘솔에 등록한다.
- 참고: 테스트 상태의 7일 만료는 요청 범위가 이름 · 이메일 · 프로필뿐일 때만 예외다. B는 `gmail.readonly`가 있어 7일 만료가 적용된다.

### 결정: `calendar.events.readonly` 대신 `calendar.events.owned.readonly` (2026-09-27 확정)

- Google은 "필요한 가장 좁은 범위"를 요구하고, 심사에서 더 좁은 범위로 안 되는 이유를 묻는다.
- `calendar.events.owned.readonly`("See the events on Google calendars you own")는 이용자가 소유한 캘린더의 일정만 읽는다. 다른 사람이 보낸 초대도 이용자 기본 캘린더(소유)에 사본으로 들어오므로, **기본 캘린더만 쓴다면 이 범위로 충분할 가능성이 높다.**
- **범위는 `calendar.events.owned.readonly`로 확정했다.** 트랙 2-3 구현 때 초대받은 회의가 모두 보이는지로 다시 확인한다. 팀 공용 캘린더처럼 소유하지 않은 캘린더가 꼭 필요하다고 밝혀지면 그때 `events.readonly`로 바꾸고 이 절 · 아래 필요성 문안 · 처리방침 3장의 권한 이름을 함께 고친다.

### 결정: 옛 프로젝트

- 9/13 묶음의 프로젝트 `soy-audio-354406`(표시명 My First Project, 이전 제품의 웹 클라이언트, 테스트 사용자 2명)는 쓰지 않고 A · B를 새로 만든다. 옛 클라이언트의 callback(`https://www.taskforcelabs.dev/api/connections/callback`)은 이전 제품용이다.
- 이전 제품을 완전히 닫는 날 옛 클라이언트를 지운다. 그 전까지는 건드리지 않는다.
- 로컬 개발용은 A에 localhost redirect를 넣지 말고, 별도 **Taskforce dev** 프로젝트(Testing, 세 범위 모두, redirect `http://localhost:3000/api/connectors/{google,gmail}/callback`)를 둔다. Google은 개발 · 운영 프로젝트를 나누라고 권한다.

---

## 2. 둘 다 먼저 할 일

### 2-1. 웹사이트와 처리방침 게시

Google 브랜드 심사는 홈페이지가 떠 있어야 시작된다. 요구 사항(Google 인증 요구 사항 문서):

- 홈페이지가 **확인된 도메인**에 있고, 앱을 정확히 나타내며, 기능을 설명한다.
- 처리방침이 **홈페이지와 같은 도메인**에 있고, **홈페이지에서 링크**되며, 동의 화면에 넣은 주소와 **같은 주소**다.
- 처리방침이 Google 사용자 데이터를 어떻게 접근 · 사용 · 저장 · 공유하는지 밝힌다. Limited Use 문장 두 개는 `docs/legal/privacy.en.md` 15장에 있다.
- 앱 안에서도 눈에 띄게 알린다(아래 [2-4](#2-4-앱-안-공개)).

확인할 것: `https://taskforcelabs.dev`는 `https://www.taskforcelabs.dev/`로 308 리디렉트된다(2026-09-27 확인). **콘솔에는 `www`가 붙은 주소를 쓴다.**

| 항목 | 값 |
|---|---|
| 홈페이지 | `https://www.taskforcelabs.dev` |
| 처리방침 | `https://www.taskforcelabs.dev/en/privacy` |
| 이용약관 | `https://www.taskforcelabs.dev/en/terms` |

홈페이지 푸터의 Privacy 링크가 위 처리방침 주소를 가리키는지 확인한다. 홈페이지에 Limited Use 문장을 한 줄 더 두면 심사 문의가 줄어든다(계획 1-2).

### 2-2. Search Console 도메인 인증

`taskforcelabs.dev`의 DNS는 Vercel DNS(`ns1.vercel-dns.com`)다. **2026-09-28 끝남:** Workspace 가입 때 넣은 `google-site-verification` TXT로 `daniel@taskforcelabs.dev`가 Search Console 도메인 속성 소유자로 자동 확인됐다. 이 TXT를 지우면 확인이 풀린다. 아래는 다른 계정을 소유자로 더할 때의 순서다.

1. 두 프로젝트의 **Owner 또는 Editor인 Google 계정**으로 <https://search.google.com/search-console> 에 로그인한다.
2. 속성 추가 → **도메인** → `taskforcelabs.dev` → 표시되는 `google-site-verification=…` 값을 복사한다.
3. Vercel → 팀 songch9511s-projects → Domains → `taskforcelabs.dev` → DNS Records → Add: Type `TXT`, Name `@`(비움), Value 복사한 값.
4. 몇 분 뒤 Search Console에서 **확인**을 누른다. `dig +short taskforcelabs.dev TXT`로 값이 보이면 된다.
5. 콘솔의 Branding → Authorized domains에 `taskforcelabs.dev`를 넣는다(하위 도메인 `api.` · `www.` 포함).

### 2-3. 어느 Google 계정으로 만들까

**2026-09-28 결정 · 만듦:** taskforcelabs.dev Google Workspace **Business Standard**(Flexible 월간, 14일 체험으로 시작). 이전에 있던 MX(`smtp.google.com`)는 Vercel DNS 프리셋만 들어간 것이고 Workspace는 없었다(`privacy@`로 오는 메일이 반송되던 상태).
- 관리자 · 프로젝트 Owner: `daniel@taskforcelabs.dev`
- `privacy@taskforcelabs.dev`: Google **그룹**(라이선스 없음). 소유자 `daniel@`, 외부에서 게시 가능, 대화는 구성원만 보기, 초대된 사용자만 참여. 동의 화면 지원 이메일 · 개발자 연락처로 쓴다.
- `review@taskforcelabs.dev`: 아직 만들지 않음(두 번째 라이선스). C4가 끝나 영상 A를 찍기 전에 만든다(6장).
- DNS(Vercel): 루트 TXT `google-site-verification=…` · SPF `v=spf1 include:_spf.google.com ~all`, `google._domainkey` DKIM(2048). 관리 콘솔 DKIM 상태 "인증 중". DMARC는 아직 없음.
- Starter를 고르지 않은 이유: Meet 전사가 Business Standard 이상에만 있다(영상 A · `meetings.space.readonly`).

- 동의 화면의 **사용자 지원 이메일**은 로그인한 계정의 주소나 그 계정이 관리하는 Google 그룹만 고를 수 있다. `privacy@taskforcelabs.dev`를 지원 이메일로 쓰려면:
  - 권장: Google Workspace(taskforcelabs.dev) 계정으로 프로젝트를 만들고, 지원 이메일에 `privacy@taskforcelabs.dev`(그 계정 또는 그 계정이 관리하는 그룹)를 고른다.
  - 대안: `privacy@`를 Google 그룹으로 만들고 프로젝트 소유자를 그룹 관리자로 둔다.
- 개발자 연락처: `privacy@taskforcelabs.dev`. Google의 심사 메일이 여기로 온다. 받은편지함을 매일 본다.
- 두 번째 Owner로 개인 계정(`songch9511@gmail.com`)을 더해 둔다(계정 분실 대비). 두 계정 모두 2단계 인증.
- Search Console 인증은 이 Owner/Editor 중 하나로 한다.

### 2-4. 앱 안 공개

Google은 처리방침 외에 앱 안에서도 데이터 사용을 눈에 띄게 알리라고 한다. 연결 버튼을 누른 뒤, Google 권한 화면을 열기 **전에** 보여 준다(트랙 3-4). 화면 문구는 BRAND.md 규칙대로 짧은 영어다.

**Google (Calendar · Meet)**
```
Google
Calendar — event titles, times, attendees
Meet — transcripts of your meetings
Read-only. Sent to AI only after your consent. Never used for training.
[Continue]
```

**Gmail**
```
Gmail
Email you sent or received. Newsletters and promotions are skipped.
Read-only. Sent to AI only after your consent. Never used for training.
Beta: reconnect every 7 days.
[Continue]
```

AI 데이터 동의 화면(첫 연결 전 한 번)은 `docs/go-live/app-store.md` 5장과 같다.

### 2-5. 로고

- 앱 아이콘의 마크(검정 바탕 `#000000` 위 흰 두 획, BRAND.md)를 정사각형 PNG로 준비한다. 콘솔 안내: **120×120px 권장, 1MB 이하, PNG/JPG/BMP**. Google 로고를 흉내 내지 않는다.
- 로고를 올리면 브랜드 심사가 필요하다. 로고 없이 이름만으로도 심사는 가능하지만, 동의 화면의 신뢰도를 위해 올린다.
- 2026-09-29 올린 파일: `apple/Taskforce/Assets.xcassets/AppIcon.appiconset/icon-ios-1024.png`를 120×120으로 줄인 PNG(2.4KB, A · B 공통).

---

## 3. 동의 화면 값

| 필드 | A. Taskforce | B. Taskforce Gmail beta |
|---|---|---|
| App name | `Taskforce` | `Taskforce` |
| User support email | `privacy@taskforcelabs.dev` | `privacy@taskforcelabs.dev` |
| App logo | 마크 PNG (2-5) | 같은 파일 |
| Application home page | `https://www.taskforcelabs.dev` | 같음 |
| Privacy policy link | `https://www.taskforcelabs.dev/en/privacy` | 같음 |
| Terms of service link | `https://www.taskforcelabs.dev/en/terms` | 같음 |
| Authorized domains | `taskforcelabs.dev` | 같음 |
| Developer contact | `privacy@taskforcelabs.dev` | 같음 |
| Audience · User type | External | External |
| Publishing status | In production (심사 제출) | **Testing** → 심사 통과 뒤 In production |
| Test users | — | 베타 테스터의 Google 주소 (100명까지, 한 명씩) |
| OAuth client | Web application `Taskforce server` | Web application `Taskforce Gmail server` |
| Authorized JavaScript origins | 없음 (서버에서 교환) | 없음 |
| Authorized redirect URIs | `https://api.taskforcelabs.dev/api/connectors/google/callback` | `https://api.taskforcelabs.dev/api/connectors/gmail/callback` |
| Data access (scopes) | `openid`, `email`, `…/calendar.events.owned.readonly`, `…/meetings.space.readonly` | `openid`, `email`, `…/gmail.readonly` |

- 권한 요청 주소에는 `access_type=offline`(갱신 토큰), `prompt=consent`(재연결 때 갱신 토큰을 다시 받기), `include_granted_scopes=false`를 쓴다. B는 테스트 상태에서 7일마다 갱신 토큰이 만료되므로 `invalid_grant`를 받으면 연결 상태를 `reauth`로 바꾸고 앱이 재연결을 안내한다(마이그레이션 `20261003000000`의 `reauth` 상태).
- client secret · 토큰 · 인증 코드는 문서 · 영상 · 로그에 넣지 않는다. client ID는 공개 값이다.

---

## 4. 범위별 필요성 (콘솔에 붙여 넣을 영어 문안)

### 앱 설명 (A · B 공통, "App description" 칸)

```
Taskforce is an AI project manager for iPhone and Mac. It reads the meeting notes, messages, and email that a user connects, finds the work that the user personally committed to, and keeps that list up to date: when a later message changes a deadline, Taskforce updates the existing task instead of adding a duplicate. Every task shows the exact quote it came from. Taskforce only reads connected services; it never sends email or changes calendar events, meetings, or messages.

Data handling: Google data is read by the Taskforce server (Vercel, Sydney region) and stored in Taskforce's database (Supabase, Sydney region, no backups). Deleting the account deletes the data immediately and revokes Google tokens. To find tasks, source text is sent to third-party AI models through OpenRouter, only after the user gives explicit in-app consent, and only to providers with zero data retention. Google data is never used to train any AI model, never sold, and never used for advertising. Humans do not read Google data except with the user's explicit consent, for security, or to comply with law.
```

### A. `openid`, `email` (비민감)

```
Taskforce uses the account's email address for two user-facing purposes: (1) to show which Google account is connected on the Connections screen, and (2) to recognize the user among meeting attendees and email recipients, so that tasks the user committed to are separated from tasks that belong to other people.
```

### A. `https://www.googleapis.com/auth/calendar.events.owned.readonly` (민감)

```
Taskforce reads events on the user's calendars (title, start and end time, organizer, attendees, and the Google Meet conference ID) to connect all sources that belong to the same meeting. Meeting notes from other tools (for example Notion AI notes) often have no attendee list and no speakers, so Taskforce cannot tell whose task an action item is. By matching the calendar event at the same time, Taskforce attaches the attendees to the meeting note and to the Meet transcript, groups them under one meeting in the task's "Sources", and uses the attendee list to decide whether a task is the user's or someone else's. The user sees this in the app as the meeting title and time on each task's evidence and as correctly assigned tasks instead of a review request.

Events are read only; Taskforce never creates, edits, deletes, or responds to events. Event descriptions and attachments are not read.

Narrower scopes are insufficient: calendar.freebusy returns no titles or attendees, and calendar.calendarlist.readonly returns no events. We request calendar.events.owned.readonly, not the broader calendar.events.readonly, because all meetings the user attends, including invitations from others, appear on the user's own primary calendar.
```

### A. `https://www.googleapis.com/auth/meetings.space.readonly` (민감)

```
Taskforce reads Google Meet conference records and transcript entries (speaker name, spoken text, and time) for the user's meetings. The transcript is the only source that records who said "I'll send it by Friday", so Taskforce uses it to find commitments made by the user and to assign owners correctly. Each resulting task shows the transcript quote, including the speaker, as its evidence. Google keeps transcript entries available through the API for 30 days after a meeting, and Taskforce imports them within that window.

Narrower scopes are insufficient: meetings.space.created only covers meeting spaces created by Taskforce, and Taskforce does not create meetings. We intentionally do not request drive.readonly (a restricted scope) to download transcript documents; the Meet REST API transcript entries are sufficient.

Meeting data is read only; Taskforce never creates, joins, or changes meetings.
```

### B. `openid`, `email` (비민감)

A와 같은 문안을 쓰고 "meeting attendees and email recipients"를 "email senders and recipients"로 바꾼다.

### B. `https://www.googleapis.com/auth/gmail.readonly` (제한)

```
Taskforce reads email threads the user sent or received (subject, sender, recipients, CC, date, and body) to find commitments the user made or accepted by email, such as "I'll send the signed contract by Monday", and to apply later changes such as "Wednesday works too", which updates the due date of the existing task instead of creating a duplicate. Each task shows the email quote it came from and links to the original thread in Gmail.

The message body is required: commitments and deadline changes are written in the body, so metadata alone (gmail.metadata) cannot determine whether a message contains a task for the user. Taskforce needs no permission to send, modify, delete, or label email. Newsletters, promotions, and automated notifications (unsubscribe header or Promotions category) are filtered out and not stored. Spam, trash, and attachments are not read.

Data flow: the Taskforce server (Vercel, Sydney) reads Gmail through the Gmail API and stores the remaining threads in Taskforce's database (Supabase, Sydney, no backups). To find tasks, the text is sent to third-party AI models through OpenRouter, only after explicit in-app consent and only to zero-data-retention providers; it is never used to train any AI model. Deleting the account deletes all stored Gmail data immediately and revokes the Google token.
```

---

## 5. 시연 영상 대본

Google 요구 사항(제한 범위 심사 문서): OAuth 권한 화면을 **영어로**, 동의 화면에 **앱 이름**이 보이고, **브라우저 주소창에 OAuth client ID가 보이며**, **범위마다 그 범위로 되는 기능**을 보여 준다. A와 B는 영상을 따로 만든다.

녹화 원칙 (9/13 묶음에서 가져옴):
- 전용 심사 계정과 아래 가상 fixture만 쓴다. 개인 받은편지함 · 실제 할 일을 찍지 않는다.
- client secret, 토큰, 비밀번호 입력, 관계없는 탭을 찍지 않는다.
- 실제로 동작한 결과만 찍는다. 편집으로 실패를 가리거나 fixture 응답을 실제 Google 데이터처럼 보이지 않는다.
- macOS 언어와 Google 계정 언어를 영어로 둔다. 3~5분.
- YouTube에 **일부 공개(Unlisted)**로 올리고, 로그인하지 않은 브라우저에서 열리는지 확인한다.

**주소창에 client ID 보이기.** 앱의 연결은 `ASWebAuthenticationSession`으로 권한 화면을 연다. 이 창이 전체 주소를 보여 주지 않으면, 녹화는 Mac의 **기본 브라우저(Chrome)**에서 권한 화면을 여는 흐름으로 한다: 앱 → Connect → Chrome이 열리고 → 권한 → `taskforce://connections/google?handoff=<id>`로 앱이 다시 열리고, 앱이 곧바로 `POST /api/v1/connections/google/complete`를 불러 Connected가 된다(GO_LIVE.md 1장). Chrome에서 주소창을 눌러 전체 주소를 펼치고 `client_id=…apps.googleusercontent.com`이 읽히게 확대한다. 이 흐름이 앱에서 되는지 트랙 3-4 구현 때 확인한다(코드 확인 필요).

**앱에서 범위의 쓰임이 보여야 한다.** Calendar의 쓰임(같은 회의 잇기 · 참석자로 담당 판정)이 화면에 보이지 않으면 심사에서 "기능이 없다"고 본다. 할 일을 펼쳤을 때 근거 줄에 일정 제목 · 시각이 보이고, Sources에 회의록과 Meet 전사가 한 회의로 묶여야 한다(트랙 2-3 · 3-2 요구 사항).

### 영상 A: Calendar + Meet (프로젝트 A)

| 시각 | 화면 | 내레이션 (영어) |
|---|---|---|
| 0:00 | 웹사이트 홈 → 푸터 Privacy → 처리방침 15장 Limited Use 문장 | "This is Taskforce, an AI project manager for iPhone and Mac. Our privacy policy, linked from the homepage, includes the Google Limited Use commitments. This demo uses a dedicated review account with fictional data." |
| 0:20 | Google Cloud Console → Clients → `Taskforce server`의 client ID (secret 패널은 열지 않음) | "This is the OAuth client used by the Taskforce server. Note the client ID." |
| 0:35 | Taskforce Mac 앱(로그인됨). Notion은 이미 연결. Review 카드에 "Send revised proposal" (담당 확인 필요) | "Notion is already connected. This meeting note has an action item, but the note has no speakers, so Taskforce asks me to review who owns it." |
| 0:55 | Connections → Google → 읽는 것 세 줄 → Continue. (AI 동의는 이미 한 상태. 처음이면 동의 화면을 함께 찍는다) | "Before connecting, Taskforce shows exactly what it reads: calendar event titles, times and attendees, and Meet transcripts. It is read-only, and data is sent to AI only after my consent." |
| 1:10 | Chrome: 계정 선택 → 동의 화면. 앱 이름 "Taskforce", 범위 목록. 주소창 펼쳐 `client_id` 확대 | "Here is Google's consent screen in English. It shows the app name Taskforce, and the address bar contains the same client ID. Taskforce requests read-only access to calendar events and Meet meeting information." |
| 1:40 | Allow → 앱으로 돌아옴 → Google: Connected → Sync now | "I allow access and return to the app. Google is connected, and I start a sync." |
| 2:00 | Google Calendar(웹)에서 "Proposal review — Acme" 일정과 참석자 두 명 | "This calendar event is the meeting from the Notion note. It lists me and Jordan as attendees." |
| 2:15 | Taskforce: Review 카드가 사라지고 Now에 "Send revised proposal to Jordan" · 기한 Fri. 펼치면 근거 줄 "Sep 30 · Proposal review — Acme"와 Sources 2 | "Using the calendar event, Taskforce links the Notion note and the Meet transcript as the same meeting and uses the attendees to decide the owner. The task is now mine, with the meeting title and time on its evidence." |
| 2:45 | Meet 전사 문서(Drive)에서 "Alex: I'll send the revised proposal to Jordan by Friday." | "This is the Meet transcript of that meeting. The speaker is recorded." |
| 3:00 | Taskforce: Sources에서 Meet 전사 인용(발화자 포함) → Open으로 원본 | "The task shows this exact transcript line, with the speaker, as its evidence. This is the feature enabled by the Meet scope." |
| 3:25 | Account → AI data (동의 · 철회), Connections → Google → Disconnect 버튼 | "I can withdraw AI consent or disconnect Google at any time. Deleting my account deletes all data immediately and revokes the Google token." |
| 3:45 | 처리방침 페이지 | "Taskforce never creates or changes events or meetings, and Google data is never used to train AI models. Thank you." |

### 영상 B: Gmail (프로젝트 B)

| 시각 | 화면 | 내레이션 (영어) |
|---|---|---|
| 0:00 | 웹사이트 홈 → 처리방침 Gmail 절 · Limited Use | "This demo shows Taskforce's Gmail connection with a dedicated review account and fictional email." |
| 0:15 | Console → Clients → `Taskforce Gmail server` client ID | "This is the OAuth client for Gmail. Note the client ID." |
| 0:25 | Taskforce → Connections → Gmail → 안내 → Continue | "Taskforce shows that it reads email I sent or received, skips newsletters and promotions, and is read-only." |
| 0:40 | Chrome 동의 화면. 앱 이름, `gmail.readonly` 설명, 주소창 `client_id` 확대 | "Google's consent screen shows the app name Taskforce and requests read-only access to email. The address bar shows the same client ID." |
| 1:05 | Allow → 앱 → Connected → Sync now | "I allow access and start a sync." |
| 1:20 | Gmail(웹): fixture 1 "Could you send the signed contract by Monday?" 와 내 답장 "Sure, I'll send it by Monday." | "In this thread, Jordan asked for the signed contract and I replied that I'd send it by Monday." |
| 1:40 | Taskforce: Now에 "Send signed contract to Jordan" · Mon. 펼치면 인용 "Sure, I'll send it by Monday." → Open으로 Gmail 스레드 | "Taskforce found my commitment from the email body and shows the exact quote, linked to the original thread. Metadata alone could not tell that this email contains a task for me." |
| 2:10 | Gmail: fixture 5 "Wednesday works too." 도착 → Sync | "Now Jordan writes that Wednesday also works." |
| 2:25 | Taskforce: 같은 할 일의 기한이 Wed로 바뀜, Sources 2 (두 인용) | "Taskforce updates the due date of the existing task instead of creating a duplicate, and keeps both quotes as evidence." |
| 2:45 | Gmail: fixture 2(정보 전달) · 4(뉴스레터) → Taskforce에 할 일 없음 | "An informational email and a newsletter did not create tasks." |
| 3:00 | Account → AI data, Connections → Gmail → Disconnect, 처리방침 | "I can withdraw consent or disconnect at any time, and deleting my account deletes all Gmail data and revokes the token. Taskforce never sends, deletes, or changes email, and never uses Gmail data to train AI models." |

합격 확인 (녹화 뒤 체크):
- [ ] 영상의 client ID가 제출하는 프로젝트의 client ID와 같다.
- [ ] 동의 화면이 영어이고, 앱 이름과 요청 범위가 모두 보인다.
- [ ] 범위마다 그 범위로 되는 기능이 실제 결과로 보인다(Calendar: 같은 회의 잇기 · 담당, Meet: 발화자 인용, Gmail: 본문 인용 · 기한 갱신).
- [ ] AI 전송 안내와 동의가 처리방침 · 제출 문안과 같다.
- [ ] 비밀값 · 관계없는 개인정보가 없다.
- [ ] 로그인하지 않은 브라우저에서 영상이 열린다.

---

## 6. 심사 계정과 fixture

모두 **가상 데이터**다. 실제 사람 · 회사 이름을 쓰지 않는다.

### 계정

| 계정 | 쓰임 | 비고 |
|---|---|---|
| `review@taskforcelabs.dev` (Workspace) | 심사 · 시연의 "나" (Alex) | Meet 전사는 **Business Standard 이상** Workspace에서만 생긴다. taskforcelabs.dev Workspace는 Business Standard다(2-3). 비밀번호는 비밀번호 관리자에만 둔다 |
| `jordan.review@…` (두 번째 계정, 가상 인물 Jordan) | 회의 참석 · 메일 상대 | 다른 도메인이면 "외부와의 약속" 시나리오가 된다 |
| Taskforce 계정 (위 review 주소로 로그인) | 앱 | App Store 심사용 데모 계정과 같게 쓸 수 있다(`app-store.md`) |

Meet REST API의 회의 기록 목록은 **이용자가 주최한 회의**만 돌려준다(Meet 문서: "The list method only returns conferences where you're the meeting organizer"). 그래서 fixture 회의는 `review@` 계정이 주최한다. 참석만 한 회의의 전사를 가져올 수 있는지는 트랙 2-3에서 확인하고, 안 되면 처리방침 3장과 연결 안내에 "내가 주최한 회의"라고 적는다.

### Calendar

| 일정 | 시각 | 참석자 | 기대 |
|---|---|---|---|
| Proposal review — Acme | 녹화 전날 10:00–10:30, Google Meet | review@, jordan | Notion 회의록 · Meet 전사와 한 회의로 묶임 |
| Weekly sync (no notes) | 녹화 전날 15:00 | review@ | 회의록이 없으면 아무것도 만들지 않음 |

### Meet (Proposal review — Acme, 전사 켜고 녹음)

두 계정으로 실제로 말한다(3분 이내, 영어):
- Jordan: "Thanks for the draft. Could you revise the pricing section?"
- Alex: "Sure. I'll send the revised proposal to Jordan by Friday."
- Jordan: "Great. I'll book the follow-up call next week."  ← Jordan의 일. Taskforce가 내 일로 잡지 않아야 한다.

### Notion (review 워크스페이스)

- Meeting 데이터베이스에 "Proposal review — Acme" 페이지(같은 날짜). AI 요약의 액션 아이템: "Send revised proposal (Friday)", "Book follow-up call". 담당 · 참석자 속성 없음.

### Gmail (`review@` 받은편지함, 녹화 2주 안에 실제로 주고받는다)

| # | 보낸 사람 → 받는 사람 | 제목 · 본문 | 기대 |
|---|---|---|---|
| 1 | jordan → review, 이어서 review → jordan 답장 | "Signed contract" / "Could you send the signed contract by Monday?" → "Sure, I'll send it by Monday." | 내 할 일 생성, 기한 월 |
| 2 | jordan → review | "Office hours" / "Office hours are unchanged this week. No action needed." | 할 일 없음 |
| 3 | jordan → review, cc 다른 사람 | "Banner update" / "Sam, please update the banner. Alex is copied for awareness." | 내 할 일 아님 |
| 4 | 뉴스레터(수신 거부 머리글 있음) | "Weekly digest" | 저장하지 않음 |
| 5 | jordan → review (1의 스레드) | "Wednesday works too, no rush." | 1의 기한을 수요일로 갱신, 새 할 일 없음 |

### 정리

녹화 · 심사가 끝나면 fixture를 지우지 않고 둔다(재심사 · 매년 CASA 재평가 때 다시 쓴다). 실제 사용자 데이터와 섞이지 않게 review 계정은 다른 용도로 쓰지 않는다.

---

## 7. CASA (Gmail 제한 범위 보안 평가)

### 언제 · 누가 · 얼마나

- **필요한 이유:** 제한 범위 데이터를 서버에 저장하거나 서버를 거쳐 보내는 앱은 Google이 지정한 평가기관의 보안 평가를 받아야 한다(Gmail 범위 문서: "If you store restricted scope data on servers (or transmit), then you must go through a security assessment"). Taskforce는 서버에서 읽고 저장하므로 예외가 없다.
- **언제 시작:** 제한 범위 심사를 제출한 뒤 **Google이 평가를 요청하는 메일을 보내면** 시작한다. 그 전에 돈을 내지 않는다. 평가 수준은 개발자가 아니라 Google이 정한다.
- **수준:** App Defense Alliance의 CASA 기준. AL1(예전 Tier 2: 개발자가 스캔을 돌리고 평가기관이 검증) 또는 AL2(예전 Tier 3: 평가기관이 앱 · 배포 인프라 · 데이터 저장소를 직접 시험).
- **평가기관 (ADA 인증 기관, 2026-09-27 목록):** Bishop Fox, DEKRA, Netsentries, TAC Security (CASA). 목록: <https://www.appdefensealliance.org/certification/authorized-labs>
- **비용 (공개 자료, 견적으로 다시 확인):** TAC Security의 Tier 2 요금제는 앱당 연 $540~$1,800(재검증 횟수에 따라). 다른 기관은 Tier 2에 $3,000 이상이라는 사례가 있다. AL2(Tier 3)는 견적제이고 더 비싸다.
- **갱신:** 평가기관의 평가 확인서(LOA) 승인일부터 **12개월 안에** 다시 평가해야 한다. 매년 비용과 일정을 잡는다.
- **기간:** 스캔 · 수정 · 재검증에 보통 2~4주. 제한 범위 심사와 합쳐 2~3개월로 잡는다.

### 준비할 증거 (Next.js + Supabase + Vercel)

| 영역 | 지금 있는 것 | 준비할 것 |
|---|---|---|
| 구조 · 데이터 흐름 | `docs/PLATFORMS.md` 2장 구조도, `docs/INTEGRATIONS.md` 서버 연동 | Gmail → 서버(syd1) → Supabase(시드니) → OpenRouter(ZDR) 흐름도 한 장. 처리자 · 리전 · 저장 항목 표 |
| 인증 | `src/lib/auth.ts`(`getClaims`로 JWT 서명 확인), `src/lib/api/auth.ts`(Bearer · 쿠키) | 인증 흐름 설명, 세션 만료 설정값 |
| OAuth | `src/lib/connectors/oauth-state.ts`(HMAC 서명 state), `oauth_nonces`(한 번만 쓰는 nonce), callback의 timing-safe 비교, 테스트 | 변조 · 만료 · 재사용 테스트 결과 캡처 |
| 권한 분리 | 모든 표 RLS(`owner_*` 정책), `connection_secrets` · `oauth_nonces`는 정책 없음(service role만), `tests/db/` RLS 테스트 | RLS 테스트 실행 결과, service role 키가 서버 env에만 있다는 증거 |
| 암호화 | 전송 TLS(Vercel HTTPS), 토큰 AES-256-GCM(`src/lib/connectors/crypto.ts`, `CONNECTOR_TOKEN_KEY`), Supabase 저장 시 암호화 | **키 교체 절차** 문서(암호문의 `v1` 접두사로 새 키 버전 추가 → 재암호화 → 옛 키 폐기) |
| 비밀값 | `.env.local` 커밋 안 함, Vercel env | Vercel env를 Sensitive로 표시, 접근자 목록 |
| 입력 검증 | `src/lib/api/contract.ts` zod, 원문 한도(20만 자 · 제목 200자 · 관련자 200명) | — |
| 속도 제한 | `src/lib/api/rate-limit.ts`, `missing_reports`(누락 신고) · `rate_limit_events` + `take_rate_limit`(물어보기 · 연결 시작, 마이그레이션 20261005000000) | — |
| 로그 | 원문 · 토큰을 남기지 않는 규칙, Vercel 1일 보관, 로그 드레인 없음 | 로그 샘플(가린 것)로 증명 |
| 보안 헤더 | 없음 (`next.config.ts`가 비어 있다, 2026-09-27) | HSTS · CSP · X-Frame-Options · Referrer-Policy 추가 (코드) |
| 스캔 | 없음 | SAST(예: Semgrep), 의존성(`npm audit`, `osv-scanner`), DAST(OWASP ZAP으로 Preview 배포 인증 스캔). **평가기관이 받는 도구 · 형식을 먼저 묻는다** |
| 삭제 | 계정 삭제 cascade(`tests/db/account-deletion.test.ts`), 토큰 폐기(트랙 2-1) | 실제 Supabase에서 삭제 후 행 0건 확인 기록 |
| 운영자 접근 | 운영자 1인 | Vercel · Supabase · GitHub · Google · Apple 계정의 2단계 인증 화면, 원문 열람 기록 표 |
| 사고 대응 | 없음 | 1쪽 절차: 감지 → 동기화 중지(cron 끄기, 연결 `revoked`) → 토큰 폐기 · 키 교체 → 영향 범위 확인 → 72시간 안 통지(처리방침 9장) → 복구 확인 |
| 백업 · 복구 | 백업 없음(의도) | "백업 없음"이 삭제 약속 때문이라는 설명과 그에 따른 데이터 손실 수용 |

### 평가기관 문의 초안 (보내지 않음)

```
Subject: Taskforce — CASA scope and quotation request (Gmail restricted scope)

Hello,

We are preparing Taskforce, an AI project manager for iPhone and Mac, for Google's restricted-scope verification with https://www.googleapis.com/auth/gmail.readonly.

Architecture: a Next.js server on Vercel (Sydney region) reads Gmail through the Gmail API and stores filtered email threads in a Supabase Postgres database (Sydney region, row-level security, no backups). OAuth tokens are encrypted with AES-256-GCM. To find tasks, text is sent to third-party AI models through OpenRouter with zero-data-retention routing, after explicit in-app consent. The iOS/macOS apps read from the database under row-level security and write through the server API.

Once Google confirms the required assurance level, could you tell us:
- the scope of the assessment (server, database, apps, AI routing) and the evidence you need,
- which scanning tools and report formats you accept for AL1,
- lead time, price, and what annual revalidation costs.

We can provide a data-flow diagram and a dedicated review environment. This message does not authorize paid work.

Regards,
Cheonghyeok Song
태스크포스 (Taskforce) · Sole proprietorship, business registration number 687-30-01972
privacy@taskforcelabs.dev
```

---

## 8. 일정

D는 웹사이트 · 처리방침이 공개된 날이다.

| 시점 | A. Taskforce | B. Taskforce Gmail beta |
|---|---|---|
| D | Search Console 인증, 프로젝트 · 클라이언트 · 동의 화면 설정, 브랜드 심사 시작 | 프로젝트 · 클라이언트 설정, Testing, 테스트 사용자 등록 → **베타 테스터가 바로 연결 가능 (7일 재연결)** |
| D+3 영업일 | 브랜드 심사 끝 (추정 2~3 영업일). **실제: D 당일 자동 인증**(2026-09-29, 민감 범위 없이 제출) | — |
| 트랙 2-3 구현 뒤 | 영상 A 녹화 → 민감 범위 심사 제출 | 영상 B 녹화 → 제한 범위 심사 제출 |
| 제출 + 10 영업일 | 민감 범위 심사 끝 (추정) → In production | Google의 CASA 요청 메일 → 평가기관 계약 |
| 제출 + 6주~3개월 | — | 제한 범위 심사 · CASA 끝 → In production, 7일 재연결 끝 |
| 매년 | — | LOA 승인일 12개월 안에 CASA 재평가 |

- Google의 추정 기간은 보장이 아니고, 답을 늦게 하면 늘어난다(Google FAQ). 심사 메일에는 그날 답한다.
- go live가 A의 심사보다 먼저 오면, A도 Testing으로 열고 테스터를 테스트 사용자로 등록한다(이때는 A도 7일 만료가 걸린다). In production으로 두고 심사 전 상태로 열면 "확인되지 않은 앱" 경고와 신규 사용자 수 제한이 붙는다.
- **A는 2026-09-29부터 In production이다**(비민감 범위만, 브랜딩 인증). Calendar · Meet 범위를 Data access에 넣고 C4가 그 범위를 요청하기 시작하면, L4 통과 전까지 위 경고 · 제한이 붙는다. 그때 go live가 L4보다 먼저면 Audience의 "테스트로 돌아가기"로 A를 Testing으로 돌린다.

---

## 9. 사용자가 누르는 순서

코드로 대신할 수 없는 일이다. 각 단계의 "끝" 조건을 채우면 다음으로 간다.

1. ✅ (2026-09-29) **웹사이트 게시 승인** — 계획 1-2의 새 사이트를 배포한다. 끝: `https://www.taskforcelabs.dev/en/privacy`에 새 처리방침(Limited Use 두 문장 포함)이 보이고 홈 푸터에서 링크된다.
2. **Workspace 계정 정하기** — 프로젝트 Owner로 쓸 taskforcelabs.dev 계정을 정하고 2단계 인증을 켠다. `privacy@`를 그 계정의 주소나 관리 그룹으로 둔다. 끝: 그 계정으로 console.cloud.google.com에 로그인된다.
3. **Search Console** — 2-2 순서대로 TXT를 넣고 확인. 끝: Search Console에 `taskforcelabs.dev` 도메인 속성이 "확인됨".
4. ✅ (2026-09-29, `taskforce-510108`) **프로젝트 A 만들기** — console.cloud.google.com → 프로젝트 선택 → 새 프로젝트 → 이름 `Taskforce`. APIs & Services → Library에서 **Google Calendar API**, **Google Meet REST API**를 켠다.
5. ✅ (2026-09-29) **A 동의 화면** — Google Auth Platform → Branding: 3장 표의 값 입력 · 로고 업로드. Audience: External. Data access → Add or remove scopes: `openid`, `email`. **Calendar 범위(1장 결정)와 `meetings.space.readonly`는 13단계(L4) 직전에 넣는다.** 브랜드 심사는 범위 심사와 따로이고 먼저이며("You must have a published branding status before you can request verification for data access"), 민감 범위가 있으면 제출에 필요성 문안 · 영상이 필요하다. 끝: Branding에 경고 없음.
6. ✅ (2026-09-29) **A 클라이언트** — Clients → Create client → Web application → 이름 `Taskforce server` → redirect URI 추가 → 만들기. client ID · secret을 비밀번호 관리자에 적고 Vercel env `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET`에 넣는다(runbook).
7. ✅ (2026-09-29) **A 브랜드 심사** — Audience → **앱 게시**(In production) → Branding 오른쪽 위 ⓘ "인증 상태" 패널 → **브랜딩 확인**(자동 검사, 몇 분) → **브랜딩 게시**(인증 뒤 7일 안). 끝: 인증 센터에 "브랜딩이 인증되었으며 사용자에게 표시되고 있습니다".
8. ✅ (2026-09-29, `taskforce-gmail-beta`) **프로젝트 B 만들기** — 새 프로젝트 `Taskforce Gmail beta` → **Gmail API** 켜기 → Branding(같은 값) → Audience: External, **Testing 유지** → Data access: `openid`, `email`, `gmail.readonly` → Clients: `Taskforce Gmail server`, redirect URI → Vercel env `GMAIL_CLIENT_ID` · `GMAIL_CLIENT_SECRET`.
9. 진행 중 (2026-09-29 등록, 연결 확인은 C4 뒤) **B 테스트 사용자** — Audience → Test users → 베타 테스터의 Google 주소를 한 명씩 추가(100명까지). 테스터에게 "Gmail은 7일마다 다시 연결"을 미리 알린다. 끝: 테스트 사용자가 연결에 성공한다.
10. 만듦 (2026-09-29, `Taskforce dev` `studied-source-510109-i1` · `Taskforce dev Gmail` `taskforce-dev-gmail`, Testing 유지) **Taskforce dev 프로젝트 (선택)** — 로컬 개발용, Testing, localhost redirect. 값은 `.env.local`에만.
11. **fixture 만들기** — 6장 계정 · 일정 · Meet 녹음 · Notion 페이지 · 메일을 실제로 만든다.
12. **영상 A 녹화 · 업로드** — 5장 대본, Unlisted. 끝: 합격 확인 6개 체크.
13. **A 민감 범위 제출** — Verification Center → Submit for verification → 4장 문안 붙여 넣기, 영상 URL, 앱 설명. 끝: 제출 확인 메일.
14. **영상 B 녹화 · B 제한 범위 제출** — B를 In production으로 바꾸라는 안내가 나오면 그때 바꾼다(바꾸면 테스트 사용자 목록 없이 누구나 연결 시도 가능해지고, 심사 전이면 경고 화면이 뜬다. 제출 흐름의 안내를 따른다).
15. **CASA** — Google 메일이 오면 7장의 평가기관 두세 곳에 문의 초안을 보내 견적을 받고, 가장 싼 AL1 경로부터 계약 · 결제한다(결제는 사용자). 스캔 · 수정 · 재검증.
16. **심사 메일 대응** — `privacy@`에 오는 Google 메일에 그날 답한다. 추가 영상 · 문안 요청이 오면 이 문서를 고쳐서 보낸다.
17. **통과 뒤** — B In production → 앱의 "7일마다 다시 연결" 안내를 끈다(코드) → 처리방침 3장 Gmail 절의 테스트 상태 문장을 지운다.

---

## 출처

- OAuth 갱신 토큰 만료: <https://developers.google.com/identity/protocols/oauth2#expiration> — "A Google Cloud Platform project with an OAuth consent screen configured for an external user type and a publishing status of 'Testing' is issued a refresh token expiring in 7 days, unless the only OAuth scopes requested are a subset of name, email address, and user profile."
- 앱 대상(Testing · 100명 · 7일): <https://support.google.com/cloud/answer/15549945> — "Projects configured with a publishing status of Testing are limited to up to 100 test users listed in the OAuth consent screen." · "Authorizations by a test user will expire seven days from the time of consent."
- 심사 기간 FAQ(브랜드 2~3 영업일, 민감 10 영업일, 제한 6주): <https://support.google.com/cloud/answer/13463817>
- 인증 요구 사항(홈페이지 · 처리방침 · 도메인 · 앱 안 공개): <https://support.google.com/cloud/answer/13464321>
- 제한 범위 심사(영상 요구 사항, CASA, 12개월 재평가): <https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification>
- 보안 평가(CASA, AL1/AL2, 매년 재평가): <https://support.google.com/cloud/answer/13465431>
- Meet 전사(30일, 발화자): <https://developers.google.com/workspace/meet/api/guides/artifacts> — "Transcript entry data is available for 30 days after the conference ends."
- Meet 범위(`meetings.space.readonly` 민감, `drive.readonly` 제한): <https://developers.google.com/workspace/meet/api/guides/authenticate-authorize>
- Meet 회의 기록은 주최자 것만 목록: <https://developers.google.com/workspace/meet/api/guides/conferences>
- Gmail 범위(`gmail.readonly` 제한): <https://developers.google.com/workspace/gmail/api/auth/scopes>
- Calendar 범위: <https://developers.google.com/workspace/calendar/api/auth>
- Workspace 사용자 데이터 정책(2026-09-03 갱신): <https://developers.google.com/workspace/workspace-api-user-data-developer-policy>
- API 서비스 사용자 데이터 정책: <https://developers.google.com/terms/api-services-user-data-policy>
- Meet 전사를 쓸 수 있는 Workspace 요금제: <https://support.google.com/meet/answer/12849897>
- ADA 인증 평가기관: <https://www.appdefensealliance.org/certification/authorized-labs> · 수준: <https://appdefensealliance.dev/casa/casa-tiering>
- TAC Security CASA 요금(검색 결과 기준, 견적으로 확인): <https://tacsecurity.com/google-casa-cloud-application-security-assessment/>
