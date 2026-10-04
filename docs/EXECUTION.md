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
- sweep: 깨우기를 놓친 run과 승인이 들어온 승인 대기 run을 이어 간다. Vercel cron(`vercel.json`: 지금 `*/15` 동기화 · `7,37` 재처리)에 실행 sweep을 더한다. 주기는 1분이다(U2 PR6, `vercel.json`의 `/api/cron/execution-sweep`, 13장). sweep은 돌 때마다 승인 대기 run에도 `begin_call`을 다시 시도한다. 이벤트는 상태가 바뀔 때만 남기고 거절마다 남기지 않는다.

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
| `running` · `waiting_approval` → `stopped` | `begin_call` (gate `action_closed`) | run의 Action이 열려 있지 않다(`done` · `dropped`, 5장). 다음 단계를 부르지 않는다 |

step: `pending → prepared → calling → called | unknown_outcome | failed | skipped`

| 전이 | 누가 | 조건 |
|---|---|---|
| `pending → prepared` | 실행기 | intent key · 준비할 때의 정책 버전 기록, 정책 평가(승인 필요 표시) |
| `prepared → pending` (다시 계획) | planner · 계획 수정 route | 도구 · 보내는 연결 · 수신자 · 본문 · 인자 · 원문 revision이 바뀌었다. 늘 version + 1, intent key는 다시 준비할 때 계산. `calling` 이후 상태에서는 거절(트리거 `execution_steps_replan`). 보관 기간 정리가 끝난 run의 `args.brief`만 지우는 것은 다시 계획이 아니다(12장) |
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
- 멈춘 시각 `execution_runs.stopped_at`(DB 시각, `20261026000000_execution_stopped_at.sql`): 열린 run을 멈출 때 처음 한 번 적고 바꾸거나 지우지 않는다(끝 상태는 다시 열리지 않는다. 다시 멈춰도 그대로). 앱은 RLS로 읽고 run 요약(`runSummarySchema`)에도 있어, 어느 기기에서 멈췄든 "Stop requested <시각>"을 보인다. 그 마이그레이션 전에 멈춘 run은 null이다.
- 열린 Action에서만 다음 단계(2026-10-04 사용자 결정): `begin_call`은 run의 Action을 `for share`로 읽고, 열려 있지 않으면(`done` · `dropped`. 열림은 `/now`와 같은 `status = 'open'`) 부르지 않고 run을 `stopped`로 끝낸다(gate `action_closed`, 멈춘 시각도 적는다). 사용자가 앱 밖(다른 기기 · 옛 빌드 · 연동 완료 동기화)에서 할 일을 끝내거나 지워도 그 run이 크레딧을 더 쓰지 않는다. 막힘(hold)이 아니라 끝이다: 할 일을 다시 열어도 멈춘 run은 이어 가지 않고 새 run으로 시작한다. 확인은 앞 단계 확인 바로 뒤, 중복 · 실행 주체 · 스위치보다 먼저라 스위치가 막혀 있어도 그 run은 멈춘다(sweep은 전체가 막힌 동안 깨우지 않으므로 풀린 뒤 첫 깨우기에서). 이미 `calling`인 단계는 위 중단과 같이 끝까지 결과를 받는다(초안이면 receipt도 붙는다. 끝낸 할 일은 다시 열리지 않는다, 9장 A57). 남은 예약은 run을 멈추는 트리거가 해제한다(12장). 할 일을 끝내는 쓰기(`write_action`의 update)는 진행 중인 `begin_call`이 commit될 때까지 기다리고, 끝낸 뒤 commit되는 전이는 없다(6장 스위치와 같다, `tests/pg/execution-locks.test.ts`).

## 6. 차단 스위치 `execution_controls`

- DB 플래그 세 층: 전체(`global`) / 공급자별(`provider`, 예: `gmail`) / 모드별(`mode`: `manual` · `auto` · `full`). `auto`와 `full`을 끄면 "Manual만"이다.
- `begin_call`은 RPC 하나 = READ COMMITTED 트랜잭션 하나이고, 외부 호출 전에 commit된다. 외부 호출은 그 트랜잭션 안에 없다.
- 스위치는 그 트랜잭션 안에서, `prepared → calling`과 함께 확인한다. 해당 행 셋(전체 · 그 공급자 · 그 모드)을 `for share`로 잠그고 읽는다. 끄는 쪽의 `update`는 진행 중인 전이가 끝날 때까지 기다리고, 끈 뒤에 commit되는 전이는 없다. 잠금 순서는 step → run → Action(5장 열린 Action 확인) → 정책 → 실행 주체 → 스위치 → 도구 · 수신자 허용 목록(7장) → 크레딧 계정(12장)이다.
- 모든 입구(route · 자기 호출 · sweep)가 같은 `begin_call`을 지난다. 스위치를 끄면 세 입구 모두 `calling` 0인 것을 `tests/db/execution-executor.test.ts`가 본다(13장).
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

