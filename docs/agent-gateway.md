# 에이전트 게이트웨이 (0.2.0 D1a–D1d) — 결정 기록과 위치

2026-10-13 · 구현 계획 D1a · 근거: Assistant 계약 v3 3.4 · 3.6 · 3.8 · 4.2, 런타임 계약 5장(`agent_tasks` · `agent_sessions` · 사건 봉투), 아키텍처 9.1(bridge), I16 · AC-20.
**1–6장은 D1a 당시 기록이다. 현재 턴 준비 경로는 8장(D1c-1)을 따른다.**
**D1a는 표 · 열 · 제약 · 인덱스 · RLS · 권한뿐이다. 에이전트를 실행하는 코드, route, gate, 앱 화면이 없다. 운영 DB 적용 전.** 이 문서는 "무엇을 만들었고, 무엇을 일부러 안 만들었고, 어디 있는가"만 적는다. 일반 규칙은 [FEATURE_MAP.md](FEATURE_MAP.md), 실행의 기본 계약은 [EXECUTION.md](EXECUTION.md), 같은 원칙의 앞 묶음은 `20261109000000_execution_additive_contract.sql`(C1)이다.

## 1. 한눈에

| 조각 | 위치 |
|---|---|
| 저장 계약 (표 4 · `execution_runs` 열 3 · `execution_events` 열 6 + type 값 1) | `supabase/migrations/20261113000000_agent_gateway_core.sql` |
| 값 상수 | `src/lib/execution/types.ts` `RUN_KINDS` · `src/lib/api/contract.ts` `agentTaskStateSchema`(`idle` 추가) · `agentSessionStatusSchema` |
| Swift 짝 | `apple/Packages/TaskforceKit/Sources/TaskforceKit/AgentBridgeContracts.swift` `AgentTaskState.idle` · `AgentSessionStatus` |
| 시험 | `tests/db/agent-gateway-core.scenarios.ts`(PGlite `.test.ts` + 실제 Postgres `tests/pg/agent-gateway-core.test.ts`, 경합은 실제 Postgres에만) |

## 2. 새 표 넷

넷 모두 `user_id` + RLS(`owner_all` 정책, 앱은 `select`만 · 쓰기는 서버(service role)만) + 부모와 `(id, user_id)` 복합 외래키다. 남의 행을 가리키지 못한다.

| 표 | 무엇 | 지킬 것 |
|---|---|---|
| `bridges` | Mac bridge 최소 identity. `device_ref`(기기 식별의 해시, 사용자당 유일) · `status`(`active` · `revoked`) · `capabilities`(bridge가 보고한 "설치돼 있고 이 버전" 값, JSON 객체) · `last_heartbeat_at` · `revoked_at` | 이메일 · 토큰 열이 없다. 이름은 표시용 `device_name`(OA F1s, 11장) 하나뿐이고 식별 · 판정 · 조인에 쓰지 않는다. `revoked` ↔ `revoked_at` |
| `agent_connections` | 에이전트 연결. `adapter`(registry 문자열 `agent:<이름>`, 64자 이하) · `bridge_id` · `device_ref` · `status`(`active` · `error` · `revoked`) | v1 `connections`를 넓히지 않는다(AC-20). 로그인 계정 · 이메일 · 토큰 열이 없다(I16). bridge가 지워지면 `bridge_id`만 빈다 |
| `agent_sessions` | 세션 binding. `connection_id` · `external_session_id` · `workspace_ref` · `display_name` · `status`(`bound` · `external` · `unreachable` · `closed`) · `bound_action_id`("처음 맡긴 이슈" 기록뿐) · `last_turn_seq` · `last_event_seq` | 연결 안에서 외부 세션 유일. 연결이 지워지면 세션도 지워진다. Action이 지워지면 `bound_action_id`만 빈다 |
| `agent_tasks` | 원격 작업(턴 하나 또는 맡긴 작업 하나). `run_id` · `step_id` · `agent_session_id` · `message_id` · `state`(아홉 값, `idle` 포함) · `last_live_state`(열린 상태 넷 중 하나, `state = 'unreachable'`이면 필수) · 지시 버전 · 결과 회차 · `pending_question` · `result_refs` | `idle`은 `completed`가 아니다(턴의 끝). 열린 상태만 `unreachable`이 된다 — `idle` 작업은 끊긴 것으로 바꾸지 않는다(AC-21). `awaiting_answer`이면 `pending_question`이 있다. 질문 모양은 서버 zod가 검증한다 |

## 3. 기존 표 확장

- `execution_runs`: `kind`(`task` 기본 · `conversation`) · `agent_session_id`(세션이 지워지면 비움) · `reviewed_turn_seq`(마지막 검토가 본 턴). `conversation`은 goal `agent`뿐. 부분 unique `(agent_session_id, action_id) where kind = 'conversation' and state not in ('done','failed','stopped')`: 세션 × 이슈마다 열린 대화 run은 하나.
- `execution_events`: `type`에 `'agent'` 추가 + `external_event_id` · `external_seq` · `directive_version` · `turn_seq` · `bridge_id` · `payload`. `type = 'agent'` ↔ `external_event_id` 있음(1–200자, 빈 문자열 불가). 부분 unique `(run_id, external_event_id) where type = 'agent'`: 같은 사건은 run마다 한 번만. **`payload`에 글을 담지 않는다**(질문 글은 `agent_tasks.pending_question`, 결과 글은 산출물에만) — 검증은 서버 코드(D1c-2)이고 DB는 JSON 객체인지만 본다. 앱은 `execution_events`를 읽지 못한다.
- 기존 트리거(`execution_runs_log` 등) · 함수는 바꾸지 않았다.

## 4. 불변식 (DB가 막는 것 / 서버가 지킬 것)

| 규칙 | DB 백스톱 | 실제로 지키는 곳 |
|---|---|---|
| 세션당 진행 중 턴 하나(`dispatched` · `accepted` · `running` · `awaiting_answer` · `unreachable`). 끊긴(`unreachable`) 작업이 있는 동안 그 세션은 reconcile을 기다리며 새 턴을 시작하지 못하고, 같은 행을 `last_live_state`로 되돌리는 갱신은 된다 | `agent_tasks_in_progress_idx` | D1c-1: 새 턴을 시작할 때 `agent_sessions` 행을 `for update`로 잡고 판단 |
| 같은 세션의 `turn_seq`는 한 번만 | `agent_tasks_session_turn_idx` | D1c-1: `last_turn_seq`를 올린 값을 적는다 |
| 세션 × 이슈마다 열린 대화 run 하나 | `execution_runs_open_conversation_idx` | D1c-1: unique 위반이면 첫째 run을 다시 읽어 쓴다 |
| 같은 사건은 한 번만 적용 | `execution_events_agent_dedup_idx` | D1c-2: 사건 봉투를 받을 때 |
| 남의 bridge · 연결 · 세션 · run · 메시지를 가리키지 못한다 | 복합 외래키 | — |
| 부모를 지우면 기록은 남고 참조만 빈다(`step_id` · `message_id` · `bridge_id` · `agent_session_id` · `bound_action_id`), 소유 관계는 함께 지운다(연결 → 세션 → 작업, run → 작업) | `on delete set null (열)` / `cascade` | — |

## 4-1. 서버가 지킬 것 (D1c) — DB가 막지 않는 것

복합 FK는 "같은 사용자의 행"까지만 보장한다. 아래는 DB가 막지 않으므로 서버 코드(D1c)와 시험이 지킨다.

- (a) 세션 · 연결을 지우기 전에 그 세션의 열린 대화 run을 먼저 `stopped`로 끝낸다. 세션을 지우면 `execution_runs.agent_session_id`가 null이 되고, 열린 대화 run의 부분 unique는 null을 구분하지 않아 세션 없는 열린 run이 쌓일 수 있다.
- (b) `agent_tasks.step_id`는 같은 run의 단계여야 하고, 대화 run(`kind = 'conversation'`)의 작업이면 `agent_tasks.agent_session_id`가 그 run의 `agent_session_id`와 같아야 한다. 복합 FK는 사용자만 맞춘다.
- (c) 글 보관 기한 정리(런타임 계약 V08)가 `agent_tasks.pending_question`과 `agent_sessions.display_name`까지 닿도록 넓힌 뒤에 D1을 켠다. 지금 정리 함수는 이 두 열을 모른다.
- (d) 사건 `payload`에는 글을 담지 않는다. DB는 JSON 객체인지만 본다.

## 5. 하지 않은 것 — 실행 입구는 D1c가 연다

이 묶음 뒤에도 goal `agent` run은 만들어지지 않고 어떤 에이전트 단계도 실행되지 않는다.

- `create_run`(goal `draft`만) · `append_step`(`plan` · `draft` · `external`만) · `begin_call` · `approve_*` · 실행기는 한 글자도 바꾸지 않았다. 이 파일은 함수를 만들지도 바꾸지도 않는다.
- `execution_tools` · `execution_controls`에 `agent:*` 행을 더하지 않았다(D1c-1은 별도 대화 run 함수와 막힌 message 도구만 더한다. `create_run`의 goal 검사는 유지한다).
- 이 묶음에 없는 것: `bridge_commands`(D2a) · `agent_path_leases`(D3c) · `context_members`의 agent_session 종류 · `execution_artifacts` 열 · route · gate · 앱 화면. (`conversations` · `conversation_messages` 열은 D1b가 더했다 — 7장.)
- 사건 `payload`의 "글 없음" 규칙, `pending_question`의 모양, `turn_seq` 직렬화는 서버 코드가 한다(위 4장).

## 6. 적용

