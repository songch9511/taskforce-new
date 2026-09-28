# Taskforce Apple 앱 (iOS · macOS)

SwiftUI 멀티플랫폼 앱과 공유 패키지 `TaskforceKit`(화면 없는 코드) · `TaskforceUI`(디자인 토큰 · 부품). 플랫폼 전략은 [`docs/PLATFORMS.md`](../docs/PLATFORMS.md), 화면 규칙은 [`docs/BRAND.md`](../docs/BRAND.md)를 보세요.
디자인 원본(SSOT)은 Figma 디자인 시스템 v1(`jDMRGHWMRXeNUILfi11xvf`)이다. 값이 다르면 Figma 변수가 기준이다.

| 항목 | 값 |
|---|---|
| 번들 ID | `dev.taskforcelabs.taskforce` |
| App Group | `group.dev.taskforcelabs.taskforce` |
| URL scheme | `taskforce://` (연동 OAuth가 끝나면 `taskforce://connections/{provider}?handoff=…` 또는 `?status=…`로 돌아온다) |
| 최소 OS | iOS 18 · macOS 15 |

## 처음 한 번

1. Supabase 설정을 채웁니다. 값은 웹의 `.env.local`과 같습니다.
   ```bash
   cp apple/Config/Secrets.example.xcconfig apple/Config/Secrets.xcconfig
   ```
   xcconfig에서는 `//`가 주석이라 URL을 `https:/$()/<ref>.supabase.co`처럼 적습니다.
   `API_BASE_URL`에는 Taskforce 서버 주소를 경로 없이 적습니다.
   - 시뮬레이터 + 로컬 서버(`npm run dev`): `API_BASE_URL = http:/$()/localhost:3000`
     (Info.plist의 `NSAllowsLocalNetworking`으로 로컬 주소만 http를 허용합니다)
   - 실제 기기 · 배포 서버: `API_BASE_URL = https:/$()/<서버 주소>`
2. `apple/Taskforce.xcodeproj`를 Xcode로 엽니다. 서명은 자동이고 Team은 `U9DWQKQFMW`로 잡혀 있습니다.
3. Supabase → Authentication → Sign In / Providers → Apple을 켜고 Client IDs에 `dev.taskforcelabs.taskforce`를 넣어야 로그인이 됩니다.
4. Apple Developer → Identifiers → `dev.taskforcelabs.taskforce`에 App Groups가 켜져 있고 `group.dev.taskforcelabs.taskforce`가 연결돼 있어야 합니다(2026-09-28에 켬).
   빠지면 Mac 프로필에 App Group이 없어 macOS가 앱 권한을 통째로 무시하고, 로그인 세션을 Keychain에 저장하지 못합니다(`-34018`, 앱에는 "Couldn't save your sign-in.").
   프로필이 바뀌면 `~/Library/Developer/Xcode/UserData/Provisioning Profiles`의 옛 Mac 프로필을 지우고, **빌드된 `Taskforce.app`도 지운 뒤** `-allowProvisioningUpdates`로 다시 빌드합니다.
   이어서 빌드하면 새 프로필만 복사되고 서명은 그대로라 서명이 깨질 수 있습니다(`codesign --verify --deep --strict`가 "a sealed resource is missing or invalid"면 이 경우). 결과는 위와 같은 `-34018`입니다.

## 프로젝트 구조를 바꿀 때

`Taskforce.xcodeproj`는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 `project.yml`에서 생성합니다.
타깃 · 설정 · 파일 그룹을 바꾸거나 **앱 타깃에 파일을 더하면** Xcode에서 직접 고치지 말고 다시 생성합니다.

```bash
brew install xcodegen
cd apple && xcodegen
```

## 테스트 · 빌드

```bash
cd apple/Packages/TaskforceKit && swift test
xcodebuild build -project apple/Taskforce.xcodeproj -scheme Taskforce -destination 'generic/platform=iOS Simulator' -derivedDataPath apple/build/dd CODE_SIGNING_ALLOWED=NO
xcodebuild build -project apple/Taskforce.xcodeproj -scheme Taskforce -destination 'platform=macOS' -derivedDataPath apple/build/dd CODE_SIGNING_ALLOWED=NO
```

