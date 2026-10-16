# 코디네이터 1 (0.2.0 C2) — 결정 기록과 위치

2026-10-12 · 구현 계획 C2 · 근거: 아키텍처 6.3 · 7.1–7.7 · 10장 · ARCH06/07/11/12/14, 런타임 계약 3 · 5 · 6 · 7 · 10–12장, DR05–07, 개발 계획 A39.
**gate `COORDINATOR_ENABLED` 기본 꺼짐. 사용자에게 보이는 것이 없다(API · UI · 알림 없음). 운영 DB 적용 전.** 이 문서는 "무엇을 만들었고, 무엇을 일부러 안 만들었고, 어디 있는가"만 적는다. 일반 규칙은 [FEATURE_MAP.md](FEATURE_MAP.md), 실행의 기본 계약은 [EXECUTION.md](EXECUTION.md).

## 1. 한눈에

코디네이터는 **사건 반응기**다(상주 재계획 루프가 아니다, DR05). 사건 하나 → 영향 후보(코드) → (필요할 때만) 모델 → 결과 기록.
이 PR의 코디네이터가 쓰는 것은 `inbox_events`의 **처리 결과(종류 + 근거 종류 + id)뿐**이다. Action 값 · Claim · run · 단계 · 정책 · 승인 · 기억을 만들거나 바꾸지 않고, 살아 있는 실행에 재dispatch하지 않는다(I01 · I04 · I14). 결과를 소비해 움직이는 쪽(제안 C3 · 에이전트 게이트웨이 D1)은 뒤 단계다.

| 조각 | 위치 |
|---|---|
| 저장 계약 (열 · 제약 · RPC · 생산자 트리거 · 회수 · timer · 결정 대기 읽기) | `supabase/migrations/20261110000000_coordinator_core.sql` |
| 봉투 · dedup 규칙 · 아직 원천 없는 생산자의 어댑터 (순수) | `src/lib/coordinator/inbox.ts` · `types.ts` |
| 영향 후보 · stale 판정 · 결과 귀속(ARCH14) (순수) | `impact.ts` |
| 결정 라우팅 표 · 모델 계획 (순수) | `routing.ts` |
| 모델 판정 (예약 → 호출 → 후보 안 출력만) | `judgments.ts` (포트 주입. 운영 배선은 포트 없음, 5장) |
| 사건 하나 처리 · 집고 처리하기 반복(batch 상한) | `coordinate.ts` |
| 사건 큐 DB (RPC) · 사실 읽기 (user_id로 좁힘, 읽기만) | `store.ts` · `reads.ts` |
| 결정 대기 계산 (순수 + 읽기 loader) | `pending.ts` |
| 한 번 돌기(timer → 회수 → 처리) · 깨우기 · route | `sweep.ts` · `wake.ts` · `src/app/api/cron/coordinator-advance/route.ts` |
| 상수 (모두 값 + 이유, `제안`은 이 PR이 정한 운영값) | `coordinator.config.ts` |

## 2. 사건 종류와 생산자: 실제 연결 / 미연결

생산자는 **실제 성공 경로의 같은 DB 트랜잭션**에서 사건을 쌓는 트리거다(3장). `src/lib/coordinator/inbox.ts` `PRODUCERS`가 같은 표를 코드로 가지고 있고 테스트가 DB 종류 목록과 견준다.

