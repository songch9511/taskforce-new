# Slack 연동: 구현 계획 (다음 마일스톤)

관련 문서: [go live](../GO_LIVE.md) "현재 상태와 진행 순서" 3 · [런북 체크리스트 C5](runbook.md#go-live-체크리스트) · [Slack 앱 설정](slack-app.md) · [처리방침 3장 Slack](../legal/privacy.ko.md) · [진실 판정 규칙](../TRUTH_RULES.md)

작성: 2026-09-28. [GO_LIVE.md](../GO_LIVE.md) 진행 순서 3(체크리스트 C5, 다른 문서의 "트랙 2-4")을 코드로 옮기기 전에 **정할 것 · 만들 것 · 끝난 기준**을 적는다.
Slack 앱 설정과 권한을 고른 이유는 [slack-app.md](slack-app.md)가 기준이다. 이 문서는 서버 · 앱 · eval 쪽이다. **코드는 아직 쓰지 않았다.** 초안을 코드와 대조해 검토했고(2026-09-28), 지적 15건을 반영했다.

## 0. 한눈에

| 항목 | 내용 |
|---|---|
| 목표 | 테스터가 앱에서 Slack을 연결하면, 그 뒤 DM · 그룹 DM · 나를 언급한 글 · 내가 쓴 글에서 약속이 할 일로 생긴다. 메시지로 바뀐 기한은 **새 할 일을 만들지 않고** 기존 할 일에 반영된다 (PRD 핵심 시나리오 2) |
| 기간 | 코드 1~2주 (PR 4개, 6장) |
| 시작 조건 | 1장 결정(D3 · D7 결정됨, 나머지 권장안). 개발 워크스페이스 · 시험용 두 번째 계정 · **Taskforce dev** Slack 앱(7장). 운영 서버 배포(I1~I3)는 개발 시작에는 필요 없고 운영 앱(L7)을 만들 때 필요하다 |
| 끝난 기준 | 8장. 요약: Slack 골든셋 eval 기록 · 개발 워크스페이스에서 시나리오 2가 끝까지 됨 · 버린 채널 메시지가 DB에 없음 · 연결을 끊으면 토큰과 Slack 데이터가 지워짐 · 처리방침과 구현이 같음 |
| 파이프라인 | **고치지 않는다.** Slack은 "Source를 만들어 파이프라인에 넣는 어댑터"다([VIBE_CODING_PLAN.md](../VIBE_CODING_PLAN.md) Phase 6). 추출 · 검증 · Jev · 매칭 · 진실 판정은 Notion과 같다. 예외는 D3의 데이터 지우기뿐이다 |

## 1. 시작 전에 정할 것

**D3 · D7은 결정했다 (2026-09-28, 권장안대로).** 나머지는 권장안으로 시작하고, 다르게 하려면 PR 1 전에 정한다. D3의 "associated Data" 범위(할 일 제목을 남겨도 되는지)는 L9 법률 검토에서 확인한다.

| # | 정할 것 | 권장 | 이유 | 다른 선택 |
|---|---|---|---|---|
| D1 | 원문 하나의 단위와 넣는 때 | DM · 그룹 DM은 **대화가 30분 멈추면** 그때까지를 원문 하나로. 스레드는 스레드 하나. 한 묶음은 **한국 시간(KST) 자정을 넘지 않고** 최대 3시간 · 100개 (기한 계산이 KST 고정이다, `dates.ts`. 이용자별 시간대는 저장하지 않는다) | Notion의 "마지막 수정 뒤 30분"(`settleMinutes`)과 같다. 시나리오 2의 반영까지 최대 45분(30분 + cron 15분). 자정 · 3시간 상한은 날짜 계산 때문이다: 기한("내일까지")과 Claim 시각은 모두 원문의 `occurredAt` 하나로 계산된다(`verify.ts`의 `checkDue`, `merge.ts`). 묶음이 날을 넘으면 "내일"이 하루 틀리고, 길면 사이에 있던 회의보다 먼저 한 말로 판정된다(TRUTH_RULES 규칙 4) | 10분: 빠르지만 대화가 더 잘게 쪼개진다 |
| D1-b | 30분 넘게 끊긴 답장의 맥락 | **PR 1의 eval로 정한다.** (가) 맥락 없이 넣기 (나) 같은 대화의 앞 원문 마지막 몇 줄을 `(앞 대화)` 표시와 함께 앞에 붙이기 | 요청 뒤 한 시간 만에 온 `:+1:`은 다음 묶음이 되어 무엇에 대한 수락인지 모른다. (나)는 앞 줄에서 같은 약속을 다시 뽑을 수 있지만 매칭이 중복으로 합친다(원칙 4). 어느 쪽이 나은지는 골든셋 `seq-slack-gap-reply`로 잰다 | — |
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
| `src/lib/retention.ts` · `/api/cron/retention` | 새 정리 RPC 호출: 넣은 지 3일 지난 대기 행, 활동 14일 지난 추적 스레드 | DB 테스트 |
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
| 가르기 (연결마다) | DM(`im`) · 그룹 DM(`mpim`): 모두 남김. 채널(`channel` · `group`): 본문에 `<@이용자id>`가 있거나, 보낸 사람이 이용자거나, **추적 중인 스레드**의 답글일 때만. 이용자가 쓰거나 언급된 글이 스레드 첫 글이거나 스레드 안이면 그 스레드를 추적에 올린다(처리방침 3장 문장을 여기에 맞춘다, 5장). 봇 · 시스템 하위 유형(`bot_message` · `channel_join` · `channel_leave` 등)은 버린다 |
| 저장 · 재전송 | 보통 메시지는 `slack_messages`에 `(connection_id, channel_id, ts)`로 넣되 **이미 있으면 아무것도 하지 않는다.** 행은 원문으로 넣은 뒤에도 3일 동안 표시만 남기므로(2-6), Slack이 늦게 다시 보낸 이벤트(`X-Slack-Retry-Num`, Delayed Events)가 이미 넣은 메시지를 다시 넣거나 고친 글을 옛 글로 덮지 않는다 |
| 고침 · 지움 | `message_changed`: 아직 넣지 않은 행이면 본문을 바꾼다. `message_deleted`: 아직 넣지 않은 행이면 지운다. 이미 원문으로 넣었으면 그대로 둔다(본문은 90일 뒤 지움, slack-app.md 7장 검토 3) |
| 답 | 저장까지 동기로 하고 200. 저장이 실패하면 5xx로 답해 Slack이 다시 보내게 한다. 받을 연결이 없는 이벤트 · 버린 이벤트도 200 (60분 동안 95% 넘게 실패하면 Slack이 구독을 끈다) |
| 앱 해제 | `tokens_revoked`: 이벤트에 든 사용자 id의 연결만. `app_uninstalled`: **그 워크스페이스의 모든 Taskforce 연결.** 두 이벤트는 순서 없이 온다. 연결의 `connected_at`이 이벤트 시각(`event_time`)보다 뒤면(그 사이 다시 연결) 건드리지 않는다. `created_at`은 다시 연결해도 그대로이고(`saveConnection`이 기존 행을 고친다), `updated_at`은 동기화마다 바뀌어서 둘 다 쓸 수 없다 → 새 열(2-6). 해당 연결은 `revoked`로 바꾸고 D3대로 지운다 |
| 로그 | 이벤트 종류 · 결정(남김/버림/연결 없음) 개수만. 본문 · 이름 · Slack id는 남기지 않는다 |

### 2-5. 묶기와 넣기 (`sync`)

| 항목 | 규칙 |
|---|---|
| 묶음 열쇠 | DM · 그룹 DM 본 대화: `c:{channel}`. 스레드(모든 대화 종류): `t:{channel}:{thread_ts}`. 채널에서 남긴 첫 글: `t:{channel}:{ts}` (나중에 답글이 달리면 그 스레드가 된다) |
| 넣는 때 | 마지막 메시지가 30분 지남. 묶음이 KST 자정 · 3시간 · 100개에 닿으면 거기서 자른다(D1). **자른 앞부분은 바로 넣을 수 있게** `lastEditedAt`을 30분 전 이하로 준다 — `ingestItems`가 모든 항목에 30분 규칙을 다시 걸기 때문이다(`ingest.ts`) |
| 외부 id · 버전 | `externalId = {열쇠}:{묶음 첫 ts}`, `externalVersion = {묶음 마지막 ts}`. 연동 공통 규칙은 "한 항목은 한 번만 넣는다"(`ingest.ts`)라서, 넣은 뒤 같은 스레드에 달린 답글은 새 첫 ts의 **다음 묶음**이 된다. unique 인덱스 `(connection_id, external_id, external_version)`와도 맞다 |
| 종류 · 제목 | `kind = message`, `writtenByMe = null`(메시지는 한 사람이 쓴 문서가 아니다). 제목: `Slack · DM with 김민지` · `Slack · Group DM` · `Slack · #fundraising` |
| 본문 형식 | 아래. 골든셋(4장)과 글자까지 같게 한다 |
| 관련자 | DM: 상대와 이용자. 그룹 DM · 채널: 묶음에서 글을 쓴 사람 + 언급된 사람(구성원 목록 `conversations.members`는 부르지 않는다). `attendees`로 넣을지, DM은 `from`(상대) · `to`(이용자)로 넣어 `sole_recipient`가 되게 할지는 PR 1 eval로 고른다(Jev의 "내 일인가" 신호가 달라진다) |
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
- 스레드 첫 글이 없으면(채널 첫 글이 나와 무관해 버렸고 답글에서 나를 언급) 머리줄을 `[#채널 · 스레드 중간부터]`로 쓴다(D2).
- D1-b에서 (나)를 고르면 앞 원문의 마지막 몇 줄을 `(앞 대화)` 아래에, 새 메시지를 `(새 메시지)` 아래에 둔다.

### 2-6. 데이터 (새 마이그레이션 `20261011000000_slack.sql`)

새 표는 모두 **서버만 쓰는 표**다: `user_id`, 부모 연결과 `(connection_id, user_id)` 복합 외래키 + `on delete cascade`, RLS 켬 + `anon` · `authenticated`의 모든 권한 회수. 앱이 읽을 일이 없고 원문 본문이 들어 있어서 `owner_all` 대신 `oauth_handoffs` · `connection_secrets`와 같은 방식을 쓴다(CLAUDE.md의 `owner_all` 규칙에서 벗어나는 이유를 마이그레이션 주석에 적는다).

| 표 · 변경 | 내용 | 지워지는 때 |
|---|---|---|
| `slack_messages` (대기 메시지) | `connection_id` · `user_id` · `channel_id` · `channel_type`(im/mpim/channel/group) · `ts` · `thread_ts` · `sender_id` · `text` · `edited_at` · `received_at` · `source_id`(넣은 원문. `sources` 외래키 `on delete set null`, 처리가 끝나면 `text`를 비움). unique `(connection_id, channel_id, ts)` | 넣은 지 3일(재전송 막기용 표시), 안 넣은 행도 3일(안전장치) — retention cron. 연결 끊기 · 계정 삭제 |
| `slack_threads` (추적 스레드) | `connection_id` · `user_id` · `channel_id` · `thread_ts` · `last_activity_at`. PK `(connection_id, channel_id, thread_ts)` | 마지막 활동 14일 뒤(retention cron), 연결 끊기, 계정 삭제 |
| `slack_people` (이름 캐시) | `connection_id` · `user_id` · `slack_id`(사람 또는 대화) · `kind` · `name` · `fetched_at`. PK `(connection_id, slack_id)` | 연결 끊기, 계정 삭제 |
| `connections.connected_at` | `saveConnection`이 연결 · 다시 연결 때마다 적는다. 늦게 온 `tokens_revoked`가 새 연결을 지우지 않게 하는 기준(2-4) | — |
| `sources.raw_text_purge_reason` | `retention`(90일) · `disconnected`(D3). 앱 · 서버의 "90일이 지나 본문을 지웠어요" 문구는 `raw_text_purged_at`만 보고 나온다(`create-action.ts` · `sources/[id]/missing` · `service.ts`) — 이유에 따라 문구를 가른다 | — |
| `connections`의 `owner_delete` 정책 삭제 (**PR 3**, 별도 마이그레이션) | 지금은 앱이 Supabase로 연결 행을 **직접** 지울 수 있다(`20260928000000_connections.sql`). 그러면 토큰 폐기와 D3를 건너뛰고 `sources.connection_id`가 `null`이 된다. 앱은 이미 API로 끊는다(`APIClient.swift`의 `disconnect`). 단, 지금의 끊기 라우트가 이 정책으로 지우므로(이용자 권한) **라우트를 서버 권한으로 바꾸는 PR 3에서 함께** 지우고, 이 정책에 기대는 `tests/db/connections.test.ts`의 "연결을 끊으면 토큰은 지워지고 원문은 남는다"도 그때 고친다 | — |

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
| 할 일(`actions`) 제목 · 범위 요약 | **남긴다.** Slack 글에서 만든 요약이지만 이용자의 할 일 목록이다. "associated Data"에 들어가는지는 L9 법률 검토에 묻는다 |

## 3. 앱 (Swift)

판정 로직은 넣지 않는다. 서버가 `slack`을 등록하면 연결 시작 API의 400("아직 연결할 수 없어요")이 멈추므로, 앱의 "Coming soon"은 저절로 Connect가 된다(`Connections.swift`의 `comingSoon`).

| 곳 | 바꿀 것 |
|---|---|
| 연결 전 안내 | 지금 확인 창은 Google 전용이다: 제목이 Google이고 Continue가 `start(.google)`을 부른다(`AccountViews.swift`의 `confirmingGoogle`). 서비스를 받는 확인 창으로 바꾸고, Slack의 `readsBeforeConnecting`에 한 줄: "DMs, group DMs, and channel messages that mention you or that you write. New messages only." |
| 연결 끊기 확인 | 지금 "Tasks already found stay." Slack이면 "Slack messages are deleted. Tasks stay." (D3) |
| 연결 직후 | 바꾸지 않는다. 공통 "Syncing…"(C11)이 잠깐 보였다가 곧 끝난다 |
| 원문 서비스 표시 | 이미 `slack.com` 링크를 Slack으로 알아본다(`SourceService.swift`). 확인만 |

UI 문구는 짧은 영어 라벨 규칙을 따른다. 설명 줄은 위 두 문장만 둔다.

## 4. 골든셋 · eval

**코드보다 먼저 만든다**(바이브코딩 원칙: 엔진 + eval 먼저). 본문은 2-5 형식과 글자까지 같게 쓰고 관련자를 채운다. 파일 이름은 `evals/golden/slack-*.json` · `seq-slack-*.json`.

| 케이스 | 보는 것 |
|---|---|
| `seq-slack-friday-to-monday` | **핵심 시나리오 2.** 회의록 "금요일까지 제안서" → DM "월요일에 받아도 괜찮아요" → 할 일 하나, 기한 월요일, 이력에 DM 인용 |
| `seq-slack-gap-reply` | 요청 "금요일까지 견적서 부탁드려요" → **한 시간 뒤 다른 묶음**의 `:+1:` (D1-b의 (가) · (나) 비교) |
| `seq-slack-thread-late-reply` | 스레드를 넣은 뒤 다음 날 같은 스레드에 기한 변경 답글 → 다음 묶음이 기존 할 일을 갱신 |
| `slack-dm-short-commit` | 한 줄 약속 "넵 내일 오전까지 보내드릴게요" |
| `slack-dm-emoji-accept` | 같은 묶음 안의 요청 → `:+1:` |
| `slack-dm-decline` | 요청 → "이번 주는 어렵겠어요" → 할 일 없음 |
| `slack-dm-tentative` | "시간 되면 볼게요" → 자동 반영 안 됨 |
| `slack-dm-only-me` | 내가 쓴 줄만 있는 DM "금요일까지 보내드릴게요" → 상대는 머리줄의 DM 상대 (D7) |
| `slack-mpim-others-commit` | 그룹 DM에서 다른 사람끼리 한 약속 → 할 일 없음 |
| `slack-channel-mention-thread` | 채널에서 나를 언급한 요청 + 다른 사람의 기한 덧붙임 + 내 수락 |
| `slack-channel-mid-thread` | `[#채널 · 스레드 중간부터]` "이거 금요일까지 될까요?" (D2) — 확인 요청이면 맞음 |
| `slack-mixed-language` | 영어 · 한국어가 섞인 스레드 |
| `seq-slack-done` | Slack 약속 → 다음 날 "보냈어요" → 완료 |
| `seq-slack-requester-cancels` | 요청 → "그 건은 안 하셔도 돼요" → 취소 |
| 실제 5건 이상 (D6) | 본인 워크스페이스 DM · 스레드, 로컬에서 익명화 |

- 지금 eval로는 두 가지를 할 수 없다: 케이스 묶음별 표(실제/합성으로만 나뉘고 `--case`만 있다, `scripts/eval.ts`), "확인 요청이면 맞음" 라벨(`golden.ts`의 기대 Action에 그런 칸이 없다). PR 1에서 이 둘만 작게 더한다 — 파이프라인은 건드리지 않는다.
- 기준(제안): 추출 precision · recall 0.9 이상(Phase 1 목표와 같음), 시퀀스 병합 정확도 100%. 못 미치면 원인을 적고 go live 여부를 정한다.
- 결과는 `evals/golden/README.md` 기록 표에 "Slack" 줄로 따로 적는다.
- 어댑터 단위 테스트(eval 아님): 서명 정상 · 변조 · 5분 초과, 버리는 규칙 표 전부, 봇 · 시스템 하위 유형, 고침 · 지움, 넣은 뒤 재전송, 동기화 도중 도착한 메시지가 남는지, 묶음 자르기(30분 · 자정 · 3시간 · 100개), 넣은 뒤 답글이 다음 묶음이 되는지, 본문 형식(본인 이름 · 언급 · 링크), `error` 연결이 이벤트를 받는지, 한 워크스페이스 두 이용자, `app_uninstalled` · 늦게 온 `tokens_revoked`, D3 표의 모든 칸.

## 5. 문서 · 처리방침 맞추기

같은 PR에서 한국어 · 영어를 함께 고친다(`docs/legal/README.md` 게시 규칙 3 · 4). 아래 줄 번호는 `privacy.ko.md` 기준(2026-09-28)이다. `privacy.en.md`는 같은 절의 대응 문장을 고친다(줄 번호는 조금 다르다).

| 곳 | 지금 | 고칠 것 |
|---|---|---|
| 3장 연결 끊기 문단 (89줄) | "이미 가져온 원문과 거기서 만든 할 일은 남습니다" | Slack은 원문 · 근거 인용을 지우고 할 일만 남긴다 (D3) |
| 3장 Slack "남기는 메시지" (116줄) | "이용자가 쓴 메시지와 그 스레드" | "이용자가 쓰거나 이용자를 언급한 스레드" (2-4 추적 규칙) |
| 3장 Slack "저장하는 것" (117줄) | "보관 기간은 5장과 같습니다(계정 삭제 때까지)" — **지금도 틀리다**(5장은 본문 90일) | 본문 90일, 연결을 끊거나 앱을 지우면 바로. 대화 이름(D7) 추가 |
| 3장 Slack "권한" (118줄) | 권한 5개 | 9개 (D7) |
| 3장 법률 검토 상자 (123줄) | 90일 · 인용 유지 | D3 · 14 영업일 정책 반영 |
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
| 1 | 골든셋(4장 표) + eval 묶음별 표 · "확인 요청이면 맞음" + 지금 파이프라인으로 기준 점수, D1-b · 관련자 모양 비교 | `npm run eval` 기록에 Slack 줄. 파이프라인 코드 변경 없음 | 1~2일 |
| 2 | 마이그레이션(새 표 · `connected_at` · `raw_text_purge_reason`) + 이벤트 받기(서명 · 가르기 · 대기 저장 · 재전송 · 앱 해제) | 단위 · RLS 테스트. dev 앱 이벤트 URL "Verified", 채널 잡담은 DB에 없고 DM은 `slack_messages`에 있음 | 2일 |
| 3 | 연결 · 묶기 · 넣기 · 이름 · 연결 끊기 라우트(서버 권한 · 토큰 폐기 · D3) + `owner_delete` 정책 삭제 + registry + retention | dev 워크스페이스에서 시나리오 2가 45분 안에 기존 할 일의 기한 변경으로 나타남. 앱에서 끊으면 Slack 앱 목록에서도 사라짐 | 2~3일 |
| 4 | 앱 문구(확인 창 일반화 · 끊기 문구) + 처리방침 · 문서 맞추기 + 전체 검증 | 8장 전부. 런북 C5 ✅ | 1~2일 |

PR 1은 운영 서버 배포와 무관하게 지금 시작할 수 있다. PR 2부터는 7장의 dev 앱이 있어야 한다.

## 7. 사용자가 먼저 할 일

| # | 할 일 | 언제까지 | 비고 |
|---|---|---|---|
| U1 | ~~D3 · D7~~ 결정됨 (2026-09-28). D1 · D1-b · D2 · D4~D6을 권장안과 다르게 하려면 알려 주기 | PR 1 전 | D3의 범위는 L9 법률 검토 항목에 더했다 |
| U2 | 개발 워크스페이스 고르기 + **시험용 두 번째 Slack 계정** | PR 2 전 | 시나리오 2는 "상대가 보낸 DM"이 필요하다. 혼자서는 시험할 수 없다 |
| U3 | 터널 도구 설치 (`brew install cloudflared` 또는 ngrok) | PR 2 전 | Slack은 이벤트를 공개 HTTPS로만 보낸다. 이 Mac에는 둘 다 없다(2026-09-28 확인). 주소가 고정되는 쪽이 편하다: 주소가 바뀔 때마다 dev 앱의 redirect · 이벤트 URL을 고쳐야 한다 |
| U4 | **Taskforce dev** Slack 앱 만들기 | PR 2 중 | [slack-app.md](slack-app.md) 2장 매니페스트(D7 권한 4개 반영됨)에서 redirect · 이벤트 URL만 터널 주소로. 비밀값 3개는 `.env.local`에만 |
| U5 | 운영 Slack 앱 (L7) | 서버 배포(I3) 뒤, PR 4 전 | slack-app.md 9장 순서 그대로 |
| U6 | D6 실제 원문 5건 고르기 | PR 1 중 | 익명화는 로컬에서, 원문은 커밋하지 않는다 |

## 8. 끝난 기준 (체크리스트 C5)

- [ ] `npm run lint && npm run typecheck && npm run test && npm run eval` 통과, Slack 골든셋 숫자가 README 기록 표에 있음
- [ ] dev 워크스페이스: 회의록 "금요일까지 제안서" → 두 번째 계정의 DM "월요일에 받아도 괜찮아요" → **새 할 일 없이** 기존 할 일의 기한이 월요일, 이력에 Slack 인용, 링크가 그 메시지를 연다
- [ ] 나를 언급하지 않은 채널 글은 `slack_messages` · `sources` 어디에도 없음 (읽기 SQL)
- [ ] 앱에서 연결 끊기 → Slack 앱 목록에서 사라짐(`auth.revoke`). 그 연결의 대기 · 추적 · 이름 행 0건, 원문 본문 · 관련자 빈 값, 근거 인용 · Claim 인용 · `value_text`에 Slack 글자 없음, 판정 기록 0건 (읽기 SQL, 지우기 전에 원문 id를 먼저 적어 둔다)
- [ ] Slack에서 앱 제거 → 그 워크스페이스의 연결이 모두 `revoked`, 같은 데이터 0건
- [ ] Vercel 로그에 메시지 본문 · 이름 · 토큰 없음
- [ ] 앱이 요청하는 권한 9개가 처리방침 3장 목록과 같음, 3장 · 5장 · 11장 문장이 구현과 같음

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
| 공개 채널 범위 | 사용자 토큰은 이용자가 들어간 채널의 이벤트만 받는다(추정) | dev 앱에서 확인. 처리방침 문장("이용자가 속한 대화")과 맞다 |
| 확인하지 못한 것 | 봇 없는 앱이 `tokens_revoked` · `app_uninstalled`를 구독할 수 있는지, `apps.event.authorizations.list`의 속도 등급, 관리자 승인 워크스페이스에서 callback이 돌아오는지 | PR 2 · 3에서 dev 앱으로 확인하고 이 표를 고친다 |

### 출처

- 비Marketplace 앱 속도 제한 (2025-05-29, 이후 수정): <https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps>
- Events API (한 이벤트는 한 번, `apps.event.authorizations.list`, 3초 · 재시도 · 30,000건/시간): <https://docs.slack.dev/apis/events-api/>
- Marketplace 설치 수 조건 (2026-09-01): <https://docs.slack.dev/changelog/2026/09/01/slack-marketplace-install-requirement>
- Marketplace 가이드라인 (`*:history` 심화 심사, "unlikely to approve", 2026-09-28 원문 확인): <https://docs.slack.dev/slack-marketplace/slack-marketplace-app-guidelines-and-requirements/>
- 배포 방식 (비공개 배포는 파일럿 · 시험용): <https://docs.slack.dev/distribution/>
- Slack API 약관 (2025-10-10 시행): <https://slack.com/terms-of-service/api>
- Slack 개발자 정책 (2024-12-10 시행, 14 영업일 삭제 · LLM 학습 금지, 2026-09-28 원문 확인): <https://docs.slack.dev/developer-policy/>
- 토큰 갱신: <https://docs.slack.dev/authentication/using-token-rotation> · 앱 해제 이벤트: <https://docs.slack.dev/reference/events/app_uninstalled>
