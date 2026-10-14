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
| `bridges` | Mac bridge 최소 identity. `device_ref`(기기 식별의 해시, 사용자당 유일) · `status`(`active` · `revoked`) · `capabilities`(bridge가 보고한 "설치돼 있고 이 버전" 값, JSON 객체) · `last_heartbeat_at` · `revoked_at` | 이름 · 이메일 열이 없다. `revoked` ↔ `revoked_at` |
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

## 11. 대화 API v2 확장 (OA D1d-s)

`20261121000000_agent_conversation_api.sql`과 route 12개, 대화 handler 확장이다. 계약: Assistant 계약 v3 2–5장 · 8장. **실제 전달은 여전히 막혀 있다**: bridge 명령을 만들지 않고 단계는 `prepared`까지, provider 스위치는 닫혀 있다(D2a가 연다).

### 11-1. gate

- 모든 새 route: `CONVERSATIONS_V2_ENABLED`가 꺼져 있으면 인증 · DB 전에 404. 에이전트 경로는 그 대화 · 세션 · 연결의 **adapter 플래그**도 켜져야 한다(꺼져 있으면 404): `AGENT_ADAPTER_CLAUDE_CODE_ENABLED`(기존) · **`AGENT_ADAPTER_CODEX_ENABLED`(새, 기본 꺼짐)**. 꺼진 adapter는 대상 목록에서 빠지고 만들기 · 보내기가 404라 Action · 세션 · run이 생기지 않는다. 이전에는 Codex가 플래그 없이 늘 켜져 있었다(B2 대화를 켜는 순간 열리는 fail-open이라 닫았다).
- **예외: 대화 Stop · 세션 Stop은 adapter 플래그와 무관하게 돈다**(롤백 규칙 — 새 전달 gate가 닫혀도 받기 · 멈추기는 계속 된다, `CONVERSATIONS_V2_ENABLED` route gate는 그대로). 멈춘 뒤 "다음 대기 메시지 시작"만 adapter 플래그와 `EXECUTION_ENABLED`를 따른다(꺼져 있으면 부르지 않는다).
- 인증은 `authenticateRequest`(Bearer + 쿠키, 쿠키 쓰기는 CSRF). 로그에는 이벤트 이름 · 오류 이름 · 코드만 남긴다(글 · 칩 id · 답 · 질문 0).

### 11-2. route

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
| `GET /api/v2/assistant/targets` | taskforce + registry 순서(claude-code · codex) 연결별 한 행, 연결 없으면 `not_connected` 한 행. 상태 순서: error · bridge 없음 · revoked → `not_connected`, heartbeat 없음 · 90초 넘음 → `unreachable`, 서버 registry가 직접 대화를 못 하면 `unsupported`, 그 밖 `ready`. 초기 registry: Claude Code `unsupported`/`null`, Codex `ready`/`read_only` |
| `POST /api/v2/agent-tasks/{id}/answer` | input 질문의 구조화된 답. 열쇠가 다르면 409 `question_stale`, 승인 409 `approval_via_review`, 비밀값 409 `secret_requires_local`(RPC 0). 같은 답은 `duplicate`(같은 step). 답 단계 앞의 입력 오류는 400 |
| `GET /api/cron/execution-sweep` | 실행 플래그 조기 반환 **앞에서** `conversation_expire_agent_messages`를 1,000행이면 반복(최대 10회). 실패는 가두고 응답 · 상태 코드 불변 |

오류 코드는 `apiErrorV2AgentCodeSchema`(기존 v2 코드 + `target_mismatch` · `question_stale` · `secret_requires_local` · `session_busy` · `approval_via_review` · `busy_retry`). 잠금 경합(55P03) · 직렬화 실패(40001) · 교착(40P01)은 쓰기가 롤백됐으니 409 `busy_retry`(같은 요청을 다시 보내도 된다, 500 아님). D1d의 SQL 호출은 TS에서 먼저 두 번까지 다시 부른다(`src/lib/agents/retry.ts`).