| 사건 종류 | 상태 | 어디에 붙었나 / 왜 안 붙었나 | 키 · refs (id · 종류만) |
|---|---|---|---|
| `source_processed` · `source_revised` | **실제 연결** | `sources`의 `processing_status`가 done으로 **바뀌는 UPDATE**(트리거). 같은 문서(`source_document_ids`)의 두 번째 revision부터 `source_revised`. 실패 · 예산 대기 · 처리 중은 사건이 아니다. INSERT로 바로 done인 행(실행 receipt · 대화 채택 note)도 아니다 | `source:<id>` · `{source_id, kind}` |
| `user_message` | **실제 연결** | `conversation_messages`의 role user INSERT(`conversation_post_message`가 쓴다). 답(assistant)은 아니다 | `message:<id>` · `{conversation_id, message_id}` |
| `decision_made` | **실제 연결** (아래 종류만) | 사용자 Action 결정(`action_events`의 actor user: 확인 · 삭제 · 병합(`user_merged`, OA D4c-2) · 수정 · 완료 · 취소 · 다시 열기), 실행 승인 · 승인 철회(`execution_approvals`), 사용자 멈춤(`stop_run`이 정한 gate stop 전이). **읽음(`user_seen`) · 착수 · 메모 · 직접 추가는 결정이 아니라 사건이 아니다** | `action_event:<id>` · `approval:<id>` · `approval_revoked:<id>` · `run_stop:<id>` |
| `memory_changed` | **실제 연결** (범위 기억만) | `work_contexts.context_version` 상승(B1 트리거): 범위 기억(B3) · 사용자 멤버십(S3b) · 멤버 원문 revision. inferred 후보는 version을 올리지 않으니 사건도 없다. **범위 없는(global) 기억의 변화는 version이 없어 연결되지 않았다** | `memory_changed:<범위>:<version>` · `{context_id, context_version}` |
| `timer_due` | **실제 연결** (기한 창만) | sweep이 `coordinator_enqueue_due_timers`로 열린 Action 중 기한이 지금~24시간 안인 것을 **기한 값마다 한 번**(기한이 바뀌면 새 사건). 지난 기한은 "다가오는" 변화가 아니라 쌓지 않는다. 다른 timer(`next_check_at` · lease 만료)는 원천이 없다 | `timer:due_window:<action>:<기한 epoch>` · `{action_id, kind}` |
| `reply_observed` | **미연결** (봉투 + 어댑터 + fixture) | 회신 관찰 원천(D5/D6 의존 · 메일 관찰)이 아직 없다 | `replyObservedEnvelope` |
| `agent_event` | **미연결** | 게이트웨이(D1)의 사건 원천이 없다. `(session, event_id)` 한 번(I07) 규칙은 어댑터가 키로 가진다 | `agentEventEnvelope` |
| `dependency_changed` | **미연결** | `action_dependencies` 표(D6)가 없다 | `dependencyChangedEnvelope` |
| `bridge_unreachable` · `connection_changed` | **미연결** | Mac bridge(D2) · 연결 상태 생산자는 C2 범위 밖 | `bridgeUnreachableEnvelope` |
| 제안(suggestion) 결정 | **미연결** | `suggestions` 표(C3)가 없다. 사건은 `decision_made`의 `suggestion_*` 종류로 | `suggestionDecisionEnvelope` |

미연결 종류는 봉투 모양 · 순수 어댑터 · fixture 시험만 있다. 그 종류의 사건이 DB에 직접 쌓이면 처리는 `not_handled`(근거 `type_not_connected`)로 **정직하게** 기록된다. "연결 완료"가 아니다. D1 · F1 · C3 객체(`agent_tasks` · `action_dependencies` · `suggestions` · `pending_decisions` 표)는 만들지 않았다.

## 3. 적재의 정직성 — 어떤 쪽을 골랐나

선택: **성공 쓰기와 같은 트랜잭션에서 DB 트리거가 적재한다 + 예외는 삼킨다 + 삼킨 누락은 멱등 회수가 메운다.**

