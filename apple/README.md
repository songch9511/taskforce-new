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
   `API_BASE_URL`에는 Taskforce 서버 주소를 경로 없이 적습니다.
   - 시뮬레이터 + 로컬 서버(`npm run dev`): `API_BASE_URL = http:/$()/localhost:3000`
     (Info.plist의 `NSAllowsLocalNetworking`으로 로컬 주소만 http를 허용합니다)
   - 실제 기기 · 배포 서버: `API_BASE_URL = https:/$()/<서버 주소>`
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

- `Taskforce/` — 앱 화면: 로그인, 지금 할 일(주간 질문 · 확인 요청 · 할 일), 할 일 상세 · 고치기 · AI에게 넘기기, 원문 목록 · 원문 상세(빠진 할 일 신고)
- `Packages/TaskforceKit/` — 화면 없는 공유 코드
  - 설정 읽기, Sign in with Apple nonce, 세션 상태, App Group Keychain 저장소
  - `APIClient`: 서버 `/api/v1` (모든 쓰기). `Authorization: Bearer <Supabase access token>`
  - `TaskforceReads`: Supabase 직접 읽기 (RLS, 읽기 전용) — 할 일 상세 · 근거 · 변경 이력 · 원문
  - `ActionChanges`: `actions` Realtime 구독. "바뀜" 신호로만 쓰고 지금 할 일은 항상 `/now`를 다시 불러온다. 앱은 로그인해 있는 동안 구독 하나만 둔다 (`MainTabs`의 `ActionChangeFeed`)
  - `Models`: `src/lib/api/contract.ts`와 같은 모양의 모델
  - 순수 함수: 변경 이력 문장(`ActionHistory`), 이유 · 기한 표기(`Labels`), 원문 줄 나누기 · 인용 만들기(`SourceText`), `app_opened`를 보낼 때(`AppOpenTracker`)
- 순서 계산 · 판정은 서버에만 있다. 앱은 받은 순서를 그대로 보여준다.
- 로그인 세션은 App Group 공유 Keychain(데이터 보호 Keychain)에 저장되어, Phase A2의 공유 확장이 같은 세션을 읽습니다.
