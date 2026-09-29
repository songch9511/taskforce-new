# go live 런북

관련 문서: [go live](../GO_LIVE.md) · [Google 심사](google-verification.md) · [Slack 앱](slack-app.md) · [App Store](app-store.md) · [법률 문서](../legal/README.md) · [연동](../INTEGRATIONS.md)

작성: 2026-09-27. 서버 배포부터 TestFlight 공개 링크까지, 무엇을 어떤 순서로 하는지 적는다. **맨 아래 [GO LIVE 체크리스트](#go-live-체크리스트)가 기준표**이고, 위 장들은 그 항목의 자세한 방법이다.
"사용자"는 계정 · 결제 · 외부 공개처럼 코드로 대신할 수 없는 일, "코드"는 이 저장소의 변경으로 끝나는 일이다.

## 0. 대상 한눈에

| 항목 | 값 | 2026-09-27 상태 |
|---|---|---|
| 서버 | Vercel **Pro 팀 `songch9511s-projects`**, 새 프로젝트(예: `taskforce-api`), GitHub `songch9511/taskforce-new`의 `main` | 프로젝트 없음 (저장소에 `.vercel` 링크 없음) |
| 리전 | `syd1` (`vercel.json`) | 설정됨 |
| API 도메인 | `api.taskforcelabs.dev` | DNS는 Vercel을 가리키지만 붙은 프로젝트가 없어 404 |
| DB · 인증 | Supabase 프로젝트 `Taskforce-new` (ref `tirtdojsahotjfgdsryi`, Vercel 연동 조직), 시드니 `ap-southeast-2` | 운영 중. 마이그레이션 기록이 비어 있음(4장) |
| 웹사이트 | `www.taskforcelabs.dev` (apex는 www로 308), `Side Kick/apps/website`의 별도 Vercel 프로젝트 | 이전 제품(Side Kick, iad1 · Codex) 기준 내용 |
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
| `OPENROUTER_API_KEY` | openrouter.ai → Keys. 운영용 키를 따로 만들고 사용 한도를 건다 | 한도가 있으면 `max_tokens`를 꼭 보낸다(llm.ts 주석) |
| `LLM_MODEL` | `z-ai/glm-5.3-flash` (지금 `.env.local`, eval 기준) | 바꾸면 eval을 다시 돌린다 |
| `JEV_MODEL` | `typesafe/jev-1.13` | 버전 고정 |
| `EMBEDDING_MODEL` | 비움 → `openai/text-embedding-3-small` | 1536차원이어야 한다 |
| `LLM_PROVIDERS` · `EMBED_PROVIDERS` · `JEV_PROVIDERS` | 비움 (선택) → 기본값 `src/lib/ai/providers.ts`: LLM `together,fireworks,deepinfra,baseten` · 임베딩 `azure` · Jev `typesafe` | ZDR · 학습 금지 공급자 고정 목록(쉼표 구분). 처리방침 7장 표와 맞춘다(`docs/legal/README.md` 결정 1) |
| `CONNECTOR_TOKEN_KEY` | `openssl rand -base64 32` | **운영 DB에 이미 저장된 연결 토큰을 암호화한 키와 같아야 한다.** 로컬 `.env.local` 값으로 운영 DB에 연결을 만들었다면 같은 값을 넣고, 새 키를 쓰면 기존 연결은 다시 연결해야 한다 |
| `CRON_SECRET` | `openssl rand -hex 32` | Vercel Cron이 `Authorization: Bearer`로 보낸다. 없으면 cron이 401 |
| `OAUTH_STATE_SECRET` | `openssl rand -hex 32` | 32자 이상(`env.ts`의 `oauthStateSecret`) |
| `NOTION_CLIENT_ID` · `NOTION_CLIENT_SECRET` | notion.so/profile/integrations → Taskforce(Public) | |
| `NOTION_REDIRECT_URI` | `https://api.taskforcelabs.dev/api/connectors/notion/callback` | Notion 설정의 Redirect URI와 글자까지 같게 |
| `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET` | Google 프로젝트 A 클라이언트 (`google-verification.md` 9장 6번) | 새 값 |
| `GMAIL_CLIENT_ID` · `GMAIL_CLIENT_SECRET` | Google 프로젝트 B 클라이언트 (9장 8번) | 새 값 |
| `GOOGLE_REDIRECT_URI` · `GMAIL_REDIRECT_URI` | `https://api.taskforcelabs.dev/api/connectors/google/callback` · `…/gmail/callback` | 코드가 Notion처럼 env로 받으면 넣는다 |
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
npx supabase db query --linked -f supabase/migrations/20261014000000_connections_server_delete.sql   # 앱의 연결 직접 삭제 정책 지우기. 서버 권한 끊기 코드를 배포한 **뒤에**
# 트랙 2-3 · 2-4가 더한 파일도 같은 방식으로
```

### Auth 설정

Supabase → Authentication:

| 설정 | 값 |
|---|---|
| URL Configuration → Site URL | `https://api.taskforcelabs.dev` |
| Redirect URLs | `https://api.taskforcelabs.dev/auth/confirm`, `http://localhost:3000/auth/confirm` |
| Sign In / Providers → Apple | 켬, Client IDs `dev.taskforcelabs.taskforce` (앱 안 로그인만이면 Services ID · Secret 불필요, PLATFORMS.md 6장) |
| Providers → Email | 웹 관리 화면의 링크 로그인용 + App Store 심사용 비밀번호 로그인으로 켬. 새 가입은 막지 않는다 — 허용 목록은 아래 Hooks가 대신 막는다 |
| Hooks → Before User Created | Postgres function `public.hook_before_user_created` → **Enable** (마이그레이션 `20261007000000_review_account_signup_hook.sql`). `provider = email`로 가입하는 주소가 `review_accounts`에 없으면 403으로 거절한다. Apple 가입에는 영향 없다(`docs/go-live/app-store.md` 3장) |
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
- **URL scheme:** `taskforce`가 `apple/Taskforce/Info.plist`에 등록되어 있다. OAuth 복귀(`taskforce://connections/{provider}?handoff=<id>`, `src/lib/connectors/callback.ts`)가 이걸로 앱에 돌아온다. callback은 code를 암호화한 완료 대기(handoff, 2분)로 남기고 이 주소로 보낼 뿐이고, 앱이 그 `handoff`로 `POST /api/v1/connections/{provider}/complete`(Bearer 토큰)를 불러야 연결이 끝난다(시작한 사용자만, 한 번만). 릴리스 빌드에서도 URL scheme이 빠지지 않았는지 확인한다.

## 6. Cron 확인

`vercel.json`: `/api/cron/sync` 15분마다, `/api/cron/reminders` 매일 00:00 UTC(한국 09:00), `/api/cron/retention` 매일 18:30 UTC(한국 03:30, 원문 90일 보관 정리 · `src/lib/retention.ts`).

1. 배포 뒤 Vercel → 프로젝트 → Settings → Cron Jobs에 세 개가 보이는지.
2. Logs에서 `/api/cron/sync`가 15분마다 200인지. 401이면 `CRON_SECRET`이 없거나 다르다.
3. 다음 날 09:00 KST에 `/api/cron/reminders`가 200인지(기한 임박 알림).
4. 다음 날 03:30 KST에 `/api/cron/retention`이 200이고 `{ sources_purged, judge_logs_deleted }`를 돌려주는지(처리방침 5장 "90일" 약속).
5. 동의하지 않은 사용자의 연결은 동기화에서 건너뛴다(`registry.ts`의 `withoutConsent`). 테스트 계정으로 동의 전 · 후를 한 번씩 본다.

## 7. 웹사이트 배포

대상: Side Kick 저장소 `apps/website`(Next 16, `[lang]` 라우팅). 새 사이트는 브랜치 **`website/taskforce-new`**에 이미 만들어져 있고 **아직 배포하지 않았다**(2026-09-27).

1. `/privacy` · `/terms`는 `/en/privacy` · `/en/terms`로 리디렉트한다. 법률 markdown은 실시간 렌더가 아니라 **`apps/website/scripts/sync-legal.mjs`가 이 저장소의 `docs/legal/*.md`를 복사**해 둔다(원본은 여전히 `docs/legal/`, 고칠 때마다 스크립트를 다시 돌려 동기화한다).
2. 이전 제품 페이지(download · pricing · account · beta · login · updates · help)는 홈으로 리디렉트. **예외: 이전 Mac 앱이 아직 `/en/login` · `/en/account`를 쓰고 있어, 이 배포를 올리면 그 링크가 끊긴다.** 이전 제품을 은퇴시킬지(안내 후 링크를 유지하거나 이전 앱에 새 배포 안내를 넣는 등)를 배포 전에 정한다. 이전 OAuth 브로커(`/api/connections/*`)는 이번 배포에서도 그대로 둔다.
3. 홈 푸터: Privacy · Contact(`privacy@taskforcelabs.dev`). 홈에 Google Limited Use 문장 한 줄.
4. 분석 도구 · 쿠키 없음 확인: `curl -sI https://www.taskforcelabs.dev | grep -i set-cookie`가 비어야 하고, 페이지에 분석 스크립트가 없어야 한다.
5. `npm run build && npm test` → Preview 배포에서 확인 → **사용자 승인 뒤** Production.
6. 끝: `https://www.taskforcelabs.dev/en/privacy`에 새 처리방침이 보이고, `docs/legal/README.md`의 게시 규칙(자리표시자 · 상자 없음)을 지킨다.
7. TestFlight CTA 링크는 go live 날 넣는다(체크리스트 G2). 그 전에는 CTA를 숨기거나 "Coming soon"으로 둔다.

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

---

## GO LIVE 체크리스트

기준: GO_LIVE.md "go live의 정의" — TestFlight 공개 링크 + 웹사이트를 여는 날부터 테스터가 1단계 연동(Notion · Google · Slack)을 앱에서 직접 연결하고 아무것도 넣지 않아도 할 일이 채워진다.
**오래 걸리는 외부 일정을 맨 위에 둔다.** 이것부터 시작해야 go live 날짜가 코드가 아니라 심사에 묶이지 않는다.

### 1) 오래 걸리는 외부 일정 (먼저 시작)

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| L1 | 웹사이트 교체 배포 (처리방침 · 약관 포함, 브랜치 `website/taskforce-new`) | 코드(사이트 준비, 끝남) → **사용자**(이전 제품 은퇴 결정 · 배포 승인) | `www.taskforcelabs.dev/en/privacy`에 새 방침, 홈에서 링크, 쿠키 · 분석 없음. 이전 Mac 앱의 `/en/login` · `/en/account` 링크가 끊기는 것을 감수하거나 먼저 처리 | W1, W2 |
| L2 | Search Console 도메인 인증 | 사용자 | Search Console에 `taskforcelabs.dev` "확인됨" | Google Workspace Owner 계정 |
| L3 | Google 프로젝트 A 설정 + 브랜드 심사 | 사용자 | "Brand verified" | L1, L2 |
| L4 | Google 프로젝트 A 민감 범위 심사 제출 (Calendar · Meet) | 사용자 | 제출 확인 메일 → 통과 (추정 10 영업일) | L3, C4, 영상 A (`google-verification.md` 5장) |
| L5 | Google 프로젝트 B Testing + 테스트 사용자 등록 (Gmail) | 사용자 | 등록한 테스터가 Gmail 연결 성공 | L1, C4, I3 |
| L6 | Google 프로젝트 B 제한 범위 심사 + CASA | 사용자 (평가기관 계약 · 결제 포함) | 심사 통과 · LOA. **go live 조건 아님** (Testing으로 go live, 통과 뒤 7일 재연결 해제) | L5, 영상 B, Google의 CASA 요청 |
| L7 | Slack 앱 생성 · 이벤트 URL 확인 · 공개 배포 | 사용자 | "Public distribution is active", 다른 워크스페이스에서 설치 성공 | I3, C5 (`slack-app.md` 9장) |
| L8 | TestFlight 외부 테스트 심사 | 사용자 | 베타 앱 심사 통과 | C6, C2, I1~I5, 데모 계정 (`app-store.md` 7장) |
| L9 | 법률 검토 (국내 개인정보 변호사) | 사용자 | `docs/legal/README.md` 검토 항목에 답을 받고 처리방침의 "법률 검토 필요" 상자를 지울 수 있음 | W2 초안 |

### 2) 인프라 · 계정 설정

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| I1 | Vercel 프로젝트 (Pro 팀 `songch9511s-projects`) | 사용자 | Production 배포 성공, 리전 `syd1` | — |
| I2 | 환경변수 전부 (2장 표) | 사용자 | 표의 모든 값이 Production에 있음, 재배포 | 각 키 발급(I6~I9, L3, L5, L7) |
| I3 | 도메인 `api.taskforcelabs.dev` | 사용자 | 인증 없는 요청에 401 | I1 |
| I4 | 운영 DB 마이그레이션 적용 | 코드(명령 준비) → **사용자**(승인 · 실행) | 4장 읽기 쿼리로 새 테이블 확인 | C1, C3~C5의 마이그레이션 |
| I5 | Supabase Auth URL · Apple 제공자 | 사용자 | 운영 서버로 앱 로그인 성공 | I3 |
| I6 | Notion 연결 설정에 운영 redirect 추가 | 사용자 | 앱에서 Notion 연결 → 앱으로 복귀 → 동기화 | I3, C1 |
| I7 | APNs 키 | 사용자 | TestFlight 기기에서 알림 수신 | I2 |
| I8 | Sign in with Apple 키 | 사용자 | `APPLE_*` 4개가 env에 있음 | — |
| I9 | OpenRouter 운영 키 · 로깅 꺼짐 · 사용 한도 | 사용자 | 설정 화면에서 확인 | — |
| I10 | Supabase Free · 백업 없음 확인 | 사용자 | Billing · Backups 화면 확인 (4장) | — |
| I11 | Cron 동작 | 사용자 | `/api/cron/sync` 15분마다 200, `/api/cron/reminders` 09:00 KST 200, `/api/cron/retention` 03:30 KST 200 | I1, I2 |
| I12 | 운영 계정 2단계 인증 (Vercel · Supabase · GitHub · Google · Apple · Slack · Notion · OpenRouter) | 사용자 | 모두 켜짐 (처리방침 9장 약속) | — |

### 3) 코드

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| C1 | 연결 틀 · 서명된 state · 동의 API · 연결 요청 · 계정 삭제 시 연동 토큰 폐기 (트랙 2-1) | 코드 ✅ (2026-09-28) | 단위 · RLS 테스트 통과 (state 정상 · 변조 · 만료 · 재사용 · 다른 사용자, 동의 없으면 처리 안 함) | — |
| C2 | 계정 삭제 시 Sign in with Apple 토큰 폐기 (서버는 `src/lib/apple/sign-in.ts`로 구현됨, 앱이 삭제 전에 authorization code를 보내는 일이 남음) | 코드 ✅ 코드 (실기기 확인 남음) | 앱이 `apple_authorization_code`를 보내는 테스트 통과, 실기기에서 Apple ID 목록에서 사라짐 (`app-store.md` 6장) | I8 |
| C3 | 물어보기 `POST /api/v1/ask` (트랙 2-2) | 코드 ✅ | 인용 기계 검증 · 근거 없으면 "모른다" 테스트, ask 골든셋 eval | C1 |
| C4 | Google 연동: Calendar · Meet 전사 · Gmail (트랙 2-3) | 코드 | 메일 · Meet 골든셋 eval 기록, `invalid_grant` → `reauth` + 재연결 안내, 처리방침 3장 Google · Gmail 문장과 구현 값 일치 | C1 |
| C5 | Slack 연동: OAuth + Events API (트랙 2-4, 계획 [slack-integration.md](slack-integration.md)) | 코드 | 서명 검증 · 버리는 규칙 테스트, Slack 골든셋(핵심 시나리오 2) eval, 권한이 처리방침 3장과 일치 | C1 |
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
| W1 | 웹사이트 코드 (원페이지 + 처리방침 · 약관 렌더) | 코드 | Side Kick 사이트 `npm run build && npm test`, Preview에서 확인 | — |
| W2 | 처리방침 · 약관 확정 | 사용자 | 자리표시자(시행일 · 전화번호 · 모델 공급자) 채움, 법률 검토 상자 지움, `docs/legal/README.md` 구현 대조표의 게시 조건 모두 끝 | C1~C7, L9 |
| W3 | 웹사이트 맥락 문단을 회의록 · Slack · 메일로 넓히기 | 사용자(카피) | BRAND.md "맥락 문단은 아직 Notion 기준" 해소 | — |
| W4 | 스토어 · TestFlight 문구 | 사용자 | `app-store.md` 2장 값 입력 | — |

### 5) go live 당일

| # | 항목 | 담당 | 끝난 기준 | 먼저 필요한 것 |
|---|---|---|---|---|
| G1 | 실기기 끝까지 확인 | 사용자 | 새 계정으로: 설치 → 로그인 → 동의 → Notion · Google · Slack 연결 → 다음 회의 · 메시지 뒤 할 일 생성 → 알림 → 체크. Gmail은 테스트 사용자로 한 번 | 모든 C · I, L4(또는 A도 Testing), L7, L8 |
| G2 | TestFlight 공개 링크를 웹사이트 CTA에 | 사용자 | 사이트 CTA가 공개 링크로 열림, 테스터 한도 100 | L1, L8, G1 |
| G3 | 테스터 안내 | 사용자 | Gmail 초대 방법(주소를 `privacy@`로), 7일 재연결, Slack은 연결 뒤 메시지부터 | G2 |
| G4 | 첫 2주 관찰 | 사용자 | `/admin/metrics`에서 지표 1~5와 서비스별 "Want this" 수를 주 1회 기록 | G2 |
