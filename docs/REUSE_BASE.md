# Taskforce Mac 재사용 베이스

기록: 2026-10-05 KST. 현재 작업본은 `/Users/daniel/.codex/worktrees/taskforce-mac-mvp-base/Taskforce-new`, 브랜치 `codex/taskforce-mac-beta-active-20261005`, 기준 커밋 `64bdb480b04cb538fd57b728dd0fdf7443004b7d`다.

## 기준과 복구

활성 작업 기준은 원본의 오래된 dirty HEAD `72cbe394b1fc86c5d6c5ec0ffea1bfd63d59fe16`가 아니라, 이미 로컬에 있던 `origin/main` `64bdb480b04cb538fd57b728dd0fdf7443004b7d`다. 두 ref 사이에는 148개 커밋 차이가 있다. 최신 쪽을 기준으로 삼아 최근 완료된 서버·인증·connector·실행 기능을 보존했다. 원본을 pull, reset, clean, stash하지 않았고 원본 파일도 수정하지 않았다.

원본 전체 보존본은 `/Users/daniel/Documents/Life Design/Taskforce-new-archive/Taskforce-new-72cbe394-20261005/`에 있다. 복원 절차는 [RESTORE.md](</Users/daniel/Documents/Life Design/Taskforce-new-archive/Taskforce-new-72cbe394-20261005/RESTORE.md>)를 따른다. 검증은 Git bundle의 complete history와 대표적인 세 파일 및 HEAD restore만 포함한다. 전체 원본 트리를 새 환경에 end-to-end 복원한 검증은 아니다.

이전에 만든 후보 `/Users/daniel/.codex/worktrees/2882/Taskforce-new`는 이 작업에서 수정하지 않았다. 그 후보와 원본은 위 148개 커밋 차이가 있는 오래된 기준에서 시작해 Mac-only 정리를 담고 있다. 최신 작업본에 그 브랜치 전체를 합치지 않고, 현재 필요한 설정과 release helper만 선별 반영했다.

## 활성 Mac 범위

Xcode 앱 target은 macOS 15 이상으로 제한했다. 활성 트리에서 뺀 것은 iPhone 전용 target 설정과 `Taskforce/iOS/` 화면·delegate, iOS 전용 entitlement와 icon asset이다. `DraftView.swift`는 제거된 iPhone 화면에서만 불렸다. 각 파일은 보호된 원본 아카이브에서 복구할 수 있다.

Mac에서 필요한 공유 흐름은 유지한다. 메뉴 막대 앱과 ⌥Space 런처, 계정·세션·로그아웃·계정 삭제 경로, 연결 해제·동의, App Group과 Keychain, Sign in with Apple, Google callback, APNs, 샌드박스·네트워크 entitlement 및 `TaskforceKit` 계약·회귀 테스트가 그 경계다. Mac 아이콘, Figma 기반 시각 기준, Google Sign-In 패키지 설정과 직접 배포 Release 설정도 남겼다. 별도 로그인이 필요한 배포 관문으로, Xcode Apple Development archive는 통과하지만 Developer ID export는 Sign in with Apple capability가 지원되지 않아 실패한다. 로그인 수단이나 배포 경로를 바꾸기 전까지 Apple 코드를 제거하지 않는다.

기본 가입·로그인은 Google identity-only 흐름을 우선하며, Gmail 읽기 권한은 별도 연결 단계다. 기존 Apple 계정도 계속 지원한다. Google 로그인 경로와 Gmail/Calendar scope를 섞거나 Apple 로그인 구현을 지우지 않는다.

기존 자동 수집은 Notion, Slack, Gmail, Google Calendar/Meet connector를 공통 계약과 registry, sync scheduler, ingestion pipeline에 연결한다. provider 구현과 수집을 유지했지만 현재 앱/API provider 목록은 코드에 고정돼 있다. 사용자가 임의 source나 MCP connector를 직접 추가하는 UI/runtime은 구현되어 있지 않으며, 별도 설계가 필요한 확장 갭이다.

