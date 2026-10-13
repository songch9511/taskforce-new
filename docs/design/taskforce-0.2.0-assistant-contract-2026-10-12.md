# 어시스턴트 · 맥락 칩 · 에이전트 직접 대화 — 서버 계약 (설계 v2, 2026-10-12)

상태: **설계 문서. 코드 · 마이그레이션은 아직 없다.** 사용자가 승인하면 구현한다.
v1 → v2: 독립 검토(같은 날)의 F1–F21을 반영했다. 바뀐 핵심은 "대화 턴 ≠ 작업 완료"(3.4), 칩의 전송 동의(2.3), 멱등 열쇠(3.3 · 3.5), 선행 조건(0.2)이다.
3차 검토(10-13 변경분)의 지적을 반영했다: 열 이름 `state`, `kind`로 통일, `agent_connections`는 select만, stale 판정 함수 대체, 전달 상태 열 · 계기 · 만료 cron, 공유 세션에서 Done은 진행 중 턴만 cancel, 경로 lease 30분 TTL, 계산 입력의 원천 열(`reviewed_turn_seq`, `conflict_*`), **병합 재설계(Claim · run을 옮기지 않고 닫아서 잇는다)**, 확인 카드 = proposal, 세션 잠금, `issue_moved` 이벤트.
v2 재검토의 N1–N9와 부분 반영(F6 · F11 · F14 · F16 · F17 · F19 · F20)을 국소 수정으로 반영했다: 세션당 열린 대화 run 하나를 보장하는 부분 unique 인덱스, Done은 중단만, 승인 질문은 자유 글로 답하지 않음, Stop 뒤 새 run, 에이전트 연결은 별도 표, Review result 시트, 사건 열쇠는 별도 열, `idle` 규칙, 대화 둘이 붙은 세션의 글 경로.

