# 실행 계약: 외부 효과는 한 번, 모르면 결과 불명

Taskforce가 사용자 대신 외부 상태를 바꾸는 실행기(메일 발송, Notion · GitHub 쓰기)의 규칙입니다.
U2(실행기)와 U6a · U6b(쓰기)는 이 문서를 계약으로 따릅니다. 규칙을 바꾸면 이 문서와 A29 fixture(11장)를 함께 고칩니다.

용어: U0 · U2 · U3a · U6a · U6b는 구현 단계다(U0 계약 · 관문, U2 실행기, U3a 연결 카탈로그 · 원격 MCP, U6a Gmail 발송, U6b Notion · GitHub 쓰기). A29는 실행기 선택 시험(승인 중 종료 · 외부 효과 직후 종료 · 철회 뒤 재개)이다.

> **외부를 부르기 전에 의도를 DB에 commit한다. 호출 결과를 모르면 다시 부르지 않고 "결과 불명"(`unknown_outcome`)으로 둔다.**

---

## 1. 목적과 범위

- 다루는 것: 사용자의 연결 계정으로 외부 상태를 바꾸는 모든 호출 (Gmail 발송, Notion 생성 · 수정, GitHub 댓글 · 이슈).
- 다루지 않는 것: 읽기(동기화 · 재조회)와 AI 호출. 다시 해도 외부가 바뀌지 않는다.
- 지금 코드에는 외부 쓰기가 없다. `Connector`(`src/lib/connectors/types.ts`)에는 연결 · 동기화 · 토큰 폐기만 있다.
- 보장의 한계: 공급자가 멱등키나 조건부 쓰기를 주지 않으면, 사람의 동시 작업까지 포함한 exactly-once는 보장하지 않는다. 남는 경쟁은 효과마다 8장에 적는다.

## 2. 실행 기반 결정 (K1 · K2)

| 후보 | 내용 | 판단 |
|---|---|---|
| **B2 Postgres 상태 머신** | run · step · approval · intent 행을 Supabase Postgres에 둔다. 함수 호출 한 번 = 단계 하나. commit 뒤 깨우기 + sweep | **채택.** B2를 fixture로 검증했다(11장) |
| B4 Supabase `pg_cron` + `pg_net` (선택 `pgmq`) | DB가 주기적으로 HTTP로 실행기를 깨운다 | 비교 문서만. 운영 Supabase에 셋 다 설치할 수 있지만 설치돼 있지 않다(2026-10-02 확인). Vercel cron이 1분마다 돌 수 있어 sweep은 그것으로 충분하다. 1분 sweep이 부족하다고 확인될 때만 1분 미만 주기로 다시 본다 |
| B1 LangGraph | checkpointer가 그래프 상태를 보존 | 문서 비교만. interrupt 뒤 재개하면 그 node를 처음부터 다시 실행하므로 승인 전 부수 효과를 따로 막아야 한다. 그래프 상태와 run/step 상태가 이중이 된다 |
| B3 Vercel Workflow | 관리형 지속 실행 | 탈락. 처리방침은 Vercel이 정보를 "요청을 처리하는 동안"만 둔다고 약속한다(`docs/legal/privacy.ko.md` 7장 국외 이전 표의 Vercel 행). 실행 상태를 Vercel에 지속 보관하면 이 약속과 충돌한다 |

K2 실행 위치:

- 함수 호출 한 번이 단계 하나를 처리한다. 긴 업무 전체를 요청 하나나 `after()` 하나에 맡기지 않는다. 상주 worker는 두지 않는다(처리방침의 받는 곳이 늘어난다).
- 시간 한도: 저장소 설정의 최장 `maxDuration`은 300초다(`src/app/api/cron/sync/route.ts`, `src/app/api/v1/sources/route.ts`). Pro 플랜은 최대 800초까지 허용한다(10장 ③). lease = 실행 route의 `maxDuration` + 여유(3장). 300초를 넘는 단계는 먼저 쪼개고, 늘려야 하면 800초 안에서 route 설정과 lease를 함께 바꾼다.
- 깨우기: 상태를 commit한 뒤 `after()`(지금 `src/app/api/v1/sources/route.ts`가 쓰는 방식) 또는 인증된 자기 호출(`CRON_SECRET`, `src/lib/api/cron.ts`)로 다음 단계를 부른다.
- sweep: 깨우기를 놓친 run과 승인이 들어온 승인 대기 run을 이어 간다. Vercel cron(`vercel.json`: 지금 `*/15` 동기화 · `7,37` 재처리)에 실행 sweep을 더한다. 주기는 U2에서 정한다(최소 1분). sweep은 돌 때마다 승인 대기 run에도 `begin_call`을 다시 시도한다. 이벤트는 상태가 바뀔 때만 남기고 거절마다 남기지 않는다.

