# Taskforce Apple 앱 (iOS · macOS)

SwiftUI 멀티플랫폼 앱과 공유 패키지 `TaskforceKit`. 플랫폼 전략은 [`docs/PLATFORMS.md`](../docs/PLATFORMS.md)를 보세요.

| 항목 | 값 |
|---|---|
| 번들 ID | `dev.taskforcelabs.taskforce` |
| App Group | `group.dev.taskforcelabs.taskforce` |
| 최소 OS | iOS 18 · macOS 15 |

## 처음 한 번

1. Supabase 설정을 채웁니다. 값은 웹의 `.env.local`과 같습니다.
   ```bash
   cp apple/Config/Secrets.example.xcconfig apple/Config/Secrets.xcconfig
   ```
   xcconfig에서는 `//`가 주석이라 URL을 `https:/$()/<ref>.supabase.co`처럼 적습니다.
2. `apple/Taskforce.xcodeproj`를 Xcode로 엽니다. 서명은 자동이고 Team은 `U9DWQKQFMW`로 잡혀 있습니다.
3. Supabase → Authentication → Sign In / Providers → Apple을 켜고 Client IDs에 `dev.taskforcelabs.taskforce`를 넣어야 로그인이 됩니다.

## 프로젝트 구조를 바꿀 때

`Taskforce.xcodeproj`는 [XcodeGen](https://github.com/yonaskolb/XcodeGen)으로 `project.yml`에서 생성합니다.
타깃 · 설정 · 파일 그룹을 바꿀 때는 Xcode에서 직접 고치지 말고 `project.yml`을 고친 뒤 다시 생성합니다.

```bash
brew install xcodegen
cd apple && xcodegen
```

## 테스트

```bash
cd apple/Packages/TaskforceKit && swift test
```

## 구조

- `Taskforce/` — 앱 화면 (로그인, 지금 할 일)
- `Packages/TaskforceKit/` — 화면 없는 공유 코드: 설정 읽기, Sign in with Apple nonce, 세션 상태, App Group Keychain 저장소
- 로그인 세션은 App Group 공유 Keychain(데이터 보호 Keychain)에 저장되어, Phase A2의 공유 확장이 같은 세션을 읽습니다.
