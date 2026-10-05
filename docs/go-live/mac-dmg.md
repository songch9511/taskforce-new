# Mac beta DMG 준비와 설치 확인

기록: 2026-10-05 KST. 이 절차는 기존 Mac 직접 배포 helper를 재사용해 DMG를 준비하고 설치 근거를 모으기 위한 것이다. 스크립트는 웹사이트에 파일이나 링크를 게시하지 않는다. Google-only 0.1.0 (3) DMG가 Developer ID 서명·공증 검증을 통과했다. 실제 설치/런처 조작 및 OAuth·취소·연결 E2E와 공개 download link는 아직 완료되지 않았다.

## 재사용한 파일과 안전장치

`scripts/release-mac-dmg.sh`와 `apple/Config/ExportOptions-DeveloperID.plist`는 helper commit `f665bdfe42876d2917bef8d9a6f4cf44295bf464`에서 선별해 가져왔다. 전체 release branch는 합치지 않았다. helper checkout의 비공개 `Secrets.xcconfig`는 읽거나 복사하지 않았다. 원본 checkout의 native 설정은 값 비노출 유형 검사를 거쳐 Supabase URL·publishable key·Taskforce API host만 active ignored 설정 파일에 복사했다. 기본 출력 루트는 저장소 밖 임시 폴더 `${TMPDIR:-/tmp}/taskforce-release`이며 `--out <directory>`로 바꿀 수 있고, 그 아래 생성하는 버전/빌드 출력 폴더가 이미 있으면 중단해 이전 산출물과 로그를 보존한다. 재시도에는 새 build 번호를 사용한다. 내부 작업 폴더 정리는 해당 실행이 새로 만든 output 아래에서만 이뤄진다.

helper는 Release archive/export, Developer ID 서명과 entitlements/profile 확인, 앱·DMG 공증·staple, Gatekeeper 확인, SHA-256 출력을 수행한다. `--skip-notarize`는 설치 배포용이 아니다. helper는 공개 사이트 업로드를 포함하지 않는다.

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
