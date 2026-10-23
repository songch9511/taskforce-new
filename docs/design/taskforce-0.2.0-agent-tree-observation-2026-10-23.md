# 프로젝트 세션 구조: 실제 이벤트 검증(P0)과 최소 구현 범위

2026-10-23 KST · [구조 조사](taskforce-0.2.0-agent-tree-research-2026-10-23.md) 8장의 P0 · 코드 기준 `origin/main` `3aa92dba`(C1–C5 · X1–X3), `9c9d8190`(C6–C9) · 구현 순서는 [구현 계획](taskforce-0.2.0-agent-tree-implementation-plan-2026-10-23.md)

**결론: 두 provider 모두 실제 이벤트만으로 부모·자식 트리를 정확히 그릴 수 있다.** 이름·시각·폴더로 추측할 필요가 없다. 다만 Taskforce가 지금 띄우는 Claude 세션은 Agent 도구가 꺼져 있어 자식이 생기지 않고, Codex는 실행 어댑터가 없다. 그래서 **첫 구현은 "이 Mac에서 관찰한 Claude 하위 에이전트를 프로젝트 안 세션 아래 트리로 보여 주기"로 확정한다.** 트리 데이터의 서버 저장 · Codex · 의존성 · 결과 revision은 첫 구현에 넣지 않는다. 서버에 더하는 것은 열기 지표 두 종류뿐이다(6장).

**사용자 결정 (2026-10-23):** 5장 범위로 확정. 읽기 · 쓰기 세션 모두 Agent 허용. 열기 이벤트 2개 추가.

제품 코드 · 설정 · DB · 배포는 바꾸지 않았다. 사용자 `~/.claude` · `~/.codex` 설정도 바꾸지 않았다(시험 세션 기록 파일만 평소처럼 생겼다).

## 1. 실제로 돌린 것

일회용 폴더(scratchpad `p0/ws`, 파일 둘)에서 실제 CLI를 돌려 원본 이벤트를 받았다. Claude는 Taskforce 어댑터와 같은 모양의 인자(`-p --output-format stream-json --verbose --include-hook-events --tools … --strict-mcp-config --setting-sources project`)에 `Agent`만 더했다. 질문 도구는 Taskforce `mcp__tf__ask_user`와 같은 이름의 가짜 MCP 서버, 승인 훅은 기록만 하는 PreToolUse 훅이다. Codex는 Taskforce 계약이 예정한 경로인 `codex app-server`(stdio JSON-RPC)에 직접 붙는 시험 클라이언트로 돌렸다.

| # | provider · 버전 | 경우 | 결과 |
|---|---|---|---|
| C1 | Claude Code 2.1.306 | 자식 2개 동시 | 성공 · $0.07 |
| C2 | 〃 | 자식 2개 동시 질문 + Bash 시도 (훅이 허락하지 않음) | 질문 둘 다 거절됨 · Bash 없음 확인 · $0.11 |
| C3 | 〃 | 자식 2개 동시 질문(훅이 허락) + 자식 안의 중첩 자식 | 성공 · 깊이 2 · $0.06 |
| C4 | 〃 | 자식이 질문을 기다리는 중 SIGINT | 자식 killed · $0.01 |
| C5 | 〃 | C3 세션 `--resume` | 같은 세션 id · task 이벤트 재전송 없음 · $0.06 |
| C6 | 〃 | **백그라운드** 자식의 질문에 훅이 `defer` (Taskforce의 질문 방식) → 답 resume | 세션이 멈추지 않음 · 자식은 답 없이 completed · resume 실패 · $0.12 |
| C7 | 〃 | **전경** 자식의 질문에 `defer` → 답 resume | C6과 같음 · $0.02 |
| C8 | 〃 | 자식 질문은 `deny`("부모에게 돌아가라"), 부모 질문은 `defer` → 답 resume | 자식(전경)이 필요한 질문을 보고 → 부모가 물음 → 프로세스가 `tool_deferred`로 끝남 → resume으로 답이 들어가 끝까지 감 · $0.05 |
| C9 | 〃 | C8을 **백그라운드** 자식으로 | 같은 흐름. `tool_deferred`는 두 번째 `result`(`result_index: 1`, 끝 알림 뒤)에 실림 · $0.06 |
| X1 | Codex CLI 0.162.1 app-server | 자식 2개 동시 + 중첩 자식 + 승인 요청 거절 | 성공 · 깊이 2 |
| X2 | 〃 | 자식 둘이 승인 대기 중 **부모 턴** interrupt | 부모만 멈춤 · 자식은 계속 대기 |
| X3 | 〃 | 자식 A **자식 턴** interrupt, 자식 B 승인 거절 | A 턴 interrupted · 나중에 부모가 A를 다시 깨움 |