| 질문 | 답 |
|---|---|
| 원문 처리가 **실패**했는데 사건이 생기나 | 아니다. 트리거는 `processing_status`가 done으로 바뀔 때만 돈다(`failed` · `pending`(예산 대기) · `processing`은 사건이 아니다). `tests/coordinator/process-source.test.ts`가 실제 `processSource` · `processTaskSource`로 확인한다 |
| done을 쓰고 적재하기 **전에** 프로세스가 죽으면 | 틈이 없다. 같은 트랜잭션이라 둘 다 있거나 둘 다 없다(`tests/pg/coordinator-core.test.ts`: 쓰기 rollback이면 사건도 없다) |
| 재시도 · 응답 유실 · 재처리로 done을 또 쓰면 | `dedup_key`(`source:<id>`)가 같아 `on conflict do nothing`: 사건은 늘지 않는다 |
| 적재가 **실패**하면 원문 처리 · 대화 · 결정의 성공이 실패로 바뀌나 | 아니다. 각 트리거는 예외를 삼키고 경고(SQLSTATE만, 데이터 없음)만 남긴다. 실패시키면 코디네이터 문제가 사용자의 결정을 막게 된다(제약으로 적재를 강제로 실패시켜 `processSource`의 반환 · 상태가 같은 것을 시험) |
| 삼킨 누락은 | `coordinator_recover_missing`이 최근 2시간(`RECOVERY_LOOKBACK_SECONDS`, `제안`)의 원문 done · 사용자 메시지 · 사용자 Action 결정 중 사건이 없는 것을 같은 `dedup_key`로 쌓는다(30분마다, `RECOVERY_EVERY_MINUTES`). 승인 · 멈춤 · 범위 version 사건은 코디네이터가 DB를 다시 읽어 판단하므로 회수하지 않는다. 원문은 처리 요약이 있는 done만 센다(INSERT로 바로 쓴 note와 가르는 표시) |
| 왜 TS가 아니라 트리거인가 | 쓰기와 적재 사이의 "틈"을 구조적으로 없애고, 사건을 만드는 곳을 코드 여러 군데(`processSource` · `processTaskSource` · 재처리 스크립트 · 대화 · Action 쓰기 · 승인)에 흩지 않으려고. `process.ts` 등 기존 쓰기 경로는 **한 글자도 바꾸지 않았다**. 사건은 id · 종류뿐이라 원문 · 발화 글이 새지 않는다(DB가 `refs`의 모양도 막는다) |
| 원문 글을 읽나 | 아니다. 처리는 id · 상태 · 버전만 읽는다(`tests/coordinator/pipeline.test.ts`가 읽은 열 목록에 글 열이 없음을 확인) |

## 4. 집기 · 직렬화 · lease (사용자별, DB 보장)

- **머리 사건만 집는다.** 사용자마다 처리 전 · 죽지 않은 사건 중 `(created_at, seq)`가 가장 이른 것 하나. 같은 시각이면 쌓인 순서(`seq`, identity)로 가른다. 뒤 사건은 앞 사건이 처리되거나 죽어야 집힌다(사용자별 순서). 다른 사용자는 서로 막지 않는다. 오래 기다린 머리부터 `limit`개.
- **같은 사용자를 동시에 집는 호출 둘은 하나만 통과한다.** 사용자 advisory xact lock(`pg_try_advisory_xact_lock`)으로 한쪽은 기다리지 않고 건너뛰고, 머리 행은 `for update skip locked`로 잠근다(끝내기 · 예산 예약이 쥐고 있는 머리를 가로채지 않는다 — 잠그지 않고 머리를 읽은 뒤 그 행만 잠가서, 잠긴 머리를 건너뛰고 뒤 사건을 집는 순서 뒤집힘을 막는다). 처리 중에는 **lease**(`claim_expires_at`)가 직렬화를 잇는다: 살아 있는 lease가 있는 머리의 사용자는 건너뛴다. 인스턴스 메모리 mutex는 없다(기존 `withUserLock`은 다른 용도).
- **lease가 끝난 머리는 다시 집힌다**(`attempts` +1, 새 `claim_token`). 시도를 다 쓰면(`COORDINATOR_MAX_ATTEMPTS` = 5, `제안`) **죽은 사건**(`dead_at`)이 된다 — 처리된 것도 성공도 아니다. 그 사용자의 다음 사건을 막지 않는다. 죽은 사건은 운영자가 볼 수 있게 남는다(보여 주는 화면은 없다, 열린 결정 D-4).
- **늦은(만료된) 소비자의 commit은 거절된다.** `coordinator_finish`는 토큰이 같고 lease가 살아 있을 때만 `processed_at`을 쓴다. 아니면 `lost_claim`. 같은 토큰으로 이미 끝났으면 `already_finished`(응답 유실 뒤 재시도가 안전하다).
- **`processed_at`은 결과와 함께, 성공한 처리에서만.** 예외는 `processed_at`을 쓰지 않고 `coordinator_fail`로 까닭 종류만 남기고 재시도를 `COORDINATOR_RETRY_DELAY_S`(60초) 늦춘다. 처리의 쓰기는 `coordinator_finish` 한 문장(멱등)이다.
- 삭제 · 권한 상실: 계정이 삭제되면 사건도 cascade로 사라지고 집은 소비자의 commit은 `lost_claim`. 원문 삭제 · 접근 상실은 처리할 때 DB로 확인해 `stale`(근거 종류가 결과에 남는다, 6장).
- **같은 `created_at`의 `seq`가 commit 순서를 뒤집을 수 있다**(동시에 열린 두 트랜잭션). 사건은 사실(id)만 담고 처리가 DB를 다시 읽으므로 순서가 진실을 정하지 않는다(도착 순서는 최신성의 증거가 아니다).