운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f supabase/migrations/20261113000000_agent_gateway_core.sql`로 한다(`db push` 금지). 한 트랜잭션이고 `lock_timeout 5s`라, 잠금을 오래 기다리면 실패한다(그대로 다시 적용한다). `execution_events.type`의 기존 CHECK가 정확히 하나가 아니면 아무것도 바꾸지 않고 실패한다.

## 7. 대화 대상과 에이전트 글 (D1b) — 결정 기록과 위치

2026-10-13 · 구현 계획 D1b · 근거: Assistant 계약 v3 3.1 · 3.2 · 3.4("질문에 대한 답") · 3.5 · 8장. D1a(`20261113000000`) 위에 쌓는다.
**저장과 SQL 함수만이다: 열 · 제약 · 트리거 · 서버 전용 함수 둘 · 기존 함수 셋의 교체. route · zod 계약 · 앱 · bridge · 턴 시작 · 전달 단계는 없다(D1c-1 · D1c-2 · D1d). 운영 DB 적용 전.**
`create_run` · `append_step` · `begin_call` · 실행기 · `execution_tools` · `execution_controls`와 `agent_tasks`는 한 글자도 바꾸지 않았고(append는 작업을 읽기만 한다), B2 시나리오(`tests/db/conversations-v2.scenarios.ts`)는 무수정으로 통과한다.

| 조각 | 위치 |
|---|---|
| 마이그레이션 | `supabase/migrations/20261114000000_conversation_agent_target.sql` |
| 시험 | `tests/db/conversation-agent-target.scenarios.ts`(PGlite `.test.ts` + 실제 Postgres `tests/pg/conversation-agent-target.test.ts`, 경합 T10은 실제 Postgres에만) |

### 7-1. 열

| 표 | 열 | 뜻 |
|---|---|---|
| `conversations` | `target_kind` (`taskforce` 기본 \| `agent`) | 대화 상대. 만든 뒤 바뀌지 않는다 |
| | `agent_connection_id` | `agent`면 필수(`agent_connections`), `taskforce`면 없다. 만든 뒤 바뀌지 않는다. 연결은 `on delete restrict`: 대화가 있는 연결은 지울 수 없다 |
| | `agent_session_id` | 첫 전달 때 묶인다(null → 값 한 번). 값 → 다른 값은 거절. 세션을 지우면(`set null`) 대화는 남고 이 열만 빈다. `taskforce`면 없다 |
| `conversation_messages` | `delivery_state` | 대상 `agent`의 사용자 메시지 전달 상태: `queued` · `not_sent` · `dispatched` · `expired` · `cancelled`. 응답의 `sent` · `accepted` · `unknown`은 열이 아니라 전달 단계에서 계산한다(D1d) |
| | `delivery_reason` | `^[a-z][a-z0-9_]{0,63}$`. `not_sent` · `queued` · `expired` · `cancelled`에만(전달 상태 없이 이유만 있는 행은 없다) |
| | `delivery_expires_at` | 저장 시각 + 24시간. 만료 sweep의 기준 |
| | `external_event_id` | 에이전트 글의 멱등 열쇠(1–200자, `assistant` · `event` 행). 대화마다 한 번만(부분 unique). `content`와 달리 글 보관 기한에 비워지지 않는다 |

### 7-2. 대상별 규칙 (`conversation_post_message`, 시그니처 · 반환 모양 그대로 교체)

| | 대상 `taskforce` | 대상 `agent` |
|---|---|---|
| 새 메시지 | B2 그대로: 처리 표시(`reply_lease_until`)를 건다, 전달 열은 null | 처리 표시 없음, `delivery_state = 'queued'`, `delivery_expires_at = 저장 + 24시간`, `delivery_reason = null` |
| 같은 `client_message_id` | `mismatch` · `refs_mismatch` → `answered` → `stale` → `in_progress` → `retry` | `mismatch` · `refs_mismatch`는 그대로, 그 밖에는 `exists`(기존 id · seq)이고 행을 고치지 않는다. 뒤에 새 메시지가 있어도 앞 메시지를 버리지 않는다(`stale` 없음) |
| 코디네이터 사건 | 사용자 메시지마다 `user_message` 한 건(생산자 트리거, 삼키면 회수 sweep이 메운다) | 없다: `coordinator_on_user_message`가 건너뛰고 `coordinator_recover_missing`도 이 대화의 메시지를 회수하지 않는다. 그 메시지는 전달 경로가 처리한다 |
| Taskforce 모델의 답(`reply_to`) | 쓴다 | 쓰지 못한다(백스톱 트리거가 거절 — `conversation_finish_turn`도 같다) |

### 7-3. 함수 (새 서버 함수 둘은 service role 전용, 앱 · 익명은 실행 불가)

- `conversation_append_agent_message(p_user_id, p_conversation_id, p_agent_task_id, p_turn_seq, p_event_id, p_text, p_kind in ('reply','question','event'))` → `(status, message_id, seq)`. 대화 행을 잠그고 `seq = max + 1`로 `assistant`(reply · question) 또는 `event` 행을 쓴다. `reply_to`는 null, `external_event_id = p_event_id`, `content = { author: { kind: 'agent', adapter }, kind, turn_seq?, truncated? }`(`turn_seq`는 null이면 키가 없다).
  - 결과: `created` · `duplicate`(같은 event id가 있으면 기존 id · seq, 아무것도 쓰지 않음) · `not_found`(대화 · 작업이 없거나 남의 것) · `wrong_target`(대상이 `agent`가 아님) · `wrong_session`(작업의 세션 ≠ 대화의 `agent_session_id`, 세션이 아직 안 묶인 대화 포함) · `wrong_conversation`(reply · question인데 작업의 `message_id`가 이 대화의 메시지가 아님). `event`는 세션만 맞으면 된다. 인자가 어긋나면 `22023`.
  - 글은 20,000자와 32,768바이트(UTF-8) 이하로 글자 단위로 자른다(멀티바이트를 가르지 않는다). 잘랐으면 `content.truncated = true`. 전문은 Mac bridge 원장에 있다.
  - `agent_tasks` · `agent_sessions` · `execution_*`는 쓰지 않는다. 잠그는 것은 대화 행 하나.
- `conversation_expire_agent_messages(p_now timestamptz)` → 바꾼 수. `delivery_expires_at < p_now`인 `queued` · `not_sent`를 `expired`로(이유는 남긴다). `dispatched` · `cancelled` · 이미 `expired`는 건드리지 않는다. 사용자 경계 없이 전체(cron용), 한 번에 최대 1,000행(가장 오래된 만료부터)이라 호출자가 0이 될 때까지 반복한다. 다른 트랜잭션이 잡은 행은 기다리지 않고 건너뛴다(다음 sweep이 본다). `p_now`가 null이면 `22023`.
- 교체한 기존 함수(권한 · 시그니처 유지): `conversation_post_message`(7-2), `coordinator_on_user_message`(`agent` 대화는 적재하지 않는다), `coordinator_recover_missing`(**코디네이터 결정으로 추가**: 본문은 `20261110000000_coordinator_core`의 정의를 그대로 옮기고, 사용자 메시지 회수의 안쪽 select에 대상 `agent` 대화 제외 조건 한 줄만 더했다. `limit`이 제외 뒤의 메시지를 센다).

### 7-4. 불변식 (DB가 막는 것 / 서버가 지킬 것)

| 규칙 | DB 백스톱 | 실제로 지키는 곳 |
|---|---|---|
| `agent` ↔ 연결 필수, `taskforce` → 세션 없음 | CHECK `conversations_agent_target_check` · `conversations_taskforce_no_session` | D1c-1: 대화 만들기 |
| 대상 · 연결은 바뀌지 않고 세션은 한 번만 묶인다 | 트리거 `conversations_agent_target_guard` | D1c-1: 첫 전달 때 `where agent_session_id is null`로 조건부 갱신 |
| 남의 연결 · 세션을 가리키지 못한다 | 복합 외래키 | — |
| `agent` 대화의 사용자 메시지는 전달 상태가 있고 모델 답(`reply_to`)이 없다 / `taskforce` 대화의 메시지는 전달 · 외부 사건 열이 null | 트리거 `conversation_messages_target_guard` | 대상별 경로: 사용자 메시지는 `conversation_post_message`, 에이전트 글은 append, 모델 답은 `conversation_finish_turn`(taskforce만) |
| 같은 에이전트 사건은 대화마다 한 번만 | 부분 unique `conversation_messages_external_event_key` + append의 `duplicate` | D1c-2: 사건마다 안정된 `event_id`를 만든다 |
| 보관 24시간 지난 `queued` · `not_sent`는 자동 전달하지 않는다 | `conversation_expire_agent_messages` | D1d: sweep route가 0이 될 때까지 반복해 부르고, 전달 단계도 `delivery_expires_at`을 본다 |
| `agent` 대화의 메시지는 코디네이터 사건이 아니다 | 생산자 트리거 + 회수 sweep 둘 다 건너뜀 | — |

### 7-5. 서버가 지킬 것 (D1c · D1d) — DB가 막지 않는 것

- (a) 세션이 대화의 연결에 속하는지(`agent_sessions.connection_id = conversations.agent_connection_id`)는 복합 외래키가 보장하지 않는다(같은 사용자의 다른 연결 세션을 묶을 수 있다). 첫 전달에서 묶을 때 확인한다.
- (b) `agent_session_id`의 값 → null은 DB가 막지 않는다(세션 삭제의 `set null`과 직접 갱신을 구별하지 않는다). 앱은 쓰기 권한이 없고 서버만 쓴다.
- (c) 연결 삭제는 그 연결의 대화가 있으면 거절된다(`restrict`). 대화를 `archived_at`으로 보관해도 대화 행이 남아 있으므로 거절은 그대로다. 그래서 연결 해제 경로는 대화를 삭제하거나, 대화를 보존하려면 연결을 지우지 않고 `revoked`로 둔다(D1c 결정). 계정 삭제(`auth.users`)는 사용자 cascade로 둘 다 지워지며 시험이 확인한다(PGlite · 실제 Postgres).
- (d) 세션 단위 `event`(중단 확인 · 연결 끊김 · 결과 검토)는 그 세션에 묶인 **모든 대화**에 한 줄씩 쓴다 — append는 대화 하나에만 쓰므로 반복은 D1c-2의 몫이다. 같은 event id는 대화마다 따로 유일하다.
- (e) `delivery_state` 전이(`queued` → `dispatched` · `not_sent`, 되돌리기, `cancelled`)는 이 묶음에 없다. 전달 단계의 intent를 만드는 트랜잭션(D1c-1 · D1d)이 같은 트랜잭션에서 바꾼다. DB는 값의 모양과 이유 ↔ 상태만 본다.
- (f) 글 보관 기한 정리(V08)가 `delivery_reason` · `external_event_id`를 어떻게 다룰지는 정하지 않았다(`external_event_id`는 남기는 쪽이 계약 3.5). D1을 켜기 전에 정한다.

### 7-6. 하지 않은 것

- 측정 이벤트(계약 8장 `metric_events.props` · 새 type)는 첫 사용 WP(D1c-1)가 더한다. 이 묶음의 새 쓰기 경로는 8장 표에 대응하는 이벤트가 없다.
- `conversation_finish_turn` · `conversation_release_lease` 변경 · 턴 시작 · 전달 단계 · `agent_tasks` 쓰기 · route · `contract.ts` · Swift · 앱.

### 7-7. 적용

운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f supabase/migrations/20261114000000_conversation_agent_target.sql`로 한다(`db push` 금지). `20261113000000_agent_gateway_core` 뒤에 적용한다. 한 트랜잭션이고 `lock_timeout 5s` 뒤에 `conversations` · `conversation_messages`를 정해진 순서로 `NOWAIT`으로 먼저 잠근다 — 두 표 중 하나라도 이미 잠겨 있으면(진행 중인 대화 쓰기 포함) 기다리지 않고 바로 `55P03`으로 실패하고 롤백한다(그대로 다시 적용한다). 기다리면 B2 답 저장(`conversation_finish_turn`: 메시지 표를 먼저 읽고 대화를 잠금)과 순환 대기가 되어 `40P01`이 날 수 있어서다(`lock_timeout`은 교착을 막지 못한다; 시험 `tests/pg` T13). 기존 행은 새 열이 기본값(`taskforce` · null)이라 영향이 없다.


## 8. 턴 시작 · 이슈 결정 · 대화 run (D1c-1)

`20261115000000_agent_turn_start.sql`과 `src/lib/agents/{registry,capability,turns,delivery}.ts`가 대화 메시지를 `prepared`까지 만든다. 실제 provider 호출 · bridge 명령 · route는 없다. `create_run`은 여전히 draft만 받으며 `EXECUTABLE_GOALS` · `EXECUTABLE_STEP_KINDS`도 그대로다.

- `start_agent_turn(user, message, added_action_ids, added_context_ids, access, live_limit)`: 메시지 소유자/대상/상태/만료 → 세션 잠금 → 보류 판단 → Action 결정/생성 순서다. 보류 중에는 메시지 상태/정규화 칩과 필요한 pending 세션만 저장한다. 후보가 여럿이면 세션 생성/바인딩도 하위 트랜잭션으로 되돌리고 `refs.referent_candidates` 최대 셋과 응답 `candidates`를 남긴다. `set_agent_message_referent`는 후보 중 내 열린 Action만 저장하며 시작 시 다시 검증한다.
- 세션이 없으면 `bound`, `external_session_id = pending:<conversation_id>`로 만들고 대화에 한 번 묶는다. 필수 `workspace_ref`도 같은 임시 식별자다. `display_name`은 메시지 첫 비어 있지 않은 줄의 공백 정리 + 80자(없으면 `Untitled`)다. 실제 세션/작업공간 증거는 bridge 사건 WP가 교체한다.
- 칩 없는 메시지는 직전 턴의 열린 Action을 재사용한다. 직전 Action이 done/dropped이거나 첫 턴이면 실제 시작할 때만 결정적 Action/note id, 위 제목 규칙, scope/owner/status user Claim, 원문 note와 `created` Evidence를 `write_action`으로 쓴다. 이벤트는 `user_created/assistant_agent`, `source_id=null`. 칩 id는 중복을 제거하며 active context 칩 하나만 사용자 멤버십 RPC로 붙인다.
- `open_agent_conversation_run`은 기존 `create_run`과 같은 정책/예산/초기값을 쓰되 `kind=conversation`, `goal=agent`, 세션과 최초 `conversation_id`를 지정하고 plan을 만들지 않는다. `request=''`, 단계 `body=''`, `args={message_id}`이며 bridge 명령 생성 시 보관 기한 내 메시지 행을 읽는다. 열린 세션×Action 부분 unique 충돌은 기존 run 재조회로 처리한다. conversation의 `append_step`은 `agent_message`만 허용한다.
- 직접 에이전트에게 보낸 메시지의 전달은 사용자 결정이므로 `prepare_step`의 conversation `agent_message`는 `needs_approval=false`다. task 외부 단계의 승인과 실제 에이전트 도구 호출 정책은 별개다. 접수/실패로 대화 run을 닫지 않으며 task 완료/실패는 유지한다.
- 잠금 순서는 메시지 → 사용자 advisory → 대화 `FOR NO KEY UPDATE` → 세션 `FOR UPDATE` → run이다. 외부 작업 한도는 TS가 `MAX_LIVE_EXTERNAL_TASKS`를 인자로 넘기고 SQL이 사용자 잠금 안에서 검사한다. `dispatched/accepted/running/unreachable`만 세며 `idle/awaiting_answer`는 제외한다. 진행 중 세션은 `session_busy`, external은 `session_external`, 한도는 `live_limit`, 앞선 메시지는 `queue_order`로 queued다. closed는 `not_sent/session_closed`다.
- FIFO는 각 대화의 만료 전 queued/not_sent 중 seq가 작은 메시지를 먼저 고른 뒤, 대화 머리끼리 created_at/seq/id로 정한다. `created_at`은 트랜잭션 시작 시각이라 같은 대화의 seq를 뒤집는 데 쓰지 않는다. 미확정 referent와 영구 제외 사유(`invalid_referent/session_closed/not_found/already_dispatched`)는 순서를 막지 않는다.
- 메시지 `dispatched`, 작업 `dispatched`, 단계 `prepared` + `intent_key`, `agent_message_sent` 지표는 원자 저장한다. `execution_intents` 표식/lease/`calling`은 만들지 않는다. 실패가 확인된 재시도만 purpose `message:<id>:<n>`을 쓰며 unknown 결과는 재전송하지 않는다.
- `next_queued_agent_message(user,session)`은 id 또는 null만 읽고 반환한다. SQL에 adapter registry는 없다. TS `startNextQueuedTurn`이 현재 registry/정책/연결로 등급을 계산하고 `startAgentTurn`을 부른다. 시작 불가 결과 not_found/already_dispatched는 소유자·대상·상태·만료 검증을 거쳐 같은 reason의 not_sent로 제외한다. 재시도 칩은 `refs.agent_turn`의 added 칩을 우선하고 없으면 `selected`를 쓴다. 호출자는 세션/작업 잠금을 쥐지 않아야 하며 API WP는 selected에 auto 칩을 섞지 않는다.
- registry S0: Claude Code는 등급 없음/`direct_chat=unsupported`, Codex는 `read_only`. bridge 보고는 검증 증거가 아니다. 버전 범위 자체 점검/프로토콜 hash는 adapter WP 책임이다. 두 adapter의 message 도구는 external, provider control은 blocked다.