### 11-3. 전달 표시 계산 (`agentDeliveryView`, 순수 함수)

원문 메시지의 단계는 `task.step_id`(질문에 답하면 답 단계로 옮겨 간다)가 아니라 **그 메시지를 가리키는 최신 task의 `run_id` 안에서 `args->>'message_id'`가 그 메시지인 `agent_message` 단계 중 seq 최대**로 읽는다(run 구분 없는 seq 최댓값이면 옛 run의 실패가 새 run의 접수를 이긴다, 검토 반영 8-3)(검토 반영 7-4: 원문 `accepted` → 답 단계 실패여도 원문은 `accepted`, 답 메시지만 `not_sent`). 답 메시지는 그 답 단계(`args->>'answer_message_id'`)로 계산한다.

`cancelled` → `cancelled` · `refs.answer_for`(질문에 자유 글로 답한 메시지) → 답 단계가 `failed`면 `not_sent`(+ 단계 receipt 이유), `skipped`면 `cancelled`, 그 밖은 `answered` · `queued` + 후보 + 아직 안 고름 → `needs_referent`(제목 ≤ 3) · `queued`/`not_sent`/`expired` → 그 상태 + 이유 · `dispatched` → 단계 `prepared`/`calling` = `sent`, `called` = `accepted`, `unknown_outcome` = `unknown`, 그 밖 `not_sent`(방어). `prepared` = `sent`는 그대로다 — bridge가 끊긴 때의 표시는 heartbeat · lease를 가진 D2a가 고친다(OD-11). 이유는 계약 9개 + SQL이 쓰는 8개 = 17개(`agentDeliveryReasonSchema`, 마이그레이션 문자열 정적 시험).

### 11-4. 새 SQL (서버 전용 invoker, service_role만 실행)

