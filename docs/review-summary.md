# Review · 복귀 요약 · 제안 서버 (0.2.0 C3) — 결정 기록과 위치

2026-10-12 · 구현 계획 C3 · 근거: 런타임 계약 1장(복귀 요약 = 기존 이벤트 계산) · 6장(`pending_decisions`) · 8장(`suggestions`) · 12장 상수, 아키텍처 I04 · I13 · I14 · ARCH06/07/25, 개발 계획 A08 · A09 · A16 · A39 · A40, 디자인 D-12(ReturnSummary) · D-8(Receipts 틀은 Mac 몫).
**gate 둘 모두 기본 꺼짐: `REVIEW_V2_ENABLED`는 새 경로 여섯 개 전부, `RETURN_SUMMARY_ENABLED`는 복귀 요약 세 경로만 연다(둘 중 하나로 복귀 요약이 열리고 Review · 제안은 `REVIEW_V2_ENABLED`만 본다, JSON 계약 "공통" 표). 꺼진 경로는 404(인증 · DB 호출 없음, 새 쓰기 0), 기존 API · 쓰기 · 실행 의미는 그대로다. 운영 DB 적용 전.** 이 문서는 "무엇을 만들었고, 무엇을 일부러 안 만들었고, 어디 있는가"만 적는다. 일반 규칙은 [FEATURE_MAP.md](FEATURE_MAP.md), 코디네이터는 [coordinator.md](coordinator.md).

## 1. 한눈에

| 조각 | 위치 |
|---|---|
| 저장 계약 (표 3 · 함수 8 · 보호 트리거 2) | `supabase/migrations/20261111000000_review_summary.sql` |
| 첫 정상 표시 기준점 저장 (표 1 · 함수 2 · 보호 트리거 1 + `return_summary_scan` 갱신, A–D 후속 C) | `supabase/migrations/20261112000000_review_summary_baseline.sql` |
| 제안 DB 호출 (생산 · 노출 · snooze · dismiss) | `src/lib/review/suggestions.ts` |
| 복귀 요약 읽기 · 계산(순수) · Clear · 기준점 확정 | `src/lib/review/return-summary.ts` · `cursor.ts` · `init-token.ts` |
| Review (결정 대기 + 열린 제안) | `src/lib/review/review.ts` · `time-zone.ts` · `day.ts` · `dto.ts` · `review.config.ts` |
| API 처리 (인증 · gate · 오류 매핑) | `src/lib/api/review.ts` · zod `src/lib/api/contract.ts` 끝(C3 절) |
| route | `src/app/api/v2/{review,return-summary,return-summary/clear,return-summary/baseline,suggestions/[id]/snooze,suggestions/[id]/dismiss}/route.ts` |
| gate | `src/lib/flags.ts` `REVIEW_V2_ENABLED`(여섯 경로) · `RETURN_SUMMARY_ENABLED`(복귀 요약 세 경로만) · `returnSummaryEnabled()` |
| 바뀜 규칙 한 곳 | `src/lib/actions/changed.ts` (`changesAfterSeen`은 `changedSinceSeen`과 같은 뜻) |
| 에이전트 입력 읽기 (질문 셋 · 결과 준비 · 경로 충돌, OA D4b-s) | `supabase/migrations/20261124000000_review_agent_inputs.sql`(읽기 전용 SQL 함수 `review_agent_inputs` 하나 — 반환은 입력 배열 **scalar `jsonb` 하나**라서 PostgREST `db-max-rows`(행 수 상한)에 잘리지 않는다) · `src/lib/coordinator/pending.ts`(종류 · 항목 열쇠 · ref · 계산) · gate `openAgentAdapters()`(`src/lib/agents/registry.ts`) |
| 경로 충돌 해소 route (D4b-s) | `src/app/api/v2/path-conflicts/[id]/resolve/route.ts` · `src/lib/api/path-conflicts.ts` → D3c-2 `resolve_path_conflict` |

## 2. 읽음 = (사건 id, 작업 id) 쌍 (P2-A · P2-C 보완 포함)

`action_events.created_at` · `execution_events.at` · `conversation_messages.created_at`은 **트랜잭션 시작 시각**이라 commit 순서와 다르다. "지평 이전은 다 봤다"를 시각으로는 증명할 수 없다 — 아직 commit하지 않았거나 BEGIN만 하고 아직 쓰지 않은 트랜잭션의 행이 나중에 그 시각으로 나타난다. grace 시간도 잠금도 이것을 막지 못한다(writer와 잠금을 공유하지 않는다). 그래서:

- **후보 사건**(`return_summary_candidates`): 지평까지 보이는 세 원천 — `action_events`(ai · agent가 쓴 `changed.ts` 종류) · `execution_events`(run `done` · `failed` 전이) · `conversation_messages`(assistant · event, `refs.action_ids`가 내 Action).
- **조회**(`return_summary_scan`): 문장 하나(스냅샷 하나)에서 후보 − 읽음 표시(`return_summary_reads`) = 보이는 변화, 그리고 후보 집합의 **digest**(원천마다 개수 + id 해시 합)와 지평을 낸다. 커서 = (사용자, 지평, digest).
- **Clear**(`return_summary_clear`): 같은 지평으로 후보 집합을 다시 세어 digest가 같을 때만, 그 **집합의 (사건, 작업) 쌍만** `return_summary_reads`에 쓴다 — digest 확인과 표시가 **한 문장**이다. 조회 뒤 Clear 전에 commit된 사건(트랜잭션 시작 시각이 지평 이전이어도)이 있으면 digest가 달라 `stale`(409, 아무것도 안 씀). Clear 때 **아직 commit되지 않은 사건은 집합에 없으므로 읽음이 되지 않아**, commit된 뒤 다음 조회에 보인다.
- 시각 워터마크는 읽음의 근거가 아니다. `return_summary_state.cleared_through`는 마지막 Clear의 지평(표시용 "Since …" · "Clear한 적이 있다"의 표시)이다 (단조 트리거).
- 단조: 읽음 표시는 쌓이기만 한다. 같은 커서 재시도 · 겹친 읽기 · 두 기기 · 늦은 Clear는 `applied:false` 성공이다. 같은 사용자의 Clear는 advisory lock으로 직렬이지만 **정확성은 잠금이 아니라 "집합" 규칙이 만든다**.
- **읽음 기준**(run 결과 · 대화 이력을 변화로 올릴 수 있는가): Clear한 적이 있거나 **첫 정상 표시 기준점**(다음 2-1절)이 있으면 올린다. 둘 다 없으면 run · 대화 이력은 올리지 않고(읽음 기준이 없다) 작업 변화만 `changed.ts` 의미로 올린다. 기준점 전에 처음 Clear하면 그때 보이던 이력 전부(보이지 않던 run · 대화 이력 포함)가 기준이 된다(읽음 표시).
- **잘린 조회(작업이 300개를 넘음, P2-C)**: `truncated` + 가장 최근 변화 순(사용자가 이미 본 작업은 순위에 들지 않는다) 앞 300개만 낸다. 커서는 **보인 작업의 id**를 싣고(최대 300 × 22자), Clear는 그 작업들의 사건만 읽음 처리한다 — 보이지 않은 작업은 읽음이 아니라 다음 조회에 나온다. 보인 작업 집합을 Clear 때 다시 계산하지 않고 실어 나르는 이유: 순위가 읽음 표시에 의존하므로 Clear 뒤의 재시도 · 다른 기기의 Clear가 끼면 같은 집합이 다시 나오지 않아 응답 유실 재시도가 409가 된다. 범위(digest)는 읽음 여부와 무관한 후보 id 집합이라 재시도 · 두 기기에서도 같고, 보이지 않은 작업의 사건은 범위 밖이라 불필요한 409도 없다. 읽음의 단위가 (사건, 작업) 쌍이라 여러 작업을 가리키는 메시지(`refs.action_ids`)도 작업마다 따로 읽는다: 보인 작업의 쌍만 읽음이 되고 보이지 않은 작업의 쌍은 안 읽음으로 남아 다음 페이지에 나온다 (사건 단위로 두면 허브 작업 하나를 모두가 가리킬 때 페이지가 멈춘다 — Codex 재현). 300 상한을 올리거나 공유 사건을 버리지 않는다. 읽음 기준이 아직 없을 때의 첫 Clear가 잘린 조회여도 올리지 않던 run · 대화 이력은 기준으로 삼는다(기준점이 이미 있으면 다시 다루지 않는다). `sources.changes`는 `truncated`, `complete:false` · `empty:false`가 유지된다. 읽음 표시는 지우지 않는다(만료 · 정리 정책 없음 — 결정 항목 P-5).