모든 새 RPC는 `SECURITY INVOKER`, `search_path=''`, service_role만 실행한다. metric 확장 블록은 코디네이터 원문 그대로이며 앱 insert 정책은 app_opened/assistant_opened만 허용한다. 마이그레이션은 한 트랜잭션, lock_timeout 5초, metric_events 잠금은 NOWAIT이다.

검증 위치: `tests/db/agent-turn-start.scenarios.ts` · `.test.ts`, `tests/pg/agent-turn-start.test.ts`, `src/lib/agents/*.test.ts`. PG 경합 시험은 샌드박스에서 작성만 했으며 실행 증거는 별도다. 질문/중단/사건·bridge API·대화 API 연결은 후속 WP다. 특히 실패 재시도의 앞 failed 단계와 기존 begin_call의 앞 단계 검사는 bridge API에서 맞춰야 한다; 이 WP는 prepared에서 멈춘다.


## 9. 에이전트 사건 반영 (D1c-2a)

`20261116000000_agent_events.sql`의 `apply_agent_event(user,event)`와 `src/lib/agents/events.ts`가 bridge 사실을 적용한다. 서버 내부 봉투는 `{adapter,session_ref:{agent_session_id},agent_task_id?,external_task_id?,event_id,seq?,turn_seq?,type,payload?,text?,question?,observed_at}`다. 기존 bridge DTO와 route 연결은 다음 WP가 맡는다.

- 사용자·세션·adapter·run·step 귀속을 잠금 후 다시 검사한다. 잠금 순서는 메시지 → 대화 → 세션 → run → task → step이며 기존 표 migration 잠금은 execution_runs → agent_tasks 순서로 둘 다 NOWAIT다. `(run_id,external_event_id)` 중복은 쓰기 0이다. seq는 1 이상, observed_at은 ISO 시각이며 last_seen_at과 seq는 역행하지 않는다. accepted는 seq-late에서, session_bound는 seq/turn late에서 제외한다.
- dispatched의 첫 accepted/progress/message/question/artifact는 calling+lease를 확인한 뒤 `settle_step(called)`로 접수부터 정산한다. prepared는 step_not_calling/기록 0이다. 같은 턴의 첫 활동은 seq-late여도 접수 사실을 먼저 정산한다. 해당 활동의 나머지 상태·질문·산출물 효과는 late로 억제하며, 다른 turn은 접수하지 않는다. 사건의 external_task_id는 task 잠금 아래 최초 바인딩하고 receipt에 남긴다. 다른 값이나 같은 세션의 다른 task와 충돌하면 conflict/변경 0이다. `progress`는 accepted→running, 반복 progress는 ignored+heartbeat이며 accepted→awaiting_answer도 허용한다. `turn_completed`는 idle이며 먼저 온 완료도 접수를 정산한다. 같은 상태 재적용은 ignored로 기록해 event 줄을 중복 생성하지 않는다. 접수 전 failed는 4종 reason과 not_sent, cancelled는 failed 단계·cancelled receipt·cancelled delivery를 원자 저장한다. 접수 뒤 failed reason은 생략 또는 agent_error이며 대화 run은 닫지 않는다. 접수 뒤 접수 전 reason 4종이 오면 22023 예외 대신 원장에 conflict로 기록하고 상태는 바꾸지 않는다.
- **Claude Code synthetic assistant는 활동이 아니다.** S0 CC-8의 미로그인 흐름은 `system:init` → `assistant`(`model: <synthetic>`, “Not logged in…”) → `result is_error`다. Bridge · Claude Code adapter WP는 `model`이 `<synthetic>`인 assistant를 `message`나 접수 신호로 보내지 않고, 그 턴을 `failed {reason: sign_in_needed}`로 보낸다(접수 전 실패 → 메시지 `not_sent`). 계약 3.2 · 13.2의 “첫 assistant 사건 = 접수”에서 synthetic은 제외한다.
- 질문은 별도 `question={provider_request_id,kind,structured,questions[1–4]{id,header,text,options[{label,description}],multi_select,allow_other,secret}}`다. TS strict zod와 SQL CHECK가 검증하며 서버는 `question_key=[agent_task_id,provider_request_id]`, `asked_at=observed_at`을 붙여 pending_question에 저장한다. 기존 질문은 question_conflict로 보존한다. 질문 글·선택지는 pending_question에, 봉투 text는 D1b의 question 대화 줄에 저장한다. 원장에는 question_key/kind/question_count 메타데이터만 남긴다. request id 1–200자, 질문 id/header 200자, text 4000자, option label/description 500/1000자, 질문당 선택지 10개와 고유 질문 id를 검사한다. task id와 question_key[0]가 같아야 하며 metadata 포함 pending_question은 JSONB UTF-8 32KB 이하다.
- message/question의 대화 글은 그 턴을 시작한 대화에만 D1b append로 저장하고 UTF-8 32KB를 넘으면 자른다. seq-late reply도 같은 turn이면 event id당 한 번 저장하되 not_sent 턴과 다른 turn의 글은 기록만 한다. payload는 허용 키만 받으며 입력과 최종 원장 모두 JSONB 표현 기준 4KB다. 길이 제한은 Unicode 문자 수(SQL char_length)로 맞췄다. 세션 event 줄은 TS가 고정 문구로 모든 연결 대화에 쓰며 부분 실패 뒤 duplicate 재시도가 누락된 줄을 보완한다. 원래 사건 복구는 at/id 순서로 선택한다(동시 fanout 전체 순서를 직렬화하는 것은 아니다).
- `unreachable`은 열린 상태의 last_live_state만 보관하고 idle은 바꾸지 않는다. reconcile은 last_live_state로만 복원한다. payload.state가 다르면 reconcile_conflict/쓰기 0이다. bridge는 끊긴 동안의 원래 사건을 원래 event_id로 재생해 단계와 task를 정상 경로로 옮긴 뒤 reconcile한다. reconcile이 접수나 실패 reason을 만들지 않는다.
- `session_bound`는 pending id를 실제 id로 바꾸되 기존 세션 id 충돌은 conflict다. 세션을 합치지 않으며 이미 같은 실제 id면 ignored다.
- 산출물은 새 `agent_artifacts`에 run/task/turn/path/content_hash/summary(≤2000자)만 저장한다. 같은 run/path의 이전 산출물에 superseded_at을 붙이고 늦은 이전 턴이 최신을 대체하지 않는다. 본문·diff는 저장하지 않는다. authenticated owner_all RLS와 `(agent_task_id,run_id,user_id)` 복합 FK 및 user/task/run 인덱스를 쓰며 앱은 SELECT, 서버만 쓴다. 기존 `execution_artifacts`와 Swift 읽기는 바꾸지 않았다. 후속 Review의 result_ready 계산은 agent_artifacts를 읽어야 한다.

새 함수는 INVOKER, search_path='', service_role 전용이다. 사건 적용용 metric type은 Assistant 계약 8장에 없어 새로 만들지 않았다. 검증은 `events.test.ts`, `tests/db/agent-events.*`, `agent-artifacts-rls.test.ts`; `tests/pg/agent-events.test.ts` 경합 시험은 작성만 했으며 실제 PostgreSQL 실행 증거는 없다. D1c-2b가 질문 답 CAS·Stop/Done·정리, bridge API가 인증된 입구·lease/calling·provider 접수 신호·재생/fanout 재시도를 연결한다.

D1c-2a 정정 2 인계: lease 만료 unknown_outcome 뒤 접수는 bridge API의 readback 설계 대상이다. pending_question 글·agent_artifacts.summary는 현재 purge_expired_execution_text 밖이며 보관 기한(V08)·처리방침(DEC-4 gate)에서 정한다. agent_connections.bridge_id와 발신 bridge 대조는 인증 route가 맡는다.

## 10. 질문 답 · Stop · Done (OA D1c-2b)

`20261116120000_agent_questions_stop.sql`과 `lib/agents/{questions,tasks,turns}.ts`는 서버 내부 입구다. 실제 route·bridge 전달은 아직 없다. 단계는 `prepared`까지만 만들며 provider 차단과 기존 실행기의 제한을 유지한다.

- `answer_agent_question(user,task,provider_request_id,answers,answered_locally,answer_message_id=null)`는 현재 질문 열쇠를 잠금 아래 비교한다. 질문이 바뀌면 `question_stale`, 같은 답의 재전송은 `duplicate`와 최신 step id다. 답은 질문 id→문자열/비어 있지 않은 선택지 배열, 승인 질문은 allow/deny다. 공백 Other는 거절하고 승인 event는 Allowed/Denied다.
- 질문은 `pending_question`에서 `answered_question`으로 옮긴다. 답 단계가 calling에서 failed로 정산되면 카드를 복원한다. 재시도마다 새 단계와 `answer:<task>:<request>:<n>` intent(n=0부터 실패마다 +1)를 만들며 이전 실패 원장은 남긴다. 수정한 선택 label은 기존 event 한 줄에 반영한다. 접수 뒤 일반 실패와 unknown_outcome은 카드 복원 대상이 아니다. 이전 seq의 활동은 답의 접수 증거가 아니다.
- TS는 `question`을 필수로 받고 비밀 질문이 하나라도 있으면 값을 RPC로 보내지 않는다. SQL도 잠금 뒤 현재 질문으로 검사하며 `{answered_locally:true}`만 기록한다. `answeredLocally`는 후속 route가 세션 소유 Mac의 증거로 정하며 요청 body의 boolean을 그대로 넘기지 않는다. 혼합 질문도 전체 답을 로컬에서 주입한다.
- `startAgentTurn`은 `route_agent_message`를 부른다. 그 턴을 시작한 대화에서 서버가 매긴 메시지 `seq`가 그 턴의 마지막 질문 줄보다 큰 메시지만 input 질문 하나·allow_other·비밀 아님 조건으로 답이 된다. 자유 글 단계 args는 `{agent_task_id,provider_request_id,answer_message_id}`뿐이고 본문은 대화 메시지 보관 기한을 따른다. 카드 답의 `args.answers`는 `purge_expired_execution_text`가 지우고 id·상태·버전·intent는 보존한다. bridge의 `observed_at`과 서버 `created_at`은 이 판정에 비교하지 않는다. 다른 대화·질문 전 메시지·다중 선택 등은 `question_open`으로 대기한다. 대기 경로의 칩 소유권·FIFO·한도 검사는 기존 start 함수를 재사용한다.
- `stop_agent_session(user,session,surface,cancel_scope)`는 `{tasks:[{agent_task_id,cancel,processes?}]}`를 반환한다. lease되지 않은 pending/prepared 최초 턴은 단계 skipped·task cancelled·메시지 cancelled로 즉시 confirmed, cancel 단계 0이다. Claude Code 보류(unreachable의 마지막 상태가 awaiting_answer인 경우 포함)와 답을 받았지만 아직 pending/prepared이고 lease·intent·calling 이력이 없는 턴은 deny 기록과 confirmed다. 후자는 answered_question의 열쇠를 버리고 답 단계를 skipped로 정리하며 cancel 단계는 만들지 않는다. 나머지는 `cancel:<task>` prepared와 requested_only, Codex의 requested_only에는 processes=may_continue가 붙는다.
- Stop·Done은 버린 질문의 열쇠만 `abandoned_question`에 남기고 `pending_question`을 비워 카드를 숨긴다. abandoned_question은 null 또는 해당 task의 `[task id, request id]`만 허용한다. 어느 adapter든 미전달 답이 skipped가 되면 answered_question의 열쇠를 기록하고 자유 글 답 메시지는 cancelled로 바꾸며 `refs.answer_for`는 보존한다. task가 idle/completed/failed/cancelled가 되면 그 task의 남은 pending/prepared 단계도 skipped다. lease·intent·calling 이력이 있는 단계는 미전달로 확정하거나 skipped로 정리하지 않는다. 일반 Stop은 열린 run·대기 메시지를 멈추고 event와 stop_requested를 남긴다. external 세션은 run만 멈추며 대기 메시지를 그대로 보존한다.
- 잠금은 메시지→대화→세션→run→task→step이다. Stop의 메시지 잠금은 보류 중 사용자 메시지와 진행 중 task의 원문만 잡는다. 세션 잠금 뒤 새 행을 NOWAIT로 재확인하며 55P03은 전체 롤백, TS는 최대 3회 시도한다. 답은 잠금 뒤 run 상태·세션 external/closed·연결 active·귀속을 다시 검사한다.
- Done/dropped는 사용자 status Claim 트리거에서 해당 이슈의 열린 대화 run만 gate `action_closed`, stopped_at=null로 멈춘다. 세션 삭제는 gate `session_deleted`로 같은 중단을 하며 둘 다 stop_run/코디네이터 run_stop 결정을 만들지 않는다. Done은 Action→run→task로 세션을 잠그지 않는다. 미전달 원문·답 메시지를 cancelled로 바꿀 때는 메시지 NOWAIT로 잠금 순환을 피하며 충돌 시 Done 전체가 롤백된다. `writeAction`·`writeProgress`는 SQLSTATE 55P03만 50ms·150ms 뒤 최대 두 번 재시도하고, 세 번째 실패와 다른 오류는 그대로 전달한다. 다른 이슈 턴과 검토 단계는 건드리지 않는다.