## 5. 모델 호출 상한

| 규칙 | 구현 |
|---|---|
| 관리(생성) 모델은 사건당 **최대 1회**, 부르기 **전에** DB에 예약 | `model_calls ∈ {0, 1}` CHECK + `coordinator_reserve_model_call`(lease가 살아 있는 소비자만 true). 예약 뒤 소비자가 죽거나 응답이 유실돼도 다시 true가 되지 않는다 → 다시 집힌 시도는 부르지 않고 `not_judged`(`model_call_unknown`) |
| Jev는 따로 센다, 후보 수와 상수로 상한 | `jev_calls` + `coordinator_reserve_jev_calls`(합이 상한(`MAX_JEV_CALLS_PER_EVENT` = 8, `제안`)을 넘으면 하나도 더하지 않음). 불확실한 후보만, 자료 변화 종류(`source_revised` · `reply_observed`)만 |
| 사건 없음 · 후보 없음 · 후보가 모두 확실 · 결정적 처리 · gate 꺼짐 → 호출 0 | `routing.ts planModelWork` + route가 꺼져 있으면 `advanceCoordinator`가 DB 클라이언트도 만들지 않는다 |
| 모델은 후보 밖 객체를 고르거나 바꾸지 못한다 | `judgments.ts restrictToCandidates`: 후보 밖이 하나라도 있으면 출력 전체를 버린다(`model_output_rejected`) |
| 일일 AI 원가 · 동의 · provider 제한 | 포트를 만드는 쪽의 몫(`budgetFetch` · `withConsentGate`). 여기서는 `AiBudgetError` · `ConsentRequiredError`를 "판정 못함"(`ai_budget` · `consent_missing`)으로 닫고 다시 부르지 않는다 |
| 상주 재계획 루프 없음 | 사건이 없으면 일이 없다. 1분 sweep은 사건을 집을 뿐 모델을 부르지 않는다 |

**지금 데이터에는 모델이 필요한 경로가 없다.** 결과(영향 후보)를 쓰는 쪽(제안 C3 · 게이트웨이 D1)이 아직 없어, 모델이 같은 후보를 "더 정확히" 걸러도 쓰는 곳이 없다. 그래서 **운영 배선은 포트를 주지 않는다**(`wake.ts advanceCoordinator`, 테스트가 확인): 불확실한 후보(살아 있는 run 등)는 판정 없이 `impact_recorded`(근거 `deterministic_only`)로 기록된다. 호출 경로(예약 · 상한 · 후보 안 출력 · crash/응답 유실 · 원가/동의 오류)는 가짜 모델로만 시험한다(`tests/coordinator/budget.test.ts`). 새 프롬프트는 만들지 않았고 기존 추출 프롬프트 · 파이프라인은 바꾸지 않았다. 실제 provider · Jev · eval은 부르지 않았다(`npm run eval` 미실시).

