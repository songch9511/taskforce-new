# Mac beta DMG 준비와 설치 확인

기록: 2026-10-05 KST. 이 절차는 기존 Mac 직접 배포 helper를 재사용해 DMG를 준비하고 설치 근거를 모으기 위한 것이다. 스크립트는 웹사이트에 파일이나 링크를 게시하지 않는다. Google-only 0.1.0 (3) DMG가 Developer ID 서명·공증 검증을 통과했다. 실제 설치/런처 조작 및 OAuth·취소·연결 E2E와 공개 download link는 아직 완료되지 않았다.

## 재사용한 파일과 안전장치

`scripts/release-mac-dmg.sh`와 `apple/Config/ExportOptions-DeveloperID.plist`는 helper commit `f665bdfe42876d2917bef8d9a6f4cf44295bf464`에서 선별해 가져왔다. 전체 release branch는 합치지 않았다. helper checkout의 비공개 `Secrets.xcconfig`는 읽거나 복사하지 않았다. 원본 checkout의 native 설정은 값 비노출 유형 검사를 거쳐 Supabase URL·publishable key·Taskforce API host만 active ignored 설정 파일에 복사했다. 기본 출력 루트는 저장소 밖 임시 폴더 `${TMPDIR:-/tmp}/taskforce-release`이며 `--out <directory>`로 바꿀 수 있고, 그 아래 생성하는 버전/빌드 출력 폴더가 이미 있으면 중단해 이전 산출물과 로그를 보존한다. 재시도에는 새 build 번호를 사용한다. 내부 작업 폴더 정리는 해당 실행이 새로 만든 output 아래에서만 이뤄진다.

helper는 Release archive/export, Developer ID 서명과 entitlements/profile 확인(서명된 앱에 App Sandbox 권한이 있으면 중단, 아래 "샌드박스 끔"), 앱·DMG 공증·staple, Gatekeeper 확인, 선택 단계로 로컬 Sparkle appcast 만들기(아래 "자동 업데이트"), SHA-256 출력을 수행한다. `--skip-notarize`는 설치 배포용이 아니다. helper는 공개 사이트 업로드를 포함하지 않는다(appcast도 올리지 않는다).

## 샌드박스 끔 (DEC-1 A, 2026-10-13)

Mac 앱은 Developer ID DMG 경로를 그대로 두고 **App Sandbox만 끈다.** 이유: 샌드박스 앱이 띄운 자식 프로세스는 샌드박스를 물려받아 사용자의 `claude` · `codex` 로그인(`~/.claude`, Keychain)과 PATH에 닿지 못한다(bridge는 앱 안에서 그 프로세스를 띄운다).