후속 대화 API·읽기 모델은 cancelled 메시지 Send again, Stop route/응답, `refs.answer_for` 메시지의 전달 표시와 Codex Stop 뒤 카드 숨김을 연결한다. Done·Stop이 로컬에서 확정한 뒤 같은 세션의 대기 메시지를 이어 보내는 `startNextQueuedTurn` 호출은 대화 API WP가 연결한다. Bridge API는 stopped run에 prepared로 남은 `agent_cancel`도 lease할 수 있어야 한다(Codex 진행 중 취소에 필요). Bridge API의 대화 run lease는 run을 잡은 뒤 Action을 잠그면 안 된다(Done은 Action→run). 답/취소의 실제 전달은 lease가 먼저다. 답이 prepared일 때 프로세스가 죽어 요청이 닫힌 경우를 `failed/agent_error`로 보내면 `step_not_calling`이며, 이 요청 종료 reason과 정산 경로는 후속 bridge WP가 정의해야 한다. 로컬 비밀값 주입과 Claude Code deny 닫기 모드 resume도 후속 구현이다. answered_question은 pending_question과 함께 V08 보관 기한 대상이다. PG 시험은 작성만 했으며 실제 잠금/교착 검증은 코디네이터에게 인계한다.

## 11. Bridge 서버 API (OA D2a)

`20261118000000_bridge_commands.sql`, `lib/bridge/`와 `/api/v1/bridge/{register,commands,ack,events,heartbeat}`가 D1c의 prepared 단계를 로컬 bridge에 연결한다. 새 DTO는 `contract.ts` 끝 `// --- D2a ---`의 `bridgeV1*`이며 기존 bridge 뼈대/v1 계약은 그대로다. 이 서버 구현의 검증 범위는 단위·route·PGlite fixture다. Mac 프로세스 실행·실제 provider·지연 실측은 D2b/D3a/D3b가, PostgreSQL 잠금 경합은 코디네이터가 확인한다.

- **자격:** 모든 route는 기존 Bearer 또는 같은 출처 쿠키 인증 → 본문 읽기·파싱 → 기기 확인 순서다. register 외 네 route는 `X-Taskforce-Bridge-Secret`도 요구한다. 등록은 32바이트 난수의 base64url secret을 한 번 응답하고 SHA-256만 저장한다. `device_ref=sha256(user_id + ':' + device_id)`라 계정별로 분리된다. 앱은 hash 열을 읽지 못한다. 행 없음/남의 기기는 404, secret 불일치는 401, revoked는 403이며 기존 v1 오류 코드만 쓴다.
- **등록·폐기:** adapter 보고는 설치·버전·로그인 상태·managed settings뿐이고 verified 권한은 서버 registry가 정한다. 연결 생성은 명시적 `connect`에서만, 같은 bridge+adapter의 revoked 아닌 연결은 하나다. 같은 기기 재등록은 secret 회전, 폐기한 기기는 `reactivate:true`가 필요하며 옛 세션은 closed로 남는다. DELETE는 사용자 인증만으로 다른 기기를 폐기한다. 살아 있는 로그인 세션의 재등록까지 막는 수단은 아니다. 등록은 시간당 사용자별 20회다. 새 기기 등록과 폐기한 기기의 재활성화는 사용자 active bridge가 10개 이상이면 HTTP 409(`conflict`, message=`too_many_bridges`)로 거절한다. 이미 active인 같은 기기의 secret 회전은 허용한다. D2b·D4a는 10개가 찼을 때 오래된 Mac을 폐기할 화면을 제공해야 한다. events·ack·commands는 기기별 각각 분당 120·240·90회이며 초과하면 429와 Retry-After를 반환한다. 폐기한 진행 중 task는 external 세션도 포함해 cancelled로 정리해 live 한도를 해제하고 last_live_state를 보존한다. 응답의 cancel=requested_only와 task의 cancel_requested_at·last_live_state는 외부 프로세스가 아직 돌고 있을 수 있음을 남긴다. 중단 범위는 기존 registry의 cancel_scope로 표시한다. 재활성화 뒤에도 옛 closed 세션의 사건·정산을 받을 수 있다. 이는 새 턴의 전달 허용이나 프로세스 종료 증명이 아니며, 기존 task/turn/intent의 reducer 조건을 그대로 적용한다.
- **명령과 글:** agent message/answer/cancel 단계가 prepared가 되는 같은 트랜잭션의 트리거가 `bridge_commands`를 한 번 넣는다. 표는 경로·cursor·lease/outcome 시각만 보관하고 상태는 `execution_steps`에서 계산한다. 목록·Realtime에는 글이 없고 lease 응답에서만 보관 기한 안의 메시지를 읽는다. 답의 자유 글도 `answer_message_id`로 읽으며 로컬 비밀값은 `answered_locally` 표식만 있다. 답 내용이 만료됐으면 expired로 거두고 task가 running일 때만 질문 카드를 복원한다. unreachable 등 다른 task 상태는 보존한다.
- **lease:** 새 message/answer만 기존 실행 플래그·adapterEnabled·현재 registry 등급/정책·actor·global/provider/mode controls·message tool을 다시 확인한다. 꺼진 adapter의 응답 이유는 `adapter_disabled`다. calling·intent·lease_owner/expiry·명령 leased_at을 원자 기록하며 대화 run을 waiting_approval로 바꾸지 않는다. 같은 lease 재요청도 현재 gate를 다시 확인한다. 닫혔으면 쓰기 없이 stale이며, 열렸으면 payload와 만료 시각을 연장 없이 replay한다. bridge는 원장으로 실행 여부를 판단한다. 아직 lease되지 않은 메시지의 전달 기한이 지났으면 단계/task failed, 메시지 expired로 거둔다. cancel은 stopped run과 닫힌 새 전달 gate에서도 가능하다.
- **결과 확인:** lease 330초가 지나면 unknown_outcome/readbacks가 되며 새 명령·단계·intent를 만들지 않는다. `received`는 기존 단계만 called, `not_received`는 반드시 `process_ended:true`여야 하며 단계는 failed(reason=not_received)로 정산하고 outcome/outcome_at을 기록한다. 메시지 명령의 task·메시지는 task가 dispatched 또는 unreachable일 때만 실패/미전달로 바꾸며, Stop 뒤 cancelled 등 다른 상태는 그대로 둔다. 소유 명령의 stale readback은 lease된 적이 있고 아직 정산 전일 때만 outcome_at을 남긴다. lease 전 또는 이미 정산된 명령은 변경하지 않는다. 단계가 lease·다시 붙임으로 calling에 들어가면 outcome과 outcome_at을 비워, 다시 만료될 때 readbacks에 다시 나오게 한다. 답 명령은 열린 run의 중단 요청이 없을 때 카드를 복원한다. `unknown`은 판정을 유보한다. outcome_at이 있는 readback은 긴 대기를 즉시 끝내는 항목에서 제외한다. cancel은 readback 대신 멱등 중단을 다시 시도하고 complete한다. `request_closed`는 lease된 답만 닫으며 카드 복원 없이 abandoned_question을 남긴다. 모르는 kind의 prepared 명령은 decline/unsupported로 거둔다.
- **사건:** 사용자·세션·연결의 bridge와 task/turn을 대조한 뒤 기존 `apply_agent_event`를 재사용한다. 같은 bridge가 보유한 unknown 단계만 calling으로 다시 붙여 원래 event_id를 적용하며 재dispatch하지 않는다. 원장의 중복 범위는 run+external_event_id다. 결정적 거절은 상태로 반환하고, 일시 실패는 retry 목록에 넣으며 같은 세션의 뒤 사건도 보류한다. 사건 본문은 1MB/100개, text는 UTF-8 32KB가 상한이고 payload에 글을 넣지 않는다. 사건은 개별 검증해 잘못된 사건만 rejected로 반환한다.
- **heartbeat·cron:** 30초마다 heartbeat를 보내며 같은 bridge의 마지막 heartbeat가 5초 이내면 잠금·쓰기·kick 없이 지난 결과와 throttled:true를 돌려준다. 지난 결과는 서버 전용 heartbeat_result 메타데이터 열에 보관한다. 90초 누락 시 bound 세션과 진행 중 작업만 unreachable이다. idle과 lease 전 dispatched는 그대로다. 복귀는 세션만 bound로 하고 task는 원래 사건 재생/reconcile을 기다린다. process_alive인 동일 bridge의 calling lease만 연장한다. 끊김·단계 lease sweep은 SQL db_now()를 기준으로 삼는다. 끊김 sweep은 bridge별 하위 트랜잭션에 오류를 가두고 실패마다 bridge id만 WARNING에 남긴다. 내부 결과의 failure_count를 TS sweep.errors에 합산하며 실패 집계 행은 unreachable 수에서 제외한다. 끊김 감지·대화 단계 lease 만료·gate 재개는 execution 플래그 조기 반환 전에 각각 실패를 가둬 실행한다. retention은 끝난 명령만 30일 후 지우며 calling/unknown은 남긴다.
- **자동 전달:** 턴 종료/확정 실패 뒤 ⓪, heartbeat 복귀 ①, 연결 active·로그인 복귀 ②는 FIFO 머리가 queued일 때만 SQL commit 뒤 시작한다. kick은 SQL이 고른 message id를 그대로 `startPinnedAgentMessage`에 넘기며 머리를 다시 선택하지 않는다. `start_agent_turn_auto`가 잠금 안에서 자동 시작 자격을 다시 검사하므로 그 사이 실패한 메시지는 재시도하지 않는다. 지워진 Action은 처리용 칩에서만 제외하며 원래 selected는 보존한다. 시작 결과가 not_found·already_dispatched이면 `mark_agent_message_not_sent_auto`가 queued일 때만 이유를 기록하여 동시 실패 이유를 덮어쓰지 않는다. not_sent는 gate 계열(write_gate_closed·not_connected·adapter_disabled)만 ③에서 connectionContext·databaseGatesOpen·adapter 플래그·bridge 보고를 다시 확인해 재개한다. gate로 거둔 ack는 kick하지 않는다. not_received·unsupported·접수 전 실패(sign_in_needed·usage_limited·spawn_failed 등)는 사용자 Send again을 기다리고 뒤 메시지도 FIFO대로 기다린다. 세션 없는 대화의 머리도 대상으로 하며 selected의 added 칩을 보존한다. external 세션·만료 메시지는 제외하고 실패는 다음 heartbeat/sweep에서 복구한다. Resume here ④와 Stop/Done 로컬 확정 뒤 호출은 D1d다. `turns.ts`는 수정하지 않는다.
- **자동 시작 재확인(F1s 항목 6):** `start_agent_turn_auto`의 재확인은 queued 또는 gate 이유 not_sent를 받는다. ⓪①②가 queued 머리를 고른 뒤 다른 경로가 같은 메시지를 gate 이유 not_sent로 바꾸는 좁은 경합에서는 그 메시지를 시작하지만 전달은 일어나지 않는다 — 정본 gate는 lease이고 lease 재확인(연결 · 실행 주체 · 통제 · 도구)이 `not_connected` · `write_gate_closed`로 되돌린다. 만료한 메시지의 lease 회수(`expired`)는 상태만 `expired`로 두고 `delivery_reason`을 쓰지 않는다(null, 20261127000000).
- **기기 이름(OA F1s):** `register` · `heartbeat` 본문의 선택 필드 `device_name`(원문 ≤ 256 코드 포인트, 넘으면 400)을 `normalizeDeviceName`(NFC · 제어 · 서식 · 양방향 문자 제거 · 공백 하나 · 글자소 단위 64 코드 포인트)으로 정규화해 새 SQL `set_bridge_device_name`으로 `bridges.device_name`에 쓴다(`register_bridge` · `bridge_heartbeat`는 교체하지 않는다. 스로틀 응답에서도 쓴다). 같은 이름이면 SQL이 행을 잡지 않는다. 쓰기 실패는 삼키고 로그에는 `bridge_device_name_failed`만 남긴다. 이름은 개인정보라 로그 · 지표 · 오류 문구 · AI 입력에 넣지 않고, 그 Mac의 폐기(트리거 `bridges_clear_device_name`)와 계정 삭제 때 지운다. 앱은 열 단위 select로 자기 행만 읽는다. 새 플래그 · 지표 type 0. Mac이 이름을 싣는 F1m은 F1s 운영 배포와 처리방침 갱신 시행 뒤에만 낸다(옛 서버는 모르는 키를 400으로 거절한다).
- **잠금:** 메시지→세션→run→task→step→명령 순서, bridge heartbeat/폐기/sweep은 bridge를 맨 앞에서 no-key-update로 잡는다. lease는 Action을 잠그지 않는다(Done은 Action→run). 명령은 bridge/step 복합 FK만 두고 session/task FK는 두지 않는다. 트리거는 세션/task를 잠그거나 쓰지 않는다. heartbeat 세션 잠금은 bound·unreachable, run·task 잠금은 진행 중 또는 보고된 task에 한정하고 연결은 register 포함 no-key-update다. unknown/missing id는 잠금 없이 조회한다. 마이그레이션은 bridges·rate_limit_events의 ACCESS EXCLUSIVE NOWAIT 잠금을 먼저 확보한다. 실제 경합은 PG P1–P16 작성 시험으로 코디네이터가 확인한다. 신규 등록·재활성화는 사용자별 advisory lock으로 열 번째 슬롯을 직렬화한다.
- **D2b 인계:** 재접속 후 lease 전에 heartbeat, lease 전 활동 사건 금지. ack replay는 로컬 원장으로 복구한다. Claude Code `close_before`가 있으면 다음 메시지 전에 닫기 모드 resume을 수행한다. Codex clientUserMessageId는 marker, external_task_id는 턴마다 다르다. synthetic assistant는 접수가 아니다. outbox는 계정 epoch별이며 인증 실패에 지우지 않는다. device_id는 128비트 이상의 무작위 값이며 device_id·secret은 계정별 Keychain ThisDeviceOnly로 저장하고 동기화하지 않는다. 비밀값은 요청/디스크/로그에 싣지 않는다. Realtime INSERT 구독과 `wait=25` 긴 대기(2초 재확인, abort 지원)를 사용하고 heartbeat tasks에 원장이 아는 모든 작업을 보낸다. Realtime DELETE는 RLS 필터 없이 PK만 전달되는 기존 표의 특성이 같으므로 삭제 통지를 행 읽기 권한으로 해석하지 않는다. 턴 중 앱 재시작 방지는 D2b다.