## 6. 영향 후보 · 결과 · 버전

사건 종류별 후보는 **코드가 DB 사실로** 정한다(`reads.ts`는 `user_id`로 좁혀 읽기만, 남의 것 · 없는 것 · 지운 것은 "없음"으로 같다):

| 사건 | 후보 | 증거 있는 stale (`result_kind=stale`, `result_evidence`) |
|---|---|---|
| 원문 처리 / revision | 같은 문서의 근거 Action(확실) · 멤버 범위(확실) · 그 Action의 살아 있는 run(**불확실**, 기록만) | `source_deleted` · `source_access_lost` |
| 사용자 메시지 | 앱이 고른 대상 중 **내 것으로 확인된 것**(확실). 남의 id는 `dropped_refs` 개수만 | `parent_deleted` |
| 사용자 결정 | 그 Action · run(확실) + 살아 있는 run(불확실) | `parent_deleted` |
| 범위 version | 그 범위에서 시작해 묶음 version이 더 옛것인 살아 있는 run(**불확실**) | `parent_deleted` · `version_mismatch`(더 새 version의 사건이 따로 있는 옛 사건) |
| 기한 창 | 그 Action(확실) | `parent_deleted` · `already_handled`(닫힘) · `version_mismatch`(기한이 바뀜) |

- 결과 종류: `no_impact` · `impact_recorded` · `stale` · `rejected` · `not_judged` · `not_handled`. 근거 종류(`result_evidence`)는 닫힌 목록이다(`types.ts EVIDENCE_KINDS`). **나이(TTL)만으로 만든 근거는 없다.**
- `context_version`(자료 · 기억)과 `directive_version`(사용자 지시)은 **섞지도 서로 파생하지도 않는다**: 범위 version 사건은 `directive_version`을 읽지도 올리지도 않고, run의 지시 · 묶음 version은 그대로다(`pipeline.test.ts`).
- 묶음 manifest에 없는 변화는 현재 결과를 무효화하지 않는다(`impact.ts bundleChangeEffect`: manifest 밖 → `outside_manifest`). 지금은 manifest를 저장하지 않아(D1) 모르면 단정하지 않고 후보로만 남긴다(`manifest_unknown`). 어느 쪽이든 재dispatch · 새 run · 새 단계 · Claim · Action 완료는 0이다.
- **결과 귀속 · 도착 순서 (ARCH14)**: `attributeResult` · `planArrivals`는 지시 회차 · 수정 회차로만 귀속한다(낮은 회차 = 옛 결과, 회차 없음 · 모르는 회차 = 귀속 불가). 요구 변경과 결과가 같이 오면 acceptance 재평가로 가고 현재 결과로 올리는 것은 0이다. 입력 순서와 무관하다. **에이전트 · 회신 원천이 없어 순수 함수 + fixture로만 시험한다(연결되지 않았다).**

## 7. 결정 라우팅 · pending_decisions (A39)

