# 어시스턴트 · 맥락 칩 · 에이전트 직접 대화 — 서버 계약 (설계 v3, 2026-10-13)

상태: **설계 문서. 코드 · 마이그레이션은 아직 없다.** 구현 순서 · PR 단위 · 완료 기준은 One 적용 구현 계획(코디네이터 로컬 `.omx/plans/taskforce-one-adoption-implementation-plan-2026-10-13.md`)의 WP를 따른다.
v2 → v3(2026-10-13): 사용자 결정 U12–U17(0.1)과 실측 S0(Claude Code 2.1.241 · codex-cli 0.162.1, 증거 `~/.claude/worktrees/taskforce-020/handoffs/oa-s0-evidence/`)를 반영했다. 바뀐 곳: 2.4 delivery 계산, 3.2 `delivery_state` 전이, 3.4 답 규칙, 3.5 agent 글 경로, 3.6 질문 열쇠 · 종류 · 비밀값 · 보류, 3.8 `external` 세션, 4.3 capability 항목, 4.4 registry 초기값, 5장 중단 범위, 10장 AC-34–AC-42, 12장 남은 질문, **13장 adapter 실행 계약(새 장)**.
v1 → v2: 독립 검토(같은 날)의 F1–F21을 반영했다. 바뀐 핵심은 "대화 턴 ≠ 작업 완료"(3.4), 칩의 전송 동의(2.3), 멱등 열쇠(3.3 · 3.5), 선행 조건(0.2)이다.
3차 검토(10-13 변경분)의 지적을 반영했다: 열 이름 `state`, `kind`로 통일, `agent_connections`는 select만, stale 판정 함수 대체, 전달 상태 열 · 계기 · 만료 cron, 공유 세션에서 Done은 진행 중 턴만 cancel, 경로 lease 30분 TTL, 계산 입력의 원천 열(`reviewed_turn_seq`, `conflict_*`), **병합 재설계(Claim · run을 옮기지 않고 닫아서 잇는다)**, 확인 카드 = proposal, 세션 잠금, `issue_moved` 이벤트.
v2 재검토의 N1–N9와 부분 반영(F6 · F11 · F14 · F16 · F17 · F19 · F20)을 국소 수정으로 반영했다: 세션당 열린 대화 run 하나를 보장하는 부분 unique 인덱스, Done은 중단만, 승인 질문은 자유 글로 답하지 않음, Stop 뒤 새 run, 에이전트 연결은 별도 표, Review result 시트, 사건 열쇠는 별도 열, `idle` 규칙, 대화 둘이 붙은 세션의 글 경로.