## 3. 상태와 전이

run · step 상태는 Action 상태와 따로 둔다. 실행 결과는 receipt를 거쳐 Action에 반영된다(9장).

run: `queued → running ⇄ waiting_approval`, 끝 상태는 `done | failed | stopped`

| 전이 | 누가 | 조건 |
|---|---|---|
| `queued → running` | 실행기 (모든 입구) | 첫 단계를 준비했다 |
| `running → waiting_approval` | `begin_call` 트랜잭션 안에서 | 유효한 승인이 없고 Auto/Full 규칙도 충족하지 않는다 |
| `waiting_approval → running` | route `POST /approvals/[id]`(승인 기록과 같은 트랜잭션), 또는 `begin_call`(sweep) | 지금 계획의 hash에 묶인 유효한 승인이 있다. 또는 같은 목적을 다른 단계가 이미 가져 단계를 건너뛰었다(승인을 기다릴 이유가 없다) |
| `running → done` | 실행기 | 남은 단계가 없다 (모두 `called` · `skipped`). 계획 단계를 끝낼 때는 planner가 다음 단계를 붙이지 않고 끝났다고 정했을 때(결과 `outcome`)만 |
| `running → failed` | 실행기 | 단계가 `failed`다 |
| 끝나지 않은 상태 → `stopped` | route `POST /runs/[id]/stop` | 사용자가 멈췄다 (5장) |

step: `pending → prepared → calling → called | unknown_outcome | failed | skipped`

| 전이 | 누가 | 조건 |
|---|---|---|
| `pending → prepared` | 실행기 | intent key · 준비할 때의 정책 버전 기록, 정책 평가(승인 필요 표시) |
| `prepared → pending` (다시 계획) | planner · 계획 수정 route | 도구 · 보내는 연결 · 수신자 · 본문 · 인자 · 원문 revision이 바뀌었다. 늘 version + 1, intent key는 다시 준비할 때 계산. `calling` 이후 상태에서는 거절 |
| `prepared → calling` | 실행기, **`begin_call` 하나로만** | 5–7장 · 12장(크레딧 예약) 확인을 모두 통과. intent 행(표식) + lease를 같은 트랜잭션에서 commit |
| `prepared → skipped` | `begin_call` | 같은 intent key를 다른 단계가 이미 가졌다 (승인보다 먼저 본다) |
| `calling → called` | lease를 가진 함수 | 공급자 응답을 받아 receipt를 저장했다 |
| `calling → failed` | lease를 가진 함수 | 공급자가 확정적으로 거절했다 (예: 형식 오류 400) |
| `calling → unknown_outcome` | lease를 가진 함수(시간 초과 · 연결 끊김), 또는 sweep(lease 만료) | 다시 부르지 않는다 |
| `calling → prepared` (내부 효과만) | sweep(lease 만료), 또는 lease를 가진 함수(응답 없음) | 외부 상태를 바꾸지 않는 내부 효과(`effect_class='internal'`: 내장 계획 · 초안의 AI 호출, 1장 범위 밖)는 결과 불명 대신 다시 준비한다. `attempt + 1`, 같은 표식을 다시 쓴다. 다시 준비가 2번을 넘으면 `failed` · run `failed` |
| `unknown_outcome → called` | sweep | readback 기간 안에 표식을 찾았다 |
| `unknown_outcome → failed` | 사용자 | 사용자가 결과를 정했다. 다시 보내기는 새 회차다(4장) |