**초안 receipt (U2 PR7에서 구현).** `supabase/migrations/20261023000000_execution_receipts.sql`, `src/lib/execution/receipt.ts`. 끝낸(`called`) 초안 단계 하나에 receipt 하나를 Action에 붙인다. 초안 목적의 완료만 반영하고 Action은 끝내지 않는다(A38).

| 무엇 | 값 |
|---|---|
| receipt 원문 | `sources` kind `execution`, 글 = 인용 = `초안 저장: <산출물 제목>`(한 줄, 200자, 본문 · 원문 · 요청은 담지 않는다), 링크 `taskforce://artifacts/<산출물 id>`, `external_id` = 단계 id(사용자마다 unique), 시각 = 산출물을 저장한 DB 시각, `processing_status = 'done'` |
| Claim | origin `execution`, field `artifact`, 값 = 산출물 id, 인용 = receipt 글. 화자 나 · 확정 · 직접 · private(아직 보내지 않은 내 초안) |
| 근거 · 이벤트 | 근거 role `executed`. 이벤트 `artifact_created`, actor `agent`, after = 산출물 · run · 단계 id(글 없음) |

- 진입점: `writeDraftReceipt(store: ReceiptStore, stepId: string): Promise<"written" | "exists">`. `ExecutionStore`가 `ReceiptStore`를 포함한다(운영 `supabaseExecutionStore`는 `supabaseReceiptStore(admin)`을, 시험 `pgliteExecutionStore`는 `pgliteReceiptStore`를 담는다). 실행기(13장 `advance`)는 초안 단계를 끝내면(`complete_internal_step`이 true, 또는 다시 쓴 쪽이 false라 앞 쓰기가 commit했을 수 있을 때) 부른다(멱등. 끝내지 않은 단계면 `not_found`로 쓰지 않는다). 실패해도(`ReceiptWriteError`, DB 오류) 단계 · run은 끝낸 그대로 두고 `execution_receipt_failed`(run · 단계 id · 까닭)만 남긴다. sweep은 보조 안전망 단계로 `writeMissingReceipts(store, SWEEP_RECEIPT_LIMIT = 20)`을 부른다(receipt가 없는 하루 안의 끝낸 초안 단계, `missing_execution_receipts`).
- 쓰기는 DB 함수 `write_execution_receipt(단계, 읽은 Action 버전, receipt)` 하나가 receipt 원문 · Claim · 근거 · 이벤트를 `write_action`과 한 트랜잭션에서 쓴다. receipt는 Action을 바꾸지 않으므로 DB 함수가 잠근 Action 행의 값을 그대로 다시 쓰고 활동 시각(`last_activity_at`, 랭킹 · 확인 순서)도 되돌린다: 바뀌는 것은 버전(+1)과 `updated_at`뿐이다. 실행기는 그 전에 Claim을 더해 진실 판정 순수 함수(`projectAction`)로 다시 계산해도 값이 같은지 확인하고, 다르면 쓰지 않는다(`changes_action`). 사용자 · Action · 종류 · 시각 · Claim의 필드 · origin · 값 · 상태 · 채널 · 근거 · 이벤트는 DB 함수가 단계 · 산출물 행에서 정한다(호출자가 넘긴 값을 믿지 않는다). 끝낸 초안 단계 · 산출물이 아니거나, 인용이 receipt 글에 없거나, 링크가 그 산출물을 가리키지 않으면 거절한다. Action 행을 먼저 잠가 같은 단계를 함께 쓰는 실행기 · sweep이 줄을 서고, 이미 붙었으면 `exists`, 버전이 어긋나면 아무것도 쓰지 않고 `conflict`(다시 읽어 3번까지, 실제 Postgres 경합은 `tests/pg/execution-receipts.test.ts`).
- 진실 판정은 `artifact` 필드를 계산하지 않는다(`TRUTH_RULES.md` 2장 "구현"): 상태 · 기한 · 담당 · 내용 · 확인 이유 그대로라 초안은 완료가 아니고, 사용자가 끝낸 할 일도 다시 열지 않는다(A57). 실행 Claim은 origin `user`가 아니다(A55).
- DB가 막는 것: 원문 · 인용 없는 실행 Claim(`claims_source_origin`), 실행 Claim으로 `artifact` 밖의 필드(`claims_execution_artifact`), 처리하지 않은 receipt 원문(`sources_execution_receipt`: 재처리 cron · 추출이 고르거나 `processing`으로 바꾸지 못한다), 클라이언트가 receipt 원문을 만들거나 고치거나 지우는 것(제한 정책, 읽기는 그대로). 기준 17 확인 쿼리: `select count(*) from claims where origin = 'execution' and (source_id is null or quote is null)` = 0.
- receipt는 원문이 아니다: 초안 자료(실행기의 근거 읽기에서 빼고 `context.ts`도 다시 뺀다)와 매칭 판정의 최근 인용(`db-store.ts` `shortlist`)에 넣지 않고(앞선 초안 제목은 모델이 쓴 글이다), 빠진 할 일 신고 · 직접 추가의 관련 구절로 고르면 400, 주간 질문의 첫 원문으로 세지 않고, 앱 원문 목록(`recentSources`)에서 뺀다. Action 상세의 근거 · 변경 이력("초안 저장"), 물어보기 · 넘기기(`실행 기록`)에는 보인다. 지표 1(AI 오판율)은 actor `agent` 이벤트를 세지 않는다.
- sweep 보조 안전망은 하루 안의 산출물만 보고, 계속 실패하는 단계(`execution_receipt_failed` 로그)는 하루 뒤 더 고르지 않는다. 점검 쿼리(개수만): `select count(*) from execution_artifacts a join execution_steps s on s.id = a.step_id where s.state = 'called' and not exists (select 1 from sources x where x.kind = 'execution' and x.user_id = a.user_id and x.external_id = a.step_id::text)`.
- 앱 디코딩: 이 값(`execution` · `executed` · `agent`)을 모르는 앱 빌드는 receipt가 붙은 할 일의 상세와 원문 목록을 읽지 못한다. 실행은 운영자 계정만(`execution_actors`)이라, 켜기 전에 운영자 앱을 이 값을 아는 빌드로 올린다.

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
- 예약: `begin_call`이 승인/Auto 확인 뒤, intent + lease와 같은 트랜잭션에서 계정 행을 `for update`로 잠그고 단계 추정치(`estimate_credits`)가 가용 잔액과 run의 남은 예산(`budget_credits - (예약 - 해제)`) 안이면 예약한다. 모자라면 gate `insufficient_credit` · `hold_reason='credit'`, 지급으로 풀리지 않는 서버 쪽 문제는 `hold_reason='blocked'`(gate: 요율 없음 `no_rate`, 추정치 없는 초안 `no_estimate`, 이미 닫힌 예약 `reservation_closed`). 단계는 `prepared`에 남는다. 추정치 0인 계획 단계는 예약하지 않는다. 같은 단계의 재시도는 열린 처음 예약을 그대로 쓴다.
- 정산: 내부 효과 단계는 `complete_internal_step`이 `called` + 산출물 + 원가 행 + 정산을 한 트랜잭션에서 한다(lease 소유자만). 정산 = 확정된 청구 대상 원가 합계(그 호출의 모든 시도, 형식 오류로 다시 물은 시도 포함) × 예약 때 요율(`credit_rates`, `c3-v1`: 1 크레딧 = $0.001), 올림, 예약 상한 안. 남은 예약은 해제한다. 끝내지 않은 단계(부르는 중 · 다시 준비 · 결과 불명)는 정산하지 않는다.
- 미확정(A46): 청구 대상 시도 하나라도 비용을 모르면, 또는 초안 단계인데 청구 대상 원가 행이 없으면 정산하지 않고 예약을 둔다. 0원으로 처리하지도, run이 끝났다고 해제하지도 않는다. `reconcile_usage`가 비용을 확정하면(sweep의 generation 조회) 그때 정산한다. 원가 행 하나씩 RPC 한 번에 확정한다.
- 해제: run이 끝나거나(`done` · `failed` · `stopped`), 끝난 run에서 부르던 · 결과 불명이던 단계가 나오면 트리거가 `release_run_credits`를 부른다: 부르지 못했거나 실패한 단계의 예약은 해제, 끝낸 단계는 정산, 부르는 중 · 결과 불명은 둔다. 함수는 run 행을 먼저 잠가(step → run → 계정) 멈추기와 단계 종료가 겹쳐도 뒤에 commit하는 쪽이 해제한다. 드물게 Postgres가 교착을 감지해 한쪽을 되돌린다(40P01, 멈추기 vs 같은 run의 재시도 `begin_call`): 실행기는 stop route · `begin_call` · `complete_internal_step`을 포함한 RPC를 40P01이면 다시 부른다(되돌려지면 단계는 그대로라 안전하다, `src/lib/execution/deadlock.ts`, 실제 교착은 `tests/pg/execution-locks.test.ts`). sweep은 보조 안전망으로 `credit_open_ended_runs()`가 고른 run마다 `release_run_credits(run)`을 RPC 한 번씩 부른다(한 트랜잭션에서 여러 run을 부르지 않는다).
- 원가(`execution_usage`, A51): OpenRouter 시도마다 한 행(generation id unique, 모델 · 토큰 · `cost_usd`, `confirmed | unconfirmed`)이고 사용자 청구와 따로 둔다. 청구 대상(`billable`)은 초안 단계를 끝낸 호출에서 응답을 받은(generation id나 비용이 있는) 시도뿐이고 서버가 정한다. 계획 단계 · 실패 · 응답 없이 다시 부른 시도(`record_usage`, 단계를 내보내기 전에 부른다) · 응답을 받지 못한 시도는 플랫폼 원가다(id 없는 행은 운영자가 정할 때까지 미확정).
- 산출물(`execution_artifacts`): 단계 하나에 초안 하나, 앱이 RLS로 읽는다. 본문은 `retain_until`(기본 90일, D9a-1이 정함)이 지나면 `purge_expired_artifacts`가 비운다. 원장 · 계정 · 요율 · 원가는 클라이언트가 읽지 못한다(잔액은 U2 PR6의 `GET /api/v1/credits` 합계). 같은 GET이 Usage & Credits 화면 숫자도 준다(U2 Mac PR1, `store.ts` `loadCreditDetails` · `credit-details.ts`): 열린 예약이 끝내지 않은 단계(`prepared` · `calling`)에 있는 run 수 `running_runs`, 끝낸 초안인데 원가가 미확정이라 정산을 미룬 예약 `settling`(A46: 단계 수 · 크레딧 · 할 일 id), `?since=` 이후 정산 합계 `used`(없으면 UTC 이번 달 1일, 형식 오류 · 미래 · 1년 넘게 전은 400), 전체 스위치가 열렸는지 `accepting_runs`, 초안 예약 `draft_estimate_credits`.
- 실행의 글(처리방침 D9a-1 5장, `20261024000000_execution_text_retention.sql`): 요청(`execution_runs.request`) · 계획이 준 지시(`execution_steps.args.brief`) · 초안의 받는 사람 후보(`receipt.to`) · 되묻는 질문(`receipt.question`)은 저장한 뒤 `EXECUTION_TEXT_RETENTION_DAYS`(90일, `src/lib/retention.ts`)에 지우고, 그때 실행 중이면 끝나는 대로 지운다(2026-10-03 사용자 결정). 매일 retention cron이 `purge_expired_execution_text`로 run을 만든 시각(`execution_runs.created_at`)이 기준 시각보다 이른 끝난 run(`done` · `failed` · `stopped`)의 글을 지운다: 만든 뒤 90일과 끝난 때 중 늦은 쪽(다음 날 정리까지 하루 안)이다. 지시 · receipt는 run을 만든 뒤에 쓰이므로(멈춘 뒤 늦게 오는 응답 · readback 포함) 만든 시각으로 세도 쓴 뒤 90일보다 늦게 남지 않는다: run이 그때 끝나 있으면 그 정리에서, 열려 있거나 부르는 중 · 결과 불명인 단계가 남았으면 끝나는 대로 지운다(늦게 쓴 글은 90일보다 일찍 지워질 수 있다). 요청은 빈 문자열로, 나머지는 키를 빼고, 지운 시각을 `execution_runs.text_purged_at`에 적는다. 끝 상태는 다시 열리지 않고 단계도 붙지 않는다는 것에 기댄다: 끝난 run을 다시 열거나 단계를 붙이는 함수를 더하면 이 정리를 함께 고친다(지금 `execution_skip`이 run을 `running`으로 되돌리는 것은 `begin_call`이 열린 run을 잠근 뒤에만이다). 끝나지 않은 run(막힌 run 포함)과, 끝났어도 부르는 중 · 결과 불명인 단계가 남은 run은 건드리지 않는다(계획 · 초안 단계가 요청 · 지시를 다시 읽는다). 오래 막힌 run은 런북 9-4로 멈추고, 멈추면 다음 정리에서 지운다. id · 상태 · 결과 · receipt의 다른 값(`decision` · `capability` · `model` · `prompt_version` · `error`) · 산출물 행(본문은 위 `retain_until`) · 원가 · 원장 · intent · 실행 이벤트는 남는다. 상태가 바뀌지 않아 이벤트 · 크레딧 해제 트리거는 돌지 않는다. 계획 동결 트리거(`execution_steps_replan`, 3장)는 이 함수가 정한 gate `retention` 안에서 `args`의 `brief`만 빠질 때 다시 계획하지도 막지도 않는다(끝난 run의 준비된 단계도 상태 · 버전 그대로). 외부 단계(U6a)가 `body` · `recipients` · 다른 `args`에 글을 담게 되면 그 글도 이 함수와 처리방침 5장에 더한다. 그때 외부 단계의 intent key(`execution_intents.intent_key`)는 정규화한 수신자 주소를 담고(4장), 결과 불명 단계가 남은 run은 그 단계가 나올 때까지 글을 지우지 않는다: 둘 다 함께 정한다.
- 원장 · 원가가 가리키는 run · step은 지울 수 없다(외래키 no action): 원장이 있는 사용자의 할 일을 하드 삭제하는 스크립트(심사 계정 `--reseed` 등)는 실패한다. 계정 삭제는 `auth.users` cascade로 같은 문장에서 함께 지운다.