## 2-1. 첫 정상 표시 기준점 (A–D 후속 C, `20261112000000`)

**문제**: 11까지는 run 결과 · 읽은 시각이 없는 대화 메시지가 "처음 Clear한 뒤"에야 변화로 올라온다. 사용자가 요약을 처음 정상으로 보고도 Clear를 누르지 않으면 새 run 결과 · 메시지가 계속 안 보였다. **결정**(Daniel 승인 C): 사용자가 요약을 처음 **정상 표시**한 순간을 기준점으로 삼는다. 다음이 서버 규칙이다.

- **GET은 계속 읽기만 한다.** 응답에 `baseline: "initialized"`(새 값)와 `init_token`이 더해진다. client now · 시간 길이 추정 · "시각 이하는 전부 읽음" · inbox 완전성 가정은 쓰지 않는다. 기준점은 서버가 발급한 토큰을 앱이 별도 확정 쓰기로 돌려줄 때만 생긴다.
- **`init_token`** = (사용자, 지평, **기준점 범위**의 관찰 집합 digest). 기준점 범위 = 지평까지 보이는 run 결과 전부 + 읽은 시각(`conversations.last_read_at`)이 없는 대화 메시지의 (사건, 작업) 쌍. **미열람 Action 변화(`action_event`)와 미결정은 범위 밖이다**(건드리지 않는다). 비-null은 `baseline == never_cleared`이고 변화 읽기가 성공(`sources.changes` ∈ `ok | truncated`)했을 때뿐이다 — 빈 첫 화면(`empty:true`)에도 발급된다. 변화 읽기가 실패하면 `baseline: unknown` + 토큰 없음. 결정 읽기만 실패해도 토큰은 나온다(결정은 범위가 아니다). 형식은 `i1.` + base64url(JSON `[사용자, 지평(마이크로초), digest]`), 400자 이하. 불투명 글자로 다루며, 위조해도 권한이 늘지 않는다: 확정이 사용자 · 지평 · digest를 DB에서 다시 확인한다.
- **확정**(`POST /api/v2/return-summary/baseline`, `return_summary_baseline_init`): 한 문장(같은 스냅샷)에서 지평까지의 기준점 범위 digest가 토큰과 같음을 확인하고 그 (사건, 작업) 쌍만 `return_summary_reads`에 쓰며 `return_summary_baseline`에 한 줄을 쓴다. **조회 뒤 확정 전에 범위 안에서 commit되거나 지워진 사건**(트랜잭션 시작 시각이 지평 이전이어도)이 있으면 digest가 달라 `stale`(409, 아무것도 안 씀, 앱은 자동 재전송하지 않고 다음 정상 표시의 새 토큰으로 다시). **확정 때 아직 commit되지 않은 사건 · 지평 뒤 사건은 범위 밖**이라 읽음이 되지 않고 기준점 뒤 새 변화로 보인다.
- **이미 기준점이 있거나 Clear한 적이 있으면**(두 기기 · 응답 유실 재시도 · 늦은 확정 · 업그레이드 이전 Clear 사용자) `already_initialized`, **아무것도 쓰지 않는다**. 이 사용자들은 `cleared`로 센다(기존 읽음 보존, 다시 초기화하지 않는다).
- **Clear와의 관계**: 기준점 전 Clear(`p_baseline` 경로)는 그대로 기준점 이력을 읽음으로 삼고 이후 `cleared`다. 기준점 뒤 Clear는 기준점 이력을 다시 다루지 않는다(조회의 `baseline` 표시는 Clear도 기준점도 없을 때만 true라 잘린 Clear 커서가 켜지 않는다). 확정과 Clear는 같은 사용자 advisory lock으로 직렬이고 정확성은 관찰 집합 규칙이 만든다 — 동시에 와도 어느 순서든 사용자는 `cleared`가 되고 옛 이력이 되살아나지 않는다(실제 Postgres 시험).
- **저장**: `return_summary_baseline`(user_id PK · `horizon` · `created_at`) — 글 없음. RLS `owner_all` + 앱은 select만, 갱신 금지 트리거, 계정 삭제 cascade. 새 원문 · 요약 캐시 없음. 기준점이 지워지면(되돌리기) 이미 표시된 읽음 쌍은 남는다.

## 3. 제안 (suggestions)

- **`GET /api/v2/review`는 읽기만 하지 않는다**(결정 항목 D-4): 제안 생산(`suggestions` 행 생성, 멱등) · 노출 표시(`shown_at`, **그날의 비긴급 묶음을 처음 정해 소비**) · snooze가 끝난 제안 다시 열기 · 증거 있는 `expired` 닫기를 같은 호출에서 한다. Action · run · Claim은 만들지 않는다. `GET /api/v2/return-summary`는 아무것도 쓰지 않는다. 쿠키 인증 GET은 CSRF 검사 대상이 아니라(앱은 Bearer) 다른 사이트가 사용자의 오늘 묶음을 앞당겨 소비시킬 수 있다(응답은 읽지 못한다). 스케줄 생산으로 옮기거나 쿠키 교차 사이트 GET을 막을지는 열린 판단이다.

- dedup = `kind + subject_key + revision`(계기). 날짜가 아니다: 같은 계기는 하루가 지나도 다시 제안하지 않는다(A08). `dismiss_scope = 'topic'`은 같은 kind + subject의 새 계기도 막는다. 생산 · 노출 · 전이는 사용자 advisory lock으로 직렬(두 worker · 두 기기).
- 비긴급 상한: 사용자 현지 날짜마다 **처음 노출 묶음 하나, 3개**(`batch_day`). 그날 한 번이라도 묶음이 있었으면(전부 처리했어도) 새 비긴급을 더 내지 않는다. 긴급(`urgent`)은 상한 밖. 이미 낸 비긴급은 처리하기 전까지 남고 다시 "새로" 나오지 않는다(변화 없는 반복 노출 없음). C2 `pending` 목록에는 상한을 씌우지 않는다(201개면 201개).
- 현지 날짜: `src/lib/review/day.ts`(Intl, 고정 시계로 시험 · DST 시험). 시간대 출처: **이 스택에는 시간대 저장소가 없다.** 보고 설정(H1 `report_preferences.time_zone`)은 별도 스택이다. 표가 없거나 그 사용자의 값이 없으면 **정당한 모름**(`needs_time_zone`, 읽기는 완전): 새 비긴급을 내지 않고 시간대를 추측하지 않는다. 표가 있는데 읽기가 실패하면(예: 57014) **모름이 아니라 읽지 못한 것**이다: `sources.time_zone: unavailable` · `complete:false` · `empty:false`, 긴급과 이미 낸 제안은 그대로 보인다(P2-B).
- 전이: `snooze`(사용자가 고른 미래 시점만, 366일 이내 — 오타를 막는 기술 한도) · `dismiss`(this | topic). 모두 `state + version` 조건부 쓰기, 실패는 409(자동 재시도 없음). **accept(채택)는 없다**: 채택이 낳는 효과가 아직 정의되지 않았다(B2 proposal 채택 멱등은 그 효과가 정해지면 재사용). 새 결정 outcome · Undo 없음.
- 만료: 나이로는 만료하지 않는다. 증거가 있을 때만 `expired`(기한이 바뀜 · Action이 닫힘 · run이 새 run으로 바뀜/끝남, `stale_evidence`). 원천(Action)이 지워지면 제안도 cascade로 사라진다(되살리지 않는다).

