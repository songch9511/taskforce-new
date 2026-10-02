# 실행 계약: 외부 효과는 한 번, 모르면 결과 불명

Taskforce가 사용자 대신 외부 상태를 바꾸는 실행기(메일 발송, Notion · GitHub 쓰기)의 규칙입니다.
U2(실행기)와 U6a · U6b(쓰기)는 이 문서를 계약으로 따릅니다. 규칙을 바꾸면 이 문서와 A29 fixture(11장)를 함께 고칩니다.

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
| **B2 Postgres 상태 머신** | run · step · approval · intent 행을 Supabase Postgres에 둔다. 함수 호출 한 번 = 단계 하나. commit 뒤 깨우기 + sweep | **A29 fixture 결과로 B2 채택** (11장, 이 문서와 같은 PR의 테스트) |
| B4 Supabase `pg_cron` + `pg_net` (선택 `pgmq`) | DB가 주기적으로 HTTP로 실행기를 깨운다 | 보조. 운영 Supabase에 셋 다 설치할 수 있지만 설치돼 있지 않다(2026-10-02 확인). sweep 주기가 분 단위로 부족할 때만 더한다 |
| B1 LangGraph | checkpointer가 그래프 상태를 보존 | 문서 비교만. interrupt 뒤 재개하면 그 node를 처음부터 다시 실행하므로 승인 전 부수 효과를 따로 막아야 한다. 그래프 상태와 run/step 상태가 이중이 된다 |
| B3 Vercel Workflow | 관리형 지속 실행 | 탈락. 처리방침은 Vercel이 정보를 "요청을 처리하는 동안"만 둔다고 약속한다(`docs/legal/privacy.ko.md` 수탁자 표). 실행 상태를 Vercel에 지속 보관하면 이 약속과 충돌한다 |

K2 실행 위치:

- 함수 호출 한 번이 단계 하나를 처리한다. 긴 업무 전체를 요청 하나나 `after()` 하나에 맡기지 않는다. 상주 worker는 두지 않는다(처리방침의 받는 곳이 늘어난다).
- 시간 한도: 저장소 설정의 최장 `maxDuration`은 300초다(`src/app/api/cron/sync/route.ts`, `src/app/api/v1/sources/route.ts`). 플랜이 실제로 허용하는 상한은 확인 대기(10장 ③). 300초를 넘는 단계는 쪼갠다.
- 깨우기: 상태를 commit한 뒤 `after()`(지금 `src/app/api/v1/sources/route.ts`가 쓰는 방식) 또는 인증된 자기 호출(`CRON_SECRET`, `src/lib/api/cron.ts`)로 다음 단계를 부른다.
- sweep: 깨우기를 놓친 run을 이어 간다. Vercel cron(`vercel.json`: 지금 `*/15` 동기화 · `7,37` 재처리)에 실행 sweep을 더한다. 주기는 U2에서 정한다.

## 3. 상태와 전이

run · step 상태는 Action 상태와 따로 둔다. 실행 결과는 receipt를 거쳐 Action에 반영된다(9장).

run: `queued → running ⇄ waiting_approval`, 끝 상태는 `done | failed | stopped`

| 전이 | 누가 | 조건 |
|---|---|---|
| `queued → running` | 실행기 (route · 자기 호출 · sweep) | 첫 단계를 준비했다 |
| `running → waiting_approval` | 실행기 | `begin_call`이 유효한 승인이 없다고 돌려줬다 |
| `waiting_approval → running` | route `POST /approvals/[id]` | 지금 계획의 hash에 묶인 승인을 기록했다 |
| `running → done` | 실행기 | 남은 단계가 없다 (모두 `called` · `skipped`) |
| `running → failed` | 실행기 | 단계가 `failed`다 |
| 끝나지 않은 상태 → `stopped` | route `POST /runs/[id]/stop` | 사용자가 멈췄다 (5장) |

step: `pending → prepared → calling → called | unknown_outcome | failed | skipped`

| 전이 | 누가 | 조건 |
|---|---|---|
| `pending → prepared` | 실행기 | 인자 고정, intent key 계산, 정책 평가(승인 필요 여부) |
| `prepared → calling` | 실행기, **`begin_call` 하나로만** | 5–7장 확인을 모두 통과. intent 행 + lease를 같은 트랜잭션에서 commit |
| `prepared → skipped` | `begin_call` | 같은 intent key를 다른 단계가 이미 가졌다 |
| `calling → called` | lease를 가진 함수 | 공급자 응답을 받아 receipt를 저장했다 |
| `calling → failed` | lease를 가진 함수 | 공급자가 확정적으로 거절했다 (예: 형식 오류 400) |
| `calling → unknown_outcome` | lease를 가진 함수(시간 초과 · 연결 끊김) 또는 sweep(lease 만료) | 다시 부르지 않는다 |
| `unknown_outcome → called` | sweep | readback이 표식을 찾았다 |
| `unknown_outcome → failed` | 사용자 | 사용자가 결과를 정했다. 다시 보내기는 새 회차다(4장) |