## 13. 실행기 (U2 PR6)

`src/lib/execution/`. 2장 B2를 TS로 구현했다. 판단(스위치 · 허용 목록 · 크레딧 · CAS)은 SQL 함수에만 있고 실행기는 RPC를 부른다. 외부 효과는 없다: 유일한 효과는 내장 계획 · 초안의 AI 호출(내부 효과)이고, 외부 단계(`kind = 'external'`)는 준비도 부르기도 하지 않는다(발송은 U6a).

**켜기.** 세 겹이 모두 열려야 단계를 부른다.

| 겹 | 어디 | 꺼져 있으면 |
|---|---|---|
| 기능 플래그 `EXECUTION_ENABLED` | 환경변수 (`src/lib/env.ts` `executionEnabled`, `"true"`만 켬, 기본 꺼짐 · 개발 서버도) | `/api/v1/runs` · stop · credits · 자기 호출 404, sweep은 아무것도 하지 않고 200 `{ enabled: false }`. 그동안 lease가 끝난 단계와 그 예약은 다시 켤 때까지 그대로 남는다 |
| 실행 주체 허용 목록 | `execution_actors` (7장) | route 404(존재를 드러내지 않는다), 있던 run은 `begin_call`이 `hold_reason = 'actor'` |
| 차단 스위치 | `execution_controls` (6장) | 전체가 막혔으면 `POST /runs` 404(막힌 채 기다릴 run을 만들지 않는다) · sweep은 깨우지 않는다, 있던 run에 자기 호출이 와도 `begin_call`이 `hold_reason = 'blocked'` |