상태 줄 재시도는 기존 `execution_events`의 글 없는 lifecycle 기록(`bridge_restored`/`bridge_unreachable`, `fanout_pending`)으로 복구한다. heartbeat/sweep은 기록과 상태 전이를 같은 SQL 트랜잭션에 남기고, TS는 사용자·bridge 범위를 명시하고 type=agent 및 payload->>fanout_pending=true 부분 색인과 일치하는 조건으로 조회한다. 원래 task/turn과 멱등 event id로 대화 줄을 모두 쓴 뒤 pending을 해제한다. 정산 응답 유실/부분 fanout 실패의 동일 op 재시도도 기존 outcome을 확인해 누락된 줄을 복구한다. 한도 때문에 뒤 항목이 막히지 않도록 commands는 새 cursor를 replay보다 먼저, readbacks는 아직 결과를 보고하지 않은 것만 고른다. gate 재개 후보는 세션의 FIFO 머리를 유지하면서 서버 분마다 제한된 후보 창을 순환한다.

`bridgeOwnsSession(userId, bridgeId, deviceSecret, sessionId)`는 D1d의 로컬 비밀값 답 증명용, `authenticateBridge`는 D3c-2 정책 API용 export다. 답 route 연결은 코디네이터가 나중에 병합되는 WP에 지정한다. D1d 읽기 모델은 unreachable+prepared를 queued로 표시하고(`delivery_expires_at`이 지나도 DB 행이 `dispatched/prepared`인 동안은 그대로다 — 표시만 `expired`로 바꾸면 Send again이 `not_eligible`이 되므로 후속 F3이 잠금 아래 회수와 함께 고친다) not_received/expired와 Send again을 연결한다. 새 서버 플래그·metric type은 없으며 ONE-TF-11의 서버 시각 원천은 명령 created_at/leased_at/outcome_at과 step 사건이다. 실제 지연 수치를 이 fixture 결과로 대체하지 않는다.

**전달 활성화 병합 조건:** 세션 단위 FIFO는 not_received·unsupported·접수 전 실패 머리 때문에 같은 세션의 다른 대화까지 기다리게 한다(D1c-1). 사용자가 이를 푸는 Send again·Stop은 D1d 대화 API에 있으므로 **D1d가 병합되기 전에는 bridge 전달을 켜지 않는다**. D1d 병합 뒤에도 운영 플래그·DB 스위치는 닫힌 상태를 유지한다. “보내지 못한 메시지 뒤에서 기다림” 표시는 D4a에 인계한다. 요청 한도는 현재 사건 행과 bridge 전용 색인으로 계산하며, 공개 전 분당 집계 행으로 바꾸는 작업을 인계한다.

### 11-1. Mac bridge (D2b)

위 서버 API의 Mac 쪽 상대다. 핵심은 `apple/Packages/TaskforceKit/Sources/TaskforceKit/Bridge/`(모두 `#if os(macOS)`, iOS 빌드는 그대로)에 있고, 앱(`apple/Taskforce/Mac/Bridge/`)은 연결만 한다. DTO는 `BridgeV1Contracts.swift`(`bridgeV1*`의 짝, 옛 `AgentBridgeContracts.swift` 뼈대는 쓰지 않는다). 계약 JSON은 `Tests/TaskforceKitTests/Fixtures/bridge-v1/*.json` 하나를 Swift 시험과 서버 `src/lib/bridge/swift-fixtures.test.ts`가 함께 읽는다. 실제 `claude`·`codex` 실행은 D3a·D3b가 `AgentProcess`를 구현해 붙인다. D2b는 가짜 agent(`FakeAgentProcess`, Debug 전용)로만 돈다. 이때 새 세션의 작업 폴더도 D4a가 정하기 전까지 가짜 값(`workspace-fake`)이고, 실제 빌드는 `WorkspaceResolver`가 없으면 짐작하지 않고 `spawn_failed`로 알린다.