- **결정 라우팅 표**(`routing.ts DECISION_ROUTING`): 런타임 계약 6장 + 아키텍처 7.7을 상황 이름 → `user | coordinator`의 순수 조회로. 입력에 범위 · 기억 · version · 정책이 없다(ARCH06/07).
- **`pending_decisions`는 계산값이다.** 표 · 사용자 API · UI · Undo · 결정 outcome은 없다. `coordinator_pending_inputs`(읽기 전용 SQL, `stable`)가 실제 원천을 주고 `pending.ts computePendingDecisions`가 묶는다:
  - 실제 원천: 승인 대기 단계(`prepared` + `needs_approval`, 유효한 승인이 없는 것 — `begin_call`과 같은 기준), run `needs_input` / `review_failed`(그 Action의 가장 최근 run, 멈추지 않음, Action이 열려 있음), `actions.needs_confirmation`.
  - 에이전트 입력(OA D4b-s): `review_agent_inputs`(읽기 전용 SQL, `stable`)가 질문 셋(`agent_question` · `agent_approval` · `agent_secret_question`) · 결과 준비(`result_ready`) · 경로 충돌(`path_conflict`)을 준다. 항목 id는 `<kind>:<item_ref>`(task · run · lease id)이고 종류별 ref(`agent` · `result` · `conflict`)가 항목에 붙는다. 대화 v2 ∧ adapter 플래그가 켜졌을 때만 읽는다(`openAgentAdapters()`) — 꺼지면 이 함수를 부르지 않아 C2 결과 그대로다. 상세는 `docs/review-summary.md`.
  - 미래 원천(열린 제안 · 긴급 창의 막힌 의존)은 입력 타입 `FutureInputs` + fixture만(연결되지 않았다).
  - 항목: `{id, kind, action_id, run_id, step_id, question_id, version, urgent, created_at}`. 묶음: `(action_id, kind)`. 긴급: 기한이 24시간 안(지남 포함) 또는 다른 작업을 막음. 순서: 긴급 먼저 → 오래 기다린 순 → 종류 · action id(입력 순서와 무관).
  - **다른 기기에서 처리 · 삭제된 항목은 version 불일치로 사라진다**(`matchPendingVersion`: current · stale · gone). **읽기 · 계산 ≠ 해결**: 여러 번 계산해도 어떤 표도 바뀌지 않고 사건도 쌓이지 않는다(`tests/coordinator/pending.test.ts`).

## 8. gate · sweep · 깨우기

- **gate `COORDINATOR_ENABLED`**(기본 꺼짐, 정확히 `"true"`): 꺼져 있으면 **적재만** 한다(트리거는 DB에 있으므로 계속 쌓인다). 집기 · 처리 · 모델 · 깨우기 · 기존 실행 변경은 0: route 404, `advanceCoordinator`가 바로 `null`(DB 클라이언트도 안 만든다), `wakeCoordinator`가 네트워크를 안 부른다, 1분 sweep이 after()를 등록하지 않는다.
- **sweep 위치: `execution-sweep`에 합류(깨우기 하나만), 처리는 별도 route.** 근거: ① `vercel.json`을 바꾸지 않는다는 조건에서, 별도 `coordinator-sweep`은 스케줄이 없어 1분 회수가 돌지 않는다. ② `execution-sweep`의 처리에 합치면 그 route의 시간 · 응답 · 실패 의미(승인 · gate · 원가 조정)가 코디네이터와 섞인다. 그래서 `execution-sweep`은 **응답을 보낸 뒤(after) 코디네이터를 깨우는 자기 호출 하나**만 더한다(꺼져 있으면 아무것도 안 함, after()가 막히거나 깨우기가 실패해도 가둔다 — 응답은 어느 경우에도 같다, `coordinator-wake.test.ts`). 실제 처리는 받는 쪽 `POST /api/cron/coordinator-advance`(`CRON_SECRET`, 202 즉시, after()에서 timer 적재 → (30분마다) 회수 → 사건 처리 `coordinatorPass`).
- 깨우기 실패 · 중복: 한 호출은 사건 `MAX_EVENTS_PER_RUN`(50)건 · `RUN_TIME_BUDGET_MS`(40초) 안에서만 돌고 더 있으면 스스로 한 번 더 깨운다. 자기 호출이 실패해도 사건은 DB에 있어 다음 분의 sweep이 다시 깨운다. 깨우기가 겹쳐 두 호출이 동시에 돌아도 DB 집기가 사건 하나를 한 소비자에게만 준다(`tests/pg/coordinator-runtime.test.ts`: 두 소비자, 사건 100건, 처리 1회 · 오류 0). 단계마다 실패를 가둔다(`PassResult.errors`).
- 생산자 쪽 "적재 직후 깨우기"는 연결하지 않았다(1분 sweep이 맡는다): 지금은 보이는 행동이 없어 지연이 문제가 아니고, 기존 원문 처리 · 대화 · 결정 코드에 호출을 더하지 않으려는 것이다. 환경변수 · `vercel.json` · 스케줄은 바꾸지 않았다.

