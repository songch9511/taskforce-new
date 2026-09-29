# Slack 앱 설정

관련 문서: [go live](../GO_LIVE.md) 5장 · [런북](runbook.md) · [처리방침 3장 Slack](../legal/privacy.ko.md) · [법률 문서 README](../legal/README.md)

작성: 2026-09-27. Slack 연동(트랙 2-4)이 쓸 Slack 앱을 만드는 방법과 그 이유다. 앱 생성 · 배포 설정은 사용자가 한다(9장).

## 1. 요약

| 항목 | 결정 |
|---|---|
| 토큰 | **사용자 토큰**(`xoxp-`). 봇 없음. 이용자 본인이 속한 대화만 받는다 |
| 받는 방식 | **Events API**. 대화 기록 API(`conversations.history` · `replies`)로 주기 조회하지 않는다(4장 속도 제한) |
| 받는 이벤트 | `message.im` · `message.mpim` · `message.channels` · `message.groups` (사용자 이벤트) |
| 남기는 메시지 | 이용자와의 DM, 그룹 DM, 이용자를 언급한 메시지, 이용자가 쓴 메시지와 그 스레드. **나머지는 받는 즉시 버린다** |
| 권한 | `im:history` · `mpim:history` · `channels:history` · `groups:history` · `users:read` + 대화 이름 `im:read` · `mpim:read` · `channels:read` · `groups:read` (모두 user scope, 9개. 대화 이름 4개는 2026-09-28 결정, [slack-integration.md](slack-integration.md) D7) |
| redirect URL | `https://api.taskforcelabs.dev/api/connectors/slack/callback` |
| 이벤트 URL | `https://api.taskforcelabs.dev/api/connectors/slack/events` |
| 배포 | 공개 배포(Public Distribution)를 켠 **비Marketplace 앱**으로 시작. Marketplace는 설치 워크스페이스가 10곳을 넘고 법률 검토(7장)가 끝난 뒤. 단, 사용자 토큰 `*:history`는 Marketplace 승인이 어렵다(8장, 2026-09-28 확인) |
| 서버 환경변수 | `SLACK_CLIENT_ID` · `SLACK_CLIENT_SECRET` · `SLACK_SIGNING_SECRET` (+ 3-3의 `SLACK_APP_TOKEN`이 필요하면) |

## 2. 앱 매니페스트

api.slack.com/apps → **Create New App** → **From a manifest** → 개발 워크스페이스 선택 → 아래 매니페스트를 붙여 넣는다. **JSON 탭을 권한다**: YAML은 복사하며 들여쓰기가 깨지면 권한이 0개로 읽힌다(2026-09-29 dev 앱). 아래 YAML과 같은 내용을 JSON으로 바꿔 넣으면 된다.

