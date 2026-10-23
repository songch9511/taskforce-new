# 프로젝트 세션 구조: PR 단위 구현 계획

2026-10-23 KST · 기준 `origin/main` `9c9d8190` · 범위는 [실측 문서](taskforce-0.2.0-agent-tree-observation-2026-10-23.md) 5 · 6장(사용자 확정 2026-10-23) · 독립 검토(critic, Opus) 1회 반영

**한 줄:** 네 PR로 낸다. ① 트리 모델과 Claude 관찰(Mac만) → ② Taskforce가 띄우는 Claude 세션에 Agent 허용(보안 검토 필수) · ③ 서버 열기 지표 · ④ 프로젝트 화면의 Sessions 묶음. ①이 끝나면 사용자의 Claude 데스크톱 세션에서 이미 트리가 보인다. Codex는 기존 Codex adapter 계약에 합쳐 그 뒤에 낸다.

이 문서는 계획이다. 코드는 바꾸지 않았다. PR마다 코디네이터가 `handoffs/oa-agent-tree-<pr>-contract.md` · `-scope.txt`를 만들고 나서 작업자를 띄운다(설계 README의 규칙). 줄 번호는 `9c9d8190` 기준이고, 경로는 따로 적지 않으면 `apple/Packages/TaskforceKit/Sources/` 아래다.

## 1. 한눈에

| PR | 이름 | 사용자에게 보이는 것 | 앞에 필요한 것 | 검토 |
|---|---|---|---|---|
| **T1** | 트리 모델 · Claude 관찰 | 세션 패널 옆줄의 백그라운드 목록이 부모 · 자식 트리로 바뀐다. Claude 데스크톱 세션은 바로 실데이터(이 Mac 기록에 하위 에이전트 444개, 중첩 68개) | 없음 | 코드 · 보안(기록 파일 읽기) |
| **T2** | Agent 허용 | Taskforce가 띄운 Claude 세션이 하위 에이전트를 쓴다. 자식이 필요한 질문은 부모가 대신 묻는다 | T1 | 코드 · **보안 필수** · 실제 CLI 재실측 |
| **T3s** | 열기 지표(서버) | 없음 (지표 두 종류가 쌓일 준비) | 없음 | 코드 · DB/RLS · 운영 적용 승인 |
| **T3m** | 프로젝트 Sessions | 프로젝트 이슈 목록 맨 위에 Sessions 묶음과 세션별 트리 | T1 · T3s | 코드 · 시각 확인 |
| C | Codex 트리 | Codex 세션의 하위 에이전트 트리 · 자식별 승인 · 자식까지 멈추는 Stop | Codex adapter(D3b) | 기존 계약의 검토 규칙 |

```text
T1 ──┬──> T2
     └──> T3m <── T3s
T3s는 언제든 시작할 수 있다. T2와 T3m은 파일이 갈려 나란히 갈 수 있지만,
앱 시험 파일을 더하는 PR끼리는 apple/Taskforce.xcodeproj/project.pbxproj가,
T3s · T3m은 docs/FEATURE_MAP.md가 겹친다: 나중에 병합하는 쪽이 main을 받아 푼다.
```

## 2. PR별 상세

### T1. 트리 모델 · Claude 관찰 (Mac Kit + 옆줄)

**할 일**