원본 이벤트는 scratchpad(`p0/claude/run*.jsonl`, `p0/codex/run*.jsonl`)에만 있고 세션이 끝나면 지워진다. 회귀 시험이 필요하면 아래 2 · 3장의 필드만 남긴 fixture를 새로 만든다(경로 · 프롬프트 · 출력은 싣지 않는다).

추가로 사용자 Mac의 **실제 Claude 데스크톱 세션 기록**을 세었다(이 저장소 프로젝트 폴더): 32개 세션에 하위 에이전트 메타 파일 444개, 그중 중첩(부모 에이전트 있음) 68개.

## 2. Claude: 무엇을 얻을 수 있나

| 알고 싶은 것 | 얻을 수 있나 | 실제로 나온 필드 (C1–C5) |
|---|---|---|
| 자식 identity | 예 | `system/task_started.task_id` (= 자식 줄의 `agent_id`, 훅의 `agent_id`, 기록 파일 `agent-<id>`) |
| 부모 | 예, 결정적 | 깊이 1: `parent_task_id` **없음** + `spawn_depth: 1` = 세션 바로 아래. 깊이 2: `parent_task_id: <부모 task_id>` + `spawn_depth: 2` |
| 실행 시도 | 예 | `run_id` (task마다 다름), 부모 도구 호출 `tool_use_id` |
| 역할 · 맡긴 일 | 예 (모델이 쓴 글) | `subagent_type`, `description`, `prompt`(전문) |
| 진행 | 예 | `task_progress` (`last_tool_name`, `usage.tool_uses/duration_ms`) |
| 끝 · 결과 | 예 | `task_updated.patch.status` (`completed` · `killed`), `task_notification.status` (`completed` · `stopped`) + `summary`(자식 마지막 답) |
| 지금 도는 목록 | 예 | `background_tasks_changed.tasks` = 도는 **백그라운드** 일 전체 스냅샷 |
| 자식의 승인 요청 | 예 | 자식의 도구 호출도 **같은 PreToolUse 훅**을 지나고 입력에 `agent_id` · `agent_type`이 붙는다 |
| 자식의 질문 | 예 | MCP `tools/call`의 `_meta."claudecode/toolUseId"` → 같은 id의 `assistant` 줄 `agent_id`로 자식을 찾는다 |
| 권한 상속 | 예 (좁아짐 확인) | `--tools`에 없는 Bash는 자식에게도 없다 (C2: 자식이 "Bash 도구 없음" 보고) |
| 자식 하나만 중단 | **아니오** (지금 실행 방식) | `-p` + 인자 프롬프트에는 제어 채널이 없다. SIGINT는 세션 전체를 멈추고 자식은 `killed`(사유 user)로 끝난다 |
| 재개 뒤 관찰 | 기록으로만 | `--resume`은 지난 task 이벤트를 다시 보내지 않는다 |
| 지난 기록 · 외부 세션 | 예 (읽기만) | `~/.claude/projects/<폴더>/<세션>/subagents/agent-<id>.meta.json`: `parentAgentId`(중첩일 때만) · `spawnDepth` · `toolUseId` · `agentType` · `description` |