- step 전이는 CAS다: `where state = <이전 상태> and version = <읽은 버전>`, 성공하면 `version + 1`. 바뀐 행이 없으면 다른 함수가 먼저 했으므로 아무것도 하지 않는다. run 전이는 이전 상태를 조건으로 한 update이고, `begin_call`은 run 행을 잠근다. 같은 패턴이 이미 있다: `write_action`의 version CAS(`p_expected_version`, `supabase/migrations/20261019000000_claim_state_write.sql`), 재처리의 `updateIfUnchanged`(상태 · 처리 요약이 그대로일 때만 update, `src/lib/sources/retry.ts`).
- lease: `calling`으로 갈 때 소유자 id(함수 호출 id)와 만료 시각을 적는다. `calling → called | failed | unknown_outcome`은 lease 소유자만 쓴다(sweep의 만료 처리는 예외).
- 시각: lease와 승인 만료는 DB 시각으로 잰다. 호출자가 넘긴 시각을 쓰지 않는다. lease 길이 = 실행 route의 `maxDuration` + 여유(fixture는 300 + 30초)라 살아 있는 함수의 lease는 만료되지 않는다. route의 `maxDuration`은 리터럴이라 같은 값인지 U2의 route 테스트가 본다(`src/lib/ai/deadline.ts`의 `INTERACTIVE_MAX_DURATION_S`와 같은 방식).
- 결과: 함수 종료 · lease 만료 · 중복 실행에서도 같은 단계의 외부 호출은 한 번이다. 어느 지점에서 죽어도 DB만 보고 이어 간다. 메모리 checkpoint는 복구 수단이 아니다.
- `unknown_outcome` 단계가 있는 run은 다음 단계로 가지 않는다. `begin_call`은 앞 단계가 모두 `called` · `skipped`일 때만 다음 단계를 부른다. readback은 결과 불명이 된 뒤 정한 기간(fixture 24시간) 안에서만 sweep이 시도한다. 지나면 그대로 두고 사용자가 정한다.
- `called`는 공급자가 받았다는 뜻이지 목적 달성(상대가 받음 · 읽음)이 아니다. HTTP 200, `isError: false`, "완료" 문장만으로 목적 달성으로 보지 않는다.

## 4. write-ahead intent와 표식

- intent key = (Action id, 공급자, 도구, 목적, 정규화한 대상, 회차). 도구가 다르면 같은 목적 · 대상이라도 중복이 아니다. 내부 효과는 단계마다 하나다(외부 상태가 없어 다른 단계와 중복을 따지지 않는다). 같은 표식을 다시 쓰는 것은 내부 효과의 재시도뿐이다: 이미 자기 표식을 가진 외부 단계가 (계약 밖에서) 다시 `prepared`가 되어도 부르지 않고(`stale`), 앞 결과를 덮거나 run을 끝내지 않는다. `intents.intent_key`는 DB unique다. 수동 버튼과 자동 trigger가 같은 목적을 동시에 시작해도 한 단계만 `calling`으로 간다. 다른 쪽은 `skipped`, receipt에 누구의 중복인지 적는다.
- 표식(marker)은 `intents` 행에 저장하는 임의 값이다(무작위 uuid, 또는 서버 비밀로 만든 intent key의 HMAC). 외부(메일 헤더 · 댓글 본문)에는 표식만 실린다. intent key는 DB 밖으로 나가지 않는다.
- 순서:
  1. intent 행(표식) + `prepared → calling` + lease를 한 트랜잭션에 commit한다.
  2. 표식을 실어, `begin_call`이 검증해 돌려준 내용(수신자 · 본문 · 인자) 그대로 외부를 부른다. 그 전에 읽어 둔 내용으로 보내지 않는다.
  3. `called` + receipt를 commit한다. 받은 뒤 이 쓰기가 실패하면 다시 쓰고, 그래도 안 되면 오류를 낸다. 결과 불명으로 바꾸지 않는다(단계는 `calling`으로 남고 lease 만료 뒤 readback이 확인한다).
- 1과 3 사이에 죽으면 sweep이 lease 만료를 보고 `unknown_outcome`으로 옮긴다. 다시 부르지 않는다. 그 뒤 sweep이 readback으로 표식을 찾는다.
- 회차: 같은 회차의 재시도 · 중복 동기화는 새 회차가 아니다. 새 회차는 사용자의 명시적 다시 보내기, 또는 미리 허용한 후속 규칙의 다음 발생(서버가 결정적 occurrence key로 한 번만 발행)에서만 생긴다. 모델은 회차를 늘리지 못한다(planner가 붙이는 단계는 늘 1회차, `append_step`). 앞 효과가 `unknown_outcome`이면 새 회차로 우회하지 않는다.
- 외부 호출 직전에 Action과 정책의 최신 버전을 다시 읽는다. 이미 외부에서 끝났으면(readback으로 확인) 부르지 않고 관찰로 반영한다.

## 5. 승인

