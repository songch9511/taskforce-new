# 에이전트 핸드오프 (2026-10-02, 방향 변경·U0)

## 현재 인계 (2026-10-05 KST)

이 문서의 아래 기록은 각 날짜의 당시 상태다. 현재 Mac beta 재사용 베이스와 통합 경계는 [Taskforce Mac 재사용 베이스](REUSE_BASE.md), 서명·DMG·설치 절차는 [Mac beta DMG 준비와 설치 확인](go-live/mac-dmg.md)을 기준으로 한다.

- Mac beta 변경의 source commit `41dba07725b13bd9a2f3d05ff5399a342833e07b`는 2026-10-05 14:41 UTC merge commit `fb1f5bf8c878134f80d4117094c48cb3e3adf9f2`로 main에 병합됐다. `check`·`apple` CI와 PR Preview가 통과했고, 같은 SHA의 Vercel Production deployment `6861963782`가 `success` / `Deployment has completed`다. 작업은 격리된 worktree에서 했으며 공유 원본 checkout과 별도 archive를 건드리지 않았다.
- Mac beta 결정은 macOS 전용 설치본과 Google 로그인이다. 앱의 native Apple 로그인 버튼·entitlement를 제거했지만 기존 Apple 계정, 서버의 Apple 지원, 연결 데이터는 삭제하거나 Google 계정과 합치지 않았다. Apple-only 계정은 이 Google-only 설치본에서 로그인할 수 없으며 기존 Apple 로그인 경로로 돌아가야 한다. 계정 통합은 별도 기능이다.
- **서명 산출물 생성·공증은 통과했다.** `/Users/daniel/.codex/releases/taskforce/0.1.0-3/Taskforce-0.1.0-3/Taskforce-0.1.0-3.dmg` (0.1.0 build 3, 6,530,158 bytes), SHA-256 `849dc331fa8e46c6c56c2ccc3a7240b16a86eb9d0f785bebf98ab3aefa4d8cd8`. 2026-10-05 재확인에서 DMG checksum, 앱·DMG 서명, 두 stapler 검증, 두 Gatekeeper 판정이 통과했고 둘 다 `Notarized Developer ID`로 승인됐다. 이 Mac에서 설치·실행 및 실제 로그인·연결 E2E는 아직 미검증이다.
- 사용자당 누적 AI 원가 `$10` 한도, 계정별 예약·정산·요약 API와 Mac 사용량 화면이 구현·배포됐다. GLM endpoint의 제한된 cache-read 요금은 보수적으로 예약하고 `max_price` 초과 endpoint는 제외해 정상 호출을 허용한다. 알려지지 않은 요금 차원과 cache-write 비용은 계속 차단한다. 운영 프로젝트 `tirtdojsahotjfgdsryi`에서 승인된 `20261027000000_ai_spend_budget.sql`, `20261028000000_ai_spend_summary.sql`만 차례로 적용했다. 적용 직전 집계는 처리 중·대기 원문, 진행 중 실행, 호출 중 단계, 미확정 청구가 모두 0이었다. 첫 파일 뒤 ledger/RLS/예약·정산 함수와 권한, 둘째 파일 뒤 요약 함수 권한·오류 제약·`task_source_states`를 확인했다. `service_role`만 예약·정산·요약 RPC를 실행할 수 있고, authenticated 사용자는 자기 ledger만 select 가능하다. `db push`, 과거 원가 소급, 유료 AI 요청은 하지 않았고 공유 provider key 한도나 결제 설정도 바꾸지 않았다.
- Production `GET /api/v1/ai-budget` 무인증 요청은 HTTP 401이다. 이는 endpoint가 인증을 요구하는 응답만 확인한 것이다. 인증된 요약 호출, budget을 통과하는 실제 AI 요청·supplier cost 정산은 아직 검증하지 않았다. 실제 OAuth·연결·기기 E2E는 W1–W5 후속 작업 뒤에 한다.
- 독립 검증 결과: backend lint·typecheck, 전체 175 files / 2,253 tests, disposable PostgreSQL 3 files / 23 tests, `npm run eval -- --labels` 및 Next build 통과. Swift `TaskforceKit` 전체 59 suites / 514 tests, macOS 앱 9 suites / 86 tests 및 focused auth 회귀 96 tests가 통과했다. 이들은 local evidence이며 실제 provider 인증을 입증하지 않는다.
- 웹사이트 PR [#29](https://github.com/songch9511/taskforce/pull/29)은 Draft다. metadata guard, Google-only 안내, 웹 보안 업데이트와 설치 안내가 준비됐고 website CI·Vercel Preview는 성공했지만, DMG 공개 링크는 비활성이다. 실제 사이트 다운로드 → 설치 → 실행과 Google OAuth·취소·재시도·연결 → 원문 수집 → 할 일 표시를 확인한 뒤에만 공개한다. 실제 OpenRouter 계정 privacy 설정과 runtime 환경변수의 모델 override는 확인하지 않았다.
- 2026-10-05 운영 준비 집계(식별자·원문 없이): `POST /api/v1/runs` 무인증 응답은 401이다. 배포된 route의 검사 순서가 `EXECUTION_ENABLED` → 인증이므로 기능 플래그가 켜진 뒤 인증 단계에 도달한 것으로 해석한다. `execution_controls`는 global · manual · Taskforce provider 허용, auto · full 차단이다. actor 1개가 동의 · 최소 20 credits 이상의 잔액 · 열린 본인 Action을 모두 만족한다. credit 계정은 1개, 가용 합계는 2,000 credits다. 새 AI spend ledger는 attempts 0, confirmed/reserved USD 0이다. 이 집계는 실행 조건 준비 상태만 확인하며 실제 run·AI 요청 성공을 뜻하지 않는다.
- 새 베타 계정의 실행 허용은 기존 운영자 절차를 쓴다: 로그인으로 계정이 생긴 뒤 정확한 계정 이메일을 확인해 `execution_actors`에 한 계정만 추가하고, `grant_credits`에 매 지급별 새 UUID를 써서 필요한 실행 크레딧을 한 번 지급한다([런북 9-2·9-3](go-live/runbook.md)). 구매·자동 지급 경로는 없다. AI 공급자 원가 한도 `$10`은 사용자별 자동 예산이며 실행 크레딧과 별개다. 이번 점검에서 actor·credit 쓰기는 하지 않았다.
- W3는 **부분 완료**다. 일반 로그아웃은 `.local`로 병합 PR [#81](https://github.com/songch9511/taskforce-new/pull/81)이 구현했고, 앱의 저장본 정리는 [#83](https://github.com/songch9511/taskforce-new/pull/83)에 포함됐다. PR #61의 잘못된 “모든 기기” 안내는 #81에서 교체됐다. Mac·iPhone 실제 기기 로그아웃, 데이터·진행 중 요청 정리, 다른 기기 세션 유지·갱신 및 Google 취소·재시도 E2E는 아직 실행하지 않았다. W3 완료는 이 `.local` 경로의 기기 검증과 실제 인증·취소 E2E가 끝난 뒤다. 이미 존재하는 계정 병합은 W3 완료 조건이 아니다.
- W1 독립 이슈는 W3를 기다릴 필요가 없다. 기존 알림 대상과 Review 목록의 불일치를 고친 PR [#65](https://github.com/songch9511/taskforce-new/pull/65)은 2026-10-02 병합됐다. 안전한 소스별 일괄 확인은 정확도를 유지해야 하고 선택·부분 실패 UX를 정하는 별도 제품 변경이다. W1은 진행 가능 상태로 유지하며, 근거 없는 자동 배정이나 임계값 완화는 하지 않는다.

다른 에이전트(Codex 등)가 이 저장소를 이어받을 때 먼저 읽는 문서다. 규칙은 [CLAUDE.md](../CLAUDE.md), 기능 위치는 [FEATURE_MAP.md](FEATURE_MAP.md), 남은 출시 일은 [GO_LIVE.md](GO_LIVE.md)와 [런북 체크리스트](go-live/runbook.md)가 기준이다. 이 문서는 PR #54 완료 상태, W3 치명적 경로·W2 재검증·W3 로그인 사용성·W1 확인 부담 수정과 **2026-09-30 09:00 UTC QA의 당시 기록 및 후속 작업 승인 범위**를 함께 담는다.

## 1. 지금 상태

### 2026-10-02 방향과 U0 (KST)

- **방향:** 제품 문제 정의(다맥락 창업자의 맥락 휘발 · 관리 비용)는 유지한다. Taskforce는 AI 에이전트(OpenAI dots 등)가 늘린 일의 관리 부담을 대신 지는 도구로, 에이전트와 함께 쓴다. 2026-10-01 Figma 재설계(`Redesign · Native · 2026-10-01`) 전체를 실제 제품으로 만든 뒤 첫 사용자 한 명에게 건넨다. 공개 출시 · 팀 기능은 그 뒤다. 시각(D1)은 지금 Figma 그대로 승인됐다.
- **구현 계획:** 단위 U0 → U2 서버 → U1 셸 → U2 Mac → U5 → U8a → U3a → U4 → U6a → U6b → U8b → U9 → U10. 코드는 단위마다 착수 승인, PR마다 병합 승인(병합 = 운영 배포). 계획 원문은 저장소 밖(로컬)에 있다.
- **외부 효과 계약:** [EXECUTION.md](EXECUTION.md)(#67 병합 뒤). 외부 쓰기는 이 문서를 따른다.
- **U0에서 한 일:**

| 항목 | 결과 |
|---|---|
| 병합 | #63 `4ba5d8b`(잘못된 JWT 401) · #65 `04e602f`(W1 알림 정렬) · #64 `ba2cb71`(문서). Production success, main CI success, 무인증 · 잘못된 JWT 401 |
| 보류 | #61 · #62는 U1(`.local` 로그아웃 · SessionStore 정리)까지 |
| 처리방침 | 베타 1.3 게시(2026-10-02) → 지금은 베타 1.4(2026-10-04), 약관은 2026-10-04 시행 판 ([legal/README.md](legal/README.md) 게시 기록) |
| eval 기준선 (`29576c6`) | 자동+확인 정밀도 90.4% · 재현율 91.7% · 담당 98.5% · 기한 100% · 남의 일 3 / 자동만 98.3% · 85.1% · 100% · 100% · 0 / 시퀀스 29/29 / 물어보기 8/8. 이후 PR은 이보다 떨어지지 않아야 한다 |
| 관문 | 계획 생성(`completeJson` + discriminated union, ZDR 공급자) 통과 · 원격 MCP(Linear 바로 · GitHub 앱 등록 · Figma는 REST 읽기만) · Vercel Pro(함수 최대 800초, cron 최소 1분) · Gmail 헤더(`X-Taskforce-Intent` 보존, 클라이언트 Message-ID는 Gmail이 바꿈). 자세한 내용은 EXECUTION.md 10장 |
| 연결 플래그(운영) | `GMAIL_CONNECT_ENABLED=true`, Slack · Google 비어 있음. Gmail은 프로젝트 B Testing이라 테스트 사용자만 연결된다 |

### 2026-10-02 U2 서버 진행 (KST)

- **병합(= 운영 배포):** #69 원칙 1 · 2와 PRD 지표 4 문서, #70 W4 처리 실패 가시화 · 지표 4 분리 · 발견 원가(마이그레이션 `20261020000000`), #71 실행 코어 스키마(`20261021000000`), #72 AI 원가 포착 · 실행 계획 · 내장 초안 프롬프트 · eval E1 · E2, #73 산출물 · 크레딧 원장 · AI 원가 기록(`20261022000000`), #74 TS 실행기 · `/api/v1/runs` · 멈추기 · 크레딧 route · 1분 sweep · `EXECUTION_ENABLED` 플래그, #76 receipt를 Claim/Evidence로(`20261023000000`).
- **병합 전:** #75 운영(런북 9장 · `/admin/metrics` 실행 카드 · 실행 산출물 본문 보관 정리).
- **닫힌 채로 나간다:** 플래그 기본 꺼짐, 차단 스위치 시드는 `global` 막힘 · auto · full 막힘, 실행 주체 시드 없음. 켜는 순서(줄마다 승인) · 되돌리기 · 점검 쿼리 · U2 완료 확인은 [런북 9장](go-live/runbook.md). 운영 DB의 마이그레이션 적용 상태는 이 문서에서 확인하지 않았다: 런북 9-6 2번의 읽기 쿼리로 본다.
- **켜기 전 남은 결정:** 처리방침 개정(D9a-1: 내장 초안 · 산출물 · 크레딧 원장 · AI 원가, 산출물 보관 기간. 지금은 열 기본값 90일).

### 2026-10-01 머지·운영 스키마 적용 (KST)

사용자가 기존 작업 머지를 승인했고, #60의 운영 DB 변경 두 건은 별도 질문에 명시적으로 승인했다. PR 최신 HEAD가 기존 검토 커밋과 같고 필수 `check`·`apple`이 SUCCESS임을 확인한 뒤 저장소 방식(`--merge`, HEAD 고정)으로 머지했다.

| PR | 범위 | merge commit |
|---|---|---|
| [#57](https://github.com/songch9511/taskforce-new/pull/57) | SDK 토큰 갱신 경쟁 수정 | `3d5ee13` |
| [#56](https://github.com/songch9511/taskforce-new/pull/56) | 저장된 세션과 화면 계정 일치 | `19bb798` |
| [#58](https://github.com/songch9511/taskforce-new/pull/58) | 계정 전환 시 이전 원문 요청 취소 | `2fb0a0c` |
| [#59](https://github.com/songch9511/taskforce-new/pull/59) | eval 담당 오판 집계 | `db3ecb3` |
| [#55](https://github.com/songch9511/taskforce-new/pull/55) | 이전 검증 HANDOFF | `8ec2dce` |
| [#60](https://github.com/songch9511/taskforce-new/pull/60) | W2 담당·상태 변경 보호 | `da121ba` |

- 운영 프로젝트 `tirtdojsahotjfgdsryi`의 스키마만 읽어 `write_action` 본문이 예상한 기존 정의와 완전히 같음을 먼저 확인했다. `20261018000000_claims_unknown_speaker_role.sql`, `20261019000000_claim_state_write.sql`을 순서대로 파일 하나씩 적용했고, 각각 읽기로 확인했다. 최종 화자 제약에 `unknown`이 있고 RPC 본문은 두 번째 파일과 같으며, execute 권한은 service_role만 유지된다(anon·authenticated는 false). 기존 데이터 재처리·수정·삭제나 `db push`는 하지 않았다.
- 최종 merge SHA `da121baf494649c391c5e917a813c1cb2344ef11`의 Vercel Production 배포 `6763975671`은 2026-10-01 00:58:22 KST `success` / `Deployment has completed`였다. [배포 URL](https://taskforce-okgijkb2v-songch9511s-projects.vercel.app). [main 통합 CI](https://github.com/songch9511/taskforce-new/actions/runs/36740703587)의 `check`·`apple`도 이 SHA에서 모두 SUCCESS였다. 같은 소스 트리의 로컬 lint·typecheck·130 파일/1,702 테스트·eval 라벨 검사·build도 통과했다.
- Apple 수정은 main 소스에 반영된 상태이며 Vercel 배포가 서명 앱 배포를 뜻하지 않는다. 사용자가 실제 OAuth·연결·기기 E2E는 필수적인 막힘이 없는 한 W1–W5가 끝난 뒤로 미뤘다. 이 단계에서 실제 제공자 인증·연결·기기 E2E는 실행하지 않았다.
- 위 머지 승인 범위는 #55–#60이다. 이후 만드는 W3 나머지·W1·W4·W5 PR의 머지와 새로운 운영 DB 변경은 다시 별도 승인 대상이다.

### 이전 PR #54 및 QA 기준선

- [PR #54](https://github.com/songch9511/taskforce-new/pull/54)는 Draft 해제 후 2026-09-30 11:56:31 UTC `b944b40` merge commit으로 `MERGED` 됐다. PR 최종 HEAD는 `35a24ec`이며 merge tree와 완전히 같다.
- PR #54 최종 HEAD `35a24ec`에서 `npm run lint`, `npm run typecheck`, 전체 테스트 128 파일 · 1,645 테스트, 실제 모델 eval, `npm run build`가 통과했다. merge commit의 코드 tree가 같아 이 결과를 재사용한다. GitHub Actions [`check`와 `apple`](https://github.com/songch9511/taskforce-new/actions/runs/36708650219)도 모두 `SUCCESS`다. CI의 eval 단계는 키 없이 실행하는 라벨 검사이며 실제 모델 eval과 구분한다.
- 실제 모델 eval은 2026-09-30 11:26 UTC 개발 키로 실행했다. 자동 반영과 확인 요청 합계: precision 91.5%, recall 92.9%, 담당 정확도 96.9%, 기한 정확도 98.5%. 자동 반영만: precision 98.2%, recall 81.8%, 담당·기한 정확도 100%. 시퀀스 28/28 정답, 추가 0, pending 2; 질문 8/8; 오류 0; 비용 $0.164.
- 운영 배포 `6758727983`은 SHA `b944b40`로 11:57:24 UTC에 GitHub의 Vercel Production deployment 상태 `success` / `Deployment has completed`임을 확인했다. [배포 URL](https://taskforce-chah5ca8a-songch9511s-projects.vercel.app). `GET https://api.taskforcelabs.dev/api/v1/now`의 무인증 요청은 HTTP 401이었다. 이것은 인증이 없는 요청의 기본 응답만 확인한 것이며 유효 토큰 로그인이나 E2E 증거가 아니다.
- PR #54 단계에서 실제 제공자 OAuth, 로그인·연결, 서명 기기 E2E는 실행하지 않았고 운영 DB 변경도 없었다.
- **당시 기준선 (2026-09-30 09:00 UTC, 읽기 전용 집계; 현재 상태로 간주하지 않음):**
  - 연결 4개(Notion 3 · Gmail 1) 모두 `active`, 마지막 동기화 08:45 UTC, 오류 · 걸린 잠금 없음. Slack · Google(Calendar · Meet) 연결은 없다 (Google은 심사 전이라 닫혀 있다).
  - 원문 294건: 처리 완료 292, 실패 2, 멈춘 것 0. 실패 2건은 모두 `빈 응답 (finish_reason: length)` (9/27 · 9/29, 재시도 수정 전).
  - 판정 후보 75건: 자동 반영 26 · 확인 요청 32 · 기각 17. 확인 요청 32건 중 31건이 "내 일인지 불확실(`NOT_MY_ACTION`)"이다. 화자(`quote_speaker`)가 있는 후보는 3건뿐이다.
  - 할 일 90개(전부 owner `me`): 열림 62(그중 확인 대기 16), 끝남 8, `dropped` 20.
  - 프로필 4개 중 3개만 AI 동의를 마쳤다. 동의 없는 프로필 1개는 동기화 대상에서 빠진다 (`syncable_connections`).
  - 원문이 있는 계정은 모두 열린 할 일이 있다. "할 일이 아예 안 생기는 계정"은 이 집계에서 보이지 않았다.

### W3 치명적 경로 재검증 (main 머지 완료, 서명 앱 배포 별도)

실제 운영 피해를 확인한 기록이 아니다. 아래 우선순위는 현재 코드·SDK 및 로컬 재현의 영향과 발생 조건에 따른다. 코드 작성은 GPT-6 Luna Max가 맡았고, 세 문제는 모두 `b944b40` 기반 별도 브랜치로 분리했다. 서로 변경 파일이 겹치지 않으며 다른 후속 PR을 기반으로 쌓지 않는다. 아래 당시 검증 기록은 문서 전용 [PR #55](https://github.com/songch9511/taskforce-new/pull/55)로 머지했다.

| 우선순위 | 문제·영향·발생 조건 | 근거와 조치 |
|---|---|---|
| P1 · 1 | 이전 계정의 진행 중 토큰 갱신이 계정 전환 뒤 성공하면 새 세션을 이전 계정으로 덮고, 특정 실패 응답이면 새 세션을 지운다. API 토큰이 바뀌므로 읽기·쓰기 계정이 잘못될 수 있다. 갱신과 로그아웃/다음 로그인이 겹쳐야 한다. 운영 발생률은 미확인 | 고정된 Supabase Swift 2.55.2의 코드와 공식 [2.55.3 수정](https://github.com/supabase/supabase-swift/releases/tag/v2.55.3)을 확인했다. [PR #57](https://github.com/songch9511/taskforce-new/pull/57), `20d87bf`. SDK 최소 버전과 두 lockfile을 2.55.3으로 올렸다. 공개 AuthClient와 AppServices 회귀에서 2.55.2는 이전 계정 토큰 전송·새 세션 삭제·로그아웃 후 복원이 재현됐고, 2.55.3은 세 경우를 막으면서 정상 갱신도 통과했다. 자체 갱신 관리자는 만들지 않았다 |
| P1 · 2 | Mac에서 원문 읽기 중 계정을 바꾸면 이전 계정의 늦은 응답이 원문 화면을 다시 채울 수 있다. 공유 기기에서 이전 계정 원문이 노출된다. 원문 요청과 계정 전환이 겹칠 때 발생하며 운영 빈도는 미확인 | `LauncherModel.sessionChanged`는 화면만 비우고 `work`를 취소하지 않았다. [PR #58](https://github.com/songch9511/taskforce-new/pull/58), `a4f70e9`. 실제 LauncherModel과 TaskforceReads를 호출하는 회귀에서 이전 원문 재표시를 재현했다. 기존 Task 취소와 취소 뒤 오류 무시를 3줄로 적용했고 정상 읽기는 유지됐다. 새 앱 테스트 타깃과 CI 실행도 추가했다 |
| P1 · 3 | Keychain에 A가 남은 채 B 저장이 실패하면 화면은 B, API 토큰은 A가 될 수 있다. 저장 실패와 이전 세션 잔존이 함께 필요하다. OS 실패의 실제 빈도는 미확인 | [PR #56](https://github.com/songch9511/taskforce-new/pull/56), `b2bb927`. 기존 코드의 잘못된 표시를 로컬 저장소 fixture로 재현했다. 새 로그인은 저장된 사용자 ID와 대조하고, 늦은 세션 이벤트는 현재 저장된 계정 또는 로그아웃 상태를 따른다. 같은 사용자 토큰 교체와 만료 세션의 오프라인 표시는 유지한다 |

- **서버 W3e:** 설치된 `@supabase/auth-js` 2.117.1의 `getClaims`는 서명·만료를 검증하고 HS/JWKS 미확보 경로에서는 Auth `getUser`로 검증한다. 오프라인 SDK 재현에서 만료·오서명·다른 프로젝트 키 토큰은 거절됐다. 신뢰된 테스트 개인키로 직접 서명한 `sub` 누락/다른 role 토큰을 받아들인 것은 claim 형식 검사가 없다는 근거이며, 공개 키만 가진 사용자의 우회 재현은 아니다. 표준 Supabase Auth 발급 경로에서 도달 가능한 인증 우회·타인 계정 접근은 확인하지 못했다. [Custom Access Token Hook](https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook)은 `sub`·`role`을 필수로 요구한다. 저장소에는 가입 전 훅만 있으며 **운영 Dashboard의 signing key/custom token hook 설정은 확인하지 않았다**.
- `connections/sync`의 사용자 ID가 없으면 전체 연결 조회가 가능한 내부 경로는 앞선 사용자 범위 동의 조회가 막는다. 로컬 PGlite에서 일반 `authenticated` role + `auth.uid() = null`은 프로필 0건이었다. 관련 RLS 4 파일 · 35 테스트가 통과했다. 서비스 역할 쓰기의 사용자 필터/소유권 RPC도 호출 흐름으로 점검했다. 이를 운영 설정 전체의 안전성 검증으로 표현하지 않는다.
- SDK가 이미 수행하는 만료·폐기 refresh 세션 정리는 다시 구현하지 않는다. 잘못된 JSON JWT가 401 대신 500을 만드는 오류 처리는 이후 W3 나머지 단계의 Draft PR #63에서 수정했다. API 401 반복 안내·이메일 오류 문구의 수정과 Google 취소 재검증은 아래 W3 나머지 절을 본다. 일반 로그아웃은 이후 `.local` 정책으로 확정했으나 구현·검증은 남아 있고, Apple 이메일 숨기기/Google 계정의 데이터 통합은 범위 밖으로 보류한다.
- 세 코드 브랜치에서 lint, typecheck, 전체 Node 테스트 128 파일 · 1,645개, `npm run eval -- --labels`, build가 통과했다. 추출·판정·병합·프롬프트를 바꾸지 않아 실제 모델 eval은 다시 실행하지 않았다. #56은 SwiftPM 285 테스트 · 28 suite, #57은 284 테스트 · 29 suite, #58은 실제 Mac 모델 3개 테스트와 iOS Simulator 빌드가 통과했다.
- 세 수정을 별도 검증 checkout에 함께 적용해 **SwiftPM 289 테스트 · 29 suite, Mac 모델 3개 테스트, iOS Simulator 빌드**도 통과했다. Xcode 26.6 / `CODE_SIGNING_ALLOWED=NO` 검증이다. 테스트 데이터는 가짜 계정·토큰·원문이며 실제 제공자/서명 기기 증거가 아니다. 최종 필수 검사 실패는 없으며, 수정 전 회귀 실패는 버그 재현 근거로 구분한다.
- 코드 PR의 최신 HEAD CI: [#56 `b2bb927`](https://github.com/songch9511/taskforce-new/actions/runs/36720414012), [#57 `20d87bf`](https://github.com/songch9511/taskforce-new/actions/runs/36721843202), [#58 `a4f70e9`](https://github.com/songch9511/taskforce-new/actions/runs/36722835621) 모두 `check`·`apple`이 `SUCCESS`임을 2026-09-30 13:44 UTC에 확인했다. 당시에는 Draft였으며, 이후 사용자 승인으로 위 머지 절의 커밋에 반영했다.
- 원본 공유 checkout의 `main`/HEAD `72cbe39`와 스테이징 index는 시작 시점 그대로다. 보존 검사에서 초기 스냅샷 27개 파일 중 26개가 동일했고, 동시에 변경된 `docs/LAUNCH_VIDEO.md`는 이번 작업에서 건드리지 않았다. 코드 PR마다 지정 파일만 커밋했고 공유 폴더에서 reset/clean/stash/브랜치 전환을 하지 않았다.
- 실제 제공자 OAuth, 서명 앱/기기 Keychain, 로그인·연결 E2E는 실행하지 않았다. 당시 후속 PR은 Draft로 남겼다. 이후 #55–#60 머지와 두 스키마 변경만 승인·실행했으며, 계정 통합·파괴적 정리는 하지 않았다.

### W2 담당·상태 변경 재검증 (main·운영 서버 반영 완료)

기존 W2 표의 `확인`·`보고`는 아래와 같이 현재 코드·호출 흐름·회귀 테스트로 다시 검증했다. 운영 피해 건수나 빈도를 확인한 것은 아니다. GPT-6 Luna Max가 코드를 작성했으며 두 W2 브랜치는 `origin/main`의 `b944b40`에서 시작했다. W3 Draft PR #56–#58에 의존하지 않는다. 런타임 수정은 신원 판별 → Claim 판정 → 병합 → DB 저장이 함께 유지되어야 해 [PR #60](https://github.com/songch9511/taskforce-new/pull/60), `dcf5da0`에 모았고, 독립적인 eval 지표는 [PR #59](https://github.com/songch9511/taskforce-new/pull/59), `fe717b9`로 분리했다. 두 PR은 변경 파일이 겹치지 않는다.

| 우선순위 | 재현 조건·영향 | 확인된 원인과 조치 |
|---|---|---|
| P1 · 1 | 같은 시각의 제3자 완료·취소 발언이 채널 순위로 기존 상태를 바꾸거나, 낮은 매칭 확신도의 후보가 다른 할 일을 닫는다. 잘못 닫히면 확인 큐에서도 빠진다 | 권한보다 채널을 먼저 비교하던 순서를 고쳤다. 사용자·할 일 도구의 같은 시각 명시적 선택을 보존하고, 권한 없는 초기 완료도 자동 확정하지 않는다. 확인 전 병합 Claim은 기존 `state=disputed`로 보관해 기존 확정 상태를 유지한다. 두 입력 순서와 완료·취소를 각각 재현했다 |
| P1 · 2 | 이메일이 다른 동명이인 또는 김도윤·박도윤의 `도윤` 표기가 내 담당·화자로 확정된다 | 명시적 이메일을 이름보다 우선한다. 실제 관련자 충돌이 있으면 화자는 `unknown`, 담당은 확인 대상으로 남긴다. 고유한 짧은 이름, 이메일 없는 이름·별칭, Notion의 정확한 사용자 ID·이메일은 유지한다. 화자 없는 Notion 요약의 `담당: 도윤`, 체크박스 및 인용에서 담당 접두어가 빠진 경우를 검증했다 |
| P1 · 3 | 새 약속이 Judge 확인 요청이거나 담당 `unknown`인데 기존 할 일과 매칭되면 확인 없이 기한이 바뀐다 | 판정 이유를 병합 후에도 별도로 보존하고 Claim을 disputed로 저장한다. 예: 기존 10/9 기한에 확인 전 후보가 붙어 10/12로 바뀌던 회귀가 이제 기존 기한·확인 대기를 유지한다. 불확실한 화자를 모델의 `me` 추정으로 복원하지 않는다. 추출 담당이 `unknown`인 완료·취소 신호도 명시적 동명이인 수신자를 검사한다. 반면 확인된 요청자의 정상적인 변경·완료·취소는 새 약속 검증의 기각만으로 막지 않는다 |
| P2 · 4 | 기존 담당 정확도는 정답에 매칭된 후보만 채점하므로 남의 일을 `me`로 잘못 추출한 수치가 따로 보이지 않는다 | #59는 `NOT_MY_ACTION` 오탐 중 `owner=me`인 후보의 절대 건수 `falseAttributions`를 자동+확인·자동 전용 단계별로 추가한다. 기존 정밀도·재현율·담당 정확도 정의는 유지한다. 최종 기한·완료·취소 오판을 잡는 시퀀스 채점 회귀도 추가했다 |

- 원래 발언의 확정도·직접성·근거는 보존한다. 새 표·의존성·판정 프레임워크를 만들지 않았고 기존 resolver, Claim 상태, `write_action` RPC, 이벤트를 재사용했다. 확인 이유가 늘거나 풀리는 경우 모두 기존 이벤트의 before·after에 남긴다. PGlite는 disputed 저장·조회, 기본 active, 잘못된 상태의 트랜잭션 rollback과 기존 권한·사용자 범위·버전 검사를 통과했다.
- **바꾸지 않은 W2a:** `owner_confidence`는 보정되지 않은 추출기 자기 확신도이며 독립 Jev 판정을 쓰는 현재 설계와 다르다. 임의의 추가 임계값이나 기존 임계값 완화는 하지 않았다.
- **제품 결정으로 남긴 W2d:** `written_by_me`는 작성자가 연결 사용자와 일치하는 비회의 Notion 문서의 자기 계획을 내 일로 해석하는 문서화된 정책이다. 페이지 작성자가 모든 항목의 실제 담당자라는 증거는 아니다. 현재 정책 유지 / 명시적 담당 근거만 자동 반영 / 협업 문서만 더 엄격하게 처리하는 선택은 정확도·누락·확인 부담이 달라 별도 결정이 필요하다. 회의 제목 판별이나 정책을 이번에 넓히지 않았다.
- **검증 한계:** 이름 충돌 방지는 실제 관련자 정보와 명시적인 화자·언급·담당 표기가 근거다. 모든 자유문장 속 사람을 결정적으로 판별하는 기능은 아니다. 시퀀스 eval은 최종 상태를 채점하고 중간 이력 전체를 별도 지표로 평가하지 않는다. 실제 운영 피해율, 제공자 OAuth·연결·기기 E2E는 이번 검증에 포함하지 않았다.
- **최종 로컬 검사:** #60에서 lint, typecheck, 전체 테스트 **130 파일 · 1,700개**, 라벨 검사 **84 사례 · 기대 Action 101 · 함정 221**, 실제 모델 eval, build가 모두 종료 코드 0이었다. #59는 128 파일 · 1,647 테스트와 lint·typecheck·라벨 검사·build를 통과했다. 문서 전용 #55의 변경하지 않은 소스 트리도 lint·typecheck·1,645 테스트·라벨 검사·build를 통과했다.
- 중간 실행에서는 기존 Notion Calendar 시간 예산 테스트가 호스트 타이밍으로 한 번 실패했다(25ms 두 번/40ms 예산에서 호출 1회, 기대 2회). 동일 코드의 전체 재실행은 1,700/1,700 통과했으며 이 테스트를 완화하지 않았다. 수정 중 타입·이전 오판을 기대하던 Notion 테스트의 실패는 수정했고, 추가 안전성 수정 때문에 중단한 부분 eval은 최종 수치에서 제외했다.
- **실제 모델 eval 비교:** 기준선 `b944b40`은 2026-09-30 14:22 UTC, 수정 후는 15:32 UTC에 끝났다. 둘 다 개발 키, `z-ai/glm-5.3-flash` / `typesafe/jev-1.13`, extract-v5 / judge-v5 / ask-v2이며 API 실행 오류는 0이다. 공통 82 사례(단일 55 + 시퀀스 27)를 따로 비교했다. 확률적 실행 1회씩의 관측값이므로 변화량을 수정의 인과 효과로 단정하지 않는다.

| 공통 사례 지표 | 기준선 | 수정 후 |
|---|---:|---:|
| 자동+확인 정밀도 / 재현율 | 90.4% / 94.3% | 93.0% / 94.3% |
| 자동+확인 담당 / 기한 정확도 | 98.5% / 100% | 98.5% / 100% |
| 자동 전용 정밀도 / 재현율 | 98.2% / 84.8% | 98.2% / 83.3% |
| 자동 전용 담당 / 기한 정확도 | 100% / 100% | 100% / 100% |
| 남의 일→me 오탐 (자동+확인 / 자동 전용, #59 scorer) | 3 / 0 | 3 / 0 |
| 시퀀스 최종 정답 / 추가 자동 생성 / 확인 대기 | 28/28 / 0 / 3 | 28/28 / 0 / 4 |
| 질문 | 7/8 | 8/8 |

- 추가 2 사례를 포함한 전체 84 사례: 자동+확인 정밀도·재현율 93.1%·93.1%, 담당 98.5%·기한 100%; 자동 전용 정밀도·재현율 98.2%·83.6%, 담당·기한 100%. 시퀀스 최종 정답 **29/29**, 추가 자동 생성 0, 확인 대기 5. 새 동명이인 취소 시퀀스는 할 일을 `open`으로 유지하며 확인 이유를 남겼다.
- **남은 품질 문제:** 새 Notion 동명이인 단일 사례에서 추출기가 확인용 후보 1개를 누락했다(명시적 전체 이름 1개는 정상 처리). 누락을 통과로 세지 않는다. 추출되었을 때 보류하는 경로는 결정적 회귀 테스트로 검증했다. 공통 사례의 남의 일 오탐 3개는 확인 대상으로 남고, 자동 전용 오탐 1개는 중복이다. 기존 `notion-summary-with-attendees`의 담당 필드 오류 1개도 남는다. 기존 질문 1개는 기준선에서 답 문구 채점에 실패했으며 수정 후 실행은 8/8이다. 이를 해결하려고 임계값이나 프롬프트를 임의로 바꾸지 않았다.
- **CI 연결:** [#59 `fe717b9`](https://github.com/songch9511/taskforce-new/actions/runs/36728768560)의 `check`·`apple`은 모두 SUCCESS였다. [#60 `dcf5da0`의 필수 CI](https://github.com/songch9511/taskforce-new/actions/runs/36737816271)와 [문서 PR #55의 최신 검사](https://github.com/songch9511/taskforce-new/pull/55/checks)는 해당 HEAD의 결과를 확인한다. CI eval은 키 없는 라벨 검사이고 실제 모델 eval은 위 별도 실행이다.
- **운영 적용 완료:** 사용자 별도 승인 후 `20261018000000_claims_unknown_speaker_role.sql`(기존 화자 역할 제약에 unknown 추가), `20261019000000_claim_state_write.sql`(기존 RPC에서 Claim 상태 보존)을 하나씩 적용·확인한 뒤 #60을 merge했다. 상세는 위 머지 절을 본다. 기존 운영 데이터의 수정·재처리·삭제는 실행하지 않았다. `db push` 금지다.
- 원본 공유 checkout은 `main`/HEAD `72cbe39`, 스테이징 index와 상태 목록이 시작 때와 같다. 시작 스냅샷 27개 파일 중 26개가 같았으며, 다른 세션이 바꾼 `docs/LAUNCH_VIDEO.md`는 건드리지 않았다. 이번 런타임 26개 파일과 eval 4개 파일만 각 전용 브랜치에 커밋했다. 공유 폴더에서 reset·clean·stash·브랜치 전환은 하지 않았다.

### W3 나머지 로그인 사용성 (부분 완료, 후속 Draft는 main 미반영)

기존 W3 표의 보고·추정을 최신 main `da121ba`와 고정 SDK의 실제 호출 흐름으로 다시 확인했다. 코드 작성은 GPT-6 Luna Max가 맡았다. 독립 변경은 겹치지 않는 파일로 분리했으며 이 단계의 새 PR은 merge하지 않는다.

| 우선순위 | 확인된 문제와 조건 | 변경·근거 |
|---|---|---|
| P2 | 설치 SDK가 잘못된 JSON JWT·null/numeric alg 헤더·비문자열 저장 토큰에서 원시 예외를 던져 인증 거절 대신 500을 만든다. 깨진 토큰으로 재현되며 인증 우회·데이터 노출을 확인한 문제는 아니다 | [Draft PR #63](https://github.com/songch9511/taskforce-new/pull/63), `167948e`. API·서버 화면·proxy의 세 getClaims 호출에 같은 오류 경계를 사용한다. SDK 서명·만료 검증은 유지하고 재현한 입력 오류만 SDK의 invalid-JWT 결과로 돌린다. getSession은 손상 토큰을 거절하는 데만 쓰고 session.user를 신뢰하지 않는다. 정상 헤더의 WebCrypto TypeError·구성 오류는 전파하고 JWKS 오류·CSRF·쿠키·리다이렉트를 유지한다 |
| P2 | API가 401을 반환해도 앱은 로그인 상태를 유지하는데 재로그인 안내만 있어 같은 작업을 반복할 수 있다. 401만으로 Supabase 세션 만료라고 확정할 수는 없다 | [Draft PR #61](https://github.com/songch9511/taskforce-new/pull/61), `7289fe5`. 실제 iPhone Account 및 Mac Settings → Account 경로에 맞춰 Sign Out → 로그인 방법과 현재 모든 기기 로그아웃 영향을 안내한다. 로컬 세션이 없으면 로그인 안내만 한다. 자동 로그아웃·세션 무효화 정책은 추가하지 않았다. **2026-10-03 닫음**("모든 기기" 문구가 `.local`과 반대). 401 안내는 [U1 PR1 #81](https://github.com/songch9511/taskforce-new/pull/81)이 다시 썼다: 인증 서버에 세션을 다시 묻고, 계정 · 세션이 없으면 이 기기만 로그아웃, 살아 있으면 "Couldn't verify your sign-in. Sign out, then sign in again." |
| P2 | 이메일 로그인에서 네트워크 단절·429·서버 장애도 이메일/비밀번호 실수로 표시된다. 사용자가 잘못된 원인에 대응하게 된다 | [Draft PR #62](https://github.com/songch9511/taskforce-new/pull/62), `f089a43`. SDK의 오류 코드·URLError로 분류한다. 잘못된 자격 증명 문구는 유지하고 속도 제한·연결 실패를 구분하며, 예상 밖 오류와 허용되지 않은 계정은 같은 중립적인 안내로 처리해 계정 존재·허용 목록을 공개하지 않는다. 실제 SDK fixture에서 수정 전 세 종류의 오분류를 재현했다 |

- #61은 APIClient 27 테스트, 전체 SwiftPM 290 테스트/29 suite를 통과했다. #62는 SessionStore 18 테스트, 전체 SwiftPM 294 테스트/29 suite를 통과했다. 실제 제공자 호출·UI 기기 E2E가 아닌 mock HTTP/SDK fixture 검증이다. 두 PR의 서버 소스·의존성은 `da121ba`와 같아 같은 서버 트리의 로컬 lint·typecheck·1,702 테스트·라벨 검사·build 결과를 재사용한다. 각 최신 HEAD의 필수 CI는 [#61](https://github.com/songch9511/taskforce-new/pull/61/checks), [#62](https://github.com/songch9511/taskforce-new/pull/62/checks)에서 별도로 확인한다.
- #63은 설치된 실제 SDK의 로컬 fixture로 기존 예외를 재현했고, 집중 4 파일/24 테스트와 전체 **133 파일/1,714 테스트**, lint·typecheck·eval 라벨 검사(84 사례)·build·diff 검사를 통과했다. [최신 HEAD 필수 CI](https://github.com/songch9511/taskforce-new/pull/63/checks)를 별도로 확인한다. 추출·판정·병합·프롬프트를 바꾸지 않아 W3에서 실제 모델 eval은 재실행하지 않았다.
- 일반 리뷰에서 인증 거절·정상 사용자 매핑·오류 전파·쿠키/CSRF/리다이렉트를 대조했고, Ponytail 리뷰에서 SDK 재사용과 세 호출부에 필요한 공용 예외 처리만 유지했다. 새 의존성·자체 서명 검증기·로그인 관리 프레임워크는 없다. 세 코드 PR은 모두 병합된 main `da121ba` 기반이며 서로 선행 머지에 의존하거나 같은 파일을 중복 수정하지 않는다.
- 이번 단계 전후 원본 공유 checkout의 `main`/HEAD `72cbe39`, index, 상태 목록과 스냅샷 파일 27개 해시가 모두 같다. 공유 폴더의 다른 세션 변경은 보존했고 새 코드 PR당 2개/2개/8개 파일만 커밋했다. HANDOFF는 별도 문서 브랜치로 분리했다.
- #62에서 저장소 필수 검사가 아닌 stock `swift format lint --strict`도 시도했으나 기존 4칸 들여쓰기를 기본 2칸 규칙과 비교해 실패했다. 저장소에는 그 formatter 설정이 없으므로 기존 스타일을 유지했다. 필수 검사의 실패로 세지 않으며 이 부가 검사를 통과했다고 표현하지 않는다.
- **Google 취소 멈춤: 재현 검증 대기.** 고정 GoogleSignIn-iOS 10.0.0은 AppAuth 사용자 취소와 OAuth `access_denied`를 `.canceled`로 전달한다. 앱은 취소를 조용히 처리하고 완료 경로의 `onFinish`가 런처 자동 닫기 중지를 해제한다. 이 코드 조사만으로 실제 기기 검증을 완료 처리하지 않는다. Mac·iPhone 각각 취소, 권한 거절, 취소 직후 재시도를 실행해 로그인 버튼과 런처가 다시 반응해야 닫는다. 멈춤이 재현되면 호출 흐름과 로그를 근거로 수정하며, 지금은 watchdog·타이머·강제 초기화를 추가하지 않는다.
- **일반 로그아웃: 정책 확정(2026-10-01 KST), 코드 구현 [U1 PR1 #81](https://github.com/songch9511/taskforce-new/pull/81)(2026-10-03 병합, `307209f`) · 실제 기기 E2E 대기.** 기본은 명시적 `.local`로 이 기기 세션만 종료한다. 다른 기기의 세션은 유지하며, 모든 기기 로그아웃은 필요할 때 별도의 명시적 동작으로 다룬다. #81은 `SessionStore.signOut()`을 `.local`로 바꾸고 API 401 복구 문구에서 모든 기기 로그아웃 안내를 제거했으며, 계정이 이 기기를 떠날 때(로그아웃 · 만료 · 계정 삭제 · 전환) 부르는 정리 지점 `SessionStore.onSignedOut`을 두었다. 현재 기기의 런처 화면 · 메모리 목록 · 진행 중 요청은 초기화하고 늦은 응답은 `NowStore` · `AccountStore` 세대 번호로 버리며, API 응답 디스크 캐시를 끈다. Mac 저장본 정리는 후속 U1 PR에서 같은 정리 지점에 등록됐고 코드 테스트를 통과했다. #81에는 `.local` 뒤 다른 기기 세션 갱신 유지와 늦은 응답 정리의 모의 회귀 테스트가 있다. PR #61은 2026-10-03 닫혔고 #81로 대체됐다. **실제 Mac · iPhone에서 로그아웃, 이전 계정 데이터·요청 정리, 다른 기기 세션 유지·갱신을 검증하지 않았으므로 W3는 부분 완료다.** 출시 전 실제 기기 확인은 남았다. SDK의 세션 정리는 재사용한다. [공식 signout 문서](https://supabase.com/docs/guides/auth/signout)는 두 범위를 지원하며, 폐기한 세션의 access token도 만료까지 유효할 수 있다고 설명한다. 다른 기기의 즉시 화면 종료를 global 검증 기준으로 삼지 않는다.
- **계정 통합: 이번 범위 밖으로 보류, 완료 아님.** 이미 존재하는 두 계정의 데이터 병합은 할 일·연결·동의·중복 처리 결정을 포함하는 별도 기능이다. 현재 계정·로그인 수단 표시와 Apple 이메일 가리기 사용 시 기존 Apple 로그인으로 돌아가는 안내는 후속 구현·검증 항목으로 남긴다. 이후에는 로그인한 기존 계정에 로그인 수단을 추가하는 [공식 identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking)을 먼저 검토하되, 이를 두 계정의 앱 데이터 병합과 같은 작업으로 취급하지 않는다. 이번에는 UI·인증 설정·운영 계정·데이터를 변경하지 않는다.
- **상태 집계 원칙:** W3는 **부분 완료**다. 위 세 버그 수정의 코드·로컬 테스트·CI 완료와 W3 전체 완료는 다르다. `.local` 구현은 W1과 분리된 PR #81에서 병합됐다. PR #61의 모든 기기 안내도 #81에서 제거됐다. Mac 저장본 정리와 계정 간 늦은 응답 방지는 뒤이은 별도 U1 PR에서 추가됐다. 코드·모의 테스트는 있지만 실제 기기 로그아웃과 다른 기기 세션 갱신 검증은 남아 있다. Google 취소는 재현 검증 대기, 실제 OAuth·연결·기기 E2E는 출시 전 필수 미실행이다. **W3 최종 완료 조건은 로그아웃 동작·현재 기기 데이터와 진행 중 요청 정리·다른 기기 세션 유지 검증을 포함한 `.local` 경로 완료 + 실제 인증·취소 E2E 통과**이며, 계정 통합은 별도 기능이라 이 완료 조건에 포함하지 않는다. W3 미완료 항목은 독립적인 W1 작업을 막지 않는다. 보류·미실행·미재현을 성공 또는 완료로 집계하지 않는다.

### W1 확인 부담 재검증 (2026-10-01 KST)

- **진단 범위:** 09-30 당시 확인 요청 43%와 담당 불확실 31건은 과거 집계이며 이번에 운영 원문을 읽거나 현재 비율로 다시 측정하지 않았다. 최신 main `da121ba`의 앱 Confirm/Dismiss, 원문 재처리, Claim 판정·병합, 알림 호출 흐름을 대조했다. W2의 담당 충돌·불확실한 Claim 보류·낮은 병합 확신도 보호는 유지한다.
- **수정 전 확인된 P2:** `mergeTask`는 연결된 완료 항목의 이후 속성 변경도 Claim으로 보관한다. 예를 들어 동료가 담당을 바꾸면 확인 사유가 생길 수 있다. `SupabaseActionStore`는 `needs_confirmation`만 보고 알림 대상으로 삼고 `processTaskSource` → `notifyConfirmations`는 그 ID로 푸시를 보낸다. 하지만 `/now`와 `rankNow`, Mac·iPhone의 Review 목록은 열린 항목 중 담당이 other가 아닌 것만 보여 준다. 닫힌 항목·남의 항목에 생긴 확인은 푸시를 눌러도 목록에 없고, 같은 처리에서 닫힌 항목의 ID도 큐에 남을 수 있다. 반대로 확인 사유를 유지한 채 다시 열린 항목은 false→true 변화가 없어 알림을 놓친다. 호출 흐름으로 확인한 조건부 버그이며 운영 발생 빈도·푸시 수신 건수는 미측정이다.
- **구현·검증 완료, Draft 미머지:** [PR #65](https://github.com/songch9511/taskforce-new/pull/65), 커밋 `d56d6ea` (`codex/w1-confirmation`). 최신 main `da121ba`에서 분리했고 W3 Draft #61–#63에 의존하거나 파일이 겹치지 않는다. GPT-6 Luna Max가 `rank.ts`, `db-store.ts`, `db-store.test.ts`만 수정했다. 목록과 생성·붙임 후 알림 큐가 같은 작은 조건(`open` · owner가 `other`가 아님 · 확인 필요)을 쓰며, Review에 들어올 때만 알리고 같은 처리에서 대상 밖으로 나가면 ID를 뺀다. 담당 판정·Claim·확인 사유·이벤트·동시 수정 재시도·사용자 범위는 유지했다. 일반 리뷰와 Ponytail 리뷰에서 추가 필수 문제를 찾지 못했다.
- **검증 증거와 한계:** 수정 전 회귀 테스트는 5건 실패했고 수정 후 관련 20개 테스트가 통과했다. 전체 130개 파일 / **1,708개 테스트**, lint, typecheck, build, `git diff --check`가 통과했다. `npm run eval -- --labels`도 통과했다(추출 84건, 기대 Action 101개, 금지 문장 221개; 물어보기 8건). 추출·판정·병합·프롬프트·골든셋은 바꾸지 않아 실제 모델 채점을 재실행하지 않았고 품질 지표 개선으로 표현하지 않는다. 최신 커밋의 필수 CI `check`·`apple` 결과는 [PR 검사](https://github.com/songch9511/taskforce-new/pull/65/checks)에서 별도로 확인한다. 실제 APNs 수신·OAuth·연결·기기 E2E는 미실행이며 출시 전 검증으로 남긴다. 로컬 로그는 `/var/folders/xj/m5m8d4j96f9_msr1vt_x577m0000gn/T/taskforce-w1-dpadye9k/`에 있다.
- **작업 공간 보존:** 이번 단계 시작 시점의 공유 원본 `main`/HEAD `72cbe39`, index, 상태 목록이 최종 점검에서도 같다. 스냅샷 파일 27개 중 26개가 같고, 진행 중 다른 세션이 바꾼 `docs/LAUNCH_VIDEO.md`는 그대로 보존했다. 다른 세션의 변경과 별도 dirty W2 Claim 작업 트리는 건드리지 않았다. 운영 DB 변경·원문 조회·새 PR 머지는 실행하지 않았다.
- **이미 있는 반복 방지:** 같은 구조화된 할 일 속성 스냅샷은 다시 처리하지 않고, 재시도 원문의 이미 적용된 인용은 병합 전에 제외한다. 한 원문의 여러 확인 요청은 푸시 하나로 묶으며, 같은 처리에서 확정돼 확인이 풀린 항목은 큐에서 뺀다. 충분히 확실한 본인 발언이 붙으면 기존 판정 확인을 푸는 경로도 있다. 이 기능을 중복 구현하지 않는다.
- **억지로 바꾸지 않은 항목:** 판정 이유만 있는 Confirm은 그 이유를 지우고 `user_confirmed` 이벤트를 남기되 필드 Claim을 추가하지 않을 수 있다. 같은 원문 재시도는 이미 인용으로 중복을 막고, 다른 원문의 새 불확실성은 다시 확인할 근거가 있다. 단지 이전에 확인했다는 이유로 이후의 담당·병합 확인을 모두 억제하지 않는다. Confirm이 현재 불확실한 필드를 함께 확인하는 동작도 기존 문서의 한 번 탭 확인과 모순되는 버그로 확인하지 못했다.
- **제품 선택으로 남는 W1 범위:** 담당 증거가 없는 원문을 자동 배정하거나 임계값을 낮추는 방식은 사용하지 않는다. 다음 최소 방향 후보는 **같은 원문의 근거를 보면서 사용자가 선택한 항목만 함께 확인하는 UI**다. 이 기능은 클릭 수를 줄이지만 선택 범위·부분 실패 처리 등 제품 선택이 필요해 이번에 구현하지 않았다. Calendar 참석 사실이나 Notion 문서 작성자만으로 개별 할 일 담당을 확정하지 않으며, W2의 `written_by_me` 정책도 그대로 둔다. 이번 알림 수정으로 과거 43% 확인 비율이나 담당 불확실성이 해결됐다고 표현하지 않는다.

## 2. 작업 규칙 (저장소 소유자와 합의)

- 코드 작성은 GPT-6 Luna Max에 위임한다. 최신 `origin/main` 기반 전용 worktree에서 작업하고, 공유 원본 checkout의 미커밋 상태는 보존한다 (`reset` · `clean` · `stash` · 브랜치 전환 금지).
- **PR #54 최종 수정과 merge는 승인되어 완료됐다.** W1–W5 진단, 코드 수정, 회귀 테스트, 후속 PR 초안 작성은 승인되어 있으며 일반 버그마다 다시 승인받을 필요는 없다. 각 단계가 끝나면 근거와 결과를 보고하고 멈춘다. 3장의 W1–W5는 승인된 후속 작업 범위다. 문서에 적힌 방향 선택 등 제품 선택이 필요한 변경은 답을 얻을 때까지 보류한다.
- W3 치명적 인증·계정·세션과 W2를 마친 뒤 사용자 요청으로 기존 PR을 머지했다. W3 나머지 UX의 세 버그 수정은 Draft로 정리했고 W3는 부분 완료다. 2026-10-01 후속 정책 요청에서는 코드·설정을 변경하지 않았으며, 이후 사용자가 W1의 독립 진행을 지시했다. 남은 W3 항목은 W1을 막지 않는다. 이번 단계는 W1만 진행하고 마친 뒤 보고하며, W4·W5는 아직 시작하지 않았다.
- #55–#60의 merge와 명시적으로 승인된 두 스키마 변경은 완료했다. 이후 후속 PR merge(운영 배포), 새 운영 DB 쓰기, 계정 통합, 파괴적인 정리는 별도 승인이 필요하다. 확인된 인증 우회, 타인 데이터 접근, 데이터 손실, 잘못된 자동 완료는 아래 우선순위보다 먼저 다룬다.
- 후속 작업 순서: W3 치명적 인증·계정·세션 → W2 잘못된 담당·상태 변경 → W3 나머지 UX → W1 확인 부담 → W4 처리 실패·복구 → W5 누락·갱신.
- **`npx supabase db query --linked`는 운영 프로젝트다.** 조회는 `SELECT` 집계만, 원문 본문 · 이메일은 읽지 않는다. 쓰기와 새 마이그레이션 적용은 사용자 승인 뒤 파일 하나씩 `db query --linked -f`로 한다. `db push` 금지 ([런북 4장](go-live/runbook.md)).
- **`main` 병합은 Vercel 운영 배포다.** PR #54 배포는 완료됐으며, 후속 PR은 별도 merge 승인 뒤 배포한다. 새 마이그레이션이 있으면 승인된 운영 DB 적용을 merge보다 먼저 해야 한다. `db push` 금지 ([런북 4장](go-live/runbook.md), [google-integration.md](go-live/google-integration.md) 마이그레이션 적용 대상).
- **키:** `.env.local`은 개발 키(누적 한도 $20), 운영 키 `taskforce-prod`는 하루 $5다. `npm run eval` 1회가 약 $0.16이다. 9/30에 키를 같이 쓰다 $10 한도에 걸려 모든 AI 호출이 403이었다 ([런북](go-live/runbook.md) I9). 로컬에서 운영 키를 쓰지 않는다.
- **PR 흐름:** 브랜치 → PR → CI(`check`: lint · typecheck · test · eval · build, `apple`: `swift test` + iOS · macOS 빌드) → `gh pr merge --merge`. 프롬프트 · 파이프라인을 바꾸면 `npm run eval` 결과를 PR에 적는다 (CLAUDE.md).
- 사용자 원문을 로그에 평문으로 남기지 않는다. 마이그레이션 · RLS 규칙은 CLAUDE.md의 기술 스택 절을 따른다.

## 3. W1–W5 후속 작업 기록 (2026-09-30 09:00 UTC 기준)

아래 수치와 관찰은 2026-09-30 09:00 UTC 읽기 전용 집계와 당시 코드·문서 조사 기록이다. `확인`은 그때 코드를 읽어 확인, `보고`는 당시 조사 보고에 근거, `추정`은 가설을 뜻한다. PR #54 단계에서 이 항목들을 새로 재검증하지 않았다. 이후 W3 치명적 경로와 W2에서 새로 확인한 사실은 1장 별도 절을 보며, 이 당시 표 자체를 현재 상태나 새로 확인된 버그로 해석하지 않는다. W1–W5의 진단·수정·회귀 테스트·후속 PR 작성은 2장의 범위에 따라 진행하되, 제품 선택이 필요한 안은 보류한다. 파일은 함수 이름으로 찾는다 (줄 번호는 바뀐다).

### W1. 확인 요청이 너무 많다 (제품 원칙 3)

- 근거: 1장 집계. 후보의 43%가 확인 요청이고, 원인은 거의 전부 담당 불확실이다. 회사 회의는 대부분 Notion 전사만 켜져 있어 화자가 없다 ([google-integration.md](go-live/google-integration.md) G2 · 위험 표). Notion 전사에는 화자 표시가 없고 Notion AI 요약 항목에는 담당자가 없다 (2026-09-26 9개 회의로 확인).
- 방향 후보(사용자가 고른다): 소스별 일괄 확인 / Calendar 참석자 · Meet 화자로 담당 신호 보강(Google 연결이 열려야 한다) / Notion AI 요약 항목을 따로 다루기.
- 확인 방법: 골든셋 + `npm run eval`의 정밀도 · 재현율 · 담당 정확도를 PR에 적는다.

### W2. 남의 할 일이 내 것으로 들어올 수 있다

텍스트 원문의 담당은 추출기의 `owner`와 Jev의 `is_my_commitment` 하나로 정해진다 (0.8 이상 자동, 0.4 미만 기각, 사이는 확인, `judge.config.ts`).

| # | 문제 | 근거 | 상태 |
|---|---|---|---|
| a | `owner_confidence`를 읽기만 하고 어디서도 비교하지 않는다 | `pipeline/extract.ts`가 읽고, `pipeline/missing.ts`가 1로 고정한다. `judge.ts` `decideOutcome`은 `is_my_commitment` · `is_actionable` · 확신 · 완료 신호만 본다 | 확인 |
| b | 이메일이 달라도 이름만 같으면 사용자로 본다. 세 글자 한글 이름은 성을 뺀 이름도 사용자 이름으로 친다 | `pipeline/identity.ts` `isUser` · `userNameForms` | 확인 |
| c | 중복 · 갱신으로 병합할 때 "판정 확인"을 남기지 않는다. 다른 사람의 완료 소식이 내 할 일을 닫을 수 있다 | `pipeline/merge.ts` | 보고 |
| d | "내가 쓴 문서"는 회의 문서(`<meeting-notes>` 블록이나 제목이 회의 · 싱크 · 1:1 · Weekly 류)가 아니면 사람 이름이 없는 할 일을 내 것으로 본다 | `connectors/notion/map.ts` `written_by_me`, `judge.ts` | 보고 |
| e | eval의 담당 정확도는 정답 항목 안에서만 계산해 오귀속을 못 본다. 오귀속은 "함정 자동 반영"으로만 잡힌다 | `lib/eval/score.ts` `ownerAccuracy` | 확인(계산 방식) |

- 운영 데이터상 지금까지의 피해는 크지 않아 보인다: 자동 26건 중 담당 확신도 0.7 미만 1건, 담당이 `me`가 아닌 것 0건. 다만 그 26건이 정말 내 것인지는 **아무도 검수하지 않았다** (4장).
- 추가할 테스트: 이메일이 다른 동명이인 `isUser`, 성을 뺀 이름이 다른 참석자와 겹칠 때, 낮은 `owner_confidence`, 중복 · 갱신에서 판정 확인 유지, 회의가 아닌 제목의 내가 쓴 문서, 화자 없는 Notion 회의 + 이름 같은 동료 골든셋.

### W3. 로그인 · 세션

| # | 문제 | 근거 | 상태 |
|---|---|---|---|
| a | 서버가 토큰을 거절(401)해도 앱은 로그아웃하지 않고 "Sign in again" 안내만 반복한다 | `TaskforceKit/APIClient.swift` `perform` | 확인 |
| b | Sign Out이 모든 기기의 세션을 폐기한다 (기본 범위 `.global`) | `TaskforceKit/SessionStore.swift` `signOut()` | 확인 |
| c | Apple 이메일 숨기기 + Google이면 계정이 둘 생기고, 둘째는 비어 있어 데이터가 사라진 것처럼 보인다. 문서는 "감수"로 적었다 | [PLATFORMS.md](PLATFORMS.md) 로그인 절 "계정 연결" | 확인(문서) |
| d | Mac Google 로그인이 SDK 콜백 없이 닫히면 런처가 열린 채 굳을 수 있다 | `Shared/GoogleSignIn.swift` · `Mac/LauncherModel.swift` (`suspendsAutoClose`, `GoogleSignInFlow.running`) | 보고 (추정) |
| e | 서버 인증이 `sub` · `role`을 확인하지 않고, `authenticateRequest`에 단위 테스트가 없다 | `lib/api/auth.ts` | 보고 |
| f | 이메일 로그인 실패를 전부 "Check your email and password"로 보여 준다 (네트워크 · 속도 제한 포함) | `SessionStore.swift` | 보고 |
| g | Keychain `-34018`은 로그인 세션 저장 실패로 나타난다. App Group이 프로필에 없을 때가 문서화된 원인이고([apple/README.md](../apple/README.md) 처음 한 번 4), 서명하지 않은 빌드(`CODE_SIGNING_ALLOWED=NO`)에서도 같은 오류가 났다. 그 빌드를 서명하니 Home까지 갔다 | 이전 세션 기록 + 문서 | 보고 |

- 코드로는 증명할 수 없는 것: 서명한 Release 빌드의 토큰이 `api.taskforcelabs.dev`에서 통과하는지 (5장 1번).

### W4. 처리 실패가 사용자에게 보이지 않는다 (급하지 않음)

- **상태 (2026-10-02, #70 병합):** 서버 쪽은 보인다. 실패로 닫은 원문은 까닭 코드 `sources.processing_error_code`(`ai_quota` · `ai_timeout` · `ai_output` · `consent` · `expired` · `internal`)를 남기고, 시도를 다 쓰거나 창이 지나거나 동의를 철회해 닫으면 지표 이벤트 `source_failed`(서비스만, 원문 없음)를 남긴다. `GET /api/v1/now`는 하루 안의 실패를 `failed_sources`(개수 · 마지막 시각 · 까닭)로 돌려주고, `/admin/metrics` 발견 원가 카드에 실패로 닫은 수가 서비스별로 나온다. 남은 것: 앱이 "All caught up" 대신 실패를 보여 주는 화면(U1 셸). 아래는 그 전 기록이다.
- 운영에서 실패는 2/294라 지금은 드물다. 그래도 실패한 원문은 앱에 보이지 않고(연결이 있고 목록이 비면 "All caught up"), `metric_events`에 처리 실패 이벤트도 없다. 재시도는 첫 처리를 포함해 3번까지, 하루 안에서만 한다 (`sources/retry.ts`).
- 새 운영 키는 하루 $5다. 첫 동기화(Notion · Gmail 각 14일치)가 한꺼번에 들어오면 한도에 걸릴 수 있다 (추정).

### W5. 원문 범위 (추정, 영향은 데이터로 확인)

- Gmail 필터가 도구 알림 메일(`no-reply` · `notification@`)과 외부 메일링 리스트를 버린다 (`connectors/gmail/filter.ts`). gmail.com 계정은 회사 도메인이 없어 리스트 메일을 모두 버린다.
- Notion 페이지는 30분 동안 수정이 없을 때 한 번만 가져온다. 그 뒤에 AI 요약이 붙어도 다시 처리하지 않는다.

## 4. 09:00 UTC 당시 미확인 항목 (이후 재검증하지 않음)

1. **자동 반영 26건이 정말 내 것인가.** 제목 · 인용을 사람이 봐야 한다 (원문 본문 접근이라 소유자 승인이 필요하다).
2. **로그인 계정과 프로필의 차이.** 다른 소셜 계정으로 로그인해 빈 새 계정이 생겼는지 `auth.users` 집계(제공자 · 프로필 유무)로 봐야 한다. 이번에는 승인 범위 밖이라 조회하지 않았다.
3. **`dropped` 20/90의 사유.** 사용자가 지운 것인지 시스템이 닫은 것인지 이 집계로는 구분되지 않는다 (`action_events`를 봐야 한다).
4. **Supabase Before-User-Created 훅이 운영에서 켜져 있는지.** 런북에 ✅가 없다. 꺼져 있으면 이메일 가입이 열려 있다.
5. **Vercel 로그.** 보관이 1일이라 9/30 이전 실패의 로그 근거는 남아 있지 않다.

## 5. 출시 전 필수 OAuth·연결·기기 E2E (미실행)

아래 실제 제공자·서명 기기 E2E는 PR #54, W3 치명적 경로·W2·W3 나머지 단계에서 실행하지 않았다. 2026-10-01 사용자 지시에 따라 필수적인 막힘이 없는 한 W1–W5 완료 뒤에 수행한다. 운영 배포 완료나 무인증 HTTP 401은 이 검증을 대신하지 않는다. 항목 번호는 [런북 체크리스트](go-live/runbook.md#go-live-체크리스트)와 같다.

**출시 순서:** 테스트용 서명 Release 빌드 → 내부 배포 → 아래 실제 E2E → 공개 배포. W1–W5 뒤에 하나의 출시 검증 단계로 실행하며, 아래 최소 항목의 실제 증거를 확보하기 전에는 공개 출시 검증 완료로 처리하지 않는다. 이 순서의 기록이 내부·공개 배포나 운영 변경을 지금 실행하라는 승인은 아니다.

| 최소 필수 검증 | 종료 조건 | 현재 상태 |
|---|---|---|
| Mac·iPhone Apple·Google 로그인과 세션 복원 | 서명 Release에서 제공자별 로그인 후 앱 재실행으로 같은 계정 세션 복원, 해당 세션의 서버 API 정상 응답 | 미실행 |
| 실제 연결 → 원문 수집 → 할 일 표시 | 연결한 제공자의 새 원문과 앱에 표시된 할 일·근거를 대조 | 미실행 |
| 계정 전환 격리 | 전환 후 이전 계정 화면·캐시·진행 중 요청의 늦은 결과가 노출되지 않음 | 미실행 |
| 취소·권한 거절·직후 재시도 | Mac·iPhone에서 로그인 버튼과 런처가 다시 반응하고 재로그인 가능 | 실제 기기 E2E 미실행 |
| 일반 로그아웃 `.local` | 현재 기기 화면·캐시·요청 정리 및 재실행 후 로그아웃 유지, 다른 기기의 세션·갱신 유지, 안내 문구와 동작 일치 | 활성 Mac 작업본에 구현됨; 실제 기기 E2E 미실행 |

다음 기존 런북 항목도 유지한다.

1. TestFlight(서명한 Release) 빌드로 Apple 로그인 → 그 세션의 access token으로 `GET /api/v1/now`가 200인지 (I5). Supabase URL · 키가 서버와 같은지가 핵심이다 (Release 빌드는 아카이브한 Mac의 `Secrets.xcconfig`를 쓴다).
2. Google 로그인: iPhone · Mac(런처 위 브라우저 시트 포함), Apple로 만든 계정과 같은 이메일일 때의 동작 (I13).
3. 새 계정으로 처음부터 끝까지: 로그인 → AI 동의 → Notion 연결 → 첫 동기화 → 할 일 표시 → 체크 (G1, I6).
4. 확인 요청 알림 수신과 눌렀을 때 해당 할 일로 이동 (I7, C10).
5. 계정 삭제 뒤 Apple · Google 서드파티 앱 목록에서 사라지는지 (C2, I13).
6. 동의 철회 → 동기화가 멈추고, 다시 동의하면 재개되는지.
7. cron 4개가 정해진 주기에 200인지 (I11).

## 6. 운영 읽기 전용 조회

`npx supabase db query --linked "<쿼리>"`, 저장소 루트에서. `SELECT` 집계만 쓴다.

```sql
-- 프로필 · 동의
select count(*) profiles, count(ai_consent_at) consented from public.profiles;
-- 연결 상태
select provider, status, count(*) n, max(last_synced_at) last_sync,
       count(*) filter (where last_error is not null) with_error,
       count(*) filter (where sync_started_at is not null) claimed_now
from public.connections group by 1,2 order by 1,2;
-- 원문 처리 상태 (연동별)
select coalesce(c.provider,'(pasted)') provider, s.processing_status, count(*) n, max(s.created_at) last_created
from public.sources s left join public.connections c on c.id = s.connection_id group by 1,2 order by 1,2;
-- 실패 · 멈춘 원문의 오류 종류
select processing_status, left(coalesce(processing_error,'(none)'),70) err,
       coalesce(processing_summary->>'closed','') closed, count(*) n
from public.sources where processing_status in ('failed','pending','processing') group by 1,2,3 order by n desc limit 15;
-- 판정 결과
select decision, count(*) n, count(*) filter (where jev_answers::text ilike '%NOT_MY_ACTION%') mentions_not_mine
from public.judge_logs group by 1 order by 1;
-- 담당 확신도 분포
select decision, count(*) n, round(avg((candidate->>'owner_confidence')::numeric),2) avg_owner_conf,
       count(*) filter (where (candidate->>'owner_confidence')::numeric < 0.7) owner_conf_lt_07
from public.judge_logs where candidate ? 'owner_confidence' group by 1 order by 1;
-- 할 일 상태
select owner, status, needs_confirmation, count(*) n from public.actions group by 1,2,3 order by n desc;
```

## 7. 저장소 밖 산출물 (커밋되지 않음)

- `.claude/`: Claude Code 도구 폴더. `launch.json`(미리보기 서버 설정)과 `worktrees/`(다른 세션의 작업 트리 사본, 2026-09-30에 약 17GB)가 있다. 사본마다 `node_modules`가 있다. 지우기 전에 브랜치가 병합됐고 변경이 없는지 확인한다 (`git worktree list`). 이날 확인한 22개는 모두 병합 · 변경 없음이었고, `claude/email-account-deletion`만 병합되지 않은 브랜치(PR #45, 닫힘)다. `launch.json`의 `slack-dev` 설정은 `worktrees/slack-milestone`을 쓴다.
- **lint:** 이 폴더가 있는 체크아웃에서 `npm run lint`는 사본까지 훑어 3분 넘게 걸리고 5,894개 오류로 실패했다(깨끗한 작업 트리에서는 통과). `eslint.config.mjs`가 `.claude/**` · `.omc/**`를 무시하도록 고쳤고 이제 5초 안에 통과한다.
- `.omc/`: 도구 상태와 일회성 스크립트. `.omc/scratch/drop-actions.mts`는 `.env.local`의 서비스 키로 지정한 할 일을 **삭제한다** (운영에 쓰기). 실행하지 않는다.
- `vibe-coding-kit/`: 범용 작업 규칙 모음(`AGENTS.md` + `vibe-coding/`). 저장소 어디에서도 참조하지 않는다.
