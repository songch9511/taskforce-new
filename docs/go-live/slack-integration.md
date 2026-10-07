# Slack 연동: 구현 계획 (다음 마일스톤)

관련 문서: [go live](../GO_LIVE.md) "현재 상태와 진행 순서" 3 · [런북 체크리스트 C5](runbook.md#go-live-체크리스트) · [Slack 앱 설정](slack-app.md) · [처리방침 3장 Slack](../legal/privacy.ko.md) · [진실 판정 규칙](../TRUTH_RULES.md)

작성: 2026-09-28. [GO_LIVE.md](../GO_LIVE.md) 진행 순서 3(체크리스트 C5, 다른 문서의 "트랙 2-4")을 코드로 옮기기 전에 **정할 것 · 만들 것 · 끝난 기준**을 적는다.
Slack 앱 설정과 권한을 고른 이유는 [slack-app.md](slack-app.md)가 기준이다. 이 문서는 서버 · 앱 · eval 쪽이다. 초안을 코드와 대조해 검토했고(2026-09-28), 지적 15건을 반영했다. PR 1 · 1b · 2 · 3을 구현했다(6장). 구현하며 정한 것은 4장 "PR 2 확인" · "PR 3 구현"에 적었다.

## 0. 한눈에

| 항목 | 내용 |
|---|---|
| 목표 | 테스터가 앱에서 Slack을 연결하면, 그 뒤 DM · 그룹 DM · 나를 언급한 글 · 내가 쓴 글에서 약속이 할 일로 생긴다. 메시지로 바뀐 기한은 **새 할 일을 만들지 않고** 기존 할 일에 반영된다 (PRD 핵심 시나리오 2) |
| 기간 | 코드 1~2주 (PR 4개, 6장) |
| 시작 조건 | 1장 결정(D3 · D7 결정됨, 나머지 권장안). 개발 워크스페이스 · 시험용 두 번째 계정 · **Taskforce dev** Slack 앱(7장). 운영 서버 배포(I1~I3)는 개발 시작에는 필요 없고 운영 앱(L7)을 만들 때 필요하다 |
| 끝난 기준 | 8장. 요약: Slack 골든셋 eval 기록 · 개발 워크스페이스에서 시나리오 2가 끝까지 됨 · 버린 채널 메시지가 DB에 없음 · 연결을 끊으면 토큰과 Slack 데이터가 지워짐 · 처리방침과 구현이 같음 |
| 파이프라인 | **고치지 않는다.** Slack은 "Source를 만들어 파이프라인에 넣는 어댑터"다([VIBE_CODING_PLAN.md](../VIBE_CODING_PLAN.md) Phase 6). 추출 · 검증 · Jev · 매칭 · 진실 판정은 Notion과 같다. 예외는 D3의 데이터 지우기뿐이다 |

## 1. 시작 전에 정할 것

**D3 · D7은 결정했다 (2026-09-28, 권장안대로).** 나머지는 권장안으로 시작하고, 다르게 하려면 PR 1 전에 정한다. D3의 "associated Data" 범위(할 일 제목을 남겨도 되는지)는 자체 검토(docs/legal/self-review.md 2번, 2026-09-29)로 정했다.

| # | 정할 것 | 권장 | 이유 | 다른 선택 |
|---|---|---|---|---|
| D1 | 원문 하나의 단위와 넣는 때 | DM · 그룹 DM은 **대화가 30분 멈추면** 그때까지를 원문 하나로. 스레드는 스레드 하나. 한 묶음은 **한국 시간(KST) 자정을 넘지 않고** 최대 3시간 · 100개 (기한 계산이 KST 고정이다, `dates.ts`. 이용자별 시간대는 저장하지 않는다) | Notion의 "마지막 수정 뒤 30분"(`settleMinutes`)과 같다. 시나리오 2의 반영까지 최대 45분(30분 + cron 15분). 자정 · 3시간 상한은 날짜 계산 때문이다: 기한("내일까지")과 Claim 시각은 모두 원문의 `occurredAt` 하나로 계산된다(`verify.ts`의 `checkDue`, `merge.ts`). 묶음이 날을 넘으면 "내일"이 하루 틀리고, 길면 사이에 있던 회의보다 먼저 한 말로 판정된다(TRUTH_RULES 규칙 4) | 10분: 빠르지만 대화가 더 잘게 쪼개진다 |
| D1-b | 30분 넘게 끊긴 답장의 맥락 | **결정 (2026-09-28, PR 1 eval): (가) 맥락 없이 넣는다.** (나)는 같은 대화의 앞 원문 마지막 몇 줄을 `(앞 대화)` 표시와 함께 앞에 붙이는 방식 | 요청 뒤 한 시간 만에 온 `:+1:`은 다음 묶음이 되어 무엇에 대한 수락인지 모른다. 그래도 `seq-slack-gap-reply`에서 (가) 5/5 · (나) 5/5로 차이가 없었다: 요청 원문만으로 할 일이 잡히고, 뒤의 수락은 새 할 일을 만들지 않았다. 더 단순한 (가)로 가고, 1주 사용에서 끊긴 답장이 할 일을 놓치면 (나)를 다시 본다 | (나): 앞 줄에서 같은 약속을 다시 뽑아도 매칭이 중복으로 합치지만(원칙 4), 원문이 길어지고 인용이 앞 원문과 겹친다 |
| D2 | 채널의 맥락 | **받은 것만 쓴다.** 나를 언급한 글 · 내가 쓴 글 · 그 스레드만 남기고, 그 앞의 채널 글은 가져오지 않는다 | 처리방침 3장 "나머지는 받는 즉시 버린다"를 지킨다. 대화 기록 API는 분당 1회 · 15개로 막혀 있다(slack-app.md 4장) | 내 글 · 언급이 오면 앞 글 5개를 `conversations.history`로 가져온다: 처리방침 문장을 고쳐야 하고 분당 1회 대기열이 필요하다. 골든셋 `slack-channel-mid-thread` 점수가 낮으면 다시 본다 |
| D3 | 연결을 끊거나 Slack에서 앱을 지웠을 때 | **결정.** 그 연결의 **Slack에서 온 글자를 바로 지운다**(2-7 표). 할 일 · 상태 · 기한은 남기고, 근거 인용은 "Slack 연결을 끊어 지웠어요"로 바꾼다 | Slack 개발자 정책(2024-12-10 시행): "When a User deletes your Application … you must delete all associated Data within 14 business days". 지금 처리방침은 "연결을 끊어도 원문이 남는다"라서 Slack에 맞지 않는다. 대신 CLAUDE.md 원칙 2(근거) · 5(Claim은 지우지 않는다)에 **예외**가 생긴다 — CLAUDE.md에 한 줄로 적는다(PR 3, 구현과 함께) | 할 일까지 지운다: 이용자가 정한 상태 · 기한이 사라진다. 인용을 남긴다: 정책 위반 소지 |
| D4 | 한 워크스페이스에 Taskforce 이용자가 둘 이상일 때 | **처음부터 처리한다.** 그 워크스페이스에 이벤트의 `authorizations`에 없는 Taskforce 연결이 하나라도 있으면 `apps.event.authorizations.list`(앱 수준 토큰 `SLACK_APP_TOKEN`)로 이 이벤트를 볼 수 있는 이용자를 모두 찾는다 | Slack은 같은 메시지를 워크스페이스에 **한 번만**, 설치 하나의 이름으로 보낸다(2026-09-28 확인). 같은 팀 두 명이 테스터면 둘 사이의 DM이 한 사람에게만 들어간다 | 베타는 한 워크스페이스에 한 명만: 코드는 줄지만 팀 단위 테스터를 못 받는다 |
| D5 | 짧은 잡담을 AI에 보내기 전에 거를지 | **처음에는 거르지 않는다.** 1주 사용에서 Slack 원문 하나당 비용 · 하루 건수를 재고, 넘치면 Jev 사전 필터를 붙인다 | 거르기는 곧 누락 위험이다(지표 4). `:+1:` 한 줄도 수락일 수 있다. Slack 묶음은 짧아서 회의록보다 싸다 | 처음부터 Jev 예/아니오 사전 필터 |
| D6 | 실제 Slack 원문 골든셋 | 본인 워크스페이스의 DM · 스레드 5건 이상을 **로컬에서 익명화**해 넣는다(원문은 커밋하지 않음, 익명화한 결과만) | 합성 예시만으로는 실제 문체를 모른다(GO_LIVE.md "직접 써 보며 드러난 것") | 합성만: 빠르지만 go live 뒤 실제 정확도를 모른다 |
| D7 | 대화 이름을 읽는 권한 | **결정. `im:read` · `mpim:read` · `channels:read` · `groups:read`를 더한다** (권한 5개 → 9개, 모두 이름 · 구성원만 읽는 권한) | 메시지 이벤트에는 대화 id만 있다. 이 권한 없이는 채널 이름(`#fundraising`)도, **DM 상대가 누구인지**도 모른다 — 내가 "금요일까지 보내드릴게요"만 쓴 DM에서 상대(counterpart)가 비고, 제목 · 매칭 · "누구에게"가 약해진다. slack-app.md 3-1은 "꼭 필요해지면 더한다"고 적어 두었다 | 더하지 않는다: 제목은 `Slack · DM` · `Slack · Channel`, DM 상대는 그 사람이 한 번이라도 글을 써야 안다. 권한 화면은 가볍다 |

## 2. 서버 설계

### 2-1. 흐름

```
Slack ──(메시지 이벤트)──▶ POST /api/connectors/slack/events
                            ① 서명 확인 ② 받을 연결 찾기 ③ 가르기(버리는 규칙)
                            ④ 남길 것만 slack_messages에 저장 ⑤ 200 (3초 안)

cron 15분 · Sync Now · 연결 직후 ──▶ syncConnections ──▶ slackConnector.sync
                            ⑥ 30분 멈춘 묶음을 원문(IngestItem)으로 만듦
                            ⑦ ingestItems → processSource (기존 파이프라인 그대로)
                            ⑧ 원문 저장과 같은 트랜잭션에서 읽은 대기 행만 표시, 처리가 끝나면 그 행의 본문을 비움
```

받기(①~⑤)와 넣기(⑥~⑧)를 나눈다. 이벤트 처리는 빨라야 하고(3초), 원문 처리는 느리다(모델 호출).
넣기는 연결 틀의 `Connector.sync`에 맞는다. cron · 수동 동기화 · 동의 확인은 새로 만들지 않는다. 잠금(`claimConnection` · `recordSync`)은 Notion처럼 커넥터가 직접 부른다(`notion/run.ts`).

### 2-2. 파일

| 파일 | 할 일 | 테스트 |
|---|---|---|
| `src/lib/connectors/slack/client.ts` | Slack Web API: `oauth.v2.access` · `auth.test` · `users.info` · `conversations.info`(D7) · `auth.revoke` · `apps.event.authorizations.list`. 응답은 모두 zod로 검증 | 가짜 fetch |
| `src/lib/connectors/slack/verify.ts` | 서명: `v0=` + HMAC-SHA256(`SLACK_SIGNING_SECRET`, `v0:{timestamp}:{본문}`), timing-safe 비교, 5분 넘은 요청 거절 | 순수 |
| `src/lib/connectors/slack/events.ts` | 이벤트 하나 + 이용자 Slack id → 남김/버림 + 묶음 열쇠 (2-4) | 순수 |
| `src/lib/connectors/slack/bucket.ts` | 대기 메시지 → 묶음 → `IngestItem` (2-5) | 순수 |
| `src/lib/connectors/slack/run.ts` | `slackConnector`: `authorizeUrl` · `connect` · `sync` · `revokeToken`. `sync`는 Notion처럼 `claimConnection` · `recordSync`를 부르고, `ConsentRequiredError`를 Notion과 같게 처리한다(`notion/run.ts`) | 가짜 저장소 |
| `src/lib/connectors/slack/store.ts` | 대기 메시지 · 추적 스레드 · 이름 캐시, 원문 저장 + 대기 행 정리(한 RPC), Slack 데이터 지우기(D3) | DB 테스트 |
| `src/app/api/connectors/slack/callback/route.ts` | 공용 `handleOAuthCallback`에 넘긴다 (Notion callback과 같은 모양) | — |
| `src/app/api/connectors/slack/events/route.ts` | 이벤트 받기(2-4). 서명 확인 전에 본문을 문자열로 먼저 읽는다(`await request.text()`) | route 테스트 |
| `src/app/api/v1/connections/[id]/route.ts` | 연결 끊기를 서버 권한으로: 토큰 폐기 → (Slack) D3 → 행 삭제 (2-7) | route 테스트 |
| `src/lib/retention.ts` · `/api/cron/retention` | 새 정리 RPC 호출: 받은 지(`received_at`) 3일 지난 대기 행(넣었는지와 관계없이), 활동 14일 지난 추적 스레드 | DB 테스트 |
| `src/lib/connectors/registry.ts` | `CONNECTORS`에 `slack: slackConnector` 한 줄. 이것으로 앱의 연결 시작 · 완료 · 동기화 · 계정 삭제 때 토큰 폐기가 이어진다 | 기존 |
| `src/lib/env.ts` · `.env.example` | `SLACK_CLIENT_ID` · `SLACK_CLIENT_SECRET` · `SLACK_SIGNING_SECRET` · `SLACK_REDIRECT_URI` · `SLACK_APP_TOKEN`(D4) | 기존 env 테스트 |
| `scripts/eval.ts` · `src/lib/eval/golden.ts` | 케이스 묶음(태그 또는 id 앞머리) 필터 · 묶음별 표, "확인 요청이면 맞음" 표시(4장) | 기존 eval 테스트 |

`slack`은 이미 `Provider` 타입 · `contract.ts`의 연결 스키마 · DB check 제약 · 앱의 `stageOne`에 들어 있다. 새로 넓힐 enum은 없다.

### 2-3. 연결 (`connect`)

1. `oauth.v2.access`로 code를 바꾼다 → `authed_user.access_token` · `authed_user.id` · `team.id` · `team.name`. 봇 토큰은 없다.
2. `auth.test`로 워크스페이스 주소(`url`)를 받는다. 원본 링크에 쓴다(2-5). 권한이 따로 필요 없다.
3. `saveConnection`: `external_account_id = team.id:authed_user.id`, `display_name = team.name`, `settings = { slackUserId, teamId, teamUrl }`. 토큰은 `saveToken`(암호화).
4. 상태는 `connected`. 첫 동기화(`afterConnected`)는 대기 메시지가 없어 바로 끝난다. **연결 전의 메시지는 가져오지 않는다**(slack-app.md 4장) — 앱 문구로 알린다(3장).
5. 관리자 승인이 필요한 워크스페이스는 이용자가 요청만 보낸다. 이때 Slack이 callback으로 돌아오는지(`denied` · `error`), 아예 돌아오지 않는지는 확인하지 못했다 → PR 3에서 dev 앱으로 확인하고, 테스터 안내(G3)에 적는다.

### 2-4. 이벤트 받기

| 단계 | 할 일 |
|---|---|
| 서명 | `verify.ts`. 틀리면 401. 본문 · 헤더는 로그에 남기지 않는다 |
| `url_verification` | `challenge`를 그대로 돌려준다 |
| 받을 연결 찾기 | `team_id`와 `authorizations[].user_id`로 `provider = slack`, `external_account_id = team:user`, **`status`가 `active` 또는 `error`**인 연결을 찾는다. `recordSync`는 동기화가 한 번 실패해도 `error`로 바꾸고(`store.ts`), `error` 연결도 동기화는 계속된다. `active`만 받으면 일시 오류 동안의 메시지가 영영 사라진다(과거를 다시 가져올 방법이 없다). `revoked`만 뺀다. 이벤트의 `authorizations`에 없는 연결이 그 워크스페이스에 있으면 D4. 동의(`ai_consent_at`)가 없는 이용자는 저장하지 않는다 |
| 가르기 (연결마다) | DM(`im`) · 그룹 DM(`mpim`): 이용자 계정에서 보이는 일반 메시지를 남긴다. 채널(`channel` · `group`): 이용자 직접 언급(`<@id>`), 이용자 본인의 글, 기존 추적 스레드의 답글, 실제 방송 언급(`<!channel>` · `<!here>` · `<!everyone>`) 중 하나가 있을 때만. 사람과 외부 앱 · 봇 작성 글 모두 조건을 적용한다. `<#C…|name>` 채널 링크는 방송 언급이 아니다. 방송 언급만으로 받은 메시지는 저장하지만 새 스레드를 추적하지 않는다. `bot_id`가 있으면 사용자 필드보다 우선해 synthetic sender로 저장한다. Taskforce 자체 글은 메시지의 `app_id` 또는 `bot_profile.app_id`가 envelope의 `api_app_id`와 같을 때만 버린다. 시스템 하위 유형(`channel_join` · `channel_leave` 등)은 버린다 |
| 저장 · 재전송 | 보통 메시지는 `slack_messages`에 `(connection_id, channel_id, ts)`로 넣되 **이미 있으면 아무것도 하지 않는다.** 행은 원문으로 넣은 뒤에도 받은 지 3일까지 표시만 남기므로(2-6), Slack이 늦게 다시 보낸 이벤트(`X-Slack-Retry-Num`, Delayed Events)가 이미 넣은 메시지를 다시 넣거나 고친 글을 옛 글로 덮지 않는다 |
| 고침 · 지움 | `message_changed`: 아직 넣지 않은 행이면 본문을 바꾼다. `message_deleted`: 아직 넣지 않은 행이면 지운다. 이미 원문으로 넣었으면 그대로 둔다(본문은 90일 뒤 지움, slack-app.md 7장 검토 3) |
| 답 | 저장까지 동기로 하고 200. 저장이 실패하면 5xx로 답해 Slack이 다시 보내게 한다. 받을 연결이 없는 이벤트 · 버린 이벤트도 200 (60분 동안 95% 넘게 실패하면 Slack이 구독을 끈다) |
| 앱 해제 | `tokens_revoked`: 이벤트에 든 사용자 id의 연결만. `app_uninstalled`: **그 워크스페이스의 모든 Taskforce 연결.** 두 이벤트는 순서 없이 온다. 연결의 `connected_at`이 이벤트 시각(`event_time`)보다 뒤면(그 사이 다시 연결) 건드리지 않는다. `created_at`은 다시 연결해도 그대로이고(`saveConnection`이 기존 행을 고친다), `updated_at`은 동기화마다 바뀌어서 둘 다 쓸 수 없다 → 새 열(2-6). 해당 연결은 `revoked`로 바꾸고 D3대로 지운다 |
| 로그 | 이벤트 종류 · 결정(남김/버림/연결 없음) 개수만. 본문 · 이름 · Slack id는 남기지 않는다 |

**수집 범위 문구 검토 전:** 구현은 연결된 Slack 계정이 볼 수 있는 실제 방송 언급과 그 메시지를 보낸 외부 앱 · 봇까지 대기 표에 넣을 수 있다. `@here`가 누구에게 알림을 보냈는지는 이벤트만으로 확인할 수 없다. 메시지를 받았다는 사실만으로 할 일의 소유자를 정하지 않는다. 제품 연결 안내 · 공개 처리방침 · 네이티브 문구는 아직 개인 언급 · 본인 작성 글만 설명하므로, 확장된 방송 수집을 운영에 켜기 전에 검토용 문구 초안([Slack 공지 수집 범위 초안](../legal/slack-notices-scope-draft.md))에 맞춰 세 곳을 함께 정렬한다. 이 초안은 정책 버전 · 시행일을 정하거나 공개하지 않는다.

### 2-5. 묶기와 넣기 (`sync`)

| 항목 | 규칙 |
|---|---|
| 묶음 열쇠 | DM · 그룹 DM 본 대화: `c:{channel}`. 스레드(모든 대화 종류): `t:{channel}:{thread_ts}`. 채널에서 남긴 첫 글: `t:{channel}:{ts}` (나중에 답글이 달리면 그 스레드가 된다) |
| 넣는 때 | 마지막 메시지가 30분 지남. 묶음이 KST 자정 · 3시간 · 100개에 닿으면 거기서 자른다(D1). **자른 앞부분은 바로 넣을 수 있게** `lastEditedAt`을 30분 전 이하로 준다 — `ingestItems`가 모든 항목에 30분 규칙을 다시 걸기 때문이다(`ingest.ts`) |
| 외부 id · 버전 | `externalId = {열쇠}:{묶음 첫 ts}`, `externalVersion = {묶음 마지막 ts}`. 연동 공통 규칙은 "한 항목은 한 번만 넣는다"(`ingest.ts`)라서, 넣은 뒤 같은 스레드에 달린 답글은 새 첫 ts의 **다음 묶음**이 된다. unique 인덱스 `(connection_id, external_id, external_version)`와도 맞다 |
| 종류 · 제목 | `kind = message`, `writtenByMe = null`(메시지는 한 사람이 쓴 문서가 아니다). 제목: `Slack · DM with 김민지` · `Slack · Group DM` · `Slack · #fundraising` |
| 본문 형식 | 아래. 골든셋(4장)과 글자까지 같게 한다 |
| 관련자 | DM: 상대와 이용자. 그룹 DM · 채널: 묶음에서 글을 쓴 사람 + 언급된 사람(구성원 목록 `conversations.members`는 부르지 않는다). **언급된 사람을 꼭 넣는다**: 판정이 "@Daniel Kim"처럼 사용자 별칭("Daniel")으로 시작하는 다른 사람을 관련자 이름으로 가린다(TRUTH_RULES 1장). 모두 `attendees`로 넣는다. DM을 `from`(상대) · `to`(이용자)로 넣어 `sole_recipient`가 되게 하는 방식은 PR 1 eval에서 나아지지 않았다(요청자 취소 실패는 그대로, 끊긴 답장이 2번 중 1번 누락, 2026-09-28) |
| 시각 | `occurredAt` = 묶음 첫 메시지. 자정 · 3시간 상한 덕분에 "오늘 · 내일"이 맞게 계산된다 |
| 원본 링크 | `{teamUrl}archives/{channel}/p{ts에서 점 뺀 값}` (스레드 답글이면 `?thread_ts=…&cid=…`). `chat.getPermalink`를 부르지 않아도 된다 |
| 이름 | 처음 보는 Slack id만 `users.info`(분당 100회 이상), 대화 이름 · DM 상대는 `conversations.info`(D7). 7일 캐시 |
| 너무 짧은 원문 | **Slack은 길이로 거르지 않는다**(`minTextLength: 1`). 공통 기본값 30자면 머리줄을 합쳐도 20자 남짓인 `:+1:` · `넵!` 수락 묶음이 버려지고, 그 대기 행은 3일 정리 때까지 쓸모없이 남는다 |
| 원문 저장 + 대기 행 정리 | 두 단계. ① 원문 저장과 한 RPC(한 트랜잭션)에서 **이번에 읽은 `(channel_id, ts)` 행만** `source_id`로 표시한다(묶음 열쇠로 고르면 동기화 도중 새로 온 메시지까지 잡힌다). 이미 넣은 원문과 부딪히면(동시 동기화) 같은 행을 그 원문으로 표시한다. ② `process()`가 끝나면(성공이든 보통 실패든 원문 행에 글이 남아 있다) 그 행들의 본문을 비운다. `ConsentRequiredError`면 ②를 하지 않는다: 원문은 기존 규칙으로 지워지고(`forgetUnprocessedSource`), `slack_messages.source_id`가 `on delete set null`이라 표시가 풀려 동의가 돌아오면 다시 묶인다(아니면 3일 정리). 순서의 근거: `ingestItems`는 원문 저장 뒤에 `process()`를 부르고, 동의 오류는 `process()` 안에서 난다(`ingest.ts`) |

본문 형식 (기존 메시지 골든셋 `[#채널]` / `이름: 글`과 같은 모양):

```
[DM · 김대표]
김대표: 제안서는 월요일에 받아도 괜찮아요. 투자 미팅이 화요일로 밀렸어요.
송창훈: 넵 알겠습니다!
김대표: @송창훈 참고로 장소는 역삼 위워크예요
```

- **이용자 본인의 줄은 Taskforce 프로필 이름으로 쓴다.** 사용자 알아보기는 이름 문자열로 한다(`identity.ts`의 `userNameForms` · `isUser`). Slack 표시 이름(예: `daniel`)이 프로필 이름 · 별칭과 다르면 "내가 한 말"을 못 알아본다(Phase A1에서 프로필이 빈 계정이 "나: …"를 남의 일로 본 문제와 같다). 본인 여부는 Slack id로 코드가 정하므로 확실하다.
- `<@U…>` → `@이름`(본인이면 프로필 이름). `<#C…|이름>` → `#이름`. `<https://…|글>` → `글 (https://…)`. 이모지 코드(`:+1:`)는 그대로 둔다.
- 머리줄: DM `[DM · 상대]`, 그룹 DM `[그룹 DM]`, 채널 `[#채널]`. 넣은 뒤 같은 스레드의 다음 묶음은 `[#채널 · 스레드 이어서]`(첫 글은 앞 원문에 있다).
- 스레드 첫 글이 없으면(채널 첫 글이 나와 무관해 버렸고 답글에서 나를 언급) 머리줄을 `[#채널 · 스레드 중간부터]`로 쓴다(D2).

### 2-6. 데이터 (새 마이그레이션 `20261011000000_slack.sql`)

새 표는 모두 **서버만 쓰는 표**다: `user_id`, 부모 연결과 `(connection_id, user_id)` 복합 외래키 + `on delete cascade`, RLS 켬 + `anon` · `authenticated`의 모든 권한 회수. 앱이 읽을 일이 없고 원문 본문이 들어 있어서 `owner_all` 대신 `oauth_handoffs` · `connection_secrets`와 같은 방식을 쓴다(CLAUDE.md의 `owner_all` 규칙에서 벗어나는 이유를 마이그레이션 주석에 적는다).

| 표 · 변경 | 내용 | 지워지는 때 |
|---|---|---|
| `slack_messages` (대기 메시지) | `connection_id` · `user_id` · `channel_id` · `channel_type`(im/mpim/channel/group) · `ts` · `thread_ts` · `sender_id` · `text` · `edited_at` · `received_at` · `source_id`(넣은 원문. `sources` 외래키 `on delete set null`, 처리가 끝나면 `text`를 비움). unique `(connection_id, channel_id, ts)` | 받은 지(`received_at`) 3일 — 넣은 행(재전송 막기용 표시) · 안 넣은 행(안전장치) 모두 — retention cron. 연결 끊기 · 계정 삭제 |
| `slack_threads` (추적 스레드) | `connection_id` · `user_id` · `channel_id` · `thread_ts` · `last_activity_at`. PK `(connection_id, channel_id, thread_ts)` | 마지막 활동 14일 뒤(retention cron), 연결 끊기, 계정 삭제 |
| `slack_people` (이름 캐시) | `connection_id` · `user_id` · `slack_id`(사람 또는 대화) · `kind` · `name` · `fetched_at`. PK `(connection_id, slack_id)` | 연결 끊기, 계정 삭제 |
| `connections.connected_at` | `saveConnection`이 연결 · 다시 연결 때마다 적는다. 늦게 온 `tokens_revoked`가 새 연결을 지우지 않게 하는 기준(2-4) | — |
| `sources.raw_text_purge_reason` | `retention`(90일) · `disconnected`(D3). 앱 · 서버의 "90일이 지나 본문을 지웠어요" 문구는 `raw_text_purged_at`만 보고 나온다(`create-action.ts` · `sources/[id]/missing` · `service.ts`) — 이유에 따라 문구를 가른다 | — |
| `connections`의 `owner_delete` 정책 삭제 (**PR 3**, 별도 마이그레이션 `20261014000000`, 배포 **뒤에** 적용) | 지금은 앱이 Supabase로 연결 행을 **직접** 지울 수 있다(`20260928000000_connections.sql`). 그러면 토큰 폐기와 D3를 건너뛰고 `sources.connection_id`가 `null`이 된다. 앱은 이미 API로 끊는다(`APIClient.swift`의 `disconnect`). 단, 지금의 끊기 라우트가 이 정책으로 지우므로(이용자 권한) **라우트를 서버 권한으로 바꾸는 PR 3에서 함께** 지우고, 이 정책에 기대는 `tests/db/connections.test.ts`의 "연결을 끊으면 토큰은 지워지고 원문은 남는다"도 그때 고친다 | — |

`tests/db/`: 새 표를 `authenticated`가 읽지도 쓰지도 못하는지, 이용자가 `connections` 행을 직접 지우지 못하는지, 연결 · 계정을 지우면 함께 지워지는지.

### 2-7. 끊기 · 계정 삭제 · 토큰

- 계정 삭제 → 기존 `revokeConnectorTokens`가 `auth.revoke`를 부른다(`slackConnector.revokeToken`만 구현하면 된다). 행은 계정과 함께 모두 지워진다.
- **앱의 연결 끊기는 지금 서비스 쪽 토큰을 폐기하지 않는다.** `DELETE /api/v1/connections/:id`는 이용자 권한으로 연결 행만 지운다(토큰 행은 cascade로 지워지지만 Slack · Notion에는 토큰이 살아 있다). PR 3에서 서버 권한으로 바꾼다: 토큰 읽기 → `revokeToken` → (Slack이면) D3 → 연결 행 삭제. 모든 연동에 같이 적용되므로 Notion도 끊을 때 토큰이 폐기된다.
- 순서가 중요하다: 연결 행을 지우면 `sources.connection_id`가 `null`이 된다(`on delete set null`). 그 뒤에는 어느 원문이 Slack에서 왔는지 찾을 수 없으므로 **D3를 연결 행 삭제보다 먼저** 한다.
- Slack 쪽에서 앱을 지우면 → `tokens_revoked` · `app_uninstalled`(2-4). 이 이벤트 없이 `users.info`가 `token_revoked` · `invalid_auth`를 돌려줘도 같은 처리를 한다.
- 토큰 갱신(rotation)은 끈 채로 시작한다(slack-app.md 2장). 켜면 되돌릴 수 없다.

**D3에서 지우는 것** (그 연결의 원문 = `sources.connection_id`가 그 연결인 행):

| 곳 | 처리 |
|---|---|
| `sources.raw_text` · `title` · `participants` | 본문 비움, 제목은 `Slack`, 관련자 비움, `raw_text_purged_at` · `raw_text_purge_reason = disconnected` |
| `evidence.quote` | "Slack 연결을 끊어 지웠어요"로 바꿈 (원칙 2 예외) |
| `claims.quote` · `claims.value_text` | 글자만 비움. Claim 행 · 값의 판정 결과(기한 · 상태 · 담당)는 남겨 할 일 값이 바뀌지 않게 한다 (원칙 5 예외: 행은 지우지 않음) |
| `judge_logs.candidate` | 그 원문의 판정 기록 행을 지움 |
| `slack_messages` · `slack_threads` · `slack_people` | 행 삭제 |
| 할 일(`actions`) 제목 · 범위 요약 | **남긴다.** Slack 글에서 만든 요약이지만 이용자의 할 일 목록이다. "associated Data"에 들어가는지는 자체 검토(docs/legal/self-review.md 2번)로 이용자 자신의 할 일 데이터로 봤다 |

## 3. 앱 (Swift)

판정 로직은 넣지 않는다. 서버가 `slack`을 등록하면 연결 시작 API의 400("아직 연결할 수 없어요")이 멈추므로, 앱의 "Coming soon"은 저절로 Connect가 된다(`Connections.swift`의 `comingSoon`).

| 곳 | 바꿀 것 |
|---|---|
| 연결 전 안내 | 지금 확인 창은 Google 전용이다: 제목이 Google이고 Continue가 `start(.google)`을 부른다(`AccountViews.swift`의 `confirmingGoogle`). 서비스를 받는 확인 창으로 바꾸고, Slack의 `readsBeforeConnecting`에 한 줄: "DMs, group DMs, and channel messages that mention you or that you write. New messages only." |
| 연결 끊기 확인 | 지금 "Tasks already found stay." Slack이면 "Slack messages are deleted. Tasks stay." (D3) |
| 연결 직후 | 바꾸지 않는다. 공통 "Syncing…"(C11)이 잠깐 보였다가 곧 끝난다 |
| 원문 서비스 표시 | 이미 `slack.com` 링크를 Slack으로 알아본다(`SourceService.swift`). 확인만 |

UI 문구는 짧은 영어 라벨 규칙을 따른다. 설명 줄은 위 두 문장만 둔다.

**PR 4에서 함 (2026-09-29):**
- 확인 창을 서비스를 받는 창으로 바꿨다(`AccountViews.swift`의 `confirming`, Google · Slack이 쓴다). Slack의 `readsBeforeConnecting`은 Google처럼 세 줄: "DMs and group DMs" · "Channel threads you write in or are mentioned in" · "New messages only. Taskforce never sends anything."
- 끊기 문구는 `ConnectionProvider.disconnectNote(for:)`. Slack은 "Slack messages are removed from Taskforce. Tasks stay." — 위 표의 "are deleted"는 Slack에서 메시지를 지운다고 읽힐 수 있어 바꿨다(PR 4 검토).
- 끊긴 연결(`needsReconnect`, Slack에서 앱을 지워 `revoked`로 남은 것)에도 Disconnect를 둔다. 처리방침이 "앱에서 끊으면 연결 기록이 지워진다"고 약속한다.
- 서버가 끊으며 바꾼 근거 인용("Slack 연결을 끊어 지웠어요")은 인용 부호 없이 "Removed when Slack was disconnected"로 보인다(`RemovedQuote`, `EvidenceView`). 맨 앞 근거는 남아 있는 인용을 먼저 고른다(`EvidenceDigest.lead`). 서버도 이 자리 표시를 AI에게 넘기기 · 물어보기 · 매칭(`SupabaseActionStore` `shortlist` · `unembedded`)에 넣지 않는다(`SLACK_DISCONNECTED_QUOTE`).
- `SourceService`는 `slack.com` 링크를 이미 Slack으로 알아본다(확인만).

## 4. 골든셋 · eval

**코드보다 먼저 만든다**(바이브코딩 원칙: 엔진 + eval 먼저). 본문은 2-5 형식과 글자까지 같게 쓰고 관련자를 채운다. 파일 이름은 `evals/golden/slack-*.json` · `seq-slack-*.json`. 아래 14건 + PR 1b에서 더한 확인용 3건(`*-heldout-*`).

| 케이스 | 보는 것 |
|---|---|
| `seq-slack-friday-to-monday` | **핵심 시나리오 2.** 회의록 "금요일까지 제안서" → DM "월요일에 받아도 괜찮아요" → 할 일 하나, 기한 월요일, 이력에 DM 인용 |
| `seq-slack-gap-reply` | 요청 "금요일까지 견적서 부탁드려요" → **한 시간 뒤 다른 묶음**의 `:+1:` (D1-b의 (가) · (나) 비교) |
| `seq-slack-thread-late-reply` | 스레드를 넣은 뒤 이틀 뒤 같은 스레드에 상대의 기한 변경 답글과 내 수락 → 다음 묶음(`[#채널 · 스레드 이어서]`)이 기존 할 일을 갱신 |
| `slack-dm-short-commit` | 상대가 "내일 받을 수 있을까요?"로 묻고 내가 "넵 오전 중으로 드릴게요"로만 답한다(기한은 상대의 말에) |
| `slack-dm-emoji-accept` | 같은 묶음 안의 요청 → `:+1:` |
| `slack-dm-decline` | 요청 → "이번 주는 어렵겠어요" → 할 일 없음 |
| `slack-dm-tentative` | "시간 되면 볼게요" → 자동 반영 안 됨 |
| `slack-dm-only-me` | 내가 쓴 줄만 있는 DM "IR 자료는 금요일까지 정리해서 공유드릴게요" → 상대는 머리줄의 DM 상대 (D7) |
| `slack-mpim-others-commit` | 그룹 DM에서 다른 사람끼리 한 약속 → 할 일 없음 |
| `slack-channel-mention-thread` | 채널에서 나를 언급한 요청 + 다른 사람의 기한 덧붙임 + 내 수락 |
| `slack-channel-mid-thread` | `[#채널 · 스레드 중간부터]` "이거 금요일까지 될까요?" (D2) — 확인 요청이면 맞음 |
| `slack-mixed-language` | 영어 · 한국어가 섞인 스레드 |
| `seq-slack-done` | Slack 약속 → 이틀 뒤 "방금 메일로 보내드렸어요" → 완료 |
| `seq-slack-requester-cancels` | 요청 → "그 건은 안 하셔도 돼요" → 취소 |
| 실제 5건 이상 (D6) | 본인 워크스페이스 DM · 스레드, 로컬에서 익명화 |

- eval에 두 가지를 더했다(PR 1, 파이프라인은 그대로): 케이스 묶음 `tags`와 `--tag`(채점 표에 `#slack` 줄), 기대 Action의 `needs_review`("확인 요청이면 맞음": "자동만" 단계에서 자동 반영되면 `REVIEW_EXPECTED` 오탐, 빠져도 누락 아님). 형식은 `evals/golden/README.md`.
- 기준(제안): 추출 precision · recall 0.9 이상(Phase 1 목표와 같음), 시퀀스 병합 정확도 100%. 못 미치면 원인을 적고 go live 여부를 정한다.
- 결과는 `evals/golden/README.md` 기록 표에 "Slack" 줄로 따로 적는다.

### 기준 점수 (PR 1, 2026-09-28)

`npm run eval -- --tag slack`, glm-5.3-flash · extract-v4 + judge-v4 + match-v1. 네 번 돌렸다(두 번째는 `seq-slack-thread-late-reply`가 모델 응답 시간 초과로 빠져 시퀀스 3/4, 뒤의 두 번은 검토 뒤 라벨 3곳을 보강하고). 틀린 시퀀스는 따로 더 돌렸다.

| 항목 | 결과 | 기준(제안) |
|---|---|---|
| 원문 하나 9건: precision · recall (자동+확인) | 100% · 85.7% (6/7), 네 번 같음 | 0.9 · 0.9 — recall 미달 |
| Jev 사람 라벨 일치율 | 100% (정답 · 함정 16개) | — |
| 시퀀스 5건: 병합 정확도 | **60% (3/5)**, 끝까지 돈 세 번 같음 | 100% — 미달 |
| 핵심 시나리오 2 (`seq-slack-friday-to-monday`) | 맞음 (네 번) | 맞음 |
| 비용 | 한 번 약 $0.012~0.017 | — |
| 기존 케이스 (전체 53건 한 번) | 회의록 · 메일 시퀀스 12/12, 원문 하나 91.8% · 93.8% — 오늘 같은 프롬프트의 이전 결과(93.0% · 90.9%)와 흔들림 범위 안. 이 PR은 파이프라인을 바꾸지 않았다 | 떨어지지 않음 |

틀린 것 세 가지. 셋 다 원문 형식이 아니라 **파이프라인(추출 · Jev)의 판단**에서 생겼다: Claim과 판정 이유를 직접 보면 추출 · 판정 단계에서 갈렸고, F2는 DM 관련자 형식을 바꿔도 같았다.

| # | 케이스 (재현) | 무엇이 일어났나 | 고칠 곳 (제안) |
|---|---|---|---|
| F1 | `seq-slack-thread-late-reply` (3/3) | 상대가 "금요일 오전까지만 주셔도 돼요"로 기한을 늦춰 주고 내가 같은 원문에서 "넵 그럼 금요일 오전에 올릴게요"로 받으면, 추출기가 **내 줄만** 뽑는다. Claim의 화자가 나라서 규칙 0이 "혼자 늦춤"으로 막고 기한은 목요일로 남는다(위험 신호 `unauthorized_change`). 기존 `friday-to-monday`는 내 답이 "넵 알겠습니다!"뿐이라 통과한다 | 추출 프롬프트: 상대의 허락과 내 수락이 함께 있으면 상대의 줄을 변경 근거로 뽑는다(extract-v5). Slack에서 흔한 모양이라 go live 전에 고친다 |
| F2 | `seq-slack-requester-cancels` (4/4, from/to 형식 포함) | 요청자 박지훈의 DM "경쟁사 가격표 건은 안 하셔도 돼요! 대표님이 이미 받으셨대요"를 Jev가 화자 `third_party` · 전언(`reported`)으로 판정한다. 뒤의 이유가 전해 들은 말이기 때문이다. 규칙 3에 따라 취소가 확인 요청으로 빠지고 상태는 `open` | Jev 판정 입력에 인용 줄의 화자를 넣는다(원문의 `이름:`에서 코드가 읽을 수 있다), 또는 judge 프롬프트에서 "이유만 전언이면 발언은 직접"을 분명히 한다(judge-v5) |
| F3 | `slack-channel-mid-thread` (2/2) | 첫 글이 없는 스레드의 "@윤지호 이거 금요일까지 될까요?"는 추출되지 않고, 같은 문장을 Jev에 직접 물어도 기각한다. 지금은 **조용히 사라진다** | D2의 크기를 보여 주는 케이스다. go live 전에 정한다: 누락으로 받아들일지, 무엇인지 모르는 요청도 확인 요청으로 보낼지(추출 규칙 변경 — 확인 요청 수가 늘어난다, 원칙 3) |

F1 · F2는 별도 PR(아래 6장 "1b")에서 프롬프트 버전을 올려 고치고, 전체 eval(회의록 · 메일 포함) 전후 숫자를 비교한다. PR 2 · 3과 동시에 할 수 있다.

### PR 1b 뒤 (2026-09-28)

F3는 "확인 요청으로 보낸다"로 정했다(2026-09-28). 고친 곳:

| # | 고친 곳 | 결과 |
|---|---|---|
| F1 | 추출 프롬프트 extract-v5: 앞선 약속의 기한을 상대가 늦춰 주고 사용자가 받으면 update 하나로, 인용은 상대의 말에서 | `seq-slack-thread-late-reply` 0/3 → 8/9 (추출기가 가끔 내 답만 뽑는다. 프롬프트로 고친 것이라 남는 흔들림) |
| F2 | 코드가 인용 줄의 화자 이름표를 읽고(`quoteSpeaker`), 병합이 붙일 할 일의 요청자와 비교해 화자 역할을 정한다(`withSpeakerFromLabel`): 요청자 본인이면 상대 · 직접 발언, 요청자가 아닌 사람이면 제3자. extract-v5는 취소 인용에서 뒤에 붙은 이유를 빼되 남의 허락을 전하는 말은 남긴다. judge-v5 `speaker_role` · `directness` 문구. 요청자가 아닌 사람이 허락을 전하는 연장은 안전장치 케이스 `seq-slack-relayed-extension`이 지킨다 | `seq-slack-requester-cancels` 0/4 → 9/9, 확인용 `seq-slack-heldout-cancel-hearsay` 9/9, 안전장치 `seq-slack-relayed-extension` 4/4 |
| F3 | extract-v5: `@이름`으로 부른 기한 있는 요청은 대상을 몰라도 뽑음. 코드 규칙: 인용이 속한 메시지가 사용자를 `@이름`으로 부르고 기각 사유가 "내 약속 아님" 하나면 확인 요청까지만(`decideOutcome`, 판정 기록 `rule`, TRUTH_RULES 1장 표) | `slack-channel-mid-thread` 누락 → 확인 요청(자동 반영 아님) |

프롬프트 예시는 골든셋 문장 · 이름과 겹치지 않게 썼다. 고친 것이 이 케이스들에만 맞춘 것이 아닌지 보려고 표현과 이름을 바꾼 **확인용 케이스 3건**(`tags: ["slack", "slack-heldout"]`: 기한 연장 수락 · 전해 들은 이유가 붙은 취소 · 첫 글 없는 `@이름` 요청)을, 화자 규칙이 규칙 3을 뚫지 않는지 보려고 **안전장치 케이스** `seq-slack-relayed-extension`(요청자가 아닌 동료가 DM으로 "○○ 님이 화요일도 된다고 하셨어요"를 전함 → 기한 유지)을 더했다. 코드 검토에서 처음 방식("1:1 대화의 상대는 요청자")이 이 경우를 자동 반영으로 뚫는 것이 드러나, 화자 역할을 판정 단계가 아니라 **병합 단계에서 붙일 할 일의 요청자와 비교해** 정하도록 바꿨다.

| 항목 | PR 1 기준 | PR 1b 뒤 (전체 eval 두 번) |
|---|---|---|
| Slack 원문 하나 (자동+확인) | 100% · 85.7% | 100% · 100% (8/8, 확인용 포함) |
| Slack 병합 정확도 | 60% (3/5) | **100% (8/8)**, 확인용 2/2 · 안전장치 포함. 최종 방식으로 돈 9번을 케이스별로 세면 스레드 답글(F1)만 8/9, 나머지 모두 9/9 |
| 회의록 · 메일 병합 | 12/12 | 12/12 |
| 회의록 · 메일 원문 하나 | 맞음 45 · 오탐 4 · 누락 3 | 같은 수준 (실행마다 오탐 · 누락 ±1) |
| 함정 문장 자동 반영 | 0 | 0 |

남은 것:
- `freelance-client-recap-email`의 "계약서 사본도 한 부 보내주실 수 있을까요?"(사용자 혼자 받은 메일의 요청, 아직 수락 전)는 Jev의 "내 약속" 확률이 기각선(0.4) 근처(0.33~0.41)라 실행마다 확인 요청과 기각을 오간다. 이번 변경 때문이 아니다. F3 규칙을 "혼자 받은 메일의 요청"으로 넓히면 확인 요청으로 고정되지만 확인 요청 수가 늘어서(원칙 3), Google 연동(Gmail) 골든셋을 만들 때 함께 정한다.
- 화자 이름표는 Slack · 메신저 형식("이름: 글")에서만 읽힌다. 이름표가 없는 메일 본문은 전과 같이 Jev 답을 쓴다.
- 이름 겹침: 사용자 별칭이 이름만("Daniel")이어도 "@Daniel Kim" · "@daniel.kim"은 사용자가 아니다(가장 긴 이름으로 읽기, 2026-09-29). 추출 · Jev도 같은 채널의 "Jiho Park"을 별칭 "Jiho"인 사용자로 헷갈리지 않았다(`slack-namesake-other-person` 3/3). 별칭은 가능하면 이름만이 아니라 전체 이름("Daniel Song")으로 적는 것이 안전하다.

### PR 2 확인 (2026-09-29, dev 앱 · 로컬 서버 · 운영 DB)

`Taskforce dev` 앱(taskforcelabs 워크스페이스, 사용자 권한 9개, 봇 없음)을 로컬 서버에 터널로 붙이고, 마이그레이션 `20261011000000_slack.sql`을 운영 DB에 적용한 뒤(사용자 승인) 본 계정에 시험용 Slack 연결 행(토큰 없음)을 넣어 두 번째 계정으로 보냈다.

| 시험 | 기대 | 결과 |
|---|---|---|
| 이벤트 URL 확인 | Verified | ✅ (서명 키를 읽은 뒤) |
| 두 번째 계정의 DM | 대기 표에 남음 | ✅ |
| 채널의 부르지 않은 글 | 버림 | ✅ DB에 없음 |
| 채널에서 본 계정을 부른 글 | 남고 스레드 추적 | ✅ |
| 그 스레드의 부르지 않은 답글 | 남음 | ✅ |
| DM 수정 | 대기 행의 글이 바뀜 | ✅ (`message_changed` → 고침 1) |
| 응답 · 로그 | 모두 200, 본문 · 이름 · id 없음 | ✅ 처리 0.7~1.9초 |

만들며 알게 된 것:
- 매니페스트는 JSON 탭으로 넣는다. YAML은 채팅에서 복사하며 들여쓰기가 깨져 권한이 0개로 읽혔다.
- "Create and Install"은 만들기만 되고 설치가 실패할 수 있다("Installation was not completed"). 앱 목록에 생긴 앱의 **Install App**에서 설치하면 된다. 설치 전(0 authed users)에는 이벤트가 오지 않는다.
- 이벤트 URL을 확인하기 전에 서버가 서명 키를 읽고 있어야 한다. `.env.local`을 고친 뒤 개발 서버를 다시 띄운다(워크트리의 `.env.local`이 링크면 자동으로 다시 읽지 않는다).
- 시험용 연결 행(본 계정의 `팀 id:사용자 id`, 토큰 없음)과 시험 메시지 대기 행은 운영 DB에 남아 있다. PR 3에서 앱으로 연결하면 같은 행이 갱신된다(토큰 · `connected_at`). PR 3 시험이 끝나면 대기 행을 지운다.

보안 검토(2026-09-29)로 고친 것: 지운 메시지는 행을 지우지 않고 표시만 남긴다(`deleted_at`, 늦게 온 재전송이 다시 넣지 못하게. DM만 행이 없어도 표시 행을 만든다) · 앱 해제는 DB 함수 하나(`revoke_slack_connections`)로 한 트랜잭션에서, 팀 id가 정확히 같고 이벤트 시각 전에 연결한 것만, `reauth`까지 · 팀 id는 영문 대문자 · 숫자만 받는다 · 설치 조회(D4)는 이 메시지와 관계있을 수 있는 다른 연결이 있을 때만, 0.7초 · 2쪽 · 연결별 처리는 동시에 · 채널 글을 고쳐 나와 무관해지면 지움 표시 · 서명 헤더가 없거나 1MB를 넘으면 본문을 읽기 전에 거절. 마이그레이션 `20261012000000_slack_tombstones_revoke.sql`.

PR 3에 넘기는 것(PR 3에서 함, 아래 "PR 3 구현"): 동기화는 `deleted_at`이 있는 대기 행을 원문에 넣지 않는다 · 대기 행 3일 · 추적 스레드 14일 정리(retention cron) · `app_uninstalled`가 한 이용자만 앱을 지워도 오는지 두 이용자로 확인(Slack 문서는 마지막 토큰이 거둬졌을 때라고 한다. 한 이용자로는 확인함, 두 이용자는 PR 4 전체 검증에서) · **운영 Slack 앱(L7)의 이벤트 URL은 PR 3(정리 · 동기화)을 배포한 뒤에 켠다** (그 전에는 남의 DM 글이 정리 기한 없이 쌓인다).

### PR 3 구현 (2026-09-29)

| 부분 | 파일 | 하는 일 |
|---|---|---|
| 연결 | `slack/run.ts` `connect` | `oauth.v2.access` → `auth.test`(워크스페이스 주소) → `saveConnection`(`팀:사용자`, 토큰 암호화) → 설정 `{ slackUserId, teamId, teamUrl }` |
| 동기화 | `slack/sync.ts` · `bucket.ts` | 대기 행 → 이름(`users.info` · `conversations.info`, 7일 캐시) → 묶기(2-5) → `slack_ingest_source`(원문 저장 + 읽은 행 표시, 한 트랜잭션) → 파이프라인 → 대기 행 본문 비움 |
| 끊기 | `DELETE /api/v1/connections/:id` → `handleConnectionDelete` | 서비스 쪽 토큰 폐기(`auth.revoke`) → `disconnect_connection`(Slack이면 `purge_slack_data` = D3, 그다음 연결 행 삭제, 한 트랜잭션). Notion도 끊을 때 토큰이 폐기된다 |
| 앱 해제 | `revoke_slack_connections`(새 버전) | 토큰 삭제 + D3 + `revoked`. 동기화 중 토큰 오류(`token_revoked` · `invalid_auth` · `account_inactive`)도 같은 함수로 |
| 정리 | `/api/cron/retention` → `purge_slack_buffers` | 받은 지 3일 지난 대기 행(넣은 행 · 못 넣은 행 · 지움 표시), 활동 14일 지난 추적 스레드, D3 원문에 남은 글자(안전망) |
| 연결 틀 | `registry.ts` | `slack: slackConnector`. 앱의 Connect가 열리고, cron · Sync Now · 계정 삭제 때 토큰 폐기가 이어진다 |

구현하며 정한 것:
- **이름은 실명(`real_name`)을 먼저** 쓴다. 회의록 · 메일의 이름과 맞아야 담당 · 상대를 알아본다. 실명이 비었으면 표시 이름. Slack이 알려 주지 않는 id(지운 사용자 등)는 "알 수 없는 사용자"로 쓰고 빈 이름으로 캐시해 7일 동안 다시 묻지 않는다. 토큰 · 속도 제한 오류는 동기화를 멈추고 다음 동기화에서 다시 한다(대기 행은 3일 남는다).
- **같은 묶음 외부 id가 다시 나오면**(동시 동기화) 넣지도 표시하지도 않는다. 넣은 쪽이 자기 행을 이미 표시했으므로, 남은 행(늦게 온 메시지)은 첫 ts가 달라 다음 동기화에 새 묶음이 된다. 대기 행이 같은 열쇠에 묶여 멈추는 일은 없다(표시는 원문을 지울 때만 풀린다).
- **읽은 뒤 Slack에서 지운 메시지**가 묶음에 있으면 넣지 않는다: 넣기 함수가 고른 행을 잠그고 지움 표시를 확인한다. 다음 동기화가 지운 글 없이 다시 묶는다.
- **첫 글 없는 채널 스레드**: 첫 묶음 외부 id(`t:{대화}:{첫 글}:{첫 글}`)가 있으면 `스레드 이어서`, 없으면 `스레드 중간부터`. DM · 그룹 DM의 스레드는 늘 `이어서`(모든 글을 남기므로 첫 글은 본 대화 원문에 있다).
- **글 없는 메시지**(파일만)는 줄로 쓰지 않는다. 묶음이 다 비면 넣지 않고 3일 정리로 지운다.
- **본문 형식 테스트**는 골든셋 파일을 직접 읽어 글자까지 비교한다(`bucket.test.ts`: DM · 내 줄만 있는 DM · 채널 언급 스레드 · 중간부터 스레드 · 그룹 DM).
- **끊기의 토큰 폐기가 실패해도**(Slack 장애) 끊기 · D3는 계속한다. 우리 쪽 토큰은 연결과 함께 지워지고 데이터 지우기가 더 급하다. 로그만 남긴다.
- **`owner_delete` 삭제는 별도 파일 `20261014000000`**: 운영 서버의 지금 코드가 이 정책으로(사용자 권한) 끊는다. DB가 하나라 먼저 적용하면 새 코드를 배포하기 전까지 앱의 연결 끊기가 404가 된다. 배포 뒤에 적용한다(런북).
- **지운 원문 안내**: 원문을 고르거나 누락 신고하면 이유에 따라 "Slack 연결을 끊어 원문을 지웠어요." 또는 90일 문구(`purgedSourceMessage`). 앱 화면 문구는 PR 4.
- **웹 /lab(내부 도구)**: Slack 연결 버튼과 끊기 확인 문구(시험용). 앱의 연결은 기존 `start` · `complete` 흐름 그대로.
- **운영에서는 Slack 연결을 닫아 둔다**(`SLACK_CONNECT_ENABLED`, 비우면 개발 서버에서만 열림). 연결 틀에 올리면 앱의 "Coming soon"이 바로 Connect가 되는데, 처리방침 · 앱 문구(PR 4)가 아직 옛 내용이다. PR 4를 배포하며 `true`로 켠다. 닫혀 있어도 이미 있는 연결의 토큰 폐기 · 이벤트 받기는 한다.

코드 리뷰(2026-09-29)로 고친 것:
- **동기화 도중의 끊기 · 앱 해제**(높음): 끊긴(revoked) · 지운 연결에는 원문을 넣지 않는다(연결 행 잠금). 이미 처리 중이던 원문은 처리가 끝난 뒤 D3로 지워졌는지 보고 다시 지운다(`slack_repurge_if_disconnected`, 처리 뒤 늘 부른다). `recordSync`가 끊긴 연결을 `active`로 되살리지 않는다(Notion도 같다). 매일 정리가 D3 원문에 남은 글자를 다시 지운다(안전망).
- **이름 캐시**: Slack이 "그런 id 없음"이라고 할 때만 빈 이름으로 7일 캐시한다. 일시 오류(장애 · 속도 제한)는 동기화를 멈추고, 그때까지 찾은 이름은 남긴다.
- **동기화 중 토큰 오류인데 그 사이 다시 연결했으면** 새 연결을 끊지 않는다.
- **받을 때 ts 모양 확인**(숫자.숫자): 잘못된 ts 하나가 연결의 동기화를 3일 동안 막지 않게.
- D3가 쓰는 `evidence(source_id)` · `claims(source_id)` 인덱스.

dev 워크스페이스 확인 (2026-09-29, Taskforce dev 앱 · 로컬 서버 · 운영 DB, 마이그레이션 `20261013000000` 적용 뒤):

| 시험 | 기대 | 결과 |
|---|---|---|
| 연결 (앱 흐름: start → 권한 화면 → callback → 완료 대기 → complete) | 사용자 권한 9개, 연결 `active`, 토큰 암호화, 설정에 Slack id · 팀 · 주소 | ✅ (완료 단계는 앱 대신 같은 서버 함수로 불렀다) |
| 첫 동기화 (PR 2 시험 메시지 3개) | DM 한 묶음 · 채널 스레드 한 묶음, 행 표시 · 본문 비움 | ✅ 원문 2건 `[DM · 상대]` · `[#채널]`, 대기 0 |
| 30분 전 동기화 | 넣지 않음 | ✅ `settling 1` |
| **핵심 시나리오 2**: 회의록 "금요일까지 제안서" → 두 번째 계정 DM "제안서는 월요일에 받아도 괜찮아요" | 새 할 일 없이 기한 10-02 → 10-05, 이력에 Slack 인용 | ✅ 병합 `updated 1 · new 0`, 기한 변경 `rule0+rule4`, 근거에 DM 인용 |
| 원본 링크 | 그 DM 메시지 | ✅ 링크의 대화가 그 DM(브라우저에서는 Slack이 데스크톱 앱을 먼저 연다) |
| **연결 끊기** (`DELETE /api/v1/connections/:id`, 앱과 같은 API) | Slack 앱 목록에서 사라짐, D3 표 전부 | ✅ 204. dev 앱의 Install App 화면이 "Install to …"로 돌아감(토큰 폐기). 원문 3건 본문 · 관련자 빈 값 · 제목 `Slack` · `disconnected`, 근거 인용 2건 모두 "Slack 연결을 끊어 지웠어요", Claim 5행은 남고 글자 0, 판정 기록 0, 대기 · 추적 · 이름 · 토큰 행 0. 할 일 기한(10-05) · 상태 그대로 |
| 끊은 뒤 Slack이 보낸 이벤트 | 받고 버림 | ✅ `tokens_revoked` · `app_uninstalled` 둘 다 200(끊을 연결 없음). 이용자가 한 명뿐일 때 마지막 토큰을 폐기하면 `app_uninstalled`도 온다 |

만들며 알게 된 것: `SLACK_CLIENT_ID`에 앱 ID(`A…`)를 넣으면 권한 화면이 "Invalid client_id"로 멈춘다(Client ID는 숫자.숫자, `.env.example`에 적음). 로컬 로그인 링크는 `localhost:3000`만 허용돼 있어 3100 서버는 이메일 링크로 로그인할 수 없다.

남긴 낮은 위험(재검토 2026-09-29, 승인): 3일 넘은 대기 행을 넣는 동기화와 매일 정리가 같은 행을 반대 순서로 잠그면 Postgres가 한쪽을 멈춘다(다음 동기화 · 다음 날 정리가 다시 한다). 고치려면 정리 쿼리에 `for update skip locked`를 더하는 마이그레이션. 속도 제한의 `Retry-After`는 기다리지 않는다(찾은 이름은 남기므로 다음 동기화가 이어서 찾는다).

자체 검토에서 남긴 것(D3 범위, docs/legal/self-review.md 2번. 나중에 변호사 검토 때의 질문): 원문 행의 링크 · 외부 id(워크스페이스 주소 · 채널 id · 메시지 ts), 끊긴 연결 행의 워크스페이스 이름 · 주소, Claim 값 · 할 일 제목 · 상대 이름 · 이력(`action_events`)은 남는다. 끊은 뒤 근거 자리에 남는 "Slack 연결을 끊어 지웠어요"는 매칭에 쓰지 않는다. 끊기 전에 제목 · 인용으로 만든 할 일 임베딩(`actions.embedding`)은 남는다.

### 어댑터 단위 테스트 (eval 아님, PR 2 · 3)

- 서명 정상 · 변조 · 5분 초과, 버리는 규칙 표 전부, 봇 · 시스템 하위 유형, 고침 · 지움, 넣은 뒤 재전송, 동기화 도중 도착한 메시지가 남는지, 묶음 자르기(30분 · 자정 · 3시간 · 100개), 넣은 뒤 답글이 다음 묶음이 되는지, 본문 형식(본인 이름 · 언급 · 링크), `error` 연결이 이벤트를 받는지, 한 워크스페이스 두 이용자, `app_uninstalled` · 늦게 온 `tokens_revoked`, D3 표의 모든 칸.

## 5. 문서 · 처리방침 맞추기

**PR 4에서 아래를 모두 고쳤다 (2026-09-29).** 법률 검토 상자는 2026-09-29 자체 검토로 지웠다(docs/legal/self-review.md).

같은 PR에서 한국어 · 영어를 함께 고친다(`docs/legal/README.md` 게시 규칙 3 · 4). 아래 줄 번호는 `privacy.ko.md` 기준(2026-09-28)이다. `privacy.en.md`는 같은 절의 대응 문장을 고친다(줄 번호는 조금 다르다).

| 곳 | 지금 | 고칠 것 |
|---|---|---|
| 3장 연결 끊기 문단 (89줄) | "이미 가져온 원문과 거기서 만든 할 일은 남습니다" | Slack은 원문 · 근거 인용을 지우고 할 일만 남긴다 (D3) |
| 3장 Slack "남기는 메시지" (116줄) | "이용자가 쓴 메시지와 그 스레드" | "이용자가 쓰거나 이용자를 언급한 스레드" (2-4 추적 규칙) |
| 3장 Slack "저장하는 것" (117줄) | "보관 기간은 5장과 같습니다(계정 삭제 때까지)" — **지금도 틀리다**(5장은 본문 90일) | 본문 90일, 연결을 끊거나 앱을 지우면 바로. 대화 이름(D7) 추가 |
| 3장 Slack "권한" (118줄) | 권한 5개 | 9개 (D7) |
| 3장 법률 검토 상자 (123줄) | 90일 · 인용 유지 | D3 · 14 영업일 정책 반영 → 자체 검토로 지움 |
| 5장 표 (158 · 160줄) | "연결을 끊어도 남습니다", "근거 인용은 그대로 남습니다" | Slack 예외. 행 추가: Slack 대기 메시지(3일) · 추적 스레드(활동 뒤 14일) · 이름 캐시(연결을 끊을 때까지) |
| 5장 파기 절차 (170~177줄) | 계정 삭제 · 90일 자동 삭제만 | 연결 끊기 때 Slack 데이터 삭제, 대기 메시지 3일 정리 |
| 11장 권리 표 (255줄) | "서비스 연결 끊기" | Slack은 끊으면 Slack 원문도 지워진다는 것 |

그 밖에:
- `docs/legal/README.md` 구현 대조표의 Slack 줄을 구현 값으로 바꾼다.
- [slack-app.md](slack-app.md): D7 권한은 반영했다(2026-09-28: 1장 요약 · 2장 매니페스트 · 3-1 권한 표 · 5장 권한 주소 · 9장 7번). 남은 것: 2장 매니페스트에 `tokens_revoked` · `app_uninstalled` (PR 2에서 봇 없이 구독되는지 확인한 뒤).
- 런북 2장 표의 `SLACK_REDIRECT_URI` · `SLACK_APP_TOKEN` 비고.
- CLAUDE.md 원칙 2 · 5에 D3 예외 한 줄 (2026-09-28 결정, PR 3).

## 6. 순서 (한 세션 = 한 PR)

| PR | 내용 | 끝난 기준 | 기간 |
|---|---|---|---|
| 1 | 골든셋(4장 표) + eval 묶음별 표 · "확인 요청이면 맞음" + 지금 파이프라인으로 기준 점수, D1-b · 관련자 모양 비교 | `npm run eval` 기록에 Slack 줄. 파이프라인 코드 변경 없음. **끝남 (2026-09-28)**: 4장 "기준 점수" | 1~2일 |
| 1b | 파이프라인 보완: F1(추출 프롬프트) · F2(Jev 판정 입력 또는 프롬프트), F3 결정 | Slack 병합 정확도 100%, 전체 eval에서 회의록 · 메일 숫자가 떨어지지 않음. **끝남 (2026-09-28)**: 4장 "PR 1b 뒤" | 1~2일 |
| 2 | 마이그레이션(새 표 · `connected_at` · `raw_text_purge_reason`) + 이벤트 받기(서명 · 가르기 · 대기 저장 · 재전송 · 앱 해제) | 단위 · RLS 테스트. dev 앱 이벤트 URL "Verified", 채널 잡담은 DB에 없고 DM은 `slack_messages`에 있음. **끝남 (2026-09-29)**: 아래 "PR 2 확인" | 2일 |
| 3 | 연결 · 묶기 · 넣기 · 이름 · 연결 끊기 라우트(서버 권한 · 토큰 폐기 · D3) + `owner_delete` 정책 삭제 + registry + retention | dev 워크스페이스에서 시나리오 2가 45분 안에 기존 할 일의 기한 변경으로 나타남. 앱에서 끊으면 Slack 앱 목록에서도 사라짐. **끝남 (2026-09-29)**: 4장 "PR 3 구현" | 2~3일 |
| 4 | 앱 문구(확인 창 일반화 · 끊기 문구) + 처리방침 · 문서 맞추기 + 전체 검증 | 8장 전부. 런북 C5 ✅. **코드 · 문서 끝남 (2026-09-29)**: 운영에서만 확인할 수 있는 칸(8장)은 go live 순서(런북)에서 | 1~2일 |

PR 1은 운영 서버 배포와 무관하게 지금 시작할 수 있다. PR 2부터는 7장의 dev 앱이 있어야 한다.

## 7. 사용자가 먼저 할 일

| # | 할 일 | 언제까지 | 비고 |
|---|---|---|---|
| U1 | ~~D3 · D7~~ 결정됨 (2026-09-28). D1 · D1-b · D2 · D4~D6을 권장안과 다르게 하려면 알려 주기 | PR 1 전 | D3의 범위는 자체 검토(docs/legal/self-review.md 2번)로 정했다 |
| U2 | 개발 워크스페이스 고르기 + **시험용 두 번째 Slack 계정** | PR 2 전 | 시나리오 2는 "상대가 보낸 DM"이 필요하다. 혼자서는 시험할 수 없다 |
| U3 | 터널 도구 설치 (`brew install cloudflared` 또는 ngrok) | PR 2 전 | Slack은 이벤트를 공개 HTTPS로만 보낸다. 이 Mac에는 둘 다 없다(2026-09-28 확인). 주소가 고정되는 쪽이 편하다: 주소가 바뀔 때마다 dev 앱의 redirect · 이벤트 URL을 고쳐야 한다 |
| U4 | **Taskforce dev** Slack 앱 만들기 | PR 2 중 | [slack-app.md](slack-app.md) 2장 매니페스트(D7 권한 4개 반영됨)에서 redirect · 이벤트 URL만 터널 주소로. 비밀값 3개는 `.env.local`에만 |
| U5 | 운영 Slack 앱 (L7) | 서버 배포(I3) 뒤, PR 4 전 | slack-app.md 9장 순서 그대로 |
| U6 | D6 실제 원문 5건 고르기 | PR 1 중 | 익명화는 로컬에서, 원문은 커밋하지 않는다 |

## 8. 끝난 기준 (체크리스트 C5)

2026-09-29 상태. dev 워크스페이스 · 로컬 서버 · 운영 DB로 확인한 것은 ✅, 운영 서버 · 운영 Slack 앱이 있어야 볼 수 있는 것은 go live 순서(런북 "Slack 켜기")에서 확인한다.

- [x] `npm run lint && npm run typecheck && npm run test && npm run eval` 통과, Slack 골든셋 숫자가 README 기록 표에 있음 (PR 1 · 1b 기록, PR 4에서 `--tag slack` 다시 돌림)
- [x] dev 워크스페이스: 회의록 "금요일까지 제안서" → 두 번째 계정의 DM "월요일에 받아도 괜찮아요" → **새 할 일 없이** 기존 할 일의 기한이 월요일, 이력에 Slack 인용, 링크가 그 메시지를 연다 (PR 3)
- [x] 나를 언급하지 않은 채널 글은 `slack_messages` · `sources` 어디에도 없음 (PR 2 · 3)
- [x] 앱에서 연결 끊기 → Slack 앱 목록에서 사라짐(`auth.revoke`). 그 연결의 대기 · 추적 · 이름 행 0건, 원문 본문 · 관련자 빈 값, 근거 인용 · Claim 인용 · `value_text`에 Slack 글자 없음, 판정 기록 0건 (PR 3, 앱과 같은 API로)
- [x] Slack에서 앱 제거 → 연결 `revoked`, 같은 데이터 0건 (2026-09-29 운영: 연결된 상태에서 Slack 쪽 Revoke, 런북 "운영 확인 결과"). **두 이용자 시험은 남음**
- [x] Vercel 로그에 메시지 본문 · 이름 · 토큰 없음 (2026-09-29 운영 확인)
- [x] 앱이 요청하는 권한 9개가 처리방침 3장 목록과 같음(`SLACK_USER_SCOPES`), 3장 · 5장 · 11장 · 12장 문장이 구현과 같음 (PR 4, 한국어 · 영어. 검토에서 과장 · 빠진 것 — 앱 제거 때 토큰 폐기 요청, 임베딩이 남음, 대기 본문을 비우는 때, 이름 새로 읽기, 12장 "모든 할 일에 인용" — 을 고쳤다)
- [x] Slack에서 앱을 지웠다는 이벤트를 놓쳐도 하루 안에 지움: 매일 `/api/cron/retention`이 끊기지 않은 Slack 연결마다 `auth.test`를 불러, 토큰을 쓸 수 없으면 앱 해제와 같게 끊는다(`slack/health.ts`, PR 4)

## 9. 위험과 확인한 사실 (2026-09-28)

| 위험 | 내용 | 대응 |
|---|---|---|
| 과거 메시지 없음 | 연결한 뒤의 메시지부터라서 첫 며칠은 Slack에서 생기는 할 일이 적다 | 연결 안내 한 줄(3장). 1주 사용에서 Slack 원문 · 할 일 수를 본다 |
| 채널 맥락 결손 | 채널에서 "제가 할게요"의 대상이 앞 글에 있으면 빠진다 | D2. 골든셋 `slack-channel-mid-thread` 점수로 판단 |
| 끊긴 답장 | 30분 넘게 끊긴 답장은 맥락 없이 들어간다 | D1-b, 골든셋 `seq-slack-gap-reply` |
| 묶음 사이의 회의 | DM 묶음(최대 3시간) 사이에 회의가 있었으면, 묶음 안의 뒤 발언이 회의보다 앞선 것으로 판정될 수 있다(시각 = 묶음 첫 메시지) | 3시간 상한으로 줄인다. 1주 사용에서 실제로 생기는지 본다 |
| Marketplace 길이 좁다 | Slack은 "user token `*:history` scopes"를 실시간 검색 · MCP 서버 같은 쓰임 없이는 "unlikely to approve"라고 적고 있다. 등록 조건은 활성 워크스페이스 10곳 이상, 기능 심사 새 앱 최대 10주 | 베타는 비Marketplace 공개 배포로 한다(Slack은 이 방식을 파일럿 · 시험용으로 둔다). **정식 출시 전에 Slack 경로를 다시 정한다.** 유료화하면 "Commercial Distribution" 계약이 필요하다 |
| 데이터 삭제 의무 | 앱을 지우면 관련 데이터를 14 영업일 안에 모두 지워야 한다 | D3 · 2-7 |
| 이벤트 유실 | 3초 안에 답하지 못하면 3번 다시 보내고, 60분 동안 95% 넘게 실패하면 구독이 꺼진다. 2026-02에 생긴 Delayed Events를 켜면 24시간 동안 매시간 다시 보낸다 | 저장까지만 동기로(2-4). Delayed Events는 dev 앱에서 설정 위치를 확인하고 켠다 |
| 같은 워크스페이스 이용자 | 이벤트는 워크스페이스에 한 번만 온다 | D4 |
| 공개 채널 범위 | 사용자 토큰은 이용자가 들어간 채널의 이벤트만 받는다 | 이용자가 들어간 공개 채널의 글이 왔다(2026-09-29 dev 앱). 들어가지 않은 채널은 PR 3 시험 때 한 번 더 본다. 처리방침 문장("이용자가 속한 대화")과 맞다 |
| 확인한 것 (2026-09-29) | 봇 없는 앱도 `tokens_revoked` · `app_uninstalled`를 구독할 수 있다(필요 권한 none, "Subscribe to bot events"에 넣는다). 설치하지 않은 이용자의 메시지는 오지 않는다 — 앱을 설치(연결)한 뒤의 메시지부터다 | slack-app.md 2장 매니페스트에 두 이벤트를 넣는다 |
| 확인하지 못한 것 | `apps.event.authorizations.list`의 속도 등급, 관리자 승인 워크스페이스에서 callback이 돌아오는지 | PR 3 · 공개 배포 때 확인하고 이 표를 고친다 |

### 출처

- 비Marketplace 앱 속도 제한 (2025-05-29, 이후 수정): <https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps>
- Events API (한 이벤트는 한 번, `apps.event.authorizations.list`, 3초 · 재시도 · 30,000건/시간): <https://docs.slack.dev/apis/events-api/>
- Marketplace 설치 수 조건 (2026-09-01): <https://docs.slack.dev/changelog/2026/09/01/slack-marketplace-install-requirement>
- Marketplace 가이드라인 (`*:history` 심화 심사, "unlikely to approve", 2026-09-28 원문 확인): <https://docs.slack.dev/slack-marketplace/slack-marketplace-app-guidelines-and-requirements/>
- 배포 방식 (비공개 배포는 파일럿 · 시험용): <https://docs.slack.dev/distribution/>
- Slack API 약관 (2025-10-10 시행): <https://slack.com/terms-of-service/api>
- Slack 개발자 정책 (2024-12-10 시행, 14 영업일 삭제 · LLM 학습 금지, 2026-09-28 원문 확인): <https://docs.slack.dev/developer-policy/>
- 토큰 갱신: <https://docs.slack.dev/authentication/using-token-rotation> · 앱 해제 이벤트: <https://docs.slack.dev/reference/events/app_uninstalled>