- 승인 hash = (공급자, 도구, 효과 종류, 보내는 연결(계정, 단계에 묶임), 인자, 수신자, 본문 hash, 원문 revision, 정책 버전, 만료). 만료는 초 단위로 자르고 UTC로 직렬화한다(앱의 Date는 밀리초라 마이크로초가 사라진다. 세션 시간대와 상관없이 같은 값).
- 정규화 규칙은 하나다: 주소는 앞뒤 공백 제거 · 소문자 · 중복 제거 · 정렬. 승인 hash · intent key · Auto 규칙 비교가 같은 함수를 쓴다.
- 앱은 보여 준 계획의 hash를 승인과 함께 보낸다. 서버는 지금 계획으로 hash를 다시 계산해 같을 때만 승인을 기록한다. 보여 준 뒤 바뀐 계획은 승인되지 않는다.
- `begin_call`은 지금 단계로 hash를 다시 계산해 승인 행과 같을 때만 통과시킨다. 하나라도 바뀌면 기존 승인으로는 실행 0이다.
- 유효한 승인이 없는 단계는 `begin_call`이 Auto/Full 규칙을 지금 다시 확인한다(준비 단계의 표시를 믿지 않는다): 모드가 `auto` · `full`, 모든 수신자의 출처가 사용자, 모든 주소가 규칙 안, 규칙의 정책 버전이 준비할 때와 같음. 하나라도 아니거나 모르면(NULL) 승인 대기다. `pending`이 아닌 단계에는 준비할 때의 정책 버전이 반드시 있다(DB 제약).
- 승인 · Auto/Full 규칙은 외부 효과에만 적용한다. 내부 효과(내장 계획 · 초안의 AI 호출)는 승인 없이 부른다. 수신자가 없는 외부 단계는 Auto/Full 규칙을 충족하지 못한다. 승인은 아직 부르지 않은 단계(`pending` · `prepared`)에만 기록한다.
- 철회 · 만료된 승인은 무효다. 철회 뒤에는 이어서 실행(resume)해도 부르지 않는다. 철회는 단계 행을 먼저 잠가 진행 중인 `begin_call`과 줄을 선다: `begin_call`이 먼저 commit하면 철회는 단계가 이미 `calling`이라고 알린다(철회가 늦었다).
- Review의 "내 일 맞음" 확인과 AI 처리 동의는 실행 승인이 아니다.
- 중단(stop)은 다음 단계만 막는다. 이미 `calling`인 호출은 되돌릴 수 없으므로 결과 확인(응답 · readback)을 끝까지 한다. 중단 요청을 받았다는 것이 원격 작업이 멈췄다는 증거는 아니다. `begin_call`은 run이 `stopped`면 거절한다.

## 6. 차단 스위치 `execution_controls`

- DB 플래그 세 층: 전체(`global`) / 공급자별(`provider`, 예: `gmail`) / 모드별(`mode`: `manual` · `auto` · `full`). `auto`와 `full`을 끄면 "Manual만"이다.
- `begin_call`은 RPC 하나 = READ COMMITTED 트랜잭션 하나이고, 외부 호출 전에 commit된다. 외부 호출은 그 트랜잭션 안에 없다.
- 스위치는 그 트랜잭션 안에서, `prepared → calling`과 함께 확인한다. 해당 행 셋(전체 · 그 공급자 · 그 모드)을 `for share`로 잠그고 읽는다. 끄는 쪽의 `update`는 진행 중인 전이가 끝날 때까지 기다리고, 끈 뒤에 commit되는 전이는 없다. 잠금 순서는 step → run → 정책 → 실행 주체 → 스위치 → 도구 · 수신자 허용 목록(7장) → 크레딧 계정(12장)이다.
- 모든 입구(route · 자기 호출 · sweep)가 같은 `begin_call`을 지난다. 입구마다 실제로 그런지는 U2에서 route 테스트로 확인한다.
- 행이 없는 공급자 · 모드는 막힌 것으로 본다(닫힌 쪽). 새 공급자는 행을 추가해야 실행된다.
- 막힌 단계는 실패가 아니다. `prepared`로 남고, 다시 켜면 sweep이 이어 간다. 이미 `calling`인 호출은 끝까지 결과를 받는다.
- 끄기 · 켜기는 승인된 `db query`로 한다. 절차는 U2에서 런북(`docs/go-live/runbook.md`)에 쓴다.

## 7. 허용 목록과 수신자 출처

실행기에서 둘 다 확인한다.

1. 실행 주체: 건넴 전까지 운영자 계정만.
2. 발송 수신자 · 쓰기 대상: 시험 동안 허용 목록 안만.

**불변식: 원문 · 도구 출력에서 나온 수신자 · 대상은 Auto/Full 규칙을 자동으로 충족하지 못한다.**

- 출처는 수신자마다 둔다: `user` · `source`(원문) · `tool_output` · `model`(모델이 제안). 사용자가 정한 것만 `user`다.
- 하나라도 `user`가 아니면 그 단계는 승인을 받는다. 규칙에 있는 주소라도 마찬가지다.
- 정책 평가(준비 단계)가 승인 필요로 표시하고, `begin_call`이 출처 · 규칙을 다시 확인한다(5장). 준비 단계가 틀려도 막힌다.
- 출처는 서버 코드가 주소가 어디서 왔는지 보고 정한다. 모델 출력의 출처 값을 그대로 받지 않는다(DB 제약은 형식만 확인한다).
- 외부 단계의 수신자 · 대상은 하나 이상이고 모두 허용 목록 안이어야 한다. 대상을 인자에만 적은 외부 단계는 막는다(Notion · GitHub 쓰기 대상은 U6b에서 수신자 항목으로 둔다). 보내는 연결이 없는 외부 단계도 막는다(`needs_connection`). 허용 목록은 외부 효과에만 적용한다.