- `requeue_agent_messages(user, conversation, message_ids|null)`: 대상 상태만(`cancelled`는 끝 상태 · 결과 불명 `unknown_outcome` · 질문의 답 `refs.answer_for` 제외), 메시지를 id 순으로 `for update`. 이름을 준 id가 이 대화의 것이 아니면 `skipped/not_found`.
- `open_agent_session_external` · `resume_agent_session_here`: 묶인 대화(id 순) → 세션 순으로 잠근 뒤 **세션을 잡은 직후 묶인 대화를 `for update nowait`로 한 번 더 확인한다**(검토 반영 7-2: 첫 조회와 세션 잠금 사이에 새 대화가 연결되고 다른 요청이 그 대화를 쥐면 서로 기다려 교착하므로 `55P03`으로 원자 실패, Stop과 같은 방식). 대화마다 `event` 줄("Opened in Terminal" · "Resumed here") + 지표. 진행 중 턴이 있으면 busy → `pending:` 세션 not_started → bound 아님 not_bound. 경로 lease 해제는 D3c-2가 `open_agent_session_external`에 건다.
- `start_agent_turn_auto(user, message, access, live_limit, action_ids, context_ids)`: 자동 시작(대기열 머리 · Resume here · Stop 뒤 · `queue_order` 뒤)의 입구 (검토 반영 8-1). TS가 고른 메시지 id를 그대로 받아 `route_agent_message`와 같은 순서로 그 메시지 행을 먼저 잠근 뒤 상태를 다시 읽는다 — `queued`이거나 `not_sent` + 이유가 gate 계열(`write_gate_closed` · `not_connected` · `adapter_disabled`)이면 같은 트랜잭션에서 `route_agent_message`를 부르고, 아니면 아무것도 하지 않고 `{status:'skipped'}`. 검사한 뒤 다른 요청이 상태를 바꿔도(앞 메시지가 만료돼 `not_sent/spawn_failed`가 머리가 되는 등) 낡은 상태로 새 회차를 만들지 않는다. 없는 · 남의 메시지는 `route_agent_message`의 `not_found` 그대로. **잠금 대상 고정(검토 반영 9-2)**: 메시지를 잠그기 전에 답 경로가 쓸 원문(질문을 낸 메시지) · 사건 기준을 한 번 읽어 두고, 잠금을 얻은 뒤 다시 읽어 달라졌으면(기다리는 사이 질문이 열리거나 닫힘) `route_agent_message`가 원문을 M 뒤에 잠그려다 (원문 → M 순으로 잠그는 다른 요청과) 교착하지 않도록 추가 잠금 전에 `40001`로 롤백한다. TS(`startPinnedAgentMessage` 외 D1d의 SQL 호출 전부)가 `40001` · `40P01` · `55P03`을 두 번까지 다시 부르고(`retryOnConflict`), 그래도 안 되면 handler가 409 `busy_retry`(교착 `40P01`도 500이 아니다). 래퍼가 읽고 `route_agent_message`가 읽기까지의 짧은 틈은 남는다 — 그때의 교착은 DB가 한쪽을 `40P01`로 끊고 같은 재시도 경로로 간다.
- `mark_agent_message_not_sent_auto(user, message, reason, from_gate)`: 자동 경로의 `not_sent` 표시(실행 kill switch 꺼짐 · 연결 · 등급 거절 · 진짜 `not_found` · `already_dispatched`)를 **메시지를 잠근 뒤 그때의 상태를 다시 보고** 한다 — 지금 `queued`일 때만 `mark_agent_message_not_sent`를 부르고(`from_gate`가 참이면 gate 계열 이유의 `not_sent`도), 읽은 뒤 다른 요청이 전달 · `spawn_failed`로 만든 메시지의 이유는 덮지 않고 `{status:'skipped'}`(검토 반영 9-1). kill switch 꺼짐 표시는 `from_gate` 거짓(어떤 `not_sent`도 안 덮음).
- `answer_agent_question_recorded(…)`: D1c-2b `answer_agent_question`의 본문은 그대로 두고 그 결과가 `answered`일 때만 같은 트랜잭션에서 `question_answered`(kind · adapter만)를 쓴다 — `duplicate` · 잘못된 답 · 낡은 질문은 지표 0. `rename_agent_session(user, session, name)`: 실제로 바뀔 때만 `session_renamed`(adapter만); 같은 이름은 `unchanged`, 없거나 남의 세션은 `not_found`, 1–200자 밖이면 `22023`. 새 지표 다섯은 모두 상태 변경과 같은 트랜잭션이다(지표 insert가 실패하면 상태도 롤백).
- 공통 metric 블록 **v2**를 글자 그대로 넣었다: type에 `message_resent` · `question_answered` · `session_renamed` · `session_opened_external` · `session_resumed` 추가. 앱이 직접 쓰는 type은 `app_opened` · `assistant_opened` 그대로.

### 11-5. 쓰기 경로별 기록 (OD-16)

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

### 11-6. 경계 · 잠금

- 대화 모듈(`src/lib/conversation`)과 `src/lib/api/conversations.ts`는 `@/lib/agents`도 `agent-conversations`도 가져오지 않는다(I04, `boundary.test.ts`): 에이전트 논리는 `src/lib/api/agent-conversations.ts` + `src/lib/agents/*`에만 있고, v2 대화 route는 그것을 주입된 delegate로만 받는다. 에이전트 경로는 `respondToMessage` · Jev · LLM을 부르지 않는다.
- 잠금 순서는 D1c와 같다(메시지 → 사용자 advisory → 대화 → 세션 → run → task → step). `startNextQueuedTurn`은 잠금을 쥔 채 부르지 않고, 쓰기 함수가 끝난 뒤에만 부른다. 실제 Postgres 경합 시험: `tests/pg/agent-conversation-api.test.ts`(Send again 동시 · requeue ↔ 만료 sweep · open-external ↔ start/route · resume-here ↔ stop).

### 11-7. 실행 kill switch 방어 (D2a 보안 검토 P1)