1. `BackgroundTask`에 `parentID: String?`(nil = 세션 바로 아래) · `depth: Int?` · `foreground: Bool`. `BackgroundTaskEvent.started`에 같은 값.
2. `BackgroundTaskList`에 트리 투영 순수 함수: 부모 미확인 자식은 세션 바로 아래(표시만 다르게), 시작이 늦게 오면 같은 id에 부모만 채운다, 자기 참조 · 순환 · 다른 세션 부모는 세션 바로 아래. 정렬은 지금 규칙(running → failed → 나머지, 새것 먼저)을 형제 안에서만. 상한 256개는 그대로.
3. **스냅샷 규칙 고침:** `.snapshot`은 도는 일 가운데 목록에 없는 것을 Stopped로 만든다(`SessionView/BackgroundTask.swift:163-168`). `background_tasks_changed`는 **백그라운드 일만** 싣는다. 그래서 전경으로 시작한 일(`foreground == true`)은 스냅샷으로 멈추지 않고, 끝 알림이나 프로세스 거두기로만 끝난다.
4. `ClaudeStreamParser`: `task_started.parent_task_id` · `spawn_depth`를 읽는다(id 규칙은 지금 `[A-Za-z0-9_-]{1,64}`).
5. `ClaudeEventMapper.backgroundActions`: **에이전트 일(`task_type == local_agent`)은 전경도 판에 올린다**(지금은 `foregroundTasks`로 버린다). 전경 Bash는 지금처럼 무시한다. 진행(progress) 의미는 바꾸지 않는다(`killed → Stopped`는 이미 있다, `ClaudeEventMapper.swift:418`).
6. **기록에서 트리 만들기.** 지금 reader는 본 기록의 비동기 에이전트만 시작으로 센다(`Bridge/ExternalSessions/ClaudeAppTranscriptReader.swift:628`). 전경 에이전트와 **깊이 2 이상**은 본 기록에 시작 줄이 없다(부모 에이전트의 `subagents/agent-<id>.jsonl`에 있다). 그래서:
   - 세션 폴더의 `subagents/`를 **이름만** 훑는다: `agent-<id>.meta.json` 꼴만, 256개 상한, 폴더 사슬 검사는 `BackgroundTaskTail`과 같은 규칙(`lstat` · uid · 그룹/모두 쓰기 권한 없음 · `realpath` 같음).
   - 메타 파일은 `ExternalSessionFileSystem.read`(`O_NOFOLLOW` · fd 소유자 · `F_GETPATH`)로 4 KiB까지, 선언한 칸 `parentAgentId` · `spawnDepth` · `description` · `requestShape`만 읽는다. 깨진 파일 · 없는 칸은 부모 미확인.
   - 끝 여부는 지금처럼 본 기록의 끝 알림으로 정한다(`finished`는 444개 중 53개에만 있어 읽지 않는다). 끝 알림이 없는 전경 에이전트는 부모 에이전트 기록의 끝 신호 · 세션이 닫힌 것으로만 끝낸다. 모르면 Running이 아니라 "끝 미확인"(Stopped와 같은 낱말)으로 둔다.
7. Taskforce 패널: 앱을 다시 띄워 판이 비어도 `LocalTranscriptLookup`이 찾은 기록에서 6과 같은 방법으로 트리를 만든다.
8. **트리 줄 · 펼침 상태를 한 벌만 만든다.** 트리 줄 컴포넌트는 `TaskforceUI`에, 펼침 상태 모델은 Kit에 둔다. 옆줄(`EdgeSidePaneViews` · `EdgeSidePaneModel`)이 첫 사용처이고, T3m은 같은 것을 다시 쓴다. 기본 2단계 펼침, 접힌 분기는 "도는 n · 실패 n"만 글자로. 줄을 누르면 지금의 에이전트 꼬리 보기. 접근성은 21-5의 Expanded · Collapsed 값.
9. 새 문구 한 개("부모 미확인"에 해당하는 영어 낱말, 디자인 승인).

**범위 파일(초안)** — `TaskforceKit/SessionView/BackgroundTask*.swift`, `TaskforceKit/SessionView/SessionViewCopy.swift`, `TaskforceKit/Bridge/ClaudeCode/ClaudeStreamParser.swift`, `TaskforceKit/Bridge/ClaudeCode/ClaudeEventMapper.swift`(백그라운드 줄 부분만), `TaskforceKit/Bridge/ExternalSessions/ClaudeAppTranscript*.swift`, `TaskforceUI/` 새 트리 줄 파일, `apple/Taskforce/Mac/Edge/EdgeSidePane*.swift`, 같은 이름의 시험, `apple/Taskforce.xcodeproj/project.pbxproj`(새 앱 시험이 있으면), `docs/agent-gateway.md`(21-5에 트리 절).

