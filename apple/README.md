# Taskforce Mac 앱

현재 beta 앱 타깃은 macOS 15 이상입니다. `TaskforceKit`(화면 없는 코드) · `TaskforceUI`(디자인 토큰 · 부품)를 재사용합니다. 예전 iPhone 화면 설명은 아래에 설계 기록으로 남아 있으며 활성 앱 타깃이 아닙니다. 플랫폼 전략은 [`docs/PLATFORMS.md`](../docs/PLATFORMS.md), 화면 규칙은 [`docs/BRAND.md`](../docs/BRAND.md)를 보세요.
디자인 원본(SSOT)은 Figma 디자인 시스템 v1(`jDMRGHWMRXeNUILfi11xvf`)이다. 값이 다르면 Figma 변수가 기준이다.

| 항목 | 값 |
|---|---|
| 번들 ID | `dev.taskforcelabs.taskforce` |
| App Group | `group.dev.taskforcelabs.taskforce` |
| URL scheme | `taskforce://` (연동 OAuth가 끝나면 `taskforce://connections/{provider}?handoff=…` 또는 `?status=…`로 돌아온다), Google 로그인 `com.googleusercontent.apps.<클라이언트>`(`GOOGLE_IOS_URL_SCHEME`) |
| 최소 OS | macOS 15 |

## 처음 한 번

1. Supabase 설정을 채웁니다. 값은 웹의 `.env.local`과 같습니다.
   ```bash
   test -e apple/Config/Secrets.xcconfig || cp apple/Config/Secrets.example.xcconfig apple/Config/Secrets.xcconfig
   ```
   xcconfig에서는 `//`가 주석이라 URL을 `https:/$()/<ref>.supabase.co`처럼 적습니다.
   `API_BASE_URL`에는 Taskforce 서버 주소를 경로 없이 적습니다. **Debug 빌드만** 이 값을 씁니다.
   - 시뮬레이터 + 로컬 서버(`npm run dev`): `API_BASE_URL = http:/$()/localhost:3000`
     (Info.plist의 `NSAllowsLocalNetworking`으로 로컬 주소만 http를 허용합니다)
   - 실제 기기 · 배포 서버: `API_BASE_URL = https:/$()/<서버 주소>`
   - **Release 빌드(직접 배포용 아카이브)는 커밋된 `Config/Release.xcconfig`가 `https://api.taskforcelabs.dev`로 고정**합니다(Base + Secrets를 불러온 뒤 `API_BASE_URL`만 바꿈). Supabase URL · 키는 두 설정 모두 Secrets에서 옵니다.
2. `apple/Taskforce.xcodeproj`를 Xcode로 엽니다. 서명은 자동이고 Team은 `U9DWQKQFMW`로 잡혀 있습니다.
3. Supabase → Authentication → Sign In / Providers → Apple을 켜고 Client IDs에 `dev.taskforcelabs.taskforce`를 넣어야 로그인이 됩니다.
   Sign in with Google은 Google 제공자(Client IDs = 프로젝트 A iOS 클라이언트 ID, Skip nonce checks 끔, 2026-09-30 켬)가 받습니다. Debug 빌드에서 Google 버튼을 보려면 `Secrets.xcconfig`에 `GOOGLE_IOS_CLIENT_ID` · `GOOGLE_IOS_URL_SCHEME`을 넣습니다(값은 `Config/Release.xcconfig`와 같음, 비우면 버튼이 숨음). [PLATFORMS.md](../docs/PLATFORMS.md) 4장.
4. Apple Developer → Identifiers → `dev.taskforcelabs.taskforce`에 App Groups가 켜져 있고 `group.dev.taskforcelabs.taskforce`가 연결돼 있어야 합니다(2026-09-28에 켬).
   빠지면 Mac 프로필에 App Group이 없어 macOS가 앱 권한을 통째로 무시하고, 로그인 세션을 Keychain에 저장하지 못합니다(`-34018`, 앱에는 "Couldn't save your sign-in.").
   프로필이 바뀌면 `~/Library/Developer/Xcode/UserData/Provisioning Profiles`의 옛 Mac 프로필을 지우고, **빌드된 `Taskforce.app`도 지운 뒤** `-allowProvisioningUpdates`로 다시 빌드합니다.
   이어서 빌드하면 새 프로필만 복사되고 서명은 그대로라 서명이 깨질 수 있습니다(`codesign --verify --deep --strict`가 "a sealed resource is missing or invalid"면 이 경우). 결과는 위와 같은 `-34018`입니다.