## 4. 실제 연결 / fixture

| 대상 | 상태 | 원천 / 이유 |
|---|---|---|
| 제안 `due_window` | **실제 연결** | `actions.due_at`이 24시간 창 안인 내 열린 Action (지난 기한은 만들지 않는다: 옛 일이 한꺼번에 제안이 되지 않게). 긴급. C2 불필요 |
| 제안 `run_failed` | **실제 연결** | 그 Action의 가장 최근 `execution_runs.state = 'failed'`. 긴급. C2 불필요 |
| 제안 `source_revised_run` | **실제 연결 (C2 결과 소비)** | C2가 처리한 `source_revised`(`impact_recorded`)가 가리키는 살아 있는 run. `COORDINATOR_ENABLED`일 때만 `inbox_events`를 읽는다. 비긴급 |
| 그 밖의 제안 종류 | **미연결** | 원천이 없다(회신 · 에이전트 질문 · 의존 · 연결 상태). 종류는 코드 토큰이고 문구는 서버가 만들지 않는다 |
| 결정 대기 (Review `decisions`) | **실제 연결 (C2 계산)** | `coordinator_pending_inputs`: 승인 대기 단계 · run `needs_input`/`review_failed` · Action 확인 요청. C2 게이트와 무관하게 실제 표에서 계산 |
| 결정 대기 `agent_question` · `agent_approval` · `agent_secret_question` | **실제 연결 (D4b-s, gate 뒤)** | `review_agent_inputs`: `agent_tasks.pending_question`(대화 run의 작업만). 항목 열쇠 = task id, version = `question:<task id>:<provider_request_id>`. `CONVERSATIONS_V2_ENABLED` ∧ 그 세션 연결의 adapter 플래그가 켜졌을 때만(답 route와 같은 gate) |
| 결정 대기 `result_ready` | **실제 연결 (D4b-s, gate 뒤)** | 끝나지 않은 대화 run의 마지막 턴 작업이 `idle`이고 `turn_seq > reviewed_turn_seq`인 현재 산출물이 있다. 항목 열쇠 = run id, version = `result:<run id>:<reviewed_turn_seq>:<마지막 turn_seq>:<산출물 수>`. 행동("Review result" · Later)은 E1c — 그 전에는 이슈 Done · 세션 Stop으로 사라진다 |
| 결정 대기 `path_conflict` | **실제 연결 (D4b-s, gate 뒤)** | `agent_path_leases.conflict_run_id`가 남은 lease(해제됐지만 해소 전인 것 포함), 늦게 쓴 run의 Action이 열려 있을 때. 항목 열쇠 = lease id, version = `conflict:<lease id>:<conflict_version>`. 해소는 새 route(JSON 계약 3-2) |
| 결정 대기 `suggestion` · `blocked_dependency` | **미연결 (계약 값만)** | 원천 표가 없다. 열린 제안은 `decisions`에 합치지 않고 Review의 `suggestions`로 따로 낸다 |
| 복귀 요약 변화 | **실제 연결** | `action_events`(사용자 자기 수정 · 본 것 이전 제외) · `execution_events`(done/failed) · `conversation_messages`(+ `last_read_at`). `inbox_events`는 읽지 않는다(C2 적재 실패 누락 한계로 완전성의 근거가 못 된다) |
| `conversations.last_read_at` | 읽기만 | 쓰는 코드는 아직 없다(열만). 쓰는 쪽이 생기면 그 이후 메시지만 변화다 |
| Receipts | **서버 몫 없음** | 틀은 Mac, 채움은 F2 |

## 5. 하지 않은 것 · 한계 (해결로 표시하지 않음)

- C2의 한계는 그대로다: 승인 · 철회 · 멈춤 · context version 적재 실패는 복구가 없고, sweep 1분, timer 전체 scan, dead_at 정책, 보관 기한, 전역 기억 생산자. C3는 `inbox_events`로 완전성을 주장하지 않는다.
- 운영 DB 적용 전, 실제 provider/Jev/eval 호출 없음, `vercel.json`/env/스케줄 변경 없음. 제안 생산은 Review 조회 때(멱등)뿐이다 — 별도 스케줄 생산은 `vercel.json` 변경이 필요해 하지 않았다.
- 읽기 비용: 후보 집합 digest는 사용자 이력 전체를 센다(`action_events` AI 변화 · run 결과 · 대화 메시지). 인덱스를 새로 만들지 않았다(기존 `action_events_action_idx` 등). 합성 한 번 측정(로컬 PG17 컨테이너 하나, 작업 2,000 · AI 변화 20,000 · 메시지 10,000, 동시성 없음): 조회 약 0.21–0.24초, 잘린 첫 페이지(300개) Clear 약 1.1초(첫 Clear라 run · 대화 이력 baseline 포함, 쌍 1만 3천 개 쓰기), 남은 전체 Clear 약 1.1초, 3만 쌍이 읽음인 뒤 조회 약 0.6초. **운영 규모의 증거가 아니다** — 운영 측정은 하지 않았다.
- 이 코드가 모르는 종류의 열린 제안(더 새 서버가 쓴 것)은 내리지 않고 `sources.suggestions: unavailable`로 알린다.
- 기준점은 앱이 확정을 보내야 생긴다. 서버는 토큰만 준다 — 무엇이 "정상 표시"인지는 앱의 책임이다(Mac 레인). 확정이 409 · 응답 유실로 안 닿으면 다음 정상 표시의 새 토큰으로 다시 한다(그동안 run · 대화 이력은 이전처럼 변화로 오르지 않는다). 기준점은 한 번 정해지면 바뀌지 않는다. 기준점 범위 digest도 읽음 여부와 무관한 사용자 이력 전체를 센다(읽기 비용은 위와 같은 종류).
- 시각 정밀도: 시각 글자는 SQL이 만든 마이크로초 UTC 그대로다. 앱이 Date로 바꿔 돌려주면 digest가 달라져 409가 난다(정직한 거절).
- 아래 결정 항목은 구현으로 정하지 않았다.

## 6. 열린 제품 결정 (구현하지 않았다)

| # | 결정 | 이 서버의 임시 동작 |
|---|---|---|
| P-1 | 복귀 요약의 **첫 기준 시각** — **해결(Daniel 승인 C, 2-1절)**: 첫 정상 표시의 별도 확정 쓰기. "Since …" 캡션 문구(`since:null`일 때)는 앱 몫 | 확정 전: `since:null` + `baseline:"never_cleared"` + `init_token`. 작업 변화는 사용자가 마지막으로 본 뒤만, run · 대화 이력은 올리지 않는다. 확정 뒤: `initialized`, Clear 없이 새 run · 메시지가 나온다 |
| P-2 | **새 문구 전부**: 변화 토큰 · `next` · 제안 세 종류 · `needs_time_zone`/`unavailable` 안내 | 서버는 토큰만 낸다(JSON 계약의 토큰 표) |
| P-3 | **제안 종류**(어떤 사실이 제안이 되는가) | 실제 원천이 분명한 세 가지만 |
| P-4 | **사용자 시간대의 출처 · 기본값** (H1 `report_preferences`와의 연결, 시간대를 모르는 사용자) | 모르면 새 비긴급을 내지 않는다 |
| P-5 | 읽음 표시 · 제안 행의 **보관/정리 정책** | 정책 없음: 지우지 않는다 |
| P-6 | 제안 **accept**가 낳는 효과 | 없음(snooze · dismiss만) |
| P-7 | `source_revised_run` 등 C2 결과를 쓰는 종류의 **사용자 노출 기준**(비긴급 3개 상한이 맞는가) | 비긴급 일일 묶음에 든다 |

## 7. 적용 · 되돌리기 · 점검