- 권한 파일 `apple/Taskforce/Taskforce-macOS.entitlements`에서 `com.apple.security.app-sandbox`와 샌드박스 전용 `com.apple.security.network.client`를 뺐다. App Group · `keychain-access-groups` · `aps-environment`와 Hardened Runtime(공증에 필요)은 그대로다.
- 배포 회귀 방지: `scripts/release-mac-dmg.sh`가 서명 뒤 `codesign -d --entitlements :-` 결과에 `com.apple.security.app-sandbox` 키가 있으면(값과 상관없이) 공증 전에 중단한다. 소스 쪽은 `apple/TaskforceTests/MacEntitlementsTests.swift`가 권한 파일 · 빌드 설정 · 이 검사 단계를 가짜 권한 출력으로 확인한다.
- 설정 1회 이전: 샌드박스를 끄면 UserDefaults 위치가 `~/Library/Containers/<번들 id>/Data/Library/Preferences/`에서 `~/Library/Preferences/`로 바뀐다. 앱 시작의 첫 코드(`TaskforceApp.init`)에서 `LegacySandboxMigration`(TaskforceKit)이 옛 plist를 읽어 **새 도메인에 없는 키만** 쓰고 표식 키 `tf.legacySandboxMigration.v1`을 표준 도메인에 남긴다.
  - 대상 도메인은 번들 id와 앱이 여는 suite 전부(`AppDefaultsDomains`: 지금은 `<번들 id>.work-pins`). 새 suite를 만들면 이 목록에 더해야 하고, `AppDefaultsDomainsTests`가 소스가 여는 설정 도메인(여러 줄 `UserDefaults(` · `.init(suiteName:)` · `CFPreferences…`)과 맞는지 확인한다.
  - 이 코드는 macOS 전용이다(`#if os(macOS)`): TaskforceKit은 `.iOS(.v18)`에서도 컴파일돼야 한다. 검사: `cd apple/Packages/TaskforceKit && xcodebuild -scheme TaskforceKit -destination 'generic/platform=iOS Simulator' build`.
  - 옮기지 않는 것: App Group 컨테이너의 저장본(`SavedNow`)과 Keychain 세션은 샌드박스와 상관없이 같은 위치다. URL 캐시 · HTTP 저장소 · 저장된 창 상태는 다시 만들어진다. 지금 앱에는 Application Support · Caches에 직접 쓰는 코드가 없다.
  - 파일 없음 · 깨진 plist(형식 오류)는 그 도메인만 건너뛰고 표식을 쓴다(다시 시도하지 않는다). **권한 오류(EPERM · EACCES · 읽기 권한 없음)는 완료가 아니다**: 표식 없이 시도 횟수 키 `tf.legacySandboxMigration.attempts`만 올리고, 3번째에도 권한 오류면 그때 표식을 쓴다(무한 재시도 없음). 다른 도메인에서 옮긴 키는 그대로 두고 다음 시도에서 키 단위로 건너뛰므로 중복이 없다.
  - 결과는 OSLog(카테고리 `legacy-sandbox-migration`)에 키 이름 · 값 · 경로 없이 개수만 남는다: 결과는 `.notice`(저장됨), 권한 오류는 `.error`.
  - 샌드박스 안이면(환경 변수 `APP_SANDBOX_CONTAINER_ID` 또는 홈 디렉터리가 `…/Library/Containers/…`) 부르지 않고 표식도 쓰지 않는다. **Debug 빌드는 기본으로 이전하지 않는다**: Debug는 실사용 번들 id를 쓰므로 개발 실행이 실사용 컨테이너를 읽고 표식을 미리 써서 나중의 DMG 이전을 소모하면 안 된다. Debug에서 시험하려면 실행 인자 `-TF_LEGACY_MIGRATION YES`(인자 영역만, 저장된 설정으로는 켜지지 않는다)를 준다. **주의**: 실사용 번들 id의 Debug를 이 인자로 돌리면 실사용 번들 id 도메인에 표식 · 시도 키(`tf.legacySandboxMigration.v1` · `.attempts`)가 써져 나중 DMG의 1회 이전이 소모된다. 옵트인 시험 뒤에는 앱을 끈 상태에서 두 키를 지우거나, 처음부터 격리 접두어(`BUNDLE_ID_PREFIX=dev.taskforcelabs.<이름>`)로 시험한다.
  - 옛 plist에 이전기 자신의 키(`tf.legacySandboxMigration.` 접두어)가 있어도 복사하지 않는다(옛 값이 완료 표식이 되지 않게).