## 8. 효과별 계약표

공통: 부정 readback이어도 비멱등 효과는 자동으로 다시 보내지 않고 `unknown_outcome`에 둔다. readback이 표식을 찾으면 `called`, 못 찾으면 사용자가 결과를 정한다. **표식에 수신자 · Action id · 본문을 넣지 않는다.**

| 효과 | 표식 | 재조회 (readback) | 남는 경쟁 |
|---|---|---|---|
| Gmail 발송 | `X-Taskforce-Intent` 헤더에 표식만. 클라이언트 `Message-ID`는 쓰지 않는다 (Gmail이 자기 값으로 바꾼다). 발송이 성공하면 응답의 Gmail 메시지 id를 receipt에 적는다 | 응답을 잃었으면 발송 전에 기록한 `historyId`부터 `history.list`(`labelId=SENT`, `messageAdded`) → `messages.get format=metadata`로 헤더 대조. `rfc822msgid:` 검색은 쓰지 않는다 | 중간에서 헤더가 지워지면 찾지 못한다(관찰된 적 없음). 그때는 `unknown_outcome`으로 남는다 |
| Notion 수정 | 값 설정은 멱등 | 페이지를 다시 읽어 값 비교 | 사람의 동시 편집은 마지막 쓰기가 남는다 |
| Notion 생성 | 표식 속성은 사용자가 동의할 때만 (사용자 DB 스키마를 바꾼다. DB 밖 페이지는 속성이 없다) | 부모 + 봇 작성자 + 생성 시각 창으로 query | 같은 창 · 같은 제목의 수동 생성 |
| GitHub 쓰기 | 본문 HTML 주석 표식 | 대상별 목록 (issue 댓글은 작성자 + `since`). search는 쓰지 않는다 (색인 지연, 분당 30회) | 같은 MCP 연결로 읽히는지 확인 전 (10장 ②) |

- 2026-10-02 dev Google 프로젝트에서 확인(운영자 본인 계정, 자기에게 1통, 확인 뒤 토큰 폐기): 클라이언트 `Message-ID`는 Gmail이 바꿨고(`rfc822msgid:` 검색 0건), `X-Taskforce-Intent`는 값 그대로 남았고, 발송 전 `historyId`부터 `history.list`가 SENT 메시지를 찾았다. U6a에서 Testing 중인 Gmail 프로젝트 B(`docs/go-live/google-verification.md`)의 첫 운영 발송 때 다시 확인한다.

## 9. CLAUDE.md 원칙과의 관계

- 실행 결과도 Claim → 진실 판정 → Action/Evidence를 거친다. 실행기는 Action 필드를 직접 쓰지 않는다(원칙 5).
- receipt(공급자 id · readback 결과)는 근거가 된다(원칙 2). receipt는 source kind `execution`으로 기존 writer(`write_action`)를 지나고, 실행 결과 Claim의 origin은 `execution`이다.
- 에이전트의 결정은 `origin=user`가 아니다. 사용자의 승인은 그 계획의 실행을 허락한 것이지 사용자가 값을 정한 Claim이 아니다.
- 모든 전이 · 승인 · 거절 · 중단은 이벤트로 남긴다(원칙 6). 운영 지표: `unknown_outcome` 수, 승인 요청 수(원칙 3: 확인 요청은 그 자체가 비용).
- 인스턴스 경합: 수집 쪽 병합 대기열은 메모리라 인스턴스 하나 안에서만 보장되고, 인스턴스 사이는 `write_action` 버전 확인이 막는다(`src/lib/sources/process.ts`). 실행 쪽은 메모리에 기대지 않고 intent unique + CAS로 막는다.

## 10. 관문

①–④ 모두 2026-10-02에 확인했다. ②의 "같은 연결로 readback이 읽히는지"는 U3a에서 확인한다.