**입구와 흐름.** 함수 호출 한 번 = 단계 하나(`executor.ts` `advance`). 모든 입구가 `advance`를 지나고, 부르기 전 판단은 `begin_call` 하나가 한다.

| 입구 | route | 하는 일 |
|---|---|---|
| run 만들기 | `POST /api/v1/runs` (`maxDuration` 300) | 플래그 → 로그인 → 실행 주체 → 전체 스위치 → 본문(예산은 초안 예약 20 이상) → 동의(409) → 열린 내 Action(404) → `take_rate_limit('run_create')`(10분 10번, 429) → `create_run` → 202 `{ run }` → `after()`에서 첫 단계 |
| 자기 호출 | `POST /api/cron/execution-advance` (`CRON_SECRET`, `maxDuration` 300) | 단계를 끝내고 다음 단계를 붙인 함수가 부른다. 바로 202로 답하고 단계는 `after()`에서 돈다 |
| sweep | `GET /api/cron/execution-sweep` (Vercel Cron 1분, `maxDuration` 60) | 아래 sweep. 단계를 직접 돌리지 않고 이어 갈 run마다 자기 호출을 보낸다 |
| 멈추기 | `POST /api/v1/runs/:id/stop` | `stop_run`(5장, 처음 멈출 때 `stopped_at`). 이미 끝난 run은 그대로 200 |