- 모든 전이는 CAS다: `where state = <이전 상태> and version = <읽은 버전>`, 성공하면 `version + 1`. 바뀐 행이 없으면 다른 함수가 먼저 했으므로 아무것도 하지 않는다. 같은 패턴이 이미 있다: `write_action`의 `p_expected_version`(`supabase/migrations/20261019000000_claim_state_write.sql`), 재처리의 `updateIfUnchanged`(`src/lib/sources/retry.ts`).
- lease: `calling`으로 갈 때 소유자 id(함수 호출 id)와 만료 시각을 적는다. 만료 = 최장 실행 시간 + 여유(fixture는 300 + 30초)라 살아 있는 함수의 lease는 만료되지 않는다. `calling → called`는 lease 소유자만 쓴다.
- 결과: 함수 종료 · lease 만료 · 중복 실행에서도 같은 단계의 외부 호출은 한 번이다(A18). 어느 지점에서 죽어도 DB만 보고 이어 간다. 메모리 checkpoint는 복구 수단이 아니다(A29).
- `unknown_outcome` 단계가 있는 run은 다음 단계로 가지 않는다.
- `called`는 공급자가 받았다는 뜻이지 목적 달성(상대가 받음 · 읽음)이 아니다. HTTP 200, `isError: false`, "완료" 문장만으로 목적 달성으로 보지 않는다(A16).

## 4. write-ahead intent

- intent key = (Action id, 목적, 정규화한 대상, 회차). 수신자는 소문자 · 공백 제거 · 중복 제거 · 정렬, Notion · GitHub는 객체 id로 정규화한다.
- `intents.intent_key`는 DB unique다. 수동 버튼과 자동 trigger가 같은 목적을 동시에 시작해도 한 단계만 `calling`으로 간다(A27). 다른 쪽은 `skipped`, receipt에 누구의 중복인지 적는다.
- 순서:
  1. intent 행 + `prepared → calling` + lease를 한 트랜잭션에 commit한다.
  2. intent key에서 만든 표식(8장)을 실어 외부를 부른다.
  3. `called` + receipt를 commit한다.
- 1과 3 사이에 죽으면 sweep이 lease 만료를 보고 `unknown_outcome`으로 옮긴다. 다시 부르지 않는다. 그 뒤 sweep마다 readback으로 표식을 찾는다.
- 회차: 같은 회차의 재시도 · 중복 동기화는 새 회차가 아니다. 새 회차는 사용자의 명시적 다시 보내기, 또는 미리 허용한 후속 규칙의 다음 발생(서버가 결정적 occurrence key로 한 번만 발행)에서만 생긴다. 모델은 회차를 늘리지 못한다. 앞 효과가 `unknown_outcome`이면 새 회차로 우회하지 않는다.
- 외부 호출 직전에 Action과 정책의 최신 버전을 다시 읽는다. 이미 외부에서 끝났으면(readback으로 확인) 부르지 않고 관찰로 반영한다.

## 5. 승인

- 승인 hash = (도구, 인자, 수신자(정규화), 본문 hash, 원문 revision, 정책 버전, 만료). 승인 행에 hash를 저장하고, `begin_call`이 지금 단계로 hash를 다시 계산해 같을 때만 통과시킨다. 하나라도 바뀌면 기존 승인으로는 실행 0이다(A13).
- 승인이 필요한 단계: Manual 모드, Auto/Full 규칙 밖, 수신자 · 대상이 사용자에게서 나오지 않은 단계(7장 불변식).
- 철회 · 만료된 승인은 무효다. 철회 뒤에는 이어서 실행(resume)해도 부르지 않는다.
- Review의 "내 일 맞음" 확인과 AI 처리 동의는 실행 승인이 아니다.
- 중단(stop)은 다음 단계만 막는다. 이미 `calling`인 호출은 되돌릴 수 없으므로 결과 확인(응답 · readback)을 끝까지 한다. 중단 요청을 받았다는 것이 원격 작업이 멈췄다는 증거는 아니다.
- `begin_call`은 run이 `stopped`면 거절한다. 단계를 읽은 뒤에 들어온 중단도 막힌다.