**계획 문서와 다르거나 새로 안 것:**

1. **자식은 기본이 백그라운드다.** 모델이 정하지 않으면(`requested.unset`) 백그라운드로 뜨고, 모델이 원하면 앞에서 돈다(C3의 중첩 자식, C4). 둘 다 같은 `task_*` 이벤트를 낸다(`is_backgrounded`만 다르다).
2. **한 프로세스가 `result`를 여러 번 낸다.** 첫 `result`(`result_index: 0`)는 "자식이 아직 돈다"는 중간 답이고, 자식이 끝날 때마다 `origin.kind: "task-notification"`인 `result`가 더 온다. **사용자에게 갈 마지막 답은 마지막 `result`에 있다**(C1: 두 값이 담긴 답은 `result_index: 2`). 프로세스는 백그라운드 자식이 다 끝나야 종료된다.
3. **init의 도구 이름은 `Task`, 호출 이름은 `Agent`다.** `--tools …,Agent`를 주면 init `tools`에는 `Task`로 나온다.
4. 끝 상태 낱말이 두 벌이다: `task_updated`는 `killed`, `task_notification`은 `stopped`.
5. 기록 메타의 `finished`는 444개 중 53개에만 있다. 끝 여부는 메타가 아니라 부모 기록의 끝 알림으로 정해야 한다(지금 reader가 그렇게 한다).
6. `result.subagent_stats`가 세션 단위 합계(spawned · completed · failed · killed · refused · max_depth)를 준다. 트리 검산에 쓸 수 있다.
7. **자식 안에서는 `defer`가 듣지 않는다(C6 · C7).** Taskforce의 질문 · 승인은 PreToolUse 훅이 `defer`를 돌려 프로세스를 `tool_deferred`로 끝내고, 답을 넣어 resume하는 방식이다. 자식의 도구 호출에 `defer`를 주면 그 호출은 결과 없이 끝나고 자식은 `completed`로 끝난다. 프로세스는 보류 표시 없이 끝나 resume도 실패한다("No deferred tool marker"). 전경 · 백그라운드 모두 같다. **그래서 자식은 묻거나 승인을 기다릴 수 없다.** C8 · C9처럼 자식에게 `deny`로 "부모에게 돌아가 보고하라"를 주면 부모가 대신 물었고, 부모의 `defer` → resume은 정상으로 돌았다.
8. 부모가 자식의 기록 파일(`~/.claude/projects/…/subagents/…`)을 Read로 열어 보려 했다(C6). 작업 폴더 밖이라 Taskforce 게이트는 이미 거절한다.

## 3. Codex: 무엇을 얻을 수 있나

| 알고 싶은 것 | 얻을 수 있나 | 실제로 나온 필드 (X1–X3) |
|---|---|---|
| 자식 identity | 예 | 자식 thread id |
| 부모 | 예, 결정적 | 부모 thread에 `item/started` `subAgentActivity {kind: "started", agentThreadId, agentPath}` — **이 item을 낸 threadId가 부모**다. `agentPath`는 `/root/agent_a/read_a`처럼 경로 전체 |
| 같은 작업 묶음 | 예 | 자식 turn의 `rootTurnId` = 루트 turn id |
| 역할 · 별명 | 예 (메타데이터) | `thread/read` · `thread/list`: `parentThreadId`, `source.subAgent.thread_spawn {parent_thread_id, depth, agent_path, agent_nickname, agent_role}` |
| 진행 · 끝 | 예 | 자식 thread의 `turn/started` · `turn/completed (status)` · `thread/status/changed`. 부모 쪽 `subAgentActivity` `completed` · `interacted` |
| 자식의 승인 요청 | 예, 자식별 | `item/commandExecution/requestApproval {threadId: 자식, turnId, itemId}` + 자식 `activeFlags: ["waitingOnApproval"]`. 두 자식의 요청이 동시에 열린다 |
| 자식 하나만 중단 | 예 | 자식 thread · turn에 `turn/interrupt` → 그 turn `interrupted`, 열린 승인 요청은 `serverRequest/resolved`로 닫힘 |
| 부모 중단이 자식도 멈추나 | **아니오** | X2: 부모 turn은 `interrupted`, 자식 둘은 8초 뒤에도 `active` + 승인 대기 |
| 자식 목록 조회 | 예 (experimental) | `thread/list {parentThreadId}` → 자식 둘 |
| 지난 기록 | 예 (읽기만) | `~/.codex/sessions/…/rollout-*-<thread>.jsonl` 첫 줄 `session_meta.source.subagent.thread_spawn` |