- 세 겹이 모두 열려 있어도 run의 할 일이 닫혔으면(`done` · `dropped`) `begin_call`이 부르지 않고 run을 멈춘다(gate `action_closed`, 5장). 실행기는 다른 막힘처럼 `held`로 끝내고, 멈춘 run은 다시 깨워도 `closed`다.
- `advance`: 끝나지 않은 첫 단계 → `pending`이면 `prepare_step` → `begin_call(단계, lease 소유자, 버전)` → `ok`면 효과 → 다음 단계를 먼저 붙이고(`append_step`, seq + 1) → `complete_internal_step`(called + 산출물 + 원가 + 정산) → 초안 단계면 receipt(9장 `writeDraftReceipt`, 실패해도 단계는 끝낸 그대로). `begin_call`이 막으면(gate) 단계는 `prepared`에 남고 sweep이 다시 본다. lease 소유자는 함수 호출마다 새 값이다.
- 단계 차례: 계획 → 초안 → 계획 → 초안, 상한 4(`limits.ts` `MAX_STEPS`). 초안을 끝낼 때 다음 계획 단계를 붙여 남은 조각을 다시 본다(그 계획이 또 초안을 붙일 자리가 있을 때만). 계획 단계의 결정(`plan.ts`)과 run 결과:

| planner의 다음 단계 | run에 반영 | `outcome` |
|---|---|---|
| `draft{brief}` | 초안 단계를 붙인다 (`args.brief`, 예약 추정치 `DRAFT_ESTIMATE_CREDITS` = 20) | 계속 |
| `needs_connection{capability}` | 끝 (A39: 초안 단계 0 · 청구 0, 앞서 만든 초안은 그대로) | `needs_connection` |
| `ask_user{question}` | 끝 (질문은 계획 단계 `receipt.question`) | `needs_input` |
| `done` | 끝 | 앞선 초안이 있으면 `draft_ready`, 없으면 null |