## 6. 차단 스위치 `execution_controls`

- DB 플래그 세 층: 전체(`global`) / 공급자별(`provider`, 예: `gmail`) / 모드별(`mode`: `manual` · `auto` · `full`). `auto`와 `full`을 끄면 "Manual만"이다.
- `begin_call` 안에서, `prepared → calling`과 같은 트랜잭션에서 확인한다. 해당 행 셋(전체 · 그 공급자 · 그 모드)을 `for share`로 잠그고 읽는다. 끄는 쪽의 `update`는 진행 중인 전이가 끝날 때까지 기다리고, 끈 뒤에 commit되는 전이는 없다.
- route · 자기 호출 · sweep 모두 `begin_call`만 지나므로 어느 입구로 와도 막힌다.
- 행이 없는 공급자 · 모드는 막힌 것으로 본다(닫힌 쪽). 새 공급자는 행을 추가해야 실행된다.
- 막힌 단계는 실패가 아니다. `prepared`로 남고, 다시 켜면 sweep이 이어 간다. 이미 `calling`인 호출은 끝까지 결과를 받는다.
- 끄기 · 켜기는 승인된 `db query`로 한다. 절차는 U2에서 런북(`docs/go-live/runbook.md`)에 쓴다.

## 7. 허용 목록

실행기에서 둘 다 확인한다.

1. 실행 주체: 건넴 전까지 운영자 계정만.
2. 발송 수신자 · 쓰기 대상: 시험 동안 허용 목록 안만.

**불변식: 원문 · 도구 출력에서 나온 수신자 · 대상은 Auto/Full 규칙을 자동으로 충족하지 못한다.** 규칙에 있는 주소라도 원문이나 도구 출력이 넣었으면 승인을 받는다. 정책 평가(준비 단계)가 승인 필요로 표시하고, `begin_call`이 수신자 출처를 다시 확인한다(준비 단계가 틀려도 막힌다).

## 8. 효과별 계약표

공통: 부정 readback이어도 비멱등 효과는 자동으로 다시 보내지 않고 `unknown_outcome`에 둔다. readback이 표식을 찾으면 `called`, 못 찾으면 사용자가 결과를 정한다.

| 효과 | 표식 | 재조회 (readback) | 남는 경쟁 |
|---|---|---|---|
| Gmail 발송 | intent key로 만든 클라이언트 `Message-ID` + `X-Taskforce-Intent` 헤더 | 발송 전에 기록한 `historyId`부터 `history.list`. 대체로 SENT `after:<t>` + `format=metadata`로 헤더 대조 | 헤더가 지워지면 제목 · 수신자 · 시간창으로만 찾는다. 같은 창의 수동 발송과 구분할 수 없다 |
| Notion 수정 | 값 설정은 멱등 | 페이지를 다시 읽어 값 비교 | 사람의 동시 편집은 마지막 쓰기가 남는다 |
| Notion 생성 | 표식 속성은 사용자가 동의할 때만 (사용자 DB 스키마를 바꾼다. DB 밖 페이지는 속성이 없다) | 부모 + 봇 작성자 + 생성 시각 창으로 query | 같은 창 · 같은 제목의 수동 생성 |
| GitHub 쓰기 | 본문 HTML 주석 표식 | 대상별 목록 (issue 댓글은 작성자 + `since`). search는 쓰지 않는다 (색인 지연, 분당 30회) | 같은 MCP 연결로 읽히는지 확인 전 (10장 ②) |

- Gmail 헤더 · `Message-ID`가 발송 뒤에도 남는지는 아직 확인 전이다. U0에서 dev 프로젝트 · 로컬로 시험하고, U6a에서 Testing 중인 Gmail 프로젝트 B(`docs/go-live/google-verification.md`)로 다시 확인한다.

## 9. CLAUDE.md 원칙과의 관계