- 한 트랜잭션 마이그레이션 둘(`lock_timeout` 5초): `20261111000000_review_summary.sql`과 후속 `20261112000000_review_summary_baseline.sql`(11 파일은 고치지 않았다). 기존 표 · 함수 · 제약 · 트리거는 바꾸지 않았다(11: 새 표 3 + 새 함수만, 12: 새 표 1 + 새 함수 2 + 새 트리거 1 + `return_summary_scan`의 `create or replace`만): 시험이 적용 전후 객체 지문을 견준다(12는 `return_summary_scan` 하나만 달라야 하고 조회 결과의 기존 키는 기준점이 없는 사용자에게 같아야 한다). 적용은 병합 직전 승인을 받고 `supabase db query --linked -f`, `db push` 금지. 12는 11 뒤에만 적용한다.
- 되돌리기: 12 → 11 순서. 12 헤더의 문장(`drop function` 둘 · 11의 `return_summary_scan` 정의 재실행 + 그 함수의 `revoke`/`grant` · `drop table` · `drop function`)을 순서대로 실행하면 11 적용 후 객체 지문 · 권한으로 돌아간다(읽음 표시는 남는다). 그다음 11 헤더의 `drop` 문장 3개를 순서대로 실행하면 적용 전 객체 지문으로 돌아간다(시험이 둘 다 그대로 실행해 확인). 코드는 PR을 닫으면 된다. gate를 끄면 새 경로가 404이고 새 쓰기가 0이다(표는 남아 있어도 읽는 코드가 없다).
- 점검 쿼리 예(개수만): 제안 `select state, count(*) from suggestions group by 1`, 읽음 `select count(*) from return_summary_reads`(쌍 수).

## 8. 검증

| 무엇 | 어디 |
|---|---|
| DB 계약 (열 · 제약 · 권한 · search_path · 생산 · 노출 · 전이 · 읽기 · Clear · 업그레이드 · 되돌리기) | `tests/db/review-summary.scenarios.ts` (PGlite `.test.ts` + 실제 Postgres `tests/pg/review-summary.test.ts`) |
| P2-A 경합 (미커밋 INSERT · BEGIN 먼저 · run · 메시지 · 대조) · 동시 Clear · 하루 묶음 · 생산 · 전이 | `tests/pg/review-summary.test.ts` (연결 둘 이상) |
| 첫 정상 표시 기준점 (A–D 후속 C): GET 뒤 · 확정 전 commit → stale, 조회 때 미커밋 → 확정 뒤에도 보임, 두 기기 동시 확정, 확정 vs Clear 동시, 위조 · 남의 · 미래 토큰, 빈 첫 화면, 같은 시각 tie · 마이크로초, 업그레이드(이미 Clear한 사용자) · 되돌리기 | `tests/db/review-summary.scenarios.ts`(PGlite + 실제 Postgres), `tests/pg/review-summary.test.ts`(실제 Postgres 연결 여럿), `tests/review/baseline.test.ts`(운영 TS 위에서) |
| Review · 제안 · 시간대 읽기(P2-B) | `tests/review/review.test.ts` · `tests/review/time-zone.test.ts` |
| 복귀 요약 · Clear · 완전성 · 권한 경계 (A40 · ARCH06/07) | `tests/review/return-summary.test.ts` · `src/lib/review/*.test.ts` |
| API 처리 · 쿠키 CSRF · gate | `src/lib/api/review.test.ts` · `src/app/api/v2/review/csrf.test.ts` |
| v1 동결 | `src/lib/api/contract-v1-freeze.test.ts` (지문 그대로) |

# JSON 계약 (Mac이 읽는다)

### 공통

- 모든 경로는 `/api/v2/…`, 인증은 `Authorization: Bearer <Supabase access token>` 또는 웹 쿠키(쿠키로 인증하는 **POST**는 같은 출처만 — 아니면 401). 앱은 Bearer.
- **gate 둘**(서버 env, 모두 기본 꺼짐, 정확히 `"true"`만 켠다 — `TRUE` · `1` · 앞뒤 공백은 꺼짐):
  - `RETURN_SUMMARY_ENABLED`는 **복귀 요약 세 경로만** 연다: `GET /api/v2/return-summary` · `POST …/clear` · `POST …/baseline`.
  - `REVIEW_V2_ENABLED`는 **여섯 경로 전부**(위 셋 + `GET /api/v2/review` + 제안 `snooze` · `dismiss`; Review GET이 제안 생산 · 노출 표시를 한다)를 연다. 상위 집합이다.
  - 복귀 요약 세 경로는 **둘 중 하나라도 켜져 있으면** 열린다. Review · 제안 세 경로는 `REVIEW_V2_ENABLED`만 본다 — `RETURN_SUMMARY_ENABLED`만 켜면 Review · 제안은 계속 404이고 제안 생산 · 노출 · snooze · dismiss는 0이다.
  - | REVIEW_V2 | RETURN_SUMMARY | 복귀 요약 3경로 | Review GET · snooze · dismiss |
    |---|---|---|---|
    | off | off | 404 | 404 |
    | on | off | 열림 | 열림 |
    | off | on | **열림** | 404 |
    | on | on | 열림 | 열림 |
  - 닫힌 경로는 **404** `{"error":{"code":"not_found","message":"없는 경로입니다."}}`, 인증도 DB도 부르지 않고 새 쓰기 0 (열린 경로의 인증 · 쿠키 CSRF는 그대로). 앱은 404를 "이 서버는 아직 이 기능이 없다"로 읽고 기존 화면으로 둔다(오류 토스트 금지).
  - **에이전트 입력 gate (D4b-s, 새 플래그 없음)**: Review · 복귀 요약이 에이전트 입력(질문 · 결과 준비 · 경로 충돌)을 읽는 조건은 `CONVERSATIONS_V2_ENABLED` ∧ adapter 플래그(`AGENT_ADAPTER_CODEX_ENABLED` · `AGENT_ADAPTER_CLAUDE_CODE_ENABLED`) 하나 이상이다(`openAgentAdapters()`, 에이전트 대화 route의 gate와 같은 조건). **전부 꺼져 있으면 `review_agent_inputs`를 부르지 않고 응답이 C3와 바이트 동일하다**(운영의 기본 상태). adapter 하나만 꺼지면 그 adapter 세션의 질문 항목만 빠진다 — 그 질문의 답 route도 404라서 Review에 보이는 질문은 늘 답할 수 있다. 결과 준비 · 충돌은 adapter가 하나라도 켜져 있으면 나온다.
  - 경로 충돌 해소 route(아래 3-2)는 `REVIEW_V2_ENABLED` ∧ `openAgentAdapters()`가 비지 않음일 때만 열린다(Review가 충돌을 보이는 조건과 같다). `RETURN_SUMMARY_ENABLED`는 이 route를 열지 못한다.
- 오류 본문은 항상 `{"error":{"code","message"}}` (code ∈ 기존 `apiErrorCodeSchema`: `unauthorized` 401 · `invalid_request` 400 · `not_found` 404 · `conflict` 409 · `internal_error` 500). 새 오류 코드는 없다. `message`는 한국어 진단문이라 화면에 그대로 쓰지 않는다. 오류 본문에는 요청 값이 없다.
- 시각은 두 종류다: **마이크로초 UTC 글자** `2026-10-12T00:00:00.123456Z`(`since` · 변화 `at` · 커서 · `cleared_through`)는 **Date로 바꿔서 서버에 돌려주지 않는다**(커서는 불투명 글자 그대로). 나머지(`generated_at` · `created_at` · `shown_at` · `snooze_until`)는 `toISOString()` 모양(밀리초) ISO 8601.
- GET 응답은 `Cache-Control: no-store`. **`GET /api/v2/return-summary`는 아무것도 쓰지 않는다. `GET /api/v2/review`는 멱등 쓰기를 한다**(제안 생산 · 노출 표시, 아래 1절) — Action · run · Claim은 만들지 않는다.
- **숫자를 내리지 않는다.** 개수 · 합계 필드가 없다. 앱도 세지 않는다(디자인 D-12).
- 서버는 문구를 만들지 않는다. 아래 "토큰" 표의 토큰에서 앱이 문구를 만든다.

### 1. `GET /api/v2/review` — Review (결정 대기 + 열린 제안)