| 관문 | 확인할 것 | 안 되면 |
|---|---|---|
| ① 계획 생성 | **확인함 (2026-10-02).** 기본 공급자(fireworks · together · deepinfra)의 `z-ai/glm-5.3-flash`로 객체 안 discriminated union 다음 단계 5/5 유효, 단계 종류 4/5(검색할 상황을 끝남으로 고름) → 품질은 eval E2로 본다. 확인한 것: ZDR 공급자 허용 목록 안에서 서비스되는 모델로 `completeJson`(`src/lib/ai/llm.ts`, `json_schema` strict)이 다음 단계 discriminated union 스키마를 받는지. `src/lib/ai/providers.ts`는 모델이 아니라 공급자를 고정한다(`data_collection: deny` · `zdr: true` · 목록 밖 fallback 금지) | 그 공급자들이 서비스하는 다른 모델. 조건을 풀어 성공시키지 않는다. `tool_calls`는 eval이 요구할 때만 |
| ② 원격 MCP | **확인함 (2026-10-02, 공개 메타데이터 · 공식 문서).** Linear: 동적 등록 · Client ID 메타데이터 문서 둘 다 지원 → 바로 연결. GitHub: 둘 다 없음 → 자체 OAuth App 또는 GitHub App 등록 필요(서버에서는 GitHub App + REST가 권한이 더 좁다). Figma: MCP 카탈로그에 오른 클라이언트만(신규 접수 중단) → REST 읽기만, 캔버스 쓰기 없음. 확인한 것: GitHub · Linear · Figma 원격 MCP가 제3자 서버 클라이언트(동적 등록 · 허용 목록)를 받는지, 같은 연결로 readback 경로가 읽히는지 | GitHub App, 또는 "Want this"로 내림 |
| ③ Vercel 플랜 한도 | **확인함 (2026-10-02).** 팀은 Pro 플랜(사용자 확인). Fluid compute(기본 켜짐)에서 함수 기본 300초, 최대 800초(GA), 함수별 확장 최대 1800초(베타). cron은 프로젝트당 100개, 최소 1분 주기 · 분 단위 정밀도. 출처: https://vercel.com/docs/functions/configuring-functions/duration (2026-08-24 갱신), https://vercel.com/docs/cron-jobs/usage-and-pricing (2026-07-15 갱신). 확인한 것: 실제 `maxDuration` 상한, cron 최소 주기 | 단계를 더 쪼갠다. 1분 sweep이 부족하면 B4(1분 미만) |
| ④ Gmail 헤더 보존 | **확인함 (2026-10-02, dev 프로젝트).** `X-Taskforce-Intent`는 남고 클라이언트 `Message-ID`는 바뀐다(8장). U6a에서 프로젝트 B Testing으로 다시 확인 | 프로젝트 B에서 헤더가 지워지면 readback 없이 `unknown_outcome`으로 두고 사용자가 정한다 |

## 11. A29 fixture (실행 가능한 명세)

`tests/execution/a29.test.ts`, 드라이버 `tests/execution/driver.ts`. 운영 마이그레이션 `supabase/migrations/20261021000000_execution_core.sql`(U2 PR3)을 PGlite에 그대로 적용해 시험한다. fixture만의 SQL은 없어서 명세와 운영 SQL이 어긋나지 않는다. 테스트 안에서만 더하는 것: 테스트 시계, 외부 효과를 기록하는 가짜 공급자 원장(`fake.ledger`)과 시험 전용 외부 도구(`fake.send` · `fake.reply`), 모두 켠 스위치, 허용 목록 안의 시험 사용자 · 주소. 드라이버는 U2가 만들 실행기가 아니다. "함수가 죽는다" = Driver 인스턴스를 버리고 새로 만든다. 시각은 DB 시각이다. 운영의 `db_now()`는 `now()`뿐이고, 테스트는 마이그레이션을 적용한 뒤 테스트 안에서만 `app.now`를 읽는 판으로 바꾼다(세션 설정은 풀링된 연결에 남을 수 있어 운영에서 쓰지 않는다).