- 실행 결과도 Claim → 진실 판정 → Action/Evidence를 거친다. 실행기는 Action 필드를 직접 쓰지 않는다(원칙 5).
- receipt(공급자 id · readback 결과)는 근거가 된다. 원칙 2는 지금 "원문 인용 구절 + 출처 링크"만 근거로 적으므로, receipt를 근거로 넣는 개정은 U2 PR에서 한다. receipt는 새 source kind로 기존 writer(`write_action`)를 지난다.
- 에이전트의 결정은 `origin=user`가 아니다. 사용자의 승인은 그 계획의 실행을 허락한 것이지 사용자가 값을 정한 Claim이 아니다.
- 모든 전이 · 승인 · 거절 · 중단은 이벤트로 남긴다(원칙 6). 운영 지표: `unknown_outcome` 수, 승인 요청 수(원칙 3: 확인 요청은 그 자체가 비용).
- 인스턴스 경합: 수집 쪽 병합 대기열은 메모리라 인스턴스 하나 안에서만 보장되고, 인스턴스 사이는 `write_action` 버전 확인이 막는다(`src/lib/sources/process.ts`). 실행 쪽은 메모리에 기대지 않고 intent unique + CAS로 막는다.

## 10. 확인 전 항목 (관문)

결과는 U0 다음 문서 PR에 적는다.

| 관문 | 확인할 것 | 안 되면 |
|---|---|---|
| ① 계획 생성 | ZDR 허용 목록 모델로 `completeJson`(`src/lib/ai/llm.ts`, `json_schema` strict)이 다음 단계 discriminated union 스키마를 받는지. 라우팅은 `data_collection: deny` · `zdr: true` · 목록 밖 fallback 금지(`src/lib/ai/providers.ts`)를 그대로 쓴다 | 허용 목록의 다른 모델. 조건을 풀어 성공시키지 않는다. `tool_calls`는 eval이 요구할 때만 |
| ② 원격 MCP | GitHub · Linear · Figma 원격 MCP가 제3자 서버 클라이언트(동적 등록 · 허용 목록)를 받는지, 같은 연결로 readback 경로가 읽히는지 | GitHub App, 또는 "Want this"로 내림 |
| ③ Vercel 플랜 한도 | 실제 `maxDuration` 상한, cron 최소 주기 | 단계를 더 쪼갠다. sweep 주기는 B4 |
| ④ Gmail 헤더 보존 | 클라이언트 `Message-ID` · `X-Taskforce-Intent`가 발송 뒤에 남는지 | 제목 · 수신자 · 시간창 readback만 쓰고, 남는 경쟁을 결과 불명 화면에 적는다 |

## 11. A29 fixture (실행 가능한 명세)

`tests/spikes/execution-a29.test.ts`, 드라이버 `tests/spikes/execution-driver.ts`. 테스트 안에서만 만드는 최소 스키마(runs · steps · approvals · intents · execution_controls + 외부 효과를 기록하는 가짜 공급자 원장)와 `begin_call` SQL 함수다. 마이그레이션이 아니고, U2가 만들 실행기도 아니다. "함수가 죽는다" = Driver 인스턴스를 버리고 새로 만든다.

| # | 사례 | 결과 |
|---|---|---|
| 1 | 승인 대기 중 죽음 → 새 인스턴스 | sweep이 승인 대기로, 승인 뒤 외부 효과 1 |
| 2 | 공급자가 받은 직후 · `called` commit 전에 죽음 | lease가 살아 있으면 그대로, 만료 → `unknown_outcome`. 음성 readback 재발송 0, 양성 → `called`. 효과 1 |
| 3 | 승인 철회 · 만료 | 효과 0 |
| 4 | 승인 hash 항목(수신자 · 본문 · 원문 revision · 정책 버전)이 바뀜 | 효과 0 |
| 5 | 스위치 전체 · 공급자 · Manual만 · 행 없음 × route · 자기 호출 · sweep | 효과 0, 다시 켜면 1. 단계를 읽은 뒤 끄면 0, `calling` commit 뒤 끄면 진행 중 1건만 |
| 6 | 같은 단계를 두 함수가 같은 버전으로 / 같은 intent를 두 run이 동시에 | 효과 1 |
| 7 | Auto 규칙 안 수신자가 원문 · 도구 출력에서 옴, 규칙 밖 수신자 | 승인 대기, 효과 0 (준비 단계가 틀려도 DB가 막는다) |
| — | 중단 | 진행 중 호출은 결과를 받고, 다음 단계 0 |

한계: PGlite는 연결이 하나라 트랜잭션이 실제로 겹치지 않는다. 동시성은 트랜잭션 경계(단계를 읽은 뒤 · `calling` commit 뒤)에 끼어드는 방식으로 보인다. `for share` 잠금과 동시 commit 경합은 U2에서 실제 Postgres(연결 둘)로 다시 시험한다. 허용 목록(7장 1 · 2), 실행 이벤트 행, `calling → failed`는 fixture에 없다(U2 · U6a).