디자인 비교용 견본 (Debug 빌드만): 실행 인자 `-TFSampleData`를 주면 Figma 견본과 같은 문구로 화면을 채우고 서버를 부르지 않는다.
Mac은 `--show-launcher -TFSampleData -TFSnapshot <폴더>`로 실행하면 런처의 목록 · 펼침 · ⌘K · 찾기 화면과 설정 창을 PNG로 남기고 끝낸다(화면 녹화 권한 없이 자기 창만 그린다).

## 화면

### iPhone — 한 화면 (Figma 9:529 · Website 17:962)

- 로그인: Sign in with Apple, 그 아래 눈에 덜 띄게 "Sign in with email"(App Store 심사 계정용, 가입 화면 없음). Mac 런처의 "Sign in with email" 행은 설정 창의 같은 로그인 화면을 연다.
- "Review 1 / N" + Review card 한 장(Confirm = `POST confirm`, Dismiss = `DELETE`) → In Progress · To Do · Done Today 구역의 Task row 목록(빈 구역은 숨김). 구역 안 순서는 서버가 정한 그대로(`TaskBoard`).
  Review card는 iOS 26부터 Liquid Glass(카드 regular 유리, Confirm = 잉크 `glassProminent`, Dismiss = `glass`), 그 전은 bg/surface + 캡슐 버튼(`TFGlassCard` · `TFGlassButtonStyle`). 할 일 행은 평평하게 둔다.
- 상태는 To Do · In Progress · Done 세 이름으로만 옮긴다(`POST /actions/:id/progress {"state": "to_do"|"in_progress"|"done"}`, `NowStore.move`). 서버를 기다리지 않고 곧바로 그 구역으로 옮기고, 쓰기가 끝나면 두 목록을 다시 읽는다.
  - 왼쪽 상태 표시(`TaskStatusMark`: ○ To Do · ◉ In Progress · ✓ Done): ○ · ◉를 누르면 Done, ✓는 끝내기 전 상태로(이 기기에서 끝낸 것은 기억, 모르면 착수 시각이 있으면 In Progress, 없으면 To Do)
  - 밀기: To Do = 오른쪽 In Progress · 왼쪽 Done, In Progress = 오른쪽 To Do · 왼쪽 Done, Done Today = 오른쪽 To Do
  - 길게 누르기: 세 상태 메뉴(지금 상태에 체크)
- 삭제(`DELETE /actions/:id`, 서버는 취소로 두고 이력을 남긴다, `NowStore.delete`): 왼쪽으로 밀면 Done 옆에 빨간 Delete(끝까지 밀면 Done, Done Today는 끝까지 밀어도 지우지 않는다) · 길게 누르기 메뉴 맨 아래 Delete. Review는 Dismiss만.
  곧바로 행을 빼고 가벼운 햅틱, 5초 동안 아래에 "Deleted  Undo" 캡슐(iOS 26 유리, 그 전 material, `tfGlassCapsule`). Undo = `PATCH status`(Done Today였으면 done, 아니면 open: 착수 시각이 남아 있어 In Progress는 In Progress로 돌아온다, `TaskUndo.restoreEdit`)
- 행을 누르면 근거 한 줄만 펼치고, 인용을 누르면 원문을 연다.
- 오른쪽 위 "+" = New Task 시트(`NowStore.add`, 원문 없이 `POST /actions`): 제목(200자까지) · Due(None · Today · Tomorrow · Date…) · Cancel / Add.
  iOS 26은 시스템 유리 시트 그대로 두고, 제목 칸 · 기한 칩 · Existing 줄은 bg/elevated 바탕 위에 둬서 뒤 목록 글자가 비치지 않게 한다(그 전 OS는 bg/canvas 시트).
  쓰는 동안 열린 할 일(Review · In Progress · To Do)에서 맞는 것을 "Existing"으로 세 개까지 보여 준다(`LauncherAdd.existing`, 런처 찾기와 같은 거르기). 추가는 막지 않는다. 추가되면 닫고 `/now`를 다시 부른다.
- 오른쪽 위 계정 시트: Profile(이름 · 다른 이름, 비어 있으면 처음 한 번 묻는다) · Connections · AI processing(외부 AI 처리 동의) · Sign Out · Delete Account(Apple 재확인 → 토큰 폐기) · Privacy Policy · Terms of Use.
- 연결이 없고 할 일도 없으면 로고 네 개 + "Connect" 한 줄. 권한이 끊긴 연결이 있으면 목록 위에 Reconnect 줄.