**시험** — 순수: 깊이 2 · 동시 2 · 종료 먼저 · 중복 시작 · 순환 · 다른 세션 부모 · 256개 상한 · 전경 일이 스냅샷으로 멈추지 않음. 실측 표본(C1 · C3 · C4)에서 **필드만 남긴** fixture(경로 · 프롬프트 · 요약 글 제거). 기록 읽기: 기호 링크 · 남의 uid · 그룹 쓰기 폴더 · 큰 파일 · 깨진 JSON · 257개째 무시. 앱: 50개 자식에서 갱신 중 선택 · 스크롤이 튀지 않는다(`SessionEntriesWindowTests`와 같은 방식).

**완료 기준** — 이 Mac의 실제 Claude 데스크톱 세션 하나(중첩 있는 것)를 열어 옆줄 트리가 메타 파일의 `parentAgentId`와 일치하고, 전경 에이전트도 보인다. 서버 · DB 변경 0, 새 지표 0.

### T2. Agent 허용 (Mac adapter + 서버 registry 근거)

**할 일**

1. **버전 문턱:** 자식 관련 사실(훅의 `agent_id`, `parent_task_id`, 여러 `result`, 자식 안 `defer` 무시)은 2.1.306 · 2.1.308에서만 봤다. 지금 범위는 `>=2.1.241 <2.2`(`TaskforceKit/Bridge/ClaudeCode/ClaudeCodeLaunch.swift:9`). **probe 버전이 2.1.306 이상일 때만 `Agent`를 넣는다**(아래면 지금 도구 집합 그대로). registry 근거에 그 문턱을 적는다.
2. `ClaudeCodeSupport.tools`: 쓰기 · 읽기 등급 둘 다 `Agent`. `initTools`는 `Task`로 대조한다(init은 `Task`로 알린다). init `agents` 목록을 `ClaudeInitInfo`가 읽게 하고(`ClaudeStreamParser.swift:129-133`은 지금 읽지 않는다), **코드에 박은 내장 이름 집합의 부분집합**이 아니면 자체 점검 실패로 띄우지 않는다.
3. **훅 wire:** `HookWire.readTools`(`TaskforceAgentWire/HookWire.swift:24`)에 `Agent`를 더한다. 지금은 집합 밖이라 `strippedInput`이 `{}`를 보내서(:28) 게이트가 `Agent` 입력을 볼 수 없다. `prompt`는 다른 본문 칸처럼 `prompt_len`으로 바꾼다(사용자 글이 섞일 수 있고 소켓 줄 상한이 256 KiB다). 훅 입력의 `agent_id` · `agent_type`을 `HookRequest`로 넘긴다(키 집합 · 버전 `v` 올림, 모르는 값은 지금처럼 거절). 값은 게이트 판단에만 쓰고 서버로 보내지 않는다.
4. **게이트(`ClaudeToolGate`)**
   - L5 도구 집합에 `Agent`. 입력은 `description` · `prompt_len` · `subagent_type` · `run_in_background`만, `isolation` · `model` · 그 밖의 키는 deny(worktree 자식 · 비싼 모델 선택을 막는다). `subagent_type`은 2의 내장 집합만.
   - spawn당 `Agent` 호출 수 상한과 깊이 상한(예: 8개 · 깊이 2, 넘으면 deny)을 둔다. 지금은 펼침을 막는 것이 없다.
   - **자식 예외는 한 곳에서:** 결정을 다 낸 뒤 감싸서, 요청에 `agent_id`가 있고 결과가 `.defer`이면 이유와 상관없이 `deny` + 정해진 영어 이유("Subagents cannot ask the user or wait for approval. Stop and report what you need; the main agent will ask.")로 바꾸고 `outcome.deferred`를 비운다(비우지 않으면 `TaskforceKit/Bridge/ClaudeCode/ClaudeCodeProcess.swift:938-940`이 `deferIssued`를 켠다). 그 대상에는 질문 · 승인뿐 아니라 로컬 defer 전부(`unknown_input` · `hard_link` · `secret_in_command` · `over_limit` · `not_attached` · `server_error` · `unknown_response` · `parse_check_failed` · `allow_unexpected`, `ClaudeToolGate.swift:239-666`)가 들어간다. 또 자식 요청은 L6 "spawn당 보류 하나" 검사(:208)보다 먼저 이 규칙을 탄다(자식이 L6에 걸려 부모의 보류를 막지 않게).
