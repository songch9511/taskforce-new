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
| `agent_tasks` | 원격 작업(턴 하나 또는 맡긴 작업 하나). `run_id` · `step_id` · `agent_session_id` · `message_id` · `state`(아홉 값, `idle` 포함) · `last_live_state` · 지시 버전 · 결과 회차 · `pending_question` · `result_refs` | `idle`은 `completed`가 아니다(턴의 끝). `awaiting_answer`이면 `pending_question`이 있다. 질문 모양은 서버 zod가 검증한다 |

## 3. 기존 표 확장

- `execution_runs`: `kind`(`task` 기본 · `conversation`) · `agent_session_id`(세션이 지워지면 비움) · `reviewed_turn_seq`(마지막 검토가 본 턴). `conversation`은 goal `agent`뿐. 부분 unique `(agent_session_id, action_id) where kind = 'conversation' and state not in ('done','failed','stopped')`: 세션 × 이슈마다 열린 대화 run은 하나.
- `execution_events`: `type`에 `'agent'` 추가 + `external_event_id` · `external_seq` · `directive_version` · `turn_seq` · `bridge_id` · `payload`. `type = 'agent'` ↔ `external_event_id` 있음. 부분 unique `(run_id, external_event_id) where type = 'agent'`: 같은 사건은 run마다 한 번만. **`payload`에 글을 담지 않는다**(질문 글은 `agent_tasks.pending_question`, 결과 글은 산출물에만) — 검증은 서버 코드(D1c-2)이고 DB는 JSON 객체인지만 본다. 앱은 `execution_events`를 읽지 못한다.
- 기존 트리거(`execution_runs_log` 등) · 함수는 바꾸지 않았다.

## 4. 불변식 (DB가 막는 것 / 서버가 지킬 것)

| 규칙 | DB 백스톱 | 실제로 지키는 곳 |
|---|---|---|
| 세션당 진행 중 턴 하나(`dispatched` · `accepted` · `running` · `awaiting_answer`) | `agent_tasks_in_progress_idx` | D1c-1: 새 턴을 시작할 때 `agent_sessions` 행을 `for update`로 잡고 판단 |
| 같은 세션의 `turn_seq`는 한 번만 | `agent_tasks_session_turn_idx` | D1c-1: `last_turn_seq`를 올린 값을 적는다 |
| 세션 × 이슈마다 열린 대화 run 하나 | `execution_runs_open_conversation_idx` | D1c-1: unique 위반이면 첫째 run을 다시 읽어 쓴다 |
| 같은 사건은 한 번만 적용 | `execution_events_agent_dedup_idx` | D1c-2: 사건 봉투를 받을 때 |
| 남의 bridge · 연결 · 세션 · run · 메시지를 가리키지 못한다 | 복합 외래키 | — |
| 부모를 지우면 기록은 남고 참조만 빈다(`step_id` · `message_id` · `bridge_id` · `agent_session_id` · `bound_action_id`), 소유 관계는 함께 지운다(연결 → 세션 → 작업, run → 작업) | `on delete set null (열)` / `cascade` | — |

## 5. 하지 않은 것 — 실행 입구는 D1c가 연다

이 묶음 뒤에도 goal `agent` run은 만들어지지 않고 어떤 에이전트 단계도 실행되지 않는다.

- `create_run`(goal `draft`만) · `append_step`(`plan` · `draft` · `external`만) · `begin_call` · `approve_*` · 실행기는 한 글자도 바꾸지 않았다. 이 파일은 함수를 만들지도 바꾸지도 않는다.
- `execution_tools` · `execution_controls`에 `agent:*` 행을 더하지 않았다(`create_run`의 goal `agent` 허용과 도구 · 스위치 행은 실행 입구를 실제로 쓰는 D1c-1에서 연다).
- 이 묶음에 없는 것: `bridge_commands`(D2a) · `agent_path_leases`(D3c) · `conversations` · `conversation_messages` 열(D1b) · `context_members`의 agent_session 종류 · `execution_artifacts` 열 · route · gate · 앱 화면.
- 사건 `payload`의 "글 없음" 규칙, `pending_question`의 모양, `turn_seq` 직렬화는 서버 코드가 한다(위 4장).

## 6. 적용

운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f supabase/migrations/20261113000000_agent_gateway_core.sql`로 한다(`db push` 금지). 한 트랜잭션이고 `lock_timeout 5s`라, 잠금을 오래 기다리면 실패한다(그대로 다시 적용한다). `execution_events.type`의 기존 CHECK가 정확히 하나가 아니면 아무것도 바꾸지 않고 실패한다.
