# Taskforce 0.2.0 런타임 계약 — 대화 · 업무 · 실행 · 에이전트 · 조율

2026-10-08 · 설계 계약 초안 · Claude Fable 5.1 독립 검토에서 작성 · 구현 시작 · 병합 · 운영 적용 지시 아님

[0.2.0 개발 계획](../../.omx/plans/taskforce-0.2.0-development-plan.md)의 D0–D7이 구현할 **인터페이스 · 상태 · 식별자 · 실패 처리**를 한 곳에 적는다. 제품 목표는 [제품 기획안](taskforce-0.2.0-product-plan.md), 유지할 기능 계약은 [제품 브리프 + 기능 계약](taskforce-product-brief-and-functional-contract.md) C01–C11, 실행의 기본 계약은 별도 worktree의 `docs/EXECUTION.md`(개발 계획 B16)다. 이 문서는 그 위에 0.2.0이 더하는 것만 적고, 이미 있는 규칙은 가리키기만 한다.

표기: `제안` = 이 검토의 설계 제안(이름 · 기본값은 D0에서 바꿀 수 있다). `기존` = worktree 코드에 이미 있다. `확정` = 사용자 결정 또는 CLAUDE.md 원칙. 코드 기준점은 개발 계획 2장의 약어(`root` · `mvp` · `handoff`)를 따른다. 운영 DB · 설치 앱과의 일치는 확인하지 않았다(13장 V01).

## 0. 지키는 원칙

1. 업무의 사실 값은 Claim → 진실 판정 → Action이다(CLAUDE.md 원칙 5). 대화 · 제안 · 에이전트 사건은 **Claim이 아니다**. 채택 · 검증을 거친 것만 Claim이 된다.
2. 외부를 부르기 전에 의도를 commit하고, 결과를 모르면 다시 부르지 않고 결과 불명으로 둔다(`EXECUTION.md` 머리말). 에이전트 지시 · 메일 발송 · 후속 연락 모두 이 규칙 안에 있다.
3. 함수 호출 한 번 = 단계 하나, lease 330초(`EXECUTION.md` 2 · 3장). 몇 시간 걸리는 원격 작업은 단계가 아니라 **사건으로 이어 받는 객체**로 둔다(5장).
4. 모델은 다음 행동 · 답변 · 맥락 선택을 고르고, 계정 격리 · 권한 · 승인 · 예산 · 중복 · 상태 버전 · 중단 · 외부 효과 기록은 코드가 지킨다(개발 계획 11장 표).
5. 새 표는 `user_id` + RLS `owner_all` + 부모와의 `(id, user_id)` 복합 FK를 따르고 `tests/db/`에 RLS 테스트를 둔다(CLAUDE.md). 기존 객체로 표현되면 새 표를 만들지 않는다(1장).

## 1. 객체 소유권 — 무엇이 어디에 사는가

| 개념 | 저장 객체 | 상태 축 | 재사용/신규 | 비고 |
|---|---|---|---|---|
| 업무(사용자가 이루려는 결과) | `actions` | open / done / dropped + 작업 상태(to_do · in_progress · done) | 기존 | 회의 · 메일에서 온 약속과 대화에서 채택한 목표가 같은 표다(R8) |
| 대화에서 채택한 목표 | `actions` + `sources`(kind `note`, 채택한 발화 한 줄, 링크 `taskforce://conversations/<id>#<message>`) + origin `user` Claim + `user_created` 이벤트 | 위와 같음 | 기존 경로 재사용 | 실행 receipt가 `sources` kind `execution` + `taskforce://artifacts/…`를 쓰는 선례(`EXECUTION.md` 9장)와 같은 방식. 채택 전 발화는 Claim이 아니다 |
| 업무 간 의존 · 외부 대기 · 후속 연락 예약 | `action_dependencies` `제안` | open / satisfied / cancelled / unobservable / superseded | 신규(기존 Plugin 계획 11장이 제안한 최소 구조) | `action_links`(외부 객체 매핑)와 구별. 3장 |
| 실행 run · step · 승인 · intent · 이벤트 | `execution_runs` · `execution_steps` · `execution_approvals` · `execution_intents` · `execution_events` | `EXECUTION.md` 3장 | 기존 | 0.2.0은 열 · 종류 값만 **additive**로 더한다(4장) |
| 산출물 | `execution_artifacts` | 보관 기간(`retain_until`) | 기존 + kind 값 추가 | 초안 · 검토 판정 · 에이전트 결과 참조 · 발송한 본문 스냅샷 |
| 검토(AI 검토 · 도구 검증) | `execution_steps` kind `review` + receipt(판정) + `execution_artifacts` kind `review` | 단계 상태 | 기존 표 + 종류 추가 | 6장 판정 스키마 |
| 사용자가 쓰는 에이전트 연결 | `connections`(provider = adapter id) + `connection_secrets` | active / error / revoked / reauth | 기존 | contract의 provider enum 확장은 V10 |
| 에이전트 세션 binding | `agent_sessions` `제안` | bound / unreachable / closed | 신규 | 세션은 run보다 오래 산다 |
| 에이전트 원격 작업 | `agent_tasks` `제안` | 5장 상태 머신 | 신규 | 단계 lease와 분리된 장시간 객체. 사건은 새 표가 아니라 기존 `execution_events`(type `agent`)에 남긴다 |
| 공유 자원 잠금 | `execution_resource_locks` `제안` | 보유 / 만료 | 신규 | 7장. `begin_call` 안에서 확인 |
| 대화 · 메시지 · 제안(proposal) | `conversations` · `conversation_messages` `제안` | 2장 | 신규 | 질문 · 답을 저장하지 않는다는 기존 안내(개발 계획 B15)는 D0에서 처리방침과 함께 바꾼다 |
| 능동 제안 | `suggestions` `제안` | open / accepted / snoozed / dismissed / expired | 신규 | Action으로 만들면 노이즈(R5)라 별도 |
| 개인 선호 | `user_preferences` `제안` | 유효 / 철회 | 신규 | 사실(Claim) · 권한(정책)과 분리 |
| 필요한 사용자 결정 | 서버 계산 목록 `pending_decisions` `제안` | 계산값 | 신규 표 없음 | 승인 대기 단계 · needs_input run · 에이전트 질문 · 확인 요청 Action · 열린 제안 · 막힌 의존을 한 목록으로(6장) |
| 복귀 요약(떠나 있던 동안 바뀐 것) | `action_events`의 `user_seen` 이후 + `execution_events` + `conversations.last_read_at` 이후 | 계산값 | 기존(`handoff` 20261025 `user_seen`, `changed.ts`) | 새 표 없음. V04 |
| 지표 | `metric_events` + `action_events` | — | 기존 + type 값 추가(마이그레이션) | 개발 계획 D7·A43 |

## 2. 대화 · 의도 · 지시 대상

### 객체 `제안`

- `conversations(id, user_id, title, created_at, last_message_at, last_read_at, archived_at, text_purged_at)`.
- `conversation_messages(id, conversation_id, user_id, seq, role in ('user','assistant','event'), client_message_id, text, refs jsonb, intent jsonb, created_at)`. `unique (conversation_id, client_message_id)`로 같은 제출을 두 번 저장 · 실행하지 않는다(A03 · D1).
  - `refs`: 이 메시지가 가리키거나 만든 것. `{action_ids[], run_ids[], artifact_ids[], suggestion_ids[], dependency_ids[], proposal{id, kind, payload_hash, state}}`. 서버가 쓴다. 모델 출력의 id를 그대로 믿지 않고 번호(A1 · S1) 방식으로 받아 서버가 대응시킨다(`pipeline/ask.ts` 선례).
  - `intent`: `{kind, confidence, judge_version}`. 아래 의도 분류의 결과와 근거.
  - `role = 'event'`: run · 에이전트 사건 중 사용자가 알아야 할 것만(질문 · 결과 · 실패 · 결과 불명 · 중단 확인 · 결정 필요). 진행 중 heartbeat는 넣지 않는다.
