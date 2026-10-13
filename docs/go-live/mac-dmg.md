# Mac beta DMG 준비와 설치 확인

기록: 2026-10-05 KST. 이 절차는 기존 Mac 직접 배포 helper를 재사용해 DMG를 준비하고 설치 근거를 모으기 위한 것이다. 스크립트는 웹사이트에 파일이나 링크를 게시하지 않는다. Google-only 0.1.0 (3) DMG가 Developer ID 서명·공증 검증을 통과했다. 공개 download link와 실제 설치·로그인·연결 확인은 아직 완료되지 않았다.

## 재사용한 파일과 안전장치

`scripts/release-mac-dmg.sh`와 `apple/Config/ExportOptions-DeveloperID.plist`는 helper commit `f665bdfe42876d2917bef8d9a6f4cf44295bf464`에서 선별해 가져왔다. 전체 release branch는 합치지 않았다. helper checkout의 비공개 `Secrets.xcconfig`는 읽거나 복사하지 않았다. 원본 checkout의 native 설정은 값 비노출 유형 검사를 거쳐 Supabase URL·publishable key·Taskforce API host만 active ignored 설정 파일에 복사했다. 기본 출력 루트는 저장소 밖 임시 폴더 `${TMPDIR:-/tmp}/taskforce-release`이며 `--out <directory>`로 바꿀 수 있고, 그 아래 생성하는 버전/빌드 출력 폴더가 이미 있으면 중단해 이전 산출물과 로그를 보존한다. 재시도에는 새 build 번호를 사용한다. 내부 작업 폴더 정리는 해당 실행이 새로 만든 output 아래에서만 이뤄진다.

helper는 Release archive/export, Developer ID 서명과 entitlements/profile 확인(서명된 앱에 App Sandbox 권한이 있으면 중단, 아래 "샌드박스 끔"), 앱·DMG 공증·staple, Gatekeeper 확인, SHA-256 출력을 수행한다. `--skip-notarize`는 설치 배포용이 아니다. helper는 공개 사이트 업로드를 포함하지 않는다.

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
- 이 단계에 없는 것: 자동 업데이트(M1b) · bridge · 자식 프로세스 실행 · 샌드박스 빌드에서 보일 화면 문구(`AgentRuntimeEnvironment.isSandboxed`는 값만 제공한다).

## 현재 상태

| 항목 | 현재 근거 |
|---|---|
| 로그인·배포 경로 | 사용자가 Mac beta는 Google 로그인만 사용하도록 결정. 이 앱에서 native Apple 진입점·entitlement 제거, 기존 서버 Apple 지원과 기존 계정 데이터는 보존 |
| 서명된 DMG | `/Users/daniel/.codex/releases/taskforce/0.1.0-3/Taskforce-0.1.0-3/Taskforce-0.1.0-3.dmg`; 0.1.0 (3), 6,530,158 bytes, SHA-256 `849dc331fa8e46c6c56c2ccc3a7240b16a86eb9d0f785bebf98ab3aefa4d8cd8` |
| DMG·앱 서명과 배포 승인 | 2026-10-05 재확인: `codesign --verify --deep --strict`, 두 `stapler validate`, 앱·DMG Gatekeeper 판정이 통과. 양쪽 모두 `Notarized Developer ID`; Developer ID Application: Cheonghyeok Song (`U9DWQKQFMW`) |
| 앱 구성 | Info.plist 버전 0.1.0 (3), bundle id `dev.taskforcelabs.taskforce`; 서명 산출물에서 production API host·Supabase 설정·Google client 설정 확인. 비밀 설정 값은 기록하거나 출력하지 않음 |
| 작업본 설정 | active worktree의 ignored `Secrets.xcconfig`는 mode `600`, Git 제외. required Supabase·Google 설정은 helper가 비노출 조건 검사로 확인 |
| 웹사이트 DMG/다운로드 링크 | website PR [#29](https://github.com/songch9511/taskforce/pull/29)은 Draft. 숨은 경로와 metadata guard가 준비됐고 Preview 검사는 통과했지만 DMG를 업로드하거나 production에 공개하지 않음 |

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

베타는 무료이며 사용자당 실제 공급자 원가의 누적 한도는 `$10`이고 자동 충전·월별 초기화는 없다. 계정별 ledger·요약 API와 Mac 사용량 화면, chat·Ask·실행·원문 추출·embedding callsite 가드가 구현됐다. 가격이 알려지지 않은 경우 예약을 보존하고, 실제 사용량이 예약을 초과하면 기록한 뒤 이후 유료 요청을 차단한다. 양수 `cache_read`는 상한이 검증된 endpoint에서 최악의 경우로 예약해 정상 호출을 허용하며 `max_price`를 넘는 endpoint와 알려지지 않은 요금·cache-write는 계속 fail-closed다. 전체 테스트는 통과했지만 이 변경은 아직 merge/deploy 전이며 두 budget migration도 운영에 적용되지 않았다. 공유 OpenRouter key 한도·결제 설정은 변경하지 않았다. Taskforce에 연결된 실제 OpenRouter 계정의 운영 privacy 설정/귀속은 확인되지 않았다.

## 확인한 로컬 조건

현재 작업본은 `codex/taskforce-mac-beta-active-20261005`의 `64bdb480b04cb538fd57b728dd0fdf7443004b7d` 기준이다. Xcode 설정은 `SUPPORTED_PLATFORMS=macosx`, `MACOSX_DEPLOYMENT_TARGET=15.0`, `ENABLE_HARDENED_RUNTIME=YES`; Developer ID signed artifact는 위 표에 있다.

검증은 `TaskforceKit` 59 suites / 514 tests, macOS 앱 9 suites / 86 tests, auth 회귀 96 tests, unsigned Release build, backend 175 files / 2,253 tests, disposable PostgreSQL 3 files / 23 tests, lint, typecheck, build와 `npm run eval -- --labels`를 통과했다. 비용·오류 처리 변경은 운영 로직 테스트로 검증했다. 추출·판정·병합·프롬프트를 바꾸지 않아 실제 모델 채점은 다시 실행하지 않았다. 이 로컬 검사는 실제 제공자 OAuth·연결·기기 E2E를 대신하지 않는다.