200 `ReviewResponse`:

```json
{
  "generated_at": "2026-10-12T09:00:00.000Z",
  "complete": true,
  "empty": false,
  "sources": { "decisions": "ok", "suggestions": "ok", "time_zone": "ok" },
  "decisions": [
    { "key": "<action_id>:approval", "action_id": "<uuid>", "kind": "approval", "urgent": true, "version": "9f2c1a0b3d4e5f60",
      "created_at": "2026-10-11T00:00:00.000Z",
      "items": [ { "id": "approval:<step_id>", "kind": "approval", "action_id": "<uuid>", "run_id": "<uuid>", "step_id": "<uuid>", "question_id": null,
                   "version": "step:<step_id>:3:1", "urgent": true, "urgent_reason": "due_window", "created_at": "2026-10-11T00:00:00.000Z" } ] }
  ],
  "suggestions": [
    { "id": "<uuid>", "kind": "due_window", "action_id": "<uuid>", "run_id": null, "urgent": true, "state": "open", "version": 1,
      "snooze_until": null, "offered_on": null, "created_at": "2026-10-12T08:59:59.000Z", "shown_at": "2026-10-12T09:00:00.000Z" }
  ],
  "suggestion_batch": { "state": "ready", "local_day": "2026-10-12", "size": 3 }
}
```

- `decisions` = C2 `pending_decisions` 계산 그대로: **(업무, 종류) 묶음**, 긴급 먼저 → 오래 기다린 순 → 종류 순(`PENDING_KINDS` 순서) → 업무 id. **이 순서가 Needs you 순서다 — 앱은 다시 정렬하지 않는다.** **개수 상한이 없다**(201개면 201개). `kind`는 C3의 `approval | review_failed | run_input | confirm`에 더해, **에이전트 입력이 켜졌을 때(위 "에이전트 입력 gate")** `agent_question | agent_approval | agent_secret_question | result_ready | path_conflict`가 나온다(`suggestion · blocked_dependency`는 계약에만 있는 예약 값 — 지금 원천이 없어 오지 않는다). **모르는 `kind`는 건너뛰되(Swift `.unknown`) `complete`를 true로 믿지 않는다.** 목록은 계산값이라 표가 없다.
- **에이전트 종류의 항목 (D4b-s)**: 항목 `id` = `<kind>:<열쇠>`(질문 셋은 task id, `result_ready`는 run id, `path_conflict`는 lease id). `step_id` · `question_id`는 null이다(답 열쇠는 아래 ref가 원천). 항목은 **자기 종류의 ref 하나만** 가진다 — C3 종류에는 `agent` · `result` · `conflict` 키 자체가 없다.
  - 질문 셋(`agent_question` 입력 · `agent_approval` 승인 · `agent_secret_question` 비밀값이 하나라도 섞임): `agent: { task_id, session_id, provider_request_id, adapter, bridge_id | null }`. 답은 **`POST /api/v2/agent-tasks/{agent.task_id}/answer { provider_request_id, answers }`**(D1d 답 route, Assistant 질문 카드와 같은 입구 · 같은 CAS)이고 승인은 `answers = { "approval": "allow" | "deny" }`다. `version` = `question:<task id>:<provider_request_id>`라서 **질문이 교체되면 같은 `id`에 다른 `version`**이 되고, 옛 화면이 옛 `provider_request_id`로 답하면 409 `question_stale`(답 단계 0)이다 → 앱은 Review를 다시 읽는다(새 version의 같은 id가 있으면 그 질문을 보인다). 답한 뒤 `pending_question`이 비면 다음 읽기에서 항목이 사라진다. **비밀값 항목은 Review에 보이되 서버로 답할 수 없다**(409 `secret_requires_local`): `agent.bridge_id`가 이 Mac의 bridge가 아니면 "다른 기기에서 답한다"로 보이고, 그 Mac은 값을 메모리에 두고 `POST /api/v1/bridge/answer-local`(OA F2)로 "이 Mac에서 답했다"만 표시한다 — 표시가 `answered`면 `pending_question`이 비어 다음 읽기에서 항목이 사라진다(세션 Stop으로도 사라진다).
  - `result_ready`: `result: { session_id | null, reviewed_turn_seq, last_turn_seq, changed_at }`. 턴이 `idle`로 끝나고 검토하지 않은 산출물이 있으면 **run마다 하나**(턴이 더해지면 같은 `id`에 version만 바뀐다). `changed_at` = 그 산출물 중 가장 늦은 생성 시각. 사라지는 때: 이슈 Done · 세션 Stop(run이 끝남) · Action이 닫힘 · 다음 턴이 진행 중 · E1c가 `reviewed_turn_seq`를 올림. **"Review result" · Later 행동은 E1c 몫이라 이 서버에는 없다.**
  - `path_conflict`: `conflict: { lease_id, conflict_version, holder_action_id, holder_run_id, later_run_id, released, stopped }`. 묶음 · 항목의 `action_id` · `run_id`는 **늦게 쓴(멈춘) run** 쪽이고 holder는 ref에 있다. 해소는 **`POST /api/v2/path-conflicts/{conflict.lease_id}/resolve { keep, conflict_version }`**(아래 3-2). 같은 lease에 새 충돌이 생기면 `conflict_version`이 올라 같은 `id`에 다른 `version`이 된다.
  - 응답에는 **글이 없다**: 질문 글 · 헤더는 `agent_tasks.pending_question`(카드는 그 값이 있을 때만), 경로는 `agent_path_leases.rel_path`, 이슈 번호는 `actions.number`를 앱이 RLS로 읽는다.
  - ⌥Space · ⌘1은 앱이 그리는 종류의 `decisions` 중 서버 순서 첫 항목(가장 오래 기다린 요청)을 연다. 요청이 없으면 ⌥Space는 마지막 화면, ⌘1은 빈 대화를 연다(앱은 순서를 다시 매기지 않는다. 계약 v3 5.4).
- 에이전트 입력 함수의 반환은 배열 하나(`[]`이면 입력 없음)다. 개수 상한이 없고 PostgREST `db-max-rows`에 잘리지 않으며, 배열이 아닌 값(null 포함)은 비었다고 읽지 않고 실패로 읽는다. 에이전트 입력 중 하나라도 읽지 못하거나 모양이 틀리면 **결정 전체**가 `unavailable`이다(`sources.decisions: "unavailable"` · `decisions: null` · `complete:false` · `empty:false`) — C3 결정만 보이고 에이전트 결정이 빠진 목록을 내지 않는다.
- `version`(묶음 · 항목)은 **처리되면 바뀌는 식별**이다. 다른 기기에서 처리되면 다음 조회에서 항목이 사라지거나(gone) version이 달라진다(stale). **옛 version으로 행동하지 않는다.** 항목 `id`는 안정 id.
- `suggestions` = 지금 보이는 열린 제안(`state`는 늘 `open`): 긴급(상한 밖) + 이미 노출한 비긴급 + 오늘 처음 노출된 비긴급(사용자 현지 날짜마다 **한 묶음 3개**). `offered_on`(YYYY-MM-DD)이 오늘이면 오늘 새로 나온 것. 긴급은 `offered_on: null`. 순서: 긴급 먼저 → 오래된 순.
- `suggestion_batch.state`: `ready`(시간대를 알아 하루 묶음을 센다) | `needs_time_zone`(**저장된 사용자 시간대가 없다** — 이 서버 스택에 시간대 저장소가 없거나 그 사용자의 값이 없는 **정당한 모름**이고 읽기는 완전하다: **새 비긴급은 아직 내지 않는다**, 긴급과 이미 낸 제안은 보인다) | `unavailable`(시간대를 **읽지 못했다** — 예상 못한 읽기 오류, 아래 `sources.time_zone`도 `unavailable`, `complete:false`: 새 비긴급은 내지 않고 긴급과 이미 낸 제안만 보인다). 앱은 어느 쪽도 "제안 없음"으로 보이면 안 된다.
- 완전성: `sources` 셋(`decisions` · `suggestions` · `time_zone`)이 모두 `ok`일 때만 `complete`. **`empty`가 true일 때만** "아무것도 없음"을 보여도 된다. 한 쪽이 `unavailable`이면 그 목록은 `null`이거나 **일부**일 수 있고(예: 이 서버가 모르는 종류의 제안이 있어 `suggestions`가 `unavailable`) 비어 있는 것이 아니라 **모르는 것**이다(Try again 상태로). `needs_time_zone`은 `unavailable`이 아니다: 저장된 시간대가 없다는 사실을 완전하게 읽은 것이다.
- **제안을 보는 것은 Action · run · Claim을 만들지 않는다. 그러나 이 GET은 읽기만 하지 않는다**: 제안 생산(지금 있는 사실에서 `suggestions` 행을 만든다, 멱등) · 노출 표시(`shown_at` · **그날의 비긴급 묶음 3개를 처음 정해 소비한다**) · snooze가 끝난 제안을 다시 연다 · 증거가 생긴 제안(기한이 바뀜 · Action이 닫힘 · run이 끝남)을 `expired`로 닫는다. 같은 하루 안에서 몇 번을 불러도 같은 묶음이다. 두 기기가 동시에 불러도 묶음은 하나다. GET이라 쿠키 CSRF 검사 대상이 아니다(앱은 Bearer): 다른 사이트가 쿠키 세션의 GET을 일으켜 그날 묶음을 앞당겨 소비시킬 수는 있다(응답은 읽지 못한다) — 열린 판단 D-4.
- 401 로그인 필요 · 404 gate 꺼짐 · 500 `internal_error`(전체 실패; 일부 실패는 200 + `unavailable`).