**계획 문서와 다르거나 새로 안 것:**

1. **자식 thread는 `thread/started`가 오지 않는다.** 부모 thread의 `subAgentActivity` item이 유일한 생성 신호다. 이 item을 놓치면(재연결 등) `thread/list {parentThreadId}`로 메운다.
2. **`forkedFromId` 규칙 정정:** spawn된 자식도 `forked_from_id = 부모`다(자식은 부모 맥락을 복제해 시작한다). 계획 문서 5장 2번 "forkedFromId는 분기 이력"만으로는 가를 수 없다. **`source.subAgent.thread_spawn`이 있으면 spawn, 없고 forkedFromId만 있으면 fork**로 판정한다.
3. **interrupted 자식은 끝난 것이 아니다.** X3: A를 멈춘 뒤 부모가 A에게 다시 말을 걸어(`subAgentActivity interacted`) A가 새 turn으로 끝까지 갔다. 부모에게는 `interrupted` 알림이 오지 않았다. 자식 상태는 "마지막 turn이 멈춤"이지 "자식 종료"가 아니다.
4. `collabAgentToolCall`(`wait`)의 `receiverThreadIds` · `agentsStates`는 이 버전에서 늘 비어 있었다. 트리 근거로 쓰지 않는다.
5. spawn 실패 하나가 stderr에만 남고 이벤트로 오지 않았다(X1 `collab spawn failed: no thread with id`). 실패한 위임은 화면에 안 보일 수 있다.
6. 역할(`executor`) · 별명(`Planck`)과 켜진 기능(`chronicle` 경고, 사용자 hooks)은 **사용자 `~/.codex` 설정**에서 왔다. 어댑터는 사용자 설정이 섞이지 않게 고정해야 하고, 역할 글은 표시용 메타데이터로만 쓴다.
7. Codex adapter 계약 초안(`~/.claude/worktrees/taskforce-020/handoffs/oa-codex-adapter-contract.md`, 2026-10-21, 코디네이터 로컬 파일)의 데몬 시험은 사용량 한도로 승인 요청을 보지 못했다. 이번 X1–X3은 자기 소유 stdio app-server(0.162.1)에서 모델이 답했고 승인 요청 · 거절 · 중단까지 봤다. 그 계약의 실측 표에 이 결과를 보탤 수 있다.

## 4. 지금 코드와 부딪히는 곳