- receipt(앱이 RLS로 읽는다, `contract.ts` `stepReceiptSchema`): 계획은 `decision` · `capability` · `question`, 초안은 `to`(모델이 자료에서 고른 받는 사람, 보내는 데 쓰지 않는다), 실패는 `error`. 산출물은 `execution_artifacts`(제목 · 본문 · 모델 · 프롬프트 버전). 글인 `question` · `to`와 요청 · `args.brief`는 저장한 뒤 90일, 그때 실행 중이면 끝나는 대로 지운다(12장 실행의 글): 실행기는 끝난 run의 글을 다시 읽지 않는다.
- 같은 계획 단계를 다시 부르면(lease 만료 뒤 다시 준비) 앞 시도가 이미 붙인 단계가 있을 수 있다: 모델을 다시 부르지 않고 그대로 끝내고 깨운다.
- 후속 계획(초안 뒤의 계획 단계)은 남은 조각을 다시 볼 뿐이라, 함수가 오류를 받으면(모델 · 자료 · 동의, 일시 오류 포함) 다시 하지 않고 이미 만든 초안으로 끝낸다
  (함수가 죽어 lease가 끝나는 경우는 다른 단계처럼 다시 준비되고, 세 번이면 SQL이 실패로 끝낸다): 계획 단계 `called`(`receipt.decision = 'done'`, `error`), run `done` · `draft_ready`. 초안을 받고 청구된 run을 실패로 두지 않는다.