```yaml
_metadata:
  major_version: 2
  minor_version: 1
display_information:
  name: Taskforce
  description: Finds what you committed to in Slack and keeps your task list up to date.
  background_color: "#000000"
  long_description: >-
    Taskforce is an AI project manager for iPhone and Mac. Connect Slack and Taskforce
    reads your direct messages, group DMs, messages that mention you, and messages you
    write, then finds the work you committed to. When a later message changes a deadline,
    Taskforce updates the existing task instead of adding a new one, and every task shows
    the exact message it came from. Taskforce only reads; it never posts, edits, or deletes
    messages. Channel messages that do not involve you are discarded on arrival. Slack data
    is never used to train AI models. Privacy policy: https://www.taskforcelabs.dev/en/privacy
oauth_config:
  redirect_urls:
    - https://api.taskforcelabs.dev/api/connectors/slack/callback
  scopes:
    user:
      - im:history
      - mpim:history
      - channels:history
      - groups:history
      - users:read
      - im:read
      - mpim:read
      - channels:read
      - groups:read
settings:
  event_subscriptions:
    request_url: https://api.taskforcelabs.dev/api/connectors/slack/events
    user_events:
      - message.im
      - message.mpim
      - message.channels
      - message.groups
    # 앱 해제 알림. 봇이 없어도 구독된다(필요 권한 none, 2026-09-29 dev 앱에서 확인). 받으면 연결을 끊고 Slack 데이터를 지운다
    bot_events:
      - app_uninstalled
      - tokens_revoked
  interactivity:
    is_enabled: false
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

- 이벤트 URL은 서버가 Slack의 `url_verification` 요청에 `challenge`를 그대로 돌려줘야 저장된다. **서버를 배포한 뒤** 매니페스트를 붙이거나, 먼저 `event_subscriptions`를 빼고 만든 뒤 배포 후 Event Subscriptions에서 켠다.
- 로컬 개발은 운영 앱을 건드리지 않게 **Taskforce dev** 앱을 따로 만든다(같은 매니페스트, redirect · 이벤트 URL만 터널 주소). Slack은 이벤트를 공개 HTTPS 주소로만 보낸다.
- 앱 아이콘: 앱 아이콘 마크(검정 바탕)를 Basic Information → Display Information에 올린다(정사각형, 512px 이상).
- `token_rotation_enabled: false`: 베타는 토큰 갱신 없이 시작한다(코드가 단순하다). 켜면 사용자 토큰이 12시간마다 만료되고 갱신 토큰을 저장 · 갱신해야 한다. Marketplace 심사 전에 켤지 다시 정한다.

## 3. 권한과 이벤트를 이렇게 고른 이유

### 3-1. 권한 (최소 권한)

| 권한 | 받는 것 | 왜 필요한가 |
|---|---|---|
| `im:history` | 이용자 DM의 메시지 이벤트(`message.im`) | 1:1 약속 · 기한 변경(PRD 핵심 시나리오 2)이 가장 많이 오가는 곳 |
| `mpim:history` | 그룹 DM(`message.mpim`) | 소규모 협업 대화 |
| `channels:history` | 이용자가 속한 공개 채널(`message.channels`) | 채널에서 이용자를 언급한 요청, 이용자가 채널에 쓴 약속("제가 할게요") |
| `groups:history` | 이용자가 속한 비공개 채널(`message.groups`) | 위와 같음. 팀 논의는 비공개 채널에서 많이 한다 |
| `users:read` | 사용자 id → 이름 | 메시지의 `U…` id를 이름으로 바꿔 `participants`에 넣는다. 담당 판정에 쓴다 |
| `im:read` · `mpim:read` | DM · 그룹 DM의 상대 (`conversations.info`) | 메시지 이벤트에는 대화 id만 있다. 내가 쓴 줄만 있는 DM에서도 **누구와의 약속인지**(상대) 알려면 필요하다 (2026-09-28 추가, D7) |
| `channels:read` · `groups:read` | 채널 이름 | 원문 머리줄 · 제목의 `#fundraising`. 채널 이름이 주제를 알려 추출을 돕는다 (2026-09-28 추가, D7) |

**넣지 않은 것과 이유:**
- `chat:write` 등 쓰기 권한: 앱은 읽기만 한다.
- `users:read.email`: 이메일로 Google 쪽 참석자와 사람을 맞출 수 있지만, 베타에서는 이름으로 충분한지 먼저 본다. 필요해지면 처리방침 3장과 함께 더한다.
- ~~`channels:read` · `groups:read` · `im:read` · `mpim:read`~~: **더했다 (2026-09-28, D7).** 이 권한 없이는 DM 상대가 글을 쓰기 전까지 상대를 모르고, 채널 이름도 모른다.
- `search:read`: 과거 메시지를 검색해 오는 것은 이벤트 방식의 목적(쌓아 두지 않기)과 맞지 않는다.
- 봇 권한 `app_mentions:read`와 이벤트 `app_mention`: 이 이벤트는 **Taskforce 봇**이 언급됐을 때만 온다. 이용자가 언급된 메시지는 `message.channels` · `message.groups`에서 `<@이용자id>`로 찾는다. 그래서 봇을 두지 않는다.

**채널 권한을 좁히는 선택지:** `channels:history` · `groups:history`를 빼면 DM과 그룹 DM만 받는다. 권한 화면이 가벼워지는 대신 채널의 언급 · 약속을 놓친다. go live는 네 권한 모두로 시작하고, 연결 화면에 "DMs, group DMs, and channel messages that mention you or that you write"라고 먼저 알린다.

### 3-2. 버리는 규칙 (서버가 지켜야 할 것, 트랙 2-4)

`message.channels` · `message.groups`는 이용자가 속한 채널의 **모든** 메시지를 보낸다. 서버는 받은 즉시 아래로 가르고, 맞지 않으면 저장하지 않는다(메모리에서 버림, 로그에도 남기지 않음).

