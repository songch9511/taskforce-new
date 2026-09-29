# Google 연동: 구현 계획 (C4)

관련 문서: [go live](../GO_LIVE.md) 6장 · [런북 체크리스트 C4](runbook.md#go-live-체크리스트) · [Google 심사](google-verification.md) · [처리방침 3장 Google · Gmail](../legal/privacy.ko.md) · [진실 판정 규칙](../TRUTH_RULES.md) · [Slack 연동 계획](slack-integration.md)

작성: 2026-09-29. [GO_LIVE.md](../GO_LIVE.md) 진행 순서 4(체크리스트 C4, 다른 문서의 "트랙 2-3")를 코드로 옮기기 전에 **정할 것 · 만들 것 · 끝난 기준**을 적는다.
Google 프로젝트 · 범위 · 동의 화면 · 심사는 [google-verification.md](google-verification.md)가 기준이다. 이 문서는 서버 · 앱 · eval 쪽이다. 형식은 [slack-integration.md](slack-integration.md)를 따른다. Google API · 범위 · 정책은 공식 문서 원문으로 확인했고(9장), 초안을 코드와 대조해 검토해 지적 13건을 반영했다(2026-09-29).

## 0. 한눈에

| 항목 | 내용 |
|---|---|
| 목표 | 테스터가 앱에서 **Google**(Calendar · Meet 전사)과 **Gmail**을 연결하면, 그 뒤 ① 메일에서 약속 · 기한 변경이 할 일로 반영되고 ② Meet 전사의 발화자로 담당이 정해지며 ③ 같은 회의의 Notion 회의록에 일정 참석자가 붙는다. Gmail은 Testing 상태라 7일마다 끊기고, 앱과 알림이 재연결을 안내한다 |
| 연결 둘 | `google` = 프로젝트 A(`openid` · `email` · `calendar.events.owned.readonly` · `meetings.space.readonly`, 정식 심사) · `gmail` = 프로젝트 B(`openid` · `email` · `gmail.readonly`, Testing). redirect `/api/connectors/{google,gmail}/callback`, env `GOOGLE_*` · `GMAIL_*` ([google-verification.md](google-verification.md) 1장) |
| 기간 | 코드 2~3주 (PR 7개, 6장. PR 5는 5a · 5b로 나눔) |
| 시작 조건 | 1장 결정. 골든셋 PR은 지금 시작할 수 있다. 연결 PR부터는 **Taskforce dev** Google 프로젝트(Testing, localhost redirect, 운영처럼 둘로, 7장 U2)와 Meet 전사가 되는 Workspace 계정 둘(U3)이 필요하다 |
| 끝난 기준 | 8장. 요약: 메일 · Meet 골든셋 eval 기록 · `invalid_grant` → `reauth` + 앱 · 알림 재연결 안내 · 처리방침 3장 Google · Gmail 문장과 구현 값(범위 · 거르기 · 저장 · 전송) 일치 · 끊기 · 계정 삭제 때 Google 토큰 폐기 |
| 파이프라인 | **고치지 않는 것이 기본이다.** 두 연결 모두 "Source를 만들어 파이프라인에 넣는 어댑터"다. 추출 · 검증 · Jev · 매칭 · 진실 판정은 Notion · Slack과 같다. 골든셋 기준 점수가 낮으면 Slack PR 1b처럼 따로 고친다(6장 PR 1b) |

## 1. 시작 전에 정할 것

권장안으로 시작하고, 다르게 하려면 PR 1(골든셋) 전에 정한다. ✅는 2026-09-29에 사용자가 정한 것이다.

| # | 정할 것 | 권장 | 이유 | 다른 선택 |
|---|---|---|---|---|
| G1 | Meet 전사를 받는 길과 범위 | ✅ **Meet REST API의 전사 항목만**(`meetings.space.readonly`, 민감). 범위를 더하지 않는다 | 전사 항목에 발화자(참가자 id)가 붙어 온다. 이미 정한 범위라 심사 문안(google-verification.md 4장)이 그대로 맞다. 전사 항목은 회의가 끝난 뒤 **30일** 동안만 API에 있다(9장) | Docs API(`documents.readonly`, 민감)로 Calendar 일정에 붙은 전사 문서 읽기: 같은 회사 초대자면 남이 주최한 회의도 되지만, 동의 화면에 "모든 Google Docs 보기"가 뜨고, 발화자가 이름뿐이며, 일정 첨부를 읽어야 해 처리방침 3장("첨부 파일은 읽지 않습니다")과 심사 문안을 고쳐야 한다. Drive(`drive.readonly` · `drive.meet.readonly`)는 제한 범위라 제외 |
| G2 | 주최하지 않은 회의의 전사 | ✅ **두 길을 모두 만들고 dev에서 두 계정으로 시험한다.** ① 주최한 회의: `conferenceRecords.list`(끝난 시각으로 거름). ② 참석한 회의: Calendar에서 참석한 Meet 일정의 회의 코드를 읽어 `conferenceRecords.list`(`space.meeting_code`로 거름). ②가 안 되면(빈 목록 · 403) 처리방침 3장 · 앱 문구를 "내가 주최한 회의"로 적는다 | Google 문서가 서로 다르다: 가이드는 "list는 주최한 회의만"이라 하고, 같은 쪽과 2025-02-07 릴리스 노트는 "참가자도 회의 기록을 조회할 수 있다"고 한다(9장). 코드로는 ②가 ①과 같은 함수에 거름 조건만 다르다. **사용자 회사는 주최자가 섞여 있고 대부분 Notion 전사만 켠다(2026-09-29 확인)** — Meet 전사가 있는 회의에서만 발화자로 담당을 정할 수 있으므로, 비율을 잰다(8장) | 주최한 회의만으로 확정: 더 단순하지만 남이 주최한 회의를 시험도 하지 않고 버린다 |
| G3 | Calendar를 읽는 방식 | ✅ **저장하지 않고 필요할 때 조회한다.** 회의 원문(Notion 회의록 · Meet 전사)을 넣기 직전에 그 회의 시각 앞뒤의 일정만 `events.list`로 읽고, 고른 일정 하나의 제목 · 시각 · 참석자만 그 원문에 붙여 저장한다. G2 ②는 Meet 커서부터 지금까지의 일정을 읽지만 회의 코드만 쓰고 저장하지 않는다 | 처리방침 3장이 이미 "붙인 일정 제목 · 시각 · 참석자는 그 회의 원문의 관련자 정보로 저장합니다"라고 약속한다. 일정 전체를 복사해 두면 저장 항목 · 보관 기간을 새로 적어야 하고, 심사 문안(4장)의 "최소 범위"와도 멀어진다. 조회는 회의 원문 하나에 1번이라 요청 수가 작다 | 최근 일정 표(`google_calendar_events`, 14일)를 15분마다 채운다: Notion 동기화가 Google을 부르지 않아도 되지만 처리방침 · 5장 표를 고쳐야 한다 |
| G4 | 회의록 ↔ 일정 잇기 | 2-4의 순수 함수 규칙. **애매하면 잇지 않는다**(후보가 둘 이상 같은 점수 · 시각도 제목도 맞지 않음) | 잘못 이으면 남의 회의 참석자가 붙어 담당 판정이 틀린다. 안 이으면 지금(참석자 없음)과 같다. 확인 요청은 만들지 않는다(원칙 3) | 제목 비슷함만으로 잇기: 매주 같은 이름의 회의에서 틀린다 |
| G5 | 발화자 → 사용자 · 참석자 | 사용자 줄은 **코드가 확실히** 정한다(2-5): Meet 참가자의 `signedinUser.user`(`users/{id}`)가 연결한 계정의 `sub`와 같으면 그 줄의 이름표를 Taskforce 프로필 이름으로 쓴다(Slack과 같은 규칙). 다른 사람은 Meet 표시 이름 그대로, 참석자 목록에는 일정 참석자(이메일)와 Meet 참가자(이름)를 합쳐 넣는다. **두 id가 같은 값인지는 Google 문서에 없다(9장)** → PR 3 첫 작업으로 dev에서 확인하고, 다르면 범위 `profile`(비민감)을 더해 `id_token`의 Google 계정 이름을 Meet 표시 이름과 비교한다 | 사용자 알아보기는 이름 문자열로 한다(`identity.ts`). Meet 표시 이름(예: `Daniel Song`)이 프로필 이름(`송창훈`)과 다르면 "내가 한 말"을 못 알아본다. 계정 id 비교는 원칙 5(사실은 코드가)와 맞다 | 이름 비교만: 영문 · 한글 표기가 다르면 틀린다. People API로 참가자 이메일 찾기: 범위가 하나 더 늘고 "모든 참가자의 정보가 있지는 않다"(Meet 문서) |
| G6 | Gmail 원문 하나의 단위와 넣는 때 | **메일 한 통 = 원문 하나.** 본문은 보낸 그대로(메일 앱이 붙인 이전 메일 인용 포함) 쓰고 2만 자에서 자른다. 안정화 시간 없이 다음 동기화에서 넣는다 | 메일은 한 통이 완결된 글이고, 기존 메일 골든셋도 한 통씩이다(`email-user-sender-quoted` · `investor-followup-email-quoted`는 인용된 옛 메일이 붙은 한 통에서 인용 속 남의 약속을 뽑지 않는지 본다). **위험:** 인용 속 옛 약속("by Monday")이 새 메일의 시각으로 다시 뽑히면 규칙 4(나중 발언)로 이미 늦춘 기한을 되돌릴 수 있다 → 골든셋 `seq-gmail-quoted-stale-deadline`으로 재고, 틀리면 PR 1b에서 코드 규칙(인용 부분에만 있는 구절은 후보로 쓰지 않음, 2-6). 보낸 사람 · 받는 사람 · 참조가 한 통마다 달라서 스레드로 묶으면 `sole_recipient` · `cc_only` 판정(`userPosition`)을 잃는다. 메일은 고쳐지지 않으므로 기다릴 이유가 없다 | 스레드를 Slack처럼 30분 묶음으로: 관련자가 `attendees`로 뭉개진다. 인용 걷어 내기: 메일 앱마다 모양이 달라(`On … wrote:` · `-----Original Message-----` · `-----원본 메시지-----`) 틀리면 짧은 답장("Sure, I'll send it by Monday.")의 대상이 사라진다 |
| G7 | Gmail에서 거르는 메일 | 2-6 표. 요약: 스팸 · 휴지통 · 임시 보관 · 채팅 · 프로모션 · 소셜은 목록에서 빼고(라벨로 한 번 더 본다), **머리글만 읽어** 자동 발송(`Auto-Submitted`), 대량 발송(`Precedence: bulk · junk`), 수신 거부 · 메일링 리스트 머리글(`List-Unsubscribe` · `List-Id`, 단 **같은 회사 도메인의 그룹 메일은 남김**), no-reply류 보낸 주소, 일정 초대 메일을 거른다. **사용자가 보낸 메일(`SENT` 표시 — 보내는 주소 별칭도 포함)은 자동 발송이 아니면 늘 남긴다.** 거른 메일은 본문을 받지 않고 저장하지 않는다 | 처리방침 3장 "뉴스레터 · 광고 · 자동 알림 메일은 거르고 저장하지 않습니다"를 지키면서, 회사 Google 그룹 메일(`team@` 등)은 `List-Id` · `List-Unsubscribe`가 붙어도 실제 요청이 오가는 곳이라 남긴다. 머리글로 먼저 거르면 거른 메일의 본문은 서버로 오지도 않는다(데이터 최소화, CASA 설명이 쉬워진다) | "업데이트" 분류도 거른다: 거래처 메일 · 문서 공유 알림이 섞여 누락이 생긴다. 알림 메일은 위 머리글 규칙으로 대부분 걸린다 |
| G8 | Gmail 첫 동기화 범위 · 다시 연결 뒤 빈틈 | ✅ **처음 14일**(Notion과 같다). 다시 연결하면 **마지막으로 동기화한 때부터**(최대 30일) 이어서 가져온다. 메일이 많으면 한 번에 다 하지 않고 15분마다 나눠 채운다(2-6 한도) | 7일마다 끊기는 동안 온 메일을 잃지 않는다. 커서가 시각이라 Gmail history id 만료("보통 1주, 드물게 몇 시간", 9장)와 상관없다. 이미 넣은 메일은 외부 id로 걸러진다. `messages.get`이 한 번에 20 단위이고 사용자당 분당 6,000 단위라 한 동기화에 머리글 200통까지만 읽는다 | 7일: 첫 결과가 빠르지만 그 앞 약속을 놓친다. 연결 뒤 메일만(Slack처럼): 첫 며칠이 빈다 |
| G9 | 7일 재연결 안내 | 앱 연결 줄은 이미 "Reconnect to keep syncing"(빨강)과 "Beta · Reconnect every 7 days"가 있다. 더할 것: **`reauth`로 바뀌는 순간 알림 한 번**("Reconnect Gmail to keep syncing."), 누르면 연결 화면. "한 번"은 상태를 실제로 바꾼 동기화만 보내는 것으로 지킨다(2-3). 만료 전 미리 알림은 하지 않는다 | 처리방침 3장 Gmail 절이 "연결이 만료되면 앱과 알림으로 알려 드립니다"라고 약속한다. 끊긴 동안의 메일은 G8로 되찾으므로 미리 알릴 만큼 급하지 않다(알림 수 = 관리 비용, 원칙 3) | 만료 하루 전 알림: 7일마다 알림 두 번이 된다 |
| G10 | 권한 화면에서 일부 범위만 허용 | Google 권한 화면은 범위마다 체크를 뺄 수 있다(9장). 토큰 응답의 `scope`로 **받은 범위만 쓴다**: `google`은 Calendar만 · Meet만 허용해도 연결하고(되는 쪽만 동기화, 설정에 `scopes` 기록) 연결 결과를 새 값 `connected_partial`로, 둘 다 없거나 Gmail에 `gmail.readonly`가 없으면 연결하지 않고 받은 토큰을 바로 폐기한 뒤 새 값 `missing_scope`로 알린다. 앱 문구는 PR 4(예: "Connected. Some access is off." · "Allow access to connect.") | 체크를 뺀 이용자를 조용히 실패시키지 않는다(지금 틀로는 502 → "Couldn't connect. Try again."만 보인다, `connections.ts`). 쓸 수 없는 토큰을 남기지 않는다. 폐기는 그 계정 · 프로젝트의 허용 전체를 거두므로, 이미 연결된 같은 계정의 Gmail 연결도 다음 동기화에서 `reauth`가 된다(PR 2 검토에서 확인, 다시 연결하면 된다). 연결 결과 값은 응답에만 더하는 것이라 옛 앱은 `unknown` → 같은 오류 문구로 보인다 | 모든 범위를 요구하고 하나라도 빠지면 실패: 이용자가 이유를 모른다 |
| G11 | 연결을 끊을 때 Google 데이터 | **지금 처리방침 그대로:** 토큰을 폐기하고, 이미 가져온 원문 · 할 일은 남긴다(원문 본문은 90일 규칙). 모두 지우려면 계정 삭제 | Google 정책(API 서비스 사용자 데이터 정책 · Workspace 사용자 데이터 정책)에서 "끊으면 지워라"는 규칙이나 기한은 찾지 못했다. 요구하는 것은 "삭제 요청을 따르고, 지우는 방법을 안내하라"다(9장). Slack D3 같은 예외를 만들지 않으면 원칙 2 · 5가 그대로다. 다만 Google API 약관의 "영구 사본을 만들지 말 것"과 근거 인용을 계정 삭제까지 두는 것이 맞는지는 L9 법률 검토에 더한다 | Slack처럼 끊으면 Google 원문 · 인용을 지운다: 정책이 요구하지 않고, 근거 없는 할 일이 늘어난다 |
| G12 | 여러 이야기 사이에 묻힌 메일 요청(혼자 받음, 아직 수락 전) | ✅ **확인 요청으로 보낸다**(PR 1 eval 뒤 결정, 4장 "기준 점수" E5): F3 규칙을 "사용자가 유일한 받는 사람인 메일의 요청"으로 넓혀, 기각 사유가 "내 약속 아님" 하나면 확인 요청까지(자동 반영은 안 함). PR 1b에서 구현한다. 처음 권장: **골든셋 PR에서 eval로 정한다.** 요청만 있는 메일은 이미 할 일이 된다(`email-sole-recipient-request`). 통화 정리 메일 끝의 "계약서 사본도 한 부 보내주실 수 있을까요?" 같은 요청은 Jev "내 약속" 확률이 기각선(0.4) 근처라 실행마다 확인 요청과 기각을 오간다(`freelance-client-recap-email`, slack-integration.md 4장 "남은 것"). F3 규칙(`@이름` 요청은 확인 요청까지)을 "사용자가 유일한 받는 사람인 메일의 요청"으로 넓힐지, 골든셋의 확인 요청 수 · 누락 수를 보고 정한다 | 메일은 외부와의 약속이 오가는 곳이라 조용히 사라지는 요청이 많으면 가치가 떨어진다. 넓히면 확인 요청이 는다(원칙 3) | — |
| G13 | 실제 원문 골든셋 | 본인 Gmail 스레드 · Meet 전사를 각 5건 이상 **로컬에서 익명화**해 넣는다(원문은 커밋하지 않음). ✅ **PR 1b 전에** 넣고 1b의 고침 전후 숫자를 같이 본다(2026-09-29). Meet 전사가 거의 없으면 Notion AI 회의록 + 같은 회의 일정 참석자로 대신한다 | 합성 예시만으로는 실제 문체 · 메일 앱의 인용 모양 · 받아쓰기 오류를 모른다(Slack D6과 같음) | 합성만: go live 뒤 실제 정확도를 모른다 |

## 2. 서버 설계

### 2-1. 흐름

```
[google 연결] cron 15분 · Sync Now · 연결 직후 ──▶ syncConnections ──▶ googleConnector.sync
   ① 토큰 (만료 60초 전이면 갱신, invalid_grant → reauth)
   ② Meet: 끝난 회의 기록 → 전사 → 전사 항목 · 참가자 → 같은 회의의 Calendar 일정 조회(G3)
   ③ IngestItem(kind meeting, 발화자 이름표) → ingestItems → processSource

[gmail 연결] cron 15분 · Sync Now · 연결 직후 ──▶ gmailConnector.sync
   ① 토큰 (같음)
   ② messages.list(시각 커서 뒤) → 머리글만 읽어 거르기(G7) → 남은 메일만 본문 받기
   ③ IngestItem(kind email, from · to · cc) → ingestItems → processSource

[notion 연결] 지금 그대로 + 이번에 넣을 회의록(kind meeting, 이미 고른 최대 20건)에만:
   이 사용자의 google 연결이 있으면 그 회의 날의 일정을 조회해 참석자 · 일정을 붙인다(G3 · G4)
```

두 Google 연결은 **받아 두는 표(대기 표)가 없다.** Slack은 Slack이 보내 주는 이벤트를 받아야 해서 대기 표가 필요했지만, Google은 동기화 때 가져온다. 잠금(`claimConnection` · `recordSync`)은 Notion처럼 커넥터가 직접 부른다(`notion/run.ts`).

### 2-2. 파일

| 파일 | 할 일 | 테스트 |
|---|---|---|
| `src/lib/connectors/google/oauth.ts` | 두 연결이 같이 쓰는 OAuth: 권한 주소(`access_type=offline` · `prompt=consent` · `include_granted_scopes=false`), code 교환, 갱신, 폐기, `id_token`에서 `sub` · `email` 읽기, 받은 범위 확인. 토큰 창구의 오류 코드(`invalid_grant` 등)를 담는 `GoogleOAuthError`. 응답은 모두 zod | 가짜 fetch |
| `src/lib/connectors/google/token.ts` | `googleAccess(store, config)`: 요청마다 저장된 토큰을 붙이고, 만료 60초 전이면 먼저 갱신해 저장하고, API가 401이면 한 번 갱신해 다시 부른다(같은 토큰으로 동시에 401을 받아도 갱신은 한 번). 갱신이 `invalid_grant`면(갱신 토큰이 없을 때도) `GoogleReauthError`. API 실패는 `GoogleApiError`(상태 · 이유 코드) | 가짜 저장소 |
| `src/lib/connectors/google/settings.ts` | 연결 설정 `{ googleUserId, email, scopes, stats }`: 연결(다시 연결)한 계정 · 범위 남기기, 동기화마다 이유 코드별 개수 더하기(8장) (PR 2) | 순수 |
| `src/lib/connectors/google/calendar.ts` | `events.list`(G3의 `fields`만) · 일정 거르기 `usableEvents` · 회의 잇기 규칙 `pickMeetingEvent`(2-4, 순수 함수) · `lookupMeetingEvent`(Notion · Meet이 부른다: 창 안의 일정 50건을 읽고 고른다) (PR 3 ✅ 2026-09-29) | 순수 + 가짜 fetch. `fields`에 설명 · 첨부 · 위치가 없음 |
| `src/lib/connectors/google/lookup.ts` | `googleCalendarLookup(admin, userId)`: 이 사용자의 google 연결(active · error) 중 Calendar를 허용한 것으로 Notion 회의록용 조회 함수를 만든다. 없거나 만들 수 없으면 null (Notion 동기화를 막지 않는다). 계획의 `findMeetingEvent`의 DB 쪽 (PR 3 ✅) | 가짜 저장소 · fetch |
| `src/lib/connectors/google/meet.ts` | Meet REST API: 회의 기록 · 전사 · 전사 항목 · 참가자 · 회의 공간(회의 코드). 응답은 zod. 한 동기화의 요청 예산(`MEET_REQUEST_BUDGET` 400, 분당 600 한도의 여유) (PR 3 ✅) | 가짜 fetch |
| `src/lib/connectors/google/transcript.ts` | 전사 항목 + 참가자 + 일정 → `IngestItem` (2-5, 순수 함수). 이름표 충돌(같은 표시 이름)은 (2)로 가른다 (PR 3 ✅) | 순수. 골든셋 파일과 글자까지 비교 (Meet 골든셋 7개 소스) |
| `src/lib/connectors/google/sync.ts` | `syncGoogleMeet`: 회의 기록 찾기 ①(주최) · ②(참석, G2) → 전사 나열 → 이미 넣은 전사 빼기 → 항목 · 참가자 · 일정 → `ingestItems`. 커서 `{ after }`, 결정하지 못한 회의가 있으면 그 끝까지만 (PR 3 ✅) | 가짜 클라이언트 |
| `src/lib/connectors/google/attendees.ts` | 관련자 합치기(이메일 → 이름, 200명 상한) (PR 3 ✅) | 순수 |
| `src/lib/connectors/google/unverified.ts` | **dev 회의로 확인할 가정 넷을 한 파일에**: `CALENDAR_EVENTS_SCOPE`(초대가 보이는가) · `LIST_ATTENDED_MEETINGS`(G2 ②) · `isConnectedAccount`(G5) · `sameMeetingCode`(코드 ↔ 일정). 확인 결과가 다르면 여기 한 줄만 바꾼다 (9장 "PR 3 dev에서 확인할 것") (PR 3 ✅) | 순수 |
| `src/lib/connectors/google/run.ts` | `googleConnector`: `authorizeUrl` · `connect`(G10: 받은 범위, `connected_partial` · `missing_scope`) · `sync`(허용한 것만: Meet 없으면 전사 없음, Calendar만이면 토큰 확인만) · `revokeToken` (PR 3 ✅) | 가짜 저장소 |
| `src/lib/connectors/gmail/client.ts` | Gmail API: `users.messages.list`(q) · `users.messages.get`(`format=metadata` · `full`). `fields`로 받을 필드를 좁힌다(머리글 읽기는 `snippet`도 받지 않는다). 응답은 zod | 가짜 fetch |
| `src/lib/connectors/gmail/mime.ts` | 문자 집합(UTF-8 · EUC-KR · ISO-2022-KR 등) 풀기, 머리글의 RFC 2047 인코딩, 주소 목록(From · To · Cc) 읽기 (PR 2) | 순수 |
| `src/lib/connectors/gmail/filter.ts` | 머리글 → 남김/버림 + 이유 (2-6, 순수 함수) | 순수. 거르기 표 전부 |
| `src/lib/connectors/gmail/message.ts` | 메일 → `IngestItem`: MIME 부분 고르기, base64url 풀기, HTML → 글(인용은 `> `), 첨부 빼기, 머리줄, 2만 자 자르기 (2-6) | 순수. 골든셋 파일과 글자까지 비교 |
| `src/lib/connectors/gmail/sync.ts` | 커서 · 하루 창 · 머리글 200통 · 본문 20통 · 429 멈춤 · `ingestItems` (2-6) (PR 2) | 가짜 클라이언트 |
| `src/lib/connectors/gmail/run.ts` | `gmailConnector`: `authorizeUrl` · `connect` · `sync` · `revokeToken` | 가짜 저장소 |
| `src/lib/connectors/types.ts` · `store.ts` `insertSource` | `IngestItem.meeting?`(붙인 일정) 하나를 더하고 `sources.meeting`에 저장한다(2-7). 일정이 붙은 원문만 `meeting` 열을 보낸다: 마이그레이션 적용 전에 배포해도 다른 원문의 저장은 그대로 된다 (PR 3 ✅ 2026-09-29) | 기존 + 1 (`store.test.ts` `insertSource`) |
| `src/lib/connectors/notion/sync.ts` · `notion/run.ts` | 본문을 받을 페이지를 고른 뒤(안정화 · 이미 넣음 · 20건 상한을 이미 거른 뒤, 지금 코드의 3단계) `pageToItem` 다음에 `kind = meeting`이면 선택 의존성 `meetingEvent({ day, createdAt, title })`(= `google/lookup.ts`) → 참석자 합치기 · `meeting`. 한 번 5초 제한, 한 동기화에서 Google이 한 번 실패하면 남은 페이지는 붙이지 않고 넣는다(Notion 동기화를 막지 않는다). google 연결이 없거나 Calendar를 허용하지 않았으면 의존성을 주지 않아 부르지 않는다. 이은 결과(붙음 · 애매 · 없음 · 실패)는 `run.ts`가 google 연결 `settings.stats`(`notion_link_*`)에 센다 (PR 3 ✅ 2026-09-29) | 가짜 의존성 (`sync.test.ts` · `run.test.ts`) |
| `src/lib/connectors/store.ts` `loadIdentity` | 사용자 이메일에 **연결한 Google 계정 주소**(두 연결의 `settings.email`)를 더한다. 지금은 프로필 · 로그인 이메일뿐이라, 로그인 주소와 다른 회사 Gmail이면 "보낸 사람 = 나"를 못 알아본다 | 기존 + 1 |
| `src/lib/connectors/store.ts` `ingestDeps` · `src/lib/sources/process.ts` | (1) "이미 넣음"을 이 연결 **또는 끊긴 연결(`connection_id` null)**의 같은 외부 id로 본다: 끊으면 원문의 `connection_id`가 null이 되어(`on delete set null`), 다시 연결하면 14일을 또 넣는다. **#18이 모든 연동(Notion 포함)에 넣었다**(FEATURE_MAP 7장 1번). (2) `ingestDeps(admin, { notifyFrom: connected_at })`: 연결 전 시각의 원문(첫 14일 · 다시 연결 뒤 이어 가져오기)은 `processSource(…, { notify: false })`로 확인 요청 알림을 보내지 않는다(원칙 3). 확인 요청 자체는 그대로 만든다. Gmail이 쓰고, google(Meet 전사)도 같게 쓴다 (PR 2 · PR 3) | 기존 + 2 |
| `src/lib/connectors/store.ts` `recordSync` | `{ reauth: true }`는 PR #16이 더했다. `connected_at`이 이번 동기화의 잠금 시각(`claimedAt`)보다 뒤면(그 사이 다시 연결함) 상태 · 커서를 덮지 않는 것은 #18이 더했다. 남은 것: 실제로 `reauth`로 바꿨는지 돌려준다 (PR 4, 알림 G9와 함께) | 기존 + 2 |
| `src/lib/notify/service.ts` · `apns.ts` | `notifyReconnect(admin, userId, provider)`: `recordSync`가 실제로 `reauth`로 바꾼 동기화에서만 (G9). `reauth` 연결은 다시 연결할 때까지 동기화하지 않으므로(`syncable_connections`) 한 번으로 끝난다 | 기존 알림 테스트 + 1 |
| `src/app/api/connectors/{google,gmail}/callback/route.ts` | 공용 `handleOAuthCallback`에 넘긴다 (Notion · Slack callback과 같은 모양) | — |
| `src/app/api/connectors/{google,gmail}/start/route.ts` · `src/app/lab/connections-panel.tsx` · `lab/page.tsx` | 웹(/lab) 시작 · 연결 버튼 · 결과 문구. dev 확인용이라 Slack처럼 운영에서는 운영자만(`slackWebConnector`를 `webConnector(provider, email)`로 넓혔다, PR 2). Gmail은 PR 2, google은 PR 3 ✅ (2026-09-29) | 기존 registry 테스트 |
| `src/lib/metrics/{compute,load}.ts` · `src/app/admin/metrics/page.tsx` | Gmail 거르기 개수(`settings.stats`의 합, 8장). 연결 설정 중 `stats`만 읽는다 (PR 2). PR 3 ✅: "Google 회의" 카드 — google 연결의 `stats`(전사 수 · 일정 잇기 결과 · 참석한 회의 찾기)와, 기간 안에 들어온 회의 원문의 외부 id · 붙은 일정 id만 읽어 셈한 "일정이 붙은 비율"(`meetingLinkage`) | 순수 |
| `src/lib/connectors/registry.ts` | `CONNECTORS`에 `google` · `gmail`. 운영에서는 처리방침 · 앱 문구를 맞출 때까지 닫아 둔다: `GOOGLE_CONNECT_ENABLED` · `GMAIL_CONNECT_ENABLED`(Slack의 `SLACK_CONNECT_ENABLED`와 같은 모양, 비우면 개발 서버에서만 열림). google은 PR 3 ✅ (2026-09-29, 아래 두 줄도 같다) | 기존 + provider 둘 |
| `src/lib/env.ts` · `.env.example` | `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET` · `GOOGLE_REDIRECT_URI` · `GMAIL_CLIENT_ID` · `GMAIL_CLIENT_SECRET` · `GMAIL_REDIRECT_URI` · 여는 플래그 둘 (OAuth 값은 `google/run.ts` `googleOAuthConfig`가 읽고, 플래그 `googleConnectEnabled`만 `env.ts`에 있다) | 기존 env 테스트 |
| `src/lib/api/contract.ts` | `connectedStatusSchema`에 `connected_partial` · `missing_scope`(G10). `missing_scope`는 PR 2가 더했다(연결이 생기지 않았으므로 `isConnected`가 거짓 → 연결 지표 · 첫 동기화를 하지 않는다), `connected_partial`은 PR 3 ✅ (연결은 생겼으므로 `isConnected`가 참). 원문은 앱이 Supabase에서 직접 읽으므로(`Models.swift` `SourceSummary.columns`) `sources.meeting`은 contract가 아니라 Swift 쪽에 더한다 | 기존 |
| `scripts/reprocess-sources.ts` | `--notion-authors`는 그대로(Notion 연결만 읽는다). "원문 속 나"를 스크립트가 따로 만들던 것을 `loadIdentity`로 바꿨다: 그대로 두면 Gmail 원문을 다시 처리할 때 연결한 Google 주소를 모른다 (PR 2, dev에서 Gmail 원문을 다시 처리해 확인) | — |

`google` · `gmail`은 이미 `Provider` 타입 · `connectProviderSchema` · DB provider 검사 · 앱의 `stageOne`에 들어 있다. 새로 넓힐 enum은 연결 결과 두 값(G10)뿐이다. 한 서비스에 계정 하나(베타): 다른 Google 계정으로 연결하면 같은 서비스의 옛 연결은 끊는다(토큰 폐기 → `disconnect_connection`). 앱의 `ConnectionState`가 `active` 행을 먼저 보여 줘서, 두지 않으면 옛 `reauth` 행을 끊을 곳이 없다.

### 2-3. 연결 · 토큰 (두 연결 공통)

| 단계 | 규칙 |
|---|---|
| 권한 주소 | `https://accounts.google.com/o/oauth2/v2/auth`, `response_type=code`, `scope`(공백 구분, 위 표), `access_type=offline`(갱신 토큰), `prompt=consent`(다시 연결할 때도 갱신 토큰을 받는다), `include_granted_scopes=false`(두 프로젝트의 범위가 섞이지 않게), `state`(연결 틀) |
| code 교환 | `POST https://oauth2.googleapis.com/token` → `access_token` · `expires_in` · `refresh_token` · `scope` · `id_token`. `id_token`은 토큰 창구에서 TLS로 직접 받은 것이라 서명 확인 없이 내용만 읽는다(9장). `sub` · `email` · `email_verified`만 쓴다 |
| 받은 범위 | `scope`를 G10대로 확인한다. `id_token`이 없으면(`openid`가 빠짐) 연결 키 `sub`가 없으므로 연결하지 않는다(`missing_scope`). `email`이 빠지면 표시 이름을 비우고 사용자 알아보기는 프로필 이메일로만 한다 |
| 저장 | `saveConnection`: `external_account_id = sub`, `display_name = email`. 토큰은 `{ access_token, refresh_token, expires_at, scope }`만 암호화해 저장한다(`id_token`은 저장하지 않는다). 설정 `{ googleUserId: sub, email, scopes }`는 `saveConnection` 뒤에 적는다(Slack의 `saveSlackSettings`와 같은 방식) |
| 다시 연결 | 같은 Google 계정이면 `saveConnection`이 기존 행을 고친다: `status = active`, `connected_at` 새로, **`sync_cursor`는 그대로**(G8 이어 가기). 다른 계정으로 연결하면 새 행을 만들고 같은 서비스의 옛 연결은 끊는다(2-2 아래 "한 서비스에 계정 하나") |
| 갱신 | 만료 60초 전이면 `grant_type=refresh_token`으로 갱신하고 새 `access_token` · `expires_at`을 저장한다. Google은 갱신 토큰을 바꾸지 않으므로 Notion(PR #16)의 "동시 갱신" 확인은 필요 없다: 두 요청이 함께 갱신해도 둘 다 유효하다 |
| `invalid_grant` | 갱신이 `400 invalid_grant`면 **`recordSync(…, { error: "…다시 연결해 주세요.", reauth: true })`** + 바뀌었으면 알림(G9, 2-2). 7일 만료 · 이용자가 Google 계정에서 권한을 거둠 · 비밀번호 변경 등을 Google이 모두 같은 코드로 돌려주므로 가르지 않는다(9장). 문구: `google` "Google 연결이 만료됐습니다. 다시 연결해 주세요.", `gmail` "Gmail 연결이 만료됐습니다. 다시 연결해 주세요." |
| 그 밖의 토큰 창구 오류 | `invalid_client` · `unauthorized_client`(우리 client 설정)는 `error`로 남긴다. 권한 끊김(`revoked`)으로 보지 않는다([FEATURE_MAP.md](../FEATURE_MAP.md) 5장, PR #17) |
| API 오류 | 401: 한 번 갱신 뒤 다시. 403 `insufficient permissions`(범위가 빠짐) · 429 · 5xx: 그 연결만 `error`, 다음 동기화에서 다시. 원문 · 토큰 · code는 로그에 남기지 않는다(오류 코드 · 연결 id만) |
| 폐기 | `revokeToken`: `POST https://oauth2.googleapis.com/revoke`, 본문 `token=<refresh_token>`(없으면 access token). 갱신 토큰을 폐기하면 그 허용 전체가 거둬진다(9장). 이미 폐기된 토큰의 400은 성공으로 본다. 10초 제한 |

### 2-4. Calendar: 같은 회의 찾기 (G3 · G4)

`findMeetingEvent(admin, userId, 찾을 것)`은 Notion 회의록과 Meet 전사가 같이 부른다. 찾을 것은 Meet이면 `{ meetingCode, start }`, Notion이면 `{ day, createdAt, title }`(`day` = 회의 날짜 속성의 한국 날짜, 없으면 페이지를 만든 날).
**구현 이름 (PR 3):** 순수 고르기 `pickMeetingEvent` · 조회 `lookupMeetingEvent`(`calendar.ts`) — Meet 동기화(`sync.ts`)는 자기 토큰의 클라이언트로 바로 부르고, Notion 쪽은 `googleCalendarLookup`(`lookup.ts`)이 1번(사용자의 google 연결 찾기)을 하고 조회 함수를 만들어 `notion/run.ts`가 `syncNotion`에 넘긴다. 아래 4의 "참석자가 사용자 한 명뿐인 일정" 규칙은 Meet 전사에도 그대로 적용한다(계획을 글자 그대로). 한 글자 제목이 모든 제목에 포함되지 않도록 제목 비교는 두 글자 이상일 때만 한다.

1. 이 사용자의 `google` 연결 중 상태가 `active` · `error`이고 설정 `scopes`에 Calendar가 있는 것. 없으면 `null`.
2. `withGoogleAccess`로 `GET /calendar/v3/calendars/primary/events`: Notion은 그 **한국 날짜 하루**(00:00 ~ 24:00 KST — 날짜만 있는 속성은 0시로 읽혀서 앞뒤 몇 시간으로는 회의를 놓친다, `notion/map.ts` `pageOccurredAt`), Meet은 `start − 3시간 ~ start + 3시간`, `singleEvents=true`, `orderBy=startTime`, `maxResults=50`, `fields=items(id,status,eventType,summary,start,end,organizer(email,displayName,self),attendees(email,displayName,self,organizer,resource,responseStatus),conferenceData(conferenceId,conferenceSolution/key/type))`. **설명 · 첨부 · 위치는 `fields`에 넣지 않는다**(처리방침 3장 "일정 설명과 첨부 파일은 읽지 않습니다").
3. 거르기: 취소된 일정, `eventType`이 `default`가 아닌 것(집중 시간 · 부재 · 근무 위치 · 생일 등), 종일 일정, 사용자가 거절한 일정(`self` 참석자의 `responseStatus = declined`), 회의실 등 자원(`resource`)은 참석자에서 뺀다.
4. 고르기 (순수 함수 `pickMeetingEvent`):
   - **Meet 전사**: 일정의 `conferenceData.conferenceId`가 Meet 회의 코드와 같은 것(같은 회의 공간이 반복 일정이면 시각이 가장 가까운 하나). 없으면 잇지 않는다. 두 값은 같은 모양(`aaa-bbbb-ccc`)이지만 Google 문서가 같은 값이라고 적지는 않았다(9장) → PR 3에서 dev 회의로 확인한다.
   - **Notion 회의록**: 그 날의 일정에서 (가) 페이지를 만든 시각(`created_time`, Notion AI 회의록은 회의를 시작할 때 만들어진다)이 일정 `[시작 − 15분, 끝 + 15분]` 안이고, (나) 제목이 같거나(공백 · 기호 · 대소문자 무시) 한쪽이 다른 쪽을 포함한다. (가)와 (나)를 모두 맞는 일정이 하나면 그것, 없으면 (가)만 맞는 일정이 딱 하나면 그것, 그것도 없으면 (나)만 맞는 일정이 그날 딱 하나면 그것. 나머지는 잇지 않는다(G4).
   - 참석자가 사용자 한 명뿐인 일정은 고르지 않는다(혼자 잡은 작업 시간).
5. 붙이기: 원문의 `participants.attendees`에 일정 참석자를 합친다(이메일로, 없으면 이름으로 중복 제거, 200명 상한). 사용자는 연결한 Google 주소로 들어간다. `sources.meeting`에 `{ calendar_event_id, title, start, end }`(2-7).
6. 실패(토큰 · 네트워크 · 429)는 `null`로 넘긴다. 연결 상태는 바꾸지 않는다(`google` 동기화가 스스로 `reauth` · `error`를 남긴다).

Calendar 일정 자체는 원문으로 넣지 않는다(GO_LIVE.md 6장 "원문이 아니라 같은 회의를 잇는 열쇠").

### 2-5. Meet 전사 → 원문

| 항목 | 규칙 |
|---|---|
| 회의 기록 찾기 | ① 주최: `conferenceRecords.list`, `filter = end_time >= "{커서}"`(진행 중인 회의는 `end_time`이 없어 빠진다), `pageSize=100`. ② 참석(G2): 커서부터 지금까지의 Calendar 일정 중 사용자가 주최자가 아니고 거절하지 않았고 `conferenceData.conferenceSolution.key.type = hangoutsMeet`인 것의 회의 코드로 `filter = space.meeting_code = "{코드}" AND start_time >= "{일정 시작 − 1일}"`. 두 결과를 회의 기록 이름으로 합친다. Calendar 범위가 없으면 ②를 건너뛴다 |
| 커서 | `sync_cursor = { after: ISO 시각 }` = 이보다 먼저 끝난 회의 기록은 모두 결정됨(넣음 · 전사 없음 · 끝난 지 2시간 넘도록 전사 파일이 안 생김). 첫 동기화는 14일 전. 29일보다 오래됐으면 29일 전으로 당긴다(전사 항목은 끝난 뒤 30일에 지워진다) |
| 전사 고르기 | 회의 기록마다 `transcripts.list`. **이미 넣은 전사(외부 id)는 여기서 빼고** 항목 · 참가자 · 일정을 부르지 않는다(Notion이 본문을 받기 전에 거르는 것과 같다). 상태가 `FILE_GENERATED`인 전사만 넣는다. `ENDED`(파일 생성 전)면 다음 동기화에서 다시 보고, 회의가 끝난 지 2시간이 지나도 `ENDED`면 전사 항목으로 넣는다(파일 생성 시간은 Google이 정하지 않았다, 9장). 한 회의에 전사가 여럿이면(껐다 켬) 전사마다 원문 하나 |
| 전사 항목 · 참가자 | `transcripts.entries.list`(`pageSize=100`, 시작 시각 순)를 끝까지, `participants.list`로 이름표. 분당 요청 한도(사용자당 600)는 한 동기화에서 넘지 않는다 |
| 이름표 (G5) | 참가자가 `signedinUser`이고 `user`가 `users/{연결 계정 sub}`면 **Taskforce 프로필 이름**, 그 밖의 로그인 참가자 · 익명 참가자는 `displayName`, 전화 참가자는 `displayName`이 없으면 `전화 참가자`. 같은 화자의 이어진 항목은 한 줄로 합친다 |
| 같은 회의 일정 | 회의 기록의 `space`로 `spaces.get` → `meetingCode` → 2-4의 `findMeetingEvent`(회의 코드로 고르기). 회의 코드는 오래 두지 않는다(Meet 문서: 코드가 공간과 떨어질 수 있다) — 일정 id만 `sources.meeting`에 남긴다 |
| 종류 · 제목 | `kind = meeting`, `title` = 일정 제목, 없으면 `Google Meet · 2026-10-05 10:00`(KST), `writtenByMe = null` |
| 관련자 | `attendees` = 일정 참석자(이메일 · 이름) + Meet 참가자(이름, 일정 참석자와 이름이 같으면 합침). **사용자는 한 번만**: 일정의 `self` 참석자와 `sub`가 같은 Meet 참가자를 빼고, 프로필 이름 + 연결한 주소로 한 줄 넣는다. 안 그러면 사용자의 Meet 이름(`Daniel Song`)이 "다른 사람"으로 들어가 `findNameVariants` · `@이름` 규칙이 사용자를 남으로 볼 수 있다 |
| 시각 | `occurredAt` = 전사 시작 시각, `lastEditedAt` = 전사 끝 시각. 안정화는 `FILE_GENERATED` 확인으로 대신한다(`settleMinutes: 0`) |
| 외부 id · 버전 | `externalId = conferenceRecords/{c}/transcripts/{t}`, `externalVersion = "1"` |
| 원본 링크 | 전사 문서 `https://docs.google.com/document/d/{docsDestination.document}/view`. 주최자 Drive의 문서라, 같은 회사 초대자는 일정 첨부로 열 수 있고 다른 회사 참석자는 못 열 수 있다(9장) |
| 너무 짧은 원문 · 길이 | 기본값(30자 미만 버림). 20만 자 한도를 넘으면 뒤를 자른다(3시간 넘는 회의) |

본문 형식 (기존 회의 전사 골든셋의 `이름: 글`과 같은 모양, 머리줄은 Slack처럼 `[…]`):

```
[Google Meet · Proposal review — Acme]
Jordan Lee: Thanks for the draft. Could you revise the pricing section?
Alex Kim: Sure. I'll send the revised proposal to Jordan by Friday.
Jordan Lee: Great. I'll book the follow-up call next week.
```

- 위 예에서 `Alex Kim`은 사용자의 Taskforce 프로필 이름이다(Meet 표시 이름이 달라도).
- 전사 시각(타임스탬프)은 넣지 않는다. 기존 전사 골든셋 · 추출 프롬프트가 시각 없는 모양을 전제한다.
- Meet 전사가 있는 회의는 **사용자 회사에서 소수다**(대부분 Notion 전사만 켠다, G2). 그래서 Notion 회의록에 일정 참석자를 붙이는 2-4가 더 많은 회의에 닿는다: Notion AI 요약의 액션 아이템은 "태오: …"처럼 이름으로 담당을 적는 경우가 많고(INTEGRATIONS.md 예), 참석자 목록이 있으면 그 이름이 사용자인지 다른 사람인지 가리기 쉬워진다(`findNameVariants` · `@이름` 규칙이 관련자 이름을 쓴다).

**PR 3 구현에서 정한 것 (2026-09-29, `google/sync.ts` · `transcript.ts` · `run.ts`):**

- **커서 = "결정하지 못한 회의 기록의 가장 이른 끝 시각, 없으면 지금 − 30분"**, 뒤로 가지 않는다. 결정하지 못한 것: `ENDED`인데 끝난 지 2시간이 안 됨 · `STARTED`(2시간 뒤 포기) · 한 동기화 20건 상한을 넘김 · 나열 상한(회의 기록 150건)을 넘김 · 전사 나열 중 속도 제한 · Meet 요청 예산(400건) 소진 · 시간 한도 · 서버 시계보다 뒤의 전사 끝 시각. 지금 − 30분은 방금 끝난 회의가 목록에 늦게 나와도 놓치지 않으려는 겹침이고, 이미 넣은 전사는 외부 id로 걸러진다.
- **나열은 오래된 기록부터, 넣을 전사가 20건에 차면 멈춘다.** 회의 기록마다 전사를 나열하고 그 기록의 이미 넣은 전사를 바로 걸러 넣을 것을 센다. 그래서 첫 동기화에 기록이 수백 개여도 요청 예산을 나열에 다 쓰지 않고(독립 검토가 재현한 문제: 420건이면 항목을 받을 예산이 없어 매번 제자리), 전사가 없는 회의가 많아도 한 동기화에 150건까지 결정하고 다음에 이어 간다.
- **볼 수 없는 자료(403 · 404)는 못 본 것으로 세고 넘어간다.** 전사 목록 · 전사 항목 · 참가자가 403이면 그 회의(또는 전사)만 결정한 것으로 보고 `meet_artifacts_denied`로 센다(주최한 회의든 참석한 회의든 같다: 참가자가 회의 기록은 나열할 수 있어도 전사 자료는 못 볼 수 있다, 9장). 속도 제한 403(`rateLimitExceeded`)은 그렇게 넘기지 않고 멈춘다. 그 밖의 오류(서버 오류)는 동기화를 실패로 남기고 커서는 그대로다.
- **참석한 회의(G2 ②):** Calendar 일정은 커서 **하루 앞**부터 읽는다. 일정의 예정 끝은 실제 회의 끝보다 빠를 수 있어(회의가 길어지거나 전사 파일을 기다리는 동안 커서가 회의 끝에 머문다) 커서부터 읽으면 그 일정이 더는 목록에 나오지 않아 전사를 영영 놓친다(독립 검토가 재현, 여러 동기화에 걸친 시험으로 막았다). 읽는 필드는 회의 코드와 거르기용 값뿐이다: 제목 · 참석자 이메일 · 이름은 받지 않는다(`CALENDAR_CODE_FIELDS`, 회의 코드만 쓰고 저장하지 않는다). 회의 코드 조회가 403 · 404면 못 본 것으로 센다(`meet_attended_denied`). 일정 목록 · 회의 코드 조회가 그 밖의 이유로 실패하면(서버 오류 · 네트워크 · API를 켜지 않음) 실패로 세고(`meet_attended_failed`) ① 주최한 회의는 그대로 넣는다: 커서는 그 앞에 둬 다음에 다시 찾는다(실패가 계속되면 커서가 멈춰 매번 그 사이 기록을 다시 훑으니, 이 개수가 늘면 원인을 고친다). 429는 멈춘다. Calendar에서 읽은 회의 코드는 영문자 · 숫자 · 하이픈 모양일 때만 목록 조건(`filter`)에 넣는다(초대한 사람이 값을 정하므로).
- **일정 조회 실패**(Calendar 5xx · 403 · 네트워크 오류 · 시간 초과, 회의 공간 조회 서버 오류)는 일정 없이 넣고 `meet_link_failed`로 센다. 속도 제한(429)은 멈춘다(일정 없이 넣으면 그 전사에는 나중에 일정을 붙일 수 없다). 토큰 만료는 연결을 `reauth`로 보낸다.
- **이름표 충돌:** 다른 사람의 표시 이름이 사용자의 프로필 이름과 같으면(두 시험 계정이 모두 "Daniel Song"이었던 PR 2 dev와 같은 경우) 뒤 사람에게 `(2)`를 붙인다. 사용자를 참가자에서 찾았으면(G5) 사용자의 **별칭과 세 글자 한글 이름의 성을 뺀 부분**도 사용자의 이름표로 보고 다른 사람이 쓰면 `(2)`를 붙인다(`identity.ts` `isUser`가 이 형태들로 사용자를 알아보므로: 프로필 이름이 "송창훈"이고 별칭이 "Daniel Song"인데 다른 사람이 "Daniel Song"이면 그 사람의 약속이 사용자의 것으로 읽힌다). 사용자를 못 찾았으면(G5 가정이 틀림) 별칭은 막지 않는다. 같은 로그인 사용자가 기기 둘로 들어와 참가자가 둘이면 한 사람(같은 이름표, 이어진 항목은 한 줄)이다. 이름표에서 `:` `[` `]` 줄바꿈은 빼고 30자로 자르고, `(2)`…`(99)`를 붙여도 30자 안에 든다(이름표 읽기 `quoteSpeaker`가 깨지지 않게).
- **G10 부분 허용:** `connect`는 Calendar · Meet 중 하나라도 받으면 연결(`connected_partial`은 하나만, `connected`는 둘 다), 둘 다 없거나 `openid`가 없으면 토큰을 폐기하고 `missing_scope`. 동기화는 받은 범위만 쓴다: Meet이 없으면 전사를 가져오지 않고, Calendar만이면 토큰이 아직 쓸 수 있는지만 본다(만료 · 거둠을 `reauth`로 알리려고 Calendar 요청 1건), Calendar가 없으면 참석한 회의 찾기 · 일정 붙이기를 하지 않는다.
- **통계 키 (`settings.stats.counts`, 글자 · 주소 없이):** `meet_transcripts`(넣은 전사) · `meet_transcripts_attended`(참석한 회의로만 찾은 것) · `meet_transcripts_abandoned`(`STARTED` 등으로 2시간 넘게 남아 포기한 것) · `meet_transcripts_short`(항목이 비었거나 30자 미만이라 넣지 않은 것) · `meet_attended_codes`(조회한 회의 코드) · `meet_attended_denied`(회의 기록을 못 본 것) · `meet_attended_failed`(일정 목록 · 회의 코드 조회 실패) · `meet_artifacts_denied`(전사 목록 · 항목 · 참가자를 못 본 것) · `meet_link_{attached,ambiguous,none,failed}`(Meet 전사 ↔ 일정) · `notion_link_{attached,ambiguous,none,failed}`(Notion 회의록 ↔ 일정). `meet_transcripts*` · `meet_link_*`는 실제로 저장한 원문만(`insertSource`가 저장한 것) 세고, `notion_link_*` · `meet_attended_*`는 조회를 시도한 횟수다.

### 2-6. Gmail → 원문

| 항목 | 규칙 |
|---|---|
| 목록 | `users.messages.list`, `q = after:{창 시작의 epoch 초} before:{창 끝} -in:chats -in:drafts -category:promotions -category:social`, `includeSpamTrash=false`(기본). 창은 아래 "커서 · 창". `after:` · `before:`는 epoch 초를 받는다(Gmail 검색 안내: 날짜만 주면 PST 0시로 읽으니 다른 시간대는 초로 주라, 9장). `fields=messages(id,threadId),nextPageToken` |
| 한도 | 쿼터 단위: `messages.list` 5, `messages.get` 20(형식과 관계없이), 사용자당 분당 6,000(9장). 한 동기화에 **머리글 읽기 200통 + 본문 받기 20통**(넣기 공통 상한 `ingestItems` 20건과 같게, 합쳐 4,500 단위 안팎), 동시에 4개, 오래된 것부터. 본문을 받았는데 넣지 못한 메일이 생기지 않게 두 상한을 맞춘다. 429면 멈추고 결정을 마친 곳까지만 커서를 옮긴다(연결은 `error` "Gmail 요청 한도에 걸려 다음 동기화에서 이어서 가져옵니다.", 다음 동기화가 `active`로 되돌린다). 첫 14일이 많으면 몇 시간에 걸쳐 오래된 것부터 채워진다(Notion과 같음) |
| 커서 · 창 | `sync_cursor = { after: ISO 시각, seen: { 메시지 id: 받은 시각(epoch ms) } }`. `after` 앞의 메일은 모두 결정됨(넣음 · 거름), `seen`은 `after − 1시간` 뒤에서 이미 결정한 id(최대 2,000개, 넘으면 최근 것만). 받은 시각을 같이 두어 겹침 구간을 지난 id를 버린다: 창을 끝내도 `seen`을 비우지 않아 겹침 1시간의 거른 메일을 매번 다시 읽지 않는다(`settings.stats`가 두 번 세지 않게). 목록은 `after − 1시간`부터 **하루 단위 창**(`after:` · `before:`)으로 오래된 창부터 받고, 창 안의 id는 페이지를 끝까지 받는다(`messages.list`는 날짜순을 약속하지 않는다). 받은 id에서 **이미 넣은 것(`ingestedIds`, 2-2의 끊긴 연결 포함)과 `seen`을 먼저 빼고** 남은 것만 머리글을 읽는다 — 본문을 받기 전에 거른다. 창 하나를 다 결정하면 `after` = 창 끝. 한도 · 시간 · 429(또는 403 `rateLimitExceeded` · `userRateLimitExceeded`)로 멈추면 `after`는 그대로 두고 결정한 id만 `seen`에 더한다. 한 창에 아직 결정하지 않은 메일이 `seen`에 다 담기지 않을 만큼(2,000 − 200통 넘게) 많으면 창을 반씩, 2시간까지 줄인다(`seen`이 넘쳐 오래된 결정부터 잊으면 커서가 그 창에 묶인다). 창 끝(`before:`)은 초 단위로 내림한다. "이미 넣음" 확인은 150개씩 나눠 묻는다. 첫 동기화는 14일 전, `after`가 30일보다 오래됐으면 30일 전으로 당긴다(G8) |
| 머리글 읽기 | 목록의 메일마다 `users.messages.get(format=metadata, metadataHeaders=From,To,Cc,Subject,Date,Message-ID,List-Id,List-Unsubscribe,Precedence,Auto-Submitted,Sender,Content-Type,Content-Class)` + `labelIds`, `fields=id,threadId,labelIds,internalDate,payload/headers`. 본문은 받지 않는다 — `snippet`(본문 앞부분)도 `fields`에서 뺀다 |
| 거르기 | `gmail/filter.ts`. 위에서부터 처음 맞는 규칙: ① `DRAFT` · `SPAM` · `TRASH` · `CHAT` 표시 → 버림 ② `Auto-Submitted`가 있고 `no`가 아님 → 버림(부재 중 자동 답장 · 시스템 알림. 사용자가 보낸 것도) ③ `SENT` 표시가 있거나 보낸 사람이 사용자(연결한 Google 주소 · 프로필 이메일) → **남김** ④ `CATEGORY_PROMOTIONS` · `CATEGORY_SOCIAL` → 버림 ⑤ `Precedence`가 `bulk` · `junk` → 버림 ⑥ `List-Unsubscribe` 또는 `List-Id`가 있고, 보낸 주소의 도메인도 `List-Id`의 도메인(Google 그룹은 `<team.회사.dev>`)도 사용자 회사 도메인(연결한 주소의 도메인과 그 하위 도메인, 단 `gmail.com` 같은 공용 도메인이면 회사 도메인 없음)이 아님 → 버림. `List-Id`도 보는 이유: 거래처가 회사 그룹 주소로 보낸 메일은 보낸 주소가 거래처 도메인이다 ⑦ 보낸 주소 앞부분이 no-reply 낱말(`noreply` · `no-reply` · `no_reply` · `donotreply` · `do-not-reply`)로 시작하거나 구분자(`-` `_` `.` `+`) 뒤에 있음(`workspace-noreply@`), 또는 `notification(s)` · `mailer-daemon` · `postmaster` · `bounce`로 시작 → 버림 ⑧ 일정 초대(`Content-Type`이 `text/calendar`를 담거나, Outlook 초대의 `Content-Class: …calendarmessage`, `From` · `Sender`가 Google Calendar 알림 주소 `calendar-notification@google.com`) → 버림. `format=metadata`는 맨 위 머리글만 주어 초대 메일의 `text/calendar` 부분은 보이지 않으므로 `Sender`가 주로 잡는다 ⑨ 나머지 → 남김. 버린 메일은 이유 코드별 개수만 연결 설정 `settings.stats`에 더한다(로그 · 원문에는 남기지 않는다) |
| 본문 받기 | 남긴 메일만 `format=full`(`fields=id,threadId,labelIds,internalDate,payload`). `text/plain` 부분을 먼저, 없으면 `text/html`을 글로 바꾼다(태그 · 스타일 · 스크립트 제거, 줄바꿈 유지, 링크는 `글 (주소)`). 파일 이름이 있는 부분(첨부)은 읽지 않는다. `Content-Type`의 문자 집합으로 풀고(UTF-8 · EUC-KR · ISO-2022-KR 등, Node `TextDecoder`), 모르면 UTF-8 |
| 종류 · 제목 | `kind = email`, `title = 제목`(200자), `writtenByMe = null`(메일에는 인용된 남의 글이 섞인다. judge-v4의 "직접 쓴 문서" 질문을 쓰지 않는다) |
| 관련자 | `from` · `to` · `cc`: 머리글의 `이름 <주소>`를 그대로(이름이 없으면 주소만). 사용자는 G5와 같게 연결한 주소로 알아본다(`loadIdentity`에 더함, 2-2). `Bcc`는 받는 쪽 머리글에 없으므로 쓰지 않는다 |
| 시각 | `occurredAt` = `lastEditedAt` = `internalDate`(Gmail이 받은 · 보낸 시각). 안정화 없이 넣는다(G6, `settleMinutes: 0`) |
| 외부 id · 버전 | `externalId = Gmail 메시지 id`, `externalVersion = "1"`(메일은 바뀌지 않는다) |
| 원본 링크 | `https://mail.google.com/mail/?authuser={연결한 주소}#all/{threadId}`. Google이 공식으로 정한 주소 형식은 없다(9장). dev에서 열리는지 PR 2에서 확인한다 |
| 너무 짧은 원문 | 길이로 거르지 않는다(`minTextLength: 1`). "OK" · "Sounds good." 같은 수락도 기한 변경의 근거다. 제목 줄이 있어 빈 글은 생기지 않는다 |
| 길이 | 본문 2만 자에서 자른다(인용된 옛 메일이 길게 이어지는 스레드의 비용 상한). 한도 20만 자보다 작다. 글로 바꾸기 전에 부분마다 20만 자에서 먼저 자른다(몇 MB짜리 HTML) |
| 저장할 수 없는 글자 | NUL과 짝이 없는 서로게이트(자른 끝의 이모지 반쪽 · `&#xD800;`)는 빼거나 U+FFFD로 바꾼다(`storableText`). 남으면 원문 저장이 실패하고 그 창에서 동기화가 멈춘다 |

본문 형식 (머리줄은 제목만, 보낸 사람 · 받는 사람은 `participants`로. 기존 메일 골든셋은 `제목:`만 있는 것과 `보낸사람:` · `받는사람:` 줄이 있는 것이 섞여 있다 — 어댑터는 앞의 모양 하나로 정하고, Gmail 골든셋은 이 모양으로 쓴다):

```
제목: RE: Signed contract

Sure, I'll send it by Monday.

Alex

On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <jordan@…> wrote:

> Could you send the signed contract by Monday?
```

- 본문은 메일 앱이 쓴 그대로 둔다(인용 포함, G6). 줄 끝 공백 · 3줄 넘는 빈 줄만 정리한다.
- 인용이 시작하는 곳(`On … wrote:` · `>`로 시작하는 줄 · `-----Original Message-----` · `-----원본 메시지-----` · 빈 줄 뒤의 `From:`/`보낸 사람:` 머리 묶음)을 찾는 순수 함수 `quotedHistoryStart(text)`를 `lib/pipeline/text.ts`에 둔다(eval도 같은 함수를 쓴다). PR 1 골든셋 `seq-gmail-quoted-stale-deadline`이 틀리면 PR 1b에서 기계 검증에 규칙 하나를 더한다: 메일 원문에서 인용이 이 위치 뒤에만 있는 후보는 버린다(옛 메일의 말은 그 메일이 들어올 때 이미 Claim이 됐고, 새 메일의 시각으로 다시 들어가면 규칙 4가 틀린다).
- 보낸 사람 · 받는 사람 줄을 본문에 넣지 않는 이유: 화자 이름표 읽기(`quoteSpeaker`)가 `보낸 사람: …`을 이름표로 오해할 여지를 두지 않는다. 사용자 위치는 `participants`로 `userPosition`이 정한다.

### 2-7. 데이터 (새 마이그레이션)

두 Google 연결은 대기 표가 없어서 새 표를 만들지 않는다. 바뀌는 것은 하나다.

| 표 · 변경 | 내용 | 지워지는 때 |
|---|---|---|
| `sources.meeting` (jsonb, null 가능) | 회의 원문(Notion 회의록 · Meet 전사)에 붙인 일정: `{ calendar_event_id, title, start, end }`. 앱이 근거 줄에 "Sep 30 · Proposal review — Acme"를 보이고 Sources를 한 회의로 묶는 데 쓴다([google-verification.md](google-verification.md) 5장 영상 A). 앱은 기존 `sources` RLS 읽기로 본다 | 원문 행과 함께(계정 삭제). 90일 본문 삭제 때는 남는다(제목 · 관련자와 같은 취급) |

- 새 표가 없으므로 `tests/db/`에는 새 열이 `authenticated`에게 자기 행만 보이는지(기존 `sources` RLS) 한 줄을 더하고, `tests/db/migrations.test.ts`에 열이 있는지 더한다.
- **PR 3 ✅ (2026-09-29):** `supabase/migrations/20261016000000_sources_meeting.sql` — `sources.meeting jsonb`(null 가능) + 모양 검사 `sources_meeting_shape`(객체, `calendar_event_id` · `start` · `end`는 문자열, `title`은 문자열 또는 null). 검사에서 없는 키는 `jsonb_typeof`가 null이라 check가 그냥 통과해 버려서 `coalesce(…, false)`로 막았다(DB 테스트가 잡았다). `tests/db/sources-meeting.test.ts`(모양 · RLS · 90일 본문 삭제에 남음 · 연결 끊기에 남음 · 계정 삭제로 지워짐)와 `migrations.test.ts`의 열 · RLS 한 건. **운영 DB에는 적용하지 않았다.**
- 운영 DB 적용은 사용자 승인 뒤 `npx supabase db query --linked -f <file>`로 새 파일 하나만(`supabase db push` 금지, 런북 4장). 코드는 일정이 붙은 원문만 `meeting` 열을 보내므로 적용 전에 배포해도 다른 원문은 저장된다. 열이 없는데 일정이 붙은 원문을 저장하려 하면(PostgREST `PGRST204` · Postgres `42703`) 일정 없이 다시 넣고 로그를 남긴다 — 그러지 않으면 저장 실패가 `ingestItems`의 배치를 멈춰 Notion 동기화가 매번 같은 자리에서 막힌다(독립 검토가 짚음). 이 경우 그 원문은 일정 연결(근거 줄의 일정 제목)을 잃으므로, 운영에서 google 연결을 처음 만들기 전에 적용하는 것이 여전히 순서다. `/admin/metrics`의 "일정이 붙은 비율"은 열이 없으면 0으로 보인다(오류는 로그에만).
- G11 결과에 따라 연결 끊기 때 지울 것이 생기면 이 표에 더한다.

### 2-8. 끊기 · 계정 삭제 · 토큰

- 연결 끊기(`DELETE /api/v1/connections/:id` → `handleConnectionDelete`)와 계정 삭제(`revokeConnectorTokens`)는 `Connector.revokeToken`만 구현하면 이어진다(`tokenRevokerFor`). 폐기가 실패해도(Google 장애) 끊기는 계속한다(Slack과 같음).
- 이용자가 Google 계정 설정에서 Taskforce 접근을 거두면 다음 동기화의 갱신이 `invalid_grant` → `reauth`(2-3). 앱에는 "Reconnect to keep syncing"과 Disconnect가 함께 보인다.
- 연결 끊기 때 Google에서 온 원문의 처리: G11.

## 3. 앱 (Swift)

판정 로직은 넣지 않는다. 서버가 `google` · `gmail`을 등록하고 플래그를 켜면 연결 시작 API의 400이 멈추므로 "Coming soon"은 저절로 Connect가 된다(`Connections.swift`의 `comingSoon`).

| 곳 | 바꿀 것 |
|---|---|
| 연결 전 안내 (`readsBeforeConnecting`) | Google은 이미 세 줄이 있다. G2 시험 결과에 맞춰 Meet 줄을 고친다(지금 "Meet: transcripts of meetings you attend" — 참석한 회의를 못 읽으면 "meetings you host"). **Gmail은 비어 있어 확인 없이 권한 화면으로 간다** → [google-verification.md](google-verification.md) 2-4의 줄 그대로: "Email you sent or received. Newsletters and promotions are skipped." · "Read-only. Sent to AI only after your consent. Never used for training." · "Beta: reconnect every 7 days." Google의 지금 세 줄도 2-4와 다르다("Read-only. Taskforce never changes or sends anything.") — Google이 요구하는 앱 안 공개라 2-4에 맞춘다 |
| 7일 재연결 | 연결 줄은 이미 있다("Beta · Reconnect every 7 days" · "Reconnect to keep syncing"). 알림(G9)을 누르면 연결 화면이 열리게 알림 종류 하나를 더한다(`PushNotifications.swift` `NotificationTarget.Kind`, `PushCenter.swift`) |
| 연결 결과 (G10) | `ConnectionCallback.Status`에 `connected_partial` · `missing_scope`와 문구 |
| 근거 줄 · Sources | 원문에 `meeting`이 있으면 근거 줄의 출처를 일정 제목 · 날짜로("Sep 30 · Proposal review — Acme"), Sources는 같은 `calendar_event_id`의 원문을 한 회의로 묶는다. 영상 A(L4)에 필요하다 |
| 원문 서비스 표시 | 이미 된다(`SourceService.infer`: `mail.google.com` → Gmail, 종류 `meeting`의 `docs.google.com` → Google Meet). 확인만 |
| 원문 읽기 | `SourceSummary.columns`(`Models.swift`)에 `meeting` |
| 연결 끊기 확인 | G11 결과에 맞춘다. 원문이 남으면 지금 문구 "Tasks already found stay."가 맞다 |

UI 문구는 짧은 영어 라벨 규칙을 따른다. 설명 줄은 위 줄들만 둔다. 서비스는 실제 로고로 보인다(`logo`: Google Meet · Gmail은 이미 있다).

## 4. 골든셋 · eval

**코드보다 먼저 만든다**(Slack PR 1과 같은 방식). 본문은 2-5 · 2-6 형식과 글자까지 같게 쓰고 관련자를 채운다. 파일 이름은 `evals/golden/gmail-*.json` · `seq-gmail-*.json` · `meet-*.json` · `seq-meet-*.json` · `seq-notion-after-meet.json` · `notion-summary-*.json`, `tags: ["gmail"]` · `["meet"]`. 모두 합성이고 실제 원문은 G13으로 더한다. 형식은 `evals/golden/README.md` "Gmail · Meet 케이스"(PR 1).

**Gmail (`--tag gmail`)**

| 케이스 | 보는 것 |
|---|---|
| `gmail-reply-commit-quoted` | 내 답장 "Sure, I'll send it by Monday." + Gmail식 인용(`On … wrote:` · `>`)의 요청 → 내 할 일, 기한 월요일, 인용 속 요청을 따로 뽑지 않음 (심사 fixture 1) |
| `gmail-info-only` | "Office hours are unchanged this week. No action needed." → 없음 (fixture 2) |
| `gmail-cc-for-awareness` | "Sam, please update the banner. Alex is copied for awareness." (사용자는 참조) → 없음 (fixture 3) |
| `seq-gmail-extend-in-thread` | 요청 · 내 약속 → 상대 "Wednesday works too, no rush." → 새 할 일 없이 기한 수요일 (fixture 5, 규칙 0) |
| `seq-gmail-request-then-reply` | 상대 요청(혼자 받음)과 두 시간 뒤 내 수락이 **따로 들어옴** → 할 일 하나, 남은 확인 요청 없음 (G6 · G12) |
| `gmail-request-in-recap-ko` | 한국어 회의 정리 메일(혼자 받음): 상대 쪽 할 일 · 이미 끝난 일 사이에 "견적서 수정본도 목요일까지 부탁드려도 될까요?" (아직 수락 전) → G12를 정하는 케이스(`needs_review`). 기존 `email-sole-recipient-request`(요청만 있는 메일 → 할 일)와 문장이 겹치지 않게 |
| `seq-gmail-quoted-stale-deadline` | 요청 "by Monday" → 내 답장 "Sure, I'll send … by Monday." → 상대 "Wednesday works" → 월요일에 내 "Thanks!" 답장(앞 세 통을 인용) → 기한 **수요일 그대로**, 인용 속 "by Monday"가 새 Claim이 되지 않음 (G6 위험). 내 약속을 인용에 넣은 이유: 기한을 당기는 것은 나 혼자도 되므로(규칙 0) 인용 속 **내** 옛 약속이 다시 뽑힐 때 가장 위험하다 |
| `gmail-group-mail-internal` | 회사 그룹 주소로 온 메일에서 사용자를 이름으로 부른 요청 → 내 할 일 (G7에서 남긴 메일이 실제로 쓸모 있는지) |
| `gmail-forwarded-with-note` | 사용자가 전달하며 "Could you take this by Friday, Sam?"를 붙임 → 내 할 일 아님, 전달된 원문 속 약속도 아님 |
| `gmail-long-quoted-history` | 다섯 통이 인용으로 이어진 답장, 새로 쓴 곳엔 "감사합니다" 한 줄 → 없음 (인용 속 옛 약속을 새로 뽑지 않음) |
| `seq-gmail-meeting-then-email` | 회의록 "금요일까지 제안서" → 요청자 메일 "월요일에 받아도 괜찮습니다" → 기한 월요일 (핵심 시나리오 2를 메일로) |
| `seq-gmail-done` | 내 약속 → 내 메일 "Attached the signed contract." → 완료 |
| `gmail-mixed-language` | 영어 메일에 한국어 답장 |

**Meet (`--tag meet`)**

| 케이스 | 보는 것 |
|---|---|
| `meet-speaker-commit` | 전사에서 내가 한 약속 + 상대가 한 약속("I'll book the follow-up call") → 내 것만 (심사 fixture) |
| `seq-meet-after-notion` | **핵심.** Notion AI 요약(발화자 없음, 담당 없는 액션 아이템 "Send revised proposal (Friday)", 일정 참석자 붙음) → 같은 회의 Meet 전사 → 할 일 하나, 담당 나, 확인 요청 없음, 근거 둘 |
| `seq-notion-after-meet` | 같은 두 원문을 반대 순서로 → 같은 결과 (회의록이 새 할 일 · 확인 요청을 만들지 않음) |
| `seq-meet-others-item` | Notion의 담당 없는 액션 아이템 둘("Share usability test results (Thursday)" · "Update signup form copy") + 전사에서 다른 참석자가 맡음 → 내 할 일 아님, 확인 요청도 남지 않음 |
| `meet-korean-transcript` | 한국어 회의 전사(Meet 전사는 한국어를 지원한다, 9장), 받아쓰기 오류(전환율 → 전화율, 사용자 이름 한 글자) · 다른 참석자의 영문 표시 이름(`Minjun Park`)과 한국어 발화가 섞임 |
| `notion-summary-names-attendees` | 전사 없이 Notion 요약만, 액션 아이템이 "태오: …" · "Alex: …"처럼 이름으로 담당을 적고 일정 참석자가 붙음 → 사용자 이름(별칭)의 일만 내 할 일. **사용자 회사의 가장 흔한 모양**(G2) |
| `meet-long-transcript` | 40분 분량, 약속 여럿 · 잡담 · 조건부 약속 |
| `notion-summary-with-attendees` | 전사 없이 Notion 요약만, 일정 참석자 두 명(나 · 상대) → 확인 요청(`needs_review`) — 지금과 같은지(참석자를 붙여도 확인 요청 수가 늘지 않는지) |
| `seq-meet-then-email-extension` | 회의에서 약속 → 요청자 메일로 연장 → 기한 갱신 |

- 기준(제안): 추출 precision · recall 0.9 이상, 시퀀스 병합 정확도 100%, 함정 자동 반영 0. 못 미치면 원인을 적고 PR 1b에서 고친다.
- 결과는 `evals/golden/README.md` 기록 표에 "Gmail" · "Meet" 줄로 따로 적는다. README의 케이스 형식 절에 "Gmail · Meet 케이스"를 더한다.
- `seq-meet-after-notion`이 틀리면 매칭 후보에 "같은 회의" 표시를 넣을지(골든셋 형식에 `meeting` 칸을 더하는 것부터) PR 1b에서 본다. 지금 파이프라인은 같은 회의인지 모른다. → PR 1 결과: 표시 없이도 하나로 합쳐졌다(아래 "기준 점수"). 남은 것은 확인 요청(E4)이다.

### 기준 점수 (PR 1, 2026-09-29)

`npm run eval -- --tag gmail` 5번 · `--tag meet` 3번 + 전체 `npm run eval` 4번, glm-5.3-flash · extract-v5 + judge-v5 + match-v1. 파이프라인 · 프롬프트는 바꾸지 않았다. 아래 숫자는 끝까지 돈 실행을 모두 합친 것이다(Gmail 9번 · Meet 7번, 시간 초과로 빠진 케이스는 그 실행에서 뺌). `seq-gmail-quoted-stale-deadline`은 첫 실행 뒤 내 약속 메일을 더해 지금 모양이 됐고(위 표), 병합 숫자는 지금 모양으로 돈 4번만 센다.

eval에 하나를 더했다: 시퀀스 끝에 **확인 요청이 남은 열린 Action**(앱과 같은 `projectAction` 계산)과 오탐의 자동 반영 · 확인 요청 구분. 위 표의 "확인 요청 없음"을 재려고.

| 항목 | Gmail | Meet | 기준(제안) |
|---|---|---|---|
| 원문 하나 precision · recall (자동+확인) | 85.3% · 80.6% (29/34 · 29/36) | 87.5% · 100% (42/48 · 42/42) | 0.9 · 0.9 — 미달 |
| 원문 하나 precision · recall (자동만) | 87.1% · 100% (27/31) | 100% · 100% (35/35) | — |
| 담당 · 기한 정확도 | 100% · 100% | 83.3% · 100% | — |
| 시퀀스 병합 정확도 | **95.0% (38/40)** | 100% (20/20) | 100% — Gmail 미달 |
| 함정 자동 반영 | **4**(원문 하나, E1) + 기한 되돌림 2(시퀀스, E2) | 0 | 0 — Gmail 미달 |
| 시퀀스 끝 확인 요청 남음 | 21 / 시퀀스 40번 (E3) | 13 / 27번 (E4 · 조건부 발언) | "확인 요청 없음" 케이스는 0 |
| Jev 사람 라벨 일치율 (실행마다 같음) | 내 약속 13/13 · 할 일 11/12 · 이미 함 5/8 · 확정 5/5 | 16/16 · 11/13 · 8/8 · 10/10 | — |
| 비용 (태그 한 번) | 약 $0.016~0.024 | 약 $0.018 | — |

잘 된 것:
- 심사 fixture 1 · 5(`gmail-reply-commit-quoted` · `seq-gmail-extend-in-thread`)와 영상 A의 Meet fixture(`meet-speaker-commit`)는 기한 · 담당이 매번 맞았다.
- 영어 요일 기한(목요일의 "by Monday" → 다음 월요일, 금요일의 "Wednesday" → 다음 수요일)도 매번 맞았다. `dates.ts`는 한국어만 다시 계산하므로 모델 값 그대로다.
- 참조 · 전달 · 정보 메일에서는 한 건도 뽑지 않았다. 그룹 메일에서 이름으로 부른 요청은 9/9 자동 반영, 한영 섞인 답장은 9/9.
- 핵심 시나리오 2를 메일로(`seq-gmail-meeting-then-email`), 회의 → 메일 연장(`seq-meet-then-email-extension`), 완료(`seq-gmail-done`)가 모두 맞았다.
- **같은 회의의 Notion 회의록과 Meet 전사는 지금 매칭으로도 하나로 합쳐진다**(duplicate 0.99~1.00, 순서를 바꿔도 같음). 담당도 "나"로 맞았다.
- 긴 전사(`meet-long-transcript`, 약속 셋 · 함정 열하나)는 끝까지 돈 5번 모두 3/3, 함정 0.
- 일정 참석자를 붙여도 확인 요청 수가 늘지 않았다: `notion-summary-with-attendees`에서 참석자를 뺀 같은 원문(시험용, 커밋 안 함)도 3번 모두 확인 요청 1건. 담당 없는 액션 아이템을 추출기가 `me`로 적는 것은 참석자가 있을 때 7/7, 없을 때 2/3으로, 3번뿐이라 차이라고 보기 어렵다.

틀린 것 (Claim · 판정을 직접 확인했다):

| # | 케이스 (재현) | 무엇이 일어났나 | 고칠 곳 (PR 1b) |
|---|---|---|---|
| E1 | `gmail-long-quoted-history` (끝까지 돈 6번 중 4번) | 인용 속 옛 약속 "네, 수정 시안은 목요일까지 드리겠습니다."(이미 보낸 일)를 새 메일의 시각으로 뽑고 Jev가 **자동 반영**한다(0.87~0.91). 이미 끝난 일이 새 할 일이 된다 | 2-6의 `quotedHistoryStart(text)`(`lib/pipeline/text.ts`) + 기계 검증 규칙: 메일 원문에서 인용 시작 뒤에만 있는 구절을 인용한 후보는 버린다 |
| E2 | `seq-gmail-quoted-stale-deadline` (지금 모양 4번 중 2번), `seq-gmail-extend-in-thread` (조짐) | **G6 위험이 실제로 났다.** 월요일 "Thanks" 메일이 인용한 내 옛 약속 "…by Monday."가 그 메일의 시각에 **내 확정 발언**으로 다시 뽑혀, 기한이 수요일에서 월요일로 되돌아갔다("기한 확인"도 남음). 기한을 당기는 것은 나 혼자도 되므로 규칙 0이 막지 않는다. 다른 실행에서도 상대 메일이 인용한 내 약속이 자주 다시 뽑혔다. 같은 메일의 연장 Claim보다 앞에 붙어서 겨우 비껴갔을 뿐이다(순서가 바뀌면 규칙 6 동점 → 확인 요청) | E1과 같은 규칙. 옛 메일의 말은 그 메일이 들어올 때 이미 Claim이 됐다 |
| E3 | `seq-gmail-request-then-reply` 8/9 · `seq-gmail-extend-in-thread` 9/9 · `seq-gmail-quoted-stale-deadline` 4/4, 기존 `seq-slack-gap-reply`도 | 요청 메일(혼자 받음)의 요청은 Jev가 확인 요청으로 보낸다(0.5~0.8, "판정 확인: NOT_MY_ACTION"). 그 내용 · 담당 · 상태 Claim은 요청자의 미확정 발언이다. 뒤에 온 **내 수락 메일은 duplicate로 붙어 기한 Claim만 더하므로**(`candidateClaims`) "판정 확인 · 내용 · 담당 · 상태 확인"이 끝까지 남는다. 기한 · 담당 값은 맞다. 메일은 요청과 수락이 늘 다른 원문으로 들어와서(G6) 가장 흔한 모양이다 | 병합: 사용자의 확정 약속(me · firm · first_hand)이 기존 Action에 duplicate · update로 붙으면 내용 · 담당 · 상태 Claim도 더하고, 판정 단계의 "판정 확인" 이유를 푼다(규칙 0 "양쪽이 말했는가") |
| E4 | `seq-meet-after-notion` 7/7 | Notion 요약의 담당 없는 액션 아이템을 추출기가 `me`로 뽑고 Jev가 확인 요청(0.4 근처)으로 보낸다. 같은 회의 Meet 전사의 내 약속이 duplicate로 붙어도 저장된 "판정 확인"이 남는다. 순서를 바꾸면(`seq-notion-after-meet`) 남지 않는다 | E3과 같은 고침 |
| E5 | `gmail-request-in-recap-ko` 9번 중 7번 기각 · 기존 `freelance-client-recap-email` 4/4 기각 | G12. 정리 메일 속 요청은 Jev "내 약속" 0.27~0.40, 대부분 기각선(0.4) 아래라 조용히 사라진다. 요청만 있는 메일(`email-sole-recipient-request`)은 0.49~0.62로 확인 요청이 된다 | **G12 결정(✅): 확인 요청으로.** `decideOutcome`의 F3 규칙(`addressedToUser`)을 "사용자가 유일한 받는 사람인 메일의 후보"로 넓힌다. 기각 사유가 "내 약속 아님" 하나면 확인 요청까지. 저장된 판정 결과에 이 규칙을 대 보면(추정, 아직 구현 전) 골든셋에서 실행마다 누락 2가 확인 요청 2가 되고, 틀린 확인 요청은 생기지 않는다(혼자 받은 메일의 추출 후보 기준. 사람 라벨로 물으면 인용 속 옛 약속 1건이 더 걸리지만 E1이 먼저 버린다) |
| E6 | `gmail-long-quoted-history` 3/9 · `seq-gmail-quoted-stale-deadline` 2/9 · `meet-long-transcript` 2/7 · `gmail-forwarded-with-note` 1/9 · `meet-korean-transcript` 1/7 · `seq-meet-then-email-extension` 1/7 | 추출 응답이 90초 시간 초과된다. 인용이 겹겹인 메일은 664자인데도 자주 걸린다(글 길이가 아니라 모델의 추론이 길어짐). 같은 날 기존 케이스도 1~2번씩 걸려 전체 eval 4번 모두 호출 실패로 끝났다(짧은 케이스 포함, 공급자 응답이 느렸다). 한 번 다시 시도한 뒤에도 넘으면 원문은 `failed`가 된다(`llm.ts` · `process.ts`) | E1은 후보만 버리고 추출 입력은 그대로라 이것을 줄이지 못한다. 추출 입력에서 두 단계 넘는 깊은 인용을 줄일지 E1과 함께 보고, `failed` 원문을 다시 처리하는 길을 확인한다 |

고치지 않고 지켜볼 것:
- `notion-summary-with-attendees`: 담당 없는 액션 아이템(참석자 둘)을 추출기가 `me`로 뽑는다(정답 `unknown`, 7/7). 확인 요청으로 가서 자동 반영은 되지 않는다.
- 조건부 발언이 확인 요청으로 간다: `meet-korean-transcript` "예산은 제가 팀장님이랑 먼저 얘기해 보고 말씀드릴게요" 6/6, `seq-meet-others-item` "I'll take a look once they're in" 6/7, `gmail-mixed-language` 1/9. 자동 반영은 0이지만 확인 요청 수를 늘린다(원칙 3). 추출 프롬프트에 조건부 예시를 더할지는 E1~E5를 고친 뒤 전체 숫자를 보고 정한다.

### 어댑터 단위 테스트 (eval 아님)

권한 주소 값 · code 교환 · `id_token` 읽기 · 받은 범위(G10) · 갱신 · `invalid_grant` → `reauth` · 토큰 창구 401 → `error` · 폐기(이미 폐기된 토큰 포함), Calendar `fields`에 설명 · 첨부가 없음 · 일정 거르기 · 회의 잇기 규칙 표 전부, Meet 전사 → 본문(사용자 줄 이름표 · 이어진 같은 화자 합치기 · 익명 참가자), Gmail 거르기 표 전부 · MIME(plain · html · 첨부 · EUC-KR) · 커서(빈틈 · 시간 한도 · 30일 당김) · 링크, `loadIdentity`에 연결 주소, 알림 한 번.

## 5. 문서 · 처리방침 맞추기

같은 PR에서 한국어 · 영어를 함께 고친다(`docs/legal/README.md` 게시 규칙 3 · 4). PR 5에서 하고, 앞 PR은 구현이 처리방침과 다르지 않게만 한다.

**PR 5는 5a(Gmail)와 5b(Calendar · Meet)로 나눴다**(2026-09-29). Gmail 연결(PR 2)은 이미 병합됐고 운영에서는 처리방침이 구현과 같아질 때까지 새 연결이 닫혀 있다(`GMAIL_CONNECT_ENABLED`). PR 3(Calendar · Meet)은 시험 계정(U3)을 기다리므로 Gmail만 먼저 맞춘다. 아래 표와 "그 밖에"의 Gmail 몫이 5a(✅, 문서만), Google(Calendar · Meet)과 전체 검증 · 런북 C4 마무리가 5b다. 처리방침은 원본만 고쳤고 웹사이트 재게시 · 시행일은 사용자가 정한다(`docs/legal/README.md` "게시 대기").

| 곳 | 지금 | 고칠 것 |
|---|---|---|
| 3장 Google "Calendar에서 읽는 것" | 제목 · 시각 · 주최자 · 참석자 · Meet 식별자, 설명 · 첨부 제외 | **(5b)** 구현(`fields`)과 같다. "회의 원문을 넣을 때 그 앞뒤 일정만 읽는다"를 한 줄 더한다(G3) |
| 3장 Google "Meet 전사에서 읽는 것" | "이용자의 Google Meet 회의 기록과 전사" | **(5b)** G2 시험 결과: "이용자가 주최하거나 참석한 회의" 또는 "주최한 회의". 참석한 회의를 찾으려고 Calendar의 Meet 회의 코드를 읽는다는 것. 받는 필드(발화자 이름 · 발언 · 시각)는 지금 문장과 같다 |
| 3장 Google "저장하는 것" | 전사 본문 · 회의 제목 · 시각 · 참석자 | **(5b)** 같은 회의의 Notion 회의록에도 일정 제목 · 시각 · 참석자를 붙인다(`sources.meeting`) |
| 3장 Gmail "읽는 것" | "보내거나 받은 메일 스레드의 …", "수신 거부 머리글이 있거나 프로모션으로 분류된 메일은 거르고 저장하지 않습니다" | **(5a ✅)** G7 규칙을 줄여서: 프로모션 · 소셜 분류, 자동 발송 · 대량 발송 · 수신 거부 · 메일링 리스트 머리글(같은 회사 그룹 메일은 제외), no-reply 주소, 일정 초대. **거른 메일은 머리글만 읽고 본문을 받지 않는다.** 첫 동기화 14일 · 다시 연결하면 마지막 동기화부터(최대 30일). 문장별 근거 코드는 `docs/legal/README.md` 구현 대조표 Gmail 줄 |
| 3장 Gmail "저장하는 것" | "거르고 남은 스레드의 본문, 제목, 관련자, 날짜, 원본 링크" | **(5a ✅)** 스레드가 아니라 **메일 한 통씩**(G6), 본문 2만 자에서 자름 |
| 3장 Gmail "권한" | "`gmail.readonly`(메일 읽기)"만 | **(5a ✅)** 코드가 요청하는 `openid` · `email`(`GMAIL_SCOPES`)을 더한다: 연결 키 · 표시 주소 · "원문 속 나". 3장 Google "권한"도 같은 두 범위가 빠져 있다 → **(5b)** |
| 3장 연결 끊기 문단 | "Notion · Google에서 이미 가져온 원문과 할 일은 남습니다" | 그대로(G11) |
| 5장 표 | Google 줄 없음(원문 90일 규칙에 포함) | 그대로. 새 표가 없다 |
| 15장 Google user data | Limited Use 두 문장 · 전송은 기능 제공 · 동의 뒤에만 | 그대로. Workspace 정책의 전송 조건("사용자에게 보이는 기능을 위해, 동의를 받고")과 같다(9장) |

그 밖에:
- `docs/legal/README.md` 구현 대조표의 Google Calendar · Meet · Gmail · 토큰 폐기 줄을 구현 값으로 바꾼다. 법률 검토 항목에 "Google API 약관의 영구 사본 금지와 근거 인용 · 할 일 제목을 계정 삭제까지 두는 것"을 더한다(G11). **5a ✅**: Gmail 줄 · Gmail 토큰 폐기 · 법률 검토 10번. Calendar · Meet 줄 · google 연결 토큰 폐기는 5b.
- [google-verification.md](google-verification.md): 4장 범위 문안 — Meet(G2 시험 결과: "the user's meetings"의 범위), Calendar(같은 시각 · 같은 날의 일정, 참석한 Meet 회의 코드), **Gmail B**("stores the remaining threads" → 메일, "unsubscribe header or Promotions category" → G7 규칙과 같게, 같은 회사 그룹 메일은 남김). 6장 fixture 주최자, 1장 `calendar.events.owned.readonly` 확인 결과(초대받은 일정이 보이는지). **5a ✅**: Gmail B 문안(CASA 견적 요청 메일의 "email threads"도 같이). 나머지는 5b.
- 런북 2장 표의 `GOOGLE_REDIRECT_URI` · `GMAIL_REDIRECT_URI`("코드가 env로 받으면" → 받는다) · 여는 플래그 둘, 체크리스트 C4. **5a ✅**: `GMAIL_REDIRECT_URI`(코드가 env로 받음, `gmail/run.ts`) · `GMAIL_CONNECT_ENABLED` · C4에 Gmail 진행 상태. `GOOGLE_REDIRECT_URI` · `GOOGLE_CONNECT_ENABLED`는 google 연결이 읽게 된 PR 3에서 표에 넣었다 ✅ (2026-09-29, C4 상태 줄도 함께. 나머지 C4 마무리는 5b).
- [FEATURE_MAP.md](../FEATURE_MAP.md) 3-3 표에 Google · Gmail 줄, 5장 "새 연동을 붙이는 자리"에서 Google 예시. (Gmail 몫은 PR 2가 했다. Google 줄은 PR 3.)
- [INTEGRATIONS.md](../INTEGRATIONS.md) 다음 연동 표의 Gmail · Meet 줄(구현됨)과 "Google(Calendar · Gmail · Meet 전사를 연결 한 번으로)" 문장. **5a ✅**: Gmail 줄(구현됨) · 그 문장(연결은 둘) · Calendar 줄 분리. Meet 줄은 5b.
- [GO_LIVE.md](../GO_LIVE.md) 머리 표 · 6장의 "Google 연결 한 번으로"(연결은 `google` · `gmail` 둘이다, google-verification.md 1장) · Gmail "스레드"(G6). **5a ✅** (`app-store.md` App Privacy 표의 "Gmail 스레드"도 "Gmail 메일"로).

## 6. 순서 (한 세션 = 한 PR)

| PR | 내용 | 끝난 기준 | 기간 |
|---|---|---|---|
| 0 | 이 계획 문서 | 1장 결정 | — |
| 1 | 골든셋(4장 표) + 지금 파이프라인으로 기준 점수, G12 비교 | `npm run eval` 기록에 Gmail · Meet 줄. 파이프라인 코드 변경 없음 | 1~2일 |
| 1b | 파이프라인 보완(4장 "기준 점수" E1~E5: 인용 속 구절 버리기 · 수락이 확인 요청을 풀기 · G12 규칙) + G13 실제 원문 | Gmail · Meet 병합 정확도 100%, 함정 자동 반영 0, 위 표의 "확인 요청 없음" 케이스에 확인 요청이 남지 않음, 전체 eval에서 회의록 · Slack 숫자가 떨어지지 않음 | 1~2일 |
| 2 | Google OAuth 공통 + **Gmail** 연결 · 거르기 · 넣기 · `reauth` · 폐기 + `loadIdentity` 주소 + callback · lab 시작 + 여는 플래그 | 단위 테스트. dev 프로젝트로: 연결 → 동기화 → fixture 1 · 5가 할 일 · 기한 갱신으로, 뉴스레터는 DB에 없음, 권한을 거두면 다음 동기화에서 `reauth` · **dev 확인 2026-09-29** (8장 · 9장 "PR 2 dev에서 확인") | 3일 |
| 3 | **google** 연결: Calendar 조회 · 회의 잇기 · Meet 전사 넣기 + Notion 회의록에 일정 붙이기(`enrich`) + `sources.meeting` 마이그레이션 | 단위 · DB 테스트. dev Workspace로: Meet 회의 → 전사가 발화자 이름표와 함께 원문으로, 같은 회의 Notion 회의록에 참석자 · 일정, 둘이 할 일 하나로 · **코드 · 단위 · DB 테스트 ✅ 2026-09-29, dev 회의 확인은 대기** (사용자가 시험 회의 둘을 녹음한 뒤, 9장 "PR 3 dev에서 확인할 것"). 확인 안 된 가정 넷은 `google/unverified.ts` 한 파일에 모아 두어 결과가 다르면 한 줄만 바꾼다 | 3~4일 |
| 4 | 재연결 알림(G9) + 앱: Gmail 연결 전 안내 · Meet 줄 · 알림 눌러 연결 화면 · 근거 줄 일정 제목 · Sources 한 회의 묶기 | `swift test` · iOS · macOS 빌드. 시뮬레이터에서 Gmail 확인 창 · `reauth` 줄 · 알림 | 2일 |
| 5a | **Gmail** 처리방침 · 문서 맞추기(5장의 Gmail 몫). 문서만 · PR 3과 상관없이 먼저 · 2026-09-29 작성 | 처리방침 3장 Gmail 문장(한국어 · 영어)이 구현과 같고 문장마다 근거 코드가 `docs/legal/README.md` 대조표에 있음, 심사 문안 · 런북 · INTEGRATIONS · GO_LIVE가 같음. **남은 것은 사용자:** 웹사이트 재게시(시행일 · 버전을 정하고 17장대로 고지. 재연결 알림 문장이 코드보다 앞선 채로 나가므로 게시 규칙 2의 예외이고, `docs/legal/README.md` "게시 대기"에 적었다), 그 뒤 PR 4(재연결 알림 · Gmail 확인 창)가 나가면 `GMAIL_CONNECT_ENABLED` | 0.5일 |
| 5b | **Calendar · Meet** 처리방침 · 문서 맞추기(5장의 Google 몫) + 전체 검증 + 런북 C4 마무리. PR 3 뒤 | 8장 전부. 운영에서만 확인할 수 있는 칸은 go live 순서에서 | 0.5일 |

PR 2(Gmail)를 먼저 하는 이유: 프로젝트 B는 Testing이라 콘솔 설정 뒤 바로 쓸 수 있고(L5), 7일 만료(`reauth`)를 가장 먼저 겪는 연결이다. Meet은 Workspace 요금제 · 회의 녹음 fixture가 필요해 준비가 더 걸린다.
**PR 2는 #16 · #17(Notion `reauth` · 토큰 창구 401)이 `main`에 병합된 뒤 시작한다**(`recordSync(…, { reauth: true })`를 쓴다). 두 PR은 #12(피처맵) → #14 위에 쌓여 있어 넷이 차례로 병합돼야 한다. PR 1(골든셋)은 기다리지 않는다.

## 7. 사용자가 먼저 할 일

| # | 할 일 | 언제까지 | 비고 |
|---|---|---|---|
| U1 | 1장 결정 (G1 · G2 · G11은 확인 결과와 함께 묻는다) | PR 1 전 | |
| U2 | **Taskforce dev** Google 프로젝트: Testing, 테스트 사용자에 시험 계정 둘, redirect `http://localhost:3000/api/connectors/{google,gmail}/callback`. **운영처럼 둘로 나누기를 권장한다**: dev A(Calendar API · Meet REST API, `openid` · `email` · Calendar · Meet 범위, redirect `…/google/callback`) → `.env.local`의 `GOOGLE_*`, dev B(Gmail API, `openid` · `email` · `gmail.readonly`, redirect `…/gmail/callback`) → `GMAIL_*`. 토큰 폐기는 **프로젝트 단위**로 모든 범위를 거두므로(9장), 한 프로젝트에 둘을 두면 Gmail을 끊을 때 `google` 연결도 끊겨 끊기 · 폐기 시험이 틀린다. 하나로 한다면 폐기 시험을 따로 한다. client secret은 사용자가 `.env.local`에 **직접** 넣는다 | PR 2 전(dev B), PR 3 전(dev A) | [google-verification.md](google-verification.md) 9장 10번. 콘솔 설정은 이 세션이 하지 않는다 |
| U3 | 시험 계정 둘: Meet 전사가 되는 Workspace(Business Standard 이상, taskforcelabs.dev) 계정 하나(나)와 두 번째 계정(상대). Meet 회의 **둘**을 실제로 전사한다: 내가 주최한 회의 하나, **상대가 주최하고 내가 참석한** 회의 하나(G2 ②). 메일 fixture를 주고받는다 | PR 3 전(메일은 PR 2 전) | 심사 fixture(google-verification.md 6장)와 같은 계정 · 데이터를 쓰면 두 번 만들지 않는다. 같은 회사 · 다른 회사 상대가 모두 되면 더 좋다 |
| U4 | G13 실제 원문 고르기(본인 Gmail 스레드 · Meet 전사 각 5건, Meet 전사가 없으면 Notion AI 회의록 + 일정 참석자) | PR 1b 전 | 익명화는 로컬에서, 원문은 커밋하지 않는다 |
| U5 | 운영 마이그레이션 적용 승인(`sources.meeting`) · Vercel env(`GOOGLE_*` · `GMAIL_*` · 여는 플래그) | PR 3 · 5 뒤 | 운영 DB · env는 매번 확인받는다 |

## 8. 끝난 기준 (체크리스트 C4)

- [ ] `npm run lint && npm run typecheck && npm run test && npm run eval` 통과, Gmail · Meet 골든셋 숫자가 README 기록 표에 있음 (PR 1 · 5)
- [x] dev: Gmail 연결 → 답장 속 약속이 할 일로, 상대의 "Wednesday works too"가 **새 할 일 없이** 기한 갱신, 링크가 그 스레드를 연다 (PR 2, 2026-09-29. 기한은 10/7로 갱신됐지만 요청 메일이 만든 확인 요청이 남았다 → 9장, PR 1b)
- [x] dev: 뉴스레터 · 프로모션 · no-reply 메일은 `sources`에 없고, 본문을 받지 않았다(요청 기록) (PR 2, 2026-09-29: 머리글 14통 중 거른 8통(자동 발송 4 · no-reply 3 · 대량 1)에 `format=full` 요청 0건. dev 메일함에는 프로모션 분류가 없었다)
- [ ] `invalid_grant` → `reauth`: 단위 테스트 + dev에서 Google 계정의 접근 권한을 거둔 뒤 다음 동기화가 `reauth`, 앱에 "Reconnect to keep syncing", 알림 한 번, 다시 연결하면 끊긴 동안의 메일이 들어옴 (PR 2 · 4. **PR 2 몫 확인 2026-09-29**: 저장된 갱신 토큰을 Google 폐기 API로 거둔 뒤 다음 동기화가 `reauth` + "Gmail 연결이 만료됐습니다. 다시 연결해 주세요.", 같은 계정으로 다시 연결하면 같은 연결 행이 `active` · 커서 유지 · 다음 동기화가 커서부터 이어 감. 끊긴 동안 온 메일은 없어 실제 메일로는 보지 못했다(단위 테스트). 앱 문구 · 알림은 PR 4)
- [ ] dev: Meet 전사가 발화자 이름표와 함께 원문으로(사용자 줄은 프로필 이름), 같은 회의의 Notion 회의록에 일정 참석자, 둘이 담당 "나"인 할 일 하나 (PR 3. **코드 · 단위 테스트 ✅ 2026-09-29**: 골든셋 Meet 소스 7개와 글자까지 같은 본문(사용자 줄 = 프로필 이름 · 이어진 항목 합치기), 일정 붙이기 · Notion 관련자 합치기. **dev 확인 대기** — 9장 "PR 3 dev에서 확인할 것" 1~4번을 먼저 본다)
- [ ] dev: 상대가 주최한 회의의 전사를 가져오는지(G2 ②) 결과를 이 문서 9장에 적고, 처리방침 3장 · 앱 Meet 줄을 그 결과대로 (PR 3 · 5. 두 길은 구현했다(`unverified.ts` `LIST_ATTENDED_MEETINGS`). **dev 확인 대기**, 9장 "PR 3 dev에서 확인할 것" 1번)
- [ ] 1주 사용에서 볼 숫자(원칙 6): Notion 회의록 중 일정이 붙은 비율 · 같은 일정에 Meet 전사도 있는 비율은 `sources`(`meeting`)로 센다. 거른 메일은 원문이 남지 않고 Vercel 로그는 1일이라, 동기화마다 **이유 코드별 개수**(넣음 · 규칙 ①~⑧) · Meet 전사 수 · 일정 잇기 결과(붙음 · 애매 · 없음)를 연결 설정 `settings.stats`에 누적한다(글자 · 주소 없이). `/admin/metrics`에서 본다 (PR 2 · 3. Gmail 몫은 PR 2: `stats.counts` · "Gmail 거르기" 카드. **google 몫 PR 3 ✅ 2026-09-29**: `stats.counts`에 전사 수 · 일정 잇기 결과(2-5 끝 "통계 키") + "Google 회의" 카드(`googleActivity` · `meetingLinkage`, 순수 함수 단위 테스트). 1주 사용 숫자는 운영 뒤)
- [x] 첫 동기화(14일) · 다시 연결 뒤 이어 가져오기가 확인 요청 알림을 원문마다 보내지 않음 (PR 2, 2-2 `ingestDeps`: `connected_at` 전 시각의 원문은 `notify: false`. 단위 테스트)
- [ ] 앱이 요청하는 범위가 처리방침 3장 목록 · google-verification.md 1장과 같고, 3장 Google · Gmail 문장(거르기 · 저장 · 첫 동기화 · 재연결)이 구현과 같음 (PR 5, 한국어 · 영어). **Gmail 몫 ✅ (PR 5a, 2026-09-29):** 범위 `openid` · `email` · `gmail.readonly`(`GMAIL_SCOPES`)가 3장(`openid` · `email`을 5a에서 더함) · 심사 문안 · google-verification.md 1장과 같고, 거르기 · 머리글만 읽기 · 메일 한 통씩 저장 · 본문 2만 자 · 첫 14일 · 재연결 30일이 구현과 같음(문장별 근거는 `docs/legal/README.md` 대조표). 웹사이트 재게시는 아직(`docs/legal/README.md` "게시 대기"). **Google(Calendar · Meet) 몫은 PR 5b**
- [x] Calendar 요청의 `fields`에 설명 · 첨부가 없음(테스트), 일정은 원문으로 저장되지 않음 (PR 3, 2026-09-29: `google/calendar.test.ts`가 실제 요청 주소의 `fields`에 `description` · `attachments` · `location` · `htmlLink` · `hangoutLink` · `entryPoints` · `extendedProperties` · `creator`가 없고 계획 2-4의 문자열과 같음을 확인. 일정 자체는 어디에도 저장하지 않는다: 저장하는 것은 고른 일정 하나의 `{ calendar_event_id, title, start, end }`뿐(`sources.meeting`)이고, 새 표가 없다 — `tests/db/migrations.test.ts`의 표 목록 그대로)
- [ ] 앱에서 연결 끊기 · 계정 삭제 → Google 계정의 "타사 앱" 목록에서 Taskforce가 사라짐(토큰 폐기) (PR 2 · 3. PR 2 dev: `DELETE /api/v1/connections/:id` 204, 폐기 실패 로그 없음, 연결 행 삭제, Gmail 원문 10건은 `connection_id`만 비워져 남음(G11). **PR 3 코드 ✅ 2026-09-29**: `googleConnector.revokeToken`(갱신 토큰으로 폐기, 이미 폐기된 400 `invalid_token`은 성공, 500은 던져도 끊기 계속) 단위 테스트, 연결 틀 `tokenRevokerFor("google")`가 연결 끊기 · 계정 삭제(`revokeConnectorTokens`)에 이어짐, `tests/db/sources-meeting.test.ts`가 연결을 끊어도 원문 · 일정이 남고(G11) 계정 삭제로 지워짐을 확인. google dev 확인은 대기)
- [ ] Vercel 로그에 메일 본문 · 전사 · 토큰 · code 없음 (운영 배포 뒤)

## 9. 위험과 확인한 사실 (2026-09-29)

Google 공식 문서(대부분 2026-04 ~ 2026-09 갱신)의 원문으로 확인했다. "확인 못 함"은 문서에 없거나 서로 다른 것이라 dev에서 시험한다.

| 항목 | 확인한 것 | 대응 |
|---|---|---|
| Meet 회의 기록 목록 | **서로 다르다.** 가이드: "The list method only returns conferences where you're the meeting organizer." 같은 쪽: "If you're a meeting space owner or participant, you can call the get and list methods". 릴리스 노트(2025-02-07): "All meeting participants can now query for certain conference data including the conference records" | G2: 두 길을 만들고 dev에서 두 계정으로 시험(PR 3). **두 길 구현 ✅ 2026-09-29, dev 확인 대기** (아래 "PR 3 dev에서 확인할 것" 1번, 바꿀 곳 `unverified.ts` `LIST_ATTENDED_MEETINGS`) |
| Meet 전사 30일 | "Transcript entry data is available for 30 days after the conference ends." 전사 항목은 생성 뒤 문서를 고쳐도 바뀌지 않는다 | 커서를 29일 안으로(2-5). 동기화가 한 달 넘게 멈추면 그 회의는 잃는다 |
| Meet 전사 상태 | `STARTED` · `ENDED`("파일은 아직") · `FILE_GENERATED`. 파일 생성까지 걸리는 시간은 정해져 있지 않다("usually ready … soon after a conference ends", "longer meetings take longer") | `FILE_GENERATED`만, 2시간 넘게 `ENDED`면 항목으로(2-5) |
| Meet 참가자 → 사용자 | `signedinUser.user`: "Unique ID for the user. Interoperable with Admin SDK API and People API. Format: users/{user}". OIDC `sub`와 같은 값이라는 문장은 **없다**. 이메일은 참가자에 없다 | G5: PR 3 첫 작업으로 확인, 다르면 `profile` 범위 + 이름 비교. **1차 규칙(id 비교) 구현 ✅ 2026-09-29, 확인 대기** (2번, `unverified.ts` `isConnectedAccount`; `profile` 범위는 확인 뒤에 더한다) |
| Meet 범위 | `list` · `entries.list`는 `meetings.space.created` 또는 `meetings.space.readonly`. `meetings.space.readonly`는 **민감**, `.created`는 "앱이 만든 공간의 회의만". `drive.readonly` · `drive.meet.readonly`는 **제한** | G1 |
| Meet 요금제 · 언어 | 전사: Business Standard · Business Plus · Enterprise · Education Plus 등. **한국어 지원**("English French German Italian Japanese Korean Portuguese Spanish"), 컴퓨터 · Android에서만 켤 수 있다 | fixture 계정은 Business Standard(google-verification.md 2-3). 한국어 골든셋 |
| Meet 한도 | 읽기 사용자당 분당 600 · 프로젝트 분당 6,000, 넘으면 429. "later in 2026" 과금 예정 | 한 동기화 안에서 넘지 않는다. 과금 공지를 본다 |
| Meet 코드 ↔ 일정 | Calendar `conferenceId`: "the 10-letter meeting code, for example aaa-bbbb-ccc". Meet `meetingCode`와 같다는 문장은 없다. Meet: 코드는 공간과 떨어질 수 있고 보통 마지막 사용 뒤 365일에 만료, `spaces.get`은 `spaces/{meetingCode}`를 받는다 | 2-4 · 2-5, PR 3에서 확인. **구현 ✅ 2026-09-29, 확인 대기** (3번, `unverified.ts` `sameMeetingCode`) |
| 전사 문서의 공유 | "Meeting transcripts are saved in the meeting organizer's Google Drive", 일정 첨부로 "All invitees in the host's organization can open the attachment"(초대자 200명 넘으면 주최자 등만). Docs API `documents.readonly`는 **민감** | G1의 다른 선택. 원본 링크가 다른 회사 참석자에게는 안 열릴 수 있다 |
| 사용자 회사의 회의 습관 | 사용자 회사는 주최자가 섞여 있고 **대부분 Notion 전사만 켠다**(2026-09-29 사용자 확인) | Meet 전사가 있는 회의에서만 발화자로 담당을 정한다. 런북 G3 테스터 안내에 "담당을 정확히 하려면 Meet 전사도 켜기"를 한 줄. 비율을 잰다(8장) |
| Calendar 범위 | `calendar.events.owned.readonly`: "See the events on Google calendars you own", `events.list`에 쓸 수 있다. **남이 보낸 초대가 포함되는지는 문서에 없다**(참석자 `self`가 "이 사본이 있는 캘린더"라는 설명으로 보아 기본 캘린더의 초대 사본이 보일 것으로 추정). 민감 등급은 범위 표에 적혀 있지 않다(심사 문서는 "캘린더 일정 읽기"를 민감 예로 든다) | PR 3 dev: 상대가 보낸 초대가 보이는지. 안 보이면 google-verification.md 1장 결정대로 `events.readonly`로 바꾸고 심사 문안 · 처리방침 권한 이름을 함께 고친다. **구현 ✅ 2026-09-29, 확인 대기** (4번, `unverified.ts` `CALENDAR_EVENTS_SCOPE`) |
| Calendar 필드 | `attendees[].email` · `displayName`은 "if available". `eventType`: `default` · `focusTime` · `outOfOffice` · `workingLocation` · `birthday` · `fromGmail` | 2-4 거르기. 이름 없는 참석자는 이메일로 |
| Gmail 범위 · CASA | `gmail.readonly`는 제한. "If you store restricted scope data on servers (or transmit), then you must go through a security assessment." | google-verification.md 7장 그대로 |
| Gmail 머리글만 읽기 | `format=metadata`: "Returns only email message IDs, labels, and email headers." `metadataHeaders`로 고른 머리글만 | 2-6(거른 메일은 본문을 받지 않는다) |
| Gmail 쿼터 | `messages.list` 5 · `messages.get` 20 · `threads.get` 40 · `history.list` 2 단위, 사용자당 분당 6,000 | 2-6 한도 |
| Gmail history | "typically valid for at least a week, but in some rare circumstances may be valid for only a few hours", 만료면 404 → 전체 동기화 | history를 쓰지 않고 시각 커서(G8) |
| Gmail 링크 | Gmail API 문서에 스레드 주소 형식이 **없다**(공식은 Apps Script `getPermalink()`뿐) | `https://mail.google.com/mail/?authuser={연결한 주소}#all/{threadId}`가 그 스레드를 연다(PR 2 dev, 2026-09-29) |
| Gmail 검색 시각 | "All dates used in the search query are interpreted as midnight on that date in the PST timezone. To specify accurate dates for other timezones pass the value in seconds instead." (Gmail 검색 안내) | `after:` · `before:`에 epoch 초(2-6) |
| Gmail 분류 | `CATEGORY_PROMOTIONS` 등은 Gmail 탭과 같다("Corresponds to messages that are displayed in the Promotions tab") | G7 |
| `invalid_grant` | "The user has revoked your app's access", "has not been used for six months", "changed passwords and the refresh token contains Gmail scopes", 계정당 갱신 토큰 한도 초과, Testing 상태의 7일 만료. 웹 서버 안내: "Authenticate the user again" | 2-3: 모두 `reauth` |
| 갱신 토큰 한도 | "a limit of 100 refresh tokens per Google Account per OAuth 2.0 client ID", 넘으면 가장 오래된 것이 경고 없이 무효 | `prompt=consent`로 다시 연결할 때마다 새로 받는다. 7일마다 다시 연결해도 쓰는 것은 가장 새것 하나라 문제없다 |
| 폐기 | `POST https://oauth2.googleapis.com/revoke`, `token`은 access · refresh 모두 가능, "Revocation removes all OAuth 2.0 scopes previously granted to a project" | 2-3 |
| 부분 허용 | "Your app should always check which scopes were granted by the user and handle any denial of scopes by disabling relevant features." 토큰 응답의 `scope` | G10 |
| `id_token` | 토큰 창구에서 직접 받으면 "you can be confident that the token you receive really comes from Google and is valid". "Use sub within your application as the unique-identifier key for the user." | 2-3: 서명 확인 없이 `sub` · `email`만, 연결 키는 `sub` |
| 액세스 토큰 수명 | `expires_in`(초)만 있고 고정 값은 문서에 없다 | `expires_at = 받은 시각 + expires_in` |
| AI 전송 | Workspace 사용자 데이터 정책(2026-09-03): 전송은 "To provide or improve your appropriate use case or user-facing features" 등 예외만, 사용자에게 보이는 기능 · 동의 조건. 일반 AI 모델 학습 금지. 승인된 쓰임 예: Gmail "generative AI summaries", Meet "meeting or speaking insights" | 지금 처리방침 4 · 15장 · 앱 동의로 맞다. 외부 AI 공급자를 하위 처리자로 쓰는 것에 대한 명시 문장은 없다 → L9 검토 항목(legal README 7번)에 이미 있음 |
| 삭제 | "Honor user requests to delete their data", 이용자가 지우는 방법을 안내하라. 끊으면 지우라는 규칙 · 기한은 찾지 못했다. 같은 쪽에 Google 약관의 "creating permanent copies of Google User data" 금지가 인용된다 | G11. L9에 더함 |

### PR 2 dev에서 확인 (2026-09-29, dev 프로젝트 B · Workspace 메일함 daniel@taskforcelabs.dev)

| 항목 | 확인한 것 | 대응 |
|---|---|---|
| Gmail API 켜기 | OAuth client가 속한 프로젝트에 Gmail API가 꺼져 있으면 모든 요청이 `403 accessNotConfigured`(동기화는 `error` "Gmail 요청 실패 (403)") | 운영 프로젝트 B에서도 Gmail API가 켜져 있는지 go live 때 확인(런북 C4) |
| 빈 목록 | 결과가 없는 창의 `messages.list`는 `fields`가 모든 필드를 걸러 **204 본문 없음** | 빈 목록으로 읽는다(`gmail/client.ts`) |
| 받은 범위 문자열 | callback · 토큰 응답의 `scope`에 `email`과 `…/userinfo.email`이 함께 온다 | 짧은 이름을 긴 이름으로 맞춰 비교(`grantedScopes`) |
| Workspace 메일함 분류 | dev Workspace 메일함에는 `CATEGORY_*` 라벨이 없었다(탭 없음). 규칙 ④는 개인 Gmail에서만 걸린다 | 머리글 규칙(②⑤⑥⑦)이 대신 거른다 |
| Google 시스템 메일 | `workspace-noreply@` · `notify-noreply@` · `platformnotifications-noreply@google.com`: 자동 발송 머리글이 없고 no-reply가 주소 **가운데**에 있다 | 규칙 ⑦을 "구분자 뒤의 no-reply 낱말"까지 넓혔다 |
| 권한 거둠 | 저장된 갱신 토큰을 폐기 API로 거둔 뒤 API는 401, 갱신은 `invalid_grant` → `reauth` | 2-3 그대로 |
| 늦게 목록에 나오는 메일 | 스팸 · 휴지통에서 되돌린 메일, 프로모션에서 옮긴 메일처럼 받은 시각(`internalDate`)이 `after − 1시간`보다 앞인데 나중에 목록에 나오는 메일은 가져오지 않는다(시각 커서의 한계, 검토에서 확인) | 베타에서는 두고, 누락 신고로 들어오면 본다 |
| **파이프라인 (PR 1b, 4장 "기준 점수"와 같은 것)** | 실제 메일에서도 골든셋과 같은 것이 났다. ① 연장 메일("Wednesday, Oct 7 works too")에서 인용된 "Sure, I'll send it by Monday"가 기한 10/5 후보로 **자동 반영**됐다(최종 기한은 규칙 4로 10/7) = **E2**. ② 혼자 받은 요청 메일이 만든 확인 요청이 내 수락 답장 뒤에도 남았다 = **E3**. 더해서 본 것: 한 스레드의 세 통이 같은 동기화에 들어오면 `ingestItems`가 3개씩 동시에 처리해 보낸 순서대로 병합되지 않는다(골든셋 시퀀스는 차례로 넣는다). ③ 인용이 붙은 메일의 추출이 90초 초과 · `finish_reason: length`로 실패했다 = **E6**. 보낸 사람 표시 이름이 사용자 이름과 같고 주소만 다를 때(두 시험 계정이 모두 "Daniel Song") 매번 실패했고, 이름을 다르게 하면 35초에 끝났다. `failed` 원문은 `scripts/reprocess-sources.ts --source`로 다시 처리된다(연결한 Google 주소를 쓰도록 이 PR에서 고쳤다) | E2 · E3 · E6 고침과 함께: 같은 스레드의 메일을 보낸 순서대로 병합할지, `isUser`가 주소가 다른 사람을 이름으로 사용자로 보는 규칙 |

### PR 3에서 문서로 확인한 것 (2026-09-29, Meet REST API v2 레퍼런스)

| 항목 | 확인한 것 | 코드 |
|---|---|---|
| 회의 기록 목록 조건 | `filter`로 걸 수 있는 필드는 `space.meeting_code` · `space.name` · `start_time` · `end_time`. 예: `space.meeting_code = "abc-mnop-xyz"`, `start_time>="2024-01-01T00:00:00.000Z" AND start_time<="…"`, `end_time IS NULL`. 쪽 크기 최대 100(기본 25) | `sync.ts`: ① `end_time>="{커서}"`, ② `space.meeting_code = "{코드}" AND start_time>="{일정 시작 − 1일}"` |
| 전사 · 항목 · 참가자 목록 | 전사 쪽 크기 최대 100(기본 10), 항목 최대 100(기본 10, **시작 시각 오름차순**), 참가자 최대 250(기본 100). 항목 한 건의 글은 최대 1만 단어. 세 목록 모두 범위 `meetings.space.readonly`로 된다 | `meet.ts` (100씩 끝까지, 항목은 받은 뒤에도 시작 순으로 정렬) |
| 전사 문서 | `docsDestination.document`(문서 id) · `exportUri` | `transcript.ts`: `https://docs.google.com/document/d/{id}/view` |
| 참가자 종류 | `signedinUser`(`user` = `users/{user}` + `displayName`) · `anonymousUser`(`displayName`) · `phoneUser`(`displayName` = 일부 가려진 전화번호) 중 하나 | `meet.ts` `MeetParticipant.kind` |
| 회의 공간 | `spaces.get`은 `spaces/{space}`(서버가 준 id) 또는 `spaces/{meetingCode}`(대소문자 무시)를 받고, 범위 `meetings.space.readonly`로 된다. 응답에 `meetingCode` · `meetingUri` | `meet.ts` `meetingCode` (403 · 404면 null) |

### PR 3 dev에서 확인할 것 (사용자가 시험 회의 둘을 녹음한 뒤)

**왜 남았나.** PR 3은 코드 · 단위 테스트 · DB 테스트까지 끝냈고(2026-09-29), 아래 넷은 Google 문서에 없거나 문서끼리 달라 dev 회의로만 답이 나온다. 넷 모두 `src/lib/connectors/google/unverified.ts`에 이름 붙은 상수 · 함수 하나로 모아 두었으므로, 결과가 다르면 그 자리 한 줄만 바꾼다(다른 코드는 이 파일을 거쳐서만 가정을 쓴다). 지금 값은 계획대로다(G5는 1차 규칙만, `profile` 범위는 더하지 않았다).

**준비 (7장 U2 · U3).**
- dev 프로젝트 A(Testing): Calendar API · Google Meet REST API 켜기, `.env.local`에 `GOOGLE_CLIENT_ID` · `GOOGLE_CLIENT_SECRET` · `GOOGLE_REDIRECT_URI=http://localhost:3000/api/connectors/google/callback`. 콘솔 설정은 사용자가 한다.
- 확인에 쓰는 DB에 `supabase/migrations/20261016000000_sources_meeting.sql` 적용(`npx supabase db query --linked -f …`, `db push` 금지). **먼저 `--linked`가 가리키는 프로젝트가 dev 확인에 쓰는 DB인지 확인한다** — 운영 프로젝트와 같다면 이 적용은 운영 DB 적용이므로 U5의 승인 절차를 따른다. 이 PR은 어느 DB에도 적용하지 않았다.
- 시험 계정 둘(Workspace Business Standard 이상): **나(A)** · **상대(B)**. Calendar 일정에서 Meet 링크를 만들어 회의를 잡는다. B의 Meet 표시 이름이 A의 **프로필 이름 · 별칭**과 같으면(PR 2 dev처럼 둘 다 "Daniel Song"이고 프로필 이름이나 별칭이 그것이면) B의 줄이 `Daniel Song (2)`로 나온다 — 정상이다(A를 참가자에서 찾았을 때만 별칭까지 막는다). 구분하려면 B의 표시 이름을 바꾼다.
- 회의 **M1**: A가 주최, B 초대, 전사 켬. A가 "I'll send the revised proposal to B by Friday." 같은 약속을 말한다. 회의 **M2**: **B가 주최, A가 초대받아 참석**, B가 전사를 켠다(A는 전사 권한이 없는 것이 정상). 두 회의가 끝나고 전사 파일이 생길 때까지 몇 분 기다린다. 가능하면 M1과 같은 시간에 A의 Notion AI 회의록도 만든다(4-b).
- A로 `/lab` → "Google 연결" → 네 범위 모두 허용 → 연결 결과 `connected`. 그다음 "지금 동기화". 결과는 DB `connections.settings.stats.counts`(A의 google 연결)와 `/admin/metrics` "Google 회의" 카드에서 본다.

| # | 확인할 것 | 어떻게 | 결과가 이러면 → 바꿀 곳 |
|---|---|---|---|
| 1 | **G2 ②: 참석한(남이 주최한) 회의의 전사가 오는가** | 동기화 뒤 `counts`를 본다. `meet_attended_codes` ≥ 1(M2의 회의 코드를 조회했다)이고 (a) `meet_transcripts_attended` = 1 → ② 길이 M2를 찾았다. (b) `meet_transcripts` = 2인데 `meet_transcripts_attended` = 0 · `meet_attended_denied` = 0 → ① 목록이 참석한 회의도 이미 돌려준다(② 없이도 됨). (c) `meet_transcripts` = 1 · `meet_attended_denied` ≥ 1 → 참석자에게는 회의 기록 목록을 주지 않는다(403). (d) 둘 다 0인데 조회만 있음 → 빈 목록. (e) M2의 회의 기록은 나오는데(①이 돌려주거나 ②가 찾음) `meet_artifacts_denied` ≥ 1이고 M2 전사가 없음 → 참가자에게 **기록은 주지만 전사 자료(전사 목록 · 항목)는 주지 않는다**(403). 이때도 동기화는 실패하지 않고 M1은 정상으로 들어와야 한다 | (a) 그대로 두고 처리방침 3장 · 앱 Meet 줄을 "주최하거나 참석한 회의"로. (b) 그대로 두어도 되고 `LIST_ATTENDED_MEETINGS = false`로 요청을 줄여도 된다(문구는 (a)와 같다). **(c) · (d) · (e) → `unverified.ts`의 `LIST_ATTENDED_MEETINGS = false`**((e)는 ①이 돌려주는 참석한 회의 기록에도 같은 결과이므로, 처리방침 3장 · 앱 Meet 줄을 "내가 주최한 회의"로 적는 데서 끝난다. 코드는 볼 수 없는 전사를 매번 건너뛸 뿐이라 끄지 않아도 동작한다) + 처리방침 3장 · 앱 Meet 줄(`Connections.swift` `readsBeforeConnecting`)을 "내가 주최한 회의"로, google-verification.md 4장 Meet 문안 · 6장 fixture 주최자를 함께. Google API Explorer의 `conferenceRecords.list`(범위 `meetings.space.readonly`)를 B 계정으로 불러 직접 확인해도 된다 |
| 2 | **G5: `signedinUser.user`(`users/{id}`)가 OIDC `sub`와 같은가** | M1 전사 원문(`sources.raw_text`, 외부 id `conferenceRecords/…`)을 본다. A의 줄이 **Taskforce 프로필 이름**으로 적히고 관련자에 A가 한 번만(프로필 이름 + 연결한 주소) 있으면 같다. A의 줄이 Meet 표시 이름으로 남고 관련자에 A가 둘(프로필 이름 · Meet 이름)이면 다르다. 확인은 API Explorer `participants.list`의 `signedinUser.user` 값과 `connections.external_account_id`(= `sub`)를 나란히 본다 | 다르면 `unverified.ts`의 `isConnectedAccount`를 바꾼다: 계획의 대안은 범위 `profile`(비민감)을 더해 `id_token`의 계정 이름을 Meet 표시 이름과 비교하는 것이다(`google/run.ts` `GOOGLE_SCOPES` + `oauth.ts` `idTokenAccount`가 이름을 읽도록 + google-verification.md 1장 범위 표 · 처리방침 3장 권한 목록). **지금은 범위를 더하지 않았다** |
| 3 | **Calendar `conferenceId` = Meet `meetingCode`인가** | M1 · M2 동기화 뒤 `meet_link_attached` = 2(일정이 붙음)이고 `sources.meeting`에 일정 제목 · 시각이 있으면 같다. `meet_link_none`이 나오면(Meet 링크가 있는 일정인데) 다르다. API Explorer로 `spaces.get`의 `meetingCode`와 Calendar `events.get`의 `conferenceData.conferenceId`를 비교 | 다르면 `unverified.ts`의 `sameMeetingCode`를 바꾼다(지금은 대소문자 · 하이픈을 무시하고 비교). 코드가 아예 다른 값이면 `meetingUri`로 일정의 화상 회의 주소와 비교하는 길이 있다(Calendar `fields`에 `hangoutLink`가 필요해지므로 처리방침 3장 "읽는 것"을 함께 확인) |
| 4 | **`calendar.events.owned.readonly`로 남이 보낸 초대가 보이는가** | (a) M2(B가 주최, A가 초대받음)의 Calendar 일정이 A의 기본 캘린더에 있고, 동기화 뒤 M2 전사에 `meet_link_attached`가 잡히거나(3번과 함께) `meet_attended_codes`가 1 이상이면 초대가 보인다. `meet_link_none` · `meet_attended_codes` = 0이면 안 보인다. (b) Notion 쪽: 같은 회의의 Notion AI 회의록을 만들고(M1 또는 M2 시간에) 동기화 → `sources.meeting`이 붙고 관련자에 일정 참석자가 들어오는지 | 초대가 안 보이면 `unverified.ts`의 `CALENDAR_EVENTS_SCOPE`를 `https://www.googleapis.com/auth/calendar.events.readonly`로 바꾸고, 심사 문안(google-verification.md 1장 결정 · 4장) · 처리방침 3장 권한 이름 · Google 콘솔(프로젝트 A · dev)의 범위를 함께 고친 뒤 다시 연결 |

**함께 볼 것 (PR 3 끝난 기준, 8장).**
- (a) M1: 전사가 발화자 이름표로 원문이 되고 사용자 줄이 프로필 이름이며, 같은 회의 A의 Notion 회의록에 일정 참석자가 붙어 **할 일 하나**(담당 나, 확인 요청 없음)가 된다 — 골든셋 `seq-meet-after-notion` · `seq-notion-after-meet`을 실제로 (E4 고침 전이면 Notion 쪽 판정 확인이 남을 수 있다, 4장 "기준 점수").
- (b) 일정 없는 즉석 회의(Calendar 일정 없이 Meet 링크만)의 전사: 제목이 `Google Meet · 2026-…`, `meet_link_none`.
- (c) 연결 화면에서 Calendar 또는 Meet 체크를 하나 빼고 허용: 결과 `connected_partial`, `settings.scopes`가 받은 범위만, 동기화가 받은 쪽만 한다. 둘 다 빼면 `missing_scope`이고 Google 계정의 "타사 앱"에 남지 않는다.
- (d) 연결 끊기 · 계정 삭제 뒤 Google 계정의 "타사 앱" 목록에서 Taskforce가 사라지는지, 원문 · 일정은 남는지(G11).
- 결과는 이 표 아래에 날짜와 함께 적고, 처리방침 3장 · 앱 Meet 줄(PR 4 · 5)을 그대로 맞춘다. 8장의 해당 칸도 체크한다.

### 출처

- Meet 회의 기록: <https://developers.google.com/workspace/meet/api/guides/conferences> · 목록 API: <https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords/list> · 릴리스 노트(2025-02-07): <https://developers.google.com/workspace/meet/release-notes>
- Meet 전사 · 30일: <https://developers.google.com/workspace/meet/api/guides/artifacts> · 전사 상태: <https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords.transcripts> · 전사 항목: <https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords.transcripts.entries/list>
- Meet 참가자: <https://developers.google.com/workspace/meet/api/reference/rest/v2/conferenceRecords.participants> · <https://developers.google.com/workspace/meet/api/guides/participants>
- Meet 범위: <https://developers.google.com/workspace/meet/api/guides/authenticate-authorize> · 한도: <https://developers.google.com/workspace/meet/api/guides/limits> · 회의 공간: <https://developers.google.com/workspace/meet/api/reference/rest/v2/spaces/get>
- Meet 전사 요금제 · 언어 · 저장 위치: <https://support.google.com/meet/answer/12849897>
- Docs API 범위(`documents.readonly` 민감): <https://developers.google.com/workspace/docs/api/auth> · <https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/get>
- Calendar 범위: <https://developers.google.com/workspace/calendar/api/auth> · 일정 목록: <https://developers.google.com/workspace/calendar/api/v3/reference/events/list> · 일정 필드: <https://developers.google.com/workspace/calendar/api/v3/reference/events> · 동기화: <https://developers.google.com/workspace/calendar/api/guides/sync>
- Gmail 범위: <https://developers.google.com/workspace/gmail/api/auth/scopes> · 동기화: <https://developers.google.com/workspace/gmail/api/guides/sync> · 라벨: <https://developers.google.com/workspace/gmail/api/guides/labels> · 쿼터: <https://developers.google.com/workspace/gmail/api/reference/quota> · 메시지 형식: <https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/get>
- OAuth 만료 · `invalid_grant` · 갱신 토큰 한도: <https://developers.google.com/identity/protocols/oauth2#expiration> · 웹 서버(폐기 · `access_type` · `prompt`): <https://developers.google.com/identity/protocols/oauth2/web-server> · 부분 허용: <https://developers.google.com/identity/protocols/oauth2/resources/granular-permissions> · OpenID Connect(`id_token` · `sub`): <https://developers.google.com/identity/openid-connect/openid-connect>
- Workspace 사용자 데이터 정책(2026-09-03): <https://developers.google.com/workspace/workspace-api-user-data-developer-policy> · 보안 평가: <https://support.google.com/cloud/answer/13465431> · 제한 범위 심사: <https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification>