5. 알림(C10): Mac 권한 파일의 `com.apple.developer.aps-environment`는 로컬 Debug에서 `development`, 직접 배포용 권한 확인에서는 `production`이어야 합니다. **App ID `dev.taskforcelabs.taskforce`에 Push Notifications 기능이 켜져 있어야** 서명된 빌드의 프로필에 이 권한이 들어갑니다(빠지면 자동 서명이 프로필 오류로 멈춥니다). 켠 뒤에는 프로필과 빌드 결과를 다시 확인합니다.

## 프로젝트 구조를 바꿀 때

`Taskforce.xcodeproj`는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 `project.yml`에서 생성합니다.
타깃 · 설정 · 파일 그룹을 바꾸거나 **앱 타깃에 파일을 더하면** Xcode에서 직접 고치지 말고 다시 생성합니다.

```bash
brew install xcodegen
cd apple && xcodegen
```

앱이 쓰는 패키지(TaskforceKit의 supabase-swift, Google Sign-In)의 고정 버전은 `Taskforce.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`(커밋, xcodegen이 지우지 않음)다. 올릴 때는 Xcode → File → Packages → Update to Latest Package Versions 뒤 이 파일을 커밋한다.

## 테스트 · 빌드

```bash
cd apple/Packages/TaskforceKit && swift test
# 색 토큰을 actool이 컴파일한 카탈로그로 확인 (swift test는 카탈로그를 복사만 한다, CI도 같은 단계). 줄마다 저장소 맨 위에서
cd apple/Packages/TaskforceKit && TEST_RUNNER_TF_REQUIRE_COMPILED_CATALOG=1 xcodebuild test -scheme TaskforceKit-Package -destination 'platform=macOS' -only-testing:TaskforceUITests
xcodebuild build -project apple/Taskforce.xcodeproj -scheme Taskforce -destination 'platform=macOS' -derivedDataPath apple/build/dd CODE_SIGNING_ALLOWED=NO
```

디자인 비교용 견본 (Debug 빌드만): 실행 인자 `-TFSampleData`를 주면 Figma 견본과 같은 문구로 화면을 채우고 서버를 부르지 않는다.
`-TFSampleData -TFSampleSyncing`은 할 일 없이 Notion이 첫 동기화 중인 화면("Syncing…")이다.
상태 견본: `-TFSampleOffline`(저장본 + 오프라인) · `-TFSampleOfflineLoaded`(받은 목록 그대로 오프라인, iPhone P10) · `-TFSampleRefreshFailed` · `-TFSampleNoSaved`(저장본 없음) · `-TFSampleEmpty` · `-TFSampleLoading`. iPhone 큰 글자는 `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`.
Mac은 `--show-launcher -TFSampleData -TFSnapshot <폴더>`로 실행하면 런처의 목록 · 펼침 · ⌘K · 찾기 화면과 설정 창을 PNG로 남기고 끝낸다(화면 녹화 권한 없이 자기 창만 그린다).
`--show-settings -TFSampleData -TFSnapshot <폴더>`는 설정 창 사이드바의 보이는 항목마다 Light · Dark PNG(`mac-settings-<항목>-light.png` · `-dark.png`, Account는 열린 시트)를 남기고 끝낸다. `-TFSnapshot` 없이 `--show-settings`만 주면 설정 창을 연다(Debug 빌드).
실행(U2) 견본: `-TFSampleCredits`는 S3 Figma 값(Usage & Credits 항목이 보이고 `usage` · `usage-end` PNG), `-TFSampleNoExecution`은 credits 404(실행 UI 없음), `-TFSampleConsent`는 동의한 계정(Privacy & AI Data 스위치 켜짐). 설정 창 PNG에는 Privacy & AI Data 끝까지(`privacy-end`) · 동의 화면 처음과 끝(`consent-prompt` · `consent-prompt-end`)도 남는다. iPhone은 `-TFSampleSettings`(설정 시트) · `-TFSamplePrivacy`(Privacy & AI Data)로 그 화면을 연 채 시작한다.

## 화면

