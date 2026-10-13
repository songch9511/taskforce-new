# 에이전트 게이트웨이 저장 계약 (0.2.0 D1a) — 결정 기록과 위치

2026-10-13 · 구현 계획 D1a · 근거: Assistant 계약 v3 3.4 · 3.6 · 3.8 · 4.2, 런타임 계약 5장(`agent_tasks` · `agent_sessions` · 사건 봉투), 아키텍처 9.1(bridge), I16 · AC-20.
**표 · 열 · 제약 · 인덱스 · RLS · 권한뿐이다. 에이전트를 실행하는 코드, route, gate, 앱 화면이 없다. 운영 DB 적용 전.** 이 문서는 "무엇을 만들었고, 무엇을 일부러 안 만들었고, 어디 있는가"만 적는다. 일반 규칙은 [FEATURE_MAP.md](FEATURE_MAP.md), 실행의 기본 계약은 [EXECUTION.md](EXECUTION.md), 같은 원칙의 앞 묶음은 `20261109000000_execution_additive_contract.sql`(C1)이다.

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
- `execution_tools` · `execution_controls`에 `agent:*` 행을 더하지 않았다(`create_run`의 goal `agent` 허용과 도구 · 스위치 행은 실행 입구를 실제로 쓰는 D1c-1에서 연다).
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
- (c) 연결 삭제는 그 연결의 대화가 있으면 거절된다(`restrict`). 연결 해제 경로는 대화를 먼저 정리하거나(보관 · 삭제) 연결을 `revoked`로만 두고 지우지 않는다(D1c 결정). 계정 삭제(`auth.users`)는 사용자 cascade로 둘 다 지워지며 시험이 확인한다(PGlite · 실제 Postgres).
- (d) 세션 단위 `event`(중단 확인 · 연결 끊김 · 결과 검토)는 그 세션에 묶인 **모든 대화**에 한 줄씩 쓴다 — append는 대화 하나에만 쓰므로 반복은 D1c-2의 몫이다. 같은 event id는 대화마다 따로 유일하다.
- (e) `delivery_state` 전이(`queued` → `dispatched` · `not_sent`, 되돌리기, `cancelled`)는 이 묶음에 없다. 전달 단계의 intent를 만드는 트랜잭션(D1c-1 · D1d)이 같은 트랜잭션에서 바꾼다. DB는 값의 모양과 이유 ↔ 상태만 본다.
- (f) 글 보관 기한 정리(V08)가 `delivery_reason` · `external_event_id`를 어떻게 다룰지는 정하지 않았다(`external_event_id`는 남기는 쪽이 계약 3.5). D1을 켜기 전에 정한다.

### 7-6. 하지 않은 것

- 측정 이벤트(계약 8장 `metric_events.props` · 새 type)는 첫 사용 WP(D1c-1)가 더한다. 이 묶음의 새 쓰기 경로는 8장 표에 대응하는 이벤트가 없다.
- `conversation_finish_turn` · `conversation_release_lease` 변경 · 턴 시작 · 전달 단계 · `agent_tasks` 쓰기 · route · `contract.ts` · Swift · 앱.

### 7-7. 적용

운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f supabase/migrations/20261114000000_conversation_agent_target.sql`로 한다(`db push` 금지). `20261113000000_agent_gateway_core` 뒤에 적용한다. 한 트랜잭션이고 `lock_timeout 5s`로 `conversations` · `conversation_messages`를 정해진 순서로 먼저 잠근다 — 잠금을 오래 기다리면 실패한다(그대로 다시 적용한다). 기존 행은 새 열이 기본값(`taskforce` · null)이라 영향이 없다.
