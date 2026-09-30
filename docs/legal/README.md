# 법률 문서: 게시 규칙 · 구현 대조 · 검토 항목

관련 문서: [go live](../GO_LIVE.md) · [go live 런북](../go-live/runbook.md) · [Google 심사](../go-live/google-verification.md) · [Slack 앱](../go-live/slack-app.md) · [App Store](../go-live/app-store.md)

작성: 2026-09-27. 이 폴더의 문서가 개인정보 처리방침 · 이용약관의 **원본**이다. 웹사이트(`Side Kick/apps/website`, `/[lang]/privacy` · `/[lang]/terms`)는 이 파일을 렌더만 한다.

| 파일 | 내용 | 게시 주소 |
|---|---|---|
| [privacy.ko.md](privacy.ko.md) | 개인정보 처리방침 (한국어, 우선) | `https://www.taskforcelabs.dev/ko/privacy` |
| [privacy.en.md](privacy.en.md) | Privacy Policy (영어) | `https://www.taskforcelabs.dev/en/privacy` |
| [terms.ko.md](terms.ko.md) | 이용약관 (베타, 한국어, 우선) | `https://www.taskforcelabs.dev/ko/terms` |
| [terms.en.md](terms.en.md) | Terms of Use (베타, 영어) | `https://www.taskforcelabs.dev/en/terms` |
| [connector-addenda.md](connector-addenda.md) | 2단계 연동을 붙일 때 처리방침에 넣을 절 | 게시하지 않음 |

## 게시 규칙