`EXECUTION_ENABLED`가 꺼져 있으면 에이전트 대상의 모든 전달 시작 경로(보내기 · Send again · referent · Resume here · Stop 뒤 다음 시작 · `queue_order` 뒤 다음 시작)가 턴을 시작하지 않고, 메시지(대기열 머리)를 기존 `mark_agent_message_not_sent` 경로로 `not_sent`/`write_gate_closed`로 표시한다(HTTP 200, 보통 응답 모양). 꺼진 채 시작하면 전달될 수 없는 task · 단계 · 명령 · `agent_message_sent` 지표가 생기고, bridge가 거둔 것을 자동 계기가 다시 시작하는 끝없는 반복이 되기 때문이다. 확인은 `lib/agents/next-turn.ts`(`markWriteGateClosed` · `startNextAgentMessage`)와 `startAgentMessage`에 있고 `turns.ts`의 함수 본문은 바꾸지 않았다. DB 쪽 gate(`execution_controls` · 실행 주체 · 도구)는 여전히 bridge lease의 몫이다. **자동 시작 경로는 대기열 머리를 한 번만 고르고 그 id를 끝까지 고정한다**(`startNextAgentMessage` → D1d 자신의 시작 함수 `startPinnedAgentMessage` → SQL `start_agent_turn_auto`; `turns.ts`의 `startNextQueuedTurn`은 D1d 경로에서 쓰지 않는다 — 그 안의 머리 재선택이 만료 경합에서 실패한 `not_sent`를 시작했다). 시작 입력의 칩에서는 지워진 Action을 뺀다(저장된 `selected`는 그대로); 진짜 `not_found` · `already_dispatched`는 `mark_agent_message_not_sent`로 대기열에서 뺀다. **표시는 지금 `queued`인 메시지만 한다 — SQL `mark_agent_message_not_sent_auto`가 메시지 잠금 안에서 현재 상태를 다시 보고 결정하며 TS가 미리 읽은 상태로 판단하지 않는다** — 이미 `not_sent`인 메시지의 이유(예: `spawn_failed`)는 덮어쓰지 않는다(검토 반영 7-1). 자동 시작 대상은 `queued`와 이유가 gate 계열인 `not_sent`뿐이라(`autoStartable`), 실패한 머리는 Send again 또는 Stop으로 풀 때까지 SQL FIFO(`queue_order`)가 뒤 메시지를 붙잡는다.

### 11-8. 다음 WP 인계

- **D2a(bridge API):** 턴 끝(idle · failed · cancelled) → 다음 대기 메시지 시작은 사건 route가 commit 뒤 `startNextQueuedTurn`으로(D1d는 보내기 · deliver · referent · Stop · Resume 뒤에만 부른다). 세션 없는 대화의 자동 전달 계기 ②, 끊김 표시(`prepared` = `sent` 보정, OD-11), heartbeat 상수(90초는 `targets.ts`), 비밀값 로컬 답(`answered_locally`) 입구, Codex `thread/unsubscribe` 순서(서버가 먼저 `external`로 막고 Mac이 그다음), `sign_in_needed` · `version_unsupported` 보고, 묶음은 added 칩만(AC-6).
- **D3c-2:** 승인 질문 답(Review의 Allow · Deny), `open_agent_session_external`의 lease 해제. **D4b-s:** Review 답 = `POST /api/v2/agent-tasks/{id}/answer`. **U1 · D4a:** `target_kind`로 대화 거르기, 새 오류 code 처리, 전달 읽기 route. 이슈 Done 뒤 `startNextQueuedTurn` 호출은 Action route 쪽(`writeAction`)이 연결한다(이 WP의 범위 밖).
- 적용: 운영 DB에는 병합 직전 승인을 받고 7-7의 방법으로만 한다. `metric_events`에 `access exclusive` 잠금을 NOWAIT로 건다(경합이면 마이그레이션만 `55P03`으로 실패하니 그대로 다시 적용).