- run 예산(`budget_credits`)은 초안 한 건의 예약(20) 이상만 받는다(작으면 초안을 한 번도 부르지 못하고 지급으로도 풀리지 않는다). 초안 둘을 맡긴 run은 첫 초안 정산 뒤 남은 예산이 다시 20 이상이어야 둘째 초안을 부른다(아니면 `hold_reason = 'credit'`으로 기다리고, 사용자가 멈춘다). 운영자만 풀 수 있는 hold(`actor` · `blocked`)에 오래 머문 run을 정리하는 일은 U2 PR8 런북에 둔다.
- 자료(`material.ts`): Action · 근거 인용 · 근거 원문을 service role로 읽고 user_id로 좁힌다. 원문의 서비스는 `sources.connection_id`가 가리키는 `connections.provider`에서 읽는다(sources에는 provider가 없다). 출처를 확인할 수 없는 원문(연결 행을 찾지 못함, 연결 없이 외부 id만 있음 = 연결이 지워진 연동 원문)은 근거째 뺀다. 실행 receipt(kind `execution`, 외부 id = 단계 id)는 출처가 분명한 내부 기록이라 넘기고 `context.ts`가 receipt로 빼고 센다(`excluded.receipts`, 9장). Slack 원문은 `context.ts`가 뺀다(provider · 지운 이유 · 링크).
- 동의: 모델을 부르기 직전마다 다시 확인한다(`withConsentGate`). 처리 도중 철회하면 단계 · run을 실패(`error: consent`)로 끝낸다. 후속 계획에서 철회했으면 아래처럼 `draft_ready`로 끝낸다.

**오류.** 내부 효과라 결과 불명 대신 다시 준비한다(3장 표).

| 경우 | 실행기 |
|---|---|
| 응답 없음 · 시간 초과 · 연결 끊김 · 공급자 5xx · 408 · 429 · 401 · 402 · 403(키 · 잔액 · 권한: 운영 설정 문제) · 형식 오류 · 자료 읽기 실패 | 원가를 먼저 남기고(`record_usage`) `mark_unknown` → 다시 준비(`attempt + 1`). 다시 준비가 2번을 넘으면 SQL이 `failed`(`retries_exhausted`). 다시 부르는 것은 sweep(1분)이다. 그래서 키 · 잔액 장애가 2분쯤 넘게 이어지면 그동안 부른 run은 실패한다(시도를 쓰지 않고 기다리는 hold 전이는 후속 마이그레이션) |
| 공급자의 확정적 거절(그 밖의 4xx, 추론 옵션 404) · 동의 철회 · Action이 지워짐 | 원가를 먼저 남기고 `settle_step('failed')` → run `failed`, 예약 해제(12장). 후속 계획이면 위처럼 `draft_ready`로 끝낸다 |
| 받은 뒤 쓰기(다음 단계 붙이기 · 결과 쓰기) 실패 | 3번까지 다시 쓰고, 그래도 안 되면 받은 시도의 원가를 남기고 오류(단계는 `calling`에 남고 lease 만료 뒤 다시 준비). 다시 쓴 쪽이 false면 앞 쓰기가 commit했을 수 있어 generation id가 있는 시도만 다시 남긴다(같은 id는 한 번) |
| lease를 잃은 뒤 받은 응답 | 다음 단계를 붙이지 않고(붙이기 전에 lease를 확인한다, `append_step`은 run만 본다) 결과를 버리고 원가만 플랫폼 원가로 남긴다(`record_usage`) |
| 원가 기록 실패 | 로그만 남기고 단계는 그대로 내보낸다(lease를 붙잡지 않는다) |
| 교착(40P01) | 모든 RPC를 3번까지(50ms 기준 두 배씩, 0.5–1.5배로 흩뜨려) 다시 부른다 (`deadlock.ts`) |

**lease와 실행 한도.** lease 330초 = 실행 route의 `maxDuration` 300 + 여유 30(`limits.ts` `LEASE_SECONDS`, `begin_call`의 리터럴과 같은지 `tests/db/execution-executor.test.ts`). 두 실행 route의 `maxDuration` 리터럴이 `EXECUTION_MAX_DURATION_S`와 같은지는 각 `route.test.ts`가 본다. 단계 하나의 최악은 LLM 한 번(90초 × 2시도, `llm.ts`)이라 한도 안이다.

**깨우기 (`wake.ts`).** 다음 단계는 `CRON_SECRET`을 실은 자기 호출로 새 함수 호출에 맡긴다. 주소는 요청 헤더에서 만들지 않는다(비밀값을 실어 보내므로): `EXECUTION_WAKE_ORIGIN`(https, http는 localhost만) → 운영 배포면 Vercel의 `VERCEL_PROJECT_PRODUCTION_URL` → 개발 서버면 localhost → 없으면 깨우지 않는다. 자기 호출이 실패해도 run은 DB에 남아 sweep이 이어 간다. 미리보기 배포는 주소가 없고 Vercel cron도 돌지 않아 첫 단계 뒤에 이어지지 않는다(실행은 운영 · 로컬 개발만). 운영 도메인에 Vercel Deployment Protection을 걸면 자기 호출이 막혀 sweep(1분)으로만 이어진다.