| # | 사례 | 결과 |
|---|---|---|
| 1 | 승인 대기를 commit한 직후 죽음 → 새 인스턴스 | 승인 뒤 외부 효과 1. 외부로 나간 표식에 주소 · Action id 없음 |
| 2 | 공급자가 받은 직후 · `called` commit 전에 죽음 | lease가 살아 있으면 그대로, 만료 → `unknown_outcome`. 음성 readback 재발송 0, 양성 → `called`. 효과 1. 그동안 계획 수정 거절 |
| 2 | readback 기간 지남 / 응답 유실 오류 / 확정 거절 | `unknown_outcome` 유지 / lease 소유자가 바로 `unknown_outcome` / `failed` · run `failed` |
| 3 | 승인 철회 · 만료 | 효과 0 |
| 3 | 승인 대기 commit 직후 승인, 승인 행만 있고 깨우기 없음 | run이 멈추지 않고 효과 1 |
| 4 | 승인 hash 항목(수신자 · 본문 · 원문 revision · 정책 버전 · 연결) 변경 | 효과 0 |
| 4 | 보여 준 뒤 수신자 추가 → 승인 / 부르기 직전 본문 · 연결 수정 / 마이크로초 만료를 Date로 돌려받아 승인 | 승인 거절 / 거절 뒤 다시 준비한 계획 그대로 1건 / 승인됨 |
| 5 | 스위치 전체 · 공급자 · Manual만 · 행 없음(전체 · 공급자 · 모드) × route · 자기 호출 · sweep | 효과 0, 다시 켜면 1. 단계를 읽은 뒤 끄면 0, `calling` commit 뒤 끄면 진행 중 1건만. Manual만에서 승인된 Manual은 1 |
| 6 | 같은 단계를 두 함수가 같은 버전으로 / 같은 intent를 수동 · 자동 run이 동시에 / 이미 보낸 목적을 Manual로 다시 / 승인을 기다리던 목적을 다른 run이 먼저 보냄 | 효과 1. 뒤의 둘은 승인을 묻지 않고 `skipped`, 기다리던 run도 끝남 |
| 6 | 도구만 다른 같은 목적 · 대상 | 효과 2 (중복 아님) |
| 7 | Auto run에서 수신자 출처(사용자 규칙 안 · 밖, 원문, 도구 출력, 모델, 섞임) | 사용자 · 규칙 안만 1, 나머지 승인 대기 |
| 7 | 준비 단계 표시가 틀림 / 준비 뒤 규칙 비움 · 정책 버전 올림 / 준비 때 정책 버전 NULL | `begin_call`이 막음, 효과 0 (NULL은 DB 제약도 막음) |
| — | 중단 | 진행 중 호출은 결과를 받고 다음 단계 0. 부르기 직전 중단도 0 |
| — | 받은 뒤 receipt 저장 실패 | 다시 써서 `called`. 계속 실패하면 오류, `calling`에 남아 lease 만료 뒤 readback으로 `called` |
| — | 내부 효과(AI 호출)에서 lease 만료 · 응답 없음 | 승인 없이 부른다(Manual이어도). 결과 불명 대신 같은 표식으로 다시 준비, 다시 준비가 2번을 넘으면 `failed` · run `failed` |
| — | 실행 주체 · 수신자 허용 목록 밖 / 목록 밖 도구 · 외부 도구를 내부 효과로 적은 단계 / 수신자 없는 외부 단계(대상을 인자에만) / 보내는 연결 없음 | 효과 0(승인이 있어도), 단계는 `prepared`, run에 막힌 이유(`hold_reason` `actor` · `blocked` · `needs_connection`). 목록에 넣으면 이어 가서 1 |
| — | 이미 보낸 외부 단계를 `prepared`로 되돌림 / 앞 단계가 결과 불명인데 뒤 단계를 직접 부름 / 승인 뒤 공급자만 바뀜 | 효과 추가 0 (`stale`, 앞 receipt 그대로 / `stale` / 승인 대기) |

한계: PGlite는 연결이 하나라 트랜잭션이 실제로 겹치지 않는다. 동시성은 트랜잭션 경계(단계를 읽은 뒤 · `calling` commit 뒤)에 끼어드는 방식으로 보인다. 잠금과 동시 commit 경합은 `tests/pg/execution-locks.test.ts`가 실제 Postgres에 연결 둘을 열어 시험한다(`npm run test:pg`, CI는 postgres service): 스위치 끄기 · 실행 주체 · 수신자 허용 목록 · 도구 목록 지우기 vs `begin_call`(양쪽 순서), 같은 intent 동시 `begin_call`(commit · rollback), 같은 단계 동시 `begin_call`, 승인 철회 vs `begin_call`(양쪽 순서). 운영 쪽 모양(처음 상태 · run 만들기 · 실행 이벤트 · 권한)은 `tests/db/execution-core.test.ts` · `execution-rls.test.ts`가 본다. 크레딧 · 산출물 · 원가(12장)는 `tests/db/execution-credits.test.ts`가, 같은 사용자의 동시 예약 · 같은 단계 원가의 동시 확정 · 멈추기와 단계 종료의 겹침은 `tests/pg/execution-locks.test.ts`가 본다.

## 12. 크레딧 · 산출물 · AI 원가 (U2 PR4)

`supabase/migrations/20261022000000_execution_credits_artifacts.sql`. K4 = C3: 크레딧은 운영자가 지급한다(`grant_credits`, 승인된 `db query`). 구매 · 구독 · 클라이언트 지급 경로는 없다. Auto/Full의 standing 예산(A47)은 Auto/Full을 켤 때(U6a) 정한다. 지금은 run 예산(`budget_credits`)과 잔액만 본다.

