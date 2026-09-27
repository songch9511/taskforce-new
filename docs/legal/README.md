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

1. `{{…}}` 자리표시자를 모두 채우고, "법률 검토 필요" 상자를 지운 뒤에만 게시한다. 상자는 검토가 끝났다는 표시가 아니라 **검토할 곳의 표시**다.
2. 아래 [구현 대조표](#구현-대조표)에서 "게시 조건"이 끝나지 않은 문장이 있으면 게시하지 않는다. 처리방침이 코드보다 앞서면 방침이 거짓이 된다.
3. 한국어와 영어의 내용을 항상 같게 고친다. 두 판이 다르면 한국어가 우선한다(각 문서 머리에 적음).
4. 코드 · 인프라를 바꿀 때 아래 중 하나라도 바뀌면 이 폴더를 같은 PR에서 고친다: AI 호출 경로 · 모델 공급자, 호스팅 리전, Supabase 요금제(백업), 로그에 남기는 것, 새 연동 · 새 수집 항목, 분석 SDK.
5. 웹사이트 첫 화면의 개인정보 한 줄("AI calls go only to providers that keep no data. Your data stays in Sydney, and deleting your account deletes it right away.")은 처리방침의 "한눈에 보기"와 같은 약속만 쓴다(BRAND.md).

## 구현 대조표

처리방침 문장이 기대는 코드 · 설정. "구현됨"은 2026-09-27에 코드로 확인한 것이다. 같은 날 다른 작업(트랙 2 · 3)이 코드를 계속 바꾸고 있어 "진행 중" · "코드 있음" 행은 **게시 직전에 다시 확인한다.**

| 처리방침의 약속 | 근거 (코드 · 설정) | 상태 | 게시 조건 |
|---|---|---|---|
| 모든 AI 요청은 ZDR · 학습 금지 공급자에게만 | `src/lib/ai/llm.ts` · `jev.ts` · `embed.ts`의 `provider: { data_collection: "deny", zdr: true }` (llm은 `require_parameters: true`도) | 구현됨 | — |
| 모델 공급자와 국가를 7장 표에 적음 | 코드가 공급자를 고정하지 않는다. `zdr: true`만으로는 조건을 만족하는 **모든** 엔드포인트로 갈 수 있다 | **결정 필요** | 아래 [결정 1](#결정-필요) |
| OpenRouter 프롬프트 로깅 꺼짐 | OpenRouter 계정 설정 (코드 아님) | 확인 필요 | 사용자가 OpenRouter → Settings → Privacy에서 확인 |
| 데이터는 시드니, 백업 없음 → 삭제 즉시 | `supabase/.temp/pooler-url`이 `aws-0-ap-southeast-2` (시드니). 요금제는 Free로 알려져 있으나 이 저장소에서 확인할 수 없다 | 확인 필요 | 사용자가 Supabase 대시보드에서 Free · 백업 없음을 확인. Pro로 올리면 7일 백업이 생겨 5장을 고친다 |
| 서버는 시드니 | `vercel.json`의 `"regions": ["syd1"]` | 구현됨 | 배포한 프로젝트에 설정이 적용됐는지 배포 뒤 확인(runbook) |
| 서버 요청 기록 1일 | Vercel Pro 런타임 로그 보관 1일 (Observability Plus를 켜면 30일) | 요금제 사실 | Observability Plus · 로그 드레인을 켜지 않는다. 켜면 5장을 고친다 |
| 데이터베이스 · 인증 기록 1일 | Supabase Free 로그 보관 1일 | 요금제 사실 | 위 요금제 확인과 같다 |
| 계정 삭제 시 모든 표가 함께 지워짐 | `src/app/api/v1/account/route.ts` → `auth.admin.deleteUser`, 모든 사용자 표가 `auth.users`에 `on delete cascade`. `tests/db/account-deletion.test.ts` | 구현됨 | 배포 뒤 실제 Supabase에서 한 번 실행(GO_LIVE.md 2장) |
| 계정 삭제 시 Sign in with Apple 토큰 폐기 | 서버: `src/lib/apple/sign-in.ts`(client secret JWT → `/auth/token` → `/auth/revoke`), `DELETE /api/v1/account`가 삭제 전에 부름, 본문 `apple_authorization_code`(선택). **앱은 아직 code를 보내지 않아(`APIClient.deleteAccount()` 본문 없음) 지금은 폐기가 항상 건너뛰어진다** | 진행 중 (앱 남음) | 앱이 삭제 확인 때 Sign in with Apple을 한 번 더 받아 code를 보냄 + `APPLE_*` env (`docs/go-live/app-store.md` 6장) |
| 계정 삭제 시 연결 서비스 토큰 폐기 | `src/lib/connectors/registry.ts`의 `revokeConnectorTokens` (Notion `POST /v1/oauth/revoke`) 작업 중 | 진행 중 | Google(`oauth2.googleapis.com/revoke`) · Slack(`auth.revoke`)까지 붙은 뒤 |
| 동의 전에는 연결 원문을 AI로 보내지 않음 · 철회 가능 | `supabase/migrations/20261003000000_go_live_connections_consent.sql`의 `profiles.ai_consent_at`, `src/lib/api/consent.ts`(POST · DELETE `/api/v1/consent`, 동의 없으면 409), 연결 시작 · 동기화 · 원문 보내기 · 물어보기가 동의를 확인, `registry.ts`가 동의 없는 사용자의 연결을 건너뜀. 앱: `apple/Taskforce/Shared/AccountViews.swift`의 동의 · 철회 화면 | 코드 있음 (작업 중, 배포 전) | 서버 배포 + 운영 DB 마이그레이션 + 앱 빌드. 동의 화면 문구가 처리방침 4장 · `app-store.md` 5장과 같은지 확인 |
| 연결 끊기 → 토큰 즉시 삭제, 원문 · 할 일은 남음 | `DELETE /api/v1/connections/:id`, `connection_secrets`는 `on delete cascade`, `sources.connection_id`는 `on delete set null` | 구현됨 | — |
| 앱에서 지운 할 일은 "지움" 상태로 남음 | `DELETE /api/v1/actions/:id`가 `dropped` + `user_deleted` 이벤트 | 구현됨 | — |
| 서버 기록에 원문 · 토큰 · 코드 없음 | 모든 `console.error`가 오류 메시지와 id만 남긴다. `processing_summary` · `processing_error` · `last_error`에 원문을 넣지 않는다(마이그레이션 주석) | 구현됨 (규칙) | 새 코드도 같은 규칙. 로그 드레인 없음 |
| 잠금 화면 알림에 할 일 제목 없음 | `src/lib/notify/apns.ts`: 일반 문구 + `mutable-content: 1` + `action_id` | 구현됨 | 앱의 Notification Service Extension |
| Apple에서 이름을 받지 않음 | `apple/Taskforce/Shared/SignIn.swift`의 `requestedScopes = [.email]` | 구현됨 | 로그인 화면을 바꿔도 이메일만 요청 |
| Notion: 콘텐츠 읽기만, 녹음 전사 · 이미지 제외, 한 건 20만 자 | INTEGRATIONS.md Notion 절, `connectors/notion/markdown.ts`(이미지 제거), ingest 한도. 전사가 빠지는 것은 Notion 본문 API(`GET /v1/pages/{id}/markdown`)가 전사를 "Transcript omitted."로 빼고 주기 때문이다. 코드는 `<transcript>` 태그를 소제목으로 바꿀 뿐 따로 버리지 않는다 | 구현됨 (API 동작에 기댐) | Notion이 전사 본문을 주기 시작하거나 코드가 전사 블록을 따로 읽게 바뀌면 3장을 고친다. 전사를 계속 빼려면 코드에서 명시적으로 버리고 테스트로 고정하는 것을 권장 |
| Google Calendar: 제목 · 시각 · 주최자 · 참석자 · Meet 식별자만, 설명 · 첨부 제외 | 없음 | **미구현** (트랙 2-3) | 구현이 이 필드만 요청하는지 확인(`fields=` 파라미터). 범위를 `calendar.events.owned.readonly`로 정하면(`google-verification.md` 1장) 3장 권한 이름을 고친다 |
| Meet 전사: 30일 안에 가져옴 | 없음 | **미구현** (트랙 2-3) | Meet API 목록은 주최한 회의만 돌려준다. 참석만 한 회의를 못 가져오면 3장에 "내가 주최한 회의"라고 적는다 |
| Gmail: 뉴스레터 · 프로모션 · 알림 거름, 스팸 · 휴지통 · 첨부 제외, 7일 재연결 안내 | 없음 | **미구현** (트랙 2-3) | 구현 값과 3장 문장을 맞춘다. 첫 동기화 기간을 정하면 3장에 적는다 |
| Slack: DM · 그룹 DM · 언급 · 내 메시지만 남기고 나머지는 받는 즉시 버림, 권한 5개 | 없음 | **미구현** (트랙 2-4) | 구현 권한과 3장 목록을 맞춘다(`docs/go-live/slack-app.md`) |
| 앱 메뉴: 계정 → 프로필 · AI data · Privacy Policy · 계정 삭제, 연결 → 연결 끊기 (11장 표) | `apple/Taskforce/iOS/AccountSheet.swift` · `apple/Taskforce/Shared/AccountViews.swift`에 프로필 · 연결(연결 끊기) · AI 동의 · 계정 삭제가 있다(작업 중). **앱 안 처리방침 링크는 없다** | 진행 중 | 계정 메뉴에 Privacy Policy 링크(App Store 5.1.1(i)). 앱의 실제 메뉴 이름과 11장 표를 맞춘다 |
| 물어보기에서 질문을 AI로 보냄 | `src/lib/pipeline/ask.ts`, `ask_requests`(질문 · 답은 저장하지 않음) 작업 중 | 진행 중 | — |
| 문의 메일 90일 안 삭제 · 원문 열람 기록 · 운영 계정 2단계 인증 | 운영 규칙 (코드 아님) | 사용자 | 게시 전에 실제로 지킬 수 있는지 사용자가 확인. 열람 기록은 날짜 · 대상 · 이유 · 동의 여부를 적는 표 하나로 시작 |

## 결정 필요

1. **모델 공급자 고정.** 2026-09-27 OpenRouter 공개 목록(`/api/v1/endpoints/zdr`)을 보면:
   - 원문 분석 `LLM_MODEL=z-ai/glm-5.3-flash`: ZDR 엔드포인트가 약 30곳이다. 미국 회사(예: Fireworks, Together, DeepInfra, BaseTen)와 함께 본사가 미국 밖인 곳(예: Z.AI, SiliconFlow)도 들어 있다. 지금 코드로는 요청마다 어느 나라로 가는지 정할 수 없다.
   - 판정 `JEV_MODEL=typesafe/jev-1.13`: TypeSafe 한 곳. 회사 소재국은 확인하지 못했다.
   - 임베딩 기본값 `openai/text-embedding-3-small`: ZDR 엔드포인트는 **Azure(Microsoft) 한 곳**뿐이다(OpenAI 직접 엔드포인트는 ZDR 목록에 없음). 그래서 지금 임베딩은 Microsoft로 간다.
   - 권장: `llm.ts` · `jev.ts` · `embed.ts`의 `provider`에 `only: [...]`(허용 공급자 목록)를 더해 고정하고, 그 목록과 국가를 처리방침 7장 표에 적는다. 목록은 eval로 품질을 확인한 뒤 정한다. 이것은 코드 변경이라 이 문서에서 하지 않는다.
2. **연동 원문 보관 기간.** 지금은 계정 삭제 때까지 원문(`sources.raw_text`)과 판정 기록(`judge_logs.candidate`, 인용 포함)이 남는다. Slack API 약관의 "필요한 최소한"과 Google Limited Use의 최소 보관 취지에 맞추려면 상한이 필요하다. 예: 원문 본문은 90일 뒤 지우고(근거 인용 · 원본 링크는 할 일과 함께 남김), 누락 신고는 90일 안의 원문에서만 받는다. 정하면 5장 표와 3장 Slack 상자를 고친다.
3. **이메일 로그인.** PRD · PLATFORMS는 이메일 6자리 코드를 보조 로그인으로 두지만 지금 앱은 Sign in with Apple만 있다. 이메일 로그인을 열면 Supabase 기본 메일 발송(한도가 낮고 운영용이 아님)을 쓸지, 자체 SMTP(예: Resend)를 붙일지 정한다. 자체 SMTP를 붙이면 처리방침 7장에 수탁자를 더한다. App Store 심사용 데모 계정도 여기에 걸려 있다(`docs/go-live/app-store.md`).
4. **개인정보 보호책임자 전화번호** (13장). 법은 "전화번호 등 연락처"를 요구한다. 이메일만 둘지 정한다.
5. **문의 주소.** 확인된 주소는 `privacy@taskforcelabs.dev`뿐이다(Google Workspace MX, 2026-09-27 `dig` 확인). TestFlight 피드백 · Google 지원 이메일 · Slack 지원에 같은 주소를 쓸지, `support@` 별칭을 만들지 정한다.

## 법률 검토 항목 (국내 개인정보 전문 변호사)

게시 전에 한 번에 검토받는다. 1 · 2는 처리방침 본문에 "법률 검토 필요" 상자로 표시했다.

1. **원문 속 제3자의 개인정보.** 메일 보낸 사람 · 회의 참석자 · Slack 대화 상대 · 발화자의 정보를 동의 없이 처리하는 근거(개인정보 보호법 제15조제1항제6호 정당한 이익 또는 수탁 구조), 제20조 수집 출처 통지, 외부 AI 전송의 적법성, GDPR 제6조제1항(f) · 제14조.
2. **Slack.** API 약관의 "설치하는 조직의 명시적 허락", 최소 보관, 일부 API의 영구 사본 금지가 근거 인용 · 원문 보관과 맞는지. 베타가 무료여도 나중에 유료 기능이 생기면 "Commercial Distribution"(Marketplace 계약 필요)에 해당하는지.
3. **국외 이전과 재위탁.** OpenRouter를 거쳐 모델 공급자로 가는 구조를 제28조의8제2항의 "이전받는 자"로 어떻게 적어야 하는지. 공급자를 고정하지 않은 동적 라우팅이 공개 요건을 만족할 수 있는지(결정 1과 함께).
4. **안전성 확보조치 기준(고시).** 개인정보취급자 접속기록 보관(1년 이상) 의무가 운영자 1인의 Supabase 대시보드 · SQL 접근에 어떻게 적용되는지. Supabase Free에는 조직 감사 로그가 없다. 내부 관리계획 수립 의무의 적용 여부.
5. **EU 이용자.** 베타를 EU 거주자에게 열면 GDPR 제27조 EU 대리인 지정이 필요한지. 필요하면 대리인을 두거나 베타 대상 지역을 정한다.
6. **약관.** 면책 조항(제10조)이 약관규제법 · 소비자 관련 법령에서 유효한지, 무료 베타에 전자상거래법 고지 의무가 있는지.
7. **Google Workspace 데이터의 외부 AI 전송.** Workspace 사용자 데이터 정책의 AI 관련 조항(일반화 모델 학습 금지 외 추가 요건)을 처리방침 15장과 앱 동의 화면이 충족하는지.
8. **통신비밀보호법.** 로그 기록 보관 의무가 이 서비스에 해당하는지.
9. **만 14세 미만 확인.** 연령을 묻지 않는 지금 방식(약관 동의 + 알게 되면 삭제)으로 충분한지.