| 어디 | 무엇이 깨지나 | 근거 |
|---|---|---|
| `ClaudeCodeLaunch.tools` · `initTools` | Agent가 없어 Taskforce가 띄운 세션에는 자식이 없다. 넣으면 init 자체 점검(정확한 집합)이 `Task` 때문에 실패한다 | 2장 3번 |
| `ClaudeEventMapper` | 첫 `result`에서 `turnCompleted`를 내고 뒤 사건은 task 줄만 옮긴다 → 자식을 쓰면 **"아직 도는 중" 중간 답이 마지막 답으로 저장되고 진짜 답은 버려진다** | 2장 2번 · 매퍼 주석 :125 |
| `ClaudeCodeProcess` 결과 타이머 | `result`를 볼 때마다 5초 뒤 SIGINT를 건다 → 첫 `result` 뒤에도 도는 백그라운드 자식과 마지막 `result`가 죽는다 | `ClaudeCodeProcess.swift:1227-1233` (독립 검토가 찾음) |
| `ClaudeStreamParser` · 매퍼의 글 | `assistant` 줄의 `agent_id`를 보지 않고 모든 글을 `message`로 낸다 → 자식 글이 부모 답으로 저장된다 | `ClaudeStreamParser.swift:168-192` · `ClaudeEventMapper.swift:217-222` (독립 검토가 찾음) |
| `ClaudeEventMapper.backgroundActions` | 전경 자식(`is_backgrounded == false`)을 무시 → 중첩 자식(C3)이 판에 안 보인다. 판에 올려도 스냅샷이 전경 일을 Stopped로 만든다 | 2장 1번 · `BackgroundTask.swift:163-168` |
| `BackgroundTask` · `BackgroundTaskList` | 평평한 목록. 부모 · 깊이 칸이 없다 | gateway 21-5장 |
| `ClaudeToolGate` L5 도구 집합 | `Agent`가 집합 밖이라 deny된다. `Agent` 입력 키(`subagent_type` · `run_in_background` · `model` · `isolation` …)를 검사하는 규칙이 없다. 메타에 `spawnedWithWorktree` · `worktreePath`가 있어 자식이 작업 폴더 밖 worktree에서 돌 수 있다 | 1장 실기록 메타 키 |
| `ClaudeToolGate`의 질문 · 승인 `defer` | 자식에게 `defer`를 주면 그 호출은 사라지고 세션은 멈추지 않는다. 또 L6 "spawn당 보류 하나"를 자식이 써 버리면 부모의 다음 보류가 거절된다 | 2장 7번 |
| `HookRequest`(훅 helper → bridge) | 키 집합이 고정이고 `agent_id`가 없다. 게이트가 부모 호출과 자식 호출을 가를 수 없다 | `HookWire.swift:108` |
| 질문 저장 (`question_conflict`) · 프롬프트 "한 번에 하나" | 두 자식이 2초 차이로 동시에 물었다(C3). 다만 자식 질문을 서버로 보내지 않으면(아래 5-1) 부딪히지 않는다 | 계획 6장 |
| 세션 Stop | Claude는 세션 전체만 멈춘다(맞음). Codex는 부모 turn을 멈춰도 자식이 남는다 → Codex에서 "Stop"은 자식 turn까지 돌아야 한다 | X2 |
| Codex 어댑터 | 없다(`BridgeHost` 등록 0). 예정 계약은 `--disable multi_agent` | 계획 5장 |
| 프로젝트 화면 | 프로젝트 → 이슈 목록 → 이슈 상세의 Sessions뿐. 프로젝트 단위로 세션을 모은 곳이 없다 | `EdgeIssueScreens.swift:241` |

## 5. 최소 구현 범위 (확정)

**한 문장:** 프로젝트를 열면 그 프로젝트 이슈들의 세션이 한곳에 모이고, 각 세션 아래에 그 세션이 실제로 띄운 Claude 하위 에이전트가 부모·자식 들여쓰기로 보인다. 데이터는 이 Mac이 관찰한 것만 쓴다.

### 5-1. 넣는 것

1. **Kit · 트리 모델 (순수)** — `BackgroundTask`에 `parentID`(nil = 세션 바로 아래) · `depth`를 더하고, `BackgroundTaskList`에서 트리를 만드는 순수 함수를 둔다.
   - 부모를 아직 모르는 자식(종료가 먼저 옴 · 시작 누락)은 세션 바로 아래 "부모 미확인"으로 두고, 시작이 오면 같은 id에 부모만 채운다. 자기 참조 · 순환은 세션 바로 아래로 내린다.
   - 이름 · 시각 · 폴더로 부모를 붙이지 않는다. 기본은 2단계까지 펴고, 실패 · 도는 분기는 접혀 있어도 개수로 보인다.
