# go live 런북

관련 문서: [go live](../GO_LIVE.md) · [Google 심사](google-verification.md) · [Slack 앱](slack-app.md) · [App Store](app-store.md) · [법률 문서](../legal/README.md) · [연동](../INTEGRATIONS.md) · [실행 계약](../EXECUTION.md)

작성: 2026-09-27. 서버 배포부터 TestFlight 공개 링크까지, 무엇을 어떤 순서로 하는지 적는다. **맨 아래 [GO LIVE 체크리스트](#go-live-체크리스트)가 기준표**이고, 위 장들은 그 항목의 자세한 방법이다.
"사용자"는 계정 · 결제 · 외부 공개처럼 코드로 대신할 수 없는 일, "코드"는 이 저장소의 변경으로 끝나는 일이다.

## 0. 대상 한눈에

| 항목 | 값 | 2026-09-27 상태 |
|---|---|---|
| 서버 | Vercel **Pro 팀 `songch9511s-projects`**, 새 프로젝트(예: `taskforce-api`), GitHub `songch9511/taskforce-new`의 `main` | 프로젝트 없음 (저장소에 `.vercel` 링크 없음) |
| 리전 | `syd1` (`vercel.json`) | 설정됨 |
| API 도메인 | `api.taskforcelabs.dev` | DNS는 Vercel을 가리키지만 붙은 프로젝트가 없어 404 |
| DB · 인증 | Supabase 프로젝트 `Taskforce-new` (ref `tirtdojsahotjfgdsryi`, Vercel 연동 조직), 시드니 `ap-southeast-2` | 운영 중. 마이그레이션 기록이 비어 있음(4장) |
| 웹사이트 | `www.taskforcelabs.dev` (apex는 www로 308), `Side Kick/apps/website`의 별도 Vercel 프로젝트 | 이전 제품(Side Kick, iad1 · Codex) 기준 내용 → 2026-09-29 새 사이트로 교체(7장) |
| DNS | Vercel DNS (`ns1/ns2.vercel-dns.com`), 메일 MX는 Google Workspace | TXT 없음(Search Console 미인증) |
| 앱 | `dev.taskforcelabs.taskforce`, Team `U9DWQKQFMW` | `API_BASE_URL`이 로컬 |

## 1. Vercel 프로젝트

1. vercel.com → 팀 전환기에서 **songch9511s-projects**(Pro)를 고른다. 개인 Hobby 범위에 만들면 cron이 하루 1회로 제한된다(GO_LIVE.md 3장).
2. Add New → Project → GitHub `songch9511/taskforce-new` Import. Framework: Next.js(자동), Root: 저장소 루트, Build: 기본(`next build`).
3. 2장의 환경변수를 **Production**에 넣는다(Preview에는 운영 비밀값을 넣지 않는다. 필요하면 별도 값). 비밀값은 모두 **Sensitive**로 표시한다.
4. Deploy. 끝나면 Settings → Functions에서 리전이 `syd1`인지, 배포 로그에 경고가 없는지 본다.
5. Settings → Domains → `api.taskforcelabs.dev` 추가. DNS가 Vercel이라 자동으로 붙는다. 끝: `curl -sI https://api.taskforcelabs.dev/api/v1/now`가 404가 아니라 401.
6. **Observability Plus · 로그 드레인을 켜지 않는다.** 켜면 로그 보관이 1일에서 30일로 늘거나 외부로 나가 처리방침 5장이 틀려진다.

## 2. 환경변수 전체

`.env.example`의 모든 값 + go live에 새로 생기는 값이다. 코드(트랙 2)가 정한 이름이 이 표와 다르면 **그 시점의 `.env.example`이 기준**이고, 이 표를 고친다. 값은 비밀번호 관리자에 먼저 적고 Vercel에 넣는다.

| 변수 | 값 · 만드는 법 | 비고 |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://tirtdojsahotjfgdsryi.supabase.co` | 경로 없이 (`src/lib/env.ts`가 검사) |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Supabase → Project Settings → API Keys → Publishable | 공개 값 |
| `SUPABASE_SERVICE_ROLE_KEY` | 같은 화면 → service_role (secret) | RLS 우회. **Sensitive**, `NEXT_PUBLIC_` 금지 |
| `OPENROUTER_API_KEY` | openrouter.ai → Keys. **운영용 키 `taskforce-prod`**(하루 한도 $5, 매일 UTC 0시에 풀림, 만료 2027-09-30)를 넣는다(Production · Preview). 로컬 · eval은 개발 키(OpenRouter 이름 "Default key", 누적 한도 $20)를 쓴다: eval 한 번이 약 $0.16이라 같은 키면 eval이 운영 한도를 쓴다(2026-09-30 한도 $10에 닿아 모든 호출 403) | 한도가 있으면 `max_tokens`를 꼭 보낸다(llm.ts 주석) |
| `LLM_MODEL` | `z-ai/glm-5.3-flash` (지금 `.env.local`, eval 기준) | 바꾸면 eval을 다시 돌린다. 추론하지 않는 모델이면 `LLM_OVERRUN_REASONING_EFFORT=off`도 같이 둔다 (아래) |
| `JEV_MODEL` | `typesafe/jev-1.13` | 버전 고정 |
| `EMBEDDING_MODEL` | 비움 → `openai/text-embedding-3-small` | 1536차원이어야 한다 |
| `LLM_PROVIDERS` · `EMBED_PROVIDERS` · `JEV_PROVIDERS` | 비움 (선택) → 기본값 `src/lib/ai/providers.ts`: LLM `fireworks,together,deepinfra` · 임베딩 `azure` · Jev `typesafe` | ZDR · 학습 금지 공급자 고정 목록(쉼표 구분). 처리방침 7장 표와 맞춘다(`docs/legal/README.md` 결정 1) |
| `LLM_OVERRUN_REASONING_EFFORT` | 비움 → `high` | 추출이 출력 · 시간 한도를 넘기면 다시 물을 때 거는 추론량 제한(`low` · `medium` · `high` · `off`). 사용자가 기다리는 빠진 할 일 신고 · 물어보기는 첫 호출부터 건다. `LLM_MODEL`을 바꾸면 eval로 다시 정한다 (`src/lib/ai/llm.ts` `OVERRUN_RETRY_REASONING`). 추론 옵션이 없는 모델로 바꾸면 `off`로 둔다: 빠진 할 일 신고 · 물어보기는 첫 호출부터 추론 옵션을 보내, `require_parameters` 때문에 받을 공급자가 없다는 404("No endpoints found that can handle the requested parameters")를 받는다. 그러면 호출마다 한 번 옵션 없이 다시 물어 늦어지고, 서버 로그에 "추론 옵션을 받는 공급자가 없어" 경고가 남는다 (배경 처리의 다시 묻기는 그대로 실패한다) |
| `CONNECTOR_TOKEN_KEY` | `openssl rand -base64 32` | **운영 DB에 이미 저장된 연결 토큰을 암호화한 키와 같아야 한다.** 로컬 `.env.local` 값으로 운영 DB에 연결을 만들었다면 같은 값을 넣고, 새 키를 쓰면 기존 연결은 다시 연결해야 한다 |
| `CRON_SECRET` | `openssl rand -hex 32` | Vercel Cron이 `Authorization: Bearer`로 보낸다. 없으면 cron이 401 |
| `OAUTH_STATE_SECRET` | `openssl rand -hex 32` | 32자 이상(`env.ts`의 `oauthStateSecret`) |
| `NOTION_CLIENT_ID` · `NOTION_CLIENT_SECRET` | notion.so/profile/integrations → Taskforce(Public) | |
| `NOTION_REDIRECT_URI` | `https://api.taskforcelabs.dev/api/connectors/notion/callback` | Notion 설정의 Redirect URI와 글자까지 같게 |
| `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET` | Google 프로젝트 A 클라이언트 (`google-verification.md` 9장 6번) | 새 값 |
| `GMAIL_CLIENT_ID` · `GMAIL_CLIENT_SECRET` | Google 프로젝트 B 클라이언트 (9장 8번) | 새 값 |
| `GMAIL_REDIRECT_URI` | `https://api.taskforcelabs.dev/api/connectors/gmail/callback` | 코드가 env로 받는다(`gmail/run.ts` `gmailOAuthConfig`. `GMAIL_CLIENT_ID` · `GMAIL_CLIENT_SECRET`과 함께 하나라도 없으면 연결 시작이 오류). 프로젝트 B 클라이언트의 Authorized redirect URI와 글자까지 같게 |
| `GMAIL_CONNECT_ENABLED` | `true` | 앱에 Gmail 연결을 연다(`lib/env.ts` `gmailConnectEnabled`). 처리방침 3장 Gmail 절의 재게시와 재연결 알림 · 앱의 Gmail 확인 창(google-integration.md PR 4a, #27)이 나간 뒤에 켠다 — 2026-09-30 처리방침 베타 1.1 게시(`docs/legal/README.md` 게시 기록), #27 배포 · 마이그레이션 `20261015000000` 적용 끝, 앱 코드는 main(첫 TestFlight 빌드에 들어감). 켜기 전에는 비워 둔다: 비우면 운영에서는 닫혀 있고 운영자(`ADMIN_EMAILS`)만 웹 /lab에서 연결해 시험할 수 있다 |
| `GOOGLE_REDIRECT_URI` | `https://api.taskforcelabs.dev/api/connectors/google/callback` | 코드가 env로 받는다(`google/run.ts` `googleOAuthConfig`. `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET`과 함께 하나라도 없으면 연결 시작이 오류). 프로젝트 A 클라이언트의 Authorized redirect URI와 글자까지 같게 |
| `GOOGLE_CONNECT_ENABLED` | 비움 (운영 기본은 닫힘) → 처리방침 3장 Google 절(PR 5b)과 앱 문구(google-integration.md PR 4)가 나간 뒤 `true` | 앱에 google(Calendar · Meet 전사) 연결을 연다(`lib/env.ts` `googleConnectEnabled`). 비우면 운영에서는 닫혀 있고 운영자(`ADMIN_EMAILS`)만 웹 /lab에서 연결해 시험할 수 있으며, 이미 있는 연결의 동기화 · 토큰 폐기는 닫혀 있어도 한다. **마이그레이션 `20261016000000_sources_meeting.sql`은 #30을 병합하기 직전에 운영 DB에 적용한다**(`db query --linked -f`, `db push` 금지, 사용자 승인 뒤. 결정 2026-09-30). 운영자 /lab 시험을 포함해 google 연결을 처음 만들기 전에는 반드시 적용돼 있어야 한다. 안 그러면 일정이 붙은 원문은 일정 없이(일정 연결을 잃고) 저장되고 로그에 "sources.meeting 열이 없어"가 남는다. 일정이 없는 원문은 영향 없음 |
| `SLACK_CLIENT_ID` · `SLACK_CLIENT_SECRET` · `SLACK_SIGNING_SECRET` | api.slack.com/apps → Taskforce → Basic Information (`slack-app.md` 9장 4번) | 새 값 |
| `SLACK_REDIRECT_URI` | `https://api.taskforcelabs.dev/api/connectors/slack/callback` | 연결(OAuth) callback. Slack 앱의 Redirect URL과 글자까지 같아야 한다 |
| `SLACK_APP_TOKEN` | App-Level Token `xapp-…` (`authorizations:read`) | 한 워크스페이스에 이용자가 둘 이상일 때(D4). 없으면 이벤트가 이름을 댄 이용자만 받는다 |
| `SLACK_CONNECT_ENABLED` | `true` | 앱에 Slack 연결을 연다. 처리방침 · 앱 문구(slack-integration.md PR 4)를 배포할 때 켠다. 그 전에는 비워 둔다 |
| `APPLE_TEAM_ID` | `U9DWQKQFMW` | Sign in with Apple 토큰 폐기 (`app-store.md` 6장) |
| `APPLE_KEY_ID` · `APPLE_PRIVATE_KEY` | Apple Developer → Keys → Sign in with Apple 키(.p8). 줄바꿈은 `\n` | APNs 키와 같은 키여도 되지만(`.env.example`) 따로 두기를 권장. 비우면 폐기를 건너뛰고 삭제는 계속 |
| `APPLE_CLIENT_ID` | 비움 → `dev.taskforcelabs.taskforce` | |
| `APNS_KEY_ID` · `APNS_PRIVATE_KEY` | Apple Developer → Keys → Apple Push Notifications service 키(.p8) | 없으면 알림이 꺼진 채 동작 |
| `APNS_TEAM_ID` | `U9DWQKQFMW` | |
| `APNS_BUNDLE_ID` | 비움 → `dev.taskforcelabs.taskforce` | TestFlight 빌드의 기기 토큰은 `production` 환경이다 |
| `ADMIN_EMAILS` | 운영자 이메일 (쉼표로 구분) | `/admin/metrics` 접근 |
| `WEEKLY_CHECK_ENABLED` | 비움 (켜짐) | 베타가 끝나면 `false` |
| `EXECUTION_ENABLED` | 비움 (꺼짐) → 9-6 순서의 3번에서 `true` | 실행(U2: run · 내장 초안)을 연다. `true`만 켠다. 켜도 DB의 차단 스위치 · 실행 주체 허용 목록이 따로 막는다(9장). 끄면 실행 route 404, sweep은 바로 끝난다 |

키를 새로 만들면 로컬 `.env.local`에도 개발용 값을 따로 둔다. 운영 비밀값을 로컬에 복사해 두지 않는다(`CONNECTOR_TOKEN_KEY` 예외는 위 비고).

## 3. 서비스별 redirect · 이벤트 주소

| 서비스 | 등록하는 곳 | 운영 주소 | 로컬 (개발용 앱 · 프로젝트에만) |
|---|---|---|---|
| Notion | notion.so/profile/integrations → Taskforce → Redirect URIs | `https://api.taskforcelabs.dev/api/connectors/notion/callback` | `http://localhost:3000/api/connectors/notion/callback` (이미 등록) |
| Google (Calendar · Meet) | 프로젝트 A → Clients → `Taskforce server` | `https://api.taskforcelabs.dev/api/connectors/google/callback` | Taskforce dev 프로젝트에 `http://localhost:3000/api/connectors/google/callback` |
| Gmail | 프로젝트 B → Clients → `Taskforce Gmail server` | `https://api.taskforcelabs.dev/api/connectors/gmail/callback` | Taskforce dev 프로젝트에 `…/gmail/callback` |
| Slack OAuth | Slack 앱 → OAuth & Permissions → Redirect URLs | `https://api.taskforcelabs.dev/api/connectors/slack/callback` | Taskforce dev 앱(터널 주소) |
| Slack 이벤트 | Slack 앱 → Event Subscriptions → Request URL | `https://api.taskforcelabs.dev/api/connectors/slack/events` | Taskforce dev 앱(터널 주소) |
| 앱 복귀 | 앱 `Info.plist` URL scheme | `taskforce://connections/{provider}?handoff=<id>` (앱이 받으면 `POST /api/v1/connections/{provider}/complete`로 마무리) | 같음 |
| Google 로그인 복귀 | 등록 없음 (프로젝트 A iOS 클라이언트가 정한다. 앱 `Info.plist`에 scheme) | `com.googleusercontent.apps.923900348266-iopmhbf1foor213n1jc3a8tv6v4fti82:/oauth2callback` (Google Sign-In SDK가 받는다) | 같음 |

Google · Slack 경로는 연결 틀(`src/lib/connectors/callback.ts`)의 `/api/connectors/{provider}/callback`을 따른 것이다. 트랙 2-3 · 2-4가 경로를 바꾸면 이 표 · 콘솔 · 매니페스트를 같이 고친다.

## 4. Supabase

### 마이그레이션 적용

운영 DB는 SQL Editor로 만들어 **마이그레이션 기록이 비어 있다.** `npx supabase db push`를 쓰면 첫 파일부터 다시 돌리려 한다. 새 파일만 하나씩 적용한다(운영 DB를 바꾸는 일이라 사용자가 승인한 뒤).

```bash
# 먼저 읽기로 상태 확인 (예: 새 테이블이 있는지)
npx supabase db query --linked "select to_regclass('public.oauth_handoffs'), to_regclass('public.rate_limit_events'), to_regclass('public.review_accounts')"
# 없으면 파일 순서대로 하나씩
npx supabase db query --linked -f supabase/migrations/20261003000000_go_live_connections_consent.sql
npx supabase db query --linked -f supabase/migrations/20261004000000_ask.sql
npx supabase db query --linked -f supabase/migrations/20261005000000_atomic_rate_limits.sql
npx supabase db query --linked -f supabase/migrations/20261006000000_source_text_retention.sql
npx supabase db query --linked -f supabase/migrations/20261007000000_review_account_signup_hook.sql
npx supabase db query --linked -f supabase/migrations/20261011000000_slack.sql   # Slack 표 · connected_at (2026-09-29 적용함). 이 파일을 쓰는 코드보다 먼저 적용한다
npx supabase db query --linked -f supabase/migrations/20261012000000_slack_tombstones_revoke.sql   # 지움 표시 · 앱 해제 함수 (2026-09-29 적용함)
npx supabase db query --linked -f supabase/migrations/20261013000000_slack_sync.sql   # Slack 원문 넣기 · 연결 끊기(D3) · 대기 데이터 정리 함수 (2026-09-29 적용함). 코드 배포 전에
npx supabase db query --linked -f supabase/migrations/20261014000000_connections_server_delete.sql   # 앱의 연결 직접 삭제 정책 지우기. 서버 권한 끊기 코드를 배포한 **뒤에** (2026-09-29 배포 뒤 적용함)
npx supabase db query --linked -f supabase/migrations/20261017000000_connection_settings_atomic.sql   # 연결 설정을 한 번에 고치는 함수(merge_connection_settings · add_connection_stats). 이 함수를 부르는 코드를 병합하기 **직전에**. 먼저 배포하면 연결 · 다시 연결 · Notion DB 설정 저장과 처음 훑기를 끝낸 Notion 동기화가 실패한다. 적용 뒤 `select has_function_privilege('service_role', 'public.merge_connection_settings(uuid,uuid,jsonb,text[],jsonb)', 'execute')`가 true, `notify pgrst, 'reload schema';`
# 트랙 2-3 · 2-4가 더한 파일도 같은 방식으로
```

### Auth 설정

Supabase → Authentication:

| 설정 | 값 |
|---|---|
| URL Configuration → Site URL | `https://api.taskforcelabs.dev` |
| Redirect URLs | `https://api.taskforcelabs.dev/auth/confirm`, `http://localhost:3000/auth/confirm` |
| Sign In / Providers → Apple | 켬, Client IDs `dev.taskforcelabs.taskforce` (앱 안 로그인만이면 Services ID · Secret 불필요, PLATFORMS.md 6장) |
| Sign In / Providers → Google | 켬 ✅ (2026-09-30). Client IDs = 프로젝트 A iOS 클라이언트 ID `923900348266-iopmhbf1foor213n1jc3a8tv6v4fti82.apps.googleusercontent.com`, Client Secret 비움(웹 OAuth용이라 앱 로그인에는 쓰지 않는다), **Skip nonce checks 끔**(앱이 nonce를 보낸다). 5장 "Sign in with Google" |
| Providers → Email | 웹 관리 화면의 링크 로그인용 + App Store 심사용 비밀번호 로그인으로 켬. 새 가입은 막지 않는다 — 허용 목록은 아래 Hooks가 대신 막는다 |
| Hooks → Before User Created | Postgres function `public.hook_before_user_created` → **Enable** (마이그레이션 `20261007000000_review_account_signup_hook.sql`). `provider = email`로 가입하는 주소가 `review_accounts`에 없으면 403으로 거절한다. Apple · Google 가입에는 영향 없다(`docs/go-live/app-store.md` 3장, `tests/db/review-accounts.test.ts`) |
| Email Templates → Magic Link | 앱에 이메일 6자리 코드를 붙이면 `{{ .Token }}` 추가 (PLATFORMS.md 4장) |
| SMTP | 지금은 Supabase 기본 메일(한도가 낮음, 운영자 로그인용으로만 충분). 이용자에게 이메일 로그인을 열면 자체 SMTP를 붙이고 처리방침 7장에 수탁자를 더한다(`docs/legal/README.md` 결정 3) |

심사 계정 만들기(위 Hook을 켠 뒤): `REVIEW_ACCOUNT_EMAIL=review@taskforcelabs.dev REVIEW_ACCOUNT_PASSWORD=… npx tsx --conditions react-server scripts/create-review-account.ts --yes`(운영 DB 키로, `docs/go-live/app-store.md` 3장).

### 요금제 · 백업 확인

Supabase → Organization → Billing에서 프로젝트가 **Free**이고 백업(Database → Backups)이 없는지 확인한다. 처리방침의 "백업 없음 → 삭제 즉시"가 여기에 기댄다. Pro로 올리면 7일 백업이 생기므로 올리기 전에 처리방침 5장을 고친다. 로그 보관은 Free 1일이다.

## 5. Apple

- **릴리스 `API_BASE_URL`:** Release 구성은 커밋된 `apple/Config/Release.xcconfig`가 `API_BASE_URL = https:/$()/api.taskforcelabs.dev`로 정한다(Debug는 `Secrets.xcconfig`의 로컬 주소). 아카이브한 앱의 Info.plist `APIBaseURL`이 운영 주소인지 확인한다. 로컬 서버 값으로 TestFlight에 올리면 테스터가 아무것도 못 한다.
- **Push Notifications 기능:** App ID `dev.taskforcelabs.taskforce`에 Push Notifications를 켠다. 앱 권한 파일에 `aps-environment`가 있어서, 켜기 전에는 서명 빌드의 프로필 발급이 실패한다.
- **APNs 키:** Apple Developer → Keys → + → Apple Push Notifications service → `.p8` → `APNS_KEY_ID` · `APNS_PRIVATE_KEY`.
- **Sign in with Apple 키:** `app-store.md` 6장 1번 → `APPLE_*`.
- **Sign in with Google (로그인만, [PLATFORMS.md](../PLATFORMS.md) 4장):** 사용자가 콘솔에서 하는 순서.
  1. ✅ (2026-09-30) Google Cloud 프로젝트 A `taskforce-510108` → Google Auth Platform → Clients → Create client → 유형 **iOS**, 이름 "Taskforce app sign-in (iOS · Mac)", 번들 ID `dev.taskforcelabs.taskforce`, Team ID `U9DWQKQFMW`. Mac 앱도 같은 iOS 클라이언트를 쓴다(Google 문서: macOS 앱은 iOS 유형). 클라이언트 ID `923900348266-iopmhbf1foor213n1jc3a8tv6v4fti82.apps.googleusercontent.com`, iOS URL scheme `com.googleusercontent.apps.923900348266-iopmhbf1foor213n1jc3a8tv6v4fti82`. 비밀 값은 없다.
     범위는 SDK 기본값(`openid` · `email` · `profile`, 민감하지 않은 범위)만 쓴다. 프로젝트 A의 Data access 목록에 `userinfo.profile`이 없으면 넣어 둔다(재심사 없음. 로그인 동의 화면에 이름 · 프로필 사진 공유가 보인다).
  2. ✅ (2026-09-30) Supabase(운영) → Authentication → Sign In / Providers → Google → Enable, Client IDs에 1번 클라이언트 ID, Client Secret 비움, Skip nonce checks **끔**. 4장 Auth 설정 표.
  3. 앱 설정: Release(TestFlight · App Store)는 커밋된 `apple/Config/Release.xcconfig`의 `GOOGLE_IOS_CLIENT_ID` · `GOOGLE_IOS_URL_SCHEME`을 쓴다(이 PR, 공개 식별자). Debug로 Google 로그인을 시험하려면 로컬 `apple/Config/Secrets.xcconfig`에 같은 두 줄을 넣는다(비우면 버튼이 숨는다, `Secrets.example.xcconfig`).
     아카이브한 앱의 Info.plist `GIDClientID`가 1번 값인지 확인한다.
  4. 서명한 Mac 빌드: 권한 파일에 `keychain-access-groups`(`$(AppIdentifierPrefix)dev.taskforcelabs.taskforce`)가 더해졌다. **처음 서명 빌드(Debug · 아카이브 모두) 때 프로필이 이 그룹을 허용하는지 확인한다.**
     허용되지 않으면 Google 로그인만 실패하는 게 아니다: 권한 파일과 프로필이 어긋나면 macOS가 앱 실행을 막거나 권한을 통째로 무시해 App Group Keychain의 Supabase 세션도 저장하지 못할 수 있다(`-34018`, "Couldn't save your sign-in.", apple/README 4번과 같은 증상).
     ```bash
     APP=<빌드된 Taskforce.app>   # 예: ~/Library/Developer/Xcode/DerivedData/…/Build/Products/Debug/Taskforce.app
     codesign -d --entitlements :- "$APP"          # keychain-access-groups에 U9DWQKQFMW.dev.taskforcelabs.taskforce, application-groups에 group.dev.taskforcelabs.taskforce
     security cms -D -i "$APP/Contents/embedded.provisionprofile" | plutil -extract Entitlements xml1 -o - -   # keychain-access-groups가 U9DWQKQFMW.* 를 허용하는지
     codesign --verify --deep --strict "$APP"       # 아무것도 출력하지 않아야 한다
     ```
     프로필에 없으면 Apple Developer에서 프로필을 다시 받고(apple/README 4번의 순서: 옛 Mac 프로필 · 빌드된 앱을 지운 뒤 `-allowProvisioningUpdates`) 다시 확인한다.
  5. 실기기 확인(8장): iPhone · Mac에서
     - Google 로그인 → 계정 메뉴에 "Google Account", 프로필 이름이 Google 이름으로 채워짐 → 로그아웃 → 다시 Google 로그인.
     - **받은 범위:** Debug 빌드로 로그인한 뒤 Xcode에서 일시 정지하고 `po GIDSignIn.sharedInstance.currentUser?.grantedScopes`. 로그인 범위(`openid` · `email` · `profile`)만 기대하지만, 같은 Google 계정으로 Calendar · Meet 연결을 허용했다면 `include_granted_scopes` 때문에 그 범위도 보일 수 있다(PLATFORMS.md 4장, 앱은 쓰지 않는다). 본 값을 여기에 적는다.
     - 계정 삭제 → Apple 창이 뜨지 않음(Google로만 가입한 계정) → Google 계정 → 보안 → 서드파티 앱 및 서비스에서 Taskforce가 사라짐. 같은 프로젝트라 Calendar · Meet 연결 권한도 함께 사라질 수 있다(삭제 때 서버도 연동 토큰을 폐기하므로 괜찮다).
     - Google로 가입한 계정에 다른 기기에서 Apple로 로그인해 이은 뒤(같은 이메일일 때) 첫 기기에서 계정 삭제 → Apple 창이 뜬다.
- **URL scheme:** `taskforce`가 `apple/Taskforce/Info.plist`에 등록되어 있다. OAuth 복귀(`taskforce://connections/{provider}?handoff=<id>`, `src/lib/connectors/callback.ts`)가 이걸로 앱에 돌아온다. callback은 code를 암호화한 완료 대기(handoff, 2분)로 남기고 이 주소로 보낼 뿐이고, 앱이 그 `handoff`로 `POST /api/v1/connections/{provider}/complete`(Bearer 토큰)를 불러야 연결이 끝난다(시작한 사용자만, 한 번만). 릴리스 빌드에서도 URL scheme이 빠지지 않았는지 확인한다.

## 6. Cron 확인

`vercel.json`: `/api/cron/sync` 15분마다, `/api/cron/retry-sources` 매시 7분 · 37분(실패 · 멈춘 글 원문 다시 처리, 하루 안에 들어온 원문만 첫 처리 포함 3번까지. 하루가 지나서도 멈춘 원문은 실패로 닫는다), `/api/cron/reminders` 매일 00:00 UTC(한국 09:00), `/api/cron/retention` 매일 18:30 UTC(한국 03:30, 원문 90일 보관 정리 · 보관 기한이 지난 실행 산출물 본문 비우기 · `src/lib/retention.ts`), `/api/cron/execution-sweep` 1분마다(실행, 9장. `EXECUTION_ENABLED`가 꺼져 있으면 `{ enabled: false }`로 바로 끝난다).

1. 배포 뒤 Vercel → 프로젝트 → Settings → Cron Jobs에 다섯 개가 보이는지.
2. Logs에서 `/api/cron/sync`가 15분마다 200인지. 401이면 `CRON_SECRET`이 없거나 다르다.
3. 다음 날 09:00 KST에 `/api/cron/reminders`가 200인지(기한 임박 알림).
4. 다음 날 03:30 KST에 `/api/cron/retention`이 200이고 `{ sources_purged, judge_logs_deleted, artifacts_purged }`를 돌려주는지(처리방침 5장 "90일" 약속). 산출물 정리가 실패하면 나머지 정리는 하고 500 · `artifacts_purged: null` · 로그 "실행 산출물 본문 정리 실패"다(마이그레이션 `20261022000000` 적용 전이면 이렇다).
5. `/api/cron/retry-sources`가 30분마다 200이고 `{ due, retried, failed, gaveUp, expired, skippedForTime }`를 돌려주는지. `failed`나 `gaveUp`이 자주 0보다 크면 추출 실패가 잦다는 뜻이다(모델 · 공급자 확인). `expired`는 이번 실행에서 실패로 닫은, 들어온 지 하루가 넘고도 처리 중 · 대기에 15분 넘게 멈춘 글 원문(kind task 제외)의 수다: 사용자가 동의하지 않았거나 후보 밖이었거나 마지막 시도에서 끊겨 앱에 "처리 중"으로 남던 원문을 다시 처리하지 않고 `failed` · `processing_summary.closed = "expired"`로 닫는다. 한 번에 100건까지(닫기에 20초까지) 오래된 것부터라, 배포 직후 옛 원문이 쌓여 있으면 몇 번의 실행 동안 `expired`가 0보다 크다가 0으로 돌아온다(계속 0보다 크면 원문이 계속 멈추고 있다는 뜻이다: 다시 처리 실패 로그와 `maxDuration`을 본다). 닫는 조회가 실패하면 로그에 "창을 지난 원문 찾기 실패"가 남고 다시 처리는 그대로 돈다. 이 cron은 들어온 지 하루가 넘은 원문은 다시 처리하지 않는다: 배포 전에 `processing_status`가 `failed` · `processing` · `pending`인 글 원문(kind task 제외)을 세어 보고, 살릴 것만 `scripts/reprocess-sources.ts --source <id>`로 하나씩 처리한다(이미 닫힌 원문도 같은 방법으로 살릴 수 있다. 스크립트는 재처리 cron처럼 이미 근거로 붙은 구절과 겹치는 후보를 빼고 병합해 근거 · Claim이 두 번 붙지 않는다). 옵션 없이 돌리면 근거가 없는 모든 원문(할 일이 없어 끝난 원문 포함)을 다시 처리하므로 쓰지 않는다.
6. 동의하지 않은 사용자의 연결은 동기화에서 건너뛴다(`registry.ts`의 `withoutConsent`). 테스트 계정으로 동의 전 · 후를 한 번씩 본다.

## 7. 웹사이트 배포

대상: Side Kick 저장소 `apps/website`(Next 16, `[lang]` 라우팅). **2026-09-29 배포함**: songch9511/taskforce #18(새 사이트 · 처리방침 · 약관, 시행일 2026-09-29) · #19(푸터 문의 주소).

배포 방법(2026-09-29 확인): Vercel `taskforce-website`는 GitHub `songch9511/taskforce`의 `main`에 Git 연동돼 있다(Root Directory `apps/website`). `main`에 병합하면 Production, 다른 브랜치는 Preview다. 저장소는 **squash 병합만** 허용한다. **커밋 작성자 이메일이 GitHub 계정에 연결돼 있지 않으면 Vercel이 배포를 막는다**(`BLOCKED`, "couldn't find a Git account for the commit author"). 이 맥에는 `git config user.email`이 없어 `…@Danielui-MacBookAir.local`이 들어가므로, 브랜치 커밋은 GitHub noreply 주소(`67100803+songch9511@users.noreply.github.com`)로 만든다. GitHub에서 병합한 커밋은 괜찮다. Side Kick 저장소의 GitHub Actions는 결제 문제로 job이 시작되지 않는다(2026-09-16부터). 같은 명령을 로컬에서 돌려 확인한다.

1. `/privacy` · `/terms`는 `/en/privacy` · `/en/terms`로 리디렉트한다. 법률 markdown은 실시간 렌더가 아니라 **`apps/website/scripts/sync-legal.mjs`가 이 저장소의 `docs/legal/`에서 네 파일(`privacy.{ko,en}.md` · `terms.{ko,en}.md`)을 복사**해 둔다(원본은 여전히 `docs/legal/`, 고칠 때마다 스크립트를 다시 돌려 동기화한다).
2. 이전 제품 페이지(download · pricing · account · beta · login · updates · help)는 홈으로 리디렉트. 이전 Mac 앱의 `/en/login` · `/en/account` 링크도 홈으로 간다. 이용자가 운영자뿐이라 감수했다(2026-09-29 결정). 이전 OAuth 브로커(`/api/connections/*`)는 그대로 둔다.
3. 홈 푸터: Privacy · 문의 주소(`privacy@taskforcelabs.dev`를 링크 글자로, 2026-09-29. "Contact" mailto는 메일 앱이 없는 브라우저에서 반응이 없었다). 홈에 Google Limited Use 문장 한 줄. Privacy 링크는 동의 화면과 같은 `https://www.taskforcelabs.dev/en/privacy`.
4. 분석 도구 · 쿠키 없음 확인: `curl -sI https://www.taskforcelabs.dev | grep -i set-cookie`가 비어야 하고, 페이지에 분석 스크립트가 없어야 한다.
5. `npm run build && npm test` → Preview 배포에서 확인 → **사용자 승인 뒤** Production.
6. 끝: `https://www.taskforcelabs.dev/en/privacy`에 새 처리방침이 보이고, `docs/legal/README.md`의 게시 규칙(자리표시자 · 상자 없음)을 지킨다.
7. TestFlight CTA 링크는 go live 날 넣는다(체크리스트 G2): Vercel `taskforce-website` Production에 `TESTFLIGHT_URL` → 재배포(빌드 때 읽는다). 그 전에는 두 CTA 자리에 링크 없는 "Coming soon"이 나온다(2026-09-29).
8. 처리방침을 바꿀 때 `src/lib/legal/policy.ts`의 버전 · 시행일을 함께 바꾼다. 앱은 `GET /api/v1/legal`로 받아 안내 한 줄을 보인다(처리방침 17장 "앱과 이 페이지에 알립니다").
   - **기본은 `upcoming`이다 (go live 뒤의 모든 실질 변경).** 새 판을 `upcoming`에 두고 시행 7일 전까지 배포한다. 수집 항목 · 목적 · 받는 곳이 늘어나는 변경은 30일 전까지 둔다(17장의 약속). 그러면 모든 계정에 "Privacy Policy changes <날짜>"가 보이고, 시행일 한국 시간 0시가 지나면 배포 없이 현재 판이 된다. 다음에 고칠 때 `current`로 옮기고 `upcoming`을 비운다.
   - **`upcoming.url`은 그 판의 버전 주소다** (`https://www.taskforcelabs.dev/{ko,en}/privacy/{version}`, 예: `/ko/privacy/beta-1.2`). 알리는 동안 `/{lang}/privacy`는 아직 현재 판을 보여 주므로, "View"가 새 판을 열려면 웹사이트가 시행 전 판도 버전 주소로 내놓아야 한다. 지금 웹사이트는 보관본(`/{lang}/privacy/beta-1.0`)만 버전 주소로 내놓는다. 시행 예정 판을 내놓는 길은 웹사이트 저장소의 별도 변경이다. 첫 `upcoming` 전에 만든다.
   - **`current`만 바꾸기(게시와 함께 시행, 시행 뒤 알림)는 두 경우뿐이다:** 처리 내용이 바뀌지 않는 고침(오탈자 · 문장 다듬기 · 연락처)이거나, 계정이 운영자 것뿐일 때(베타 1.1이 그랬다, `docs/legal/README.md` 게시 기록). 그 전에 가입한 계정에 시행일부터 30일 동안 "Privacy Policy updated"가 보인다(그 뒤 처음 앱을 연 계정에는 보이지 않는다).
   - 서버를 배포해야 안내가 나간다. `current`만 바꿀 때는 웹사이트 게시와 같은 날 배포한다.
   - 안내를 봤는지는 기기에만 남고 서버에는 남기지 않는다: 서버에 남기려면 처리방침에 그 이용 기록을 먼저 적는다. 앱은 계정마다 30분에 한 번만 읽으므로 배포 뒤 안내가 보이기까지 30분쯤 걸릴 수 있다.

## 8. 배포 뒤 확인 (한 번씩)

| 확인 | 방법 | 기대 |
|---|---|---|
| 인증 없는 요청 | `curl -s -o /dev/null -w '%{http_code}' https://api.taskforcelabs.dev/api/v1/now` | 401 |
| 리전 | Vercel Logs → 요청 상세 → Function region | `syd1` |
| 앱 로그인 | TestFlight 빌드로 Sign in with Apple | 로그인 · 프로필 저장 |
| 동의 | 첫 Connect → AI data 화면 → Allow | `profiles.ai_consent_at` 채워짐 |
| Notion 연결 | 앱 → Connect Notion → 앱으로 복귀 | `connected`, 14일 회의록 동기화, Now에 할 일 |
| 알림 | 확인 요청이 생기는 원문 넣기 | 잠금 화면에 제목 없는 알림, 열면 제목 |
| 계정 삭제 | 시험 계정으로 앱에서 삭제 | 사용자 표 행 0건 (아래 SQL), Apple · Notion 연결 목록에서 사라짐 |
| 삭제 뒤 남는 것 | `select count(*) from auth.audit_log_entries where payload->>'actor_id' = '<지운 id>'` | 0이 아니면 처리방침 "삭제 즉시"와 어긋난다 → 기록하고 처리 방법을 정한다(확인하지 못한 사실) |
| OpenRouter | Settings → Privacy | 프롬프트 로깅 꺼짐, 운영 키 사용 한도 |
| 로그 | Vercel Logs에서 동기화 · 원문 처리 요청 몇 개 | 원문 · 토큰 없음, 오류 메시지 · id만 |

삭제 확인 SQL(시험 계정 id로, 읽기만):
```sql
select 'sources' t, count(*) from public.sources where user_id = '<id>'
union all select 'actions', count(*) from public.actions where user_id = '<id>'
union all select 'connections', count(*) from public.connections where user_id = '<id>'
union all select 'profiles', count(*) from public.profiles where user_id = '<id>';
```

### Slack 켜기 (순서대로, [slack-integration.md](slack-integration.md) 8장의 남은 칸)

1. ✅ **배포** (2026-09-29) — Slack PR #4~#10을 main에 병합해 배포했다. 마이그레이션 `20261011` · `20261012` · `20261013`은 그 전에 적용했다.
2. ✅ **배포 바로 뒤** `20261014000000_connections_server_delete.sql` 적용(2026-09-29). 확인: `connections`의 정책이 `owner_select`만 남음.
3. ✅ **운영 Slack 앱(L7)** (2026-09-29) — taskforcelabs 워크스페이스의 **Taskforce**(App ID `A0C584MQJV7`). Vercel env `SLACK_CLIENT_ID`(숫자.숫자, 앱의 Basic Information에서) · `SLACK_CLIENT_SECRET` · `SLACK_SIGNING_SECRET` · `SLACK_REDIRECT_URI` → 재배포 → 이벤트 URL "Verified". 남은 것: 앱 아이콘, 공개 배포(운영 확인 뒤).
   - 운영 확인은 앱에 열기 전에 **운영자만**(`ADMIN_EMAILS`) 웹 /lab의 "Slack 연결"로 한다. 그 밖의 사용자는 `/lab?slack=unavailable`.
4. **처리방침 게시(W2)와 PR 4 앱 빌드(Slack 확인 창 · 끊기 문구)가 TestFlight에 나간 뒤** `SLACK_CONNECT_ENABLED=true` → 재배포. 앱의 Slack 줄이 "Coming soon"에서 Connect로 바뀐다. 예전 빌드는 확인 창 없이 연결되고 끊기 문구가 옛것이라, 켜기 전에 테스터가 새 빌드를 받게 한다.
5. **확인** — 운영자 연결로 2026-09-29에 했다(아래 "결과"). 남은 것: 두 이용자, 앱 빌드로 연결(확인 창 · 끊기 문구), 정리 cron 응답

| 확인 | 방법 | 기대 |
|---|---|---|
| 연결 | 앱 → Connect Slack → 확인 창 세 줄 → 권한 화면 | 권한 9개, 봇 없음, 앱으로 돌아와 `connected` |
| 할 일 | 다른 계정이 DM "금요일까지 보내 주실 수 있을까요?" + 내 "넵" | 대화가 30분 멈추고 다음 동기화(15분마다) 뒤 할 일, 근거에 Slack 인용 |
| 버림 | 나를 부르지 않은 채널 글 | `slack_messages` · `sources`에 없음 |
| 끊기 | 앱 → Disconnect (확인 창 "Slack messages are removed from Taskforce. Tasks stay.") | Slack 워크스페이스의 앱 관리에서 사라짐, 아래 SQL이 모두 0, 할 일 그대로, 근거 자리에 "Removed when Slack was disconnected" |
| Slack에서 앱 제거 | 다시 연결한 뒤 Slack 쪽(워크스페이스 앱 관리)에서 Taskforce 제거 | 연결이 `revoked`(앱에 Reconnect · Disconnect), 아래 SQL이 모두 0. 앱에서 Disconnect하면 연결 행도 사라짐 |
| 두 이용자 | 같은 워크스페이스의 Taskforce 계정 둘이 연결 → 한 명이 Slack에서 권한을 거둠 | 그 사람만 `revoked`(`tokens_revoked`), 다른 사람은 그대로. 마지막 한 명까지 거두면 `app_uninstalled` |
| 로그 | Vercel Logs의 `/api/connectors/slack/events` · 동기화 요청 | 메시지 본문 · 이름 · 토큰 없음 |
| 정리 · 토큰 확인 | `/api/cron/retention` 응답 | `slack_messages_deleted` · `slack_threads_deleted` · `slack_sources_repurged` · `slack_tokens_checked` · `slack_tokens_revoked` 칸이 있고, 연결된 Slack 수만큼 `slack_tokens_checked` |

운영 확인 결과 (2026-09-29, 운영자 연결 · /lab · 운영 DB):

| 확인 | 결과 |
|---|---|
| 연결 | ✅ 운영 앱 권한 화면(권한 9개, 봇 없음) → `/lab?slack=connected`. 운영자가 아니면 `/lab?slack=unavailable` |
| 할 일 | ✅ 두 번째 계정 DM "견적서 목요일까지 보내 주실 수 있을까요?" + 내 "넵, 목요일까지 보내드릴게요" → "푸바오에게 견적 발송", 기한 10-01(목), 자동 반영, 근거 인용 |
| 버림 | ✅ 나를 부르지 않은 채널 글은 `slack_messages`에 없음 |
| 끊기 | ✅ 204, 원문 본문 · 관련자 · 인용 · Claim 글자 · 판정 기록 0, 할 일 기한 그대로. 끊은 직후 Slack 이벤트 2건(`tokens_revoked` · `app_uninstalled`) 200 |
| Slack에서 권한 거둠 | ✅ 워크스페이스 앱 페이지 → Configuration → Your authorization → Revoke → 연결 `revoked`, 토큰 · 대기 데이터 0. 앱의 끊기로 연결 행도 지워짐 |
| 로그 | ✅ Vercel Logs에서 메시지 글("견적") · 이름("푸바오")이 나오지 않음, 토큰 폐기 실패 없음 |
| 두 이용자 | 남음 — 같은 워크스페이스의 두 번째 Taskforce 계정이 필요하다 |

만들며 알게 된 것: 운영 `SLACK_CONNECT_ENABLED`가 꺼져 있으면 운영자 연결의 callback도 막혔고(#11로 고침), 동기화도 Slack을 빼고 돌았다(#15로 고침: 닫는 것은 새 연결뿐).

Slack 글자가 남았는지 확인하는 SQL(시험 계정 id로, 읽기만, 그 계정에 Slack 연결이 없을 때 모두 0이어야 한다). 첫 줄은 D3가 빠뜨린 Slack 원문을 잡는다(Slack 링크인데 지운 표시가 없음):
```sql
select 'unpurged slack source' t, count(*) from public.sources where user_id = '<id>'
  and external_url like 'https://%.slack.com/%' and raw_text_purge_reason is distinct from 'disconnected'
union all select 'source text', count(*) from public.sources where user_id = '<id>' and raw_text_purge_reason = 'disconnected' and (raw_text <> '' or participants is not null)
union all select 'evidence', count(*) from public.evidence e join public.sources s on s.id = e.source_id
  where s.user_id = '<id>' and s.raw_text_purge_reason = 'disconnected' and e.quote <> 'Slack 연결을 끊어 지웠어요'
union all select 'claims', count(*) from public.claims c join public.sources s on s.id = c.source_id
  where s.user_id = '<id>' and s.raw_text_purge_reason = 'disconnected' and (c.quote <> '' or c.value_text is not null or c.speaker is not null)
union all select 'judge_logs', count(*) from public.judge_logs j join public.sources s on s.id = j.source_id
  where s.user_id = '<id>' and s.raw_text_purge_reason = 'disconnected'
union all select 'slack_messages', count(*) from public.slack_messages where user_id = '<id>'
union all select 'slack_threads', count(*) from public.slack_threads where user_id = '<id>'
union all select 'slack_people', count(*) from public.slack_people where user_id = '<id>';
```

## 9. 실행 (U2: run · 내장 초안)

계약은 [EXECUTION.md](../EXECUTION.md). 단계는 세 겹이 모두 열려야 불린다: 환경변수 `EXECUTION_ENABLED`(Vercel), 실행 주체 허용 목록 `execution_actors`, 차단 스위치 `execution_controls`. U2는 외부로 아무것도 보내지 않는다(유일한 효과는 내장 초안의 AI 호출).

- 아래 명령은 저장소 루트에서 `npx supabase db query --linked "<sql>"`로 한다. **운영 DB다.** 쓰기는 줄마다 사용자 승인 뒤, 한 명령에 문장 하나만 넣는다(여러 문장을 한 명령에 넣으면 한 트랜잭션으로 돌 수 있다).
- 조회는 개수 · 상태 · 시각만 본다. 요청 · 계획 · 초안 · receipt · 원문 본문과 다른 사람의 이메일은 읽지 않는다. 운영자 계정은 자기 이메일로 찾되 이메일을 출력하지 않는다.
- 이메일 · 크레딧 양 · uuid는 `<…>` 자리에 넣는다. 이 문서에 실제 값을 적지 않는다(공개 저장소).

### 9-1. 차단 스위치 `execution_controls`

행 다섯 개: `global '*'` · `provider 'taskforce'` · `mode 'manual'` · `mode 'auto'` · `mode 'full'`. 행이 없거나 `blocked = true`면 막힌다. 처음 상태(마이그레이션 시드)는 `global` 막힘, `auto` · `full` 막힘이라 `global`을 풀어도 "Manual만"이다. 막힌 단계는 실패가 아니다: `prepared`에 남고, 풀리면 sweep이 이어 간다. sweep은 막힌 run을 5분마다만 깨우므로(UTC 분이 5의 배수일 때, `HELD_WAKE_EVERY_MINUTES`) 풀린 뒤 늦어도 5분 안에 이어 간다. global이 막혀 있는 동안에는 어떤 run도 깨우지 않는다. 이미 `calling`인 단계는 끝까지 결과를 받는다(EXECUTION 6장).

```bash
# 지금 상태 (읽기)
npx supabase db query --linked "select scope, key, blocked from public.execution_controls order by scope, key"
# 끄기 · 긴급 (이 한 줄만)
npx supabase db query --linked "update public.execution_controls set blocked = true where scope = 'global' and key = '*'"
# 켜기 (먼저 위 읽기로 auto · full이 막혀 있는지 본다)
npx supabase db query --linked "update public.execution_controls set blocked = false where scope = 'global' and key = '*'"
```

"Manual만"으로 되돌리기(auto · full을 연 적이 있을 때): **global을 먼저 막고**, 모드 행을 한 줄씩 바꾸고, 읽기로 확인한 뒤 global을 푼다. 바꾸는 동안 반쯤 바뀐 스위치로 단계가 불리지 않는다.

```bash
npx supabase db query --linked "update public.execution_controls set blocked = true where scope = 'global' and key = '*'"
npx supabase db query --linked "update public.execution_controls set blocked = true where scope = 'mode' and key = 'auto'"
npx supabase db query --linked "update public.execution_controls set blocked = true where scope = 'mode' and key = 'full'"
npx supabase db query --linked "select scope, key, blocked from public.execution_controls order by scope, key"
npx supabase db query --linked "update public.execution_controls set blocked = false where scope = 'global' and key = '*'"
```

교착(deadlock)을 피하는 규칙. `begin_call`은 단계 → run → 정책 → 실행 주체 → 스위치 세 행(`global` → `mode` → `provider` 순서) → 도구 → 크레딧 계정 순서로 잠근다(EXECUTION 6장). 이 순서를 거스르는 운영자 쓰기는 진행 중인 `begin_call`과 서로 기다리다 한쪽이 되돌려진다(40P01).

- 긴급할 때는 **`global` 한 행만** 바꾼다. 스위치 여러 행을 한 문장 · 한 명령에서 바꾸지 않는다(행을 잠그는 순서가 정해지지 않는다).
- 정책(`execution_policies`)과 단계(`execution_steps`)를 한 트랜잭션(한 명령)에서 쓰지 않는다: `begin_call`은 단계를 먼저, 정책을 나중에 잠근다. U2에서 운영자가 정책 · 단계를 고칠 일은 없다. 꼭 고쳐야 하면 한 명령에 한 표만.
- 끄는 update는 진행 중인 `begin_call`(RPC 하나 길이)이 끝날 때까지 기다렸다가 들어간다. 그 뒤에 `calling`으로 가는 단계는 없다.

### 9-2. 실행 주체 `execution_actors`

건넴 전까지 운영자 계정만 넣는다. 목록 밖 사용자는 `/api/v1/runs`가 404이고, 이미 있던 run은 `begin_call`이 `hold_reason = 'actor'`로 막는다.

```bash
# 넣기: 결과가 1행(added = 1)이어야 한다. 0행이면 이메일이 틀렸거나 이미 들어 있다
npx supabase db query --linked "insert into public.execution_actors (user_id) select id from auth.users where lower(email) = lower('<운영자 이메일>') on conflict do nothing returning 1 as added"
# 빼기: 결과 1행(removed = 1)
npx supabase db query --linked "delete from public.execution_actors where user_id = (select id from auth.users where lower(email) = lower('<운영자 이메일>')) returning 1 as removed"
# 확인 (개수만)
npx supabase db query --linked "select count(*) as actors from public.execution_actors"
```

### 9-3. 크레딧 지급 `grant_credits`

크레딧은 운영자가 지급한다(구매 경로 없음, EXECUTION 12장). 양은 크레딧이고 요율 `c3-v1`에서 1 크레딧 = $0.001다. 초안 단계 하나의 예약 추정치는 `DRAFT_ESTIMATE_CREDITS`(`src/lib/execution/limits.ts`)이고, 정산은 확정된 원가 ÷ 크레딧당 USD를 올림한 값이고 예약을 넘지 않는다. 가용 잔액(지급 - 예약 - 정산)이 이 추정치 이상이어야 초안 단계를 부른다. 모자라면 run이 `hold_reason = 'credit'`로 막히고, 지급하면 늦어도 5분 안에 이어 간다(9-1). run 예산(`budget_credits`)은 만들 때 이 추정치 이상만 받는다(작으면 400). 초안 둘을 맡긴 run은 첫 초안 정산 뒤 남은 예산이 추정치보다 작으면 `credit`으로 기다리고 지급으로 풀리지 않는다: 그 run은 멈춘다(9-4 "오래 막힌 run 정리"). 양수는 지급, 음수는 회수(예약 · 정산된 크레딧은 회수하지 못한다). 지급 id마다 한 번만 들어간다: 같은 id로 다시 보내면 아무것도 하지 않고 `false`, 같은 id로 다른 양을 보내면 오류다.

```bash
# 지급 id를 지급마다 새로 만든다 (작업 기록에 적어 둔다. 같은 지급을 다시 보내도 한 번만 들어간다)
uuidgen
# 지급: granted = true (이메일이 틀리면 '잘못된 인자' 오류)
npx supabase db query --linked "select public.grant_credits((select id from auth.users where lower(email) = lower('<운영자 이메일>')), <크레딧>, '<지급 uuid>') as granted"
# 확인 (그 계정의 합계만)
npx supabase db query --linked "select granted, reserved, settled, granted - reserved - settled as available from public.credit_accounts where user_id = (select id from auth.users where lower(email) = lower('<운영자 이메일>'))"
```

### 9-4. 점검 (읽기, 개수만)

```sql
-- lease가 끝났는데 아직 calling인 단계: 1분 sweep이 옮긴다. 몇 분 넘게 0이 아니면 sweep이 돌지 않는다 (Vercel Cron · CRON_SECRET · EXECUTION_ENABLED)
select count(*) as expired_calling from public.execution_steps where state = 'calling' and lease_expires_at < now();
-- 결과 불명 단계: U2에는 외부 효과가 없어 0이어야 한다 (내부 효과는 결과 불명 대신 다시 준비한다)
select count(*) as unknown_outcome, min(unknown_since) as oldest from public.execution_steps where state = 'unknown_outcome';
-- 끝나지 않은 run의 막힌 이유 (null = 막히지 않음). credit → 9-3 지급(또는 run 예산이 작음), actor → 9-2, blocked → 아래 판단별. 풀린 뒤 늦어도 5분 안에 이어 간다(9-1)
select hold_reason, count(*) as runs from public.execution_runs where state in ('queued', 'running', 'waiting_approval') group by 1 order by 1;
-- blocked인 run을 막은 판단 (막힌 이유가 blocked로 바뀐 때의 gate, 코드 값만): blocked = 스위치(9-1), tool = 도구 목록, recipient = 수신자 허용 목록,
-- no_rate · no_estimate · reservation_closed = 서버 쪽 문제(요율 없음 · 추정치 없는 초안 · 닫힌 예약). 운영자가 풀 수 없다 → 코드 · 데이터를 본다.
-- 이벤트는 막힌 이유가 바뀔 때만 남아, blocked인 채 다른 판단으로 막혀도 처음 판단이 보인다: 스위치를 푼 지 5분이 지나도 blocked면 도구 · 수신자 · 서버 쪽을 본다
select gate, count(*) as runs from (select distinct on (e.run_id) e.gate from public.execution_events e join public.execution_runs r on r.id = e.run_id
  where e.type = 'hold' and r.hold_reason = 'blocked' and r.state in ('queued', 'running', 'waiting_approval') order by e.run_id, e.id desc) g group by 1 order by 1;
-- 미확정 원가: sweep은 하루 안의 행만 generation 조회로 확정한다. 청구 대상(billable)이고 하루가 지난 행은 아래 "미확정 원가 정하기"
select billable, generation_id is not null as has_generation, created_at < now() - interval '1 day' as over_a_day, count(*) as n
from public.execution_usage where cost_status = 'unconfirmed' group by 1, 2, 3 order by 1, 2, 3;
-- 끝났는데 열린 예약이 남은 run: 원가가 미확정인 run만 남아야 한다 (그 밖은 sweep의 보조 안전망이 1분 안에 푼다)
select count(*) as open_ended_runs from public.credit_open_ended_runs(1000);
-- receipt가 빠진 끝낸 초안 (EXECUTION 9장): 0이어야 한다. sweep 보조 안전망이 하루 안의 것을 1분마다 이어 쓴다.
-- 하루가 지나도 남으면 로그 execution_receipt_failed(단계 id · 까닭)를 본다 (sweep은 하루 지난 산출물을 더 고르지 않는다)
select count(*) as missing_receipts from public.execution_artifacts a join public.execution_steps s on s.id = a.step_id
where s.state = 'called' and not exists (select 1 from public.sources x where x.kind = 'execution' and x.user_id = a.user_id and x.external_id = a.step_id::text);
-- 원문 · 인용 없는 실행 Claim (기준 17): 0이어야 한다
select count(*) as claims_without_source from public.claims where origin = 'execution' and (source_id is null or quote is null);
-- 실패한 단계의 까닭 (코드 값만): retries_exhausted가 몰리면 OpenRouter 키 · 잔액 · 권한(401 · 402 · 403)부터 본다 (EXECUTION 13장 오류 표)
select receipt->>'error' as error, count(*) as steps from public.execution_steps where state = 'failed' group by 1 order by 2 desc;
```

`EXECUTION_ENABLED`가 꺼져 있으면 sweep이 아무것도 하지 않아(lease 정리 · 원가 확정 · 예약 해제 모두) 위 수가 그대로 남는다. 켜면 1분 안에 줄어든다.

미확정 원가 정하기 (운영자, 행마다 승인). 예약을 잡고 있는 것은 청구 대상 행뿐이고, 청구 대상 미확정 행에는 늘 generation id가 있다. 청구 대상이 아닌 행(플랫폼 원가: 계획 · 실패 · 응답 없는 시도)은 청구 · 예약에 영향이 없고 지표의 미확정 수에만 남는다.

```bash
# 하루가 지난 청구 대상 미확정 행 (id · generation id만)
npx supabase db query --linked "select id, generation_id from public.execution_usage where cost_status = 'unconfirmed' and billable and created_at < now() - interval '1 day' order by id limit 20"
# OpenRouter 대시보드 Activity에서 그 generation의 비용(USD)을 찾는다 → 확정 (끝낸 단계면 그 자리에서 정산한다)
npx supabase db query --linked "select public.reconcile_usage(<id>, <비용 USD>) as confirmed"
```

비용을 찾을 수 없으면 정하지 않고 사용자에게 묻는다. 0원으로 확정하거나 예약을 손으로 해제하지 않는다(A46: 모르는 원가를 0으로 두지 않는다).

오래 막힌 run 정리 (운영자, run마다 승인). 운영자만 풀 수 있는 hold(`actor` · `blocked`)나 지급으로 풀리지 않는 `credit`(run 예산 부족)에 머문 run은 sweep이 5분마다 깨워도 그대로다. 풀 수 있는 것(9-1 · 9-2 · 9-3)이면 먼저 푼다. 아니면 그 run의 주인(지금은 운영자)에게 확인하고 멈춘다. 멈추면 남은 예약이 해제되고 이미 만든 초안은 그대로다.

```bash
# 하루 넘게 막힌 끝나지 않은 run (id · 이유 · 만든 날만)
npx supabase db query --linked "select id, hold_reason, created_at::date as created from public.execution_runs where state in ('queued', 'running', 'waiting_approval') and hold_reason is not null and created_at < now() - interval '1 day' order by created_at limit 20"
# 멈추기: run마다 한 명령 (여러 run을 한 명령에서 멈추면 run · 계정 잠금끼리 교착할 수 있다). 결과 stopped. 교착(40P01)으로 되돌려지면 그대로 다시 보낸다
npx supabase db query --linked "select public.stop_run((select user_id from public.execution_runs where id = '<run>'), '<run>') as state"
```

### 9-5. 되돌리기

순서대로. 앞 단계만으로 멈추면 거기서 끝낸다.

1. **global 막기** (9-1 "끄기 · 긴급"). 새 단계가 바로 멈추고, 전체가 막히면 `POST /api/v1/runs`도 404다. 진행 중인 `calling`은 결과를 받는다.
2. **`EXECUTION_ENABLED` 끄기**: Vercel → Settings → Environment Variables(Production)에서 지우거나 `true`가 아닌 값으로 → Redeploy(환경변수는 새 배포부터 적용된다). 실행 route 404, sweep은 `{ enabled: false }`로 바로 끝난다.
3. **코드 되돌리기** (코드가 문제일 때): Vercel → Deployments → 되돌아갈 앞 Production 배포 → Instant Rollback(다시 빌드하지 않아 바로 바뀐다). 배포는 만들 때의 환경변수를 지닌다: 되돌아간 배포가 `EXECUTION_ENABLED=true`를 넣은 뒤에 만든 것이면 2번이 풀린다. 9-6 3번의 curl로 404인지 확인하고, 401이면 global을 막힌 채 두고 아래 revert 배포를 올린다. 이어서 main에서 그 PR을 revert(`git revert -m 1 <merge sha>` → PR → 병합). Instant Rollback 뒤에는 새 main 배포가 운영 도메인에 자동으로 붙지 않으니, revert 배포가 나오면 그 배포를 Promote해 자동 연결을 되살린다. 마이그레이션은 되돌리지 않는다(표를 지우지 않는다. 실행 마이그레이션은 표 · 함수 · 허용 값을 더하기만 해서 앞 배포도 그대로 돈다).

### 9-6. 운영 켜기 순서 (줄마다 승인 한 번)

앞 줄이 끝나고 확인까지 된 뒤 다음 줄로 간다. 어느 줄에서든 이상하면 9-5.

1. **처리방침 개정 게시 (D9a-1).** 내장 초안 · 산출물 · 크레딧 원장 · AI 원가 기록과 산출물 보관 기간을 담은 판을 게시한다([legal/README.md](../legal/README.md) 게시 규칙). 계정이 운영자 것뿐이면 게시와 함께 시행할 수 있다(7장 8번 "`current`만 바꾸기"). 먼저 개수로 확인한다: 운영자 계정(심사 계정 포함)의 이메일을 모두 넣고 `others = 0`이어야 한다(이메일이 없는 계정도 `others`에 든다).
   ```bash
   npx supabase db query --linked "select count(*) as total, count(*) filter (where email is null or lower(email) not in (lower('<운영자 이메일 1>'), lower('<운영자 이메일 2>'))) as others from auth.users"
   ```
   보관 기간이 90일(`execution_artifacts.retain_until` 열 기본값)이 아니면 켜기 전에 새 마이그레이션으로 열 기본값을 바꾼다. 본문은 매일 retention cron이 비운다(6장).
2. **마이그레이션 `20261020`–`20261023` 적용 확인** (읽기, 4장 방식으로 적용한 뒤). 기대: `1 · true · true · true · 2`.
   ```bash
   npx supabase db query --linked "select (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'sources' and column_name = 'processing_error_code') as m20261020, to_regprocedure('public.sweep_expire()') is not null as m20261021, to_regprocedure('public.purge_expired_artifacts()') is not null as m20261022, (select prosrc like '%insufficient_credit%' from pg_proc where oid = to_regprocedure('public.begin_call(uuid,text,integer)')) as begin_call_credits, (select count(*) from pg_constraint where conname in ('sources_kind_check', 'claims_origin_check') and pg_get_constraintdef(oid) like '%execution%') as m20261023"
   # 시드 그대로인지 (global 막힘, auto · full 막힘)와 빈 표
   npx supabase db query --linked "select scope, key, blocked from public.execution_controls order by scope, key"
   npx supabase db query --linked "select (select count(*) from public.execution_runs) as runs, (select count(*) from public.execution_actors) as actors, (select count(*) from public.credit_ledger) as ledger"
   ```
3. **`EXECUTION_ENABLED=true`** (Vercel Production) → Redeploy. 확인: `curl -s -o /dev/null -w '%{http_code}' -X POST https://api.taskforcelabs.dev/api/v1/runs`가 401(꺼져 있으면 404). `/api/cron/execution-sweep` 로그에 `execution_sweep`이 1분마다 남는다. 아직 실행 주체가 없고 global이 막혀 있어 아무것도 불리지 않는다.
4. **운영자 실행 주체 1행** (9-2 넣기). 확인: `actors = 1`.
5. **운영자 크레딧 지급** (9-3). 확인: `available`이 지급한 양.
6. **`global` 풀기** (9-1 켜기). auto · full은 막힌 채다. 확인: 읽기에서 `global` false, `auto` · `full` true.
7. **내장 초안 1건.** 먼저 운영자 기기의 앱을 receipt 값(`execution` · `executed` · `agent`)을 아는 빌드(#76 이후)로 올린다: 옛 빌드는 receipt가 붙은 할 일의 상세 · 원문 목록을 읽지 못한다(EXECUTION 9장). AI 동의를 마친 운영자 계정으로 웹 /lab에 로그인한 브라우저의 개발자 도구 콘솔에서 부른다(같은 출처라 쿠키 인증 · CSRF를 지난다). 할 일 id는 같은 콘솔에서 자기 목록(`GET /api/v1/now`의 `now[].id`)으로 고른다.
   ```js
   await fetch("/api/v1/now").then((r) => r.json())
   await fetch("/api/v1/runs", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ action_id: "<할 일 id>", goal: "draft", request: "<맡길 일>" }) }).then((r) => r.json())
   ```
   202 `{ run }`의 `run.id`를 적어 둔다. 1–2분 뒤 아래 9-7로 확인한다. 문제가 있으면 9-5.

### 9-7. U2 완료 확인

9-6 7번의 run으로. `<run>`은 그 run id다. 아래 기대값은 초안이 하나인 run 기준이다(planner가 초안을 둘 붙였으면 산출물 · 원장 수가 단계마다 하나씩 늘어난다). 모두 기대와 같으면 U2 서버 완료다.

```bash
# run: state done · outcome draft_ready · hold_reason null
npx supabase db query --linked "select state, outcome, hold_reason from public.execution_runs where id = '<run>'"
# 산출물 · 원가 · 원장
npx supabase db query --linked "select (select count(*) from public.execution_artifacts where run_id = '<run>') as artifacts, (select count(*) from public.execution_usage where run_id = '<run>' and billable and generation_id is not null and cost_status = 'confirmed') as billable_confirmed, (select count(*) from public.execution_usage where run_id = '<run>' and cost_status = 'unconfirmed') as unconfirmed, (select count(*) from public.credit_ledger where run_id = '<run>' and kind = 'reserve') as reserve, (select count(*) from public.credit_ledger where run_id = '<run>' and kind = 'settle') as settle, (select count(*) from public.credit_ledger where run_id = '<run>' and kind = 'release') as release"
# receipt → Claim/Evidence, Action 상태 (claims_without_evidence는 전체 실행 Claim 중 executed 근거가 없는 것)
npx supabase db query --linked "select (select count(*) from public.sources x join public.execution_artifacts a on x.external_id = a.step_id::text and x.user_id = a.user_id where a.run_id = r.id and x.kind = 'execution') as receipts, (select count(*) from public.execution_artifacts a join public.execution_steps s on s.id = a.step_id where a.run_id = r.id and s.state = 'called' and not exists (select 1 from public.sources x where x.kind = 'execution' and x.user_id = a.user_id and x.external_id = a.step_id::text)) as missing_receipts, (select count(*) from public.claims c where c.action_id = r.action_id and c.origin = 'execution') as execution_claims, (select count(*) from public.claims c where c.origin = 'execution' and not exists (select 1 from public.evidence e where e.action_id = c.action_id and e.source_id = c.source_id and e.role = 'executed')) as claims_without_evidence, (select count(*) from public.evidence e where e.action_id = r.action_id and e.role = 'executed') as executed_evidence, (select a.status from public.actions a where a.id = r.action_id) as action_status from public.execution_runs r where r.id = '<run>'"
```

| 확인 | 기대 |
|---|---|
| 산출물 `artifacts` | 1 |
| 원가 `billable_confirmed` · `unconfirmed` | 1 이상(generation id와 확정 비용이 있는 청구 대상 행) · 0. 다시 물은 시도가 있으면 청구 대상 행이 더 있다 |
| 원장 `reserve` · `settle` · `release` | 1 · 1 · 0 또는 1 (정산하고 남은 예약만 해제) |
| receipt `receipts` · `missing_receipts` | 1 · 0 (끝낸 초안마다 receipt 원문 하나, kind `execution`) |
| `execution_claims` · `executed_evidence` | 1 · 1 (그 할 일에 앞선 실행이 없을 때. Claim origin은 `execution`, field `artifact`, `user`가 아니다) |
| `claims_without_evidence` | 0 (실행 Claim마다 같은 receipt 원문의 `executed` 근거가 있다. 원문 · 인용이 null인 실행 Claim은 DB 제약이, 빈 인용은 `write_execution_receipt`가 막는다) |
| `action_status` | 실행 전과 같음(`open`): 초안은 완료가 아니다 |

`unconfirmed`가 0이 아니면 정산이 보류된 것이다(`settle` 0, 예약 유지). 하루 안이면 sweep이 확정하고, 지나면 9-4 "미확정 원가 정하기". `missing_receipts`가 0이 아니면 1분 안에 sweep이 이어 쓴다(9-4 receipt 점검).

---

## GO LIVE 체크리스트

기준: GO_LIVE.md "go live의 정의" — TestFlight 공개 링크 + 웹사이트를 여는 날부터 테스터가 1단계 연동(Notion · Google · Slack)을 앱에서 직접 연결하고 아무것도 넣지 않아도 할 일이 채워진다.
**오래 걸리는 외부 일정을 맨 위에 둔다.** 이것부터 시작해야 go live 날짜가 코드가 아니라 심사에 묶이지 않는다.

### 1) 오래 걸리는 외부 일정 (먼저 시작)

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| L1 | 웹사이트 교체 배포 (처리방침 · 약관 포함, 브랜치 `website/taskforce-new`) | 사용자 ✅ (2026-09-29, songch9511/taskforce #18 · #19. 이전 앱 링크는 감수, 배포 뒤 확인 7장 · `check-seo.mjs` 통과) | `www.taskforcelabs.dev/en/privacy`에 새 방침, 홈에서 링크, 쿠키 · 분석 없음. 이전 Mac 앱의 `/en/login` · `/en/account` 링크가 끊기는 것을 감수하거나 먼저 처리 | W1, W2 |
| L2 | Search Console 도메인 인증 | 사용자 ✅ (2026-09-28, `daniel@taskforcelabs.dev`) | Search Console에 `taskforcelabs.dev` "확인됨" | Google Workspace Owner 계정 |
| L3 | Google 프로젝트 A 설정 + 브랜드 심사 | 사용자 ✅ (2026-09-29, `taskforce-510108` In production, 브랜딩 자동 인증 · 게시. 범위는 `openid` · `email`만, 민감 범위는 L4에서) | "Brand verified" | L1, L2 |
| L4 | Google 프로젝트 A 민감 범위 심사 제출 (Calendar · Meet) | 사용자 | 제출 확인 메일 → 통과 (추정 10 영업일) | L3, C4, 영상 A (`google-verification.md` 5장) |
| L5 | Google 프로젝트 B Testing + 테스트 사용자 등록 (Gmail) | 사용자 ✅ (2026-09-29: `taskforce-gmail-beta` Testing, 범위 3개, 클라이언트 · `GMAIL_*` env, 테스트 사용자 등록. 2026-09-30: `GMAIL_CONNECT_ENABLED=true` 뒤 첫 연결의 동기화가 `Gmail 요청 실패 (403)` — **운영 프로젝트 B에 Gmail API를 켜지 않았었다**(dev 프로젝트에만 켬). API 및 서비스 → Gmail API → 사용으로 고친 뒤 메일 13통 처리 확인. 프로젝트 A(`taskforce-510108`)는 Calendar API · Meet REST API가 켜져 있음을 같은 날 확인. 새 Google 프로젝트를 만들면 쓰는 API를 먼저 켠다. 테스트 사용자: `daniel@taskforcelabs.dev` · `songch9511@gmail.com` · `songch9511@dimension.company`) | 등록한 테스터가 Gmail 연결 성공 | L1, C4, I3 |
| L6 | Google 프로젝트 B 제한 범위 심사 + CASA | 사용자 (평가기관 계약 · 결제 포함) | 심사 통과 · LOA. **go live 조건 아님** (Testing으로 go live, 통과 뒤 7일 재연결 해제) | L5, 영상 B, Google의 CASA 요청 |
| L7 | Slack 앱 생성 · 이벤트 URL 확인 · 공개 배포 | 사용자 ✅ (2026-09-29, `A0C584MQJV7`, 공개 배포 켬) | "Public distribution is active", 다른 워크스페이스에서 설치 성공(남음) | I3, C5 (`slack-app.md` 9장) |
| L8 | TestFlight 외부 테스트 심사 | 사용자 | 베타 앱 심사 통과 | C6, C2, I1~I5, 데모 계정 (`app-store.md` 7장) |
| L9 | 법률 검토 → **자체 검토로 대신** ([self-review.md](../legal/self-review.md)) | 사용자 ✅ (2026-09-29 결정표) | 결정표대로 문안을 고치고 상자를 지움. 변호사 검토는 유료화 · Marketplace · Google 민감 범위 심사 전 | W2 초안 |

### 2) 인프라 · 계정 설정

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| I1 | Vercel 프로젝트 (Pro 팀 `songch9511s-projects`) | 사용자 ✅ (2026-09-28) | Production 배포 성공, 리전 `syd1` | — |
| I2 | 환경변수 전부 (2장 표) | 사용자 ✅ 1차 (2026-09-28, Google · Slack 값은 L3 · L5 · L7 뒤). 2026-09-29 `GOOGLE_*` · `GMAIL_*` 추가(C4 배포 때 반영) | 표의 모든 값이 Production에 있음, 재배포 | 각 키 발급(I6~I9, L3, L5, L7) |
| I3 | 도메인 `api.taskforcelabs.dev` | 사용자 ✅ (2026-09-28) | 인증 없는 요청에 401 | I1 |
| I4 | 운영 DB 마이그레이션 적용 | 코드(명령 준비) → **사용자**(승인 · 실행) | 4장 읽기 쿼리로 새 테이블 확인 | C1, C3~C5의 마이그레이션 |
| I5 | Supabase Auth URL · Apple 제공자 | 사용자 ✅ 설정 (2026-09-28, 운영 서버로 앱 로그인 확인 남음) | 운영 서버로 앱 로그인 성공 | I3 |
| I13 | Sign in with Google: 프로젝트 A iOS 클라이언트 · Supabase Google 제공자 (5장 "Sign in with Google" 1 · 2) | 사용자 ✅ 설정 (2026-09-30, 실기기 로그인 · 계정 삭제 확인 남음) | TestFlight 빌드에서 Google 로그인 성공, 계정 삭제 뒤 Google 서드파티 앱 목록에서 사라짐 | L3 |
| I6 | Notion 연결 설정에 운영 redirect 추가 | 사용자 ✅ 설정 (2026-09-28, 앱에서 연결 확인 남음) | 앱에서 Notion 연결 → 앱으로 복귀 → 동기화 | I3, C1 |
| I7 | APNs 키 | 사용자 ✅ 키 · env (2026-09-28, PR #4 배포 뒤 기기 수신 확인 남음) | TestFlight 기기에서 알림 수신 | I2 |
| I8 | Sign in with Apple 키 | 사용자 ✅ (2026-09-28) | `APPLE_*` 4개가 env에 있음 | — |
| I9 | OpenRouter 운영 키 · 로깅 꺼짐 · 사용 한도 | 사용자 ✅ (2026-09-28: 한도 $10, 계정 Privacy에서 ZDR 필수 · 학습 엔드포인트 모두 끔. 키 만료 2027-03-24). **2026-09-30: 로컬 · eval과 같이 쓰던 키가 한도 $10에 닿아 모든 AI 호출이 403 → 키를 나눴다 ✅.** 운영 `taskforce-prod`(하루 $5, Vercel Production · Preview, 다시 배포 뒤 앱 물어보기로 이 키만 쓰이는 것 확인), 개발 "Default key"(누적 $20, `.env.local` · eval). **운영 키 만료 2027-09-30 전에 새 키로 바꾼다.** 두 키가 같은 계정 크레딧에서 빠지므로 크레딧 잔액 · 자동 충전도 본다) | 설정 화면에서 확인 | — |
| I10 | Supabase Free · 백업 없음 확인 | 사용자 ✅ (2026-09-29, 처리방침 게시 전 확인) | Billing · Backups 화면 확인 (4장) | — |
| I11 | Cron 동작 | 사용자 | `/api/cron/sync` 15분마다 200, `/api/cron/retry-sources` 매시 7분 · 37분 200, `/api/cron/reminders` 09:00 KST 200, `/api/cron/retention` 03:30 KST 200, `/api/cron/execution-sweep` 1분마다 200 | I1, I2 |
| I12 | 운영 계정 2단계 인증 (Vercel · Supabase · GitHub · Google · Apple · Slack · Notion · OpenRouter) | 사용자 | 모두 켜짐 (처리방침 9장 약속) | — |

### 3) 코드

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| C1 | 연결 틀 · 서명된 state · 동의 API · 연결 요청 · 계정 삭제 시 연동 토큰 폐기 (트랙 2-1) | 코드 ✅ (2026-09-28) | 단위 · RLS 테스트 통과 (state 정상 · 변조 · 만료 · 재사용 · 다른 사용자, 동의 없으면 처리 안 함) | — |
| C2 | 계정 삭제 시 Sign in with Apple 토큰 폐기 (서버 `src/lib/apple/sign-in.ts`, 앱은 Apple 로그인이 붙은 계정만 삭제 전에 authorization code를 보낸다 `apple/Taskforce/Shared/AccountDeletion.swift` · `AccountDeletionPlan`) | 코드 ✅ (실기기 확인 남음) | 앱이 `apple_authorization_code`를 보내는 테스트 통과, 실기기에서 Apple ID 목록에서 사라짐 (`app-store.md` 6장) | I8 |
| C3 | 물어보기 `POST /api/v1/ask` (트랙 2-2) | 코드 ✅ | 인용 기계 검증 · 근거 없으면 "모른다" 테스트, ask 골든셋 eval | C1 |
| C4 | Google 연동: Calendar · Meet 전사 · Gmail (트랙 2-3, 계획 [google-integration.md](google-integration.md)) | 코드 ✅ (2026-09-30: Gmail #25 · #27 · #31, Calendar · Meet #30 · #36, 운영 배포. 운영 DB에 `20261015` · `20261016` · `20261017` 적용). 남은 것: 녹화한 Meet 회의로 dev 확인(google-integration.md 9장), PR 5b(처리방침 Calendar · Meet 문장 · 전체 검증), 처리방침 재게시 뒤 `GMAIL_CONNECT_ENABLED`, 심사 뒤 `GOOGLE_CONNECT_ENABLED` | 메일 · Meet 골든셋 eval 기록, `invalid_grant` → `reauth` + 재연결 안내, 처리방침 3장 Google · Gmail 문장과 구현 값 일치 | C1 |
| C5 | Slack 연동: OAuth + Events API (트랙 2-4, 계획 [slack-integration.md](slack-integration.md)) | 코드 ✅ (2026-09-29, PR 1~4. dev 워크스페이스에서 시나리오 2 · 연결 끊기 확인) | 서명 검증 · 버리는 규칙 테스트, Slack 골든셋(핵심 시나리오 2) eval, 권한이 처리방침 3장과 일치. 운영에서 남은 확인은 아래 "Slack 켜기" | C1 |
| C6 | 앱: iPhone 한 화면 · Mac 런처 · 연결 · AI 동의 화면 · 계정 메뉴(Connections · AI data · Privacy Policy · Sign out · Delete account) · 데모 로그인 (트랙 3) | 코드 ✅ (Mac E2E 2026-09-28, 로컬 서버) | 시뮬레이터 · Mac E2E: 로그인 → 동의 → Notion 연결(앱 복귀) → 할 일 → 체크 · Review 확정 | C1, 데모 로그인 결정 |
| C7 | 모델 공급자 고정 (`provider.only`) | 코드 ✅ (`src/lib/ai/providers.ts`) | 처리방침 7장 표에 공급자 · 국가를 적음(`docs/legal/README.md` 결정 1, 해결됨). 남은 것: TypeSafe 소재지 서면 확인 | — |
| C8 | 보안 헤더 (`next.config.ts`) | 코드 ✅ | HSTS · CSP 등 응답 헤더 확인. 모든 응답에 HSTS(2년, 하위 도메인) · nosniff · Referrer-Policy · X-Frame-Options DENY · Permissions-Policy · COOP를 붙이고, CSP는 화면이 `default-src 'self'`(Next 인라인 스크립트 때문에 `'unsafe-inline'` 허용) · API가 `default-src 'none'`이며 X-Powered-By는 끔 (`tests/next-config-headers.test.ts`) | — (CASA 준비에도 필요) |
| C10 | 앱 알림: 권한 요청 · 기기 토큰 등록(`POST /api/v1/devices`) · 알림을 누르면 해당 할 일로 (Phase A3) | 코드 ✅ (App ID Push 기능 · APNs 키 뒤 실기기 확인 남음) | TestFlight 기기에서 확인 요청 알림 수신 → 눌러서 앱이 열림 | I7 |
| C11 | 첫 동기화 경험: 연결 직후 진행 표시("Syncing…"), 동기화 중 Sync Now 안내, 끝나면 목록 갱신 | 코드 ✅ | 새 계정으로 Notion 연결 → 진행 표시 → 몇 분 뒤 할 일이 뜸, 중간에 Sync Now를 눌러도 오류가 아닌 안내 | C1 |
| C12 | CI에 Swift 테스트 · iOS · macOS 빌드 추가 | 코드 ✅ | PR마다 `swift test`와 두 빌드가 돈다 (macOS 러너) | — |
| C9 | 전체 검증 | 코드 | `npm run lint && npm run typecheck && npm run test && npm run eval` 통과, 숫자를 커밋에 기록. `swift test` 통과, iOS · macOS 빌드 경고 0 | C1~C8 · C10~C12 |

### 4) 문서 · 게시

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| W1 | 웹사이트 코드 (원페이지 + 처리방침 · 약관 렌더) | 코드 ✅ (2026-09-29, 테스트 29개 · build · Preview 확인) | Side Kick 사이트 `npm run build && npm test`, Preview에서 확인 | — |
| W2 | 처리방침 · 약관 확정 | 사용자 ✅ (2026-09-29 게시, 시행일 2026-09-29. Google 줄은 C4 전 게시 예외, `docs/legal/README.md` "게시 기록") | 자리표시자(시행일) 채움, 자체 검토 결정 반영(전화 · 모델 공급자 연락처는 채움), `docs/legal/README.md` 구현 대조표의 게시 조건 모두 끝 | C1~C7, L9(자체 검토) |
| W3 | 웹사이트 맥락 문단을 회의록 · Slack · 메일로 넓히기 | 사용자(카피) ✅ (2026-09-29, BRAND.md · 사이트) | BRAND.md "맥락 문단은 아직 Notion 기준" 해소 | — |
| W4 | 스토어 · TestFlight 문구 | 사용자 | `app-store.md` 2장 값 입력 | — |

### 5) go live 당일

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| G1 | 실기기 끝까지 확인 | 사용자 | 새 계정으로: 설치 → 로그인 → 동의 → Notion · Google · Slack 연결 → 다음 회의 · 메시지 뒤 할 일 생성 → 알림 → 체크. Gmail은 테스트 사용자로 한 번 | 모든 C · I, L4(또는 A도 Testing), L7, L8 |
| G2 | TestFlight 공개 링크를 웹사이트 CTA에 | 사용자 | 사이트 CTA가 공개 링크로 열림, 테스터 한도 100 | L1, L8, G1 |
| G3 | 테스터 안내 | 사용자 | Gmail 초대 방법(주소를 `privacy@`로), 7일 재연결, Slack은 연결 뒤 메시지부터 | G2 |
| G4 | 첫 2주 관찰 | 사용자 | `/admin/metrics`에서 지표 1~5와 서비스별 "Want this" 수를 주 1회 기록 | G2 |