- 글 보관: 제품 기획안 3.2의 제안값(30일)을 따르되 D0에서 처리방침과 함께 확정한다(V08). 지울 때 `text`만 비우고 행 · `refs`는 남긴다(`sources.raw_text` 정리와 같은 모양).
- 대화 삭제: 메시지 글을 비우고 행은 남긴다. 채택으로 만든 Action과 그 `note` 원문은 사용자 소유라 남는다(원문 삭제는 Action 삭제의 일부). 명시 선호의 `source_message_id`는 null이 되고 값은 남는다.
- 상한 `제안`: 사용자 메시지 4,000자(현 Ask 500자는 질문용. 위임 지시는 길다). 모델에 넣는 창은 최근 20개 메시지 + 고정 참조(`refs`)에 연결된 Action의 현재 값. 넘치면 요약하되 **잘랐다는 사실을 응답에 적는다**. 조용히 잘라 다른 뜻으로 실행하지 않는다(D1).

### 의도 분류 `제안`

의도는 Jev `choice`로 가른다(CLAUDE.md: 선택지 고르기는 Jev). 생성 모델이 의도를 함께 적어도 코드는 Jev 답과 아래 규칙으로만 분기한다.

| kind | 뜻 | 대상 필요 | 쓰기 |
|---|---|---|---|
| `lookup` | 사실 조회(“남은 일이 뭐야”) | 아니오 | 아니오 |
| `consult` | 상담 · 추천(“하면 어떨까”) | 아니오 | 아니오 |
| `adopt` | 직전 제안 채택(“그렇게 해”) | 예(proposal) | 예 — Action 생성 또는 run 생성 |
| `instruct` | 새 수행 위임(“작성해줘”, “이 세 건 진행해줘”) | 예 또는 새 Action | 예 — run 생성 |
| `modify` | 진행 중 수행 · 산출물 수정(“가격은 빼줘”) | 예(run/artifact) | 예 — 지시 버전 올림(5장) |
| `answer` | Taskforce · 에이전트의 질문에 답 | 예(question) | 예 — 답 전달 |
| `stop` | 중단 | 예(run) | 예 |
| `preference` | 선호 저장(“앞으로 이 고객에게는”) | 범위 | 예 — `user_preferences` |
| `organize` | 이슈 정리(“#139 Launch로 옮겨줘”, “#141 지워줘”, “#144를 #139에 합쳐줘”) | 예(칩 · 글의 #번호 · 프로젝트 이름) | 이동 · 빼기는 대상이 정해지면 바로(멤버십), 삭제 · 병합은 확인 카드(제안) 뒤에 — OA D4c-2 |
| `other` | 그 밖 | — | 아니오 |

임계값 `제안`(`src/lib/pipeline/intent.config.ts`, 판정 설정 `judge.config.ts`의 0.8 선례): 확신 ≥ 0.8 → 그대로. 0.5–0.8 → `lookup` · `consult`는 그대로 답하고, 쓰기 의도는 한 가지를 묻는다. < 0.5 → 묻는다. 어떤 의도든 **쓰기는 대상이 정해진 뒤에만** 한다. 한 발화에 조회와 위임이 섞이면 읽기 부분은 답하고 쓰기 부분은 아래 대상 규칙을 거친다(기획안 3.1).

### 지시 대상(referent) 규칙 `제안`

쓰기 의도의 대상은 순서대로 하나만 고른다. 제목 유사도만으로 고르지 않는다.

1. 요청의 명시 참조(앱이 보낸 `refs`: 선택된 Action · run · 산출물, 또는 글 안의 분명한 지칭).
2. 같은 대화의 **직전 assistant 메시지**가 낸 열린 proposal 또는 question.
3. 이 대화에 연결된(`refs`) 열린 run 또는 Action이 **하나**뿐일 때 그것.
4. 그래도 둘 이상이면 후보 ≤ 3개를 들어 한 번 묻는다. 묻는 동안 아무것도 쓰지 않는다.

정한 대상은 메시지 `refs`에 남겨 “그렇게 해”가 무엇을 가리켰는지 뒤에 확인할 수 있게 한다(A34).

### 제안(proposal)과 채택 `제안`

- assistant 메시지는 `refs.proposal`을 하나 가질 수 있다: `{id, kind in ('create_action','run','modify','stop','preference','move','delete','merge'), payload_hash, state in ('open','adopted','superseded','dismissed')}`. `move`(불확실한 이동을 묻는 글) · `delete` · `merge`(확인 카드)는 OA D4c-2다: `content.asks`는 각각 `adopt` · `confirm` · `confirm`이고, 묻고 난 다음 답을 위해 `organize`(정리가 모자란 것을 한 번 물음, 한 라운드)가 더해졌다. `payload_hash` = (종류, 대상 Action id들과 각 `version`, 병합이면 남는 쪽 id)의 hash — 제목 · 숫자는 넣지 않는다.
- 제안은 Action · run이 아니다. `adopt`가 오면 그때 만든다. **채택은 proposal id로 멱등**이다: 같은 제안을 두 번 채택해도 Action · run은 하나다(A41).
- 같은 대화에서 새 proposal이 나오면 앞의 열린 proposal은 `superseded`다. 다른 대상이 명시되면 열린 proposal은 그대로 두되 3번 규칙의 후보에서 뺀다.
- 채택한 목표는 1장 표의 경로(Action + `note` 원문 + origin `user` Claim)로 저장한다. 사용자가 말한 내용은 사용자 Claim이 근거다(CLAUDE.md 원칙 2).

### 응답의 근거 구분 `제안`

응답 스키마 `{text, segments[], citations[], refs}`에서 `segments[].tier`는 10장의 신뢰 등급(T1 확인 사실 · T2 사용자 발화 · T3 실행 결과 · T4 에이전트 주장 · T5 제안/가정)이다. 모든 문장에 배지를 붙이지 않고(기획안 3.1), 앱은 등급이 다른 구간만 구별해 보인다. 기존 `/api/v1/ask`는 그대로 두고 대화는 `/api/v2/conversations/...` 계열이다(개발 계획 D1).

### run과 대화의 연결 `제안`

- `execution_runs`에 `conversation_id` · `message_id`(nullable)를 더한다. run이 어느 발화에서 시작됐는지 남기고, run의 중요한 사건은 그 대화에 `event` 메시지로 들어온다.
- 하나의 대화가 여러 Action · run을 가질 수 있고, 하나의 Action이 여러 대화에서 다뤄질 수 있다. 대화 수 · 세션 수와 업무 수를 같다고 가정하지 않는다(기획안 2장).

## 3. 업무 · 목표 · 의존 · 외부 대기

### 업무와 목표

- 업무 = `actions`. 대화에서 말한 목표도 채택되면 같은 표다. “목표 3건”은 Action 3개다. 묶음 객체(프로젝트 · 그룹)는 0.2.0에 만들지 않는다. 필요하면 `scope_summary` 글과 `action_dependencies`로 표현한다.
- 독립적으로 완료 근거를 갖는 조각(예: 화면 개선안, 영상 시안)은 각각 Action이다. 한 Action 안의 수행 · 검토 · 수정은 run · step이다. “동시에 진행되는 독립 작업 2개”는 서로 다른 Action의 run이 시간상 겹치는 것이다.
- 기한: 외부에 약속한 기한은 `actions.due_at`(Claim으로만 바뀐다, TRUTH_RULES 규칙 0). 내부 실행 목표 시각은 `execution_runs.target_at` `제안`(nullable)이며 Claim이 아니다. **AI가 자기 계획으로 `due` Claim을 쓰지 않는다.**

### `action_dependencies` `제안`

```
action_dependencies(
  id, user_id, action_id,                       -- 기다리는 쪽 Action
  kind in ('needs_action','needs_artifact','needs_external'),
  depends_on_action_id null,                    -- needs_action
  depends_on_artifact_id null,                  -- needs_artifact
  external jsonb null,                          -- needs_external: {counterpart, what, channel: {provider, thread_id}}
  group_key text, relation in ('all','any'),    -- 같은 group_key 안 AND/OR
  state in ('open','satisfied','cancelled','unobservable','superseded'),
  satisfied_by_source_id null,                  -- 충족 근거(원문 · receipt)
  -- 후속 연락 예약 (needs_external만, 개발 계획 D6)
  next_check_at, observe_until, max_contacts int, contacts_made int default 0,
  stop_condition jsonb, policy_version int,
  created_at, updated_at
)
```

- 순환(`A→B→A`)은 쓰기에서 거절한다(검증 계획 A53). 하나가 충족돼도 `relation='all'`의 나머지가 남으면 후속을 시작하지 않는다. `cancelled`는 `satisfied`가 아니다.
- 관찰 실패 · 접근 상실은 `unobservable`이며 미충족 확정이 아니다(C05 · 검증 계획 A57).
- 후속 연락 회차 키 = (dependency id, `contacts_made + 1`). 이 키가 발송 단계의 intent key에 들어가 같은 회차를 두 번 보내지 않는다(`EXECUTION.md` 4장 회차 규칙). 회차는 사용자의 명시 재발송 또는 허용된 다음 회차에서만 늘고 모델은 늘리지 못한다.

### 영향 범위(blast radius) `제안`

- run R의 실패 · 결과 불명은 R의 Action과, 그 Action(또는 산출물)을 `needs_action` · `needs_artifact`로 기다리는 Action에만 영향을 준다. 그 밖의 Action · run은 계속 간다(A30).
- 영향받는 Action은 자동 취소하지 않고 `막힘(blocked_by)`으로 보인다. 그 Action의 `due_at`이 긴급 창(12장) 안이면 즉시 결정 요청, 아니면 일일 묶음.

## 4. 실행 run · step 확장 — additive 목록

현재 값(`handoff` `20261021000000_execution_core.sql`, `limits.ts`): `execution_runs.goal in ('draft')`, `execution_steps.kind in ('plan','draft','external')`, `outcome in ('draft_ready','needs_connection','needs_input')`, `hold_reason in ('blocked','actor','needs_connection','credit')`, `execution_artifacts.kind in ('draft')`, `MAX_STEPS = 4`, 외부 단계는 실행기가 `busy`로 두고 부르지 않음, 정책은 사용자당 1행(`execution_policies.mode` · `auto_recipients`). D0에서 이 값을 다시 읽어(V02) 아래를 **기존 값을 모두 포함하는 CHECK 제약 교체**(새 값만 추가)로 작성한다. 기존 `draft` run의 동작은 바뀌지 않아야 한다(A42, A29 fixture 결과표 유지).

| 대상 | 추가 값 / 열 `제안` | 이유 |
|---|---|---|
| `execution_runs.goal` | `agent`(사용자 에이전트 위임) · `send`(D5) · `followup`(D6 후속 연락) | 검토는 goal이 아니라 단계다 |
| `execution_steps.kind` | `agent_dispatch`(외부) · `agent_message`(외부: 답변 · 지시 변경) · `agent_cancel`(외부) · `review`(내부: AI 검토) · `check`(내부: 도구 검증, 읽기) · `send`(외부) · `observe`(내부: 회신 조회) | `effect_class`는 괄호 안. 외부 상태를 바꾸는 것은 모두 외부 효과라 intent · 표식 · readback을 따른다 |
| `execution_tools` 행 | `('agent:<adapter>','dispatch','external')` · `(…,'message','external')` · `(…,'cancel','external')` · `('taskforce','review','internal')` · `('taskforce','check','internal')` · `('gmail','send','external')` · `('gmail','observe','internal')` | 목록 밖 도구는 `begin_call`이 막는다(기존 `tool` gate) |
| `execution_controls` 행 | `('provider','agent:<adapter>', true)`로 **막힌 채** 시작 | 닫힌 쪽 시작(`EXECUTION.md` 6장) |
| `execution_runs` 열 | `conversation_id` · `message_id` · `agent_session_id` · `directive_version int default 1` · `target_at` · `acceptance jsonb` | 2 · 5 · 6장 |
| `execution_runs.outcome` | `needs_capability`(미지원 동작) · `review_failed`(검토 한도 소진) · `agent_done`(에이전트 결과 검증 통과) | 미지원을 성공처럼 보이지 않게(R9) |
| `execution_runs.hold_reason` | `resource`(공유 자원 잠금) · `agent_unreachable` | 7장 · 5장 |
| `execution_artifacts.kind` | `review` · `agent_result` · `message` | 검토 판정 글, 에이전트 결과 참조(URL · 경로 · 커밋 · 요약), 발송 본문 스냅샷 |
| `execution_artifacts` 열 | `directive_version int` · `result_revision int` · `attribution in ('confirmed','unconfirmed')` · `superseded_at timestamptz null` | 옛 지시 · 미귀속 · 늦은 결과를 새 표 없이 표시한다(5장) |
| `execution_events` | `type`에 `agent` 추가, 열 `external_event_id` · `external_seq` · `directive_version` · `payload jsonb`(글 없음), `unique (run_id, external_event_id) where type = 'agent'` | 에이전트 사건 저장 · 중복 방지를 기존 이벤트 표로 한다(5장). 질문 · 결과 글은 `agent_tasks.pending_question` · 산출물에만 둔다 |
| `limits.ts` | goal별 단계 상한: `draft` 4(기존), `agent` 12, `send` 4, `followup` 3 | agent = dispatch 1 + 메시지 왕복 ≤ 3×2 + 검토 ≤ 2 + 계획 단계. 상한은 비용 · 무한 반복 방지. 바꾸려면 상수와 테스트를 함께 |
| 정책 | `execution_connection_policies(user_id, connection_id, mode, allowed_tools text[], allowed_targets jsonb, standing_budget_credits, version)` `제안` | C03 “연결별” 정책. 기존 사용자 정책은 기본값으로 남긴다. 승인 hash의 정책 버전에 연결 정책 버전도 넣는다. **OA D3c-2 Q2: 이 표는 v1 connections FK라 0.2.0 에이전트 판정에는 사용하지 않는다. `execution_policies.mode` + registry 등급 + DB gate만 적용하고 연결별 정책은 0.2.x로 남긴다** |
| 동시성 한도 | 세 가지를 나눈다. ① 실행 동시성 = 사용자당 동시에 `calling`인 비용 단계(모델 · 에이전트 호출) 3. ② 살아 있는 외부 작업 = 실행 중이거나 실행 가능성이 남은 원격 작업 5(아래). ③ 대기 보관 = 승인 · 질문 · 회신 대기 run에 실행 동시성 한도를 적용하지 않으며, 30일 뒤 정리를 제안한다. Action당 열린 run은 intent가 다를 때만 2 | 대기 기록만으로 독립 작업을 막지 않는다(A45). 읽기 전용이어도 모델 등 유료 호출은 ①에 포함한다. 저장량·조회 빈도는 별도 서비스 한도를 적용한다. `limits.ts` 상수 |

②에는 `dispatched` · `accepted` · `running`과 실행 여부가 불명인 `unreachable`을 센다. `awaiting_answer`는 adapter가 해당 작업의 실행·과금 대기를 확인한 경우에만 제외한다. 질문하면서 다른 작업을 계속하거나 상태를 관찰할 수 없으면 외부 작업 자리를 유지한다. 답변·수정 후 재개할 때는 ①②와 예산을 다시 검사한다. 승인·외부 회신을 기다리는 기록만으로 자리를 차지하지 않되, 실제 원격 실행을 대기로 가장해 한도를 우회하지 않는다.

intent key(`EXECUTION.md` 4장 (Action id, 공급자, 도구, 목적, 정규화한 대상, 회차))의 대상은 종류별로: `agent_dispatch` = 세션 id(없으면 workspace id), `agent_message` = question id 또는 `directive_version`, `send` = 정규화한 수신자, `followup` = 3장의 회차 키. 같은 대상에 같은 목적의 두 run이 동시에 서면 하나만 `calling`으로 간다(기존).

## 5. 에이전트 adapter 계약

### capability 서술자 `제안`

서버 registry에 adapter마다 한 개. **값은 D0에서 실제로 확인한 증거와 함께 채운다**(V06). 확인하지 못한 항목은 `unsupported`로 둔다.

```ts
type AgentCapability = {
  adapter: string;                                   // "agent:<이름>"
  transport: "remote_api" | "local_bridge";
  session: { list: boolean; attach_existing: boolean; create: boolean; workspace_scoped: boolean };
  dispatch: { ack_level: "transport" | "agent"; max_instruction_chars: number };
  events: "push" | "poll" | "none";                  // 진행 · 질문 · 결과를 받는 방식
  question: { receive: boolean; answer: boolean };
  cancel: "confirmed" | "requested_only" | "unsupported";
  resume: "supported" | "unsupported";
  enforcement: {                                     // 권한 경계마다 실제로 막는 통로와 D0 실측 여부 (D4A 실제 정책 gate)
    approval_gate: Boundary;    // Manual: 승인 전 쓰기를 막는다 (공식 도구 승인 콜백 · 쓰기 금지 권한 모드 등)
    target_scope: Boundary;     // Auto/Full: 허용한 대상 · 작업 밖 쓰기를 막는다 (작업공간 격리 · 대상 목록 · 도구 제한 등)
    revocation: Boundary;       // 철회 · 중단 뒤 새 쓰기를 막는다 (권한 모드 변경 반영 · 확인되는 중단 등)
    budget: Boundary;           // 외부 비용 상한. 쓰기를 켜는 조건이 아니라 표시 · 한도 조건
  };
  cost: "observable" | "estimated" | "unknown";
  artifacts: Array<"files" | "diff" | "url" | "text">;
};
type Boundary = { channel: string | null; verified: boolean; evidence?: string };   // verified는 D0 통제 테스트에서 실제로 막힘을 본 것만 true
```

쓰기를 켜는 조건은 **동작과 모드마다 적용되는 권한 경계가 모두 `verified`**일 때다. 하나라도 아니면 그 모드의 쓰기 도구를 `execution_tools`에 넣지 않아 `begin_call`이 막고, 그 adapter는 읽기 전용 관찰 + 지시 전달 등급이다. 이 등급의 결과는 수행 성공으로 세지 않는다(개발 계획 D4A 실제 정책 gate, A26 · A44).

| 동작 | 켜는 조건(모두 필요) |
|---|---|
| 쓰기를 포함한 `dispatch` · `message` — Manual | `approval_gate.verified` ∧ `revocation.verified` |
| 쓰기를 포함한 `dispatch` · `message` — Auto/Full | `approval_gate.verified`(규칙 밖 예외의 승인용) ∧ `target_scope.verified` ∧ `revocation.verified` |
| `cancel` | 현재 권한 안에서 지원되는 중단 통로(`confirmed` 또는 `requested_only`). 후자는 요청만 기록하고 확인 전 중단 성공으로 표시하지 않음 |
| 읽기 전용 관찰 · 지시 전달 | 계정·자료 접근과 전송 동의 필요. 지시가 실행을 유발할 수 있으면 위 쓰기 조건 적용. 관찰만으로 수행 성공을 세지 않음 |

`budget`만 확인된 adapter는 쓰기 0이다(예산 상한은 대상 · 도구 · 철회를 증명하지 않는다). 프롬프트에 범위를 적는 것은 통로가 아니다. 검증은 D4A gate의 통제된 테스트로 한다: Manual 승인 전 쓰기 시도, Auto/Full 범위 밖 쓰기 시도, 철회 뒤 쓰기 시도가 **각각 실제로 막히는 것**을 보고 `evidence`에 남긴다.

### 세션 binding `제안`

```
agent_sessions(id, user_id, connection_id, external_session_id, workspace_ref, display_name,
  status in ('bound','unreachable','closed'), bound_action_id null,
  last_event_seq bigint, last_seen_at, created_at)
```

- 같은 이름의 다른 계정 · 작업공간은 다른 `connection_id` · 다른 세션이다. run은 `agent_session_id`로 어느 세션에 보냈는지 들고, 앱은 대상을 드러낸다(D4A 1).
- 미지정이면 허용된 후보에서 서버가 고르되(역량 · 자료 접근 · 연속성 · 예산) 고른 이유를 run receipt에 적고 사용자가 바꿀 수 있다. 같은 세션이 다른 run을 진행 중이면 자원 잠금(7장)에 걸린다.

### dispatch 묶음(context bundle) `제안`

```
{ taskforce_task_id, marker, directive_version, expected_result_revision,
  goal, acceptance: [{id, text, check: 'tool'|'model'|'user', required}],
  constraints: { scope, forbidden[] },
  materials: [{ref, version, hash, tier}],          // 10장 신뢰 등급
  open_questions[], permissions: { mode, allowed[], forbidden[] } }
```

- 전체 대화 이력은 기본으로 보내지 않는다(D4A 2). 묶음의 hash를 단계 `args.bundle_hash`에 남겨 stale 판단에 쓴다.
- Slack 원문은 넣지 않는다(`context.ts`의 기존 규칙, Slack D3). 표식(marker)에는 수신자 · Action id · 본문을 넣지 않는다(`EXECUTION.md` 4장).

### 원격 작업 `agent_tasks` `제안`

```
agent_tasks(id, user_id, run_id, step_id, agent_session_id, external_task_id,
  state in ('dispatched','accepted','running','awaiting_answer','completed','failed','cancelled','unreachable'),
  directive_version int,
  result_revision int default 0,                        -- 검증된 현재 결과 회차. 사건 도착만으로 올리지 않는다
  expected_result_revision int default 1,               -- dispatch/수정 요청에 실어 보낸 다음 결과 회차
  pending_question jsonb null,                          -- {question_id, text, context_version, asked_at}
  last_live_state text null,                            -- unreachable 직전 상태. reconcile이 ‘변화 없음’이면 이 상태로 복원
  cancel_requested_at null, last_event_seq bigint, last_seen_at, result_refs jsonb, created_at, updated_at)
```

전이:

| 전이 | 누가 | 조건 |
|---|---|---|
| (단계 `agent_dispatch` `calling`) → `dispatched` | 실행기 | intent · lease commit 뒤 adapter에 묶음 전송 |
| `dispatched` → `accepted` | 사건 `accepted` 또는 `ack_level=agent` 응답 | 단계는 여기서 `called`(receipt: `{ack_level, external_task_id}`). **접수 ≠ 완료** |
| `accepted` → `running` | 사건 `progress` | |
| `running` → `awaiting_answer` | 사건 `question` | `pending_question` 기록 → 6장 라우팅 |
| `awaiting_answer` → `running` | 단계 `agent_message`(답) `called` | intent key에 question id |
| `running` → `completed` (result_revision n) | 사건 `completed` | 완료 사건은 **검증 전**이다. 귀속(아래 사건 봉투)이 `confirmed`일 때만 서버가 `review` · `check` 단계를 run에 붙인다(`append_step`, V03). `unconfirmed`면 readback 단계 또는 사용자 확인 |
| `running` → `failed` | 사건 `failed` | 끝. 산출물이 있으면 보존 |
| `completed` → `running` | 검토 `fail` → 단계 `agent_message`(수정 요청) `called` | 같은 `directive_version`. 수정 요청에 `expected_result_revision=n+1`을 연결하고, 그 회차에 귀속된 다음 `completed`만 새 결과로 검토한다. n의 산출물은 보존(`superseded_at`) |
| 열린 상태 → `unreachable` | heartbeat 누락(12장) 또는 adapter 오류 | 실패가 아니다. 직전 상태를 `last_live_state`에 적고 재접속 reconcile을 기다린다 |
| `unreachable` → `last_live_state` / `completed` / `failed` / `cancelled` | reconcile 사건 | 끊긴 동안의 사건을 `external_event_id`로 중복 없이 재생한 뒤 그 결과 상태. 재생할 사건이 없으면 `last_live_state`로 복원 |
| 열린 상태 → `cancelled` | 사건 `cancelled` 또는 `cancel='confirmed'` 응답 | 확인 전까지는 `cancel_requested_at`만 있고 상태는 그대로. 앱은 “중단 요청됨”(C04) |
| 끝 상태(`completed` · `failed` · `cancelled`) | 뒤에 오는 다른 끝 사건 | 현재 지시·수정 회차와 provider 순서/조회 결과를 대조한다. 상충하면 임의로 덮어쓰지 않고 결과 불명으로 후속 쓰기를 보류한다(아래) |

- 단계 `agent_dispatch`가 `calling`에서 함수가 죽으면 lease 만료 → `unknown_outcome`(외부 효과, `EXECUTION.md` 3장). readback = adapter에 `taskforce_task_id`/표식으로 작업 존재를 조회. 찾으면 `called` + `agent_tasks` 생성, 못 찾으면 사용자가 정한다. **다시 dispatch하지 않는다**.
- 에이전트 사건은 Action 필드를 직접 바꾸지 않는다(원칙 5). `completed` → 검토(6장) → receipt → Claim origin `execution`(`EXECUTION.md` 9장 선례)만 Action에 닿는다.

### 사건 봉투(inbound) `제안`

```
{ adapter, session_id, external_task_id, event_id, seq?: number,
  type in ('accepted','progress','question','artifact','completed','failed','cancelled','unreachable','reconcile'),
  directive_version?: number, result_revision?: number, payload, observed_at }
```

- 저장: 사건은 기존 `execution_events`에 `type='agent'`로 남긴다(4장의 열 추가). `payload`에 글을 담지 않는다. 질문 글은 `agent_tasks.pending_question`, 결과 글은 산출물에만.
- 중복: `unique (run_id, external_event_id) where type='agent'`. 같은 사건은 한 번만 적용한다.
- 순서: `seq`가 있으면 그 순서. 없으면 `observed_at`은 **도착 순서일 뿐** 어느 지시의 결과인지의 증거가 아니다.
- 결과의 귀속(attribution): 해당 계정·세션·작업뿐 아니라 **그 산출물**이 현재 지시와 `expected_result_revision`에 속한다는 증거가 필요하다. ① 사건의 지시/결과 회차, ② 해당 회차의 요청 hash·표식과 산출물의 연결, ③ provider readback의 산출물 버전 대조 중 지원되는 방식으로 확인한다. 작업이 현재 지시로 실행 중이라는 사실만으로 과거 산출물을 최신 결과로 바꾸지 않는다. 증명하지 못하면 `attribution='unconfirmed'`로 보존하고 현재 결과의 검토·전달을 보류한다(A35).
- 종료 사건은 도착 순서로 승자를 정하지 않는다. provider 순서와 요청 회차가 확인된 오래된 사건만 `late`로 기록한다. 같은 회차의 완료·실패·취소가 상충하면 기존 기록을 보존하고 `agent_tasks`의 대조 상태를 `execution_events.payload`에 남겨 readback으로 확인할 때까지 후속 검토·쓰기를 보류한다. 중단 요청 또는 run `stopped` 뒤 도착한 결과는 기록하되 자동으로 다음 단계를 시작하지 않는다.
- 검토 실패 후 수정 요청은 `expected_result_revision`을 올려 요청에 실어 보낸다. 그 회차로 귀속된 새 결과를 한 번 적용할 때만 `result_revision`을 갱신한다. 이전 결과가 새 event id로 재전송돼도 새 수정 결과로 세지 않는다(A38).
- 다른 세션의 사건은 그 세션의 `agent_tasks`에만 간다. 세션 혼선 0(A24).
- `question`의 `directive_version`이 run의 현재 값보다 낮으면 **오래된 질문**이다: 답하지 않고 `stale_question` 사건으로 기록, 현재 지시를 다시 보내는 `agent_message`를 붙인다(One의 “같은 질문인지 확인” 원리, 벤치마크 10장).

### 질문 · 답변 라우팅

6장 결정 라우팅 표를 따른다. Taskforce가 답할 수 있는 것은 `agent_message` 단계로 보낸다(외부 효과, intent key = question id → 같은 질문에 두 번 답하지 않는다). 사용자 결정이 필요하면 `pending_decisions`에 들어가고 run은 `waiting_approval`이 아니라 `running` 그대로다(에이전트가 기다리는 것은 run의 승인이 아니다). 에이전트 고유의 승인 요구는 두 가지로 가른다. ① 공식 승인 콜백(capability `approval_gate.channel`)으로 온 요구에는 사용자의 기존 Manual/Auto/Full 정책을 **그대로 적용해 답한다**: Auto/Full 규칙 안이면 허락, Manual이거나 규칙 밖이면 거절 또는 보류하고 사용자 결정으로 올린다. 이것은 위임 정책의 적용이지 우회가 아니다. ② 그 밖의 방법(화면 자동 조작, 권한 모드 임의 변경, 정책 밖 권한 허락)으로 에이전트의 승인 관문을 넘지 않는다(A23). 어느 경우에도 사용자 정책이 허락하지 않은 권한을 Taskforce가 대신 만들어 주지 않는다.

### 지시 변경(directive) `제안`

- 사용자의 `modify`는 run의 `directive_version`을 1 올리고, 변경분만 담은 `agent_message` 단계를 붙인다. 살아 있는 작업이 있으면 새 `dispatch`를 만들지 않는다(중복 실행 금지, A24).
- 결과 사건 · 산출물은 만들어진 `directive_version`을 단다. run의 현재 값보다 낮으면 `execution_artifacts`에 `superseded` 표시로 보존하고 **현재 결과로 검토 · 전달하지 않는다**. 앱은 “이전 지시의 결과”로 보인다(A35).
- 지시 변경이 수신자 · 대상 · 범위를 바꾸면 기존 승인은 무효다(승인 hash에 bundle hash · directive_version 포함).

### 중단 · 재개

- 사용자 Stop → `stop_run`(기존)으로 run은 `stopped`. 살아 있는 `agent_tasks`가 있으면 `agent_cancel` 단계를 **run이 stopped여도** 한 번 시도한다(`begin_call`은 stopped run을 거절하므로 cancel은 별도 경로 `cancel_agent_task` RPC `제안` — V03에서 설계). 확인 사건 전까지 “중단 요청됨”.
- `resume='unsupported'`인 adapter는 끊긴 뒤 이어 가지 못한다. 그 사실을 run outcome `needs_capability`로 드러내고 새 dispatch는 사용자 지시에서만 만든다.

### 로컬 bridge와 서버 책임 `제안`

| 책임 | 서버 | Mac bridge(앱 안 또는 helper) |
|---|---|---|
| 정책 · 승인 · 예산 · intent · 상태 · 사건 저장 · 결정 목록 | ○ | × |
| 로컬 에이전트와의 전송(CLI · 로컬 API · 파일) | × | ○ |
| heartbeat(12장 주기), 로컬 outbox(끊긴 동안 받은 사건 보관, TTL 12장) | 수신 · 판정 | 송신 · 보관 |
| 비밀값 | adapter 토큰은 `connection_secrets` | 자기 기기 토큰만. 다른 연결 · 사용자 범위 없음 |
| Mac 종료 · 절전 | 세션 `unreachable`로만 표시. 원격 작업이 멈췄다고 가정하지 않는다 | 재시작 시 outbox 재생 + `reconcile` |

서버는 bridge가 끊겼을 때 그 에이전트를 계속 제어할 수 있다고 가정하지 않는다(개발 계획 11장). `remote_api` adapter는 bridge 없이 서버가 직접 부른다.

### 미지원 동작

adapter가 `unsupported`를 돌려주면 단계는 `failed`(receipt `error: unsupported:<op>`), run은 `needs_capability`로 끝낸다. 자체 LLM 생성이나 프롬프트 복사로 대체해 통과시키지 않는다(R9, A22).

## 6. 검토 · 결정 라우팅

### 검토 기준은 수행 전에

- run의 `acceptance`(4장)는 dispatch 전에 채운다: 사용자 지시 + 적용 범위의 명시 선호(8장) + Action의 현재 값. Manual에서는 사용자에게 보이고, Auto/Full에서는 기록만 한다(허용된 자동 실행에 승인을 더하지 않는다, R6).
- 기준에는 `check` 종류가 있다: `tool`(빌드 · 테스트 · 링크 도달 · 규격 등 코드로 확인) > `model`(생성 모델 또는 Jev `noul` “기준을 충족하는가”) > `user`(사람만 판단).

### 검토 단계와 판정 `제안`

- `review` 단계 입력 = 산출물(최신 `directive_version`) + `acceptance`. 출력 receipt:

```
{ artifact_id, directive_version, round,
  results: [{criterion_id, result: 'pass'|'fail'|'unverifiable', evidence_ref, note}],
  overall: 'pass'|'fail'|'unverifiable', checker: {kind: 'tool'|'model', version} }
```

- `overall = pass`는 **필수 기준이 모두 `pass`**일 때만. `unverifiable`은 `pass`가 아니다(A31).
- 검사기 독립: `tool`을 먼저, `model` 검사는 생산자(에이전트 또는 초안 모델)와 다른 프롬프트 버전 · 설정을 쓰고 생산자의 추론 글을 넣지 않는다(Jev state에 추출기 추론을 넣지 않는 TRUTH_RULES 선례).
- 왕복: `fail`이면 `agent_message`(수정 요청, 실패한 기준만) → 다음 결과 → `review`. 횟수 상한 `제안` 2회(`limits.ts`). 넘으면 run outcome `review_failed`로 끝내고 두 판정을 `pending_decisions`로 올린다. 검토 1회 비용 상한은 12장.
- 사용자가 검토를 맡겼으면(Auto/Full 또는 지시) 정상 왕복에서 사용자를 부르지 않는다(R11). `user` 종류 기준이 있으면 그 기준만 사용자에게 간다.

### 결정 라우팅 표

| 사용자만 결정 | Taskforce가 위임 범위 안에서 결정 |
|---|---|
| 방향 · 취향(둘 다 기준을 충족하는 안 중 선택) | 확인된 사실(T1) · 이 run의 대화에서 사용자가 말한 것(T2) · 적용 범위의 명시 선호로 답할 수 있는 질문 |
| 외부와의 새 약속(상대에게 말할 기한 · 금액 · 범위) | 내부 실행 순서(외부 기한은 건드리지 않음) |
| 정책 · standing 예산 밖 지출, 새 수신자 · 대상, 권한 확장 | 수정 왕복(횟수 상한 안) |
| 허용 범위 밖 변경, 아직 허용되지 않은 비가역 변경, 해당 provider가 명시적으로 사람 확인을 요구하는 동작 | 허용 범위 안의 수정·검토·후속 연락. 이미 정해진 대상·내용·한도와 Auto/Full 정책에 포함된 외부 행동은 그 정책에 따라 진행 |
| 공식 승인 콜백으로 온 요구 중 Manual이거나 정책 규칙 밖인 것 | 공식 승인 콜백으로 온 요구 중 Auto/Full 규칙 안인 것(기존 정책 적용) |
| 정책이 Manual인 모든 외부 변경 | Auto/Full 규칙 안 외부 변경 |

가역 · 비가역은 복구 경로의 존재로 가르되, 비가역이라는 이유만으로 유효한 기존 위임·승인을 다시 요구하지 않는다. 예를 들어 허용된 수신자·내용·횟수의 후속 메일은 기존 정책을 적용한다. 새 대상·범위·예산이거나 provider의 별도 사람 확인 요구가 있으면 그 경계에서 결정을 요청한다. 에이전트의 승인 관문을 콜백 밖의 방법으로 넘지 않는다(5장).

### `pending_decisions` 계산 목록 `제안`

- 원천: 승인 대기 단계(`execution_steps.needs_approval` + `prepared`), run `outcome=needs_input` 또는 `review_failed`, 결과 귀속·종료 사건 대조 실패 중 사용자 판단이 필요한 항목, `agent_tasks.pending_question`(사용자 몫), `actions.needs_confirmation`, 열린 `suggestions`, 긴급 창 안 `blocked_by` 의존.
- 항목: `{kind, action_id, run_id?, step_id?, question_id?, version, urgent, created_at}`. `version`은 승인 hash · question id · proposal id라 **다른 기기에서 처리되면 목록에서 사라진다**(C10).
- 묶음: 같은 `(action_id, kind)`는 한 묶음. `urgent`(다른 작업을 막거나 `due_at`이 긴급 창 안)는 일일 묶음을 기다리지 않는다(A32 · A33). 읽음은 결정이 아니다.

## 7. 동시 업무 조율

- 병렬: 서로 다른 Action의 run은 독립이다(기존 run 모델 + 1분 sweep). 한 run의 대기(승인 · 질문 · 자원)가 다른 run을 멈추지 않는다. 한도는 4장 동시성 한도.
- 공유 자원 `제안`: `execution_resource_locks(user_id, resource_key, run_id, step_id, acquired_at, expires_at)`. 단계는 `args.resources[]`에 쓰려는 자원을 선언한다(정규화: `connection_id + 외부 객체 id` / `repo + branch` / `파일 경로` / `agent_session_id`). `begin_call`이 잠금을 함께 잡고, 다른 run이 들고 있으면 gate `resource_busy` → `hold_reason='resource'`, 단계는 `prepared`에 남아 sweep이 다시 본다. **조용히 덮어쓰지 않는다**(A37). TTL은 내부 효과면 lease, 에이전트 세션이면 `agent_tasks`가 끝날 때까지.
- 자리와 우선순위: 실행 자리(4장 ①)는 비용이 드는 단계에만 쓰고, 대기 기록 자체는 자리를 쓰지 않는다. 원격 작업의 자리는 4장의 실행 가능성 기준으로 별도 계산한다. 준비된 단계가 자리를 다투면 (1) `due_at`이 긴급 창 안인 Action, (2) 다른 Action의 의존을 푸는 run, (3) 가장 오래 기다린 준비 단계 순으로 깨운다(sweep의 ‘막힌 run은 뒤로’ 규칙과 같은 방식). 외부 기한을 AI가 바꾸지 않는다. 대기 보관 기한(12장)이 지난 run은 자동 중단하지 않고 정리를 제안한다.
- 예산: run `budget_credits`(기존) · 사용자 일일 AI 원가(`ai_spend_budget`, 기존) · 연결 정책 standing 예산(4장) · 선택적 Action 상한. 소진은 그 run만 `hold_reason='credit'`(기존). 비용을 관찰할 수 없는 adapter는 `cost: unknown`을 사용자에게 보이고 무제한 실행으로 약속하지 않는다(D4A 권한 · 비용).
- 영향 범위는 3장.

## 8. 능동 제안 · 개인 선호

### `suggestions` `제안`

```
suggestions(id, user_id, kind, subject jsonb,            -- {action_id|dependency_id|run_id|source_id}
  dedup_key text, reason_refs jsonb,
  state in ('open','accepted','snoozed','dismissed','expired'),
  snooze_until, dismiss_scope in ('this','topic') null, urgent boolean,
  created_at, shown_at, decided_at,
  unique (user_id, dedup_key))
```

- `dedup_key` = kind + subject + 계기 revision(원문 revision · run id · 의존 상태). 날짜가 아니다: 같은 계기는 하루가 지나도 다시 제안하지 않는다(A08).
- 상한: 비긴급 묶음 하루 1회 · 3개(기획안 3.3 실험값). `urgent`(실행 실패 · 막힌 결정 · 긴급 창 기한)는 상한 밖. `dismiss_scope='topic'`은 같은 kind + subject의 재제안을 막는다.
- 제안 채택은 2장 proposal 채택과 같은 멱등 규칙이다. 제안만으로 Action을 만들지 않는다(R5).

### `user_preferences` `제안`

```
user_preferences(id, user_id, scope_kind in ('global','counterpart','project','action'), scope_ref text null,
  key, value jsonb, origin in ('explicit','inferred'), source_message_id null,
  valid_from, revoked_at, version, created_at)
```

- `explicit`만 `acceptance` 기본값 · 답변 라우팅에 쓴다. `inferred`는 후보로 보이기만 하고 사용자가 확인하면 `explicit`가 된다(기획안 3.2).
- **어느 origin도 `execution_policies` · 연결 정책 · 승인 범위를 바꾸지 못한다**(코드 경계, 테스트). 반복 행동은 권한을 넓히지 않는다(C05 · 검증 계획 A63).
- “이번만”은 선호가 아니라 그 run의 지시다: run의 `acceptance` · dispatch 묶음의 constraints에 들어가고 `user_preferences`에 쓰지 않는다. “앞으로”만 선호이고 말한 범위(`scope_kind`)를 가진다. 충돌하면 더 좁은 범위 · 더 최근 명시가 이긴다.

## 9. 사람과의 커뮤니케이션(D5/D6) 연결점

- 발송: `EXECUTION.md` 8장의 Gmail 설계를 그대로 쓴다. 표식은 `X-Taskforce-Intent` 헤더, readback은 발송 전 `historyId`부터 `history.list` → `messages.get` 헤더 대조, 클라이언트 `Message-ID` · `rfc822msgid:` 검색은 쓰지 않는다(2026-10-02 dev 프로젝트 확인, 운영 프로젝트에서 재확인). 다시 설계하지 않는다.
- 발송 단계 수신자 출처(`user` · `source` · `tool_output` · `model`)와 허용 목록은 기존 7장 규칙. 회의 참석자 명단 · 에이전트 출력의 주소는 `user`가 아니다.
- 후속 연락 예약은 3장 `action_dependencies(kind='needs_external')`에 있고, 회차 키가 intent key에 들어간다. 회신 · 취소 · 중단 · 완료 뒤 깨어난 예약은 `begin_call`이 조건 상태(`satisfied` · `cancelled`)를 보고 거절한다(A15).
- 회신 관찰(`observe` 단계, 내부 효과): 발송 thread · 참여자 · RFC 헤더로만 연결하고 발견용 필터(B11)는 적용하지 않는다. 분류(OOO · 반송 · 거절 · 요구 변경 · 수락)는 Jev `choice`로 하고, 자동 응답은 수락이 아니다(A14). 수락은 의존 조건을 `satisfied`로, 요구 변경은 영향받는 run의 재평가 사건으로 간다.
- 발송한 본문은 `execution_artifacts(kind='message')`로 스냅샷을 남긴다(보관 기간은 산출물과 같다). 승인은 그 스냅샷의 hash에 묶인다(기존 승인 hash).

## 10. 사건 · 버전 · 중복 · 신뢰 — 식별자 요약

| 무엇을 막나 | 식별자 | 있는 곳 |
|---|---|---|
| 같은 메시지 두 번 저장 · 실행 | `client_message_id` | `conversation_messages` unique `제안` |
| 같은 제안 두 번 채택 | `proposal.id` | 메시지 `refs` `제안` |
| 같은 단계 동시 실행 | `execution_steps.version` CAS · lease | 기존 |
| 같은 목적 두 run | `intent_key` unique | 기존 |
| 바뀐 계획을 옛 승인으로 실행 | 승인 hash(+ bundle hash · directive_version) | 기존 + 확장 |
| 같은 에이전트 사건 두 번 적용 | `(agent_session_id, event_id)` unique | `agent_tasks` 사건 `제안` |
| 같은 질문에 두 번 답 | question id → intent key | `agent_message` `제안` |
| 옛 지시의 결과를 현재 결과로 | `directive_version` | run · 산출물 `제안` |
| 바뀐 원문으로 옛 계획 실행 | `sources.external_version` · Action `version` · 정책 `version` | 기존 |
| 같은 회차 재발송 | (dependency id, 회차) → intent key | `action_dependencies` `제안` |
| 버전 표시 없는 결과를 최신 결과로 | 귀속 조건(사건의 `directive_version` · bundle hash 되돌림 · readback) → `attribution` | 산출물 열 `제안` |
| 수정 요청 전 결과를 새 결과로 | `result_revision` | `agent_tasks` · 산출물 열 `제안` |

### 신뢰 등급(context tier)

| 등급 | 뜻 | Claim이 될 수 있나 |
|---|---|---|
| T1 확인 사실 | 원문 인용 · 출처 · 시각이 있는 Claim/Evidence, provider 응답 · readback | 이미 Claim |
| T2 사용자 발화 | 대화 메시지(이 run의 대화) | 채택될 때만(origin `user`) |
| T3 실행 결과 | receipt · 검토 통과 산출물 | origin `execution` |
| T4 에이전트 주장 | 검증 전 완료 보고 · 진행 메시지 | 아니오. 검토 뒤 T3 |
| T5 제안 · 가정 | assistant 제안, 모델 추론 | 아니오 |

dispatch 묶음 · 응답 segments · 검토 입력은 등급을 들고 다닌다. T4 · T5만으로 Action을 완료 · 변경하지 않는다(C04 · C07).

## 11. 실패 처리표

| 상황 | 처리 | 사용자에게 |
|---|---|---|
| dispatch 전송 뒤 ack 없음 | lease 만료 → `unknown_outcome` → readback(작업 존재 조회). 재dispatch 금지 | “전달 결과 확인 중” |
| bridge heartbeat 누락 | 세션 · 작업 `unreachable`. 실패 아님. 재접속 reconcile 대기 | “연결 끊김, 진행은 알 수 없음”, 다른 작업은 계속 |
| 오래된 지시의 질문 | 답하지 않고 기록, 현재 지시 재전송 | 보이지 않음(로그) |
| 버전 표시 없는 결과 도착 | `attribution='unconfirmed'` → readback 단계 또는 확인 요청. 현재 결과로 검토 · 전달 0 | “최신 지시의 결과인지 확인 중” |
| 검토 실패 → 수정 요청 → 새 결과 | 같은 `directive_version`, `result_revision` +1, 앞 결과는 보존 | 수정된 판정 결과 |
| 끝 사건 뒤의 다른 끝 사건(늦은 완료 · 늦은 취소) | 상태 유지, `late` 기록, 산출물은 `superseded_at` | run 이벤트에만 |
| 중복 · 역순 사건 | `event_id`로 무시 / `late` 표시 | 보이지 않음 |
| 중단 요청 뒤 확인 없음 | `cancel_requested_at`만, 상태 유지, 관찰 계속 | “중단 요청됨, 확인 전” |
| 검토 `unverifiable` | 통과 아님. 사용자 몫이면 결정 요청, 아니면 다음 왕복 | “확인하지 못한 기준” 목록 |
| 검토 횟수 소진 | `review_failed`, 두 판정 보존 | 선택지 + 근거 |
| 공유 자원 충돌 | `resource_busy` hold, sweep 재시도 | 보류 이유 |
| 예산 소진(작업 중) | 새 유료 단계만 hold `credit`. 살아 있는 에이전트 작업은 adapter의 `budget_cap`이 있으면 전달, 없으면 `cost: unknown` 표시 | 기존 산출물 유지 |
| 서버 함수가 dispatch와 `called` 사이에 죽음 | `EXECUTION.md` 3 · 4장 그대로(`unknown_outcome` → readback) | 위와 같음 |
| 에이전트가 범위 밖 외부 효과를 냄 | 사건은 기록, run은 새 쓰기 중단(`hold`), 사용자 결정. 되돌렸다고 표시하지 않음 | 발생한 효과와 선택지 |
| 사용자가 Action을 수동 완료(작업 중) | `begin_call` gate `action_closed` → run `stopped`(기존), `agent_cancel` 시도, 산출물 보존 | “수동 완료, 진행 중 효과 확인” |
| Mac 절전 · 종료 | bridge outbox 보관, 서버는 `unreachable`만 | 복귀 시 재생 결과 |
| adapter `unsupported` | 단계 `failed`, run `needs_capability` | 미지원 이유. 대체 생성 없음 |
| 대화 글 보관 만료 | `text` 비움, `refs` 유지 | “보관 기간이 지남” |

## 12. 기본값표 `제안`

모두 상수 또는 설정이며 이유를 함께 둔다. 바꾸면 상수와 테스트를 함께 바꾼다.

| 항목 | 값 | 이유 | 위치 |
|---|---|---|---|
| 의도 확신 임계값 | 0.8 / 0.5 | 판정 자동 반영 0.8의 선례와 같은 보정 철학 | `intent.config.ts` |
| 지시 대상 후보 상한 | 3 | 한 번에 고르기 쉬운 수 | 같은 곳 |
| 사용자 메시지 상한 | 4,000자 | 위임 지시는 질문(500자)보다 길다 | `contract.ts` |
| 모델 창 | 최근 20개 메시지 + 고정 참조 | 비용 · 요약 손실 균형 | `conversation.config.ts` |
| 대화 글 보관 | 30일(기획안 제안, D0 확정) | 원문 90일보다 짧게 두어 처리방침 부담을 줄임 | 처리방침 · retention |
| heartbeat | 30초, 3회 누락(90초) → `unreachable` | 함수 호출 비용과 감지 지연의 균형 | bridge · `limits.ts` |
| bridge outbox TTL | 24시간 | 하루 안 복귀를 가정, 넘으면 `unknown` | bridge |
| 경로 lease idle | 30분 | 턴 종료 뒤 해제, 다음 턴 `accepted`면 만료 시각을 비움(OA D3c-2) | `PATH_LEASE_IDLE_MINUTES` · `sweep_agent_path_leases` |
| agent goal 단계 상한 | 12 | dispatch 1 + 왕복 ≤ 6 + 검토 ≤ 2 + 계획 | `limits.ts` |
| 검토 왕복 상한 | 2 | 세 번째부터는 사람의 기준 판단이 필요할 확률이 높다 | `limits.ts` |
| 검토 1회 비용 상한 | 40 크레딧(초안 추정 20의 2배) | 검토 입력이 초안보다 크다 | `limits.ts` |
| 실행 동시성(동시 `calling` 비용 단계) | 사용자당 3 | 모델 등 유료 읽기 호출 포함. 단순 상태 조회는 별도 빈도 제한 | `limits.ts` |
| 살아 있는 외부 작업 | 사용자당 5 | 4장의 실행 가능성 기준. 확인된 실행·과금 대기만 제외하고 재개 때 다시 검사 | `limits.ts` |
| 대기 보관 기한 | 30일 | 대기 기록은 실행 동시성 한도에서 제외. 별도 저장량·조회 빈도 제한과 오래된 항목 정리 제안(자동 중단 아님) | `limits.ts` |
| Action당 열린 run | 2(intent가 다를 때만) | 같은 목적 중복 방지는 intent key가 한다 | `limits.ts` |
| 비긴급 제안 | 하루 1묶음 · 3개 | 기획안 3.3 실험값 | `suggestions.config.ts` |
| 긴급 창 | `due_at` 24시간 안 또는 다른 작업을 막음 | 일일 묶음까지 미루면 늦는 범위 | 같은 곳 |
| 후속 연락 | 최대 2회, 간격 2 영업일 | 재촉 부담(C06). 의존 조건마다 바꿀 수 있음 | `action_dependencies` 기본값 |
| 자원 잠금 TTL | 내부 = lease 330초, 에이전트 세션 = 작업 종료까지 | 7장 | `begin_call` |

## 13. D0에서 확인할 항목 — 통합 시점 검증(V01–V12)

코드는 읽기 전용으로 확인했으며 실행 검증·운영 확인은 하지 않았다. 코드·운영 상태 조사는 D0에서 읽기 전용으로 확인해 기준점 표에 기록한다. V06의 차단 증명은 별도 지정 테스트 환경에서 명시된 시험 범위로 실행하며 운영 변경 허가로 해석하지 않는다. 운영 DB 쓰기 · 마이그레이션 적용은 포함하지 않는다.

| ID | 확인할 것 | 왜 |
|---|---|---|
| V01 | 통합 기반 커밋(`mvp` 0c5775b7 / `handoff` 0a6f9d2f / `origin/main`)과 root dirty 변경의 관계. 어느 쪽을 0.2.0 기반으로 삼는지와 보존할 root 변경 목록 | 개발 계획 2장. 재구현 방지 |
| V02 | `execution_core` · `credits_artifacts` · `receipts` · `stopped_at` · `text_retention` 마이그레이션의 **현재 CHECK 값**과 함수 서명(`create_run` · `append_step` · `begin_call` · `stop_run`) | 4장 additive 목록의 정확한 base |
| V03 | `append_step`이 planner 외의 호출자(사건 처리기)에서 안전한지(run 상태 · seq 조건), `stop_run` 뒤 에이전트 cancel 경로를 어떻게 둘지 | 5장 사건 → 단계 추가, 중단 |
| V04 | `user_seen` 이벤트 · `changed.ts` · `notes_markdown`이 통합 기반에 있는지 | 복귀 요약 · 에이전트 맥락 재사용 |
| V05 | `metric_events.type` CHECK의 현재 값 목록 | 11장 새 이벤트 마이그레이션 |
| V06 | 첫 에이전트 capability 서술자(5장)를 **실측 증거**로 채움. `enforcement`의 `approval_gate` · `target_scope` · `revocation`은 각각 통제된 테스트에서 실제로 막힘을 본 것만 `verified`. 예산 상한은 쓰기 조건이 아님 | D4A 실제 정책 gate 선행, A44 |
| V07 | Gmail 프로젝트 B 현재 상태(개발 계획 B20), `gmail.send` 추가 시 검증 경로와 기간, Testing 시절 발급 토큰의 만료 규칙 | D5 외부 의존 |
| V08 | 대화 보관 기간 · 처리방침 · 법률 README(“질문 · 답 저장 안 함”) 수정 범위 | D1 활성화 전 조건(A16) |
| V09 | Vercel 플랜 · 함수 한도(300/800초) · cron 100개 한도가 지금도 유효한지 | `EXECUTION.md` 10장 ③ 재확인 |
| V10 | `contract.ts` `connectProviderSchema` enum에 에이전트 adapter를 어떻게 넣을지(enum 확장 vs 문자열 + registry) | Plugin 계획 7장의 enum 경고 |
| V11 | Swift 앱이 새 enum 값(step kind · outcome · hold_reason · artifact kind)을 모를 때 상세를 읽지 못하는지, 켜기 전 앱 배포 순서 | `EXECUTION.md` 9장 선례 |
| V12 | `execution_policies` 사용자당 1행에서 연결별 정책으로 가는 마이그레이션 경로와 기존 승인 hash 호환 | 4장 정책 |

## 14. 사용자 결정이 필요한 항목

- 첫 에이전트(개발 계획 D0 선택 기준 ①–⑤와 V06 결과를 보고).
- 대화 글 보관 기간(제안 30일)과 처리방침 문구.
- 연결별 정책(C03)을 0.2.0에 넣을지, 사용자 정책 1행으로 시작할지.
- 확장 Ask · 대화의 제공량과 과금 경계(무료 상담 vs 유료 수행).
- 12장 기본값 중 사용자 경험에 보이는 것: 제안 상한, 긴급 창, 후속 연락 횟수 · 간격, 검토 왕복 상한.