### iPhone — 이전 설계 기록, 현재 beta 타깃 아님 (Figma 156:6 P1 · P10 · P11, U1 셸)

- 로그인: Sign in with Apple, 그 아래 같은 크기의 Sign in with Google(Google 클라이언트 설정이 있을 때, 로그인만: 기본 범위 openid · email · profile), 그 아래 눈에 덜 띄게 "Sign in with email"(App Store 심사 계정용, 가입 화면 없음). Mac 런처도 같은 순서의 행이고, "Sign in with email" 행은 설정 창의 같은 로그인 화면을 연다.
  Google 버튼은 Google 브랜드 규칙의 Light 테마(흰 바탕 · 회색 테두리 · 표준 색 G)로 다크 모드에서도 같다(`SignInWithGoogleButton`). Google 로그인 직후 프로필 이름이 비어 있으면 그 이름으로 한 번 채운다. 로그인이 풀릴 때마다(로그아웃 · 만료 · 계정 삭제) Google SDK 로그인도 지운다.
- 큰 제목 `Tasks` → 검색칸 `Search 23 tasks`(열린 할 일 수, `PhoneHome.searchPrompt`, 찾는 동안 네 구역 모두 거름 `TaskFilter`) → Review card 한 장(`1 of 4`, 위에 `Show All 4 ›` = 모든 카드 화면. Confirm = `POST confirm`, Dismiss = `DELETE`, 둘 다 버튼으로만) → In Progress · To Do · Done Today(머리에 개수, 빈 구역은 숨김)의 Task row 목록. 구역 안 순서는 서버가 정한 그대로(`TaskBoard`). 섹션 접기(`SectionCaps`)는 쓰지 않는다(Mac 런처만).
  Task row = 옅은 빈 원(열린 할 일, 누르면 Done) + 제목 2줄까지 + 오른쪽 기한(지났거나 오늘이면 빨강) + 바뀜 점. 접근성 크기에서는 제목 전부 · 기한은 제목 아래 · 원 44. 원 VoiceOver "Mark Done", 섹션 머리 `.isHeader`.
  오프라인(P10): 목록 위 `Offline since 10:41. Showing saved tasks.`, 검색칸 `Search 23 saved tasks`, Confirm · Dismiss · 상태 바꾸기 · 삭제 · Undo · 주간 질문은 꺼지고(+ 직접 추가는 Figma P10대로 켜 둔다) 카드 아래 `Confirm and Dismiss wait for a connection. Nothing is saved for later.`(`PhoneHome.canWrite`). 새로고침 실패는 `Couldn’t refresh at 10:46. Showing 10:31.` + Try Again, 실패 원문은 `Couldn’t read 2 sources`. 연결이 돌아오면 다시 불러온다(`Connectivity`).
  저장본: `/now`가 성공할 때마다 그 계정의 저장본(제목 · 기한 · 상태만)을 쓰고, 이번 실행에서 `/now`를 받기 전에는 그것을 읽기만 한다. 계정이 떠나면 지운다(`Startup.make`의 `onSignedOut`, 앱을 열 때 `SavedNowStore.prune(keeping:)`).
  Review card 위 줄에 확인 이유(`ConfirmReasonText.label`: `confirm_reasons` 중 가장 중요한 하나 — Not sure it's yours · May be done already · May not be a task · May not be a firm commitment · Update may not belong here(`병합 확인`: 기존 할 일에 붙은 새 내용) · May duplicate another task(`중복 확인`) · Due date unclear · Scope unclear · Status unclear, 모르는 이유는 Needs review).
  Review card는 평평한 bg/elevated 면 + settings/line 테두리(r16), Confirm = 잉크 캡슐 · Dismiss = settings/fill 캡슐(`CapsuleButtonStyle`, Figma P1). 유리는 떠 있는 "Deleted  Undo" 막대에만.
- 상태는 To Do · In Progress · Done 세 이름으로만 옮긴다(`POST /actions/:id/progress {"state": "to_do"|"in_progress"|"done"}`, `NowStore.move`). 서버를 기다리지 않고 곧바로 그 구역으로 옮기고, 쓰기가 끝나면 두 목록을 다시 읽는다.
  - 왼쪽 원: 옅은 빈 원(To Do · In Progress)을 누르면 Done, ✓는 끝내기 전 상태로(이 기기에서 끝낸 것은 기억, 모르면 착수 시각이 있으면 In Progress, 없으면 To Do)
  - 밀기: To Do = 오른쪽 In Progress · 왼쪽 Done, In Progress = 오른쪽 To Do · 왼쪽 Done, Done Today = 오른쪽 To Do
  - 길게 누르기: 세 상태 메뉴(지금 상태에 체크)
- 삭제(`DELETE /actions/:id`, 서버는 취소로 두고 이력을 남긴다, `NowStore.delete`): 왼쪽으로 밀면 Done 옆에 빨간 Delete(끝까지 밀면 Done, Done Today는 끝까지 밀어도 지우지 않는다) · 길게 누르기 메뉴 맨 아래 Delete. Review는 Dismiss만.
  곧바로 행을 빼고 가벼운 햅틱, 5초 동안 아래에 "Deleted  Undo" 캡슐(iOS 26 유리, 그 전 material, `tfGlassCapsule`). Undo = `PATCH status`(Done Today였으면 done, 아니면 open: 착수 시각이 남아 있어 In Progress는 In Progress로 돌아온다, `TaskUndo.restoreEdit`)
- 행을 누르면 근거 한 줄만 펼치고(종이 면 `SourceSlip`), 인용을 누르면 원문을 연다. 바뀐 할 일이면 펼칠 때 `POST /actions/:id/seen`을 한 번 보내고 점을 지운다(`SeenTracker.open`, 실패해도 다시 보내지 않음, 오프라인이면 보내지 않음). 바뀐 Review 카드는 보였다가 떠날 때(다른 카드 · 화면 밖 · Show All) 같은 방법으로.
- 오른쪽 위 "+" = New Task 시트(`NowStore.add`, 원문 없이 `POST /actions`): 제목(200자까지) · Due(None · Today · Tomorrow · Date…) · Cancel / Add.
  iOS 26은 시스템 유리 시트 그대로 두고, 제목 칸 · 기한 칩 · Existing 줄은 bg/elevated 바탕 위에 둬서 뒤 목록 글자가 비치지 않게 한다(그 전 OS는 bg/canvas 시트).
  쓰는 동안 열린 할 일(Review · In Progress · To Do)에서 맞는 것을 "Existing"으로 세 개까지 보여 준다(`LauncherAdd.existing`, 런처 찾기와 같은 거르기). 추가는 막지 않는다. 추가되면 닫고 `/now`를 다시 부른다.
- 왼쪽 위 설정 시트(제목 Settings, Figma P1에는 없지만 로그아웃 · 계정 삭제 · 동의 철회 경로라 둔다): Profile(이름 · 다른 이름, 비어 있으면 처음 한 번 묻는다) · Connections · Privacy & AI Data(외부 AI 처리 동의 스위치 `Use AI on new sources`, 철회 경로 "Settings > Privacy & AI Data") · 로그인 계정 줄("Apple ID" · "Google Account" · "Email") · Sign Out(이 기기만, 다른 기기는 로그인 유지: 아래 한 줄 "Sign Out applies only to this device.") · Delete Account(Apple 로그인 계정은 Apple 재확인 → 토큰 폐기, Google 로그인 계정은 삭제 뒤 Google 권한 폐기) · Privacy Policy · Terms of Use.
- 연결이 없고 할 일도 없으면 로고 네 개 + "Connect" 한 줄. 연결이 동기화 중이고 할 일이 없으면 가운데 진행 표시 + "Syncing…". 권한이 끊긴 연결이 있으면 목록 위에 Reconnect 줄.
- 알림(C10): 권한은 첫 실행에 묻지 않고, 로그인했고 연결이 하나라도 있으며 다른 시트가 없을 때 한 번 묻는다(`PushPermission`). 알림을 누르면 떠 있는 시트를 닫고 목록을 다시 읽은 뒤 그 할 일로 스크롤한다: 확인 요청이면 그 Review card를 먼저 보이고, 할 일이면 그 행을 2초 동안 bg/surface로 칠한다.

### Mac — 에이전트 앱 + ⌥Space 런처 (Figma 5:57 · 5:90)

- Dock 아이콘 없음(`LSUIElement`, macOS만). 메뉴 막대의 로고 마크: Open Launcher · Settings… · Quit.
- 전역 단축키 ⌥Space(Carbon `RegisterEventHotKey`, 샌드박스 안에서 동작). Settings → Keyboard Shortcuts에서 바꾼다(UserDefaults).
- 런처: 폭 696 · 모서리 26, 바탕은 macOS 26부터 `NSGlassEffectView`(Liquid Glass), 그 전은 `NSVisualEffectView` 유리 재질 + 1pt 테두리. 화면 가운데 위쪽. esc · 다른 곳 클릭 · 동작 완료로 닫힌다.
  - 빈칸 → Review · In Progress · To Do · Done Today(흐리게) · Commands(Send clipboard as source · Report missing action · Connections · Settings · Quit). 빈 구역은 숨김
  - 짧은 글 → 네 구역을 앱에서 거른 결과(순서 계산 아님) + Ask “…” + Hand off “첫 결과” to AI, 그 아래 거른 Done Today
    - 열린 할 일(Review · In Progress · To Do)에 맞는 것이 없으면 맨 위에 Add “…”(Done Today는 보지 않는다)(`POST /actions`, 제목 200자까지): ↩ → 기한(맨 위 No due date) → 원문(맨 위 No source, 아래는 빠진 할 일 신고와 같은 최근 원문) → 원문을 골랐으면 줄 고르기 후 ⌘↩ → "Added". esc는 한 단계 뒤로
  - 200자가 넘거나 여러 줄 → Send as source(`POST /sources`, 여러 줄은 note · 한 줄은 message, 제목은 첫 줄) + Ask
  - Review 행은 제목 옆(부제 자리)에 확인 이유 한 줄(iPhone Review card와 같은 `ConfirmReasonText.label`). 행 높이는 그대로 40이고, 긴 제목은 이유를 자르지 않고 제목을 줄인다
  - 키: ↑↓ 고르기 · ↩ 실행(Review 행은 근거 펼치기 — 행에서 ↩로 확정하지 않는다, 할 일은 ⌘K 패널) · ⌘↩ Review Confirm(목록 · 펼침 · ⌘K 패널, 패널에서 고른 줄과 상관없이) · ⌘K 동작 · Tab/→ 펼침(Sources 묶음) · ⌘⌫ Review Dismiss(목록 · 펼친 Review는 입력이 비었을 때, ⌘K 패널에서도. 펼침에서 입력이 있으면 아무것도 하지 않는다) · 할 일 Delete(목록은 입력이 비었을 때, ⌘K 패널에서도. 펼친 할 일에서는 아무것도 하지 않는다) · esc 뒤로/닫기
    - 누르고 있어 반복된 ↩ · ⌘↩는 어느 화면에서나 무시한다(`LauncherReturn`: 펼침 → ⌘K로 이어지거나, 확정 뒤 다음 화면 · 목록 첫 줄을 실행하지 않게). ⌘⌫ 반복도 무시(`LauncherDeleteGuard`). "Confirmed" 같은 완료 줄에서 ↩는 런처를 닫기만 한다
    - 펼침 · ⌘K 패널(과 거기서 연 알림)에서 esc로 돌아오면 본 할 일의 행을 고른다(`LauncherContent.rowAfterBack`: 목록이 새로 와 자리가 바뀌어도 그 행. 사라졌으면 가장 가까운 할 일 행, Review · 명령 줄은 고르지 않고 할 일 행이 없으면 고른 줄 없음)
    - 펼침 · 패널을 연 뒤 그 할 일이 바뀌었으면(다른 기기에서 확정 · 옮김 · 지움) ↩ · ⌘↩ · ⌘⌫ · 패널 줄 누르기는 실행하지 않고 목록으로 돌아간다
    - Review 행 · 펼친 Review를 고르면 아래에 "Confirm ⌘↩ · Dismiss ⌘⌫ · Actions ⌘K"(입력이 있으면 Dismiss는 빠진다)
    - ⌘K: To Do · In Progress = Status(To Do · In Progress · Done, 지금 상태에 체크) + Actions(Hand off to AI · Open source · Edit due · Delete ⌘⌫), Done Today = Status + Actions(Open source · Delete ⌘⌫), Review = Confirm ⌘↩ · Dismiss ⌘⌫ · Hand off to AI · Open source · Edit due.
      열면 다음 상태를 고른 채 둔다(To Do → In Progress → Done, Done → 끝내기 전 상태). Review는 Open source를 고른 채 연다(↩를 이어 눌러도 확정되지 않게. 확정은 ⌘↩이나 Confirm 줄로 옮겨서 ↩)
  - 행 왼쪽 상태 표시(Review는 점선 원, 누를 수 없음): ○ · ◉를 누르면 Done, ✓는 끝내기 전 상태로. 상태를 옮기면 런처를 닫지 않고 그 행을 옮긴 구역에서 고른 채 둔다.
    옮긴 뒤 5초 동안 아래에 "Undo ⌘Z"(⌘Z = 옮기기 전 상태로)
  - Delete는 런처를 닫지 않고 그 행을 빼고 같은 자리의 다음 행을 고른다. 5초 동안 "Undo ⌘Z"(⌘Z = 지우기 전 구역으로 되살림, iPhone Undo와 같은 쓰기)
  - `app_opened`는 런처가 뜰 때 30분에 한 번(`LauncherOpenThrottle`).
  - 할 일이 하나도 없는데 연결이 동기화 중이면 빈 입력창 목록 맨 위에 진행 표시 + "Syncing…" 한 줄(고를 수 없음).
  - 알림 권한은 런처가 뜰 때 연결이 있으면 한 번 묻는다. 알림을 누르면 런처를 열고 그 할 일(Review · 할 일 행)을 고른다(목록을 아직 못 읽었으면 읽은 뒤에).
- 설정 창(SwiftUI Settings 장면, 760×480, Figma S1): 왼쪽 사이드바(`Settings` · 검색칸 · Personal / Work)에 Keyboard Shortcuts · Usage & Credits · Account ↗ · Connections · Privacy & AI Data. Usage & Credits(Figma S3)는 실행을 쓸 수 있는 계정(`GET /credits` 200)에만 보인다(`MacSettingsTab.sidebar(executionAvailable:)`). Account는 페이지가 아니라 창 위 시트이고, 그 Sign Out도 이 기기만이다. iPhone과 같은 연결 · 동의 화면을 쓴다(Privacy & AI Data는 Mac에서 설정 카드 모양). 아직 내용이 없는 General · Notifications · Automation은 숨기고, 그 단위가 `MacSettingsTab.all`에 한 줄씩 넣는다.
  - 키보드: 검색칸에서 시작한다. 글자로 항목 이름을 거르고, ↑↓로 옮기고, ↩로 연다(Account는 시트). ⌘F는 검색칸으로, esc는 검색어를 지운다.
  - 마지막에 본 페이지를 기억한다(`settings.tab`). 처음(저장값 없음)은 Connections. 예전 탭 값은 `MacSettingsTab.page(stored:execution:)`가 옮긴다: `shortcut` → Keyboard Shortcuts, `account`(이제 시트) · 모르는 값 → Connections. 저장된 `usage`는 실행을 쓸 수 없으면 Connections, 아직 모르면(credits를 읽는 중) 그대로.
- 로그아웃 · 만료 · 계정 삭제 · 계정 전환으로 계정이 떠나면 `SessionStore.onSignedOut`에서 런처 화면 · 목록 · 진행 중 작업을 지운다. Supabase · API 요청은 응답을 디스크 캐시에 남기지 않는다(`TaskforceClient.urlSession`). API가 401이면 인증 서버에 세션을 다시 묻고, 계정(다른 기기에서 지움) · 세션이 없을 때만 이 기기를 로그아웃한다. 살아 있으면 "Couldn't verify your sign-in. Sign out, then sign in again."

### 연결 · 동의 (양쪽)

- `POST /api/v1/connections/{provider}/start` → `ASWebAuthenticationSession`(callback scheme `taskforce`) → 돌아온 주소를 `ConnectionCallback`으로 읽는다. 앱 밖에서 열리면 `onOpenURL`(iOS) · `application(_:open:)`(Mac).
  400 invalid_request = "Coming soon", 409 conflict = 동의 화면 먼저. Google은 연결 전 읽는 것 세 줄, Gmail은 "Reconnect every 7 days".
- 동의 성공 콜백은 `?handoff=<id>`만 준다. 앱이 자기 Bearer 토큰으로 `POST /api/v1/connections/{provider}/complete {"handoff": id}`를 불러야 연결이 생긴다
  (서버는 연결을 시작한 사용자일 때만 잇는다: 남의 계정을 공격자 계정에 잇는 일을 막는다). 404 = 만료 · 내 것 아님 → "Couldn't connect. Try again.", 409 = 동의한 뒤 같은 handoff로 다시.
  실패 콜백은 `?status=denied|error|invalid_state`.
- 외부 AI 처리 동의: 기존 사용자도 모두 동의 없이 시작한다. 동의 전인데 연결이 있으면 로그인 뒤 한 번 동의 화면(iPhone)을 띄우고, 목록 위에 "Allow AI processing" 한 줄(iPhone 배너 · Mac 런처 맨 위)을 둔다. 목록 보기는 막지 않는다.
- 2단계(Microsoft 365 · Zoom · GitHub · Linear · Jira)는 "Want this" → `POST /api/v1/connection-requests`.
- 연결 목록은 `connections` 표를 RLS로 읽는다. Sync Now = `POST /connections/sync`, Disconnect = `DELETE /connections/:id`.
- 동기화 진행(C11, `ConnectionSync`): 서버 잠금 `sync_started_at`이 10분 안이면 그 줄에 작은 진행 표시 + "Syncing…". 연결 직후 · Sync Now 직후에는 잠금이 보이기 전에도 먼저 보여 준다(90초까지, 잠금이 보이면 서버를 따른다).
  동기화 중인 연결이 있으면 보이는 화면(iPhone 홈 · 계정 시트의 Connections · Mac 설정 · 떠 있는 런처)이 6초마다 연결을 다시 읽고, 끝나면 `NowStore.load()`로 새 할 일을 불러온다(Realtime `actions` 신호도 그대로).
  Sync Now는 서버가 끝날 때까지(최대 4분) 답하지 않아 요청 시간을 5분으로 둔다. 429 rate_limited(이미 동기화 중 · 방금 동기화)는 오류가 아니다: 연결을 다시 읽어 "Syncing…" 또는 "Synced just now"를 보여 준다(`SyncNowFailure`). 409는 동의 화면.
- 알림 기기 등록(C10, `PushCenter`): 허용돼 있으면 실행 · 로그인마다 토큰을 다시 받아 `POST /api/v1/devices {token, platform, environment, app_version}`. environment는 서명 프로필의 aps-environment(개발 서명 = sandbox, TestFlight · App Store = production), 프로필이 없으면 Debug = sandbox · Release = production(`PushEnvironment`). Sign Out 전에 `DELETE /api/v1/devices {token}`.
  알림 내용의 `kind`(confirmation · due · reconnect) · `action_id`(`action_ids`)로 열 곳을 정한다(`NotificationTarget`, 서버 `src/lib/notify/apns.ts`). `reconnect`(연결이 만료돼 다시 연결해야 함)는 할 일 없이 연결 화면을 연다: iPhone은 계정 시트의 Connections, Mac은 설정의 Connections. 모르는 `kind`는 앱만 연다.

## 구조

- `Taskforce/` — 앱
  - `Shared/` — Mac에서 재사용하는 계정·연결·동의·프로필·로그인·삭제 코드와 `NowStore` · `PushCenter` 등 화면 없는 공통 코드
  - 이전 `iOS/` 화면은 활성 소스 트리에서 제거됐다. 복원 위치와 범위는 [`docs/REUSE_BASE.md`](../docs/REUSE_BASE.md)를 본다.
  - `Mac/` — 앱 델리게이트 · 메뉴 막대 · 단축키 · 런처 패널/모델/화면 · 설정 창
- `Packages/TaskforceKit/`
  - `TaskforceKit` — 화면 없는 공유 코드
    - `APIClient`: 서버 `/api/v1` (모든 쓰기). `Authorization: Bearer <Supabase access token>`. 화면용 오류 문구는 영어
    - `TaskforceReads`: Supabase 직접 읽기 (RLS, 읽기 전용) — 할 일 상세 · 근거 · 원문 · 연결 · 원해요 · 오늘 끝낸 할 일(`status = done`, 기기 시간대 오늘 0시 뒤 `updated_at`, 최근 것부터 10개, 다른 사람 몫 제외)
    - `ActionChanges`: `actions` Realtime 구독. "바뀜" 신호로만 쓰고 지금 할 일은 항상 `/now`를 다시 불러온다 (로그인해 있는 동안 구독 하나: `ActionChangeFeed`)
    - `Models` · `AccountModels` · `Connections`: `src/lib/api/contract.ts`와 같은 모양 (새 필드는 없어도 읽는다)
    - 로그인: `SessionStore`(Apple · Google `signInWithIdToken`, `SignInNonce`, Google 로그인 직후 이름 `AccountNameFill`), Google 설정 `GoogleSignInConfig`(Info.plist), 로그인 방식 `SignInMethods`, 계정 삭제 때 폐기할 것 `AccountDeletionPlan`(서버에서 새로 읽은 사용자), 계정 이름 `AccountName`
    - 순수 규칙(테스트로 고정): 목록 구역 · 진행 상태(`WorkState`) · 먼저 보여 주는 내 변경 · 지울 수 있는 행 · 되돌리기(`TaskSections`: `TaskChange` · `TaskUndo` · `UndoOffer`), 런처 입력 모드 · 구역 · 거르기 · 붙여 넣은 원문 · 직접 추가 제목 · 이미 있는 할 일 · ↩ · ⌘↩(`Launcher`), Review 확인 이유 표기(`Labels` `ConfirmReasonText`), 영어 기한 · 시점 표기 · Task row 메타(`DisplayText`), 서비스 추정 · Source stack 접기(`SourceService`), 근거 고르기(`EvidenceDigest`), 연결 상태 · 줄 상태 · 동기화 진행 · 콜백 · 시작 · Sync Now 실패 분류(`Connections`), 알림 토큰 · APNs 환경 · 권한 · 누른 알림(`PushNotifications`), 단축키(`HotKeyShortcut`), `app_opened`(`AppOpenTracker` · `LauncherOpenThrottle`), 원문 줄 고르기(`SourceText` · `LineSelection`), 섹션 접기(`SectionCaps`: `/now` `section_limits`, 없으면 Review 2 · In Progress 5 · To Do 5, Done Today 접힌 한 줄, 찾는 중 · 범위 선택 중에는 접지 않음) · 범위와 개수(`TaskScope`) · 바뀜 점과 `seen` 보낼 때(`SeenTracker`) · 연결 · 새로고침 상태(`RefreshTracker` · `RefreshState`, 경로는 `Connectivity`) · iPhone 목록 글자 · 쓰기 막기 · 저장본 찾기(`PhoneHome`)
    - 저장본(`SavedNow` · `SavedNowStore`): 계정마다 마지막 목록의 제목 · 기한 · 상태만(원문 · 인용 · 상대 · id 없음, 사용자 결정 2026-10-03), App Group 컨테이너 `Library/Application Support/Taskforce/SavedNow/<user id>/now.json`, 백업 제외 · iOS 파일 보호. 로그아웃 · 계정 전환은 `removeAll()`, 계정 삭제는 `remove(account:)`(앱이 `SessionStore.onSignedOut`에서 부른다, Mac U1 PR4 · iPhone U1 PR5b)
  - `TaskforceUI` — Figma 토큰(Asset Catalog 색 세트, 이름 = Figma 변수 · 간격 · 모서리 · 글자)과 부품(Task status · Task row · Review card · Evidence · Source slip · Sources group · Source icon/stack · Launcher row · Keycap · 캡슐 버튼 · 유리 캡슐, Native 재설계 156:6의 Mac list row · Section header · Show N More · Key · Quiet button · Dropdown · Empty state · Action bar · Settings row/card/divider · 스크롤 아래 흐림), 부품마다 `#Preview`
    - `TaskforceUITests`: 모든 색 토큰이 Light · Dark로 풀리고 Figma 변수와 같은지, 글자 토큰 대비 4.5:1 이상인지
    - 서비스 로고는 Figma Source icon(Simple Icons 단색)의 글리프만 template 이미지로 두고, 타일은 토큰으로 그린다
- 순서 계산 · 판정은 서버에만 있다. 앱은 받은 순서를 그대로 보여준다.
- 로그인 세션은 App Group 공유 Keychain(데이터 보호 Keychain)에 저장한다. 공유 확장 · 위젯(Phase A2)을 붙이면 같은 세션을 읽을 수 있다(아직 없음).