- **원칙:** bridge는 전송이고 판단은 서버다. 등급·gate·상태 전이를 계산하지 않고 "내가 실제로 무엇을 했는가"만 원장에 적고 보고한다. 명령 하나는 실행 한 번이다: 원장이 `start_intent` 이상이면 lease도 실행도 다시 하지 않는다. 모든 외부 효과(lease 요청·프로세스 시작·중단·ack) 앞에 의도를 원장에 commit한다. 사용자 메시지 글은 디스크에 쓰지 않고(lease `replay`가 다시 준다) 비밀값 답은 메모리(`LocalSecretAnswers`)에만 있다.
- **원장:** 시스템 SQLite(WAL·synchronous=FULL), `<Application Support>/<번들 id>/Bridge/v1/<파티션>/ledger.sqlite`, 폴더 0700·파일 0600. 파티션 = `sha256(API origin + 사용자 id)` 앞 32자라 계정·서버(로컬/운영)가 섞이지 않는다. 열 때 `quick_check`에 실패하면 파일을 `ledger.sqlite.corrupt-<epoch>`로 옮기고(지우지 않는다) 빈 원장으로 시작하며, 그 뒤 모르는 명령의 결과 확인은 모두 `unknown`이다. 끝난 명령·죽은 outbox 행·보내지 못한 사건은 7일, 잘린 글 전체(View full)는 30일, 파티션당 50MB. 계정 삭제 성공 시 그 파티션 폴더와 Keychain 항목을 지운다.
- **자격:** device_id는 파티션마다 만든 32바이트 난수(43자), secret은 등록 응답이 준 43자 base64url이며 모양을 확인한 뒤에만 저장한다. 둘 다 Keychain generic password(service `taskforce.bridge`, `ThisDeviceOnly`·동기화 안 함·데이터 보호 Keychain·앱 전용 접근 그룹 `$(AppIdentifierPrefix)$(APP_BUNDLE_ID)`로 고정, App Group이 아니다)다. 서명 안 된 빌드는 팀 접두가 비어 그룹을 지정하지 않는다. 등록은 secret이 없을 때·401 회복·404 회복·사용자가 Connect를 눌렀을 때만 하고 실행마다 하지 않는다. `reactivate: true`는 사용자 행동(Reconnect this Mac)에서만 보낸다.
- **명령 처리:** 깨우기(Realtime `bridge_commands` INSERT, 끊기면 `wait=25` 긴 대기) → 결과 확인 → cancel → answer → message 순으로 처리한다. 같은 세션에 살아 있는 실행이 있으면 lease도 하지 않는다(writer 하나). 모르는 kind는 `decline`, payload의 모르는 값(access·policy_mode·question_kind)은 띄우지 않고 `readback not_received, process_ended: true`, 모르는 cancel 범위는 더 넓게(`turn_and_processes`) 멈춘다. adapter가 없거나 설치 안 됨·버전 밖·로그인 안 됨이면 `failed`로 정확한 이유(`spawn_failed`·`version_unsupported`·`sign_in_needed`)를 보낸다. lease 응답은 `leased`·`replay`(원장에 `start_intent`가 없을 때만 첫 실행), `withdrawn`(기록만), `stale/heartbeat_first`·`policy_changed`(한 번 다시), 그 밖의 `stale`(기록만), 404(`gone`)로 갈린다.
- **결과 확인:** 서버가 결과를 모르는 명령(lease 만료)은 원장·프로세스·접수 신호로 답한다(`Reconcile`, 순수 함수). `not_received`는 앞 프로세스가 끝난 것을 확인한 뒤에만 보내고 살아 있으면 보내지 않는다. 접수 신호가 있으면 outbox를 먼저 재생하고(서버가 다시 붙인다) 그래도 남을 때 `received`, 접수 신호 없이 살아 있으면 `unknown`을 한 번만 보고한다. 원장을 잃었거나 이 Mac이 모르는 명령은 `unknown`만 보내고 실행하지 않는다.
- **outbox:** 사건은 먼저 적고 보낸다. 묶음은 사건 ≤ 100개·본문 ≤ 900KB·세션 순서 유지, 지우는 신호는 응답의 `accepted_event_ids`뿐이다. `retry_event_ids`는 남기고 같은 세션의 뒤 사건도 보류, `rejected`는 dead-letter, 묶음 400은 반으로 나눠 다시 보낸다. 401·403·404·429·5xx에는 지우지 않는다. 글은 UTF-8 32KB로 유니코드 스칼라 경계에서 자르고 전체는 원장에, 질문은 상한(4개·선택지 10개·길이)에 맞춰 자르거나(원래 선택지 값은 원장에 두고 답은 원래 값으로 되돌린다) 담을 수 없으면 그 요청을 거절로 닫는다.
- **heartbeat·한도:** 30초(±2초)마다, 시작·깨어남·연결 복귀·자격 회복 뒤와 lease 전(마지막 성공이 90초보다 오래됐을 때)에는 바로 보낸다. `tasks`는 원장이 아는 끝나지 않은 작업 전부(50개 우선순위: 살아 있음 → 질문 대기 → 최근)이고 `app_version`·`adapters`는 시작 때와 probe 결과가 바뀔 때만 싣는다(키를 뺀다, null 금지). 클라이언트 예산은 서버 한도의 80%(events 96·ack 192·poll 72 /분), 429는 `Retry-After`(없거나 못 읽으면 30초) 동안 그 route만 멈춘다. 목록 사이 최소 2초, 돌아온 항목이 모두 처리했거나 미룬 것이면 5초.
- **종료·재시작·꺼짐:** 실행 중인 턴(또는 전달하지 않은 비밀값 답)이 있으면 종료 때 확인 창("Quit Taskforce?" / "Running agent turns will stop." / Quit·Cancel)을 띄우고, Quit이면 턴을 중단하고 끝남을 본 턴은 `cancelled` 사건으로 알린 뒤 outbox를 최대 3초 비우고 종료한다. 강제 종료로 남은 고아 프로세스는 (pid, 시작 시각, marker)로 찾아 재시작 때 끝내고 원장으로 정산한다(접수 뒤였으면 `cancelled`). 새 실행은 lease가 새로 성공한 명령에만 있다. 업데이트 재시작은 Sparkle 2.10.0이 `updaterShouldRelaunchApplication`에서 false를 받으면 설치를 접기 때문에 그 질문은 true로 두고 `shouldPostponeRelaunchForUpdate`에서 한가해질 때까지 미룬다. `BRIDGE_ENABLED`(Info.plist `TaskforceBridgeEnabled` ← 빌드 설정 `TF_BRIDGE_ENABLED`, 모든 구성 기본 NO, Debug는 실행 인자 `-TF_BRIDGE YES`도 필요)가 꺼진 빌드는 네트워크·프로세스가 0이고, 꺼졌는데 원장에 할 일이 남았으면 **마무리 모드**(새 전달 0·새 등록 0, 사건·cancel·결과 확인·heartbeat는 계속)로 올라 일이 끝나면 멈춘다.
- **계정:** 런타임은 (파티션, 세대)에 묶인다. 계정이 떠나면 네트워크를 끊고(늦게 도착한 응답은 원장에 쓰지 않고 버린다) 살아 있는 턴은 그 파티션 원장에만 기록하며 계속 감독하고, 같은 사용자가 돌아오면 같은 파티션·같은 런타임을 잇는다. 요청을 보내기 직전에 토큰의 사용자가 파티션 사용자와 같은지 다시 본다.
- **확인 범위:** 가짜 서버(`FakeBridgeServer`)·가짜 agent·수동 시계로 ONE-TF-04·09·15와 AC-11의 bridge 몫을 Kit(`swift test`)과 격리 Mac 호스트 시험에서 확인한다. ONE-TF-11은 지연 측정 장치(`BridgeLatencyReport`: 원장 시각만으로 경로별 p50·p95)까지만이고 실제 수치는 실제 스택(코디네이터 MS-1)에서 잰다. 서명 빌드의 Keychain 실제 저장, 실제 `claude`·`codex`는 D3a·D3b·MS-2다.
- **인계:** D3a(`ClaudeCodeProcess`)·D3b(Codex)는 `AgentProcess`의 `probe`·`startTurn`·`deliverAnswer`·`closeRequest`·`interrupt`·`liveness`·`terminateOrphan`·`readback`을 구현하고, 접수 신호(`accepted`)를 언제 내는지는 adapter가 정한다. U2·D4a: 상태(`revoked`·`tooManyBridges`·`credentialRejected`·오프라인) 표시, Connect, Reconnect this Mac, 오래된 Mac 폐기 목록(10개 상한), `WorkspaceResolver`, `LocalSecretAnswers`에 비밀값 넣기, View full(원장 `full_texts`). 문서 정정(코디네이터): 아키텍처 9.3의 "모르는 kind는 `unsupported` 사건"은 "lease 전 `decline`"으로, "앱 종료 → 에이전트 프로세스 사망"은 "확인 종료는 중단, 강제 종료의 고아는 재시작 때 끝냄"으로, 런타임 12장 outbox 24시간은 "같은 파티션이면 7일까지 보낸다"로, 계획 D2b 행의 파일 위치는 Kit `Bridge/`로.
- **검토 반영(계약 7장):** (A) 한 task의 외부 작업 id는 처음 묶인 값을 바꾸지 않는다(답으로 새 프로세스를 띄워도, 서버는 다른 값을 final `conflict`로 버린다). 2xx인데 본문을 못 읽으면 일시 실패(물러섰다 다시, 행 유지)이고 묶음을 쪼개거나 dead-letter하는 것은 진짜 400뿐이다. 끝을 증명하지 못한 고아(`liveness == .unknown`)는 "확인 안 된 고아"다: heartbeat `process_alive` false, 결과 확인에는 `unknown` 한 번, Sparkle 재시작을 막지 않되 같은 세션의 다음 실행은 계속 막는다. `reactivate()`가 성공하면 루프를 다시 시작한다. (B) 마무리 모드는 할 일이 없으면 요청 없이 멈추고 호스트가 런타임을 놓는다. 원장 분실 · 기록 없음의 `declined` 기록과 `unknown` ack, run 시작(`start_intent`)의 task · 명령 두 행은 각각 한 트랜잭션이다. 나가는 값은 정리기 하나(`OutgoingValues`)가 서버 zod 한도(`sanitizer-limits.json`)에 맞춘다: `workspace_ref` 비어 있지 않음 · 500자, 외부 작업 · 세션 id 1–200자(자르지 않고 거절), 산출물 payload 4096바이트, NUL 제거, adapter version 50자, probe 보고가 없는 adapter는 connect하지 않는다. (C) 서버 숫자는 디코딩과 `recover()`에서 범위를 자른다(heartbeat 5–3600초 · unreachable 30–3600초 · long poll 1–25초, 음수 cursor는 건너뛰고 next_cursor는 본 cursor까지만). 서버가 준 작업 폴더는 `WorkspaceResolver.authorize`가 인정한 값(이 Mac이 고른 폴더)일 때만 쓰고 아니면 `not_received`로 거절하며, 재개 세션 id는 `^[A-Za-z0-9_-]{1,128}$`(맨 앞 `-` 제외)만 받는다. 종료 · 한가한 종료 · 계정 삭제는 중단 신호 뒤 3초 유예 다음에도 남은 실행을 `terminateOrphan`으로 끝낸다(턴이 `idle`이어도 프로세스가 남아 있으면 확인 창 없이 끝내고 종료). 계정 삭제는 끝낸 뒤에 원장 폴더 · Keychain을 지우고 지운 결과를 알린다. (D) WAL · SHM · 잠금 파일도 0600, 끝난 task · 질문 원래 값 · 세션 번호표 · 7일 지난 격리 파일을 정리, 자동 등록은 1시간 10회 예산과 점점 길어지는 간격(성공해도 초기화하지 않음), 401은 요청이 쓴 secret이 이미 낡았으면 다시 등록하지 않고 새 secret으로 재시도, bridge 요청은 https 또는 loopback만 · 리다이렉트 거절 · 응답 4MB 상한, 하위 프로세스 환경은 `HOME`·`PATH`·`LANG`·`USER`만, 가짜 agent는 서버 주소가 loopback일 때만, lease payload의 id · task · 세션이 lease한 항목과 다르면 거절하고 24시간 전달 창이 지난 명령은 띄우지 않는다, 더 새 원장 스키마는 손상과 구분해 열지도 옮기지도 않는다, 원장은 파티션 폴더의 `flock`으로 한 곳에서만 연다. **D4a 인계:** 비밀값 답은 질문 카드를 보인 때의 파티션에 묶어 넣는다(계정이 바뀐 뒤 다른 계정의 런타임에 들어가지 않게).
- **검토 반영 2(계약 8장):** Stop(cancel)은 24시간 전달 창의 적용을 받지 않는다: 언제 lease했든 돌고 있는 실행을 중단하고 `complete`로 정산한다(창은 message · answer의 `replay`에만). 모든 실행은 이 Mac이 승인한 작업 폴더가 있어야 한다: 서버가 폴더를 주지 않으면 재개(`external_session_id`)여도 `WorkspaceResolver`가 정하고, 없거나 비면 접수 전 `spawn_failed`다. 서버가 준 폴더는 resolver가 인정하거나 이 Mac이 그 세션에 기록한(`session_bound`) 값과 같을 때만 받는다. `AgentProcess`는 `workspaceRef == nil`이면 `startTurn` · `closeRequest`에서 `spawnFailed`를 던진다(D3a · D3b). marker는 UUID 모양만 adapter에 넘긴다. 답을 기다리던 task를 Stop으로 정산하면 원장도 `cancelled`로 닫고, 보관 정리는 살아 있지 않은 `dispatched` · `awaiting_answer` task도 7일 뒤 지운다. 응답 4MB 상한은 읽으면서 센다. 계정 삭제는 끝내지 못했거나 끝을 증명하지 못한 프로세스 수를 알리고(`CleanupResult.unterminatedProcesses`, 0이 아니면 `isComplete`가 false) 호스트는 런타임이 멈춰 있고 그 파티션이 다시 활성이 아닐 때(또는 마무리 모드)만 놓는다.

## 12. 대화 API v2 확장 (OA D1d-s)

`20261121000000_agent_conversation_api.sql`과 route 12개, 대화 handler 확장이다. 계약: Assistant 계약 v3 2–5장 · 8장. **운영 전달 gate는 닫힌 상태를 유지한다**. D2a와 통합되어 `prepared` 단계가 bridge 명령으로 이어지지만, 전달 활성화는 별도 작업이다.

### 12-1. gate

- 모든 새 route: `CONVERSATIONS_V2_ENABLED`가 꺼져 있으면 인증 · DB 전에 404. 에이전트 경로는 그 대화 · 세션 · 연결의 **adapter 플래그**도 켜져야 한다(꺼져 있으면 404): `AGENT_ADAPTER_CLAUDE_CODE_ENABLED`(기존) · **`AGENT_ADAPTER_CODEX_ENABLED`(새, 기본 꺼짐)**. 꺼진 adapter는 대상 목록에서 빠지고 만들기 · 보내기가 404라 Action · 세션 · run이 생기지 않는다. 이전에는 Codex가 플래그 없이 늘 켜져 있었다(B2 대화를 켜는 순간 열리는 fail-open이라 닫았다).
- **예외: 대화 Stop · 세션 Stop은 adapter 플래그와 무관하게 돈다**(롤백 규칙 — 새 전달 gate가 닫혀도 받기 · 멈추기는 계속 된다, `CONVERSATIONS_V2_ENABLED` route gate는 그대로). 멈춘 뒤 "다음 대기 메시지 시작"만 adapter 플래그와 `EXECUTION_ENABLED`를 따른다(꺼져 있으면 부르지 않는다).
- 인증은 `authenticateRequest`(Bearer + 쿠키, 쿠키 쓰기는 CSRF). 로그에는 이벤트 이름 · 오류 이름 · 코드만 남긴다(글 · 칩 id · 답 · 질문 0).

### 12-2. route