5. **자식 글은 부모 대화가 아니다.** 지금 parser는 `assistant` · `user` 줄의 `parent_tool_use_id` · `agent_id`를 보지 않고(`ClaudeStreamParser.swift:168-192`), 매퍼는 모든 글 블록을 `.message`로 낸다(`ClaudeEventMapper.swift:217-222, 382`). 그대로면 자식의 글이 부모의 답으로 서버에 저장된다. parser가 그 표시를 읽고, 매퍼는 자식 줄을 `message` · `accepted` · 글 모으기에서 뺀다. 자식의 도구 호출 대조(④)와 산출물(Edit · Write 결과)은 그대로 센다.
6. **프로세스 수명:** 지금은 `result`를 볼 때마다 5초 뒤 SIGINT 타이머를 건다(`ClaudeCodeProcess.swift:1227-1233`, `exitAfterResult`). 자식은 기본이 백그라운드라 첫 `result` 뒤에도 돌고, 이 타이머가 그 자식과 마지막 `result`를 죽인다. 또 다음 `result`가 앞 타이머를 취소하지 않고 덮는다. 고침: 타이머는 **마지막으로 본 `background_tasks_changed` 스냅샷이 비었을 때만** 걸고, 새로 걸기 전에 앞 것을 취소한다. 대신 spawn 전체에 벽시계 상한(예: 30분, 넘으면 SIGINT)을 둔다.
7. **턴 판정:** 첫 `result`에서 `terminal`로 가지 않는다. 각 `result`를 "지금까지의 마지막"으로 갈아 끼우고, 프로세스가 끝날 때 마지막 것으로 `turnCompleted` · 보류(`tool_deferred`, C9처럼 두 번째 `result`에 올 수 있다) · 실패를 정한다. **글은 오는 순서대로 낸다**(중간 답 "아직 도는 중"도 부모의 글이라 대화에 남는다. 마지막 답이 그 뒤에 붙는다). 두 번째 이후 `system/init`은 같은 spawn의 재init이다: 서버 사건(`inputReached` · `sessionBound`, `ClaudeEventMapper.swift:197-201`)을 다시 내지 않고, init 실패 검사(`initFailure`)는 매번 한다.
8. 시스템 프롬프트 v3(`ClaudeCodePrompts`): v2 + "Subagents you launch cannot ask the user or wait for approval. If one reports that it needs something, ask the user yourself with mcp__tf__ask_user."
9. 맞춰 고칠 곳: `FakeClaudeCode/main.swift:341`의 `--tools` 검사와 시나리오 셋(백그라운드 자식 2 + 여러 `result` · 자식 질문 거절 → 부모 보류 · killed), 공유 fixture `apple/Packages/TaskforceKit/Tests/TaskforceKitTests/Fixtures/bridge-v1/claude-code-adapter.json`(Swift golden 시험과 `src/lib/bridge/swift-fixtures.test.ts`가 대조한다), 훅 wire 버전을 고정한 `apple/Packages/TaskforceKit/Tests/TaskforceAgentWireTests/HookRereview7Tests.swift`.
10. 서버: `src/lib/agents/registry.ts`의 Claude 근거 문장(읽기 등급 "init tools exactly Read Glob Grep + ask_user")을 새 실측과 버전 문턱으로 바꾼다. `docs/rollouts/claude-code-r1-evidence.md`에 재실측 절.
11. 문서: Assistant 계약 13장의 `--tools` 줄 · agent-gateway 16장(D3a) · 21-5의 "첫 `result` 뒤" 절.