| 이벤트 | 남기는 조건 |
|---|---|
| `message.im` · `message.mpim` | 모두 (봇 · 시스템 메시지 하위 유형 제외) |
| `message.channels` · `message.groups` | 본문에 `<@이용자id>`가 있음, 또는 보낸 사람이 이용자, 또는 이용자가 쓴 · 언급된 스레드의 답글 |
| 하위 유형 `message_changed` | 이미 남긴 메시지면 고친 내용으로 바꿈 |
| 하위 유형 `message_deleted` | 아직 원문으로 넣기 전이면 지움. 이미 넣었으면 원문 처리 규칙을 정한다(아래 7장) |

- 대화 · 스레드 단위로 묶고, 대화가 멈춘 뒤(안정화 시간) 원문 하나로 넣는다(계획 2-4). 묶는 동안의 메시지 보관 위치(DB 표)도 RLS · 계정 삭제 cascade를 따른다.
- 이벤트는 3초 안에 200으로 답하고 처리는 뒤에서 한다. Slack은 실패하면 다시 보내므로(`X-Slack-Retry-Num`) `event_id`로 중복을 거른다.
- 서명 확인: `X-Slack-Signature`가 `v0=` + HMAC-SHA256(`SLACK_SIGNING_SECRET`, `v0:{X-Slack-Request-Timestamp}:{본문}`)와 같은지 timing-safe로 비교하고, 타임스탬프가 5분보다 오래됐으면 거절한다. 원문 본문은 로그에 남기지 않는다.
- Events API 한도: 워크스페이스 · 앱마다 시간당 30,000건. 넘으면 Slack이 `app_rate_limited`를 보내고 일부 이벤트를 버린다. 베타 규모에서는 문제없지만 큰 워크스페이스를 연결하면 확인한다.

### 3-3. 한 워크스페이스에 Taskforce 이용자가 여럿일 때 (구현 때 확인)

Slack은 같은 메시지 이벤트를 워크스페이스에 한 번만 보내고, 이벤트의 `authorizations`에는 설치 하나만 들어 있다고 문서에 적혀 있다. 같은 채널에 Taskforce 이용자가 둘 이상이면 나머지 이용자를 찾으려면 `apps.event.authorizations.list`(앱 수준 토큰 `xapp-`, 권한 `authorizations:read`)를 불러야 한다.
트랙 2-4에서 최신 문서로 확인하고, 필요하면 앱 수준 토큰을 만들어 `SLACK_APP_TOKEN`으로 둔다(runbook에 더함).

## 4. 왜 Events API인가: 2025-05-29 속도 제한

Slack은 2025-05-29에 **Marketplace에 올리지 않고 배포하는 상업용 앱**의 대화 기록 조회를 크게 제한했다(docs.slack.dev 변경 기록 "Rate limit changes for non-Marketplace apps").

- `conversations.history` · `conversations.replies`: **분당 1회, 요청당 최대 15개**.
- 2025-05-29 이후 만든 앱과, 기존 비Marketplace 앱의 새 설치에 적용된다. 조직 내부용 앱은 예외(분당 50회 이상, 1,000개).
- API 약관 변경은 2025-05-29 이후 만든 앱에 바로, 그 전 앱에는 2025-06-30부터 적용됐다.

이용자 한 명이 대화 수십 개에 속해 있으면 분당 1회로는 따라갈 수 없다. 그래서 기록을 조회하지 않고, Slack이 보내 주는 이벤트만 받는다. 이 방식에는 **연결하기 전의 과거 메시지는 가져오지 않는다**는 한계가 있다. 연결 화면과 첫 빈 화면에 "연결한 뒤의 메시지부터 읽어요"를 알린다(트랙 3-4).

## 5. OAuth 흐름 (서버 구현 참고)