할 일에 연결되는 기존 AI run·draft·credit 흐름도 그대로 둔다. 코드 기준의 실행 전제는 `EXECUTION_ENABLED`가 정확히 `true`, `execution_actors` 허용, DB 차단 스위치와 수동 credit이다. 신규 계정 잔액은 0일 수 있고 plan 예약 추정치 0 뒤 draft 예약 추정치 20에서 hold가 생길 수 있다. 이는 코드 및 로컬 테스트 정보일 뿐 현재 운영 DB의 migration·flag·actor·credit 상태는 확인하지 않았다. 운영 확인과 단계별 승인 절차는 [런북 9-1, 9-2, 9-3, 9-6](go-live/runbook.md#9-실행-u2-run--내장-초안)을 따른다. 결제 엔진 추가나 외부 발송·수정 자동화는 이 작업에 포함되지 않는다.

베타는 무료이며 실제 청구·자동 충전·월별 초기화는 없다. 사용자가 정한 AI 원가 한도는 사용자당 누적 `$10`이다. 계정별 누적 비용 ledger·summary API와 Mac UI 구현은 active isolated worktree에 있고 로컬 테스트를 통과했으나 아직 merge·운영 migration/deploy하지 않았다. 현재 선택된 OpenRouter 모델의 기본 허용 endpoint 모두 양수 cache-read 가격을 보여 준다. `provider.max_price`가 cache-read 비용을 제한한다는 공식 보장을 찾지 못해 fail-closed guard가 generative AI 호출을 차단한다. 모델·공급자 품질 결정을 대신하거나 guard를 완화하지 않았으며, 이 검증 전까지 정상적인 생성형 AI 작동을 약속하지 않는다.

OpenRouter 요청은 `data_collection=deny`와 `zdr=true`를 지정한다는 backend 구현 보고를 받았다. 이것은 Taskforce 자체 저장 동작과 별개다. Taskforce는 할 일·AI 초안·run/사용량 기록을 저장하므로 이를 “저장하지 않는다”로 일반화하지 않는다. 실제 Taskforce OpenRouter 계정 귀속과 운영 개인정보·학습·로그 설정은 확인되지 않았으며, 공개 정책 문구와 맞는지 beta 링크를 내기 전에 확인해야 한다.

## 직접 배포 준비

Mac DMG helper는 `f665bdfe42876d2917bef8d9a6f4cf44295bf464`에서 `scripts/release-mac-dmg.sh`와 `apple/Config/ExportOptions-DeveloperID.plist`만 선별했다. helper branch 전체는 merge하지 않았다. 새 문서인 [Mac DMG 및 설치 확인](go-live/mac-dmg.md)에 helper의 입력·출력, 현재 서명 준비 상태와 남은 증거를 기록했다. helper는 DMG 생성만 하며 웹사이트 게시를 하지 않는다.

Mac build 설정을 위해 원본 checkout의 native `Secrets.xcconfig`를 키 이름·형식만 로컬에서 분류했다. Supabase 프로젝트 URL, `sb_publishable_` 공개 키, Taskforce API host 외의 설정이나 비공개 key type이 없음을 확인한 뒤 active ignored 파일에 mode `600`으로 복사했다. secret value는 어떤 보고·문서에도 남기지 않았다. helper worktree의 별도 private 설정, 웹 서버 `.env`, API secret, service role key는 복사하지 않았다.

## 검증 근거와 한계

- 이 기준 커밋에서 Mac 공유 Swift package의 기준 검사는 57 suites / 506 tests 통과했다. 통합 후 `Taskforce` scheme의 unsigned macOS app test 75개와 Release build가 통과했다. Release build는 `TaskRow.swift`에서 `@ScaledMetric` 값을 alignment closure에서 읽을 때 actor isolation/non-Sendable capture 경고를 출력했다.
- Mac UI lane은 연결·사용량 문구 관련 focused Swift 검사를 5 suites / 62 tests 통과했다고 보고했다. 각 결과는 구분해 취급하며 signed archive나 실제 provider/install 검증으로 보지 않는다.
- macOS build settings에서 `SUPPORTED_PLATFORMS=macosx`와 `CODE_SIGN_ENTITLEMENTS=Taskforce/Taskforce-macOS.entitlements`를 확인했다. 이 확인은 실제 로그인·OAuth·연결 동작 증거가 아니다.
- provider 등록, 로컬 테스트, unsigned build, OpenRouter request metadata는 실제 provider 운영·서명 설치·공증·다운로드 설치 실행 증거가 아니다.
- 현재 Developer ID identity/profile와 별도 사이트 게시·깨끗한 Mac 설치 실행 상태는 Mac DMG 문서의 현황표를 본다.