### 2. `GET /api/v2/return-summary` — 복귀 요약

200 `ReturnSummaryResponse`:

```json
{
  "generated_at": "2026-10-12T21:00:00.000Z",
  "since": "2026-10-12T08:00:00.000000Z",
  "baseline": "cleared",
  "init_token": null,
  "cursor": "c3.WyIxMTExLi4uIiwiMjAyNi0xMC0xMlQyMDowMDowMC4wMDAwMDBaIiwi…",
  "complete": true,
  "empty": false,
  "sources": { "changes": "ok", "decisions": "ok" },
  "items": [
    { "action_id": "<uuid>", "title": "확인이 필요한 일", "status": "open", "state": "to_do",
      "needs_answer": true, "urgent": false,
      "decisions": [ { "id": "confirm:<action_id>", "kind": "confirm", "version": "action:<id>:4", "urgent": false } ],
      "changes": [],
      "next": { "kind": "answer", "decision_kinds": ["confirm"] },
      "version": "0a1b2c3d4e5f6071" },
    { "action_id": "<uuid>", "title": "초안 작성", "status": "open", "state": "in_progress",
      "needs_answer": false, "urgent": false, "decisions": [],
      "changes": [ { "source": "run", "kind": "done", "at": "2026-10-12T13:00:00.000000Z", "detail": "draft_ready", "source_state": null } ],
      "next": { "kind": "review_result", "decision_kinds": [] },
      "version": "7c6b5a4938271605" }
  ]
}
```

- **한 줄 = 업무 하나**(`action_id`가 안정 id). 줄에는 `StatusMark`(`state`), `title`(**지금 제목** — 옛 제목 · 원문 글 · 변경 전후 값은 절대 내려가지 않는다), 변화(`changes`), `Needs your answer`(`needs_answer`), `Next`(`next`). 줄을 누르면 그 업무 상세. 순서: 답할 결정이 있는 줄(긴급 맨 앞) → 최근 변화 순 → id.
- `state`: `to_do | in_progress | done | null`(취소된 업무는 null). `status`: `open | done | dropped`.
- `changes`(시각 순, 안 읽은 것만): `source` ∈ `action_event`(원문 · AI · 실행기 변화 — **사용자 자기 수정 · 사용자가 본 이전 변화는 없다**, `changed.ts`와 같은 뜻) · `run`(실행 결과 전이 `done | failed`, `detail`=run outcome) · `message`(안 읽은 `assistant | event` 메시지가 그 업무를 가리킴). `source_state`(action_event만): `available | deleted | access_lost | text_expired` — **지운 원문 · 접근 상실 · 보관 만료는 글이나 옛 제목으로 되살리지 않고 이 토큰으로만** 보인다.
- `since`: **마지막 Clear의 지평**(마이크로초, "Since …" 표시용). **읽음의 근거가 아니다** — 무엇이 읽혔는지는 서버가 (사건, 작업) 쌍으로 기억한다. 그래서 Clear 뒤에 commit된 사건은 시각이 `since`보다 이르더라도 다음 조회에 **새 변화로 보인다**(트랜잭션 시작 시각 때문에 숨지 않는다). Clear한 적이 없으면 `null`(`initialized`도 `null`일 수 있다 — 표시 문구는 앱 몫).
- `baseline`: `cleared`(Clear한 적 있음 — 업그레이드 이전에 Clear한 사용자도 여기, 기존 읽음 그대로) | `initialized`(첫 정상 표시 기준점은 있고 Clear는 아직 없음 — 기준점 뒤의 새 run 결과 · 메시지는 **Clear 없이** 변화로 나온다) | `never_cleared`(Clear도 기준점도 없음 — run · 대화 이력은 변화로 올리지 않고, 업무 변화(`action_event`)는 "사용자가 마지막으로 본 뒤"만 올린다. 아래 `init_token`이 있으면 기준점을 정할 수 있다) | `unknown`(변화 원천을 읽지 못함).
- `init_token`: **`baseline == "never_cleared"`이고 변화 읽기가 성공(`sources.changes` ∈ `ok | truncated`)했을 때만** 문자열, 그 밖에는 `null`(`cleared` · `initialized` · `unknown`, 변화 읽기 실패). **빈 첫 화면(`empty: true`)에도 발급된다.** 서버가 만든 불투명 글자(최대 400자): 열지도 고치지도 시각으로 바꾸지도 않는다. 앱은 **그 응답을 정상 표시했을 때만** `POST /api/v2/return-summary/baseline`에 그대로 돌려준다(아래 3-1). 결정(`sources.decisions`) 읽기만 실패해도 토큰은 나온다(결정은 기준점 범위가 아니다).
- `cursor`: **Clear에 그대로 돌려줄 불투명 글자**(조회가 본 사건 집합의 지문, 최대 약 9KB). 열지도 고치지도 시각으로 바꾸지도 않는다. **`cursor`가 있으면 Clear할 수 있다.** `null`은 변화 원천을 읽지 못했을 때뿐이다(`sources.changes: unavailable` — 읽음 처리할 범위를 정할 수 없다). **잘렸어도(`truncated`) 커서가 있다**: 그 커서는 **지금 보인 작업의 사건만** 읽음 처리하고, 보이지 않은 작업은 읽음이 되지 않아 다음 조회에 나온다.
- 완전성: `sources.changes` ∈ `ok | unavailable | truncated`(작업이 300개를 넘으면 `truncated` + 가장 최근 변화 순 앞 300개만 — 사용자가 이미 본 작업은 세지 않는다), `sources.decisions` ∈ `ok | unavailable`. `complete` = 둘 다 `ok`. **`empty`(= complete이면서 items가 빔)일 때만** "변화 없음 · 모두 처리됨"을 보일 수 있다. `unavailable`/`truncated`는 비어 있는 것이 아니라 일부를 모르는 것이다. `truncated` 페이지를 Clear해도 "모두 처리됨"이 아니다: 다음 GET에 나머지가 나온다(마지막 페이지는 `truncated`가 아니다).
- 결정(`decisions`)은 Clear와 무관하다 — **읽음은 결정이 아니다.** Clear 뒤에도 `needs_answer` 줄은 남고 ⌥ Space는 Review 먼저다. `decisions[].id/version`은 Review의 항목 `id/version`과 같은 값이다(상세 연결 키) — 에이전트 종류(위 1절)에서도 같다(같은 계산을 쓴다). 에이전트 결정만 있는 업무도 줄이 있다(제목 · 상태). "Since …" 칸에서 해야 할 일을 빼는 것은 화면 규칙이고, 서버는 결정을 줄에 그대로 싣는다.
- `needs_answer`: **`result_ready`가 아닌 결정이 하나라도 있다**(결과 준비는 답할 것이 아니라 검토할 것이라 "Needs your answer"를 만들지 않는다).
- `next.kind`: `answer`(답할 결정이 있음 — 위 `needs_answer`) · `review_result`(`result_ready` 결정만 있거나, 끝난 결과 `draft_ready`/`agent_done`를 볼 차례) · `open`(그 업무를 열어 본다). `decision_kinds`는 줄에 **있는 결정 종류 전부**(결정이 없으면 빈 배열).
- 줄 `version`: 줄의 변화 · 결정이 바뀌면 달라지는 글자. 같은 `action_id`의 줄을 비교할 때 쓴다.
- 401 · 404 · 500.