기준 코드: `~/.claude/worktrees/taskforce-020/c3-server` (`claude/020-c3-review-summary`, PR #131) — 대화 v2(B2/B3), 맥락층(B1/S3b), 실행 계약(C1), 코디네이터(C2).
화면: Figma `ieGR9CeHpR27xXvH0x5jOE` "Merged plan" M6 · M6b, 디자인 시스템 README "Assistant window"(버전 30).

## 0. 결정과 선행 조건

### 0.1 이 문서가 받는 결정 (사용자, 2026-10-12)

| # | 결정 | 장 |
|---|---|---|
| U1 | Projects · Issues · 이슈 상세 패널에는 입력창이 없다. 대화는 떠 있는 Assistant 창에서 한다(여러 개 동시). 세션 패널과 Review는 입력창을 유지한다 | 1 |
| U2 | 지금 보는 항목은 자동으로 칩이 되고, 다른 항목은 Ask · 끌어다 놓기 · 첨부로 붙인다 | 2 |
| U3 | **에이전트와 직접 대화가 필요하다.** Assistant의 대상은 Taskforce 또는 사용자가 연결한 에이전트다 | 3 |
| U4 | Cursor는 앞으로 붙일 많은 에이전트 연결의 한 예다. 연결 구조는 계속 더할 수 있어야 한다 | 4 |
| U5 | 프로젝트는 사용자가 만들고 이름 · 아이콘을 정하고 보관한다. 자동 생성 없음 | 6 |
| U6 | 일을 맡기는 순간 이슈(Action)가 생긴다. 이슈 없는 실행은 없다 | 3.3 |
| U7 | 실행 중에는 보내기 버튼이 Stop이 된다 | 5 |
| U8 (10-13) | 결과 검토는 Review로 합친다. Dock에 Review 항목은 검토할 것이 있을 때만 나온다 | 3.4 |
| U9 (10-13) | 세션 하나가 이슈 여러 개를 맡을 수 있다 | 3.3 · 3.4 · 3.8 |
| U10 (10-13) | 0.2.0의 에이전트는 Claude Code · Codex만. Cursor는 나중 | 4.4 |
| U11 (10-13) | 이슈를 프로젝트에 넣는 것은 사용자가 한다: 이슈 우클릭 → 프로젝트 선택, 또는 Taskforce에게 말로 | 6 |

### 0.2 선행 조건 — 아직 없는 것 (검토 F1)

이 계약은 아래가 있어야 돈다. 모두 계획의 D1 묶음이고 c3 기준 코드에는 **없다**.

| 필요한 것 | 지금 | 근거 |
|---|---|---|
| `agent_sessions` · `agent_tasks` 표, `cancel_agent_task` RPC | 없음 (contract.ts에 zod만) | `20261103000000_context_core.sql:63` "agent_sessions가 생기는 PR(D1)" |
| `create_run`의 goal `agent` | 없음 (`draft`만) | `20261109000000_execution_additive_contract.sql:105` |
| bridge 표 · 명령 lease · 사건 수신 | 없음 (`bridgeRegisterRequestSchema`만) | `contract.ts:1162` |
| `pending_decisions`의 에이전트 질문 입력 | 계산 목록의 `FutureInputs`로만 있음 (연결 안 됨) | `src/lib/coordinator/pending.ts:15,38` |

구현 순서: **D1(위 표) → 이 계약**. 이 문서는 D1이 런타임 계약 5장대로 만들어진다고 가정하고, 그 위에 더하는 것만 정한다.

### 0.3 지키는 것

CLAUDE.md 원칙 1–6 · 실행은 Action에 묶인다(`execution_runs.action_id not null`, `create_run`은 열린 Action 요구) · 쓰기 gate는 capability `verified`로만 열린다(런타임 계약 5장) · I14(범위는 권한이 아니다) · I16(Taskforce는 에이전트 로그인 · 토큰을 다루지 않는다) · Slack 원문은 묶음 · 외부 전송에 넣지 않는다(D3) · 대화 v2의 멱등 규칙.

## 1. 개념

- **Assistant 대화** = `conversations` 한 행 + **대상(target)**. 창 하나 = 대화 하나. 창 위치 · 크기 · 숨김은 앱 로컬 상태다.
- **대상**은 둘 중 하나다.
  - `taskforce`: 지금의 대화 v2 그대로(의도 분류 → 조회 · 상담 · 제안 · 채택 · 위임). 메시지 하나에 답 하나(`conversation_finish_turn`).
  - `agent`: 사용자가 연결한 에이전트 하나와의 대화. 사용자의 글은 그 에이전트 세션에 **그대로** 가고, 에이전트의 글도 그대로 보인다. Taskforce는 글을 고쳐 쓰지 않되 **기록 · 정책 · 상태 · 권한**을 맡는다.
- **맥락 칩(attachment)** = 메시지 하나에 붙는 대상 목록. 대화의 기본 범위(`conversations.context_id`, B3)는 그대로이고 칩은 메시지마다 다르다.

## 2. 맥락 칩

### 2.1 요청

`POST /api/v2/conversations/{id}/messages`에 `attachments`를 더한다. 기존 `refs`(action_ids · run_ids · artifact_ids)는 호환을 위해 받고, 새 앱은 `attachments`만 보낸다.

```ts
export const attachmentKindSchema = z.enum(["action", "context", "agent_session", "run", "artifact", "source"]);
export const attachmentSchema = z.object({
  kind: attachmentKindSchema,
  id: z.uuid(),
  origin: z.enum(["auto", "added"]),   // auto = 패널에 열린 항목(점선 칩), added = Ask · 끌어다 놓기 · 첨부
}).strict();
// postConversationMessageRequestSchema += attachments: z.array(attachmentSchema).max(20).optional()
```

결정(Review 항목)은 칩 종류가 아니다. `pending_decisions`는 표가 아니라 계산값이고(`coordinator_core.sql:3`), 항목 id는 `${kind}:${step_id|question_id|…}`라 uuid가 아니며 처리되면 사라진다(`pending.ts:76`). 결정을 가리키려면 그 결정의 `run` · `agent_session` 칩을 쓴다(검토 F2).

### 2.2 서버 규칙

| 규칙 | 내용 |
|---|---|
| 소유 | 모든 id는 요청자 것이어야 한다. 아니면 404(존재를 드러내지 않음), 쓰기 0 |
| 정규화 | (kind, id) 소문자 · 중복 제거 · 정렬. 같은 (kind, id)가 auto와 added로 함께 오면 added 하나 |
| 저장 · 멱등 | 정규화한 목록을 **`conversation_messages.selected`**에 넣는다(`selected`가 "고른 대상"이고 같은 제출 비교에 쓰이는 열이다, `conversations_v2.sql:6,35`). 같은 `client_message_id`에 attachments가 다르면 409 `refs_mismatch`(기존 코드). `refs`는 지금처럼 "정해진 대상"으로 서버가 쓴다 |
| 재시도 | 앱은 처음 보낸 attachments를 `client_message_id`와 함께 저장해 두고 재전송에 그대로 쓴다. 패널이 바뀌어 auto 칩이 달라져도 재전송 값은 바꾸지 않는다(검토 F18) |
| 지시 대상(런타임 계약 2장) | **added 칩만 규칙 1(명시 참조)**이다. auto 칩은 규칙 3의 후보로만 쓴다. 그래서 패널을 연 채 "그렇게 해"라고 하면 규칙 2(직전 제안 · 질문)가 먼저다(검토 F10) |
| 읽기 범위 | 칩은 답을 만들 때 읽을 범위만 넓힌다. 실행 권한 · 정책 · 연결 범위를 바꾸지 않는다(I14 원리) |
| 빠진 칩 | 지워졌거나 접근을 잃은 칩은 `content.used`에서 빼고 응답 `attachments_dropped: [{kind, id, reason: "deleted" \| "access_lost" \| "slack_purged"}]` |

### 2.3 외부 에이전트로 보낼 때의 동의 (검토 F10)

- 대상이 `taskforce`면 칩 내용은 Taskforce 자체 호출(ZDR, 처리방침 범위)에만 쓰인다.
- 대상이 `agent`면 **added 칩만 보낸다.** auto 칩은 보내지 않는다. 앱은 에이전트 대화에서 auto 칩을 "Not sent" 상태(점선 유지)로 두고, 사용자가 누르면 added가 된다. 이것이 런타임 계약 5장 "전송 동의"다.
- 보낼 때도 묶음 규칙을 그대로 쓴다: Slack 원문 제외, 보관 기한 지난 글 제외, 신뢰 등급 표시, 묶음 hash 기록.

### 2.4 응답

`postConversationMessageResponseSchema`를 이렇게 바꾼다(검토 F4).

```ts
{
  message: conversationMessageSchema,                 // 저장한 사용자 메시지
  reply: (conversationMessageSchema & {...}).nullable(),  // taskforce 대상: 지금처럼 필수. agent 대상: null (답은 비동기, 3.5)
  delivery: { state: "answered" | "sent" | "queued" | "needs_referent" | "not_sent" | "expired",
              reason?: "not_connected" | "sign_in_needed" | "unsupported" | "write_gate_closed",
              candidates?: Array<{ action_id: string, title: string }> }, // needs_referent일 때 ≤ 3
  attachments_dropped: Array<{ kind, id, reason }>,
  created_action: { id, number, title, context_id: string | null } | null,   // 3.3
  agent_task: { id, state, agent_session_id } | null,
}
```

## 3. 에이전트 직접 대화

### 3.1 대화의 대상

`conversations`에 열을 더한다.

| 열 | 뜻 |
|---|---|
| `target_kind text not null default 'taskforce' check (in ('taskforce','agent'))` | 대상 |
| `agent_connection_id uuid null` | `agent`면 필수. 내 에이전트 연결(4.2) |
| `agent_session_id uuid null` | 첫 전달 때 **조건부 갱신(`where agent_session_id is null`)**으로 한 번만 묶인다(검토 F17) |

- 대상은 대화를 만들 때 정하고 바꾸지 않는다. `POST /api/v2/conversations`에 `target: { kind: "taskforce" } | { kind: "agent", connection_id, session_id? }`를 더한다(`connection_id` = `agent_connections.id`). 같은 `id`로 다른 target이 오면 409 `target_mismatch`(`apiErrorV2CodeSchema`에 추가). PATCH 스키마(`updateConversationRequestSchema`, `context_id`만)는 그대로라 target을 바꾸는 경로가 없다(검토 F16).
- 앱에서 대상을 바꾸면 새 대화를 만들고 칩을 옮긴다(디자인 시스템 "Prompt box").
- `coordinator_on_user_message` 트리거(`coordinator_core.sql:467`)는 `target_kind='agent'` 대화의 메시지에는 사건을 만들지 않는다. 그 메시지는 3.2 경로가 처리한다(검토 F21).

### 3.2 전달 경로

사용자 메시지 1건:

1. 저장(멱등, 2.2). `coordinator_on_user_message`는 건너뛴다(3.1).
2. 대상 준비: 연결 `active`, adapter `direct_chat=supported`(4.3). 아니면 저장만 하고 `delivery.state='not_sent'` + reason. **대상 `agent` 대화에는 B2의 stale 규칙(뒤에 새 사용자 메시지가 있으면 앞 메시지를 버림)을 쓰지 않는다.** 이 판정은 SQL 함수 `conversation_post_message` 안에 있으므로(`conversations_v2.sql:104-110`) 대상이 `agent`면 건너뛰도록 함수를 대체하는 마이그레이션을 둔다. 보내지 못한 메시지는 순서대로 보류되고, 뒤에 보낸 메시지도 그 뒤에 보류된다(검토 F19).
   - **저장:** 새 열 `conversation_messages.delivery_state text null check (in ('queued','not_sent','sent','expired','cancelled'))`(대상 `agent`의 사용자 메시지만), `delivery_reason text null`, `delivery_expires_at timestamptz null`(= 저장 시각 + 24시간).
   - **자동 전달 계기:** ① bridge heartbeat가 돌아올 때(`queued`), ② 그 대화의 `agent_connections.status`가 `active`가 되거나 대상 목록의 `state`가 `ready`가 될 때, ③ 쓰기 gate · `read_only`가 열릴 때(`not_sent`). 셋 다 서버가 그 세션의 보류 메시지를 보낸 순서대로 전달 경로에 넣는다. `delivery_expires_at`이 지난 것은 넣지 않는다.
   - **만료:** 기존 실행 sweep cron(`/api/cron/execution-sweep`)이 `delivery_expires_at < now()`인 `queued` · `not_sent`를 `expired`로 바꾼다.
   - **"Send again"** = `POST /api/v2/conversations/{id}/deliver { message_ids? }`. 없으면 보류 · 만료 메시지 전부. 각 메시지를 `queued`로 되돌리고 `delivery_expires_at`을 새로 24시간 준다. 전달 단계의 intent key가 `message:<id>`라 두 번 눌러도 한 번만 전달된다.
3. 권한 등급 결정(3.7). 쓰기도 읽기 전용도 쓸 수 없으면 `not_sent`, reason `write_gate_closed`.
4. Action 결정(3.3) → 실행 결정(3.4).
5. 전달은 bridge 명령으로 간다. bridge가 끊겨 있으면 명령은 lease 없이 대기하고 `delivery.state='queued'`. 같은 세션의 메시지는 **보낸 순서대로** 대기열에 쌓이고, bridge가 돌아오면 그 순서로 전달된다. 대기 중인 메시지는 사용자가 지울 수 있다(전달 전만). 작업이 `unreachable`이면 reconcile이 끝날 때까지 대기한다(검토 F19).
   - **보관 기한 24시간**(bridge outbox TTL과 같은 값, arch 9.1 기본값표). 보류(`not_sent`) · 대기(`queued`) 메시지는 보낸 지 24시간 안에만 자동으로 전달한다. 넘으면 `delivery.state='expired'`로 바꾸고 자동 전달하지 않는다: 하루 뒤의 지시는 그 사이 바뀐 상황과 어긋날 수 있다. 글은 대화에 남고(대화 글 보관 기한은 그대로), "Send again"을 누르면 그때 다시 전달 경로에 들어간다. 만료된 메시지 뒤에 쌓인 메시지는 앞 메시지를 기다리지 않는다.
6. 에이전트의 글 · 사건은 3.5대로 대화에 남는다.

### 3.3 Action 결정 — "일을 맡기면 이슈가 생긴다" (U6)

한 세션이 이슈 여러 개를 맡을 수 있다(U9). 턴마다 Action을 이 순서로 정한다.

| 경우 | Action |
|---|---|
| added 칩 중 `action`이 하나 | 그 Action. 세션이 이미 다른 이슈를 맡고 있어도 묻지 않는다 |
| added 칩 중 `action`이 둘 이상 | 전달 0, `needs_referent` + 후보 ≤ 3. 사용자가 고르면 `POST /api/v2/conversations/{id}/messages/{message_id}/referent { action_id }`로 정하고 **같은 메시지를 그대로 전달한다**(다시 보내지 않는다, 검토 F21) |
| added 칩에 `action`이 없고 세션에 앞 턴이 있다 (auto 칩은 세지 않는다) | 세션의 **현재 이슈** = 직전 턴의 Action |
| added 칩에 `action`이 없고 첫 턴이다 | **새 Action**(아래) |

새 Action:

- 제목 = **사용자 메시지의 첫 줄을 그대로**(공백 정리, 80자에서 자름). origin `user` Claim이다. 사용자가 쓴 글자 그대로이므로 출처가 맞다(원칙 2 · 5, 검토 F12). 모델이 다듬은 제목은 쓰지 않는다. 사용자가 고치면 그것도 user Claim.
- 근거 = 메시지 원문을 `note`로(채택 경로 `proposal.ts` `adoptPlan`과 같은 모양).
- 범위 = added 칩 중 `context`가 하나면 그 프로젝트의 멤버(origin `user`), 아니면 Ungrouped.
- 기록 = `action_events.type='user_created'`, `rule='assistant_agent'`, `source_id` 없음. 지표 4는 원문이 붙은 `user_created`만 "추출 누락"으로 세므로(`compute.ts:11,28`) 섞이지 않는다(검토 F7).
- 멱등 = Action · note id를 **사용자 메시지 id에서 결정적으로** 만든다(같은 메시지의 재시도 · lease 만료 재실행에도 하나, 검토 F17).
- CLAUDE.md 원칙 1의 직접 추가 입구 목록에 "Assistant(에이전트 대상)"를 더해야 한다(9장).

대상이 `taskforce`인 대화는 바뀌지 않는다: 상담 · 조회만으로 Action을 만들지 않는다. 제안 → 채택일 때만.

### 3.4 대화 턴 ≠ 작업 완료 (검토 F11 · F20)

에이전트 직접 대화는 **세션 × 이슈마다 열린 run 하나**로 묶는다. 메시지마다 run을 만들지 않는다. 한 세션이 이슈 셋을 맡으면 run도 셋이고, 셋은 같은 에이전트 세션(같은 `external_session_id`)을 쓴다.

| 개념 | 정의 |
|---|---|
| run | 그 세션에서 그 이슈의 첫 턴 때 `create_run(goal='agent')` 한 번. 새 열 `execution_runs.kind text not null default 'task' check (kind in ('task','conversation'))`, `execution_runs.agent_session_id uuid null`. **부분 unique 인덱스 `(agent_session_id, action_id) where kind='conversation' and state not in ('done','failed','stopped')`**(열 이름은 `state`, `execution_core.sql:124`)로 세션 × 이슈마다 열린 대화 run은 하나다(동시 요청 둘이 와도 둘째는 unique 위반 → 첫째 run을 다시 읽어 쓴다). `create_run`에는 intent key 인자가 없으므로(intent는 단계 단위, `execution_core.sql:234`) 이 인덱스가 run 하나를 보장한다(검토 N1) |
| 세션의 이슈 | 따로 표를 두지 않는다. 세션의 이슈 = 그 `agent_session_id`를 가진 run들의 Action. 세션의 현재 이슈 = 직전 턴의 run의 Action. 런타임 계약 5장 `agent_sessions.bound_action_id`는 "처음 맡긴 이슈" 기록으로만 남긴다 |
| 턴 | 사용자 메시지 1건의 전달과 그에 대한 에이전트의 응답 묶음. 에이전트 세션은 한 번에 한 턴만 돈다(세션 단위 직렬). 턴을 시작할 때 `agent_sessions` 행을 `for update`로 잡고, 그 세션에 진행 중인 턴(dispatched · accepted · running · awaiting_answer인 작업)이 있으면 새 턴은 대기열(3.2-5)로 간다. 없으면 `agent_sessions.last_turn_seq`(새 열)를 1 올려 그 턴의 `agent_tasks.turn_seq`에 적는다. 같은 세션에 붙은 대화 둘이 동시에 보내도 이 잠금이 순서를 정한다. 그 턴의 `agent_message` 단계 intent key = `message:<message_id>` |
| 턴의 끝 | 에이전트 CLI의 턴 종료(`result` · `turn/completed`)는 **`completed`가 아니다.** `agent_tasks.state`에 새 값 `idle`(다음 사용자 메시지를 기다림)로 간다. 검토 · check 단계를 붙이지 않는다 |
| `idle` 규칙 | 프로세스가 없어도 된다(`-p`는 턴마다 뜨고 끝난다). heartbeat의 `process_alive=false`는 `idle` 작업을 `unreachable`로 바꾸지 않는다. 다음 메시지는 `resume`으로 같은 세션을 잇는다(capability `resume='supported'`가 `direct_chat` 조건, 4.3). 사용자당 "살아 있는 외부 작업" 한도(런타임 계약 4장)에 **세지 않는다.** `agentTaskStateSchema`와 Swift 디코딩에 `idle`을 더한다(검토 N8) |
| 결과 준비 → Review | `pending_decisions`는 계산값이므로 원천을 run에 둔다: 새 열 `execution_runs.reviewed_turn_seq int not null default 0`(마지막 검토가 본 턴). 계산 입력 `result_ready` = 대화 run 중 작업이 `idle`이고, `turn_seq > reviewed_turn_seq`이며 superseded가 아닌 산출물이 하나 이상 있는 것. 항목 id `result_ready:<run_id>`라 세션 × 이슈(= run)마다 하나로 합쳐지고, 턴이 더 지나면 같은 항목의 "마지막 변경"만 바뀐다. 산출물 없는 턴은 항목을 만들지 않는다(원칙 3). 검토가 끝나면 `reviewed_turn_seq`를 검토한 마지막 턴으로 올려 항목이 사라진다 (U8) |
| Dock의 Review | Review는 두 칸이다: 위 **Needs you**(결정 · `result_ready` · `path_conflict`), 아래 **Since …**(돌아왔을 때 요약, C3 `/api/v2/return-summary` 그대로; 해야 할 일은 빼고 알아 둘 변화만). Dock의 Review 항목은 Needs you가 있으면 노란 타일, 읽지 않은 변화만 있으면 조용한 타일, 둘 다 없으면 사라진다. 눌러서 Review 목록을 연다. ⌥Space는 가장 최근 결정을 바로 연다. 요약은 Projects 목록 위에 두지 않는다(D-12 변경, 2026-10-13, 디자인 시스템 v34) |
| 작업 완료 | Review의 `result_ready` 항목에서 사용자가 "Review result"를 고를 때만 생긴다. 이슈 Done은 검토를 시작하지 **않는다**: 런타임 계약 11장대로 `action_closed` → 그 이슈의 대화 run `stopped`(검토 N2). 에이전트 세션은 이슈들이 함께 쓰므로 **그 이슈의 턴이 지금 돌고 있을 때만** `agent_cancel`을 보낸다. 그 이슈 작업이 `idle`이면 cancel을 보내지 않는다(다른 이슈의 진행 중 턴을 끊지 않기 위해). 같은 세션의 다른 이슈 run은 그대로 |
| "Review result" | 시트 하나: Taskforce가 대화에서 뽑은 완료 기준 후보(T5 제안, ≤ 5줄)를 사용자가 고치고 확인한다. 확인한 기준이 `acceptance`가 되고(런타임 계약 6장 "검토 기준은 수행 전에"를 대화 모드에서는 이 시점에 정한다), 검토 대상은 **그 run의 산출물 중 superseded가 아닌 것, 경로마다 가장 늦은 `turn_seq`의 것**이다. 그 뒤 `completed`(result_revision n) → 검토 · check 한 번. 비용 상한은 그대로. "Later"를 고르면 항목은 남는다(검토 N6) |
| 질문에 대한 답 | `pending_question.kind='input'`일 때 오는 사용자 메시지만 그 질문의 답이다(intent key = question id). **승인 질문(`kind='approval'`)은 자유 글로 답하지 않는다**: 정책 평가기와 Review(Allow · Deny)에서만 처리하고, 그동안 오는 메시지는 대기열에 쌓인다(검토 N3) |
| 지시 버전 | 직접 대화에서는 `directive_version`을 **올리지 않는다.** 결과의 귀속은 `turn_seq`로 한다: 사건 봉투에 `turn_seq?: number`, `execution_artifacts`에 `turn_seq int null`을 더한다. 승인 hash는 `(bundle_hash, turn_seq)`를 포함한다(I03 원리 유지) |
| 검토 중 새 메시지 | 검토가 끝날 때까지 메시지는 대기열(3.2-5)에 쌓인다. 검토 결과 `fail`이면 수정 요청이 먼저 가고 대기 메시지가 뒤따른다 |
| Stop 뒤 | 그 세션의 열린 대화 run은 모두 `stopped`로 끝나고 세션은 남는다. 다음 메시지는 3.3대로 정한 이슈에 **새 대화 run**을 만든다(부분 unique 인덱스는 열린 run만 보므로 충돌 없음). 세션의 `turn_seq`는 이어서 센다(검토 N4) |

Taskforce가 맡긴 작업(대상 `taskforce`에서 위임 → `goal='agent'`, `kind='task'`)은 런타임 계약 5장 그대로다: 끝 사건 = `completed` → 검토, 수정은 `directive_version`.

### 3.5 에이전트의 글을 대화에 쓰기 (검토 F5)

`conversation_finish_turn`은 메시지 하나에 답 하나(`reply_to` unique)이고 뒤에 새 사용자 메시지가 있으면 stale로 버린다. 에이전트의 글은 비동기 · 여러 번이라 이 함수를 쓰지 않는다.

- 새 서버 함수 `conversation_append_agent_message(p_conversation_id, p_agent_task_id, p_turn_seq, p_event_id, p_text, p_kind in ('reply','question','event'))`:
  - 대화를 잠그고 다음 `seq`를 준다. `role='assistant'`(reply · question) 또는 `'event'`, `reply_to = null`.
  - `content.author = { kind: "agent", adapter }`(새 필드), `content.turn_seq`.
  - 멱등: 새 열 `conversation_messages.external_event_id text null` + `unique (conversation_id, external_event_id) where external_event_id is not null`. `content`는 글 보관 기한에 비워지므로 열쇠를 거기 두지 않는다(검토 N7).
  - 글 보관 기한 · 삭제 전파는 다른 메시지와 같다(text · content만 비우고 `external_event_id`는 남긴다).
  - **어느 대화에 쓰나:** 에이전트의 글(reply · question)은 그 턴을 시작한 사용자 메시지의 대화에만 쓴다(`agent_tasks`가 턴의 `message_id`를 든다). 세션 단위의 사건(중단 확인 · 연결 끊김 · 결과 검토)은 그 세션에 묶인 모든 대화에 `event` 한 줄씩 쓴다(검토 N9).
- Taskforce가 한 일(이슈 생성, 승인 라우팅, 중단 확인, 검토 결과)은 `role='event'` 한 줄.

### 3.6 질문 · 승인

- 승인 콜백(`question.kind='approval'`)은 **지금과 같은 정책 평가기**가 처리한다. 직접 대화라고 승인을 건너뛰지 않는다.
- 입력 질문(`question.kind='input'`)은 원천을 `agent_tasks.pending_question` 하나로 둔다. 대화에는 3.5로 보이고, Review 목록은 계산 입력(`FutureInputs.agentQuestions`)을 이 열에 연결해 계산한다. 어느 쪽에서 답해도 같은 question id의 단계 하나로 전달되고, `pending_question`이 비면 두 곳에서 함께 사라진다(검토 F2).
- 대상 `agent` 대화에서는 Taskforce가 입력 질문에 조용히 답하지 않는다(사용자가 상대다). 대상 `taskforce`에서 맡긴 작업의 질문은 런타임 계약 6장대로 Taskforce가 먼저 답을 시도한다.

### 3.7 권한 등급 (검토 F13)

한 메시지가 쓰기를 일으킬 수 있으므로, 전달 전에 등급을 정한다.

| 조건 | 등급 | 전달 |
|---|---|---|
| 이 연결 · 정책의 쓰기 gate가 모두 `verified`(런타임 계약 5장 표) | write | 사용자 정책(Manual/Auto/Full)대로 |
| 쓰기 gate가 닫혔고 `enforcement.read_only`(새 Boundary)가 `verified` | read_only | adapter의 읽기 전용 통로로만 띄운다. 화면에 "Read only"를 보인다 |
| 둘 다 아님 | — | `not_sent`, `write_gate_closed` |

### 3.8 세션

- 첫 전달 때 `agent_sessions`를 만들거나(새 대화) 기존 것에 붙는다(`target.session_id`, 같은 연결이어야 함). `bound_action_id` = 첫 턴의 Action(기록용, 3.4).
- **세션 이름** = 첫 메시지의 첫 줄(3.3 제목과 같은 값으로 시작). 사용자가 바꾼다: `PATCH /api/v2/agent-sessions/{id} { display_name }`. 이슈 상세 Sessions · 세션 패널 헤더가 이 값을 쓴다. 헤더의 이슈 번호는 세션의 현재 이슈다("Pricing copy draft — #139").
- **한 세션이 이슈 여러 개를 맡는다(U9).** 다른 이슈를 added 칩으로 붙여 보내면 묻지 않고 그 이슈의 run을 이 세션에 연다(3.3). 이 세션은 그 이슈들 각각의 상세 Sessions 목록에 나온다. auto 칩이 바뀌는 것은 이슈를 바꾸는 계기가 아니다(원칙 3, 검토 F15).

### 3.9 같은 파일 — 먼저 건드린 쪽이 계속한다 (사용자, 2026-10-13)

같은 작업 폴더에서 두 작업(같은 세션의 두 이슈, 또는 다른 세션)이 같은 파일을 고치려 하면 **먼저 그 파일을 건드린 작업이 계속하고 다른 쪽이 양보한다.**

- 경로 lease: 새 표 `agent_path_leases(user_id, workspace_ref, path, run_id, acquired_at, released_at)`, `unique (user_id, workspace_ref, path) where released_at is null`. 작업이 처음 그 경로에 쓰기를 승인받을 때(승인 콜백의 `target` 경로) 잡는다. 시간 순서 = lease를 잡은 순서(DB unique가 정한다).
- 양보: 다른 run의 같은 경로 쓰기 승인 요청은 정책 평가기가 거절하고(이유 `path_in_use:<run_id>`), 그 작업에 "이 파일은 #139 작업이 쓰고 있다. 다른 일을 먼저 하거나 기다려라"를 `agent_message`로 보낸다. 사용자에게는 묻지 않는다(원칙 3). 세션 패널 · 대화에 `event` 한 줄("Waiting for #139 · pricing.mdx")만 남긴다.
- 해제: 그 run이 `stopped` · `done` · `failed`가 되면 바로 풀린다. `idle`이 된 뒤 **30분** 동안 같은 run이 다음 턴을 시작하지 않아도 풀린다(새 열 `expires_at` = 턴 끝 + 30분, 다음 턴이 시작되면 lease를 그대로 이어 `expires_at`을 비운다). 그래서 "먼저 건드린 쪽이 계속"은 이어지는 턴들에만 적용되고, 사용자의 검토(Later) 같은 행동에 다른 작업이 무기한 묶이지 않는다. 기본값 30분은 런타임 계약 12장 기본값표에 더한다. 풀리면 기다린 작업에 `agent_message`로 알린다. 만료 처리는 기존 실행 sweep cron(`/api/cron/execution-sweep`)이 한다.
- 막을 수 있는 경우만: 이 규칙은 쓰기 전에 경로가 보이는 승인 통로(`approval_gate`)가 `verified`인 adapter에서만 강제된다. 경로를 쓰기 뒤에야 아는 adapter는 산출물 사건에서 충돌을 발견하면 늦게 쓴 쪽 작업에 `Stop new steps`를 걸고, 원천 행으로 `agent_path_leases`에 `conflict_run_id uuid null` · `conflict_at timestamptz null`을 적는다. Review 계산 입력 `path_conflict:<lease_id>`가 이 열에서 나온다(`pending_decisions`는 계산값). 사용자가 어느 쪽을 남길지 고르면 두 열을 비운다.
- 같은 세션의 두 이슈는 턴이 직렬이라(3.4) 동시에 쓰지 않지만, 한 이슈의 산출물이 아직 검토 전인 파일을 다른 이슈 턴이 고치려 하면 위 규칙대로 양보한다.

## 4. 에이전트 연결 — 계속 더할 수 있게 (U4)

### 4.1 원칙

- adapter id는 **문자열 + 서버 registry**(`agent:<이름>`)다. 런타임 계약 V10을 이것으로 닫는다.
- 새 에이전트 = registry 항목 하나 + bridge 쪽 adapter 구현 하나. **연결 표를 처음 한 번 넓힌 뒤에는**(4.2) 계약 · 마이그레이션 변경이 없다.
- 앱은 registry가 준 것만 그린다: 이름(평문), 상태, 가능한 동작. 로고 없음.

### 4.2 연결 표 — 별도 표 (1회 마이그레이션, 검토 F6 · N5)

`connections`를 넓히지 **않는다.** `connections.provider` CHECK(`('notion','google','gmail','slack','github')`, `20261003000000_go_live_connections_consent.sql:7`)를 넓히면 v1 연결 목록(`connectionSummarySchema.provider` enum, `contract.ts:384`)과 Swift 디코딩이 모르는 값을 받고, provider로 거르지 않는 연결 순회(`connectors/store.ts:198`의 토큰 로드 · 동기화)에 에이전트 행이 섞인다. 배포된 앱이 깨진다(V11).

- 새 표 `agent_connections(id, user_id, adapter text, bridge_id uuid, device_ref text, status in ('active','error','revoked'), created_at, updated_at)`. `user_id` + RLS + `(id, user_id)` 복합 외래키 패턴(CLAUDE.md DB 규칙). RLS는 `owner_all`이 아니라 **`owner_select`만** 둔다(`connections`와 같음): `adapter` · `status`는 registry와 bridge 보고로 서버만 쓴다(검토 3차 N5). `adapter`는 registry 문자열이다. `device_ref` = bridge가 보고한 기기 · adapter의 해시.
- 로그인 계정 · 이메일 · 토큰은 담지 않는다(I16). 비밀값 표를 쓰지 않는다(local_bridge adapter의 비밀값은 Mac에만). `remote_api` adapter가 생기면 그때 비밀값 표를 정한다.
- `agent_sessions.connection_id`(런타임 계약 5장)는 이 표를 가리킨다. `conversations.agent_connection_id`도 이 표다.
- Settings › Connections › Your agents는 이 표를 읽는다. 기존 Sources 목록 · 동기화 경로는 바뀌지 않는다.

### 4.3 서술자에 더하는 것

```ts
type AgentCapability = /* 런타임 계약 5장 그대로 */ & {
  display_name: string;                              // "Claude Code", "Codex"
  sign_in: "user_terminal" | "user_app" | "token";   // 표시용. Taskforce는 로그인을 대행하지 않는다(I16)
  enforcement: /* 5장 그대로 */ & { read_only: Boundary };   // 3.7
};
// 파생: direct_chat
```

`direct_chat = supported` 조건: `session.create` ∧ `resume = "supported"`(턴 사이 `idle`을 잇는다, 3.4) ∧ `events != "none"` ∧ `question.receive` ∧ **`cancel != "unsupported"`**(U7 Stop) ∧ (쓰기 gate 또는 `read_only` 중 하나 `verified`). 서버가 계산한다(검토 F21 · N8).

**`verified`의 출처:** 서버 registry만 정한다(D0식 통제 테스트 증거와 함께). bridge가 등록 때 보내는 `capabilities`(`bridgeRegisterRequestSchema`)는 "이 Mac에 설치돼 있고 이 버전이다"만 뜻한다. 실제 값 = registry 값과 bridge 보고의 **더 좁은 쪽**(검토 F21).

### 4.4 0.2.0 registry (U10)

| adapter | display_name | transport | 상태 |
|---|---|---|---|
| `agent:claude-code` | Claude Code | local_bridge | 첫 에이전트(결정). arch 8.2. 값은 D0 V06 실측 뒤 `verified` |
| `agent:codex` | Codex | local_bridge | 두 번째 구현. arch 8.2 |

0.2.0은 이 둘만 등록한다. Cursor 등 다음 에이전트는 공식 통로(세션 · 사건 · 질문 · 중단 · 읽기 전용)를 조사한 뒤 같은 방식으로 항목을 더한다(4.1). 등록하지 않은 에이전트는 대상 목록에 나오지 않는다.

### 4.5 대상 목록

`GET /api/v2/assistant/targets`:

```ts
{ targets: Array<
    | { kind: "taskforce" }
    | { kind: "agent", adapter: string, display_name: string, connection_id: string | null,
        state: "ready" | "not_connected" | "sign_in_needed" | "unreachable" | "unsupported",
        access: "write" | "read_only" | null }      // 3.7 등급. 앱은 대상 이름 옆에 보일 수 있다
  > }
```

registry에 있고 연결이 없으면 `not_connected`(예: Codex를 아직 연결하지 않음). `sign_in_needed`는 bridge 사전 점검(arch 8.2 spawn (a))에서 온다.

## 5. 중단 (U7, 검토 F14)

- 보내기 ↔ Stop 전환 = **이 대화에 묶인 세션**에 열린 `agent_tasks`(dispatched · accepted · running · awaiting_answer)가 있는가. `idle`은 열린 작업이 아니다(Stop 대신 보내기).
- `POST /api/v2/conversations/{id}/stop` = **세션 단위 중단**: 그 세션의 진행 중인 턴(하나)에 `cancel_agent_task`, 그 세션의 열린 대화 run 전부에 `stop_run`. 어느 대화가 시작했는지는 따지지 않는다(같은 세션에 붙은 두 번째 대화에서도 같은 효과). 세션 패널은 `POST /api/v2/agent-sessions/{id}/stop`(같은 동작). 이슈 하나만 멈추는 것은 그 이슈의 Done(3.4) 또는 이슈 우클릭이다.
- 응답 = `{ tasks: [{ agent_task_id, cancel: "requested_only" | "confirmed" }] }`. 앱은 하나라도 `requested_only`면 "Stop requested · not confirmed".
- 대기열(3.2-5)의 아직 전달하지 않은 메시지는 Stop 때 함께 취소하고 `event` 줄로 남긴다.

## 6. 프로젝트 관리 (U5)

| route | 내용 |
|---|---|
| `POST /api/v2/contexts` | `{ name, kind: "project", icon? }`(`createWorkContextRequestSchema`에 icon 추가). icon이 없으면 서버가 풀에서 무작위 |
| `PATCH /api/v2/contexts/{id}` | `{ name?, icon?, status?: "active" \| "archived", expected_version }` |

- 마이그레이션: `work_contexts.icon text not null default 'compass' check (icon in (<풀 12개>))`, **`work_contexts.version int not null default 1`**(이름 · 아이콘 · 상태를 바꿀 때마다 +1). `context_version`은 멤버십 · 기억 · 원문 revision에만 오르므로(`context_layer.sql:15`) 이 수정의 충돌 검사에 쓸 수 없다. version이 다르면 409(검토 F9).
- 보관은 `context_version`도 1 올린다(묶음 stale 판정이 보관된 범위를 다시 보게).
- 풀: rocket · briefcase · flask-conical · palette · code-xml · megaphone · book-open · building-2 · leaf · compass · target · users.
- 보관한 프로젝트의 열린 이슈는 Ungrouped에 보인다(화면 계산). 실행 · 권한 변화 0(I14, ARCH07).
- 자동 생성 없음: `createContext`는 이 route에서만 부른다. arch 5.4 · 5.7의 자동 생성 경로는 닫힌다(9장).

### 6.1 이슈를 프로젝트에 넣기 (U11)

사용자가 한다. 자동 배치(auto · inferred 멤버십)는 0.2.0에서 만들지 않는다.

| 입구 | 경로 |
|---|---|
| 이슈 우클릭 → Move to project ▸ 프로젝트 | 기존 S3b route `POST /api/v2/contexts/{id}/members`(add) · `members/move`(옮기기), origin `user`, Undo는 응답의 `change`(그대로) |
| Taskforce에게 말로("#139 Taskforce 0.2.0으로 옮겨줘") | 대상 `taskforce` 대화의 새 의도 `organize`(Jev choice에 kind 추가). 대상 이슈 · 프로젝트를 지시 대상 규칙(added 칩 → 글의 분명한 지칭 → 묻기)으로 정한 뒤, **사용자의 명시 지시이므로 제안 없이 바로** 같은 S3b route로 쓴다(origin `user`). 답에 `event` 줄 "Moved #139 to Taskforce 0.2.0"과 Undo. 이슈 · 프로젝트가 정해지지 않으면 묻고 쓰지 않는다 |

여러 이슈를 한 번에 옮기는 말("Shape 관련 다 옮겨줘")은 후보 목록을 보이고 확인 뒤 쓴다(대상이 명시되지 않은 쓰기이므로).

`organize`는 **이슈 삭제 · 병합**도 한다(사용자, 2026-10-13).

| 말 | 동작 | 확인 |
|---|---|---|
| "#141 지워줘" | 기존 삭제 경로(`DELETE /api/v1/actions/:id`), `action_events user_deleted`(오판 신호, 원칙 6). 열린 대화 run은 Done과 같은 규칙으로 멈춘다(3.4) | **항상 한 번 확인 카드**(제목 · 프로젝트 · 열린 세션 수, Delete · Cancel) |
| "#144를 #139에 합쳐줘" | **병합 = 사라지는 쪽을 닫고 남는 쪽에 잇는다.** 남는 쪽 = 뒤에 말한 이슈. 사라지는 쪽(#144)은 삭제와 같은 경로로 닫는다: user Claim `status='dropped'`(`applyUserChanges`, `src/lib/actions/service.ts:97`) — 다만 이벤트는 `user_deleted` 대신 새 사용자 이벤트 `action_events user_merged`(actor user, `after: { into: <남는 쪽 id> }`). **Claim · 근거 · run은 옮기지 않는다**: Claim은 지우거나 다른 Action으로 옮기지 않는다는 원칙 5와 "실행은 Action에 묶인다"(외부 단계 intent key가 `action_id`를 포함, `execution_core.sql:509`)를 지키기 위해서다. #144의 열린 대화 run은 Done과 같은 규칙으로 멈춘다. 남는 쪽 상세의 Source "Show all"과 Sessions는 `user_merged`로 이어진 이슈의 근거 · 세션을 "From #144"로 함께 보인다(읽기만). 남는 쪽의 값은 바뀌지 않는다(바꾸려면 사용자가 고친다 → user Claim) | **항상 한 번 확인 카드**(두 제목, 남는 쪽, 함께 보일 근거 · 세션 수) |
| 이동 · 프로젝트에서 빼기 | 위 표 | 대상이 하나로 정해지면 확인 없음, Undo |

- **확인 카드 = 제안(proposal)**: proposal kind에 `delete` · `merge`를 더하고 `content.asks`에 `confirm`을 더한다(`contract.ts:795`의 enum). `payload_hash` = (대상 Action id들, 각 Action의 `updated_at`)의 hash. 채택은 proposal id로 멱등이라(기존 A41) 두 번 눌러도 한 번 쓴다. 대상이 그 사이 바뀌었으면(hash 불일치) 409 `superseded`로 쓰지 않고 새 카드를 낸다.
- **Undo**: 삭제는 실제로 지우지 않는다(`DELETE /api/v1/actions/:id` = user Claim `status='dropped'`, `src/app/api/v1/actions/[id]/route.ts:6`). 삭제 Undo · 병합 Undo 모두 user Claim으로 `status='open'`을 다시 적는다(`PATCH /api/v1/actions/:id`, 이벤트 `user_edited`; 병합 Undo는 `before.into`를 남김). Claim을 지우지 않으므로 원칙 5와 맞고, 옮긴 것이 없어 되돌릴 Claim 이동도 없다.
- **이벤트(원칙 4 · 6)**: `user_merged`는 "추출이 중복을 만들었다"는 오판 신호로 지표 1에서 센다(사용자 수정과 같은 줄). `coordinator_on_action_decision` 트리거(`coordinator_core.sql:509`)가 `user_merged`를 받도록 더한다(9장).
- 확인 카드는 Assistant 입력창 위 질문 카드(디자인 시스템 Assistant window)와 같은 자리다.

## 7. 이슈 번호

화면은 이슈를 "#139"로 부른다. `actions`에는 사람이 읽는 번호가 없다(`20260925000000_init.sql`).

- `actions.number int` + `unique (user_id, number)`. 사용자별 카운터 `action_counters(user_id pk, next int)`를 `for update`로 잡고 insert 트리거에서 준다.
- `action_counters`는 **앱 역할에서 select · insert · update · delete를 모두 revoke**한다(`context_version_bumps`와 같은 처리). 앱이 카운터를 되돌리면 unique 위반으로 모든 생성이 막히기 때문이다(검토 F21).
- 기존 행은 `created_at` 순으로 채운다. 번호는 재사용하지 않는다.

## 8. 측정 이벤트 (원칙 6, 검토 F8)

- `metric_events`에 `props jsonb not null default '{}'`(차원: kind · origin · target_kind · adapter)를 더하고 `type` CHECK를 넓힌다.
- 앱 insert 정책(`20261001000000_metric_events_client_app_opened.sql`)은 `type in ('app_opened','assistant_opened')`로만 넓힌다. 나머지는 서버가 service role로 쓴다.

| type | 누가 | 언제 | props |
|---|---|---|---|
| `assistant_opened` | 앱 | Assistant 창을 열 때 | target_kind |
| `context_attached` | 서버 | 메시지 저장 시 칩마다 | kind · origin · sent(외부로 보냈는가) |
| `agent_message_sent` | 서버 | 대상 `agent` 전달 시 | adapter · access |
| `stop_requested` | 서버 | 5장 | surface(assistant · session_panel) |
| `project_created` · `project_renamed` · `project_archived` · `project_icon_changed` | 서버 | 6장 | — |
| `issue_moved` | 서버 | 6.1 이동 · 빼기 | via(menu · talk) · from_context · to_context |

Action 생성(3.3)은 `action_events` `user_created`(`rule='assistant_agent'`)로 남는다.

## 9. 같이 고칠 문서

- CLAUDE.md 원칙 1: 직접 추가 입구에 "Assistant에서 에이전트에게 일을 맡길 때"를 더한다(3.3).
- 런타임 계약 2장(대화: target · attachments · `selected`, proposal kind `delete` · `merge`, asks `confirm`), 5장(`execution_runs.kind='conversation'`, `idle`, `turn_seq`, `read_only` Boundary, registry 문자열, 질문 원천, **`agent_sessions.bound_action_id`는 binding이 아니라 "처음 맡긴 이슈" 기록**, 세션 단위 직렬 · `for update`), 6장(직접 대화의 입력 질문, 계산 입력 `result_ready` · `path_conflict`), 12장 기본값표(대기 메시지 24시간, 경로 lease 30분), 14장 V10 닫음.
- 마이그레이션이 필요한 기존 함수: `conversation_post_message`의 stale 판정(`conversations_v2.sql:104-110`)을 대상 `agent` 대화에서 건너뛰도록 대체한다(3.2-2). `coordinator_on_user_message`는 대상 `agent` 대화를 건너뛴다(3.1). `coordinator_on_action_decision`은 `user_merged`를 받는다(6.1).
- 코드의 이벤트 종류: `UserEventType`(`src/lib/actions/project.ts:64`)과 `action_events.type` CHECK에 `user_merged`.
- arch 5.4 · 5.7(자동 생성 경로 제거), 5.6(대화 target), 8장(registry 원칙, verified 출처), 12.1 D-1(범위 헤더 → 칩).
- 디자인 시스템 README "Assistant window": 에이전트 대화의 auto 칩 "Not sent", "Read only" 표시, 대기 · 만료 메시지 표시. Rail: Review 항목은 Review 목록이 있을 때만(3.4). Behaviors: 이슈 우클릭 Move to project(6.1).
- 런타임 계약 2장 의도 분류에 `organize`(6.1).

## 10. 검증 기준

| id | 기준 | 방법 |
|---|---|---|
| AC-1 | 남의 id를 칩으로 보내면 404, 쓰기 0 | 단위 + DB(RLS) |
| AC-2 | 같은 client_message_id에 attachments만 다르면 409 `refs_mismatch`, 같으면 저장 · 전달 한 번 | DB(PGlite) |
| AC-3 | 대상 `agent` + added action 칩 없음 → Action 1 + user Claim(제목 = 첫 줄 그대로) + note + `user_created/assistant_agent`. lease 만료 재실행 · 동시 첫 메시지 둘에도 Action · 세션 · run 하나 | 실제 Postgres 경합 |
| AC-4 | added action 칩 둘 → 전달 0, `needs_referent`. referent 확정 뒤 같은 메시지가 한 번 전달 | DB |
| AC-5 | 같은 id로 다른 target의 대화 만들기 → 409 `target_mismatch` | 단위 |
| AC-6 | 에이전트 대상에서 auto 칩 내용은 묶음에 들어가지 않는다 | 단위 |
| AC-7 | 에이전트 턴 종료 → `idle`, 검토 단계 0. Review의 `result_ready`에서 "Review result" 뒤에만 검토 한 번 | DB |
| AC-8 | `awaiting_answer` 중 메시지 = 답, `directive_version` 변화 0, 대화 · Review 양쪽에서 사라짐 | DB + 단위 |
| AC-9 | 승인 콜백은 직접 대화에서도 정책 평가기를 거친다(Manual이면 Review로, 자동 허락 0) | 단위 |
| AC-10 | 쓰기 gate 닫힘 + read_only 미검증 → `not_sent/write_gate_closed`, 프로세스 spawn 0 | 단위 |
| AC-11 | bridge 끊김 중 보낸 메시지 셋이 재접속 후 보낸 순서대로 한 번씩 전달 | DB + bridge 모의 |
| AC-12 | 두 번째 대화에서 Stop → 같은 세션 작업 전부 cancel 요청, 응답에 작업별 결과 | DB |
| AC-13 | 새 adapter 추가 = registry 항목 + bridge adapter만(4.2 이후 마이그레이션 0) | 리뷰 |
| AC-14 | 프로젝트 이름 · 아이콘 동시 수정 → 뒤 요청 409, 보관은 실행 결과 · 정책 평가 변화 0 | DB |
| AC-15 | `action_counters`에 앱 역할 접근 0, 동시 생성에도 번호 중복 0 | 실제 Postgres |
| AC-16 | 에이전트 글 사건 재전송 → 대화 메시지 하나. 글 보관 기한으로 content가 비워진 뒤 재전송돼도 하나 | DB |
| AC-17 | 승인 질문 대기 중 자유 글 → 승인 답으로 전달 0, 대기열에 보관 | 단위 |
| AC-18 | 이슈 Done → 그 이슈의 대화 run `stopped` + cancel 요청, 같은 세션의 다른 이슈 run 그대로, 검토 단계 0 | DB |
| AC-19 | Stop 뒤 다음 메시지 → 새 대화 run 하나, 같은 세션, turn_seq 이어짐 | DB |
| AC-20 | v1 연결 목록 · 동기화 순회에 에이전트 연결 0(`agent_connections`는 별도 표) | 단위 + DB |
| AC-21 | `idle` 작업은 heartbeat 누락으로 `unreachable`이 되지 않고 외부 작업 한도에 세지 않는다 | 단위 |
| AC-22 | 보내지 못한 메시지 둘 뒤 "Send again" → 보낸 순서대로 둘 다 한 번씩 전달 | DB |
| AC-23 | 한 세션에서 이슈 A 턴 → 이슈 B 칩으로 턴 → 열린 대화 run 둘(A · B), 같은 에이전트 세션, turn_seq 1 · 2 | DB |
| AC-24 | 같은 세션 × 이슈에 산출물 있는 턴 셋 → Review `result_ready` 항목 하나. 산출물 없는 턴 → 항목 0 | 단위(계산 목록) |
| AC-25 | Review 목록이 비면 Dock Review 항목 0 | 앱 |
| AC-26 | 24시간 넘은 보류 메시지는 재접속에 자동 전달 0, `expired`. "Send again"이면 한 번 전달 | DB |
| AC-27 | "옮겨줘" 의도: 대상이 하나로 정해지면 S3b route로 한 번 쓰고 Undo 가능, 정해지지 않으면 쓰기 0 | 단위 + DB |
| AC-28 | 두 run이 같은 경로를 요청 → 먼저 lease를 잡은 쪽만 쓰기 승인, 다른 쪽은 거절 + 알림, 해제 뒤 기다린 쪽에 알림 | 실제 Postgres 경합 |
| AC-29 | "지워줘" · "합쳐줘"는 확인 전 쓰기 0, 확인 두 번 눌러도 한 번, 대상이 바뀐 뒤 확인은 409 `superseded`, Undo로 되돌림 | DB |
| AC-30 | 병합: Claim · run 이동 0, 사라지는 쪽 `dropped` + `user_merged`, 남는 쪽 값 변화 0, 남는 쪽 상세에 "From #144" 근거 · 세션 표시 | DB + 앱 |
| AC-31 | 같은 세션의 이슈 A Done 중 이슈 B 턴이 진행 중 → B 턴 cancel 0, A run만 `stopped` | DB |
| AC-32 | 경로 lease는 `idle` 30분 뒤 자동 해제, 다음 턴이 시작되면 이어짐 | DB(sweep) |
| AC-33 | 같은 세션에 대화 둘이 동시에 보냄 → 턴 하나만 시작, 다른 하나는 대기열, `turn_seq` 중복 0 | 실제 Postgres 경합 |

## 11. 닫힌 질문 (사용자, 2026-10-13)

1. 결과 검토 입구: Review로 합침. Dock의 Review 항목은 검토할 것이 있을 때만(3.4).
2. 세션 하나에 이슈 여러 개: 허용(3.3 · 3.4 · 3.8).
3. 보내지 못한 메시지: 24시간 자동 전달, 그 뒤 만료(3.2-5). 사용자가 추천을 받기로 함 — 추천값.
4. Cursor: 0.2.0 밖. Claude Code · Codex만(4.4).
5. 이슈 → 프로젝트: 사용자가 우클릭 또는 Taskforce에게 말로(6.1). 자동 배치 없음.

6. 같은 파일 충돌: 먼저 건드린 작업이 계속, 다른 쪽이 양보(3.9). (10-13)
7. `organize`: 이슈 삭제 · 병합까지, 둘 다 확인 카드 한 번(6.1). (10-13)

8. 에이전트 · 서비스 마크(Clawd · OpenAI · Slack) 사용: 사용자가 사용 조건을 확인함. (10-13)

## 12. 남은 질문

없음. 다음 단계는 이 문서의 독립 재검토와 사용자 승인, 그 뒤 D1(0.2) 구현 계획.