### Mac — 에이전트 앱 + ⌥Space 런처 (Figma 5:57 · 5:90)

- Dock 아이콘 없음(`LSUIElement`, macOS만). 메뉴 막대의 로고 마크: Open Launcher · Settings… · Quit.
- 전역 단축키 ⌥Space(Carbon `RegisterEventHotKey`, 샌드박스 안에서 동작). Settings → Shortcut에서 바꾼다(UserDefaults).
- 런처: 폭 696 · 모서리 26, 바탕은 macOS 26부터 `NSGlassEffectView`(Liquid Glass), 그 전은 `NSVisualEffectView` 유리 재질 + 1pt 테두리. 화면 가운데 위쪽. esc · 다른 곳 클릭 · 동작 완료로 닫힌다.
  - 빈칸 → Review · In Progress · To Do · Done Today(흐리게) · Commands(Send clipboard as source · Report missing action · Connections · Settings · Quit). 빈 구역은 숨김
  - 짧은 글 → 네 구역을 앱에서 거른 결과(순서 계산 아님) + Ask “…” + Hand off “첫 결과” to AI, 그 아래 거른 Done Today
    - 열린 할 일(Review · In Progress · To Do)에 맞는 것이 없으면 맨 위에 Add “…”(Done Today는 보지 않는다)(`POST /actions`, 제목 200자까지): ↩ → 기한(맨 위 No due date) → 원문(맨 위 No source, 아래는 빠진 할 일 신고와 같은 최근 원문) → 원문을 골랐으면 줄 고르기 후 ⌘↩ → "Added". esc는 한 단계 뒤로
  - 200자가 넘거나 여러 줄 → Send as source(`POST /sources`, 여러 줄은 note · 한 줄은 message, 제목은 첫 줄) + Ask
  - 키: ↑↓ 고르기 · ↩ 실행(Review는 Confirm, 할 일은 ⌘K 패널) · ⌘K 동작 · Tab/→ 펼침(Sources 묶음) · ⌘⌫ Review Dismiss · 할 일 Delete(목록은 입력이 비었을 때, ⌘K 패널에서도) · esc 뒤로/닫기
    - ⌘K: To Do · In Progress = Status(To Do · In Progress · Done, 지금 상태에 체크) + Actions(Hand off to AI · Open source · Edit due · Delete ⌘⌫), Done Today = Status + Actions(Open source · Delete ⌘⌫), Review = Confirm · Dismiss · Hand off to AI · Open source · Edit due.
      열면 다음 상태를 고른 채 둔다(To Do → In Progress → Done, Done → 끝내기 전 상태)
  - 행 왼쪽 상태 표시(Review는 점선 원, 누를 수 없음): ○ · ◉를 누르면 Done, ✓는 끝내기 전 상태로. 상태를 옮기면 런처를 닫지 않고 그 행을 옮긴 구역에서 고른 채 둔다.
    옮긴 뒤 5초 동안 아래에 "Undo ⌘Z"(⌘Z = 옮기기 전 상태로)
  - Delete는 런처를 닫지 않고 그 행을 빼고 같은 자리의 다음 행을 고른다. 5초 동안 "Undo ⌘Z"(⌘Z = 지우기 전 구역으로 되살림, iPhone Undo와 같은 쓰기)
  - `app_opened`는 런처가 뜰 때 30분에 한 번(`LauncherOpenThrottle`).
- 설정 창(SwiftUI Settings 장면): Account · Connections · AI processing · Shortcut. iPhone과 같은 연결 · 동의 화면을 쓴다.

### 연결 · 동의 (양쪽)

- `POST /api/v1/connections/{provider}/start` → `ASWebAuthenticationSession`(callback scheme `taskforce`) → 돌아온 주소를 `ConnectionCallback`으로 읽는다. 앱 밖에서 열리면 `onOpenURL`(iOS) · `application(_:open:)`(Mac).
  400 invalid_request = "Coming soon", 409 conflict = 동의 화면 먼저. Google은 연결 전 읽는 것 세 줄, Gmail은 "Reconnect every 7 days".
- 동의 성공 콜백은 `?handoff=<id>`만 준다. 앱이 자기 Bearer 토큰으로 `POST /api/v1/connections/{provider}/complete {"handoff": id}`를 불러야 연결이 생긴다
  (서버는 연결을 시작한 사용자일 때만 잇는다: 남의 계정을 공격자 계정에 잇는 일을 막는다). 404 = 만료 · 내 것 아님 → "Couldn't connect. Try again.", 409 = 동의한 뒤 같은 handoff로 다시.
  실패 콜백은 `?status=denied|error|invalid_state`.