## 9. 기본값 꺼짐으로 쌓이는 사건 — 폭주를 막는 것, 그리고 열린 결정

gate가 꺼진 채 쌓인 사건은 나중에 켜도 **한꺼번에 모델 호출로 이어지지 않는다**. 막는 것은 이 다섯 가지뿐이다.

1. 호출(sweep · 자기 호출) 한 번의 **batch 상한**: 사건 50건 · 시간 40초. 더 있으면 다음 호출이 이어 간다.
2. **claim/lease**: 사용자당 머리 하나, 시도 5번이 상한.
3. **사건당 모델 호출 예산**(5장, DB 선예약): 오래된 사건도 모델은 최대 1회 · Jev 8회.
4. **`dedup_key` 멱등**: 같은 사건은 한 번만 쌓인다.
5. 포트가 없는 운영 배선: 지금은 모델 호출 0.

**증거 있는 stale 처리**(허용): 원천의 실제 삭제 · 접근 상실 · 버전 불일치 · 이미 처리됨은 DB로 확인한 사실로 모델 없이 결정적으로 닫고, 근거 종류를 결과에 남긴다(6장).

**열린 결정(구현하지 않았다 — 제품 결정이 필요하다):**

| # | 결정 | 상태 |
|---|---|---|
| D-1 | **미처리 사건을 나이(TTL)만으로 자동 만료 · 삭제 · 성공 처리**하는 정책 | 이번 승인에 없다. 값에 `제안`을 붙여도 승인이 아니라서 코드 · 상수 · 테스트 모두 두지 않았다 |
| D-2 | **처리된 사건 보관 기한**(아키텍처 5.7 "`processed_at` 뒤 보관 기한 지나면 정리"의 값) | 문서에 값이 없다. 값을 정해 자동 삭제하지 않았다 → 처리된 사건은 지금 쌓이기만 한다 |
| D-3 | B3 기억 · S3b 멤버십 쓰기가 사건함에 `memory_changed` 한 줄을 더하게 한 것 | 구현 계획의 입구(`memory_changed`)대로 연결했다. 그러자 B3 PR1 · S3b가 "사건함에 한 줄도 더하지 않는다"로 적어 둔 경계 시험 둘(`tests/db/memory-writes.scenarios.ts` · `context-members.scenarios.ts`)과 트리거 목록 시험(`context-core.test.ts`)이 실패해 **좁혀서 고쳤다**: 다른 표는 그대로 0줄, 사건함은 `memory_changed`만 예외(다른 종류는 여전히 0줄). 쓰기 경로 · 반환값 · 권한은 바뀌지 않았다. 되돌리려면 `coordinator_on_context_version` 트리거를 지운다 |
| D-4 | 죽은 사건(시도 소진)을 누가 어떻게 보나 | 화면 · 알림 없음. DB에 `dead_at`으로 남는다(운영 점검 쿼리는 아래 11장) |
| D-5 | 전역(범위 없는) 기억 변화 사건 | version이 없어 연결하지 않았다. 묶음이 생기는 D1에서 필요하면 정한다 |
| D-6 | `제안` 운영값: 시도 5 · 재시도 지연 60초 · batch 50건/40초 · Jev 8 · 후보 50 · 회수 30분/2시간 | D0에서 바꿀 수 있다(`coordinator.config.ts`) |

## 10. 일부러 하지 않은 것 (한계)