| route | 하는 일 |
|---|---|
| `POST /api/v2/conversations` | `target: {kind:"taskforce"} \| {kind:"agent", connection_id, session_id?}`. 같은 id에 다른 대상이면 409 `target_mismatch`. 연결이 내 것 · revoked 아님 · registry · adapter 켜짐, 세션이 같은 연결 · closed 아님이 아니면 404. 응답 대화에 `target_kind` · `agent_connection_id` · `agent_session_id` |
| `POST …/{id}/messages` | `attachments`(≤ 20) 추가. 에이전트 대상은 delegate로 넘어가 칩 정규화 → 소유 확인(없는 · 남의 칩 404, 쓰기 0) → 저장(`selected` = `{action_ids, context_ids, attachments}` — added만 id 목록) → 새 메시지면 `context_attached` → 전달 시작 → 다시 읽은 행으로 응답(`reply: null`, `delivery`, `attachments_dropped`, `created_action`, `agent_task`). 같은 제출 재전송에서 그 사이 지워진 칩은 404가 아니라 `attachments_dropped`(`deleted`)이고, 처리 입력(`start_agent_turn`의 Action 칩)에서 빠진다(저장된 `selected`는 처음 그대로). taskforce 대상은 칩을 검증 · 저장만 하고 응답 모양 · 답 생성은 그대로이며, **같은 제출인지를 칩 존재 확인보다 먼저** 보아(`known`) 재전송이면 지워진 칩이 있어도 저장된 응답을 돌려준다(처리용 refs에서만 뺀다; 첫 제출의 없는 칩은 404) |
| `POST …/{id}/deliver` | Send again. `requeue_agent_messages`(`not_sent` · `expired` → `queued`, 새 24시간) → commit 뒤 seq 순으로 하나씩 시작. **자동 시작은 `queued` 머리와 이유가 gate 계열(`write_gate_closed` · `not_connected` · `adapter_disabled`)인 `not_sent`뿐이다** — `spawn_failed` · `sign_in_needed` · `usage_limited` · `not_received` · `unsupported` 등으로 실패한 메시지는 이 route(사용자 Send again)로만 다시 시작한다(`autoStartable`, 검토 반영 7-1) |
| `POST …/{id}/messages/{message_id}/referent` | `needs_referent` 후보 선택 → 같은 메시지를 한 번 전달 |
| `POST …/{id}/stop` · `POST /api/v2/agent-sessions/{id}/stop` | 세션 단위 중단(surface `assistant` · `session_panel`). 세션 없는 대화는 `{tasks:[]}`(쓰기 0). 확정(`confirmed`)된 작업이 있고 adapter 플래그가 켜져 있으면 commit 뒤 `startNextQueuedTurn` 한 번(실패해도 Stop 결과 유지) |
| `GET …/{id}/delivery?since_seq=` | 사용자 메시지의 전달 표시를 서버 계산으로(OD-13, ≤ 100, 읽기만) |
| `PATCH /api/v2/agent-sessions/{id}` | 이름(trim 1–200자). SQL `rename_agent_session`이 이름과 `session_renamed`를 같은 트랜잭션에서 쓴다 |
| `POST /api/v2/agent-sessions/{id}/open-external` · `…/resume-here` | `open_agent_session_external` · `resume_agent_session_here`. busy → 409 `session_busy`, `pending:` 세션 · bound 아님 → 409 `conflict`. Resume은 본문 `{confirmed_terminal_closed:true}` 필수, 되돌린 뒤 `startNextQueuedTurn` 한 번(이미 bound여도 한 번 확인). 묶인 대화 잠금 경합(`55P03`)은 TS가 세 번까지 다시 부르고 그래도 안 되면 409 `busy_retry` |
| `GET /api/v2/assistant/targets` | taskforce + registry 순서(claude-code · codex) 연결별 한 행, 연결 없으면 `not_connected` 한 행. 상태 순서: error · bridge 없음 · revoked → `not_connected`, heartbeat 없음 · 90초 넘음 → `unreachable`, 서버 registry가 직접 대화를 못 하면 `unsupported`, 그 밖 `ready`. 초기 registry: Claude Code `unsupported`/`null`, Codex `ready`/`read_only`. F1s: 행마다 `device_name`(그 연결 bridge의 표시용 Mac 이름 1–64 코드 포인트, 모르면 `null`)과 `bridge_id`(연결의 bridge, 연결 없으면 `null`)를 더한다 — 이름은 상태 계산에 쓰지 않는다(`assistantTargetsWithDeviceResponseSchema`) |
| `POST /api/v2/agent-tasks/{id}/answer` | input 질문의 구조화된 답. 열쇠가 다르면 409 `question_stale`, 승인 409 `approval_via_review`, 비밀값 409 `secret_requires_local`(RPC 0). 같은 답은 `duplicate`(같은 step). 답 단계 앞의 입력 오류는 400 |
| `GET /api/cron/execution-sweep` | 실행 플래그 조기 반환 **앞에서** `conversation_expire_agent_messages`를 1,000행이면 반복(최대 10회). 실패는 가두고 응답 · 상태 코드 불변 |

오류 코드는 `apiErrorV2AgentCodeSchema`(기존 v2 코드 + `target_mismatch` · `question_stale` · `secret_requires_local` · `session_busy` · `approval_via_review` · `busy_retry`). 잠금 경합(55P03) · 직렬화 실패(40001) · 교착(40P01)은 쓰기가 롤백됐으니 409 `busy_retry`(같은 요청을 다시 보내도 된다, 500 아님). D1d의 SQL 호출은 TS에서 먼저 두 번까지 다시 부른다(`src/lib/agents/retry.ts`).

### 12-3. 전달 표시 계산 (`agentDeliveryView`, 순수 함수)

원문 메시지의 단계는 `task.step_id`(질문에 답하면 답 단계로 옮겨 간다)가 아니라 **그 메시지를 가리키는 최신 task의 `run_id` 안에서 `args->>'message_id'`가 그 메시지인 `agent_message` 단계 중 seq 최대**로 읽는다(run 구분 없는 seq 최댓값이면 옛 run의 실패가 새 run의 접수를 이긴다, 검토 반영 8-3)(검토 반영 7-4: 원문 `accepted` → 답 단계 실패여도 원문은 `accepted`, 답 메시지만 `not_sent`). 답 메시지는 그 답 단계(`args->>'answer_message_id'`)로 계산한다.

`cancelled` → `cancelled` · `refs.answer_for`(질문에 자유 글로 답한 메시지) → 답 단계가 `failed`면 `not_sent`(+ 단계 receipt 이유), `skipped`면 `cancelled`, 그 밖은 `answered` · `queued` + 후보 + 아직 안 고름 → `needs_referent`(제목 ≤ 3) · `queued`/`not_sent`/`expired` → 그 상태 + 이유 · `dispatched` → 단계 `prepared`/`calling` = `sent`, `called` = `accepted`, `unknown_outcome` = `unknown`, 그 밖 `not_sent`(방어). D2a 통합: 세션이 `unreachable`이고 단계가 `prepared`면 `queued`로 표시한다(OD-11). `calling` 이후의 전달 표시는 그대로 유지한다. 이유는 계약 9개 + SQL이 쓰는 8개 = 17개(`agentDeliveryReasonSchema`, 마이그레이션 문자열 정적 시험).

### 12-4. 새 SQL (서버 전용 invoker, service_role만 실행)

- `requeue_agent_messages(user, conversation, message_ids|null)`: 대상 상태만(`cancelled`는 끝 상태 · 결과 불명 `unknown_outcome` · 질문의 답 `refs.answer_for` 제외), 메시지를 id 순으로 `for update`. 이름을 준 id가 이 대화의 것이 아니면 `skipped/not_found`. **잠근 행의 id를 배열로 고정**해 그 행만 처리하고(일괄 호출의 두 번째 조회가 대상을 다시 고르면, 처음에 빠졌던 잠그지 않은 행이 섞여 들어 다른 요청이 재전송해 `dispatched`로 commit한 행을 `queued`로 덮는다 — 검토 반영 10-1), 갱신도 지금 `not_sent` · `expired`일 때만 한다.
- `open_agent_session_external` · `resume_agent_session_here`: 묶인 대화(id 순) → 세션 순으로 잠근 뒤 **세션을 잡은 직후 묶인 대화를 `for update nowait`로 한 번 더 확인한다**(검토 반영 7-2: 첫 조회와 세션 잠금 사이에 새 대화가 연결되고 다른 요청이 그 대화를 쥐면 서로 기다려 교착하므로 `55P03`으로 원자 실패, Stop과 같은 방식). 대화마다 `event` 줄("Opened in Terminal" · "Resumed here") + 지표. 진행 중 턴이 있으면 busy → `pending:` 세션 not_started → bound 아님 not_bound. 경로 lease 해제는 D3c-2가 `open_agent_session_external`에 건다.
- `start_agent_turn_auto(user, message, access, live_limit, action_ids, context_ids)`: 자동 시작(대기열 머리 · Resume here · Stop 뒤 · `queue_order` 뒤)의 입구 (검토 반영 8-1). TS가 고른 메시지 id를 그대로 받아 `route_agent_message`와 같은 순서로 그 메시지 행을 먼저 잠근 뒤 상태를 다시 읽는다 — `queued`이거나 `not_sent` + 이유가 gate 계열(`write_gate_closed` · `not_connected` · `adapter_disabled`)이면 같은 트랜잭션에서 `route_agent_message`를 부르고, 아니면 아무것도 하지 않고 `{status:'skipped'}`. 검사한 뒤 다른 요청이 상태를 바꿔도(앞 메시지가 만료돼 `not_sent/spawn_failed`가 머리가 되는 등) 낡은 상태로 새 회차를 만들지 않는다. 없는 · 남의 메시지는 `route_agent_message`의 `not_found` 그대로. **잠금 대상 고정(검토 반영 9-2)**: 메시지를 잠그기 전에 답 경로가 쓸 원문(질문을 낸 메시지) · 사건 기준을 한 번 읽어 두고, 잠금을 얻은 뒤 다시 읽어 달라졌으면(기다리는 사이 질문이 열리거나 닫힘) `route_agent_message`가 원문을 M 뒤에 잠그려다 (원문 → M 순으로 잠그는 다른 요청과) 교착하지 않도록 추가 잠금 전에 `40001`로 롤백한다. TS(`startPinnedAgentMessage` 외 D1d의 SQL 호출 전부)가 `40001` · `40P01` · `55P03`을 두 번까지 다시 부르고(`retryOnConflict`), 그래도 안 되면 handler가 409 `busy_retry`(교착 `40P01`도 500이 아니다). 래퍼가 읽고 `route_agent_message`가 읽기까지의 짧은 틈은 남는다 — 그때의 교착은 DB가 한쪽을 `40P01`로 끊고 같은 재시도 경로로 간다.
- `mark_agent_message_not_sent_auto(user, message, reason, from_gate)`: 자동 경로의 `not_sent` 표시(실행 kill switch 꺼짐 · 연결 · 등급 거절 · 진짜 `not_found` · `already_dispatched`)를 **메시지를 잠근 뒤 그때의 상태를 다시 보고** 한다 — 지금 `queued`일 때만 `mark_agent_message_not_sent_auto`를 부르고(`from_gate`가 참이면 gate 계열 이유의 `not_sent`도), 읽은 뒤 다른 요청이 전달 · `spawn_failed`로 만든 메시지의 이유는 덮지 않고 `{status:'skipped'}`(검토 반영 9-1). kill switch 꺼짐 표시는 `from_gate` 거짓(어떤 `not_sent`도 안 덮음).
- `answer_agent_question_recorded(…)`: D1c-2b `answer_agent_question`의 본문은 그대로 두고 그 결과가 `answered`일 때만 같은 트랜잭션에서 `question_answered`(kind · adapter만)를 쓴다 — `duplicate` · 잘못된 답 · 낡은 질문은 지표 0. `rename_agent_session(user, session, name)`: 실제로 바뀔 때만 `session_renamed`(adapter만); 같은 이름은 `unchanged`, 없거나 남의 세션은 `not_found`, 1–200자 밖이면 `22023`. 새 지표 다섯은 모두 상태 변경과 같은 트랜잭션이다(지표 insert가 실패하면 상태도 롤백).
- 공통 metric 블록 **v2**를 글자 그대로 넣었다: type에 `message_resent` · `question_answered` · `session_renamed` · `session_opened_external` · `session_resumed` 추가. 앱이 직접 쓰는 type은 `app_opened` · `assistant_opened` 그대로.

### 12-5. 쓰기 경로별 기록 (OD-16)

| 쓰기 | 기록 |
|---|---|
| 메시지 저장(두 대상) | `context_attached`(칩마다, 새 메시지만, TS insert — 저장 뒤 insert 실패 시 그 지표만 빠질 수 있다) |
| 전달 시작 | `agent_message_sent`(SQL, 시작될 때만) |
| Send again | `message_resent`(SQL, 다시 대기시킨 메시지마다) |
| referent | 시작될 때 `agent_message_sent` |
| Stop | `stop_requested`(SQL) + 대화에 "Queued messages cancelled" |
| 질문 답 | 대화 `event` 줄 + `question_answered`(SQL 래퍼 `answer_agent_question_recorded`, 같은 트랜잭션, 종류 · adapter만, `answered`일 때만) |
| 이름 바꾸기 | `session_renamed`(SQL `rename_agent_session`, 같은 트랜잭션, 실제로 바뀔 때만, adapter만) |
| Open in Terminal · Resume here | `event` 줄 + `session_opened_external` · `session_resumed`(SQL) |

### 12-6. 경계 · 잠금