**실제 CLI 재실측(병합 전, 2.1.306)** — 처음에 확인할 두 가지: 자식 훅의 `tool_name`이 `Agent`인지 `Task`인지, 자식 훅의 `session_id`가 부모와 같은지(`HookSocketServer.swift:249`는 다르면 거절한다). 그다음: R1-02/02b(읽기 등급 자식에게도 Edit · Write · Bash 없음), R1-03 계열(자식의 작업 폴더 밖 Read · Write 거절), 자식 질문 → 부모 보류 → 답 resume(C8 · C9), 자식의 Edit가 서버 승인 요구일 때 deny되고 파일 해시 그대로, 자식 2 + 중첩 1의 마지막 답이 사용자에게 간 답과 같고 자식 글이 대화에 없음, 세션 Stop 뒤 자식 모두 Stopped, CLI가 훅 전에 `Agent`를 거절하는 경우(없는 `subagent_type`)에 턴이 죽지 않는지(죽으면 ④의 거절 허용 목록에 `Agent`를 더한다, `ClaudeEventMapper.swift:257`), 자식 둘의 도구 호출이 한 줄 훅 잠금(`ClaudeCodeProcess.swift:886-903`) 뒤에서 4초 예산(`HookWire.budget`)을 넘겨 `bridge_timeout`으로 거절되는지. **열린 확인 하나:** 백그라운드 자식이 도는 중에 부모가 보류로 프로세스를 끝내면 그 자식이 어떻게 되는지. 죽는다면 보류 전 기다리라는 문장을 프롬프트 v3에 더한다.

**범위 파일(초안)** — `TaskforceKit/Bridge/ClaudeCode/ClaudeCodeLaunch.swift` · `ClaudeToolGate.swift` · `ClaudeStreamParser.swift` · `ClaudeEventMapper.swift` · `ClaudeCodeProcess.swift` · `ProcessIdentity.swift`, `TaskforceKit/Bridge/HookSocketServer.swift`(필요하면), `TaskforceAgentWire/Hook*.swift`, `tf-agent-hook/**`, `FakeClaudeCode/**`, 시험(`Tests/TaskforceKitTests/ClaudeCode/*` · `Tests/TaskforceAgentWireTests/*` · `Fixtures/bridge-v1/claude-code-adapter.json`), `src/lib/agents/registry.ts` · `src/lib/bridge/swift-fixtures.test.ts` · registry 시험, `docs/rollouts/claude-code-r1-evidence.md`, `docs/agent-gateway.md`, `docs/design/taskforce-0.2.0-assistant-contract-2026-10-12.md`.

**완료 기준** — 위 재실측 전부 통과 기록, 보안 검토 승인(게이트 · 훅 wire · 자식 권한 · 프로세스 수명), `npm run lint` · `typecheck` · `test`(TS가 바뀌므로), Kit `swift test` · 앱 `xcodebuild test`. `--max-budget-usd 25`가 자식까지 합친 값인지 재실측의 `total_cost_usd`로 확인해 근거에 적는다.

### T3s. 열기 지표 (서버)

**모양** — 앞선 `claude_app_session_opened`(20261206000000)와 같다: 본문에 칸이 없고, 앱이 v2 route로 알리면 route가 서버 권한으로 `metric_events`에 남기며, 같은 날(UTC) 두 번째는 조용히 넘긴다.

| 종류 | 언제 | route |
|---|---|---|
| `project_sessions_opened` | 프로젝트 이슈 목록의 Sessions 묶음이 행 1개 이상으로 펼쳐 보인 날 | `POST /api/v2/agent-tree/project-sessions-opened` |
| `subagent_row_opened` | 하위 에이전트 줄을 눌러 꼬리 보기를 연 날 (옆줄 · 프로젝트 어디서든) | `POST /api/v2/agent-tree/subagent-opened` |

**할 일**
- 새 마이그레이션 하나(번호는 원장에 예약: 지금 최고 `20261207000000`, 후보 `20261208000000`): 종류 검사를 바로 앞 목록 전체 + 두 종류로 다시 만들고, 종류마다 하루 한 번 부분 unique 인덱스. 맨 앞에 **적용 순서 가드**(앞 마이그레이션의 종류가 검사에 있는지 보고 없으면 멈춤, `20261207000000_claude_app_chats.sql:51-54`와 같은 모양).
- 지표 등록부 `src/lib/metrics/agents.ts`(:69 근처)에 두 종류, 관리자 지표 화면 이름표 `src/app/admin/metrics/page.tsx`(:61 근처).
- `contract.ts`에 두 스키마(`z.strictObject({})`). route 둘: `authenticateRequest`, 쿠키 쓰기는 CSRF 확인, 앞선 route와 같은 문(`src/lib/api/external-sessions.ts:144, 159`의 `betaAllowed` 확인과 adapter 플래그 `AGENT_ADAPTER_CLAUDE_CODE_ENABLED`), 꺼져 있으면 404.
- 시험: route · CSRF · 같은 날 두 번 · 다른 사용자 · 플래그 꺼짐 · `tests/metrics/agent-event-registry.test.ts` 최신 목록 대조 · `tests/db/` RLS(앱이 이 종류를 직접 넣지 못함) · 적용 순서 가드.