- 외부 AI 처리 동의: 기존 사용자도 모두 동의 없이 시작한다. 동의 전인데 연결이 있으면 로그인 뒤 한 번 동의 화면(iPhone)을 띄우고, 목록 위에 "Allow AI processing" 한 줄(iPhone 배너 · Mac 런처 맨 위)을 둔다. 목록 보기는 막지 않는다.
- 2단계(Microsoft 365 · Zoom · GitHub · Linear · Jira)는 "Want this" → `POST /api/v1/connection-requests`.
- 연결 목록은 `connections` 표를 RLS로 읽는다. Sync Now = `POST /connections/sync`, Disconnect = `DELETE /connections/:id`.

## 구조

- `Taskforce/` — 앱
  - `Shared/` — 두 플랫폼 공용: `NowStore`(지금 할 일 · 오늘 끝낸 할 일 · 근거 · 쓰기, To Do · In Progress · Done 옮기기 · 삭제 · 되살리기는 먼저 보여 줌), `AccountStore`(연결 · 동의 · 프로필), 연결 · 동의 · 프로필 화면, 로그인, 계정 삭제
  - `iOS/` — 한 화면(`HomeView`) · 계정 시트 · New Task 시트
  - `Mac/` — 앱 델리게이트 · 메뉴 막대 · 단축키 · 런처 패널/모델/화면 · 설정 창
- `Packages/TaskforceKit/`
  - `TaskforceKit` — 화면 없는 공유 코드
    - `APIClient`: 서버 `/api/v1` (모든 쓰기). `Authorization: Bearer <Supabase access token>`. 화면용 오류 문구는 영어
    - `TaskforceReads`: Supabase 직접 읽기 (RLS, 읽기 전용) — 할 일 상세 · 근거 · 원문 · 연결 · 원해요 · 오늘 끝낸 할 일(`status = done`, 기기 시간대 오늘 0시 뒤 `updated_at`, 최근 것부터 10개, 다른 사람 몫 제외)
    - `ActionChanges`: `actions` Realtime 구독. "바뀜" 신호로만 쓰고 지금 할 일은 항상 `/now`를 다시 불러온다 (로그인해 있는 동안 구독 하나: `ActionChangeFeed`)
    - `Models` · `AccountModels` · `Connections`: `src/lib/api/contract.ts`와 같은 모양 (새 필드는 없어도 읽는다)
    - 순수 규칙(테스트로 고정): 목록 구역 · 진행 상태(`WorkState`) · 먼저 보여 주는 내 변경 · 지울 수 있는 행 · 되돌리기(`TaskSections`: `TaskChange` · `TaskUndo` · `UndoOffer`), 런처 입력 모드 · 구역 · 거르기 · 붙여 넣은 원문 · 직접 추가 제목 · 이미 있는 할 일(`Launcher`), 영어 기한 · 시점 표기 · Task row 메타(`DisplayText`), 서비스 추정 · Source stack 접기(`SourceService`), 근거 고르기(`EvidenceDigest`), 연결 상태 · 콜백 · 시작 실패 분류(`Connections`), 단축키(`HotKeyShortcut`), `app_opened`(`AppOpenTracker` · `LauncherOpenThrottle`), 원문 줄 고르기(`SourceText` · `LineSelection`)
  - `TaskforceUI` — Figma 토큰(Asset Catalog 색 세트, 이름 = Figma 변수 · 간격 · 모서리 · 글자)과 부품(Task status · Task row · Review card · Evidence · Sources group · Source icon/stack · Launcher row · Keycap · 캡슐 버튼 · 유리 카드/버튼/묶음), 부품마다 `#Preview`
    - 서비스 로고는 Figma Source icon(Simple Icons 단색)의 글리프만 template 이미지로 두고, 타일은 토큰으로 그린다
- 순서 계산 · 판정은 서버에만 있다. 앱은 받은 순서를 그대로 보여준다.
- 로그인 세션은 App Group 공유 Keychain(데이터 보호 Keychain)에 저장되어, Phase A2의 공유 확장이 같은 세션을 읽습니다.