### 3. `POST /api/v2/return-summary/clear` — Clear (읽음 처리)

요청 `{ "cursor": "<GET이 준 글자 그대로>" }` (1–10,000자, 그 밖의 키는 400). 응답 200 `{ "cleared_through": "2026-10-12T20:00:00.000000Z", "applied": true }`.

- **Clear = 조회가 본 (사건, 작업)만 읽음 처리한다. 해결 · 승인 · 완료 · 거절이 아니다**(결정 · Action · run · 정책 · 승인 어느 것도 바뀌지 않는다). 기존 `POST /api/v1/actions/{id}/seen`과 다르다 — 그것은 now()를 찍지만 Clear는 **커서가 가리키는 (사건, 작업) 쌍만** 읽음으로 표시한다(시각 워터마크를 옮기지 않는다).
- **잘린 조회의 Clear**: 커서가 보인 작업(최대 300개)을 싣고 있어, Clear는 그 작업들에 대한 (사건, 작업) 쌍만 읽음 처리한다 — 보이지 않은 작업은 읽음이 아니다. **한 메시지가 여러 작업을 가리켜도 작업마다 따로 읽는다**: 보인 작업에서는 읽음이 되고 보이지 않은 작업에는 그 메시지가 안 읽은 변화로 남아 다음 조회에 나온다(조회 → Clear를 되풀이하면 모두 읽음이 된다). 재시도 · 두 기기도 같다(같은 커서 `applied:false`). 보인 작업에 조회 뒤 Clear 전에 늦게 들어온 사건이 있으면 409(다시 조회), 보이지 않은 작업의 사건은 Clear에 영향이 없다.
- 조회와 Clear 사이에 생긴 새 변화는 **남는다**(다음 조회에 보인다). 조회 때 **아직 commit되지 않았던** 사건도 Clear가 읽음으로 만들지 못한다 — 나중에 commit되면(그 행의 `at`이 조회 지평보다 이르더라도) 다음 조회에 보인다. 읽음은 **줄지 않는다**(단조): 겹친 조회 · 두 기기 · 늦은 Clear · 응답 유실 뒤 같은 커서 재시도는 `200 applied:false`(쓸 것이 없었다 — 성공이다).
- **409 `conflict`**: 조회한 뒤 Clear 전에 그 범위의 사건이 달라졌다(늦게 들어온 변화 · 삭제). **아무것도 읽음 처리하지 않았다.** 앱은 자동 재전송하지 않고 다시 조회한다(변화가 아직 보인다).
- **400 `invalid_request`**: 모양이 틀린 · 미래 · 남의 · 옛 커서. 다시 조회한다.
- 404 gate 꺼짐 · 401 · 500. 클라이언트 시각을 보내지 않는다 — 서버가 낸 커서만 통한다.

### 3-1. `POST /api/v2/return-summary/baseline` — 첫 정상 표시 기준점 확정

요청 `{ "init_token": "<GET이 준 글자 그대로>" }` (1–400자, 그 밖의 키는 400). 인증은 Bearer(쿠키로 인증하는 POST는 같은 출처만 — 아니면 401), gate가 꺼져 있으면 404. 응답 200 `{ "status": "initialized" | "already_initialized", "applied": true | false }`.

- **뜻**: 사용자가 요약을 처음 **정상 표시**한 순간 그때까지의 run 결과 · 읽은 시각이 없는 대화 메시지 이력(= `never_cleared`에서 변화로 올리지 않던 바로 그 집합)을 "본 과거"로 읽음 표시한다. **읽음 표시일 뿐이다 — 결정 · 완료 · 승인이 아니다.** 미열람 Action 변화(`action_event`)와 미결정은 건드리지 않는다(Clear 뒤에도 `needs_answer` 줄이 남는 것과 같다). 기준점 뒤에는 Clear를 한 번도 안 눌러도 새 run 결과 · 메시지가 요약에 나온다.
- 200 `initialized` / `applied:true`: 한 문장(같은 스냅샷)에서 기준점 범위 digest가 토큰과 같음을 확인하고 그 (사건, 작업) 쌍을 읽음으로 표시하며 기준점 행을 쓴다. 토큰 지평 **뒤**의 사건 · 확정 때 **아직 commit되지 않았던** 사건은 범위 밖이라 읽음이 아니다 — 다음 조회에 새 변화로 보인다. 성공 뒤 앱은 GET으로 다시 읽는다.
- 200 `already_initialized` / `applied:false`: 이미 기준점이 있거나 Clear한 적이 있다(두 기기 · 응답 유실 뒤 같은 토큰 재시도 · 늦은 확정). **아무것도 쓰지 않았다**(다시 초기화하지 않는다, 기존 읽음 그대로) — 성공이다.
- **409 `conflict`**: 조회한 뒤 확정 전에 기준점 범위가 달라졌다(늦게 들어온 사건 · 삭제). **아무것도 쓰지 않았다.** 앱은 자동 재전송하지 않고, **다음 정상 표시**(새 GET의 새 토큰)에서 다시 확정한다.
- **400 `invalid_request`**: 모양이 틀린 · 남의 · 미래 지평 · 옛 형식 토큰.
- 404 gate 꺼짐 · 401 · 500. 클라이언트 시각 · 읽음 목록 · 사용자 id를 보내지 않는다 — 서버가 낸 토큰만 통한다.
- Clear와의 관계: 기준점 **전** Clear는 그대로 기준점 이력도 읽음으로 삼는다(이후 `cleared`, 이 확정은 `already_initialized`). 기준점 **뒤** Clear는 기준점 이력을 다시 다루지 않는다. 같은 사용자의 확정 · Clear는 서버에서 직렬이다.

### 3-2. `POST /api/v2/path-conflicts/{lease_id}/resolve` — 경로 충돌 해소 (OA D4b-s)

요청 `{ "keep": "holder" | "later", "conflict_version": <정수 ≥ 1> }`(그 밖의 키 · 범위 밖 값은 400). `conflict_version`은 Review 항목 `conflict.conflict_version` 그대로다(정수 CAS). 응답 200 `{ "status": "resolved" }`. 인증은 Bearer(쿠키로 인증하는 POST는 같은 출처만 — 아니면 401), gate는 위 "에이전트 입력 gate"의 해소 route 줄.

- **뜻**: 같은 경로를 쓴 두 세션 중 한쪽을 남긴다. `holder` = 먼저 쓴 쪽을 남긴다(충돌 표시만 지운다). `later` = 늦게 쓴 쪽을 남긴다(holder의 살아 있는 lease를 `conflict_resolved`로 푼다). **멈춘 run을 다시 시작하지 않고 파일을 되돌리지 않는다.** 효과는 D3c-2 SQL(`resolve_path_conflict`) 그대로이고, 성공한 해소마다 지표 `path_conflict_resolved {keep}`가 같은 트랜잭션에 한 줄 남는다(새 지표 type 없음).
- **409 `conflict`**: 옛 `conflict_version`이거나 이미 해소됐다(같은 lease에 새 충돌이 생긴 경우 포함). **아무것도 쓰지 않았다**(지표 0). 앱은 자동 재시도하지 않고 Review를 다시 읽는다. 응답이 유실돼 같은 요청을 다시 보내면 409가 정상이다(다시 읽으면 항목이 없다).
- 404: 없는 lease · 남의 lease(구별하지 않는다) · gate 꺼짐. 400: 본문 오류. 401. 500: 그 밖의 서버 오류(로그에는 오류 이름만, lease id · 경로 · 본문 0).
- 응답에 글이 없다. 되돌릴 수 없는 일이므로 보내기 전 확인(2초 보류)은 Mac 몫이다.