**완료 기준** — lint · typecheck · test · `test:pg`(마이그레이션이 바뀌므로). **운영 DB 적용은 병합 직전 사용자 승인 뒤 `supabase db query --linked -f`로 한 번**(db push 금지). 적용 뒤 종류 검사 · 인덱스 존재 확인 SELECT를 원장 상태 열에 적는다.

### T3m. 프로젝트 Sessions 묶음 (Mac 화면)

**할 일**

1. 프로젝트 이슈 목록(`IssueListBody`, 프로젝트 모드) 맨 위에 **Sessions** 묶음: 그 프로젝트의 열린 이슈 · 오늘 끝난 이슈에 묶인 세션의 합집합(같은 세션은 한 번, 순서는 지금 `sessions(of:)` 규칙, `apple/Taskforce/Mac/Edge/EdgeShellModel.swift:1115`). 세션이 없으면 묶음이 없다(빈 칸 · 안내 문구 없음).
2. 행은 기존 `SessionRow`. 행 끝에는 이미 Ask 단추가 있다(`TaskforceUI/ProjectRow.swift:69-120`). **트리 펼침은 행 앞쪽의 펼침 표시**로 두고, 펼친 아래에 T1의 트리 줄 컴포넌트를 그대로 쓴다. 행을 누르면 기존 세션 패널, 자식 줄을 누르면 그 세션 패널의 옆줄 꼬리 보기로 간다.
3. **열리지 않은 세션의 트리 채우기:** 지금 판과 기록 합치기는 열린 패널의 고리에서만 돈다(`apple/Taskforce/Mac/Edge/EdgeSessionPanel.swift:186-199`). 그래서 프로젝트 목록에서는 **사용자가 세션 행을 펼칠 때 그 세션 하나만** T1의 기록 읽기(메타 이름 훑기 + 본 기록 끝 알림)를 한 번 한다(메인 밖, 세션당 메타 256개 · 본 기록 꼬리 2 MiB 상한, 같은 세션은 접었다 펴도 30초 안에는 다시 읽지 않는다). 이 Mac에서 도는 중인 세션은 판의 실시간 값을 먼저 쓴다. 접힌 행에는 판에 이미 있는 값으로만 "도는 n"을 보이고, 없으면 아무것도 보이지 않는다(목록을 그릴 때 기록 파일을 읽지 않는다).
4. 한 세션이 다른 프로젝트 이슈에도 묶여 있으면 행 둘째 줄에 기존 낱말로 공유임을 보인다(새 문구가 필요하면 디자인 승인).
5. 지표 호출: 묶음이 처음 펼쳐 보일 때 · 자식 줄을 열 때 T3s route를 한 번씩. 실패는 조용히 버린다(지표가 화면을 막지 않는다).
6. 펼침 상태는 T1의 펼침 모델로 이 Mac에만 둔다. 계정이 바뀌면 비운다.

**범위 파일(초안)** — `apple/Taskforce/Mac/Edge/EdgeIssueScreens.swift` · `EdgeShellModel.swift`(세션 합집합), Kit의 세션 규칙 파일, API 클라이언트(지표 두 호출), 시험(`apple/TaskforceTests/EdgeIssuesTests.swift` · 새 `ProjectSessionsTests`), `apple/Taskforce.xcodeproj/project.pbxproj`, `docs/FEATURE_MAP.md`.

**완료 기준** — 앱 시험, `oa-live` worktree의 `scripts/dev-mac-live.sh`로 설치 앱에서 시각 확인(DS 미리보기와 대조), 2개 세션 · 8개 자식 · 실패 1개에서 30초 안에 막힌 자식을 찾는 사용 확인 1회(조사 문서 9장 "UI 판단").

### C. Codex 트리 (뒤에, 기존 계약에 합친다)