1. `{{…}}` 자리표시자를 모두 채운 뒤에만 게시한다. 베타는 변호사 검토 대신 **자체 검토**([self-review.md](self-review.md))로 게시한다(2026-09-29 결정): 쟁점마다 결정과 남는 위험을 그 문서에 적고, 처리방침의 "법률 검토 필요" 상자는 결정대로 문안을 고친 뒤 지운다. 유료화 · 베타 대상 확대 · Marketplace · Google 민감 범위 심사 전에는 변호사 검토를 한 번 받는다.
2. 아래 [구현 대조표](#구현-대조표)에서 "게시 조건"이 끝나지 않은 문장이 있으면 게시하지 않는다. 처리방침이 코드보다 앞서면 방침이 거짓이 된다.
3. 한국어와 영어의 내용을 항상 같게 고친다. 두 판이 다르면 한국어가 우선한다(각 문서 머리에 적음).
4. 코드 · 인프라를 바꿀 때 아래 중 하나라도 바뀌면 이 폴더를 같은 PR에서 고친다: AI 호출 경로 · 모델 공급자, 호스팅 리전, Supabase 요금제(백업), 로그에 남기는 것, 새 연동 · 새 수집 항목, 분석 SDK.
5. 웹사이트 첫 화면의 개인정보 한 줄("AI calls go only to providers that keep no data. Your data stays in Sydney, and deleting your account deletes it right away.")은 처리방침의 "한눈에 보기"와 같은 약속만 쓴다(BRAND.md).

## 게시 기록

| 날짜 | 판 | 내용 |
|---|---|---|
| 2026-09-29 | 베타 1.0 (시행일 2026-09-29) | 첫 게시(runbook L1 · W2). 자체 검토(#13) 반영. **규칙 2의 예외:** 구현 대조표의 Google 줄(Calendar · Meet · Gmail, 계정 삭제 · 연결 끊기 때 Google 토큰 폐기)은 아직 구현 전(C4)이지만, Google 브랜드 · 범위 심사가 게시된 처리방침을 먼저 요구해서 게시했다(사용자 결정). Google 연결은 C4 배포 전에는 열리지 않아 그 문장이 적용되는 처리는 아직 없다. **C4를 배포하기 전에 3장 Google 문장 · 이 표의 Google 줄을 구현과 다시 맞춘다.** Supabase Free · 백업 없음은 사용자가 확인했다. **게시본의 원본:** 이 저장소 `28395ea`의 `docs/legal/{privacy,terms}.{ko,en}.md`. 웹사이트 `songch9511/taskforce` #18의 병합 커밋 `971ab5c`(2026-09-29 17:54 KST)의 `apps/website/content/legal/` 네 파일과 지금 `main`의 처리방침 두 파일이 글자까지 같음을 확인했다(2026-09-29). 이전 버전은 `git show 28395ea:docs/legal/privacy.ko.md`처럼 꺼낼 수 있다 |
| 2026-09-30 | 베타 1.1 (시행일 2026-09-30) | 재게시(웹사이트 `songch9511/taskforce` #24 병합 커밋 `9676857`, 운영 배포 확인: `/{ko,en}/privacy` 베타 1.1 · `/{ko,en}/privacy/beta-1.0` 보관본). 아래 세 변경을 한 판으로: 7장 원문 분석 공급자에서 Baseten 삭제(#24), 3장 Gmail 절을 구현대로(Google PR 5a), 재연결 알림 문장(2장 목적 표 · 1장 이용 기록 · 3장 Notion 절 · 수탁자 표의 Apple 행, Google PR 4a #27). 17장 끝에 "변경 이력"과 베타 1.0 보기 링크(`/{ko,en}/privacy/beta-1.0`, 원본 `archive/privacy.{ko,en}.beta-1.0.md` = `28395ea`의 게시본 그대로). **시행일을 게시일과 같게 했다(사용자 결정 2026-09-30):** 17장은 시행 7일 전 고지(늘어나는 수집 항목이 있으면 30일)를 약속하지만, 이날 운영 DB의 계정은 운영자 둘뿐이고 Gmail 연결은 0건이라 알릴 이용자가 없었다. 테스터를 받은 뒤의 변경은 17장대로 미리 알린다(앱 안 알림은 `src/lib/legal/policy.ts` + 앱 배너로 만드는 중). **규칙 2의 예외(베타 1.0과 같음):** 3장 Google(Calendar · Meet) 문장은 코드(PR 3 #30)가 있지만 구현에 맞춘 문장은 PR 5b에서 고친다. 운영은 `GOOGLE_CONNECT_ENABLED`가 비어 있어 일반 이용자의 google 연결이 닫혀 있다. 재연결 알림 조건(#27 배포 · 마이그레이션 `20261015000000`)은 2026-09-29 운영 배포(`e547e05`)와 `metric_events.provider` 확인(2026-09-30)으로 충족 |

### 게시 대기 (원본만 고침, 웹사이트에는 아직 없음)

원본을 고치면 여기에 적고, 시행일 · 버전은 게시하는 날 정한다([self-review.md](self-review.md) "게시 전에 채울 값"). 웹사이트의 `scripts/sync-legal.mjs`는 `privacy.{ko,en}.md` · `terms.{ko,en}.md`와 `archive/`를 복사하므로, 고친 것은 모두 다음 판에 함께 나간다. 판을 바꿀 때마다 직전 게시본을 `archive/`에 남기고 17장 "변경 이력"에 링크를 더한다. 앱 안 알림용 버전 · 시행일(`src/lib/legal/policy.ts`)도 같이 바꾼다.

| 고친 곳 | 내용 | 게시할 때 할 일 |
|---|---|---|
| 처리방침 5장 "파기 절차와 방법"의 계정 삭제 항목 (한국어 · 영어, 2026-09-30) | Apple 확인을 취소하거나 확인에 실패하면 Apple 토큰 폐기를 요청하지 못하고, 그래도 계정은 지워지며 앱이 Apple 계정 설정에서 직접 지우는 방법을 알린다는 문장을 더했다(`apple/Taskforce/Shared/AccountDeletion.swift` `revokeSkippedNote`, 아래 대조표의 Apple 줄) | 따로 재게시하지 않고 다음 판(예: PR 5b의 Calendar · Meet 문장)과 함께 낸다(사용자 결정 2026-09-30). 이미 있는 동작을 적는 것이라 17장의 "불리한 변경"으로 보이지 않지만 판단은 사용자 |

## 구현 대조표

처리방침 문장이 기대는 코드 · 설정. "구현됨"은 2026-09-27에 코드로 확인한 것이다. 같은 날 다른 작업(트랙 2 · 3)이 코드를 계속 바꾸고 있어 "진행 중" · "코드 있음" 행은 **게시 직전에 다시 확인한다.**

| 처리방침의 약속 | 근거 (코드 · 설정) | 상태 | 게시 조건 |
|---|---|---|---|
| 모든 AI 요청은 ZDR · 학습 금지 공급자에게만 | `src/lib/ai/providers.ts`의 `providerRouting()` → 모든 요청에 `data_collection: "deny"` · `zdr: true`, `llm.ts` · `jev.ts` · `embed.ts`가 그대로 씀 | 구현됨 | — |
| 모델 공급자와 국가를 7장 표에 적음 | `src/lib/ai/providers.ts`가 공급자를 고정한다: `provider: { only, order, allow_fallbacks: false }`로 아래 목록 밖으로 넘어가지 않는다(2026-09-27 [결정 1](#결정-필요), 해결됨) | 구현됨 | — |
| OpenRouter 프롬프트 로깅 꺼짐 | OpenRouter 계정 설정 (코드 아님) | 확인됨 (2026-09-28, runbook I9: ZDR 필수 · 학습 엔드포인트 끔) | — |
| 데이터는 시드니, 백업 없음 → 삭제 즉시 | `supabase/.temp/pooler-url`이 `aws-0-ap-southeast-2` (시드니). 요금제는 Free로 알려져 있으나 이 저장소에서 확인할 수 없다 | 확인됨 (2026-09-29, 사용자) | Pro로 올리면 7일 백업이 생겨 5장을 고친다 |
| 서버는 시드니 | `vercel.json`의 `"regions": ["syd1"]` | 구현됨 | 배포한 프로젝트에 설정이 적용됐는지 배포 뒤 확인(runbook) |
| 서버 요청 기록 1일 | Vercel Pro 런타임 로그 보관 1일 (Observability Plus를 켜면 30일) | 요금제 사실 | Observability Plus · 로그 드레인을 켜지 않는다. 켜면 5장을 고친다 |
| 데이터베이스 · 인증 기록 1일 | Supabase Free 로그 보관 1일 | 요금제 사실 | 위 요금제 확인과 같다 |
| 계정 삭제 시 모든 표가 함께 지워짐 | `src/app/api/v1/account/route.ts` → `auth.admin.deleteUser`, 모든 사용자 표가 `auth.users`에 `on delete cascade`. `tests/db/account-deletion.test.ts` | 구현됨 | 배포 뒤 실제 Supabase에서 한 번 실행(GO_LIVE.md 2장) |
| 원문 글자는 저장 후 90일 뒤 지움 (근거 인용 · 할 일 · 제목 · 링크 · 관련자는 남음. Slack 연결 끊기 · 앱 제거는 아래 줄) | `src/lib/retention.ts`(`RAW_TEXT_RETENTION_DAYS = 90`), `/api/cron/retention`이 매일 `purge_expired_source_text`를 불러 `sources.raw_text`를 비우고(`raw_text_purged_at` 기록), 90일 지난 `judge_logs`(후보 구절 포함)를 지운다(마이그레이션 20261006000000) | 구현됨 | 배포 뒤 cron이 매일 도는지 확인(runbook) |
| 계정 삭제 시 Sign in with Apple 토큰 폐기 | 서버: `src/lib/apple/sign-in.ts`(client secret JWT → `/auth/token` → `/auth/revoke`), `DELETE /api/v1/account`가 삭제 전에 부름, 본문 `apple_authorization_code`(선택). 앱은 삭제 확인 때 Sign in with Apple을 한 번 더 받아 code를 보낸다(`apple/Taskforce/Shared/AccountDeletion.swift` `AppleReauthorization.authorizationCode()` → `APIClient.deleteAccount(authorizationCode:)`, `APIClientTests`). Apple 확인을 취소하거나 실패하면 폐기 없이 삭제하고, 로그인 화면에 설정 › Apple 계정 › Apple로 로그인에서 직접 지우는 방법을 한 줄로 알린다(`AccountDeletion.revokeSkippedNote`) | 구현됨 (2026-09-30 코드 확인, 실기기 확인 남음) | `APPLE_*` env(runbook I8 ✅) + TestFlight 기기에서 삭제 뒤 Apple ID의 앱 목록에서 사라지는지 (`docs/go-live/app-store.md` 6장). 취소 · 실패 때는 폐기를 요청하지 않는다: 5장에 이 경우를 적었다(위 "게시 대기", 다음 판에 게시) |
| 계정 삭제 시 연결 서비스 토큰 폐기 | `src/lib/connectors/registry.ts`의 `revokeConnectorTokens`(`src/lib/api/account.ts`가 삭제 전에 부르고, 실패해도 삭제는 계속한다): Notion `POST /v1/oauth/revoke`, Slack `auth.revoke`(`slackConnector.revokeToken`, 2026-09-29), Gmail `POST https://oauth2.googleapis.com/revoke`(`gmailConnector.revokeToken` → `revokeGoogleToken`, `src/lib/connectors/google/oauth.ts`: 갱신 토큰이 있으면 그것으로 폐기해 그 프로젝트에 준 허용 전체를 거두고, 이미 폐기된 토큰의 400 `invalid_token`은 성공으로 본다. 단위 테스트 `gmail/run.test.ts`) | 구현됨 (Gmail #25 · google 연결(Calendar · Meet) PR 3 #30 `googleConnector.revokeToken`) | PR 5b에서 google 연결 폐기를 한 번 더 확인 |
| 동의 전에는 연결 원문을 AI로 보내지 않음 · 철회 가능 | `supabase/migrations/20261003000000_go_live_connections_consent.sql`의 `profiles.ai_consent_at`, `src/lib/api/consent.ts`(POST · DELETE `/api/v1/consent`, 동의 없으면 409), 연결 시작 · 동기화 · 원문 보내기 · 물어보기가 동의를 확인, `registry.ts`가 동의 없는 사용자의 연결을 건너뜀. 앱: `apple/Taskforce/Shared/AccountViews.swift`의 동의 · 철회 화면 | 코드 있음 (작업 중, 배포 전) | 서버 배포 + 운영 DB 마이그레이션 + 앱 빌드. 동의 화면 문구가 처리방침 4장 · `app-store.md` 5장과 같은지 확인. **결정 (go live 전):** go live 전에 앱을 써본 이용자도 새 버전에서 앱 안 동의 화면을 한 번 통과해야 한다 — 서버가 계정을 나누거나 새 API 버전을 만들지 않고, 지금 v1의 동의 확인(409)이 그대로 그 화면을 띄운다 |
| 연결 끊기 → 토큰 즉시 삭제 · 서비스에 폐기 요청, Notion · Google 원문 · 할 일은 남음 | `DELETE /api/v1/connections/:id` → `handleConnectionDelete`(`src/lib/api/connections.ts`): 서버 권한으로 서비스 토큰 폐기(`Connector.revokeToken`: Notion · Slack · Gmail. Gmail은 갱신 토큰으로 폐기해 그 프로젝트에 준 허용 전체를 거둔다. **google 연동(Calendar · Meet)은 붙일 때 `revokeToken`을 구현해야 3장 문장이 맞다**) → `disconnect_connection`(연결 행 삭제, `connection_secrets` cascade, `sources.connection_id`는 `on delete set null`). 앱이 연결 행을 직접 지우는 정책은 `20261014000000`에서 지운다 | 구현됨 (2026-09-29 배포, `20261014000000` 적용) | — |
| Slack: 연결 끊기 · 앱 제거 → Slack 원문 본문 · 관련자 · 근거 인용 · 판정 기록 · 대기 데이터 즉시 삭제, 할 일 · 원본 링크는 남음 (3장 · 5장 · 11장) | `purge_slack_data` · `purge_slack_sources`(마이그레이션 20261013000000): `disconnect_connection` · `revoke_slack_connections`(`app_uninstalled` · `tokens_revoked` · 동기화 중 토큰 오류 · 매일 토큰 확인 `slack/health.ts`)가 부른다. 처리 도중 끊긴 원문은 `slack_repurge_if_disconnected`, 매일 `purge_slack_buffers`가 다시 지운다. `tests/db/slack-sync.test.ts`. dev 워크스페이스에서 확인(2026-09-29, `slack-integration.md` "PR 3 구현") | 구현됨 (2026-09-29 배포, 운영에서 확인) | 자체 검토([self-review.md](self-review.md) 2번) |
| Slack 대기 메시지 3일 · 추적 스레드 14일 · 이름 정보는 연결을 끊을 때까지 (5장) | `src/lib/retention.ts`(`SLACK_PENDING_RETENTION_DAYS` · `SLACK_THREAD_RETENTION_DAYS`), `/api/cron/retention` → `purge_slack_buffers`. 원문으로 묶으면 대기 행 본문을 바로 비운다(`slack/sync.ts`) | 구현됨 (2026-09-29 배포) | cron 확인(runbook I11) |
| 원문 속 다른 사람의 출처 문의 · 처리정지 · 삭제 요구에 응함 (2장) | 수동 절차 [internal-plan.md](internal-plan.md) 6장 | 운영 규칙 | 요청이 잦아지면 서버 기능 |
| 앱에서 지운 할 일은 "지움" 상태로 남음 | `DELETE /api/v1/actions/:id`가 `dropped` + `user_deleted` 이벤트 | 구현됨 | — |
| 서버 기록에 원문 · 토큰 · 코드 없음 | 모든 `console.error`가 오류 메시지와 id만 남긴다. `processing_summary` · `processing_error` · `last_error`에 원문을 넣지 않는다(마이그레이션 주석) | 구현됨 (규칙) | 새 코드도 같은 규칙. 로그 드레인 없음 |
| 잠금 화면 알림에 할 일 제목 없음. 알림 문구는 서버가 정한 짧은 영어뿐(확인 요청 "Review", 기한 "Due today" · "Due tomorrow" + 할 일 개수). 재연결 알림은 서비스 이름이 든 문구뿐이고 할 일 식별자도 없음 (수탁자 표의 Apple 행) | `src/lib/notify/apns.ts`: 확인 요청 · 기한 알림은 짧은 영어 문구 + `mutable-content: 1` + `action_id`(`confirmationPayload` `:106-112`, 문구 `:108`, `duePayload` `:114-125`, 문구 `:118-122`), 재연결 알림은 "Reconnect Gmail to keep syncing." 같은 문구 + `kind: "reconnect"`뿐(`reconnectPayload` `:128-133`, 문구 `:130`, 서비스 이름 `notify/service.ts:53`) | 구현됨 (재연결 알림은 #27, 2026-09-29 운영 `e547e05`) | 앱의 Notification Service Extension |
| Apple에서 이름을 받지 않음 | `apple/Taskforce/Shared/SignIn.swift`의 `requestedScopes = [.email]` | 구현됨 | 로그인 화면을 바꿔도 이메일만 요청 |
| Notion: 콘텐츠 읽기만, 녹음 전사 · 이미지 제외, 한 건 20만 자 | INTEGRATIONS.md Notion 절, `connectors/notion/markdown.ts`(이미지 제거), ingest 한도. 전사가 빠지는 것은 Notion 본문 API(`GET /v1/pages/{id}/markdown`)가 전사를 "Transcript omitted."로 빼고 주기 때문이다. 코드는 `<transcript>` 태그를 소제목으로 바꿀 뿐 따로 버리지 않는다 | 구현됨 (API 동작에 기댐) | Notion이 전사 본문을 주기 시작하거나 코드가 전사 블록을 따로 읽게 바뀌면 3장을 고친다. 전사를 계속 빼려면 코드에서 명시적으로 버리고 테스트로 고정하는 것을 권장 |
| Google Calendar: 제목 · 시각 · 주최자 · 참석자 · Meet 식별자만, 설명 · 첨부 제외 | 없음. 범위는 `calendar.events.owned.readonly`로 정했다(2026-09-27, `google-verification.md` 1장) | **미구현** (트랙 2-3) | 구현이 이 필드만 요청하는지, 그리고 실제로 `calendar.events.owned.readonly`를 쓰는지 확인(`fields=` 파라미터) |
| Meet 전사: 30일 안에 가져옴 | 없음 | **미구현** (트랙 2-3) | Meet API 목록은 주최한 회의만 돌려준다. 참석만 한 회의를 못 가져오면 3장에 "내가 주최한 회의"라고 적는다 |
| Gmail: 프로모션 · 소셜 분류는 목록에서 빼고, 자동 발송 · 대량 발송 · 수신 거부 · 메일링 리스트 머리글(같은 회사 도메인의 그룹 메일은 예외) · no-reply · 알림 · 반송 주소 · 일정 초대 · 알림은 머리글만 읽고 거름(본문을 받지 않음). 스팸 · 휴지통 · 임시 보관 · 채팅 · 첨부는 읽지 않음. 이용자가 보낸 메일은 자동 발송이 아니면 거르지 않음. 메일 한 통씩 저장(본문 2만 자에서 자름, 거른 메일은 저장하지 않음). 숨은 참조 등 다른 머리글 · 첨부 이름 · 형식은 쓰거나 저장하지 않음. 가져오거나 거른 메일의 식별자 · 받은 시각은 연결의 커서에 두었다가 가져오기가 한 시간 넘게 지나면 지우고, 이유별 개수는 연결 설정에 누적. 첫 동기화 14일 · 만료 뒤 다시 연결하면 마지막 동기화부터(최대 30일). 권한은 `gmail.readonly`(읽기만)와 계정 식별용 `openid` · `email` (3장 Gmail · 1장 연결 정보) | `src/lib/connectors/gmail/sync.ts`(`gmailQuery`: `-in:chats -in:drafts -category:promotions -category:social`, `DEFAULT_GMAIL_SYNC`: `lookbackDays` 14 · `maxGapDays` 30 · 겹침 1시간), `gmail/client.ts`(`METADATA_HEADERS` · 머리글 읽기 `format=metadata` + `fields`에 `snippet` 없음, 본문은 남긴 메일만 `format=full`), `gmail/filter.ts`(`filterMessage` 규칙 ①~⑨, 회사 도메인 예외 `companyDomain`), `gmail/message.ts`(`MAX_EMAIL_BODY` 20,000자 · 메일 한 통 = `IngestItem` 하나 · 첨부 제외 `:19-33` · 제목 · 보낸 사람 · 받는 사람 · 참조만 씀 `:164-194`), `gmail/sync.ts` `:118-121` · `:229-238`(`seen` 유지 기간) · `google/settings.ts`(`stats`), 연결 끊기는 `disconnect_connection`이 연결 행을 지움(`supabase/migrations/20261013000000_slack_sync.sql:160-181`), `gmail/run.ts`(`GMAIL_SCOPES`, `:87` 회사 도메인), 다시 연결은 `connectors/store.ts` `saveConnection`이 커서를 건드리지 않는 것. 단위 테스트 `gmail/*.test.ts`, dev 확인 2026-09-29(`docs/go-live/google-integration.md` 8장 · 9장) | 구현됨 (2026-09-29, PR #25). 3장 Gmail 절은 구현에 맞춰 고쳤고(Google PR 5a) 베타 1.1로 게시(2026-09-30) | ✅ 게시. `GMAIL_CONNECT_ENABLED=true`는 게시(베타 1.1) + 앱의 Gmail 확인 창(#27, 앱 빌드) + 재연결 알림(#27 배포) 뒤. 2026-09-30: 게시 · 재연결 알림은 충족, Gmail 확인 창은 main의 앱 코드에 있고 TestFlight 빌드는 아직 없다(앱 이용자는 운영자뿐). 테스터에게 나가는 첫 빌드에 #27이 들어가므로 켜도 된다 |
| Gmail: 연결은 7일마다 만료(Google Testing), 만료되면 앱과 알림으로 알림 | `src/lib/connectors/gmail/run.ts` `syncGmailConnection`: 갱신이 `invalid_grant`면(`GoogleReauthError` `:104`) `recordSync(…, { reauth: true })`(`:105`) → 연결 `reauth`. `recordSync`가 실제로 `reauth`로 바꿨을 때만 true(`connectors/store.ts:229-260`, 이미 `reauth`였거나 그 사이 다시 연결했으면 false)이고 그때 `notifyReconnect`가 등록된 기기마다 한 번 보낸다(`gmail/run.ts:107`, `notify/service.ts:60-74`). 앱의 "Reconnect to keep syncing" 줄(`apple/Packages/TaskforceKit/Sources/TaskforceKit/Connections.swift:180`), 알림을 누르면 연결 화면(`PushNotifications.swift:102` `Kind.reconnect`, `apple/Taskforce/iOS/HomeView.swift:502`, `apple/Taskforce/Mac/MacAppDelegate.swift:90`). 단위 테스트 `connectors/store.test.ts` · `gmail/run.test.ts` · `notify/service.test.ts` · `PushNotificationsTests` | 구현됨 · 배포됨 (Google PR 4a, #27, 2026-09-29 운영 `e547e05`) | ✅ 베타 1.1로 게시(2026-09-30). 그 뒤 `GMAIL_CONNECT_ENABLED`. 알림이 나가기 전에 켜면 3장의 "알림으로 알려 드립니다"가 거짓이 된다 |
| Notion: 연결이 만료되거나 끊기면 앱의 연결 화면에 표시. 갱신 토큰이 거절돼 다시 연결이 필요하면(접근을 거둔 경우 포함될 수 있음) 알림 한 번 (3장 Notion) | `src/lib/connectors/notion/run.ts`: 갱신이 `invalid_grant`면(`isInvalidGrant` `:40`, `:68`) `reauth: true`(`:84`), API 호출의 401은 먼저 갱신을 한 번 시도한다(`:61-69`): 갱신이 `invalid_grant`면 `reauth`(알림), 갱신 토큰이 없거나 갱신한 토큰으로도 401이면 `revoked`(`:86-87`, 알림 없음). `invalid_grant`에는 권한 취소가 든다(`notion/api.ts:83`, `docs/INTEGRATIONS.md:248`). `recordSync` 결과가 true이고 `reauth`일 때만 `notifyReconnect(… "notion")`(`:130-135`). 앱 줄은 `reauth` · `revoked` 모두 "Reconnect to keep syncing"(`Connections.swift:169`, `:180`). `notion/run.test.ts` | 구현됨 · 배포됨 (Google PR 4a, #27, 2026-09-29 운영 `e547e05`) | ✅ 베타 1.1로 게시(2026-09-30). #27 배포 뒤에 게시해야 했다(Notion 연결은 이미 열려 있어서, 규칙 2) |
| 이용 기록: 서비스 연결을 마친 기록 · 연결 만료 기록 · 재연결 알림을 보낸 기록(서비스 이름과 시각만), 계정 삭제까지 보유 (1장 · 5장) | `metric_events`의 `connection_created` · `connection_reauth` · `reconnect_notified`와 `provider` 열(마이그레이션 `20261015000000_metric_events_reauth_provider.sql`): `connectors/store.ts:186-187`(연결 완료), `:259` · `:264-267`(만료), `notify/service.ts:66-72`(알림 도달). 서버만 남기고 앱은 `app_opened`만 남긴다(테스트 `tests/db/go-live-connections.test.ts`). `user_id`가 `auth.users` 삭제에 연쇄 삭제된다(`supabase/migrations/20260925000000_init.sql:136`, `tests/db/account-deletion.test.ts`). 리텐션 지표 활동에는 넣지 않는다(`metrics/compute.ts` `metricActivity`) | 구현됨 · 배포됨 (#27, 운영 DB에 `20261015000000` 적용 · `metric_events.provider` 확인 2026-09-30) | ✅ 베타 1.1로 게시(2026-09-30) |
| Slack: DM · 그룹 DM · 언급 · 내 메시지 · 그 스레드만 남기고 나머지는 받는 즉시 버림, 연결 전 메시지는 가져오지 않음, 권한 9개, 봇 없음 | `src/lib/connectors/slack/events.ts`(`classifySlackMessage`), `SLACK_USER_SCOPES`(`slack/client.ts`, 9개 = 3장 목록), 매니페스트(`docs/go-live/slack-app.md` 2장). 버린 채널 메시지가 DB에 없음을 dev 워크스페이스에서 확인(2026-09-29) | 구현됨 (2026-09-29 배포, 운영 Slack 앱 `A0C584MQJV7`) | `SLACK_CONNECT_ENABLED=true`(처리방침 게시 · Slack 문구가 든 새 앱 빌드 뒤) |
| 앱 메뉴: 계정 → 프로필 · AI data · Privacy Policy · 계정 삭제, 연결 → 연결 끊기 (11장 표) | `apple/Taskforce/iOS/AccountSheet.swift` · `apple/Taskforce/Shared/AccountViews.swift`에 프로필 · 연결(연결 끊기) · AI 동의 · 계정 삭제가 있다. Privacy Policy · Terms of Use 링크는 iPhone 계정 시트(`iOS/AccountSheet.swift`) · Mac 설정 · 로그인 화면(`LegalLinksRow`, `apple/Taskforce/Shared/AccountDeletion.swift`)에 있다 | 구현됨 (2026-09-30 코드 확인) | — (2026-09-30 앱의 동의 메뉴 · 동의 화면 제목 · Mac 설정 탭을 "AI processing"에서 "AI data"로 바꿔 처리방침 4장 · 7장 · 11장의 "AI 데이터" · "AI data"와 `docs/go-live/app-store.md`에 맞췄다. 이 이름이 든 앱 빌드부터 적용) |
| 물어보기에서 질문을 AI로 보냄 | `src/lib/pipeline/ask.ts` (질문 · 답은 저장하지 않는다). 속도 제한은 `rate_limit_events` · `take_rate_limit`(20261005000000, `ASK_LIMIT` 10분 20번)이 맡는다. `ask_requests` 표는 없다 | 구현됨 | — |
| 문의 메일 90일 안 삭제 · 원문 열람 기록 · 운영 계정 2단계 인증 | 운영 규칙 (코드 아님) | 사용자가 지키기로 함 (2026-09-29 게시) | 열람 기록은 날짜 · 대상 · 이유 · 동의 여부를 적는 표 하나로 시작([internal-plan.md](internal-plan.md)). 2단계 인증은 runbook I12 |

## 결정 필요

1. ~~**모델 공급자 고정.**~~ **해결됨 (2026-09-27).** `src/lib/ai/providers.ts`가 모든 AI 요청에 `only` · `order` · `allow_fallbacks: false`를 붙여 아래 목록 밖으로 나가지 않는다(목록이 모두 막히면 요청은 실패한다, 다른 공급자로 새지 않는다):
   - 원문 분석 `LLM_MODEL=z-ai/glm-5.3-flash`: Fireworks · Together · DeepInfra(모두 ZDR, 본사 미국). BaseTen은 이 모델 제공자에서 빠져 2026-09-29에 목록에서 뺐다(웹사이트에 게시된 처리방침도 다음 배포 때 함께 고친다).
   - 임베딩 `openai/text-embedding-3-small`: Azure(Microsoft, 본사 미국) 한 곳.
   - 판정 `JEV_MODEL=typesafe/jev-1.13`: TypeSafe 한 곳. OpenRouter에 본사 국가 표기가 없고, 공개 자료 기준으로는 미국 샌프란시스코다. **해결됨 (2026-09-29):** TypeSafe AI, Inc., 255 California St, Suite 1300, San Francisco(TypeSafe 이용약관), 개인정보 문의 privacy@typesafe.ai. 처리방침 7장에 적었다.
   - 목록은 환경변수(`LLM_PROVIDERS` · `EMBED_PROVIDERS` · `JEV_PROVIDERS`)로 바꿀 수 있다. 처리방침 7장 표는 위 목록 · 국가를 그대로 옮긴다.
2. ~~**연동 원문 보관 기간.**~~ **해결됨 (2026-09-27).** 원문 본문(`sources.raw_text`)은 저장 뒤 90일이 지나면 지우고(`raw_text_purged_at` 기록), 근거 인용 · 원본 링크 · 할 일은 함께 남는다. (Slack은 연결을 끊거나 앱을 지우면 근거 인용까지 바로 지운다, 2026-09-28 D3) Jev 판정 기록(`judge_logs`, 후보 구절 포함)도 90일 뒤 지운다. 매일 `/api/cron/retention`이 `purge_expired_source_text`를 부른다(`src/lib/retention.ts`, 마이그레이션 20261006000000). 5장 표와 3장 Slack 상자를 고쳤다(상자는 2026-09-29 자체 검토로 지웠다).
3. **이메일 로그인.** PRD · PLATFORMS는 이메일 6자리 코드를 보조 로그인으로 두지만 지금 앱은 Sign in with Apple만 있다. 이메일 로그인을 열면 Supabase 기본 메일 발송(한도가 낮고 운영용이 아님)을 쓸지, 자체 SMTP(예: Resend)를 붙일지 정한다. 자체 SMTP를 붙이면 처리방침 7장에 수탁자를 더한다. App Store 심사용 데모 계정도 여기에 걸려 있다(`docs/go-live/app-store.md`).
4. ~~**개인정보 보호책임자 전화번호** (13장).~~ **해결됨 (2026-09-29):** 이메일만 둔다(13장 "이메일로 받습니다").
5. **문의 주소.** 확인된 주소는 `privacy@taskforcelabs.dev`뿐이다(Google Workspace MX, 2026-09-27 `dig` 확인). TestFlight 피드백 · Google 지원 이메일 · Slack 지원에 같은 주소를 쓸지, `support@` 별칭을 만들지 정한다.

## 법률 검토 항목 (국내 개인정보 전문 변호사)

베타는 [self-review.md](self-review.md)의 결정표로 자체 검토했다(2026-09-29). 아래 목록은 나중에 변호사 검토를 받을 때의 질문 목록으로 남긴다.

1. **원문 속 제3자의 개인정보.** 메일 보낸 사람 · 회의 참석자 · Slack 대화 상대 · 발화자의 정보를 동의 없이 처리하는 근거(개인정보 보호법 제15조제1항제6호 정당한 이익 또는 수탁 구조), 제20조 수집 출처 통지, 외부 AI 전송의 적법성, GDPR 제6조제1항(f) · 제14조.
2. **Slack.** API 약관의 "설치하는 조직의 명시적 허락", 최소 보관, 일부 API의 영구 사본 금지가 근거 인용 · 원문 보관과 맞는지. 베타가 무료여도 나중에 유료 기능이 생기면 "Commercial Distribution"(Marketplace 계약 필요)에 해당하는지. Slack 개발자 정책의 "앱을 지우면 관련 데이터를 14 영업일 안에 모두 삭제"에 맞춰, 연결을 끊으면 Slack 원문 본문을 지우고 근거 인용을 바꾸되 할 일은 남기는 방식(`docs/go-live/slack-integration.md` D3)으로 충분한지. 남는 것: 할 일 제목 · 상대 이름 · Claim 값 · 변경 이력 · 임베딩(제목과 당시 인용으로 만든 벡터) · 원본 링크(워크스페이스 주소 · 채널 id · 메시지 ts), Slack에서 앱을 지운 경우 끊긴 연결 기록(워크스페이스 이름 · 주소 · 식별자, 이용자의 Slack 식별자).
3. **국외 이전과 재위탁.** OpenRouter를 거쳐 고정된 모델 공급자 목록(결정 1, 2026-09-27 해결)으로 가는 구조를 제28조의8제2항의 "이전받는 자"로 어떻게 적어야 하는지. TypeSafe의 소재지를 서면으로 확인하지 못한 채 공개해도 되는지.
4. **안전성 확보조치 기준(고시).** 개인정보취급자 접속기록 보관(1년 이상) 의무가 운영자 1인의 Supabase 대시보드 · SQL 접근에 어떻게 적용되는지. Supabase Free에는 조직 감사 로그가 없다. 내부 관리계획 수립 의무의 적용 여부.
5. **EU 이용자.** 베타를 EU 거주자에게 열면 GDPR 제27조 EU 대리인 지정이 필요한지. 필요하면 대리인을 두거나 베타 대상 지역을 정한다.
6. **약관.** 면책 조항(제10조)이 약관규제법 · 소비자 관련 법령에서 유효한지, 무료 베타에 전자상거래법 고지 의무가 있는지.
7. **Google Workspace 데이터의 외부 AI 전송.** Workspace 사용자 데이터 정책의 AI 관련 조항(일반화 모델 학습 금지 외 추가 요건)을 처리방침 15장과 앱 동의 화면이 충족하는지.
8. **통신비밀보호법.** 로그 기록 보관 의무가 이 서비스에 해당하는지.
9. **만 14세 미만 확인.** 연령을 묻지 않는 지금 방식(약관 동의 + 알게 되면 삭제)으로 충분한지.
10. **Google API 약관의 영구 사본 금지.** 연결을 끊어도 Google에서 가져온 원문 · 할 일은 남고(원문 본문은 90일 뒤 삭제, `docs/go-live/google-integration.md` G11), 근거 인용 · 할 일 제목 · 관련자는 계정 삭제까지 남는다. 이것이 Google API 서비스 이용약관의 "영구 사본을 만들지 말 것"과 맞는지, 맞지 않으면 Slack D3처럼 끊을 때 Google 원문 · 인용을 지우는 방식으로 바꿔야 하는지. Google 정책(API 서비스 사용자 데이터 정책 · Workspace 사용자 데이터 정책)에서 "끊으면 지우라"는 규칙이나 기한은 찾지 못했다(요구하는 것은 삭제 요청을 따르고 지우는 방법을 안내하는 것).