- 권한 요청: `https://slack.com/oauth/v2/authorize?client_id=…&user_scope=im:history,mpim:history,channels:history,groups:history,users:read,im:read,mpim:read,channels:read,groups:read&redirect_uri=https://api.taskforcelabs.dev/api/connectors/slack/callback&state=<서명된 state>`. 봇 권한이 없으므로 `scope=`는 비운다.
- callback에서 `oauth.v2.access`로 교환 → `authed_user.access_token`(사용자 토큰), `authed_user.id`, `team.id` · `team.name`. 연결은 `external_account_id = team.id:authed_user.id`, `display_name = team.name`으로 저장하고 토큰은 `connection_secrets`에 암호화한다(기존 `saveConnection`).
- 연결 끊기 · 계정 삭제 때 `auth.revoke`로 토큰을 폐기한다(`registry.ts`의 `revokeToken`).
- 워크스페이스가 앱 승인을 요구하면(관리자 설정) 이용자는 "요청"만 보내고 관리자가 승인해야 설치된다. 연결 실패 문구에 이 경우를 넣는다.

## 6. 공개 배포 (다른 워크스페이스에 설치)

1. api.slack.com/apps → Taskforce → **Manage Distribution**.
2. 체크리스트를 채운다: 코드에 박힌 토큰 없음(Remove Hard Coded Information), 모든 기능 HTTPS, OAuth redirect URL 등록.
3. **Activate Public Distribution**. 이제 "Add to Slack"(여기서는 앱의 Connect 버튼이 여는 권한 주소)으로 어느 워크스페이스에서든 설치할 수 있다.
4. Marketplace에는 올리지 않는다(아래 7장). 비Marketplace 배포라 대화 기록 API는 4장의 제한을 받지만, 이벤트 방식이라 영향이 없다.
5. 설치한 워크스페이스 수는 Manage Distribution에서 본다(Marketplace 기준 10곳을 넘는지).

## 7. Slack 약관과 보관: 법률 검토 필요