- 되돌리기: 옛 컨테이너 파일은 지우지도 바꾸지도 않는다. 샌드박스 빌드로 돌아가려면 권한 파일에 두 키를 되돌리면 되고, 샌드박스 앱은 컨테이너의 이전 설정을 그대로 읽는다(샌드박스를 끄고 쓰는 동안 바꾼 설정은 컨테이너에 없다). **배포 검사(`reject_sandbox_entitlement`)와 `MacEntitlementsTests`도 함께 되돌린다**: 권한 파일만 되돌리면 둘 다 실패한다. 이전을 다시 돌리려면 앱을 끈 상태에서 표준 도메인의 표식 키 하나(와 시도 횟수 키)만 지운다.
- 이 변경 전에 만든 DMG(0.1.0 (3) 포함)는 권한 파일이 샌드박스였던 커밋의 빌드다. 새 DMG를 만들 때 위 검사가 통과해야 한다.
- 서명된 빌드에서만 확인되는 것(이 단계에서 서명 · 공증 · DMG는 만들지 않았다): (1) 비샌드박스 Developer ID 서명에서도 App Group 컨테이너와 Keychain 접근 그룹이 샌드박스 때와 같이 동작하는지, (2) 비샌드박스 앱이 자기 옛 컨테이너 plist를 읽을 때 macOS가 다른 앱의 데이터 접근 동의를 묻는지(거부되면 권한 오류 → 표식 없이 최대 3번 시도, 옛 파일은 남는다), (3) 권한 파일의 `aps-environment`가 내보내기에서 `production`으로 바뀌는지(기존 검사).
- 남은 위험(PATH): 샌드박스를 꺼도 LaunchServices(Finder · Dock)로 뜬 앱은 launchd의 기본 PATH를 받는다. 사용자의 CLI(`claude` · `codex`)를 찾는 PATH 해석은 bridge(D3a)가 한다.
- 이 단계에 없는 것: bridge · 자식 프로세스 실행 · 샌드박스 빌드에서 보일 화면 문구(`AgentRuntimeEnvironment.isSandboxed`는 값만 제공한다). 자동 업데이트는 다음 절.

## 자동 업데이트 (Sparkle 2, OA M1b)