- 대화 모듈(`src/lib/conversation`)과 `src/lib/api/conversations.ts`는 `@/lib/agents`도 `agent-conversations`도 가져오지 않는다(I04, `boundary.test.ts`): 에이전트 논리는 `src/lib/api/agent-conversations.ts` + `src/lib/agents/*`에만 있고, v2 대화 route는 그것을 주입된 delegate로만 받는다. 에이전트 경로는 `respondToMessage` · Jev · LLM을 부르지 않는다.
- 잠금 순서는 D1c와 같다(메시지 → 사용자 advisory → 대화 → 세션 → run → task → step). `startNextQueuedTurn`은 잠금을 쥔 채 부르지 않고, 쓰기 함수가 끝난 뒤에만 부른다. 실제 Postgres 경합 시험: `tests/pg/agent-conversation-api.test.ts`(Send again 동시 · requeue ↔ 만료 sweep · open-external ↔ start/route · resume-here ↔ stop).

### 12-7. 실행 kill switch 방어 (D2a 보안 검토 P1)

`EXECUTION_ENABLED`가 꺼져 있으면 에이전트 대상의 모든 전달 시작 경로(보내기 · Send again · referent · Resume here · Stop 뒤 다음 시작 · `queue_order` 뒤 다음 시작)가 턴을 시작하지 않고, 메시지(대기열 머리)를 기존 `mark_agent_message_not_sent_auto` 경로로 `not_sent`/`write_gate_closed`로 표시한다(HTTP 200, 보통 응답 모양). 꺼진 채 시작하면 전달될 수 없는 task · 단계 · 명령 · `agent_message_sent` 지표가 생기고, bridge가 거둔 것을 자동 계기가 다시 시작하는 끝없는 반복이 되기 때문이다. 확인은 `lib/agents/next-turn.ts`(`markWriteGateClosed` · `startNextAgentMessage`)와 `startAgentMessage`에 있고 `turns.ts`의 함수 본문은 바꾸지 않았다. DB 쪽 gate(`execution_controls` · 실행 주체 · 도구)는 여전히 bridge lease의 몫이다. **자동 시작 경로는 대기열 머리를 한 번만 고르고 그 id를 끝까지 고정한다**(`startNextAgentMessage` → D1d 자신의 시작 함수 `startPinnedAgentMessage` → SQL `start_agent_turn_auto`; `turns.ts`의 `startNextQueuedTurn`은 D1d 경로에서 쓰지 않는다 — 그 안의 머리 재선택이 만료 경합에서 실패한 `not_sent`를 시작했다). 시작 입력의 칩에서는 지워진 Action을 뺀다(저장된 `selected`는 그대로); 진짜 `not_found` · `already_dispatched`는 `mark_agent_message_not_sent_auto`로 대기열에서 뺀다. **표시는 지금 `queued`인 메시지만 한다 — SQL `mark_agent_message_not_sent_auto`가 메시지 잠금 안에서 현재 상태를 다시 보고 결정하며 TS가 미리 읽은 상태로 판단하지 않는다** — 이미 `not_sent`인 메시지의 이유(예: `spawn_failed`)는 덮어쓰지 않는다(검토 반영 7-1). 자동 시작 대상은 `queued`와 이유가 gate 계열인 `not_sent`뿐이라(`autoStartable`), 실패한 머리는 Send again 또는 Stop으로 풀 때까지 SQL FIFO(`queue_order`)가 뒤 메시지를 붙잡는다.

### 12-8. 다음 WP 인계

- **D2a 통합:** 사건 commit 뒤와 heartbeat의 자동 시작은 `startPinnedAgentMessage`로 같은 메시지를 잠금 검사하며, 세션 없는 대화의 재개·끊긴 세션의 `prepared` → `queued` 표시도 연결했다. 운영 전달 gate는 닫힌 상태다. 비밀값 로컬 답(`answered_locally`) 입구와 Codex `thread/unsubscribe`의 Mac 실행은 후속 WP가 연결한다.
- **D3c-2:** 승인 질문 답(Review의 Allow · Deny), `open_agent_session_external`의 lease 해제. **D4b-s:** Review 답 = `POST /api/v2/agent-tasks/{id}/answer`. **U1 · D4a:** `target_kind`로 대화 거르기, 새 오류 code 처리, 전달 읽기 route. 이슈 Done 뒤 `startNextQueuedTurn` 호출은 Action route 쪽(`writeAction`)이 연결한다(이 WP의 범위 밖).
- 적용: 운영 DB에는 병합 직전 승인을 받고 7-7의 방법으로만 한다. `metric_events`에 `access exclusive` 잠금을 NOWAIT로 건다(경합이면 마이그레이션만 `55P03`으로 실패하니 그대로 다시 적용).

## 13. 승인 정책 · 경로 lease (OA D3c-2)

`20261123000000_agent_path_leases.sql`은 `20261121000000` 뒤에 적용한다. 공통 지표 블록 v3를 그대로 쓰며, CHECK 교체와 트리거 생성에 필요한 표와 `bridges`의 잠금을 처음에 NOWAIT로 확인한다. 새 서버 플래그는 없다. 초기 registry에서 Claude Code는 등급 없음, Codex는 `read_only`이므로 실제 쓰기 허용 증거는 아니다.

- `POST /api/v1/bridge/tool-decision`: 인증 → 64 KiB 이하 strict 본문 → 같은 기기 secret → 순수 결정표 → SQL 재검증 순서다. 명령·쓰기 본문을 저장하거나 로그에 남기지 않는다. 입력은 Bash·Edit/Write·Codex command/file-change 네 종류뿐이며, 응답은 `allow | deny | defer`, 정해진 reason, 필요한 parse·holder·카드 flag만 준다. `maxDuration=5`, `Cache-Control: no-store`. bridge별 600회/분은 결정 RPC 안에서 확인하고 초과는 `deny/rate_limited`로 기록한다.
- Manual에서도 작업 폴더 안 읽기 전용 단일 명령은 파서가 허용하면 자동 허용한다(사용자 결정 Q17). Manual 쓰기는 예약 후 승인 질문으로, Claude Code Auto/Full 쓰기는 lease 획득 후 허용한다. Codex Manual command는 최초 요청·읽기 action 종류·파서 허용을 모두 만족해야 한다. Codex Auto/Full 요청은 `defer`와 `runs_without_sandbox` 표시다. bridge 정적 판정이 먼저이며 서버에 명령 허용 목록은 없다.
- SQL은 사용자·bridge·adapter 귀속, 세션/run/task의 살아 있음, 정책 mode, 기존 DB gate와 workspace를 다시 확인한다. 정책 변경은 쓰기 없이 반환하고 TS가 한 번 다시 계산한다. 잠금 순서는 세션 공유 → run 공유 → task 공유 → 경로 열쇠 오름차순이며 Action은 잠그지 않는다. 잠금 대기 250ms 초과는 허용을 늘리지 않고 `defer/server_busy`로 내린다.
- `agent_path_leases` 열쇠는 사용자 × bridge × NFC 정규화·`ſ`→`s` 변환·ASCII 대소문자 접기를 한 절대 realpath다. 같은 run은 이어 쓰고 같은 세션의 다른 이슈도 양보한다. 여러 대상 중 하나가 다른 run의 것이면 이번 획득은 모두 롤백하고 그 holder의 waiter만 추가한다(중복 없이 최대 20). 응답의 `holder`에는 Action 번호·상대 경로만 있고 run id는 없다.
- **12장의 승인 답 409는 이 WP에서 열린다.** Assistant와 Review 모두 `POST /api/v2/agent-tasks/{id}/answer`에 `{provider_request_id, answers:{approval:"allow"|"deny"}}`를 보낸다. 질문은 id `approval` 하나여야 한다. `answer_agent_approval`은 기존 답 함수를 호출한 뒤 성공한 같은 요청의 예약만 승인하거나 해제하고 `question_answered {kind:approval}`를 한 번 기록한다. 입력 질문·비밀값·자유 글 답 규칙은 유지한다. 답 뒤 adapter resume는 원장의 답을 쓰고 결정 API를 다시 부르지 않는다.
- task가 `accepted/running/awaiting_answer`로 들어가면 만료를 지운다. `idle/failed/cancelled`이면 미승인 예약을 해제하고 승인·관찰 lease는 30분 뒤로 설정한다. `unreachable`은 유지한다. run 종료는 즉시 해제, external 전환은 해당 세션의 lease를 해제한다. 결정·산출물 처리도 만료되거나 끝난 run의 lease를 바로 해제한다. 실행 플래그와 무관하게 cron이 만료·종료 백업 정리를 한다. 해제 30일 뒤 삭제하되 미해소 충돌은 보존한다.
- 산출물의 경로가 비어 있으면 `observed` lease를 만든다. 다른 run의 경로를 실제로 썼으면 충돌을 기록하고 사건 commit 뒤 늦게 쓴 run을 멈춘다. 이 멈춤은 run → task → lease 순서, Action·세션 잠금 없이 `stopped_at=null`과 gate `path_conflict`를 사용한다. `55P03`은 최대 세 번 시도하고 남으면 cron이 재시도한다. `list_pending_path_conflict_stops`는 같은 사용자의 충돌 run이 `queued/running/waiting_approval`인 행만 한도 전에 고르므로 종료된 run이 다음 후보를 가리지 않는다. 파일 내용을 되돌리지는 않는다.
- 양보·해제·external·충돌 알림은 고정 id를 가진 대화 `event` 줄이다. 먼저 말을 거는 `agent_message`는 만들지 않는다. 알림이 전부 기록된 lease만 시각을 CAS 비교해 표시하므로 오래된 전달 확인이 뒤의 해제를 숨기지 않는다. `listPathConflicts`와 `resolve_path_conflict`는 D4b-s가 Review에 연결한다(항목 `path_conflict:<lease_id>`, version=`conflict_version`, 충돌 발생마다 증가하는 정수).
- 결정·충돌 발견·해소와 승인 답 지표는 상태 변경과 같은 DB 트랜잭션에 있다. props에는 명령·경로·id가 없다. bridge 로컬 결정 및 1초 초과 로컬 defer는 이 서버 지표에 포함되지 않는다. TS는 RPC를 중간에 취소하지 않아 bridge 시간 초과 뒤 서버 결과와 다를 수 있으며, 사후 충돌 규칙이 늦은 쓰기를 처리한다.

검토 반영: 설정 파일(`.git/.claude/.codex/.vscode/.idea/.husky/.githooks/.cargo` 아래와 `.envrc/.mcp.json/.gitattributes/.gitmodules/.yarnrc.yml/.npmrc/.pre-commit-config.yaml/lefthook.yml`)은 접힌 경로로 검사하고 Auto/Full도 승인 예약한다. Codex 설정 파일 요청도 Auto/Full 또는 같은 item의 반복 요청이면 `runs_without_sandbox`를 표시한다. 작업 폴더의 일치·포함은 대소문자를 보존한 NFC 경로로 검사하고 상대 경로는 SQL이 만든다. `pending:` 실제 폴더는 두 단 이상이어야 하며 홈 자체(`^/Users/[^/]+$`)는 거절한다. 경로 길이는 NFC 뒤에 재며, 산출물의 절대 경로가 1,000자 또는 작업 폴더가 500자를 넘으면 사건을 적용하고 lease만 건너뛴다. 미승인 예약은 사후 충돌 근거에서 제외하고, 끝난 run에는 관찰 lease를 만들지 않는다. 실제로 멈춘 충돌만 중단 시각·알림을 남긴다.

승인 재사용: 같은 열쇠의 다른 답이나 다시 열린 질문은 `question_stale`(409), Codex의 이미 답한 결정 열쇠는 `deny/not_first_request`다. D3b는 같은 item의 두 번째 이후 승인 요청에 회차 `:<n>`을 붙인다. 같은 run의 재사용 lease 중 `requested`만 현재 요청에 다시 연결한다. 기존 `approved/observed`는 source·request_id를 보존하고 만료만 지우므로 새 요청의 Deny로 해제되지 않는다. 서버의 늦은 `allow`가 새로 넣은 행은 그 요청의 Deny로 해제한다. 인증·기기 확인 뒤 프로세스 내 사전 한도를 검사하며, DB 한도는 그대로 최종 검증한다. 사전 거절에도 SQL 경로와 같은 `agent_note`를 붙이며, DB 결정 지표에는 포함되지 않는다.

검증은 `lib/agents/{tool-decision,path-leases,approvals}.test.ts`, `lib/bridge/tool-decision.test.ts`, 새 route 및 기존 연결부 시험, `tests/db/agent-path-leases*`에 있다. `tests/pg/agent-path-leases.test.ts`의 P1–P12는 실제 잠금 경합용으로 작성했으며 코디네이터가 실행한다. Mac realpath·PATH·명령 재구성, 훅 1.5초/서버 왕복 1초 및 p95, 실제 provider는 D3a/D3b의 검증이다. ASCII 밖 대소문자 충돌과 D2a gate 조회의 중복은 남는다.