Slack API 약관(2025-10-10 시행, <https://slack.com/terms-of-service/api>)에서 Taskforce와 관계있는 조항:

- **학습 금지:** 조직 밖에 제공하는 앱은 "use API Data to train a large language model"을 할 수 없다. → 처리방침 3장 · 4장에 이미 약속. OpenRouter 경유 공급자도 ZDR · 학습 금지 조건이라 맞다.
- **최소 사용 · 보관:** 조직 밖 데이터의 사용 · 처리 · 보관을 앱 기능의 개발 · 시험 · 운영 · 지원에 "minimum necessary"로 제한하고, **설치하는 조직의 명시적 허락**을 받아야 한다.
- **대량 내보내기 · 다른 조직을 위한 사용 금지.**
- **영구 사본 금지:** "Data Access API and Real-Time Search API" 절에 "you may not create persistent copies, archives, indexes, or long-term data stores of other organizations' API Data"가 있다. 이 문장이 그 두 API에만 걸리는지, 모든 API 데이터에 걸리는지 문맥상 분명하지 않다.
- **상업 배포:** "users could pay fees for your product"이면 Commercial Distribution이고 별도 계약(대부분 Marketplace)이 필요하다. 베타는 무료지만 유료화하면 해당한다.
- **앱을 지우면 14 영업일 안에 삭제 (2026-09-28 확인):** Slack 개발자 정책(2024-12-10 시행)은 "When a User deletes your Application … you must delete all associated Data within 14 business days"라고 한다. 지금 처리방침 5장의 "연결을 끊어도 원문이 남는다"는 Slack에 맞지 않는다 → [slack-integration.md](slack-integration.md) D3.

Taskforce가 지금 하는 것: 남긴 메시지를 원문(`sources.raw_text`)으로 **저장 후 90일**, 근거 인용(`evidence.quote`, `claims.quote`)으로는 **계정 삭제 때까지** 보관한다(결정 2, 2026-09-27 해결, 처리방침 5장 · `src/lib/retention.ts`).

**검토할 것 (docs/legal/README.md 법률 검토 2번):**
1. ~~원문 보관 기간 상한을 둘지~~ **해결됨**: 원문 본문 90일 뒤 삭제, 인용은 할 일이 있는 동안(결정 2).
2. "설치하는 조직의 명시적 허락"을 사용자 토큰 설치로 충족하는지, 워크스페이스 관리자의 승인 절차가 필요한지.
3. Slack에서 지운 메시지(`message_deleted`)를 이미 넣은 원문 · 인용에서도 지울지.
4. 유료화 전에 Marketplace 계약이 필요한지.

## 8. 나중에: Slack Marketplace

Marketplace에 올리면 대화 기록 API 제한이 풀리고 설치 경고가 줄지만, 요구 사항이 있다(docs.slack.dev Marketplace 가이드라인).

- **설치 수:** 활성 워크스페이스 10곳 미만 · 주간 활성 사용자 10명 미만인 앱은 올릴 수 없다.
- **사용자 토큰 대화 권한 (2026-09-28 확인):** 가이드라인은 `*:history` 권한을 심화 심사하고, 실시간 검색 · MCP 서버 같은 쓰임이 없는 사용자 토큰 `*:history`는 "승인하기 어렵다"고 적는다. 기능 심사는 새 앱 최대 10주다. 비Marketplace 공개 배포는 Slack이 파일럿 · 시험용으로 둔다. 베타는 이대로 가되 **정식 출시 전에 Slack 경로를 다시 정한다**([slack-integration.md](slack-integration.md) 9장).
- **AI:** Slack 데이터로 LLM을 학습하지 않는다. Agent/Assistant UI 앱에는 "DO not store any Slack data you obtain. Store metadata instead and pull in data in real time if needed, i.e. zero-copy" 규칙이 있다. Taskforce는 Agent UI 앱이 아니지만, 원문 · 인용을 저장하는 설계가 심사에서 문제가 될 수 있다 → **7장 법률 검토와 함께 판단**.
- **처리방침:** 수집하는 데이터, 쓰임, 보관 기간, 열람 · 이동 · 삭제 요청 방법, 연락처를 적어야 한다 → `docs/legal/privacy.en.md`가 이미 다룬다.
- **지원:** 연락 방법을 두고 2 영업일 안에 답한다. 지원을 받으려고 계정을 더 만들게 하지 않는다.
- 보안 검토 · 토큰 갱신(rotation) 여부를 그때 다시 본다.

## 9. 사용자가 누르는 순서

1. **서버 배포 확인** — `https://api.taskforcelabs.dev`가 떠 있다(runbook). 끝: `/api/connectors/slack/events`가 배포되어 있다(트랙 2-4).
2. **앱 만들기** — api.slack.com/apps → Create New App → From a manifest → 개발 워크스페이스(예: Dimension) → 2장 YAML → Create. 이벤트 URL 확인이 실패하면 `event_subscriptions`를 빼고 만든 뒤 6번에서 켠다. "Create and Install"이 "Installation was not completed"로 끝나도 앱은 만들어져 있다 — 같은 버튼을 다시 누르지 말고(앱이 또 생긴다) 앱의 **Install App**에서 설치한다(2026-09-29 dev 앱).
3. **아이콘** — Basic Information → Display Information → App icon 업로드.
4. **비밀값** — Basic Information → App Credentials의 Client ID · Client Secret · Signing Secret을 비밀번호 관리자에 적고 Vercel env `SLACK_CLIENT_ID` · `SLACK_CLIENT_SECRET` · `SLACK_SIGNING_SECRET`에 넣는다 → 재배포.
5. **(필요하면) 앱 수준 토큰** — 3-3을 구현하면 Basic Information → App-Level Tokens → Generate(`authorizations:read`) → `SLACK_APP_TOKEN`.
6. **이벤트 URL 확인** — Event Subscriptions → Enable → Request URL에 이벤트 URL → "Verified". Subscribe to events on behalf of users에 네 이벤트가 있는지 확인 → Save.
7. **자기 워크스페이스에서 시험** — 앱에서 Slack 연결 → 권한 화면에 아홉 권한 → Allow → 앱으로 돌아옴. DM으로 "금요일까지 보낼게요" → 대화가 멈춘 뒤 할 일이 생기는지 확인.
8. **공개 배포** — 6장 순서. 끝: Manage Distribution에 "Public distribution is active".
9. **다른 워크스페이스에서 시험** — 테스터 한 명의 워크스페이스에서 설치. 관리자 승인이 필요한 곳인지 기록한다.
10. **처리방침 확인** — 앱이 실제로 요청하는 권한이 처리방침 3장 목록과 같은지 확인한다.

## 출처

- 비Marketplace 앱 속도 제한 (2025-05-29): <https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps>
- Slack API 약관 (2025-10-10 시행): <https://slack.com/terms-of-service/api>
- Marketplace 가이드라인: <https://docs.slack.dev/slack-marketplace/slack-marketplace-app-guidelines-and-requirements>