- 사용자 API · UI · 알림 · 복귀 요약 · 제안(`suggestions`) · Undo · 결정 outcome · `pending_decisions` 표: 없다(C3).
- 에이전트 게이트웨이 · bridge · 의존 · 회신 관찰 생산자: 없다(D1–D6). 어댑터 · fixture만.
- 실제 모델 호출 · 실제 provider · Jev · eval: 하지 않았다. 호출 경로는 가짜 모델로만 검증.
- 실행 쪽 변경 없음: `begin_call` · intent · lease · 승인 hash · `unknown_outcome` · 크레딧 · stopped/action_closed · 연결별 정책(저장만, C1) · 동시성 상수(값만 — 세는 쪽은 D1) · v1 API · v1 동결 지문은 그대로다. 코디네이터는 정책 · 승인 · 도구를 가져오지 않는다(eslint · `src/lib/coordinator/boundary.test.ts`).
- 운영/Preview DB 조회 · 적용, 배포, 환경변수, `vercel.json`, 스케줄 변경 없음. **운영 DB에 적용 전이다**(적용은 병합 직전 승인을 받고 `supabase db query --linked -f`, `db push` 금지).
- B3 · S3b · A2 쪽 시험 세 곳은 D-3 때문에 좁혀서 고쳤다(위 표).

## 11. 적용 · 되돌리기 · 점검

- 한 트랜잭션 마이그레이션(`lock_timeout` 5초). 기존 데이터를 바꾸지 않고 기존 마이그레이션 파일을 고치지 않았다. 기존 함수를 다시 만들지 않았다(`create or replace` 0).
- `refs` · 처리 일관성 CHECK는 `NOT VALID`다: 이 표에 쓰는 코드는 지금까지 없었지만 운영을 조회하지 않아 확인하지 못했으므로 옛 행이 있어도 적용이 실패하지 않는다(새 행 · 고치는 행에는 적용). 필요하면 나중에 `validate constraint`.
- 되돌리기: 트리거 일곱 · 함수 · 제약 · 인덱스 · 열을 지우면 된다(`inbox_events`의 A2 열은 그대로). 코드는 PR을 닫으면 된다. gate를 끄면 처리만 멈추고 적재는 계속된다 — 적재까지 멈추려면 생산자 트리거를 지운다.
- 점검 쿼리 예(개수만): 처리 전 `select count(*) from inbox_events where processed_at is null and dead_at is null`, 죽은 사건 `… where dead_at is not null`, 결과 분포 `select result_kind, result_evidence, count(*) from inbox_events where processed_at is not null group by 1, 2`.

## 12. 검증

| 무엇 | 어디 |
|---|---|
| DB 계약 (열 · 제약 · 권한 · search_path · RPC · 생산자 · 격리 · 회수 · timer · 업그레이드 · 롤백) | `tests/db/coordinator-core.scenarios.ts` (PGlite `tests/db/coordinator-core.test.ts` + 실제 Postgres `tests/pg/coordinator-core.test.ts`) |
| ARCH12 (100건 · 두 소비자 · 사용자별 순서 · 처리 1회) — SQL 직접 / 운영 TS 코드 | `tests/pg/coordinator-core.test.ts` / `tests/pg/coordinator-runtime.test.ts` |
| 정직한 적재 (실제 `processSource` × 트리거) | `tests/coordinator/process-source.test.ts` |
| 처리 파이프라인 · 권한(위조 refs) · crash · 응답 유실 · 늦은 소비자 · 삭제 · batch | `tests/coordinator/pipeline.test.ts` |
| 모델 상한 (가짜 모델) | `tests/coordinator/budget.test.ts` |
| ARCH11 (고정 24시간) | `tests/coordinator/arch11.test.ts` |
| A39 (두 기기) | `src/lib/coordinator/pending.test.ts` (순수) · `tests/coordinator/pending.test.ts` (실제 DB 원천) |
| ARCH14 (fixture) · 영향 · 라우팅 · 봉투 | `src/lib/coordinator/{impact,routing,inbox}.test.ts` |
| 깨우기 · route · gate | `src/lib/coordinator/wake.test.ts` · `src/app/api/cron/coordinator-advance/route.test.ts` · `src/app/api/cron/execution-sweep/coordinator-wake.test.ts` |
| 경계 (실행 ← 코디네이터, 맥락층 → 실행 없음, 마이그레이션이 쓰는 표) | `src/lib/coordinator/boundary.test.ts` · eslint `no-restricted-imports` |