2. **Claude 스트림 → 트리** — `ClaudeStreamParser`가 `parent_task_id` · `spawn_depth`를 읽고, 매퍼는 전경 자식도 판에 올린다. 상태는 기존 낱말(Running · Done · Failed · Stopped)을 그대로 쓴다(`killed` · `stopped` → Stopped).
3. **Claude 데스크톱 기록 → 트리** — `ClaudeAppTranscriptReader` 쪽에서 `subagents/agent-<id>.meta.json`의 `parentAgentId` · `spawnDepth`만 읽는다. 끝 여부는 지금처럼 부모 기록의 끝 알림으로 정한다. 기존 `BackgroundTaskTail` 보안 규칙(선언한 필드만, `O_NOFOLLOW`, uid 확인)을 그대로 따른다.
4. **Taskforce가 띄우는 Claude 세션(읽기 · 쓰기 둘 다)에 Agent 허용** — 아래가 함께 들어가야만 켠다.
   - init 점검 집합에 `Task`를 넣는다(호출 이름은 `Agent`).
   - 게이트가 `Agent` 호출을 검사한다: 아는 키만, `isolation`(worktree) · 사용자 정의 에이전트 거절, `subagent_type`은 init이 알린 내장 에이전트만.
   - 훅 helper가 `agent_id`를 bridge로 넘긴다(훅 wire 버전 올림).
   - **자식은 묻지도, 승인을 기다리지도 않는다.** 게이트는 자식(`agent_id` 있음)의 호출에 `defer`를 내지 않는다. 지금 `defer`가 될 호출(질문 · 서버가 사용자 승인을 요구한 쓰기 · Bash)은 `deny`와 "부모에게 돌아가 필요한 것을 보고하라"는 이유를 준다. 그러면 부모가 묻는다(C8 · C9 실측). 자식의 거절은 L6 "spawn당 보류 하나"를 쓰지 않는다. 서버가 바로 허락하는 호출과 작업 폴더 안 읽기는 지금처럼 허락한다. 그래서 질문은 늘 부모가 하나씩 하고, 서버 질문 계약 · DB는 그대로다.
   - 시스템 프롬프트 v3: "하위 에이전트는 사용자에게 묻거나 승인을 기다릴 수 없다. 필요하면 하위 에이전트의 보고를 받아 직접 물어라."
   - 매퍼: 첫 `result`에서 턴을 끝내지 않는다. **프로세스의 마지막 `result`**로 턴을 판정하고(보류 `tool_deferred`도 마지막 `result`에 온다, C9), 그 답을 마지막 답으로 쓴다. 중간 답은 진행으로만 둔다.
5. **Mac 화면**
   - 프로젝트 이슈 목록 맨 위에 **Sessions** 묶음: 그 프로젝트 이슈들의 세션을 합쳐 보인다(한 세션이 여러 이슈에 걸치면 한 번만). 기존 `SessionRow`를 쓴다.
   - 세션 행을 펴면 하위 에이전트 트리. 줄 = 모델이 쓴 `description` + 상태 낱말. 줄을 누르면 기존 옆줄의 에이전트 꼬리 보기, 세션 행을 누르면 기존 세션 패널.
   - 세션 패널 옆줄(gateway 21-5)도 같은 트리로 그린다.
   - 자식 줄에는 Stop · 답하기 단추를 두지 않는다. Stop은 지금처럼 세션 단위다.
   - 새 문구는 최소로 둔다: "부모 미확인"에 해당하는 한 낱말만 승인받는다.