- 원장(`credit_ledger`)은 더하기만 한다. 키(`receipt_key`)가 unique다: `grant:<지급 id>` · `reserve:<step>` · `settle:<step>` · `release:<step>`. 같은 영수증 · 재시도 · 중복 호출은 두 번 차감 · 지급하지 않는다. 계정(`credit_accounts`)은 원장 합계를 들고 있는 잠금 행이고, 가용(`granted - reserved - settled`)은 제약으로 음수가 되지 않는다.
- 예약: `begin_call`이 승인/Auto 확인 뒤, intent + lease와 같은 트랜잭션에서 계정 행을 `for update`로 잠그고 단계 추정치(`estimate_credits`)가 가용 잔액과 run의 남은 예산(`budget_credits - (예약 - 해제)`) 안이면 예약한다. 막히면 `hold_reason='credit'`, 단계는 `prepared`에 남는다(gate: 잔액 · 예산 `insufficient_credit`, 요율 없음 `no_rate`, 추정치 없는 초안 `no_estimate`, 이미 닫힌 예약 `reservation_closed`). 추정치 0인 계획 단계는 예약하지 않는다. 같은 단계의 재시도는 열린 처음 예약을 그대로 쓴다.
- 정산: 내부 효과 단계는 `complete_internal_step`이 `called` + 산출물 + 원가 행 + 정산을 한 트랜잭션에서 한다(lease 소유자만). 정산 = 확정된 청구 대상 원가 합계(그 호출의 모든 시도, 형식 오류로 다시 물은 시도 포함) × 예약 때 요율(`credit_rates`, `c3-v1`: 1 크레딧 = $0.001), 올림, 예약 상한 안. 남은 예약은 해제한다. 끝내지 않은 단계(부르는 중 · 다시 준비 · 결과 불명)는 정산하지 않는다.
- 미확정(A46): 청구 대상 시도 하나라도 비용을 모르면, 또는 초안 단계인데 청구 대상 원가 행이 없으면 정산하지 않고 예약을 둔다. 0원으로 처리하지도, run이 끝났다고 해제하지도 않는다. `reconcile_usage`가 비용을 확정하면(sweep의 generation 조회) 그때 정산한다. 원가 행 하나씩 RPC 한 번에 확정한다.
- 해제: run이 끝나거나(`done` · `failed` · `stopped`), 끝난 run에서 부르던 · 결과 불명이던 단계가 나오면 트리거가 `release_run_credits`를 부른다: 부르지 못했거나 실패한 단계의 예약은 해제, 끝낸 단계는 정산, 부르는 중 · 결과 불명은 둔다. 함수는 run 행을 먼저 잠가(step → run → 계정) 멈추기와 단계 종료가 겹쳐도 뒤에 commit하는 쪽이 해제한다. 드물게 Postgres가 교착을 감지해 한쪽을 되돌리면(멈추기 vs 같은 run의 재시도 `begin_call`) 다시 부르면 된다. U2 PR6 sweep은 보조 안전망으로 `release_run_credits()`(인자 없음 = 열린 예약이 남은 끝난 run 모두)를 부른다.
- 원가(`execution_usage`, A51): OpenRouter 시도마다 한 행(generation id unique, 모델 · 토큰 · `cost_usd`, `confirmed | unconfirmed`)이고 사용자 청구와 따로 둔다. 청구 대상(`billable`)은 초안 단계를 끝낸 호출에서 응답을 받은(generation id가 있는) 시도뿐이고 서버가 정한다. 계획 단계 · 실패 · 응답 없이 다시 부른 시도(`record_usage`, 단계를 내보내기 전에 부른다) · 응답을 받지 못한 시도는 플랫폼 원가다(id 없는 행은 운영자가 정할 때까지 미확정).
- 산출물(`execution_artifacts`): 단계 하나에 초안 하나, 앱이 RLS로 읽는다. 본문은 `retain_until`(기본 90일, D9a-1이 정함)이 지나면 `purge_expired_artifacts`가 비운다. 원장 · 계정 · 요율 · 원가는 클라이언트가 읽지 못한다(잔액은 U2 PR6의 `GET /api/v1/credits` 합계).
- 원장 · 원가가 가리키는 run · step은 지울 수 없다(외래키 no action): 원장이 있는 사용자의 할 일을 하드 삭제하는 스크립트(심사 계정 `--reseed` 등)는 실패한다. 계정 삭제는 `auth.users` cascade로 같은 문장에서 함께 지운다.