Mac 앱은 [Sparkle 2](https://sparkle-project.org/documentation/)로 스스로 업데이트한다. 샌드박스를 끈 구성(위 절)을 전제로 쓴다. **이 단계에서 키 생성 · 서명 · 공증 · DMG · appcast 게시는 하지 않았다.** 코드는 연결돼 있지만 피드 주소와 공개 키가 비어 있어 **지금 빌드의 업데이터는 꺼져 있다**: 시작하지 않고 메뉴 항목 "Check for Updates…"는 비활성이다. 아래 "출시 전에 사용자가 할 일"을 채워야 켜진다.

- 의존성: Swift Package `https://github.com/sparkle-project/Sparkle`을 **정확한 버전 2.10.0** 하나로 고정했다(`apple/project.yml`의 `exactVersion` + 커밋된 `Taskforce.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`). **Mac 앱 타깃(`Taskforce`)에만** 연결하고 `TaskforceKit` · 시험 타깃에는 넣지 않는다(`UpdaterBuildSettingsTests`가 고정 버전 · 연결 타깃을 고정한다). 버전을 올릴 때는 `project.yml`의 숫자를 바꾸고 `cd apple && xcodegen` 뒤 `xcodebuild -resolvePackageDependencies -project apple/Taskforce.xcodeproj -scheme Taskforce`로 `Package.resolved`를 갱신한다. 공개된 지 2주 넘은 정식 2.x만 고른다.
- 설정값: Info.plist의 `SUFeedURL` · `SUPublicEDKey`는 빌드 설정 `SPARKLE_FEED_URL` · `SPARKLE_PUBLIC_ED_KEY`에서 온다. Debug · Debug-Test(`Config/Base.xcconfig`)는 빈 값이고, 채울 자리는 `Config/Release.xcconfig`다. 둘 다 공개 값이라 커밋한다(비밀 아님).
- 업데이터가 켜지는 조건(`UpdateConfiguration`): Release 빌드이고, XCTest 호스트가 아니고, 피드 주소가 http(s) 주소이고(**앞뒤 공백 · 줄바꿈이 있으면 안 된다**: Sparkle은 Info.plist 원문을 그대로 읽어서, 검사한 값과 쓰는 값이 달라지지 않게 그런 피드는 켜지 않는다), 공개 키가 base64 32바이트(ed25519 공개 키 크기)일 때(키의 앞뒤 공백은 Sparkle도 지운다). 하나라도 아니면 Sparkle 객체를 만들지 않는다(크래시 · 오류 창 없음. 시작했는지와 이유만 OSLog `category: updater`에 주소 · 키 없이 남는다).
- 앱 쪽: `SPUStandardUpdaterController` 하나(`AppUpdater`)를 앱 시작 때 만든다. 메뉴 막대 메뉴와 앱 메뉴(설정 창이 앞일 때)에 표준 항목 "Check for Updates…"가 있다. 자동 확인은 Sparkle 기본 동작을 따른다(두 번째 실행에서 사용자에게 자동 확인을 켤지 묻는다). 별도 설정 화면은 없다.
- 종료 전 확인: 실행 중인 에이전트 턴이 있을 때 업데이트 재시작을 막는 일은 bridge WP 몫이다. 자리는 `AppUpdater`의 `updaterShouldRelaunchApplication` → `UpdateRelaunchPolicy.allowsRelaunchNow()`(지금은 항상 `true`)다.

### 출시 전에 사용자가 할 일

1. **서명 키 만들기** (사용자 Mac에서 한 번). Sparkle 도구는 Xcode가 패키지와 함께 내려받는다: 스크립트 아카이브라면 `<출력 폴더>/Taskforce-<버전>-<빌드>/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`, Xcode에서 열었다면 `~/Library/Developer/Xcode/DerivedData/Taskforce-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`. 그 안의 `generate_keys`를 인자 없이 실행하면 **개인 키는 로그인 Keychain에만** 저장되고(서비스 `https://sparkle-project.org`, 계정 `ed25519`) 공개 키가 출력된다. 다시 실행하면 같은 공개 키를 보여 주고, `generate_keys -p`는 공개 키만 출력한다. 개인 키를 파일로 내보내거나(`-x`) 채팅 · 저장소 · 로그에 붙이지 않는다. 키를 잃으면 이미 설치된 앱에는 더 이상 업데이트를 줄 수 없으니 백업은 사용자가 정한 안전한 곳에 한다.
2. **값 넣기**: `apple/Config/Release.xcconfig`의 `SPARKLE_FEED_URL`(appcast의 HTTPS 주소)과 `SPARKLE_PUBLIC_ED_KEY`(위에서 출력된 공개 키). xcconfig에서 `//`는 주석이라 URL은 `https:/$()/…`로 적고, 공개 키에 `//`가 들어 있으면 그 자리도 `/$()/`로 적는다.
3. **호스팅 정하기**: appcast.xml과 DMG를 올릴 곳(HTTPS)을 사용자가 정한다. 이 저장소의 스크립트는 올리지 않는다.
4. 업데이터가 들어 있는 첫 빌드부터 업데이트를 받을 수 있다. Sparkle이 없는 기존 DMG(0.1.0 (3) 포함) 사용자는 그 한 번은 새 DMG를 직접 설치한다.

### appcast 만들기 · 올리기

`scripts/release-mac-dmg.sh`가 공증 · Gatekeeper 확인 뒤 **선택 단계**로 `generate_appcast`(Sparkle 도구, 아카이브의 `DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`. 다른 곳에 있으면 환경 변수 `SPARKLE_BIN_DIR`)를 부른다. 다음 중 하나라도 없으면 **건너뛰고 실패하지 않는다**: 앱 Info.plist의 `SUFeedURL` · `SUPublicEDKey`, 도구, Keychain의 Sparkle 서명 키(항목이 있는지만 속성으로 확인한다: 키 값은 읽지도 출력하지도 않는다. 항목이 없을 때 도구를 그냥 부르면 서명하지 못해 실패한다: 2.10.0에서 확인. 조회 종료 상태 44만 "키 없음"이고, 그 밖의 조회 실패는 "Keychain 조회가 실패했습니다: 종료 상태 N"으로 따로 알리며 이때도 건너뛴다). `--skip-notarize` DMG에는 만들지 않는다. 도구가 돌았는데 실패하면 로그 경로를 보여 주고 멈춘다.

- 서명은 `generate_appcast`가 사용자 Keychain에서 직접 한다. 처음에는 macOS가 "generate_appcast가 Keychain 항목을 쓰려 한다"는 허용 창을 띄울 수 있다.
- 결과: `<출력 폴더>/Taskforce-<버전>-<빌드>/appcast/appcast.xml`과 DMG 사본(로컬만). 이전 버전 항목을 이어 가려면 `--appcast-dir <폴더>`로 같은 폴더를 계속 쓰고 이전 DMG도 그 폴더에 둔다(도구가 폴더의 아카이브를 훑어 appcast를 다시 만든다. 기본으로 최근 3개 버전을 유지).
- 다운로드 주소 접두어는 기본이 피드 주소의 폴더(`https://host/path/appcast.xml` → `https://host/path/`)이고 `--download-url-prefix <주소>`로 바꾼다. 도구가 접두어에 파일 이름을 상대 주소로 이어 붙이므로 끝에 `/`가 있어야 하고, 스크립트가 없으면 붙인다. 출력된 appcast의 `enclosure url`을 올리기 전에 눈으로 확인한다.
- **올리기는 사용자가 한다**: `appcast.xml`을 `SUFeedURL`이 가리키는 주소에, DMG를 접두어 아래에 올린다. 올리기 전에는 새 버전이 사용자에게 보이지 않는다.

### 되돌리기

- 배포 중단: 올린 appcast에서 그 버전 `<item>`을 지우거나 이전 appcast로 바꾼다. 새로 확인하는 사용자는 더 이상 받지 않는다. **이미 설치한 사용자는 낮은 버전으로 자동으로 돌아가지 않는다**(Sparkle은 더 높은 빌드 번호만 업데이트로 본다): 고친 빌드를 더 높은 빌드 번호로 내야 한다.
- 앱 쪽 끄기: 다음 빌드에서 `SPARKLE_FEED_URL` 또는 `SPARKLE_PUBLIC_ED_KEY`를 비우면 그 빌드는 업데이터를 시작하지 않는다.
- 코드 되돌리기: Sparkle 연결 커밋을 되돌리고 `cd apple && xcodegen`. 설정 이전 · 샌드박스 끔(위 절)은 그대로 둔다.

### 확인하지 못한 것 (서명 · 공증한 빌드에서만 확인된다)

이 단계는 서명 · 공증 · DMG를 만들지 않았다. 따라서 (1) Developer ID로 다시 서명한 뒤에도 앱 안의 `Sparkle.framework`와 그 보조 도구(`Autoupdate` · `Updater.app` · XPC 서비스)가 Hardened Runtime 아래에서 서명 검증을 통과하는지, (2) 실제 업데이트가 내려받기 · 설치 · 재시작까지 되는지, (3) Dock 아이콘이 없는 에이전트 앱(`LSUIElement`)에서 예약된 확인 창이 다른 창 뒤에 뜨는지(Sparkle은 시작 직후가 아니면 포커스를 가져오지 않는다. 눈에 띄게 하려면 Sparkle의 "gentle reminders"가 필요하고 지금은 만들지 않았다, 화면 설계 빈칸)는 확인하지 못했다. 첫 서명 빌드에서 사람이 한 번 본다.

## 현재 상태

| 항목 | 현재 근거 |
|---|---|
| 로그인·배포 경로 | 사용자가 Mac beta는 Google 로그인만 사용하도록 결정. 이 앱에서 native Apple 진입점·entitlement 제거, 기존 서버 Apple 지원과 기존 계정 데이터는 보존 |
| 서명된 DMG | `/Users/daniel/.codex/releases/taskforce/0.1.0-3/Taskforce-0.1.0-3/Taskforce-0.1.0-3.dmg`; 0.1.0 (3), 6,530,158 bytes, SHA-256 `849dc331fa8e46c6c56c2ccc3a7240b16a86eb9d0f785bebf98ab3aefa4d8cd8` |
| DMG·앱 서명과 배포 승인 | 2026-10-05 재확인: `codesign --verify --deep --strict`, 두 `stapler validate`, 앱·DMG Gatekeeper 판정이 통과. 양쪽 모두 `Notarized Developer ID`; Developer ID Application: Cheonghyeok Song (`U9DWQKQFMW`) |
| 앱 구성 | Info.plist 버전 0.1.0 (3), bundle id `dev.taskforcelabs.taskforce`; 서명 산출물에서 production API host·Supabase 설정·Google client 설정 확인. 비밀 설정 값은 기록하거나 출력하지 않음 |
| 작업본 설정 | active worktree의 ignored `Secrets.xcconfig`는 mode `600`, Git 제외. required Supabase·Google 설정은 helper가 비노출 조건 검사로 확인 |
| 코드와 운영 budget gate | PR [#98](https://github.com/songch9511/taskforce-new/pull/98)의 source `41dba077`가 `fb1f5bf8`로 병합·배포됐다. 승인된 두 budget migration을 운영에 적용하고 table/RLS/RPC 권한 및 오류 constraint를 읽기로 확인했다. 무인증 budget 요청은 401이며 인증 summary·실제 paid call은 아직 미검증 |
| 실행 준비 확인 | 2026-10-05 운영 집계: `POST /api/v1/runs` 무인증 401로 route의 flag→auth 순서상 `EXECUTION_ENABLED`가 켜진 상태임을 확인. global · manual · Taskforce 스위치는 열림, auto · full은 차단. 실행 actor 1개 중 1개가 consent · 20 credits 이상 · 열린 본인 Action 조건을 만족했고 actor 연결 가용 크레딧은 2,000. 이는 준비 상태이며 실제 run/AI 실행 증거가 아님 |
| 현재 AI spend | 새 budget ledger 집계는 attempts 0, confirmed 0 USD, reserved 0 USD. 실제 사용자 자료로 AI 요청을 하지 않음 |
| 웹사이트 DMG/다운로드 링크 | website PR [#29](https://github.com/songch9511/taskforce/pull/29)은 Draft. 숨은 경로와 Google-only metadata 안내가 준비됐고 Preview 검사는 통과했지만 DMG를 업로드하거나 production에 공개하지 않음 |

Developer ID export·공증 막힘은 Google-only 구성으로 해결됐다. 이 산출물의 로컬 서명·공증 검증은 실제 OAuth·설치 사용성 검증을 대신하지 않는다. Apple-only 사용자는 이 설치본으로 로그인할 수 없고, 기존 계정 데이터는 보존되므로 Apple 로그인 경로로 돌아가야 한다. 계정 병합이나 보호장치 우회는 하지 않는다.

## 준비 완료 기준

1. 현재 승인된 출시 경로는 Google-only 직접 Developer ID DMG다. 로그인 방식과 Apple-only 계정의 영향이 사용자에게 고지됐다. 계정 삭제의 재인증 보호는 유지한다.
2. active worktree의 ignored `Secrets.xcconfig`는 mode `600`이며 Git에 포함되지 않는다. 값은 로그·문서·채팅에 복사하지 않는다. Release config는 API host와 Google 공개 client 설정을 고정한다.
3. DMG 0.1.0 (3)은 export·notarization·stapling·Gatekeeper 검증을 통과했다. 재검증에는 해시, `hdiutil verify`, app/DMG `codesign`, `stapler validate`, `spctl`을 사용한다.
4. 다음은 지정한 검증 계정으로 설치본을 열어 Google OAuth·세션 복원·취소/재시도와 `.local` 로그아웃을 확인하고, 실제 연결 → 원문 수집 → 할 일 표시까지 증거를 남기는 것이다. 실제 AI 요청은 운영 예산 migration과 guarded 코드 배포가 준비되기 전에는 보내지 않는다.
5. 별도의 깨끗한 Mac은 확보되지 않았다. 현재 Mac 설치/실행 확인도 아직 완료로 보고하지 않는다.
6. website PR #29에 검증된 DMG와 일치하는 metadata를 넣어 Preview에서 URL·hash·size를 확인한 다음, 실제 앱 E2E 통과 뒤 승인된 website main에 병합해 공개한다. 현재 URL은 hidden route뿐이며 download button은 disabled; DMG는 Git에 복사되지 않았다.

AI 실행을 베타에서 열기 전에는 [런북 9-1 차단 스위치](runbook.md#9-1-차단-스위치-execution_controls), [9-2 실행 주체](runbook.md#9-2-실행-주체-execution_actors), [9-3 크레딧 지급](runbook.md#9-3-크레딧-지급-grant_credits), [9-6 운영 켜기 순서](runbook.md#9-6-운영-켜기-순서-줄마다-승인-한-번)를 따라야 한다. 코드의 flag·actor·credit 규칙은 현재 운영 설정 검증을 대신하지 않는다.

## AI·계정 안내가 필요한 배포 조건

backend 구현 보고상 OpenRouter 호출에는 `data_collection=deny`와 `zdr=true`가 요청되지만, Taskforce에 연결된 실제 OpenRouter 계정의 운영 설정과 계정 귀속은 확인되지 않았다. 공개 개인정보 처리방침의 공급자 보관·학습 문구와 실제 설정이 맞는지 확인하기 전에는 그 보호 조건이 운영에서 검증됐다고 안내하지 않는다. Taskforce에는 할 일, 초안, run·사용량 정보의 자체 저장·삭제 동작이 있으므로 공급자 보관과 섞어 설명하지 않는다.

계정 삭제는 계정과 연결된 저장행을 삭제하고 connector token을 정리한다. Apple revoke는 제한 시간 안에 best-effort이며, 실패해도 계정 삭제를 막지 않는다. Google 권한 해제는 현재 기기에 남은 SDK 상태에 한정되고 비동기 처리된다. 다른 기기의 토큰만 있는 경우 이 앱에서 Google 연결 해제를 완료할 수 있다고 단정하지 않는다. 다른 기기 캐시는 다음 서버 접속 때 정리되며 삭제 직후 access token이 만료되기 전까지 모든 API가 차단되는지는 live 검증되지 않았다. 이 경계는 beta 안내와 실제 계정 화면에 그대로 맞춰야 한다.

베타는 무료이며 사용자당 실제 공급자 원가의 누적 한도는 `$10`이고 자동 충전·월별 초기화는 없다. 계정별 ledger·요약 API와 Mac 사용량 화면, chat·Ask·실행·원문 추출·embedding callsite 가드가 구현·배포됐다. 승인된 두 budget migration도 운영에 적용하고 권한을 검증했다. 가격이 알려지지 않은 경우 예약을 보존하고, 실제 사용량이 예약을 초과하면 기록한 뒤 이후 유료 요청을 차단한다. 양수 `cache_read`는 상한이 검증된 endpoint에서 최악의 경우로 예약해 정상 호출을 허용하며 `max_price`를 넘는 endpoint와 알려지지 않은 요금·cache-write는 계속 fail-closed다. 실제 OAuth·인증 요약·유료 AI 요청과 supplier cost 정산은 아직 미검증이다. 공유 OpenRouter key 한도·결제 설정은 변경하지 않았다. Taskforce에 연결된 실제 OpenRouter 계정의 운영 privacy 설정/귀속은 확인되지 않았다.

### 기존 beta 계정과 새 계정 준비

2026-10-05 운영 집계는 실행 actor 1개와 가용 credit 계정 1개를 확인했다. 그 actor는 AI 동의, 초안 최소 추정치(`DRAFT_ESTIMATE_CREDITS`, 현재 20) 이상의 잔액, 열린 본인 Action을 모두 만족했다. 실행 credit 합계는 2,000이며 새 AI spend ledger는 0 attempt / $0 confirmed / $0 reserved였다. 실행 허용 스위치는 global · manual · Taskforce provider가 열려 있고 auto · full이 닫혀 있다. 무인증 `POST /api/v1/runs`가 401이었고, 서버 route가 기능 flag를 인증보다 먼저 검사하므로 Production `EXECUTION_ENABLED`가 켜진 것으로 확인했다. 이는 실제 인증·run 생성·AI 호출 테스트는 아니다.

새 베타 계정에는 기존 운영자 절차만 적용한다. Google 로그인이 끝나 auth user가 만들어진 뒤 [런북 9-2](runbook.md#9-2-실행-주체-execution_actors)의 정확한 계정 이메일 조회로 해당 사용자 하나만 `execution_actors`에 추가한다. [런북 9-3](runbook.md#9-3-크레딧-지급-grant_credits)의 `grant_credits`로 초안 최소치 이상 필요한 실행 크레딧을 지급하고, 매 지급마다 새 UUID를 사용한다. 구매나 자동 지급은 없고 전체 계정 허용도 하지 않는다. 사용자당 실제 AI 공급자 원가 `$10` cap은 별도 자동 예산이며 실행 크레딧과 서로 대체되지 않는다. 이번 출시 준비에서 actor·credit 데이터는 쓰지 않았다.

2026-10-05 OpenRouter 공개 카탈로그 조회는 현재 소스 기본 경로와 일치했다: `z-ai/glm-5.3-flash` 모델에 Fireworks · Together · DeepInfra endpoint가 있었고, `openai/text-embedding-3-small`에 Azure endpoint, `typesafe/jev-1.13`에 TypeSafe endpoint가 있었다. decisions 모델 필터 요청은 200으로 Jev를 반환했고 세 경로의 현재 catalog 가격은 budget parser 형식으로 읽혔다. 이는 [모델 목록](https://openrouter.ai/docs/api/api-reference/models/get-models), [embedding 목록](https://openrouter.ai/docs/api/api-reference/embeddings/list-embeddings-models), [Jev decisions API 가이드](https://openrouter.ai/blog/tutorials/how-to-use-jev/)와 맞는다. Production secret 환경의 `LLM_MODEL`/provider override 값은 확인하지 않았고, live paid call은 하지 않았다.

## 확인한 로컬 조건

Production source SHA는 `fb1f5bf8c878134f80d4117094c48cb3e3adf9f2` (PR source `41dba07725b13bd9a2f3d05ff5399a342833e07b`)이다. Xcode 설정은 `SUPPORTED_PLATFORMS=macosx`, `MACOSX_DEPLOYMENT_TARGET=15.0`, `ENABLE_HARDENED_RUNTIME=YES`; Developer ID signed artifact는 위 표에 있다.

검증은 `TaskforceKit` 59 suites / 514 tests, macOS 앱 9 suites / 86 tests, auth 회귀 96 tests, unsigned Release build, backend 175 files / 2,253 tests, disposable PostgreSQL 3 files / 23 tests, lint, typecheck, build와 `npm run eval -- --labels`를 통과했다. 비용·오류 처리 변경은 운영 로직 테스트로 검증했다. 추출·판정·병합·프롬프트를 바꾸지 않아 실제 모델 채점은 다시 실행하지 않았다. 이 로컬 검사는 실제 제공자 OAuth·연결·기기 E2E를 대신하지 않는다.