6. **시험**
   - C1 · C3 · C4 표본에서 필드만 남긴 fixture로 매퍼 · 트리 순수 시험을 만든다: 깊이 2, 동시 2, 종료 먼저 도착, 중복 줄, 여러 `result`, killed.
   - C6–C9 표본으로 게이트 · 매퍼 시험: 자식 질문 → deny, 부모 질문 → defer, 보류가 두 번째 `result`에 오는 경우.
   - 실제 Claude E2E(서명 앱): 자식 2 + 중첩 1이 화면 트리와 일치하고, 마지막 답이 맞고, 자식이 필요한 답을 부모가 대신 물어 답이 들어간다. 자식의 Edit · Bash가 승인 없이 돌지 않는 부정 사례.

### 5-2. 넣지 않는 것 (다음 단계로)

| 빼는 것 | 언제 | 왜 지금이 아닌가 |
|---|---|---|
| Codex | 다음: app-server 어댑터 + `subAgentActivity` 트리 + 자식별 승인 · 자식 turn 중단 | 어댑터 자체가 없다. 관찰 필드는 이 문서 3장으로 충분히 확인됐다 |
| 트리의 서버 저장 · iPhone · 다른 Mac | V2 | 세션 보기 V1과 같은 원칙(로컬만). 새 agent 이벤트 종류 0으로 화면 가치를 먼저 본다 |
| 자식이 직접 묻기 · 서버의 동시 질문 | Codex 어댑터 때 | Claude는 자식 안에서 `defer`가 듣지 않아 부모가 묻는 것이 유일한 길이다. Codex는 자식별 승인이 열린 채 기다릴 수 있어(X2) 그때 정한다 |
| 자식 하나만 중단 · 자식에 직접 입력 | Codex 어댑터 때 (Codex만) | Claude는 지금 실행 방식에 제어 채널이 없다 |
| 작업 의존성 · 결과 revision · stale | 계획 P4 | 저장 모델이 없다(`action_dependencies` 미구현) |
| 호출 그래프 · 비용 | 계획 P5 | 트리로 부족하다는 증거가 아직 없다 |

### 5-3. 합격 기준

- 트리의 모든 실선은 provider id(`parent_task_id` · `parentAgentId` · `spawn_depth`)에서 왔다. 추측으로 그린 선 0.
- 자식을 쓴 턴의 마지막 답이 마지막 `result`의 답과 같다. 중간 답이 마지막 답으로 저장된 사례 0.
- 자식의 질문 · 승인 대기가 서버로 간 사례 0. 자식이 필요한 답은 부모가 물어 들어가고, 그 사이 질문이 사라지거나 덮어써진 사례 0.
- 자식의 Edit · Write · Bash가 부모와 같은 승인 규칙 밖에서 돈 사례 0.
- 세션 Stop 뒤 도는 자식은 모두 Stopped. 끝을 못 본 자식을 Done으로 보이는 사례 0.
- 50개 자식에서 접기로 찾을 수 있고, 갱신 중에도 선택 · 스크롤이 튀지 않는다(gateway 21-7의 150줄 창 규칙과 같이 시험).

## 6. 정한 것 (사용자 2026-10-23)

1. **Agent 허용 범위: 읽기 · 쓰기 세션 모두.** 자식은 부모의 `--tools` 안에서만 움직인다(C2 실측). 읽기 세션의 자식도 Edit · Write · Bash가 없다.
2. **측정: 열기 이벤트 2개를 더한다.** "프로젝트 Sessions 묶음을 편 날"과 "하위 에이전트 줄을 연 날". 이름 · id · 글 · 개수는 싣지 않는다. 모양은 기존 `claude_app_session_opened`(20261206000000)를 따른다: v2 route가 서버 권한으로 남기고 하루 한 번만. 세부는 [구현 계획](taskforce-0.2.0-agent-tree-implementation-plan-2026-10-23.md) PR-T3s.
3. **질문 설계 변경(이 문서의 C6–C9 결과, 확정 범위 안의 보정):** 처음 적은 "MCP helper에서 자식 질문 줄 세우기"는 버린다. 자식 안에서는 Taskforce의 질문 방식(`defer`)이 듣지 않기 때문이다. 자식 질문은 거절하고 부모가 묻는다(5-1의 4).