`handoffs/oa-codex-adapter-contract.md`(2026-10-21 초안, 코디네이터 로컬)에 아래를 더하고 그 계약의 PR 순서를 따른다.

- `--disable multi_agent`(Assistant 계약 13.3)를 그대로 둘지 정한다. 트리를 원하면 켜고, 사용자 `~/.codex` 설정이 섞이지 않게 기능 · 역할을 고정한다.
- 자식 생성 = 부모 thread의 `subAgentActivity started`. 놓치면 `thread/list {parentThreadId}`로 메운다. spawn · fork는 `source.subAgent.thread_spawn` 유무로 가른다.
- 자식 글은 자식 thread의 것이다(부모 대화에 섞지 않는다, T2 5와 같은 원칙).
- 자식별 승인: 요청의 `threadId`가 자식이면 질문 카드에 그 자식 이름을 붙인다. 서버 질문 하나 제한과 부딪히면 adapter가 열린 채로 줄 세운다(X2: 열린 승인은 기다린다) — 그때 실측으로 정한다.
- Stop: 루트 turn과 **살아 있는 모든 자식 turn**에 `turn/interrupt`(X2: 루트만 멈추면 자식이 남는다). 멈춘 자식은 "마지막 turn 멈춤"이지 끝이 아니다(X3).
- 0.162.1 실측(X1–X3)을 그 계약의 실측 표에 보탠다(데몬 시험은 사용량 한도로 승인을 보지 못했다).

## 3. 공통 규칙

- worktree `~/.claude/worktrees/taskforce-020/oa-agent-tree-<pr>`, 브랜치 `claude/020-oa-agent-tree-<pr>`, base는 그때의 `origin/main`. 작업자 · 검토자 배치는 기존 규칙(코딩 Sonnet 5.5 xhigh, 조정 · 최종 검토 Opus 5.5).
- 사용자 데이터 원칙: 트리의 이름은 모델이 쓴 `description`뿐이다. 프롬프트 · 요약 · 경로 · 명령은 화면 값과 로그에 없다. 서버로 가는 것은 T3s의 종류 두 개뿐이다(4장의 T2 측정을 고르면 그 두 종류까지).
- 진실 규칙 · 추출 파이프라인 · 프롬프트(`src/lib/ai/prompts/`)는 건드리지 않으므로 `npm run eval`이 필요한 PR은 없다(T2의 Claude 시스템 프롬프트는 adapter 글이고 eval 대상이 아니다).
- 커밋 전 검사는 CLAUDE.md 순서(lint → typecheck → test → eval), 마이그레이션이 있는 T3s는 `test:pg`까지.

## 4. 사용자가 정할 것 (검토에서 나온 것)

| 무엇 | 왜 | 추천 |
|---|---|---|
| **Agent 원격 끄기** | 지금 계획대로면 T2 뒤 Agent를 끄려면 앱을 다시 내야 한다 | 서버가 턴 시작 명령에 "하위 에이전트 허용" 한 칸을 싣고, 꺼져 있으면 Mac이 지금 도구 집합으로 띄운다. 환경변수 하나(기본 켜짐). T2에 넣는다 |
| **T2 자체의 측정** | 원칙 6: Agent를 켠 효과(자식을 쓴 턴 수, 자식이 "묻지 못함"으로 거절된 수)를 셀 수단이 없다. 확정한 열기 이벤트 2개는 화면 쪽만 센다 | 서버 지표 종류 둘을 더한다: 자식을 쓴 턴(하루 한 번 아님, 턴마다 1, 개수 칸 없음) · 자식 질문 거절(턴마다 1). T2와 같이, 또는 T3s에 합친다. 이름 · 글 · 개수는 싣지 않는다 |

## 5. 이번에 정하지 않은 것

- "부모 미확인"과 프로젝트 공유 세션 표시의 영어 낱말(디자인 승인, T1 · T3m 안에서).
- T2 재실측의 열린 확인(보류 시 백그라운드 자식의 운명) 결과에 따른 프롬프트 한 문장.
- spawn당 `Agent` 상한 · 깊이 상한 · 벽시계 상한의 정확한 값(T2 재실측에서 정한다).
- Codex의 `multi_agent` 켜기(C에서).