**sweep (`sweep.ts`).** 모두 다시 해도 같은 결과인 RPC라 겹쳐 돌아도 된다. 한 단계가 실패해도 다음 단계는 한다.

1. `sweep_expire`: lease가 끝난 `calling` → 내부 효과는 다시 준비(3장).
2. 미확정 원가: 하루 안의 `unconfirmed` 행(generation id 있음) 20개(청구 대상 먼저)를 generation 조회(`generation.ts`)로 확정 → `reconcile_usage`(행마다 RPC 한 번, 12장). 하루가 지난 행은 운영자가 정한다(U2 PR8 런북).
3. 보조 안전망: `credit_open_ended_runs(50)`이 고른 run마다 `release_run_credits` RPC 한 번(12장).
4. 이어 갈 run: 끝나지 않았고 부르는 중인 단계가 없는 run 20개(막히지 않은 run 먼저 오래된 순, 막힌 run은 뒤에 새것부터: 운영자만 풀 수 있는 오래된 hold가 쌓여도 지급으로 풀린 새 run이 굶지 않게)에 자기 호출. 다시 준비된 재시도 · 승인 대기가 여기서 이어진다(`begin_call`이 다시 본다). 막힌 run(`hold_reason` 있음)은 5분마다만(UTC 분이 5의 배수, `HELD_WAKE_EVERY_MINUTES`) 깨우고, 차단 스위치가 전체를 막고 있으면 아무도 깨우지 않는다(매분 함수 호출을 쓰지 않게). 실패한 단계가 있으면 sweep 로그를 오류로 남긴다.
5. receipt 보조 안전망: receipt가 없는 하루 안의 끝낸 초안 단계 20개(`SWEEP_RECEIPT_LIMIT`)에 receipt를 이어 쓴다(`writeMissingReceipts`, 9장). 깨우기 뒤에 해 쌓였을 때 깨우기를 늦추지 않고, 차단 스위치와 상관없이 한다(외부도 모델도 부르지 않는 기록이다). 결과의 `receipts` · `receipt_failed`.

**기록.** 상태 · hold가 바뀌는 모든 쓰기는 같은 트랜잭션에서 `execution_events`를 남긴다(7장 트리거). 로그에는 id · 상태 · gate · 숫자만 남긴다(요청 · 원문 · 초안 · 모델의 이유는 남기지 않는다): `execution_step`(단계마다, 끝낸 초안이면 `receipt`: written · exists · failed), `execution_sweep`(sweep마다), `execution_wake_failed` · `execution_advance_failed` · `execution_receipt_failed`(단계 id · 까닭 · DB 오류면 SQLSTATE).

**과금 경계 (A37 · A44).** 할 일 직접 추가 · 수정 · 완료와 원문 처리는 실행 · 크레딧을 확인하지도 부르지도 않는다(`src/lib/execution/boundary.test.ts`, eslint `no-restricted-imports`).

**테스트.** 실행기 × 운영 마이그레이션(PGlite, 가짜 LLM) `tests/db/execution-executor.test.ts`: 초안 1건의 산출물 · 원가 · 예약/정산/해제, 다시 물은 시도까지 더한 정산, 단계 상한, A39, 함수가 중간에 죽은 뒤 이어 가기와 늦은 응답(A18), 스위치를 끄면 세 입구 모두 `calling` 0(기준 9), 크레딧 부족 hold → 지급 뒤 이어 가기, 미확정 원가 보류(A46), 멈추기, Slack · 출처 모를 원문 제외, 초안마다 receipt · Action 그대로 · 다음 초안 자료에 receipt 없음 · sweep이 빠진 receipt를 한 번만 이어 씀(9장), 할 일을 끝내거나 지우면 세 입구 모두 다음 단계 0 · run 멈춤 · 예약 해제 · 부르던 단계는 끝까지(5장). 멈춘 시각과 `begin_call`의 할 일 확인 SQL은 `tests/db/execution-core.test.ts`, 크레딧 화면 숫자는 `tests/db/execution-credit-details.test.ts`(운영 `loadCreditDetails`를 PGlite에서 그대로). 순서 · 오류 처리 단위 테스트는 `src/lib/execution/*.test.ts`, route는 `src/app/api/v1/runs/**/route.test.ts` · `credits` · `cron/execution-*`.