기준 코드: origin/main `a03e9c2`(= `~/.claude/worktrees/taskforce-020/c3-server` 트리, PR #131까지 병합) — 대화 v2(B2/B3), 맥락층(B1/S3b), 실행 계약(C1), 코디네이터(C2), 복귀 요약(C3).
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
| U12 (10-13) | Mac 앱의 App Sandbox를 끈다(Developer ID DMG 배포 그대로). bridge는 앱 안에서 돈다. 샌드박스 앱이 띄운 자식 프로세스는 사용자 CLI 로그인 · 프로젝트에 닿지 못하기 때문이다 | 13.1 |
| U13 (10-13) | 0.2.0의 세션은 Taskforce가 만든 것만. 세션 패널에 Open in Terminal · View full · Resume here | 3.8 |
| U14 (10-13) | Claude Code는 턴마다 `claude -p` + Taskforce 설정 파일. 질문 = Taskforce MCP `ask_user` + 훅 `defer`, 승인 = 훅의 즉시 결정 또는 `defer`, 권한 모드 `manual` 고정(실측 S0) | 13.2 |
| U15 (10-13) | 서버에는 agent의 답 · 질문 글만 저장한다(메시지당 ≤ 32KB). 도구 출력 · diff 본문 · 비밀값 답은 저장하지 않는다 | 3.5 · 3.6 |
| U16 (10-13) | 답은 2초 보류 뒤 보낸다(Undo). 보류 중 앱 종료 = 전송 | 3.6 |
| U17 (10-13) | 최소 화면 호스트(Assistant 창 · Dock Review · Issues · 세션 패널 · Projects)를 이 계약의 구현 범위에 넣는다 | 1 |

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
  delivery: { state: "answered" | "queued" | "needs_referent" | "not_sent" | "expired" | "cancelled"   // 열 값(3.2)
                   | "sent" | "accepted" | "unknown",                                               // dispatched 뒤 계산(3.2, v3)
              reason?: "not_connected" | "sign_in_needed" | "unsupported" | "write_gate_closed"
                      | "session_external" | "version_unsupported" | "usage_limited" | "spawn_failed" | "not_received",   // 뒤 다섯 (v3, 3.2 · 13.1)
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
   - **저장:** 새 열 `conversation_messages.delivery_state text null check (in ('queued','not_sent','dispatched','expired','cancelled'))`(대상 `agent`의 사용자 메시지만), `delivery_reason text null`, `delivery_expires_at timestamptz null`(= 저장 시각 + 24시간).
   - **전이(v3):** `queued` · `not_sent` → 전달 단계의 intent를 만드는 트랜잭션에서 `dispatched`. 그 뒤 응답의 `delivery.state`는 열이 아니라 단계에서 계산한다(원천은 단계 하나): 단계 `prepared` · `calling`(bridge가 아직 접수 신호를 받지 않음) = `sent`, 단계 `called` = `accepted`, 단계 `unknown_outcome` = `unknown`. 단계를 `called`로 바꾸는 접수 신호는 adapter가 정한다(Claude Code: 그 턴 프로세스의 첫 `assistant` 사건 — `system/init`은 프로세스가 떴다는 transport 접수일 뿐이다(아키텍처 8.2), Codex: `turn/started`, 13장). 단계가 `failed`면(로그인 없음 · 사용량 한도 · 실행 실패 · 지원 버전 밖) 같은 트랜잭션에서 열을 `not_sent`로 되돌리고 reason(`sign_in_needed` · `usage_limited` · `spawn_failed` · `version_unsupported`)을 적는다. 그 메시지는 "Send again"과 자동 전달 계기의 대상이 되고, 다시 보낼 때 intent key는 `message:<id>:<n>`(n은 앞 단계가 `failed`일 때만 1 오른다. `unknown_outcome` 뒤에는 오르지 않는다). 만료 sweep은 `queued` · `not_sent`만 본다. `dispatched`는 lease된 뒤에는 만료되지 않는다. 아직 lease되지 않은 `prepared` 명령은 lease 시점에 전달 기한을 다시 확인하고, 지났으면 단계 `failed`, 작업 `failed`, 메시지 `expired`로 거둔다(OA D2a Q12). 세션이 `external`(3.8)이면 새 메시지는 `queued`, reason `session_external`.
   - **자동 전달 계기:** ① bridge heartbeat가 돌아올 때(`queued`), ② 그 대화의 `agent_connections.status`가 `active`가 되거나 대상 목록의 `state`가 `ready`가 될 때, ③ 쓰기 gate · `read_only`가 열릴 때(`not_sent`), ④ (v3) 세션의 Resume here(3.8). 넷 다 서버가 그 세션의 보류 메시지를 보낸 순서대로 전달 경로에 넣는다. `delivery_expires_at`이 지난 것은 넣지 않는다. 세션이 `external`이면 ①–③은 건너뛴다.
   - **만료:** 기존 실행 sweep cron(`/api/cron/execution-sweep`)이 `delivery_expires_at < now()`인 `queued` · `not_sent`를 `expired`로 바꾼다.
   - **"Send again"** = `POST /api/v2/conversations/{id}/deliver { message_ids? }`. 없으면 보류 · 만료 메시지 전부. 각 메시지를 `queued`로 되돌리고 `delivery_expires_at`을 새로 24시간 준다. 전달 단계의 intent key가 `message:<id>`(앞 단계가 `failed`였으면 `message:<id>:<n>`, 3.2 전이)라 두 번 눌러도 한 번만 전달된다.
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
| 턴 | 사용자 메시지 1건의 전달과 그에 대한 에이전트의 응답 묶음. 에이전트 세션은 한 번에 한 턴만 돈다(세션 단위 직렬). 턴을 시작할 때 `agent_sessions` 행을 `for update`로 잡고, 그 세션에 진행 중인 턴(dispatched · accepted · running · awaiting_answer인 작업)이 있으면 새 턴은 대기열(3.2-5)로 간다. 없으면 `agent_sessions.last_turn_seq`(새 열)를 1 올려 그 턴의 `agent_tasks.turn_seq`에 적는다. 같은 세션에 붙은 대화 둘이 동시에 보내도 이 잠금이 순서를 정한다. 그 턴의 `agent_message` 단계 intent key = `message:<message_id>`(실패 뒤 다시 보낼 때 `message:<message_id>:<n>`, 3.2) |
| 턴의 끝 | 에이전트 CLI의 턴 종료(`result` · `turn/completed`)는 **`completed`가 아니다.** `agent_tasks.state`에 새 값 `idle`(다음 사용자 메시지를 기다림)로 간다. 검토 · check 단계를 붙이지 않는다 |
| `idle` 규칙 | 프로세스가 없어도 된다(`-p`는 턴마다 뜨고 끝난다). heartbeat의 `process_alive=false`는 `idle` 작업을 `unreachable`로 바꾸지 않는다. 다음 메시지는 `resume`으로 같은 세션을 잇는다(capability `resume='supported'`가 `direct_chat` 조건, 4.3). 사용자당 "살아 있는 외부 작업" 한도(런타임 계약 4장)에 **세지 않는다.** `agentTaskStateSchema`와 Swift 디코딩에 `idle`을 더한다(검토 N8) |
| 결과 준비 → Review | `pending_decisions`는 계산값이므로 원천을 run에 둔다: 새 열 `execution_runs.reviewed_turn_seq int not null default 0`(마지막 검토가 본 턴). 계산 입력 `result_ready` = 대화 run 중 작업이 `idle`이고, `turn_seq > reviewed_turn_seq`이며 superseded가 아닌 산출물이 하나 이상 있는 것. 항목 id `result_ready:<run_id>`라 세션 × 이슈(= run)마다 하나로 합쳐지고, 턴이 더 지나면 같은 항목의 "마지막 변경"만 바뀐다. 산출물 없는 턴은 항목을 만들지 않는다(원칙 3). 검토가 끝나면 `reviewed_turn_seq`를 검토한 마지막 턴으로 올려 항목이 사라진다 (U8) |
| Dock의 Review | Review는 두 칸이다: 위 **Needs you**(결정 · `result_ready` · `path_conflict`), 아래 **Since …**(돌아왔을 때 요약, C3 `/api/v2/return-summary` 그대로; 해야 할 일은 빼고 알아 둘 변화만). Dock의 Review 항목은 Needs you가 있으면 노란 타일, 읽지 않은 변화만 있으면 조용한 타일, 둘 다 없으면 사라진다. 눌러서 Review 목록을 연다. ⌥Space는 가장 최근 결정을 바로 연다. 요약은 Projects 목록 위에 두지 않는다(D-12 변경, 2026-10-13, 디자인 시스템 v34) |
| 작업 완료 | Review의 `result_ready` 항목에서 사용자가 "Review result"를 고를 때만 생긴다. 이슈 Done은 검토를 시작하지 **않는다**: 런타임 계약 11장대로 `action_closed` → 그 이슈의 대화 run `stopped`(검토 N2). 에이전트 세션은 이슈들이 함께 쓰므로 **그 이슈의 턴이 지금 돌고 있을 때만** `agent_cancel`을 보낸다. 그 이슈 작업이 `idle`이면 cancel을 보내지 않는다(다른 이슈의 진행 중 턴을 끊지 않기 위해). 같은 세션의 다른 이슈 run은 그대로 |
| "Review result" | 시트 하나: Taskforce가 대화에서 뽑은 완료 기준 후보(T5 제안, ≤ 5줄)를 사용자가 고치고 확인한다. 확인한 기준이 `acceptance`가 되고(런타임 계약 6장 "검토 기준은 수행 전에"를 대화 모드에서는 이 시점에 정한다), 검토 대상은 **그 run의 산출물 중 superseded가 아닌 것, 경로마다 가장 늦은 `turn_seq`의 것**이다. 그 뒤 `completed`(result_revision n) → 검토 · check 한 번. 비용 상한은 그대로. "Later"를 고르면 항목은 남는다(검토 N6) |
| 질문에 대한 답 | `pending_question.kind='input'`일 때 오는 사용자 메시지만 그 질문의 답이 될 수 있다(intent key = **(v3)** `answer:<agent_task_id>:<provider_request_id>`. 한 작업 안에서 질문 id는 반복될 수 있어 질문 id만으로는 열쇠가 되지 않는다). **승인 질문(`kind='approval'`)은 자유 글로 답하지 않는다**: 정책 평가기와 Review(Allow · Deny)에서만 처리하고, 그동안 오는 메시지는 대기열에 쌓인다(검토 N3). **(v3)** 대화의 자유 글이 답이 되는 것은 대기 질문이 하나이고, 선택지 밖 입력을 받고(`allow_other`), 비밀값이 아닐 때(`secret=false`)뿐이다. 아니면 메시지는 대기열에 남고 앱은 질문 카드를 연다(구조화 답만 받는다, 3.6) |
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
- **(v3) 글의 경로:** agent의 답 · 질문 글은 bridge 사건 봉투의 `payload`가 아니라 별도 필드 `text`로 오고, 서버는 이 함수로만 저장한다(`execution_events.payload`에 글 0, 런타임 계약 5장 사건 봉투 규칙 유지). 메시지당 32KB를 넘으면 잘라 저장하고 `content.truncated=true`(전문은 Mac bridge 원장, 세션 패널 View full). 도구 출력 · 명령 결과 · diff 본문은 저장하지 않는다(산출물은 경로 · hash · 요약 ≤ 2k자, 아키텍처 9.2).

### 3.6 질문 · 승인

- 승인 콜백(`question.kind='approval'`)은 **지금과 같은 정책 평가기**가 처리한다. 직접 대화라고 승인을 건너뛰지 않는다.
- 입력 질문(`question.kind='input'`)은 원천을 `agent_tasks.pending_question` 하나로 둔다. 대화에는 3.5로 보이고, Review 목록은 계산 입력(`FutureInputs.agentQuestions`)을 이 열에 연결해 계산한다. 어느 쪽에서 답해도 같은 `answer:<agent_task_id>:<provider_request_id>` 단계 하나로 전달되고, `pending_question`이 비면 두 곳에서 함께 사라진다(검토 F2).
- 대상 `agent` 대화에서는 Taskforce가 입력 질문에 조용히 답하지 않는다(사용자가 상대다). 대상 `taskforce`에서 맡긴 작업의 질문은 런타임 계약 6장대로 Taskforce가 먼저 답을 시도한다.
- **(v3) 질문 열쇠:** `question_key = (agent_task_id, provider_request_id)`. `provider_request_id`는 adapter가 정한다(13장). `pending_question = {question_key, provider_request_id, kind: 'input' | 'approval', structured: boolean, questions: [{id, header, text, options: [{label, description}], multi_select, allow_other, secret}], asked_at}` (`structured` = 이 질문이 id · 선택지가 있는 요청으로 왔는가. 같은 adapter라도 질문마다 다를 수 있다, 13.3). 질문은 1–4개, 다중 선택 · 선택지 밖 입력 · 비밀값을 모두 표현한다. 답은 `answer_agent_question`이 `question_key`로 CAS하고(다르면 409 `question_stale`), bridge는 그 요청이 아직 열려 있을 때만 전달한다(13장의 adapter별 판정). 닫힌 요청에 온 답은 `stale`로 기록하고 전달 0. 질문 글의 해시나 화면 재확인은 쓰지 않는다(화면 파싱용 보정이라 구조화 통로에는 필요 없다). `pending_question`은 런타임 계약 5장 `agent_tasks.pending_question`(`{question_id, text, context_version, asked_at}`)을 이 모양으로 대체한다(9장).
- **(v3) 버려지는 요청:** Stop, `stale`, 또는 답 없이 다른 메시지를 먼저 보내야 할 때 열린 요청은 거절로 닫는다. bridge는 그 `provider_request_id`에 deny를 기록하고, adapter 방식으로 닫은 뒤(Claude Code: 빈 stdin resume → 훅이 그 id에 `deny` → 턴 끝, Codex: 그 요청에 `decline`) 다음 메시지를 보낸다. 요청이 열린 채로 새 메시지를 보내지 않는다. 닫기 resume(Claude Code)은 **닫기 모드**로 띄운다: 훅이 그 프로세스의 모든 호출을 deny하고(닫는 id 포함), 닫는 id의 `tool_result`가 나오면 bridge가 곧바로 SIGINT한다. Stop 뒤에 모델이 계속 행동하지 않게 하기 위해서다(S0에서 deny 뒤 `end_turn`은 질문 도구에서만 관찰했다). 열린 요청이 있는데 프로세스가 없는 작업(Claude Code의 보류)의 Stop은 이 거절 기록으로 `cancel='confirmed'`다.
- **(v3) 비밀값(`secret`):** 그 세션을 가진 Mac에서만 입력한다. 서버는 같은 CAS로 `answered_locally`만 기록하고 값은 저장 · 전달하지 않는다. 다른 기기는 "Answer on <Mac 이름>". 대화의 자유 글은 비밀값의 답이 되지 않는다(3.4). 값은 Mac 디스크에도 쓰지 않는다: 입력 도중 앱이 죽으면 질문은 열린 채 남고 다시 입력받는다. 비밀값 질문이 열린 대화에서는 앱이 일반 메시지 보내기를 막고 질문 카드로 안내한다(비밀을 대화 글로 보내 서버에 남지 않게).
- **(v3) 보내기:** 앱은 답을 2초 보류한 뒤 보낸다(U16). 보류 중 Undo = 서버 호출 0. 보류 중 앱 종료 = 즉시 전송. 실패하면 카드를 되돌리고 이유를 보인다.

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
- **(v3) 세션은 Taskforce가 만든 것만(U13), writer는 하나.** 세션 패널의 **Open in Terminal**은 그 세션을 사용자 터미널에서 이어 쓰게 한다. 턴이 돌거나 답을 기다리는 동안은 누를 수 없다. 누르면 `agent_sessions.status='external'`: Taskforce 전달 0(새 메시지 `queued`, reason `session_external`), Done · Stop은 run만 `stopped`(끊을 프로세스가 없다), 경로 lease는 강제하지 못한다고 표시, 터미널에서 진행한 턴은 `turn_seq` · `result_ready`를 만들지 않는다. **Resume here**로 `bound`로 되돌리면 대기 메시지를 보낸 순서대로 전달한다(자동 전달 계기 ④). Resume here는 사용자가 터미널 세션을 닫았다고 확인한 뒤에만 되돌린다(확인 창). bridge는 보조로 인자에 그 id가 있는 `claude` · `codex` 프로세스를 찾아 있으면 "Close the terminal session first"를 보이고 되돌리지 않는다. 찾지 못한 것은 증명이 아니다: Codex는 다른 프로세스의 thread 연결을 볼 수 없고, 사용자가 id 없이 이어 쓸 수도 있다. Codex 세션은 Open in Terminal 전에 bridge가 그 thread에서 빠진다(`thread/unsubscribe`). `external` 동안 그 세션 run이 잡은 경로 lease(3.9)는 풀고 `event` 한 줄을 남긴다(Taskforce가 막을 수 없으므로). 같은 세션 id를 두 프로세스가 동시에 resume하면 둘 다 실행되고 서로의 턴을 보지 못한 채 대화가 갈라진다(S0 CC-7) — 이 잠금이 필요한 이유다. **View full**은 잘린 글을 Mac 원장에서 읽어 보이며 writer를 바꾸지 않는다.

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
  cancel_scope: "turn" | "turn_and_processes";      // (v3) 중단 확인이 턴 상태만인지, 실행 중 명령까지인지
  question: /* 5장 그대로 */ & { structured: boolean };  // (v3) 이 adapter가 구조화 질문 통로를 쓸 수 있는가. 실제 통로는 질문마다 pending_question.structured
  version_range: string;                              // (v3) 실측한 CLI 버전 범위. 밖이면 대상 state `unsupported`, reason `version_unsupported`
};
// 파생: direct_chat
```

`direct_chat = supported` 조건: `session.create` ∧ `resume = "supported"`(턴 사이 `idle`을 잇는다, 3.4) ∧ `events != "none"` ∧ `question.receive` ∧ **`cancel != "unsupported"`**(U7 Stop) ∧ (쓰기 gate 또는 `read_only` 중 하나 `verified`). 서버가 계산한다(검토 F21 · N8).

**`verified`의 출처:** 서버 registry만 정한다(D0식 통제 테스트 증거와 함께). bridge가 등록 때 보내는 `capabilities`(`bridgeRegisterRequestSchema`)는 "이 Mac에 설치돼 있고 이 버전이다"만 뜻한다. 실제 값 = registry 값과 bridge 보고의 **더 좁은 쪽**(검토 F21).

### 4.4 0.2.0 registry (U10)

| adapter | display_name | transport | 상태 |
|---|---|---|---|
| `agent:claude-code` | Claude Code | local_bridge | 첫 에이전트(결정). 13.2. **S0(2.1.241) 초기값:** session.create · resume · events push · question receive/answer(Taskforce MCP `ask_user`, structured) · cancel `confirmed`/`turn_and_processes` · `approval_gate` verified(CC-3 · CC-9 · CC-10 · CC-12). `target_scope` · `read_only` · `revocation` = `verified: false` |
| `agent:codex` | Codex | local_bridge | 두 번째 구현. 13.3. **S0(0.162.1) 초기값:** session.create · resume · events push · question receive/answer(`requestUserInput`, structured — 실험 기능) · cancel `confirmed`/`turn` · `approval_gate` verified(Manual 매핑, CX-8a) · `target_scope` verified(CX-5b) · `read_only` verified(CX-8 `never`+`readOnly`). `revocation` = `verified: false` |

**(v3) 초기값의 결과.** registry 값은 이 표가 정한다(S0 `capability.json`의 값과 다르면 보수적인 쪽, 즉 이 표가 이긴다). 런타임 계약 5장 gate 표대로 계산하면 시작 시점에는: 두 adapter 모두 `revocation`이 미검증이라 **쓰기 등급이 닫혀 있다**. Claude Code는 `read_only`도 미검증이라 `direct_chat = unsupported`이고, Codex는 읽기 전용 등급(3.7)으로만 `direct_chat`이 열린다. 쓰기를 여는 시험: D3a · D3b의 "철회 뒤 쓰기 시도가 막힌다"(정책을 Manual로 바꾸거나 연결 철회 뒤 다음 쓰기 호출이 거절됨 — Claude Code는 훅이 매 호출 현재 정책을 읽고, Codex는 다음 `turn/start`의 정책과 진행 중 승인 요청의 거절로). Claude Code의 읽기 전용 등급: `--tools "Read,Glob,Grep"` + 훅 결정표에서 Edit · Write · Bash deny로 쓰기 0을 보이면 `read_only` verified. Claude Code의 `target_scope`: 작업 폴더 밖 경로의 Read · Edit · Write가 훅에서 거절됨을 보이면 verified(Bash는 13.4 파서 판정 밖이면 항상 defer라 문자열 범위 검사로 verified를 주지 않는다). 각 시험의 증거가 `capability` evidence가 된다.

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
- **(v3)** `cancel_scope='turn'`인 adapter(Codex 실측: `turn/interrupt` 뒤 실행 중 명령이 살아남음)는 응답 작업마다 `processes: "may_continue"`를 더하고, 앱은 "Stopped · commands may still be running"을 보인다. `external` 세션(3.8)의 Stop은 run만 멈춘다.

### 5.1 OA D3c-2 서버 확정 정정 (2026-10-14)

이 절은 OA D3c-2 계약 5.1의 Q1–Q21을 반영하며 아래에 지정한 기존 문구보다 우선한다. 13.4.1의 파서 규칙은 수정하지 않는다.

- **3.9 경로 lease:** 키는 `(user_id, bridge_id, agent_path_key(real_path))`다. Mac이 절대 realpath를 보고하고 SQL이 NFC + `ſ`→`s` + ASCII 대소문자 접기를 한다. 그 밖의 비ASCII 대소문자는 접지 않는다. Manual 파일 쓰기는 승인 요청 때 `requested`로 예약하고 Allow면 `approved`, Deny면 그 요청의 예약만 해제한다. 같은 run의 `approved/observed` 재사용은 source·request_id를 보존하고 만료만 지운다. 늦은 `allow`가 새로 만든 행은 그 요청의 Deny로 해제한다. 산출물로 처음 관찰한 경로는 `observed`로 잡는다. 같은 세션의 다른 이슈 run에도 양보 규칙을 적용한다.
- **3.9 양보·해제:** 응답은 `deny`, `reason: path_in_use`, `holder: {action_number, rel_path}`이며 run id를 에이전트에 보내지 않는다. Claude Code에는 `agent_note`를 훅 거절 이유로 전달한다. 대화에는 `Waiting for …`, 해제 뒤에는 `… is free now` event 줄을 남긴다. Taskforce가 에이전트에게 먼저 보내는 새 턴은 만들지 않는다. run 종료·external·Deny에서 해제하고, 턴 종료 30분 뒤 sweep으로 만료한다. 다음 턴의 실제 접수(`accepted`)에서 만료 시각을 비운다.
- **3.9 사후 충돌:** 늦게 쓴 run에 취소를 요청하고 `stopped`로 끝내는 것이 `Stop new steps`다. `conflict_run_id`, `conflict_at`, `conflict_stop_at`은 충돌 해소까지 보존한다. 이미 실행된 파일 변경을 되돌렸다는 뜻은 아니다.
- **13.2 결정표:** bridge는 정적 도구·닫기 모드·보류 중복·파일 시스템 사실을 먼저 확인한다. Bash·Edit·Write·Codex 승인의 정책 판정은 서버 API가 한다. 0.2.0에는 사용자 명령 허용 목록이 없으며 Bash 자동 허용은 13.4 파서 성공에만 근거한다.
- **AC-9 (사용자 결정: 읽기는 허용):** Manual에서 쓰기 자동 허락은 0이다. 작업 폴더 안 읽기 전용 단일 명령은 13.4 판정으로 허용한다. Codex Manual은 읽기 actions·독립 파서 성공·첫 요청의 세 조건을 모두 요구한다. Auto/Full에서 온 Codex 승인 요청은 사용자에게 묻고 `Runs without sandbox`를 표시한다.
- **3.6 승인 답·8장 측정:** Assistant와 Review는 같은 `POST /api/v2/agent-tasks/{id}/answer`에 `{provider_request_id, answers:{approval:"allow"|"deny"}}`를 보낸다. SQL이 답·예약 확정/해제·`question_answered {kind:approval,adapter,decision}`를 원자 처리한다. 서버 판정은 `tool_call_decided`, 사후 충돌·해소는 `path_conflict_found`·`path_conflict_resolved`로 센다. bridge 로컬 결정은 서버 지표에 포함하지 않는다.

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
- (v3) 런타임 계약 5장: `agent_sessions.status`에 `external`, `agent_tasks.pending_question`을 3.6의 모양으로, capability에 `cancel_scope` · `question.structured` · `version_range`(4.3). 아키텍처 8.2(b)(c)(d)는 13.2가 고친다(환경변수에 `USER`, `--setting-sources project`, 승인 · 질문은 PreToolUse 훅 + `defer` · Taskforce MCP `ask_user`). 0.2.0 계획 · 이행 계획의 "Mac 앱 샌드박스 유지" 전제는 U12로 바뀐다.
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
| AC-8 | `awaiting_answer` 중 메시지가 3.4의 답 조건(질문 하나 · `allow_other` · `secret=false`)을 만족하면 답, 아니면 대기열 · 질문 카드. 답이면 `directive_version` 변화 0, 대화 · Review 양쪽에서 사라짐 (v3 수정) | DB + 단위 |
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
| AC-34 | (v3) 지연: 시계는 메시지 보내기 또는 답 보류(2초)가 끝난 시점에 시작해 CLI 입력에서 멈춘다(Claude Code: 턴 프로세스 시작, Codex: `turn/start` · 요청 응답 전송). Realtime 연결 시 열린 작업 유무와 상관없이 20회 중 p95 ≤ 3초. Realtime 끊김: 열린 작업 있음 ≤ 8초, idle ≤ long-poll 한 주기(≤ 25초) | bridge 원장 · 서버 시각 |
| AC-35 | (v3) 비샌드박스 공증 앱이 사용자 로그인된 `claude` · `codex`를 띄운다. 샌드박스 구성에서는 "Can't run agents in this build"를 보이고 크래시 0. 샌드박스 → 비샌드박스 업데이트 뒤 로그인 · 설정 유지 | Mac |
| AC-36 | (v3) 턴 진행 · 답 대기 중 Open in Terminal 비활성, `external` 동안 전달 0 · 새 메시지 `queued`, Resume here 뒤 순서대로 한 번씩 | DB + 실제 provider |
| AC-37 | (v3) 단일 · 다중 선택 · 선택지 밖 입력 · 질문 여러 개 · 승인 · 비밀값이 각각 Assistant와 Review에서 정확히 1회 전달. 비밀값 답의 서버 기록 0, 다른 기기에는 "Answer on <Mac>". 닫힌 요청에 온 답 전달 0. 버려진 요청은 거절로 닫히고 실행 0 | 단위 + 실제 provider |
| AC-38 | (v3) 실행 중 턴이 있을 때 앱 종료 → 확인, 강제 종료 뒤 재시작 → bridge 원장으로 정리하거나 `unknown`, 재dispatch 0 | Mac |
| AC-39 | (v3) 지원 범위 밖 CLI 버전 → `unsupported`/`version_unsupported`, 로그인 없음 → 단계 `failed` · 메시지 `not_sent`/`sign_in_needed` · Send again으로 다시, 사용량 한도 → `not_sent`/`usage_limited` · 자동 재전송 0, 24시간 넘으면 `expired` | 실제 provider + 단위 |
| AC-40 | (v3) 답 보류 2초 안 Undo → 서버 호출 0, 2초 뒤 정확히 1회, 보류 중 종료 → 정확히 1회 | Mac + bridge 원장 |
| AC-41 | (v3) Codex `turn/start`마다 `sandboxPolicy`(`excludeSlashTmp` · `excludeTmpdirEnvVar` true) · `approvalPolicy`가 있다. 빠지면 bridge가 보내지 않는다 | 단위 |
| AC-42 | (v3) Claude Code 자식 환경변수 = `HOME` · `PATH` · `LANG` · `USER`뿐. `ANTHROPIC_*` · `CLAUDE_*` 0 | 단위 |

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

1. Codex 기존 세션 부착: 공유 app-server daemon(`thread/loaded/list` · `thread/queue/add`)으로 사용자가 이미 돌리는 Codex 세션에 구조적으로 붙을 수 있다(One이 이 방식을 쓴다). S0에서는 daemon을 건드리지 않았다. 0.2.x에서 실측 뒤 정한다. 그때까지 `session.attach_existing=false`.
2. Codex의 MCP 서버 일괄 비활성 방법: 이름별로 끄려면 사용자 설정을 읽어야 하는데 `config/read`는 자격을 돌려준다(13.3). 일괄 비활성 플래그를 찾기 전에는 이름을 모르는 MCP 서버가 켜진 채 돈다는 것을 대상 목록에 표시한다.
3. 약관: LEGAL-CC(Anthropic Commercial Terms · 사용자 구독 로그인 사용) · LEGAL-CX(OpenAI app-server 인증 문구)는 외부 사용자에게 플래그를 켜기 전에 확인한다.

## 13. adapter 실행 계약 (v3, 실측 S0 2026-10-13)

증거: `~/.claude/worktrees/taskforce-020/handoffs/oa-s0-evidence/<adapter>-<version>/`(`results.md` · `capability.json` · `events/` · `harness/`). 이 장의 값은 그 버전에서 관찰한 것이다. 버전이 바뀌면 같은 harness로 다시 실측하고 `version_range`를 넓힌다.

### 13.1 공통

- **실행 위치:** Mac bridge는 앱 안에서 돈다(U12). App Sandbox를 끈 앱만 사용자 CLI를 띄운다. 샌드박스 구성에서는 대상 state `unsupported`, 앱은 "Can't run agents in this build".
- **로그인 · 자격:** Taskforce는 로그인을 대행하지 않고 자격을 읽지 않는다(I16). 사용자가 터미널에서 CLI에 직접 로그인한다. adapter는 자격을 돌려주는 호출(Codex `config/read` · `account/*`의 개인 필드, Claude 자격 파일 · Keychain)을 부르지 않는다. 로그인 여부는 CLI 자체의 상태 명령으로만 본다.
- **writer 하나:** 세션마다 한 프로세스만 쓴다(3.8). bridge는 같은 세션 id로 두 번째 프로세스를 띄우지 않는다.
- **질문 · 승인 열쇠:** `provider_request_id`는 아래 adapter별 정의. 한 연결 안에서만 유효한 번호(예: JSON-RPC id)는 열쇠로 쓰지 않는다.
- **결과 불명:** bridge 원장이 1차 원천이다. adapter가 "받았는가"를 조회할 수 있으면(13.3) 그 결과로 정리한다. 자동으로 다시 보내지 않는다(런타임 계약 5장 "다시 dispatch하지 않는다"): 조회가 "받지 않음"을 보이면 메시지를 `not_sent`, reason `not_received`로 되돌려 사용자가 Send again을 누르게 하고, 판정하지 못하면 `unknown`으로 두고 사용자가 정한다. 조회 전에 앞 프로세스가 끝났는지 확인한다(살아 있으면 늦게 받을 수 있다).
- **중단:** `cancel_scope`(4.3)를 adapter마다 적는다. 턴 상태만 확인되면 "명령이 계속될 수 있다"를 보인다(5장).

### 13.2 Claude Code (`agent:claude-code`, 2.1.241, 턴마다 `claude -p`)

실측 S0 run 2 · run 3(`oa-s0-evidence/claude-code-2.1.241/results.md`). 아키텍처 8.2(b)(c)(d)를 이 절이 고친다.

**실행**

- **환경변수:** `HOME` · `PATH` · `LANG` · `USER`만 넘긴다(AC-42). 로그인 뒤 같은 Mac에서 `USER`를 빼면 `claude auth status`가 `loggedIn: false`, 넣으면 `true`였다(코디네이터 확인, `handoffs/oa-progress.md` 10-13). `ANTHROPIC_*` · `CLAUDE_*`는 넘기지 않는다.
- **cwd · 프롬프트:** cwd = 세션마다 Taskforce가 만든 빈 폴더. 프롬프트는 stdin으로 준다(`--add-dir` · `--mcp-config` · `--disallowedTools`가 가변 인자라 위치 인자 프롬프트를 삼킨다).
- **첫 턴:** `claude -p --output-format stream-json --verbose --include-hook-events --max-budget-usd <n> --model <m> --tools "Read,Glob,Grep,Edit,Write,Bash" --strict-mcp-config --mcp-config <세션 폴더>/mcp.json --add-dir <작업 폴더> --settings <세션 폴더>/settings.json --setting-sources project --permission-mode manual --append-system-prompt <질문은 mcp__tf__ask_user로, 한 번에 하나> --session-id <agent_sessions.external_session_id>`. **다음 턴:** `--session-id` 대신 `--resume <id>`, 나머지 · cwd는 같게.
- **도구:** `--tools`로 내장 도구를 여섯 개로 줄인다. MCP 도구는 `--tools`로 걸러지지 않으므로 `--strict-mcp-config` + Taskforce 서버 하나로 제한한다. 이 구성의 init `tools`는 정확히 `Bash, Edit, Glob, Grep, Read, Write, mcp__tf__ask_user`였고 ToolSearch 없이 `ask_user`를 바로 불렀다(CC-11). 2.1.241에는 MultiEdit · TodoWrite · LS · AskUserQuestion · WebFetch가 없고, 모르는 이름은 조용히 버려진다.
- **설정 출처:** `--setting-sources project` + 빈 cwd라 사용자 전역 훅 · 허용 규칙 · 전역 `~/.claude/CLAUDE.md`가 들어오지 않는다(CC-14: `project`면 미로딩, `user`면 로딩). 대상 목록에 "Your Claude Code settings aren't applied"를 보인다.
- **권한 모드 `manual` 고정.** `acceptEdits` · `auto` · `bypassPermissions`는 쓰지 않는다. 훅이 오류(exit 127)이거나 timeout으로 끊기면 일반 권한 흐름으로 넘어가는데, `manual`이면 Write · Bash 쓰기가 거절되고(CC-3 · CC-10) `acceptEdits`면 쓰기가 실행됐다(fail-open). 읽기(`ls` 등)는 `manual`에서도 결정 없이 허용된다(CC-10) → 읽기 제한은 훅의 몫이다. Taskforce 설정 파일에는 `permissions.allow`를 두지 않는다. 명시적 deny는 허용 규칙 · `acceptEdits`보다 이긴다(CC-3b).

**훅과 bridge**

- **설정 파일:** 세션 폴더의 `settings.json`에 SessionStart 훅(표식 출력)과 PreToolUse 훅(matcher `*`) 둘. 명령은 앱 번들의 `Contents/Helpers/tf-agent-hook --session <session id> --nonce <spawn nonce>`(절대 경로, 인터프리터 없음), PreToolUse `timeout` 10초.
- **bridge 소켓:** 사용자만 읽고 쓰는 Unix 소켓 `~/Library/Application Support/Taskforce/bridge.sock`(0600). 요청 한 줄 JSON `{v: 1, nonce, session_id, hook_event, tool_use_id, tool_name, tool_input, permission_mode, cwd}`(`cwd`는 훅 입력의 `cwd` 그대로, 13.4.1-3), 응답 `{decision: "allow" | "deny" | "defer", reason, updated_input?}`. 훅은 응답을 1.5초까지 기다리고, 그 안에 답이 없거나 소켓이 없거나 nonce가 맞지 않으면 deny JSON을 낸다(exit 2도 차단이다). 훅 안에서 사용자를 기다리지 않는다(timeout = fail-open 경로).
- **결정표**(bridge가 정한다):

| 입력 | 결정 |
|---|---|
| `permission_mode`가 `default`가 아님 | deny |
| Read · Glob · Grep | allow(작업 폴더 · 세션 폴더 밖 경로는 deny) |
| `mcp__tf__ask_user` | 답이 있으면 allow + `updated_input.answers`, 버려진 요청이면 deny, 아니면 defer |
| Edit · Write | 경로가 작업 폴더 밖이면 deny. 안이면 정책 평가기(3.6 · 3.7 · 3.9)가 1초 안에 정하면 allow · deny, 사용자 판단이 필요하면 defer |
| Bash | 사용자 정책의 명령 허용 목록과 **정확히 일치**하거나 13.4 파서가 작업 폴더 안 읽기 전용 단일 명령으로 판정하면 allow. 아니면 Manual · Auto/Full 모두 defer(명령 문자열로 쓰기 범위를 증명할 수 없다). `dangerouslyDisableSandbox: true` · `run_in_background: true`는 deny |
| 닫기 모드(3.6 버려지는 요청) | 모든 호출 deny |
| 그 밖(`Agent`(init에서는 `Task`) · `Skill` · `NotebookEdit` 등 모든 도구) | deny |
| 같은 프로세스에서 이미 defer를 한 번 냄 | deny("Wait for the answer") — 한 턴에 보류 하나 |

- **Taskforce MCP 서버:** `mcp.json`이 앱 번들의 `Contents/Helpers/tf-agent-mcp --session <id> --nonce <n>`을 `tf` 서버로 띄운다(claude가 띄운다). 도구 `ask_user`의 입력 스키마는 3.6의 `questions[]`. 도구 본문은 훅이 넘긴 `answers`를 결과로 돌려줄 뿐이다(답 없이 불리면 오류 결과 "No answer yet").
- **자체 점검(매 spawn):** ① spawn 전에 `settings.json` · `mcp.json`을 검증한다(깨진 `--settings`는 오류 없이 훅 없이 돈다, CC-13). ② init의 `permissionMode == "default"`, `tools`가 위 일곱 개와 같음, `mcp_servers`에 `tf` 연결. ③ SessionStart 훅 표식이 init 전에 있음. ④ 모든 `tool_use`마다 `hook_started PreToolUse:<tool>` 사건이 결과보다 먼저 와야 한다. 하나라도 어긋나면 SIGINT하고 단계 `failed`/`spawn_failed`(SessionStart 표식만으로는 PreToolUse 설치를 증명하지 못한다 — 한 파일에서 PreToolUse만 잘못돼도 그것만 조용히 빠졌다). ⑤ ④는 도구 결과가 나온 뒤에야 훅 누락을 알므로, bridge 시작 때 관리자 managed settings 파일(`/Library/Application Support/ClaudeCode/managed-settings.json`)이 있으면 대상 `unsupported`로 둔다(허용 규칙 · 훅 비활성 키가 없음을 검사하는 규칙은 D3a에서 만든다).

**질문 · 승인 · 중단**

- **보류(`defer`):** 승인 · 질문 모두 훅의 `defer`로 턴이 `stop_reason: "tool_deferred"` + `deferred_tool_use {id, name, input}`로 끝난다 → `agent_tasks` `awaiting_answer` → 답 · Allow · Deny → **빈 stdin**으로 `--resume` → 훅이 같은 id에 allow(+ `updated_input`) 또는 deny. 비어 있지 않은 프롬프트로 resume하면 보류된 호출 뒤에 턴이 더 돌아 같은 요청이 중복됐다(CC-2). 보류 상태는 강제 종료 뒤에도 남는다(CC-5b). `-p`에는 기본 AskUserQuestion 도구가 없다(CC-2).
- **답 모양:** `updated_input.answers = {<question id>: <label> | [<label>] | <글>}`(Taskforce가 정한 스키마).
- **열쇠 · 열린 요청:** `provider_request_id = deferred_tool_use.id`. 그 세션의 마지막 프로세스가 그 id로 `tool_deferred`를 끝냈고 그 뒤 다른 프로세스가 돌지 않았을 때만 열려 있다. 한 응답에 보류가 둘이면 마지막 것만 보고된다. 보고되지 않은 쓰기는 실행되지 않았고 훅도 다시 불리지 않았으며, 모델이 새 id로 다시 냈다(CC-9). 강제 종료로 끊긴 도구도 resume 때 새 id로 다시 나온다(CC-5a). 보고되지 않은 · 옛 id는 `stale`.
- **거절로 닫기:** 보고된 id에 deny로 resume하면 모델이 받아들이고 턴이 `end_turn`으로 끝났다(CC-9, 질문 도구).
- **중단:** 프로세스가 있으면 SIGINT → `result.subtype: "error_during_execution"`, `terminal_reason: "aborted_tools"`, exit 0, 실행 중이던 자식 프로세스 종료, 늦은 사건 0, 이후 resume 가능(CC-4, 전경 자식 하나의 관찰). `cancel = "confirmed"`, `cancel_scope = "turn_and_processes"`. 보류 중이라 프로세스가 없으면 3.6 "버려지는 요청" 규칙. SIGTERM은 쓰지 않는다.
- **writer 하나:** 같은 id로 resume 둘을 동시에 띄우면 둘 다 실행되고 서로의 턴을 보지 못했다(CC-7). bridge는 세션마다 한 프로세스만 띄운다(3.8).

**그 밖**

- **로그인 · 한도:** 로그인 여부 = `claude auth status`의 `loggedIn` · `authMethod`만. 로그인 없음의 결과 = `subtype: "success"` + `is_error: true` + `terminal_reason: "api_error"`, exit 1 → 단계 `failed`, 메시지 `not_sent`/`sign_in_needed`. `rate_limit_event`는 매 실행 온다(사용량 표시). 한도 초과 모양은 미확인 → 미확인 오류는 `spawn_failed`.
- **결과 불명:** transcript 형식은 내부용이라 파싱하지 않는다. bridge 원장(spawn · init · 훅 사건 · result · 보류 id)이 원천이다. `system/init` 전 종료 = 받지 않음(`not_sent`/`not_received`, D3a는 이때 transcript에 사용자 턴이 없음을 시험으로 확인한다), init 뒤 첫 `assistant` 전 종료 · `result` 없는 종료 = `unknown`(다음 resume이 이어 가고 끊긴 도구는 새 id로 다시 나온다).
- **버전:** `version_range = ">=2.1.241 <2.2"`. Claude Code는 자주 갱신되므로 범위 안의 새 패치는 매 spawn 자체 점검을 통과할 때만 쓴다. 범위 밖은 `unsupported`. 범위를 넓히려면 같은 harness로 다시 실측한다.
- **지연(실측):** spawn → init 1.0–1.2초, 짧은 턴 결과 2.8–3.3초.
- **미시험(D3a에서 시험):** 같은 응답의 defer 뒤 deny 조합(결정표 "이미 defer를 한 번 냄"), Write를 deny로 닫은 뒤의 모델 행동(닫기 모드), managed settings가 있는 Mac, `--permission-mode plan`, stream-json 제어 프로토콜.
- **약관 gate LEGAL-CC:** 사용자가 수정하지 않은 `claude`에 직접 로그인해 쓰는 구조다. 제품에서 Claude Code를 띄우는 것은 Commercial Terms 동의를 조건으로 한다. 외부 사용자에게 켜기 전에 확인한다(아키텍처 8.2의 ARCH-V07).

#### 13.2.1 정정 (OA D3a, 2026-10-15)

OA D3a 계약(`handoffs/oa-d3a-contract.md`) 5.1의 결정을 반영한다. 위 13.2와 다르면 이 절이 이긴다. 13.4.1은 바꾸지 않는다.

1. **답 resume의 순서(실측, 위 본문 침묵).** 보류를 답하는 빈 stdin resume에서는 `SessionStart:resume` → `command_lifecycle` → 보류 id의 `hook_started PreToolUse` → `hook_response` → `tool_result` → **그 뒤에** `system/init`이 온다(S0 `r3-cc9-2` · `r3-cc9-3`). 그래서 답 resume의 자체 점검 ②는 보류 호출이 실행된 뒤에 확인된다. 보류 호출은 ③ · ④와 bridge 자신의 답(보류 id · 입력 digest 대조)으로 지키고, ②가 어긋나면 SIGINT로 그 뒤 호출을 0으로 만든다. 보류 id의 훅보다 init이 먼저 오면(상태 유실) 그 답은 닫힌 것으로 본다.
2. **소켓 · 인자 · 요청 모양(Q4).** 소켓은 `<Application Support>/<번들 id>/Bridge/hook.sock`(경로가 100바이트를 넘으면 사용자 임시 폴더 아래 `tf-<번들 id sha256 앞 8자>/hook.sock`, 폴더 0700 · 소켓 0600 · 피어 uid 확인)이다. 훅 명령은 `'<helper>' pre-tool-use --socket '<S>' --session '<id>' --nonce '<N>'`(SessionStart는 `'<helper>' session-start`, 모든 값 작은따옴표)이고 `mcp.json`은 `--session`만 준다(MCP는 소켓 · nonce를 쓰지 않는다). 설정 파일은 세션 폴더의 `config/`(cwd 밖)에 spawn마다 새로 쓴다. 요청은 Write `content` · Edit `old_string` · `new_string`을 빼고 길이와 원래 입력 전체의 정규 sha256(`input_sha256`), 훅 입력의 Claude 세션 id(`provider_session_id`)를 싣는다. bridge 응답은 `updated_input` 대신 `answers`(ask_user 답) 또는 `command`(다시 만든 Bash)만 주고, 훅이 자기가 받은 원래 입력에서 그 키만 바꿔 `updatedInput`을 만든다(모델이 넣은 `answers`는 버린다). bridge는 1.2초 안에 답하지 못하면 deny로 끊는다.
3. **model · 예산(Q6).** `--model`은 주지 않는다(사용자 플랜의 기본). `--max-budget-usd 25`는 폭주를 막는 상한일 뿐 약속이 아니다(넘으면 `failed(agent_error)`).
4. **PATH · 실행 파일(Q7).** `claude`는 `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin`의 처음 있는 것을 쓰고, 자식 PATH = `<그 폴더>:~/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`이다. 셸 설정을 실행해 PATH를 얻지 않는다.
5. **결과 불명(Q5).** init을 본 시각을 명령 `inputAt`으로 적는다(로컬 전용, 서버 사건 아님). 접수 신호 없이 끝난 명령은 `inputAt`이 없으면 `not_received`, 있으면 `unknown`이다. adapter 결과 확인은 transcript를 읽지 않으므로 `unsupported` 그대로다.
6. **신호(Q12).** 중단(감독 중인 Stop 포함)과 고아 끝내기는 SIGINT → (유예, 정체 재확인) → SIGKILL이다. 신호는 확인한 pid에만 하나씩 보내고(보내기 직전 그 세대의 unique id · 사용자를 다시 대조), 그룹은 부모가 살아 있는 그룹 리더일 때만 구성원 찾기에 쓰며 `killpg`는 쓰지 않는다(OA D3a 계약 9장 5 · 6 · 10장 1). SIGTERM은 쓰지 않는다(OA D2b `AgentProcess` 문서의 "SIGTERM → SIGKILL"보다 이 절이 이긴다).
7. **managed settings(Q13).** 파일이 있으면 `managed_settings: true`(대상 `unsupported`)이고 내용 검사는 0.2.x다.
8. **승인 카드 글(Q8, 사용자 결정).** Edit · Write는 `Edit <작업 폴더 기준 상대 경로>` · `Write <상대 경로>`, Bash는 `Run: <명령 앞 300자>`를 질문 글로 서버에 둔다(대화 보관 기한을 따른다). 줄바꿈은 `⏎`, 탭은 `⇥`, 제어 · 양방향 · 폭 없는 글자는 `\u{XXXX}`로, 빈칸으로 보이는 글자(Zs · U+115F · U+1160 · U+3164 · U+FFA0 · U+2800)의 연속은 `␠×N`으로(보통 공백 하나는 그대로), 한 글자에 붙은 결합 표시가 2개를 넘으면 `\u{XXXX}×N`으로 보이고, 유니코드 스칼라로 세어 300을 넘으면 앞부분 + `…(+숨긴 수)…` + 마지막 80이다. Mac이 서버 없이 미룬 카드(하드 링크 · 모르는 입력 키 · 가린 명령)는 둘째 줄에 사유 한 줄을 붙인다: 카드 전체 = 머리 + 명령 300 스칼라 이하 + 사유 줄(OA D3a 계약 8장 4 · 9장 11 · 12 · 10장 9). diff · 파일 내용은 0이다.
9. **비밀값(Q9, 사용자 결정).** `ask_user`의 `secret` 질문을 허용한다. 값은 Taskforce 서버 · Mac 원장 · 로그에 없고, 훅 출력 → MCP 도구 결과로 모델 문맥과 Claude Code 자체 기록(`~/.claude/projects/…`)에만 남는다. 3.6의 "Mac 디스크에도 쓰지 않는다"는 Taskforce가 쓰는 곳으로 읽는다. 모델이 그 값을 되말하거나 명령에 넣으면, 그 agent 세션 동안 Mac 메모리에 쌓아 둔 값(8자 이상)과 그 변형(앞뒤 공백 정리 · NFC/NFD · JSON 이스케이프 · 셸 `'\''` · 퍼센트 인코딩)을 그 세션의 모든 spawn이 밖으로 내는 사건 글 · 승인 글에서 `[redacted]`로 바꾼다. 결정 입력과 사건 글은 디코드해서도 찾는다(퍼센트 두 방식 · `+`→빈칸 · JSON unescape · 셸 따옴표 풀기 · NFC/NFD): 비밀값이 든 Bash 명령은 서버에 묻지 않고 가린 글의 승인 카드로, 비밀값이 든 Edit · Write 경로는 deny(`secret_in_path`)다. 원문 비밀값은 어떤 요청에도 없다. 비밀 항목 id(값이 아니라)는 상태 파일에 두고 런타임이 이 Mac에서 답한 값인지를 알려, 질문이 열린 채 앱이 다시 떠도 그 값을 가린다. 탐지는 셸 줄 이음 · ANSI-C `$'…'`도 풀고(글 전체를 셸로 푼 것과 따로 `$'…'` 조각마다도 푼다 — 앞선 자연어 · 주석의 작은따옴표에 흔들리지 않게, Bash 주석은 그대로 둔다), 디코드한 형태마다 정규화 전 글자 그대로를 먼저 본다. 비밀값(가리개가 실제로 가진 8자 이상 값)을 건넨 뒤 앱이 다시 떠 그 세션의 가리개가 비었으면 그 Claude 세션은 이어 띄우지 않는다(`spawn_failed`, 사용자는 새 세션으로, OA D3a 계약 8장 11 · 9장 1–3 · 10장 7 · 8 · 11장 7–9 · 12장 11 · 12). 범위는 실수로 되말한 값과 이 인코딩들까지이고, 일부러 꼰 형태(변수 이어 붙이기 · 중괄호 확장 · base64 · 일부만 출력)는 남는 위험이다.
10. **질문은 보고된 보류만.** 질문 사건은 `result.deferred_tool_use`가 bridge가 기록한 id를 보고할 때만 내고, 프로세스가 끝난 뒤에 낸다(답이 왔을 때 writer가 하나). 기록에 없는 id가 보고되거나 열린 요청을 상태 파일에 적지 못하면 질문 없이 그 id를 닫기 모드로 닫고 `failed(agent_error)`다.
11. **승인 대상 · 끝 · resume id(OA D3a 계약 8장 2 · 13 · 10).** 승인한 Edit · Write는 보류 때 해석한 대상과 같을 때만 실행한다(지문 해시, 다르면 deny). 프로세스의 끝은 그 spawn의 자손까지 사라진 때다. 구성원은 책임 프로세스로 본다(사용자 결정 2026-10-17): `claude`를 disclaim으로 띄워 자기 책임 프로세스가 되게 하고, 뿌리가 살아 있는 동안 책임 프로세스가 뿌리인 이 사용자 프로세스(뿌리보다 뒤에 만들어진 것)가 구성원이다 — setsid · 이중 fork · 못 본 중간 프로세스의 자손도 든다. 뿌리가 끝나면 그 자손은 스스로의 책임 프로세스가 되므로(실측), 그때 본 구성원을 커널 계보(unique id · pid)에 적어 두고 같은 그룹 · spawn marker와 함께 쓴다. disclaim · 책임 조회 함수가 없거나 실패하면 구성원을 증명할 수 없어 끝을 확정하지 않고(`unknown`) 자손에 신호를 보내지 않는다. 귀속되지 않은 살아 있는 프로세스가 뿌리 pid나 계보에 적힌 pid의 그룹에 있으면 그 훑기는 불완전하다. `claude`가 자기 책임 프로세스라 macOS 권한 창(문서 · 데스크톱 등)은 `claude` 이름으로 뜬다. 다른 부팅에 적힌 계보 · 끝 기록은 이미 끝난 것이다. 끝은 완전한 증거(그 기록, 또는 연속 두 번의 완전한 빈 훑기)가 있을 때만이고, 뿌리 id를 모르거나 계보 파일이 없거나 읽지 못하거나(덧붙이기 실패 · 잘린 줄 포함) 훑기가 불완전하면(조회 실패는 언제나 불완전) `unknown`(세션 잠금 유지)이다(OA D3a 계약 9장 4 · 10장 1–4 · 11장 1–5 · 12장 1–8, 정정 제안 9-4). 뿌리 id를 읽지 못한 spawn은 정체를 적기 전에 멈춘다(`spawn_failed`). 격리 `cwd/`가 비어 있지 않으면 세션 폴더 안 격리 폴더로 옮기고 빈 `cwd/`로 띄운다(12장 13). `--resume`은 Mac 세션 폴더가 init으로 묶은 id만 쓴다. 세션 · 원장 루트와 앱 Application Support 안의 Edit · Write는 deny다(10장 5).

### 13.3 Codex (`agent:codex`, codex-cli 0.162.1, `codex app-server` stdio)

실측 S0 CX-1–CX-8 · CX-3d(`oa-s0-evidence/codex-0.162.1/results.md`).

**실행**

- **프로토콜 · 버전:** 실험 단계다. `version_range = ">=0.162.1 <0.163"`. bridge는 시작할 때 `codex app-server generate-json-schema --experimental --out <임시 폴더>`로 쓰는 정의(아래 메서드 · 요청 · 알림)의 hash를 구해 registry의 실측 hash와 비교하고, 다르면 `unsupported`. `codex exec`(질문 · 승인에 답할 수 없음)과 `codex mcp-server`(제거됨)는 쓰지 않는다.
- **프로세스:** bridge의 계정 epoch마다 오래 사는 `codex app-server` 하나(턴마다 띄우지 않는다: spawn → `initialize` 중앙값 574ms, 20회 중 2회 약 5.7초). 죽으면 다시 띄우고 `thread/resume`. 환경변수는 13.2와 같은 `HOME` · `PATH` · `LANG` · `USER`(S0는 물려받은 환경으로 돌았다 → D3b에서 이 네 개로 로그인 · 실행을 시험한다).
- **설정 격리:** 사용자 `~/.codex` 설정(notify · hooks · plugins · MCP 서버 · 전역 AGENTS.md)이 적용된다. 프로세스마다 `-c notify=[]`, `--disable hooks --disable plugins --disable apps --disable memories --disable computer_use --disable browser_use --disable browser_use_external --disable in_app_browser --disable daemon_auto_start --disable multi_agent`. 전역 AGENTS.md는 끌 수 없어 대상 목록에 "Uses your Codex instructions"를 보인다. MCP 서버 일괄 비활성은 12장 2. adapter는 `config/read`를 부르지 않는다(MCP 자격을 돌려준다).
- **시작:** `initialize {clientInfo, capabilities: {experimentalApi: true}}` → `initialized` → `thread/start {cwd: <작업 폴더>, approvalPolicy, sandbox}`(`ephemeral` 금지). 재시작 뒤 `thread/resume {threadId}`는 같은 id(CX-1). 기록 조회는 `thread/turns/list`(`thread/read includeTurns`는 폐지 예정).
- **턴마다 정책**(thread 수준 값은 `/tmp` 제외를 표현하지 못하고 resume이 `writableRoots`를 비우므로 매 `turn/start`에 보낸다, AC-41). `ws` = 작업 폴더, `WW` = `{type: "workspaceWrite", writableRoots: [ws], networkAccess: false, excludeSlashTmp: true, excludeTmpdirEnvVar: true}`:

| 등급(3.7) · 사용자 정책 | `approvalPolicy` | `sandboxPolicy` | 실측 |
|---|---|---|---|
| write · Manual | `untrusted` | `WW` | 셸 쓰기 · 패치 모두 실행 전 승인 요청, 거절 = 파일 0(CX-8a · CX-2). 읽기(`ls`)도 묻는다. 승인한 쓰기 명령이 샌드박스 안에서 도는지는 **미시험**(CX-8a에서 승인한 것은 `ls`뿐) → D3b에서 폴더 밖 쓰기를 승인해 확인한다 |
| write · Auto/Full | `on-request` | `WW` | 폴더 안 쓰기는 묻지 않음, 밖은 샌드박스가 막고 승인 요청이 됨(CX-5b · CX-1) |
| read_only | `never` | `{type: "readOnly", networkAccess: false}` | 쓰기 `operation not permitted`, 요청 없음(CX-8) |

  쓰지 않는 조합: `readOnly` + `on-request`(승인된 요청이 샌드박스 없이 실행됐다, CX-8b), `granular`(폴더 안 쓰기가 승인 없이 실행, CX-8c), 제외 플래그 없는 `workspaceWrite`(폴더 밖 `/tmp` 형제 쓰기가 조용히 성공, CX-5c).

**승인**

- 요청: `item/commandExecution/requestApproval`(명령 문자열 · cwd · reason · `commandActions[]` · `availableDecisions`) · `item/fileChange/requestApproval`(id만, 경로 · diff는 같은 `itemId`의 앞선 `item/started`). `provider_request_id = "<threadId>:<turnId>:<itemId>"`(명령 승인에 `approvalId`가 있으면 덧붙인다). 같은 item의 두 번째 이후 승인 요청은 끝에 회차 `:<n>`을 붙여 새 열쇠를 쓴다(예: `…:<itemId>:2`). 재전송은 같은 회차의 열쇠를 유지한다. 이미 답한 열쇠의 다른 답이나 다시 열린 질문은 `question_stale`(409), 그 열쇠를 재사용한 도구 결정은 `deny/not_first_request`다. 연결마다 0부터 다시 세는 JSON-RPC id는 응답 · `serverRequest/resolved` 대조에만 쓴다.
- 결정: `accept` · `decline` · `cancel`(= 거절 + 턴 중단, CX-8b). `acceptForSession` · execpolicy 수정은 보내지 않는다. adapter가 다루지 않는 서버 요청(`item/permissions/requestApproval` · MCP elicitation 등)은 `decline`.
- Manual에서 읽기 요청의 자동 승인은 셋을 모두 만족할 때만: ① `commandActions[]`가 모두 알려진 읽기 종류(`listFiles` · `read` · `search`), ② 13.4 파서가 같은 문자열을 작업 폴더 안 읽기 전용 단일 명령으로 판정, ③ 그 `itemId`의 첫 요청. 아니면 정책 평가기 → 사용자. 같은 `itemId`의 두 번째 요청은 샌드박스 밖 재실행 요청으로 보고 카드에 "Runs without sandbox"를 붙이며 자동 승인하지 않는다(요청에 샌드박스 표시가 없다, CX-8b).
- Auto/Full의 승인 요청은 모두 샌드박스 밖 실행 요청이다. 자동 승인하지 않고 항상 사용자에게 묻는다(카드에 "Runs without sandbox"). 승인하면 그 명령은 샌드박스 없이 실행된다(CX-8b).
- 경로 lease(3.9): Manual에서 파일 변경은 승인 요청 전에 온 `item/started`의 경로로 잡고 양보를 강제한다. Auto/Full에서는 폴더 안 파일 변경에 승인 요청이 없으므로(CX-8c · CX-1) 양보시킬 수 없다 → 3.9의 사후 충돌 규칙(`conflict_run_id` · Stop new steps)만 적용한다. 셸 명령은 실행 전 경로를 알 수 없어 등급과 무관하게 사후 충돌 규칙이다.
- 열린 요청: `serverRequest/resolved {requestId}` 전이고 `thread/status/changed.activeFlags`에 `waitingOnApproval` · `waitingOnUserInput`이 있을 때만. 중단 · 턴 끝으로도 닫히며 `turn/completed` 뒤에 올 수 있다. 늦은 답은 오류 없이 무시되므로 항목 상태(`declined` · `completed`)로 결과를 확인한다.

**질문**

- 실험 기능 `default_mode_request_user_input`을 켠 기본 모드에서 `item/tool/requestUserInput {threadId, turnId, itemId, questions: [{id, header, question, isOther, isSecret, options}]}`이 온다(CX-3c). 60초 늦은 답도 같은 턴에서 받아들여졌고, 기다리는 동안 모델은 진행하지 않았으며 timeout은 없었다(CX-3d, `isBlocking` 값과 무관). 답 = `{answers: {<id>: {answers: [<label> | <글>]}}}`. `pending_question.structured = true`, `provider_request_id`는 승인과 같은 규칙.
- 기능을 켜도 질문이 `agentMessage.questions`(id 없음)로 오면(모델이 그 통로를 고를 수 있다, CX-3a): `structured = false`, `provider_request_id = "<threadId>:<turnId>:<agentMessage id>"`, 질문 카드에 선택지를 보이고 답은 턴이 살아 있으면 `turn/steer {expectedTurnId}`, 끝났으면 새 `turn/start`의 글로 보낸다(이 경로에서 모델은 약 139초 쉬다가 턴을 끝냈다, CX-3a).
- `isSecret` 질문은 3.6 비밀값 규칙(이번 실측에서 나타나지 않음).

**중단 · 결과**

- 중단: `turn/interrupt {threadId, turnId}` → `turn/completed{status: "interrupted"}`(14ms). 실행 중이던 명령 프로세스는 살아남았다(CX-4) → `cancel = "confirmed"`, `cancel_scope = "turn"`(5장). 사건은 계속 받아 정리한다.
- 결과 불명: `thread/resume` → `thread/turns/list {itemsView: "full"}`에서 `userMessage.clientId`(= 보낸 `clientUserMessageId`)를 찾는다. 있음 + `completed` = 끝, 있음 + `completedAt` 없음 · `interrupted` = 도중 종료, 없음 = 받지 않음 → 13.1(자동 재전송 없음, `not_sent`/`not_received`). 이전 app-server가 끝났는지 먼저 확인한다. 거절 · 진행 중 도구 항목은 기록에 남지 않는다.
- 접수 신호(3.2의 단계 `called`): `turn/started`.
- **지연(실측):** `turn/start` → `turn/started` 15–197ms, 짧은 턴 완료 2.6–4.2초.
- **미시험:** 공유 daemon과 기존 세션 부착(12장 1), `acceptForSession` 철회, `item/permissions/requestApproval`, `isSecret: true`, 환경변수를 비운 실행.
- **약관 gate LEGAL-CX:** OpenAI 문서는 app-server 인증이 상용 · 호스팅 서비스에 허용된 적이 없다고 적는다. 사용자 본인의 CLI 로그인을 로컬에서 쓰는 이 구조가 허용되는지 외부 사용자에게 켜기 전에 확인한다.

### 13.4 Taskforce 명령 파서 (Claude Code Bash · Codex 명령 공통)

명령 문자열을 실행 없이 판정해 "작업 폴더 안 읽기 전용 단일 명령"일 때만 자동 허용의 근거로 쓴다. 그 밖은 모두 정책 평가기 → 사용자다. 쓰기를 여는 근거로는 쓰지 않는다.

- 쉘 단어 분해(따옴표 처리)만 하고 평가 · 확장은 하지 않는다. 다음이 하나라도 있으면 판정 실패: 리다이렉션(`>` · `>>` · `<` · `<<`), 파이프 `|`, `;` · `&&` · `||` · `&`, `$(` · 백틱, 줄바꿈, 변수 대입 접두(`X=1 cmd`), `sudo` · `env` · `xargs` · `sh -c` 류.
- 허용 명령: `ls` · `cat` · `head` · `tail` · `wc` · `pwd` · `stat` · `file` · `grep` · `rg` · `find`. 목록에 없는 명령은 실패. **`git`은 자동 허용하지 않는다:** 전역 옵션(`-c` · `-C` · `--git-dir` · `--work-tree` · `--exec-path`)과 저장소 설정(`core.fsmonitor` · `core.pager` · `diff.external` · textconv)으로 `git status` · `git diff`도 임의 명령을 실행할 수 있고, 앞서 승인된 쓰기가 `.git/config`를 심을 수 있기 때문이다.
- **플래그는 명령별 허용 목록이 원칙이다**(목록 밖 플래그 = 실패, `--flag=value` · 붙여 쓴 짧은 플래그도 같은 규칙). D3c가 명령별 허용 플래그 표를 만든다. 표와 상관없이 다음은 항상 실패: `rg`의 `--pre` · `--pre-glob` · `--hostname-bin` · `-z`/`--search-zip`(외부 프로그램 실행), `find`의 `-exec` · `-execdir` · `-ok` · `-okdir` · `-delete` · `-fprint*` · `-fls`, `file`의 `-C`(파일 생성), `grep`의 `-r`로 작업 폴더 밖을 가리키는 경로.
- 경로 인자는 cwd 기준으로 정규화해 작업 폴더 안이어야 한다(`..`로 벗어나면 실패, 기호 링크는 실제 경로로).
- 명령 이름은 정확히 일치해야 하고(`./ls` · 경로가 붙은 이름은 실패), PATH에서 찾은 실제 실행 파일이 `/bin` · `/usr/bin`에 있을 때만 통과한다(PATH 앞쪽의 `~/.local/bin`은 사용자가 쓸 수 있는 폴더라 같은 이름의 다른 프로그램일 수 있다).
- D3c가 이 파서와 적대적 사례 단위 시험(예: `find . -delete`, `sed -i`, `cat a > b`, `ls; rm x`, `ls $(rm x)`, `rg --pre rm .`, `rg --pre=rm .`, `rg -z x`, `git -c core.fsmonitor=x status`, `git diff`, `file -C -m x`, `cat ../../etc/hosts`)을 소유한다. 판정 실패는 "자동 허용 안 함"일 뿐 거절이 아니다: 정책 평가기 → 사용자로 간다.

#### 13.4.1 정정 (D3c-1, 2026-10-14)

적대적 사례 목록(`handoffs/oa-d3c-adversarial-cases.md`)이 찾은 빈칸 P1–P12와 코디네이터가 더 찾은 P13–P15를 정한다. 위 13.4와 다르면 이 절이 이긴다.

1. **나누는 곳.** 판정(문자열 분해 · 명령 · 플래그 · 경로 모양)은 서버의 순수 함수가 한다(`src/lib/agents/command-parser.ts`, 플랫폼 원칙 "판정은 서버"). 파일 시스템 사실 두 가지는 Mac bridge가 확인한다: ① 명령 이름을 넘긴 `PATH`에서 찾은 실행 파일의 실제 경로(`realpath`)가 `/bin` · `/usr/bin` 바로 아래, ② 파서가 돌려준 경로마다 실제 경로(없는 경로는 있는 가장 가까운 조상의 실제 경로 + 나머지)가 작업 폴더의 실제 경로 안. 하나라도 아니면 자동 허용 안 함. bridge는 서버 판정 없이 자동 허용하지 않는다(서버가 1초 안에 답하지 않으면 defer).
2. **글자는 허용 목록으로 본다**(P3–P9 · P8). 따옴표 밖에 올 수 있는 글자는 영문자 · 숫자 · `-` `_` `.` `/` `,` `:` `@` `%` `+` `=`(단어 첫 글자 `=`는 zsh가 실행 파일 경로로 바꾸므로 실패) · 공백 · 탭뿐이다. 그 밖(`|` `&` `;` `<` `>` `(` `)` `{` `}` `[` `]` `$` 백틱 `\` `*` `?` `~` `!` `#` `^` 등 따옴표가 아닌 모든 기호)은 하나라도 있으면 실패 — 리다이렉트 `>|` · `<>`, 프로세스 치환, `$'…'` · `$"…"` · `$VAR`, 글로브, `~`, 함수 정의가 모두 여기서 막힌다. 작은따옴표 안은 `'` · 줄바꿈 말고 모두 글자 그대로, 큰따옴표 안은 `$` 백틱 `\` `!` 줄바꿈이 있으면 실패. 줄바꿈은 어디든 실패. ASCII가 아닌 글자는 Unicode 문자 · 결합 표시 · 숫자(L · M · N 분류)만 허용(한글 파일 이름), 제어 · 서식(양방향 · 폭 없는 글자) · 다른 공백 · 기호는 어디든 실패. NUL은 실패. 사용자 zsh 설정(Codex `-l`)에 기대지 않도록, 닫는 `'` 바로 뒤에 `'`가 오면 실패(`RC_QUOTES`), 따옴표 밖 `=`의 앞 글자(빈 따옴표 쌍은 건너뜀)가 `=` · `:`이면 실패(`MAGIC_EQUAL_SUBST`). 유니코드 정규화는 하지 않는다(경로 비교는 1-②의 실제 경로로). 문자열 4,096자 · 단어 64개를 넘으면 실패.
3. **cwd**(P13). 상대 경로는 요청의 `cwd`(Claude Code는 훅 입력 `cwd`, Codex는 승인 요청 `cwd`) 기준이다. `cwd`가 작업 폴더 안이 아니면 실패. 경로 단어에 `..` 성분이 하나라도 있으면 실패(기호 링크가 끼면 글자 정규화로 안팎을 정할 수 없다), `.` · 겹친 `/`는 정리한다. 경로 인자가 없는 `ls` · `rg` · 재귀 `grep`(`-r` · `-R`)은 `cwd`를 경로로 더한다(`index: null`) — macOS `grep -r`은 경로가 없으면 `.`을 뒤진다.
4. **실행되는 것 = 판정한 것**(P14, Claude Code). 자동 허용할 때 bridge는 `updated_input.command`를 파서가 돌려준 단어로 다시 만든다: 첫 단어는 1-①에서 확인한 실행 파일의 절대 경로, 경로 인자는 절대 경로, `index: null` 경로(3)는 끝에 명시 인자로 덧붙이고, 모든 단어는 작은따옴표로 감싼다. 그래서 사용자 셸의 alias · 함수(Claude Code Bash는 사용자 셸 설정을 가져온다), zsh 확장, cwd 차이가 실행에 끼지 않는다. Codex는 명령을 바꿀 수 없으므로 Manual의 샌드박스(13.3 `WW`)가 경계이고 파서는 그 안의 추가 방어다.
5. **Codex 래퍼**(P1). 승인 요청 `command` 문자열을 같은 규칙으로 분해해 정확히 `/bin/zsh` · `-lc` · 한 단어일 때만 그 단어를 다시 이 절 전체로 판정한다. 다른 셸(`/bin/bash` 포함) · `-c`만 · 인자 추가 · 중첩은 실패(bash 로그인 셸 사용자는 묻는다 — 실측 뒤 넓힌다). `-l`이 읽는 사용자 셸 설정(alias 포함)은 파서 밖이며 Manual 샌드박스가 쓰기를 막는다.
6. **명령과 플래그.** 허용 명령은 13.4의 11개 그대로, 첫 단어가 정확히 그 이름일 때만(`command` · `exec` · `time` · `nice` · `timeout` · `builtin` · `noglob` · `nohup` 같은 접두 래퍼는 목록 밖이라 실패, P2). 플래그는 macOS BSD 도구 기준 명령별 허용 표만. **첫 위치 인자(경로 · 패턴) 뒤에 `-`로 시작하는 단어가 오면 실패**(`find`의 식은 예외 — 아래 식 문법), `--`도 첫 위치 인자 앞에서만. 이유: `ls` · `cat` · `head` · `tail` · `wc` · `stat`은 첫 위치 인자에서 플래그 읽기를 멈추므로 뒤의 `-n /etc/hosts`는 플래그가 아니라 읽을 파일이고, `grep` · `file`은 순서를 바꾸지만 `POSIXLY_CORRECT`가 있으면 바꾸지 않는다 — 어느 쪽인지 문자열로 정할 수 없으니 묻는다(보안 검토 2026-10-14, `head a -n /etc/hosts`). 위치 인자 `-`(표준 입력)와 `--` 앞의 `tail` `+…`(옛 형식 `+5f`는 끝나지 않는다)도 실패. 긴 플래그는 정확한 이름만(줄임 불가). 기호 링크를 따라가는 플래그(`ls -L` · `stat -L` · `file -L` · `find -L` · `-H` · `-follow` · `grep -S` · `-O` · `rg -L`/`--follow`), 압축 해제(`grep -Z` · `-z` · `-J` · `file -z` · `-Z`), 끝나지 않는 플래그(`tail -f` · `-F`), 파일을 읽는 값(`grep -f` · `rg -f` · `--ignore-file` · `file -m` · `-f`)은 표에 넣지 않는다. 값이 경로인 플래그(`find -newer`)는 경로로 판정한다.
7. **Homebrew**(P10). `/opt/homebrew/bin` · `/usr/local/bin`의 실행 파일은 자동 허용하지 않는다(의도). 그래서 macOS에서 `rg`는 사실상 항상 묻는다. 사용자가 한 번 허용하면 세션 동안 허용하는 것은 0.2.x.
8. **lease 경로**(P11)는 lease 계층(D3c-2)이 실제 경로 + 볼륨이 대소문자를 무시하면 소문자로 정규화한다. 파서는 경로가 작업 폴더 안인지만 본다.
9. **Codex 교차 확인**(P12). Manual 자동 승인은 13.3의 세 조건 그대로이며 `commandActions`에 `unknown`이나 모르는 종류가 하나라도 있으면 읽기가 아니다. `commandActions`만 믿지 않는다.
10. **결과 모양**(P15). 성공 `{ok: true, wrapper: "none" | "zsh_lc", command, argv, paths: [{index, absolute}], implicitCwd}`, 실패 `{ok: false, reason}`(정해진 이유 코드만, 명령 글을 담지 않는다 — 로그 · 지표에 원문 0).