### 4. `POST /api/v2/suggestions/{id}/snooze` · `/dismiss` — 제안 처리

- snooze 요청 `{ "expected_version": 1, "snooze_until": "2026-10-13T09:00:00+09:00" }` — 시점은 **사용자가 고른 것**(오프셋이 있는 ISO). 지금 이후 · 366일 이내(아니면 400). 서버가 시점을 정하지 않는다(자동 snooze 없음). 시점이 지나면 같은 제안이 다시 `open`이 된다(새 제안이 아니다, `version`이 오른다).
- dismiss 요청 `{ "expected_version": 1, "scope": "this" | "topic" }` — `topic`은 같은 종류 + 같은 주제의 새 계기도 다시 제안하지 않는다.
- 응답 200 `{ "suggestion": { …Suggestion, "state": "snoozed" | "dismissed", "version": n+1 } }`.
- `expected_version`은 Review가 준 `suggestions[].version`. **409 `conflict`**: 옛 version이거나 이미 처리된(다른 기기) 제안 — 아무것도 쓰지 않았다. **자동 재시도 금지**, 다시 조회. 404: 없거나 남의 제안(구별하지 않는다). 400: 본문 · 시점 오류. 응답이 유실돼 같은 요청을 다시 보내면 409가 나오는 것이 정상이다(다시 조회하면 처리된 상태).
- `accept`는 **없다**(채택이 낳는 효과가 아직 정의되지 않았다). `state`의 `accepted`/`expired`는 계약 값이지만 이 서버가 보이는 목록에 내지 않는다.

### 토큰 (앱이 문구로 옮긴다)

| 토큰 | 값 | 앱에 이미 있는 문구 | 승인 필요 |
|---|---|---|---|
| `changes[].kind` (`action_event`) | `due_changed`(기한) · `scope_changed`(**제목이 바뀜**) · `owner_changed`(담당) · `merged`(**원문에서 다시 언급돼 갱신됨** — 확인 사유가 바뀐 경우 포함) · `completed` · `dropped`(취소) · `reopened` · `artifact_created` | `ActionHistory.swift`의 활동 문구(있는 것) | 복귀 요약 한 줄 변화 문구가 따로 필요하면 |
| `changes[].kind` (`run`) | `done`(+`detail`: `draft_ready` · `needs_input` · `needs_connection` · `needs_capability` · `review_failed`(**수정이 필요하다는 뜻만** — 성공이 아니다) · `agent_done`(**검토를 거친 결과만**)) · `failed`. `detail`이 위 값이 아니거나 `null`이면 **알 수 없는 결과**다 — 정상 성공으로 읽지 않고 중립 문구로만 보인다 | `RunLaneText.swift` 결과 문구(있는 것) | `agent_done` 등 새 outcome 문구 |
| `changes[].kind` (`message`) | `assistant · event` | 없음 | 필요하면 |
| `changes[].source_state` | `available · deleted · access_lost · text_expired` | `deleted`/`access_lost`/`text_expired` 일부(원문 삭제 · 보관 기간 문구) | 복귀 요약용 문구 |
| `next.kind` | `answer · review_result · open` | SSOT 예시 "Next: accept the result" | 세 토큰별 문구 |
| `decisions[].kind` / `decision_kinds` | `approval · review_failed · run_input · confirm`, 에이전트 입력이 켜졌을 때 `agent_question · agent_approval · agent_secret_question · result_ready · path_conflict` | S4 Review의 확인 요청 문구(`confirm`) | 나머지 여덟 |
| `suggestions[].kind` | `due_window · run_failed · source_revised_run` | 없음 | **세 종류 모두 새 문구** |
| `suggestion_batch.state` | `ready · needs_time_zone · unavailable` | 없음 | `needs_time_zone` · `unavailable` 안내 문구 |
| `baseline` | `cleared · initialized · never_cleared · unknown` | 없음 | "Since …" 캡션이 없을 때의 문구(`initialized` · `never_cleared`는 `since:null`) |
| SSOT 고정 문구 | `Since <since>` · `Clear` · `Needs your answer` · `Next: …` | 디자인 SSOT 원문 | 이미 승인된 디자인 |

### 앱이 하면 안 되는 것 (서버 계약)

1. `unavailable`(`sources`의 어느 값이든, `time_zone` 포함) · `truncated` · `cursor: null` · `complete: false`를 빈 상태로 보이지 않는다. `empty: true`일 때만 "변화 없음 · 아무것도 없음"이다. `needs_time_zone`은 오류가 아니라 정당한 모름이다(읽기는 완전하다). 잘린 페이지의 Clear는 "모두 처리됨"이 아니다(다음 GET을 다시 부른다).
2. Clear 409를 자동 재전송하지 않는다. 클라이언트 시각 · 마이크로초를 잘라 만든 커서를 보내지 않는다.
3. 읽음(Clear/열기)을 결정으로 다루지 않는다. 결정은 Review의 항목 `version`으로만 처리하고 옛 version으로 행동하지 않는다.
4. 제안 처리(snooze/dismiss)의 409를 자동 재시도하지 않는다. 숫자 · 개수를 만들지 않는다.
5. 원문 글 · 옛 제목을 캐시해 되살리지 않는다(서버도 주지 않는다). 새 영구 원문 캐시 없음.
6. `init_token`은 **그 응답을 정상 표시했을 때만** 확정에 쓴다(디코드 성공 · `sources.changes` ∈ `ok | truncated` · 앱이 표현하지 못하는 변화가 표시에 없음 · 같은 계정 · 패널이 그 응답을 실제로 보이는 중). 읽기 실패 · 오래된 응답 · 닫힘 · 계정 바뀜이면 보내지 않는다(쓰기 0). 토큰을 열거나 고치거나 시각으로 바꾸거나 저장해 두었다 나중에 보내지 않는다.
7. 확정 409 · 응답 유실을 자동 재전송하지 않는다 — 다음 정상 표시의 새 GET이 준 새 토큰으로만. 확정 성공 뒤에는 GET으로 다시 읽는다. 확정은 읽음 표시일 뿐 결정이 아니다.
8. `run`의 `detail`이 모르는 값이면 정상 성공 문구(결과가 준비됨)로 올리지 않는다. `review_failed`를 실패 · 오류로 단정하지 않는다(수정이 필요하다는 뜻), `agent_done`을 아무 완료에나 쓰지 않는다(검토를 거친 결과).
9. (D4b-s) 모르는 `decisions[].kind`는 건너뛰되(`.unknown`) `complete`를 true로 믿지 않는다. `decisions`의 순서를 다시 매기지 않는다(서버 순서가 Needs you 순서).
10. (D4b-s) 에이전트 질문 · 해소의 409(`question_stale` · `conflict`)를 자동 재시도하지 않는다 — Review를 다시 읽는다. 비밀값 항목(`agent_secret_question`)의 답을 서버로 보내지 않는다(409 `secret_requires_local`; 값은 서버로 오지 않는다). 그 Mac의 표시는 값 없는 `POST /api/v1/bridge/answer-local { bridge_id, agent_task_id, request_digest }`뿐이다(OA F2).
11. (D4b-s) 응답에 없는 글(질문 · 경로 · 파일 이름)을 서버에 요청하지 않는다 — 앱이 RLS로 읽는다. 결과 준비 항목에서 `reviewed_turn_seq`를 올리는 행동은 E1c 전에는 없다.
