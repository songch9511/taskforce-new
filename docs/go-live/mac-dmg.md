# Mac 앱 DMG 배포 (Developer ID 서명 · 공증)

관련 문서: [런북 5장 Apple](runbook.md#5-apple) · [apple/README](../../apple/README.md) · [App Store · TestFlight](app-store.md)

작성: 2026-10-04. TestFlight · App Store를 거치지 않고 Mac 앱을 **한 사람(창업자)에게 직접 건넬 때**의 절차다. 앱을 Developer ID로 서명하고 Apple에 공증한 DMG 한 파일을 만들어, 사람이 모르는 웹 주소로만 내려받게 한다. 외부 공개용이 아니다(공개는 TestFlight 링크, [런북](runbook.md) 체크리스트).
"사용자"는 계정 · 키체인 비밀번호처럼 코드로 대신할 수 없는 일, "코드"는 `scripts/release-mac-dmg.sh`가 하는 일이다.

| 항목 | 값 |
|---|---|
| 서명 | `Developer ID Application: … (U9DWQKQFMW)` (이 Mac 키체인) + Developer ID 프로비저닝 프로필(자동 서명 + `-allowProvisioningUpdates`) |
| 공증 | `xcrun notarytool` (키체인 프로필 `taskforce-notary`), 앱과 DMG 둘 다 공증 · 스테이플 |
| 서버 | Release 구성이 `https://api.taskforcelabs.dev`로 고정 (`apple/Config/Release.xcconfig`) |
| 알림 | `aps-environment` = `production` (아니면 스크립트가 멈춘다) |
| 산출물 | `dist/Taskforce-<버전>-<빌드>/Taskforce-<버전>-<빌드>.dmg` (`dist/`는 git 무시) |
| 업데이트 | 자동 업데이트 없음. 새 DMG를 다시 건넨다 (4장) |

## 1. 한 번만 하는 준비 (사용자)

1. **공증 프로필 만들기.** 비밀번호는 Apple ID 비밀번호가 아니라 **앱 암호**다. [appleid.apple.com](https://appleid.apple.com) → 로그인 및 보안 → 앱 암호 → 새로 만들기(이름 예: `taskforce-notary`).
   ```bash
   xcrun notarytool store-credentials taskforce-notary --apple-id <Apple ID> --team-id U9DWQKQFMW
   ```
   비밀번호를 물으면 앱 암호를 붙여 넣는다. 자격 증명은 이 Mac의 키체인에만 저장된다. 저장소 · 스크립트 · 채팅에는 남기지 않는다.
   확인: `xcrun notarytool history --keychain-profile taskforce-notary`가 오류 없이 목록(비어 있어도 됨)을 낸다.
2. **서명 인증서.** `security find-identity -v -p codesigning`에 `Developer ID Application: … (U9DWQKQFMW)`가 있어야 한다(없으면 Xcode → Settings → Accounts → Manage Certificates에서 Developer ID Application 추가).
3. **Xcode가 Apple 계정에 로그인**돼 있어야 한다. 스크립트가 `-allowProvisioningUpdates`로 Developer ID 프로필을 발급 · 갱신한다. 이 앱의 권한(App Group · Sign in with Apple · 알림 · Keychain 그룹)은 제한된 권한이라 프로필 없이는 앱이 실행되지 않는다.
   App ID `dev.taskforcelabs.taskforce`에 App Groups · Sign In with Apple · Push Notifications가 켜져 있어야 한다([런북 5장](runbook.md#5-apple), [apple/README](../../apple/README.md) 4 · 5번).
4. **`apple/Config/Secrets.xcconfig`가 이 Mac에 있어야 한다**(Supabase URL · 공개 키. 커밋되지 않는 파일, [apple/README](../../apple/README.md) 처음 한 번 1번). 워크트리에서 돌린다면 주 체크아웃의 파일을 복사한다.

## 2. 실행 (코드 + 사용자)

저장소 맨 위에서:

```bash
scripts/release-mac-dmg.sh --version 0.1.0 --build 3
```

| 옵션 | 뜻 | 기본 |
|---|---|---|
| `--version` | 마케팅 버전 (`MARKETING_VERSION`) | 필수 |
| `--build` | 빌드 번호 (`CURRENT_PROJECT_VERSION`). 건넬 때마다 올린다 | 필수 |
| `--profile` | 공증 키체인 프로필 | `taskforce-notary` |
| `--out` | 출력 폴더 | `dist` |
| `--skip-notarize` | 아카이브 · 내보내기 · 서명 · DMG까지만 하고 공증을 건너뛴다. **시험용, 만든 DMG는 건네지 않는다** | 끔 |

스크립트가 차례로 하는 일(어느 단계든 실패하면 멈추고 로그 위치를 알려 준다. 로그는 `dist/…/logs/`):

1. 사전 점검: Developer ID 인증서, `Secrets.xcconfig`(있다고만 출력, 내용은 출력하지 않음), 공증 프로필(`notarytool history`).
2. `xcodebuild archive` (Release, `generic/platform=macOS`, 버전 · 빌드 번호는 build setting으로 덮어씀) → `xcodebuild -exportArchive` (`apple/Config/ExportOptions-DeveloperID.plist`, `method` = `developer-id`).
3. 검증: `codesign --verify --deep --strict`, 권한 키 목록과 `aps-environment` 값(`production`이어야 함), 프로필이 앱에 들어 있는지(`Contents/embedded.provisionprofile`), 앱 `Info.plist`의 `APIBaseURL` 호스트가 `api.taskforcelabs.dev`인지 · `SupabaseURL` · `SupabaseKey` · `GIDClientID`가 비어 있지 않은지.
4. 앱을 zip으로 만들어 공증(`notarytool submit --wait`) → 스테이플.
5. `hdiutil`로 DMG(앱 + `/Applications` 바로가기, UDZO) → Developer ID로 서명 → 공증 → 스테이플.
6. `spctl`로 앱(`-a -vv`)과 DMG(`-a -t open --context context:primary-signature -vv`)가 Gatekeeper를 통과하는지 확인하고, DMG 경로 · 크기 · SHA-256을 출력한다.

공증이 실패하면(`Invalid`) 스크립트가 `notarytool log`를 그대로 출력한다.
공증은 보통 몇 분이다. 처음이거나 Apple이 바쁜 때는 더 걸릴 수 있다.

**서버 주소와 비밀 값.** Release 빌드는 **이 Mac의 `Secrets.xcconfig`**(Supabase URL · 공개 키)와 **커밋된 `Release.xcconfig`**(`API_BASE_URL`, Google 로그인 클라이언트)를 쓴다. `Secrets.xcconfig`에 로컬 서버 주소가 있어도 Release가 운영 주소로 덮어쓰고, 스크립트가 만든 앱의 `APIBaseURL`을 확인한다. 앱에 들어가는 Supabase 키는 공개 키(RLS가 막는다)이고 비밀 키는 들어가지 않는다.

## 3. 건네기: 숨은 주소로만

1. 만들어진 `dist/Taskforce-<버전>-<빌드>/Taskforce-<버전>-<빌드>.dmg` 한 파일과 스크립트가 출력한 SHA-256을 쓴다.
2. 웹사이트의 **추측할 수 없는 주소**(예: `https://www.taskforcelabs.dev/<무작위 20자 이상>/Taskforce-0.1.0-3.dmg`)에 올린다. 지킬 것:
   - 사이트의 어떤 페이지 · 내비게이션 · 사이트맵 · `robots.txt`에도 링크하거나 적지 않는다(robots.txt의 `Disallow`는 주소를 알려 주므로 쓰지 않는다. 대신 응답 헤더 `X-Robots-Tag: noindex, nofollow`).
   - 주소는 창업자에게 메신저로 직접 보낸다. 공개 채널 · 이슈 · PR에 적지 않는다.
   - 주소가 새면 파일을 지우고 새 주소로 다시 올린다.
3. 창업자에게는 주소와 SHA-256(받은 파일이 맞는지 `shasum -a 256 <파일>`로 비교), 처음 로그인 방법을 같이 알린다.

이 문서의 스크립트는 웹사이트를 건드리지 않는다. 올리는 일은 사용자가 한다(웹사이트 배포는 런북 7장).

## 4. 깨끗한 Mac에서 확인 (건네기 전, 사용자)

개발 Mac이 아닌 Mac(또는 새로 만든 macOS 사용자 계정)에서, **브라우저로 3장의 주소에서 내려받아**(내려받은 파일에 격리 표시가 붙어야 Gatekeeper 검사가 진짜로 돈다):

1. DMG를 연다 → `Taskforce`를 `Applications`로 끌어 놓는다 → 실행한다.
2. **"확인되지 않은 개발자" · "악성 소프트웨어가 있는지 확인할 수 없습니다" 경고 없이** 열려야 한다. "인터넷에서 다운로드한 앱입니다. 열겠습니까?"는 한 번 뜨는 것이 정상이다.
3. 메뉴 막대에 로고가 생기고 ⌥Space로 런처가 뜨는지, 로그인(Apple · Google)이 되는지, 알림 허용을 묻는지, 로그인한 뒤 할 일이 운영 서버에서 오는지 본다.
4. 터미널로도 본다:
   ```bash
   spctl -a -vv /Applications/Taskforce.app     # accepted, source=Notarized Developer ID
   xcrun stapler validate /Applications/Taskforce.app   # The validate action worked!
   ```
   네트워크를 끊고 열어도 경고가 없어야 한다(스테이플됨).

경고가 뜨거나 앱이 바로 꺼지면 건네지 말고 5장을 본다.

## 5. 업데이트 (자동 업데이트 없음)

1. 코드를 `main`에 합친 뒤 그 커밋에서 **빌드 번호를 올려**(필요하면 버전도) 스크립트를 다시 돌린다: `scripts/release-mac-dmg.sh --version 0.1.0 --build 4`.
2. 4장으로 한 번 확인하고, 3장의 숨은 위치에 새 파일(새 주소)을 올리고 **이전 파일은 지운다**.
3. 창업자에게 새 주소 · SHA-256을 보낸다. 창업자는 앱을 종료(메뉴 막대 → Quit)한 뒤 새 `Taskforce`를 `Applications`에 덮어쓴다. 같은 번들 ID · 팀이라 로그인 세션(Keychain)은 그대로 남는다.

앱이 스스로 새 버전을 알려 주지 않는다. 바뀐 것은 메신저로 직접 알린다.

## 6. 문제가 생기면

| 증상 | 확인 |
|---|---|
| 아카이브 · 내보내기가 프로필 오류로 멈춤 (`exportArchive No Accounts`, `No profiles for … were found`, `Provisioning profile … doesn't include …`) | `No Accounts`는 `xcodebuild`가 Xcode에 로그인된 Apple ID를 못 찾는 것이다: Xcode → Settings → Accounts에 Apple ID(팀 `U9DWQKQFMW`)가 있고 로그인 상태인지, 그 계정이 보이는 터미널 앱(Terminal.app)에서 돌리는지 확인한다. Apple Developer의 App ID capability(1장 3번)도 본다. 옛 Mac 프로필 · 빌드 산출물을 지우고 다시: [apple/README](../../apple/README.md) 4번. 스크립트는 권한을 빼거나 ad-hoc 서명으로 우회하지 않는다 |
| `aps-environment`가 `production`이 아니라고 멈춤 | Developer ID 내보내기가 production으로 바꾸지 않은 것이다. 권한 키 출력과 프로필의 `Entitlements`를 확인한다 |
| 공증이 `Invalid` | 스크립트가 출력한 `notarytool log`의 `issues`를 본다. 흔한 원인: Hardened Runtime 꺼짐(`project.yml`은 켜 둠), 서명 시각 표시 없음, 서명되지 않은 실행 파일 |
| 스크립트가 공증 프로필이 없다고 멈춤 | 1장 1번 |
| 받은 Mac에서 열 때 경고 | 4장 확인에서 스테이플 · `spctl` 결과를 본다. 격리 표시가 없는 파일(AirDrop · USB 복사)은 경고가 안 뜰 수 있어 검증이 안 된다. 꼭 브라우저로 받는다 |
| 로그인 직후 `-34018`, "Couldn't save your sign-in." | 프로필에 App Group · Keychain 그룹이 없다. [apple/README](../../apple/README.md) 4번 |

## 7. 하지 않는 것

- App Store · TestFlight 심사를 받지 않는다. 이 DMG는 한 사람에게 건네는 용도다. 여러 사람에게 퍼뜨리거나 공개 링크로 두지 않는다.
- 자동 업데이트(Sparkle 등)를 붙이지 않는다.
- DMG에 배경 그림 · 라이선스 화면을 넣지 않는다.
- `--skip-notarize`로 만든 파일을 건네지 않는다.
