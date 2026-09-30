# 에이전트 핸드오프 (2026-09-30, PR #54 완료)

다른 에이전트(Codex 등)가 이 저장소를 이어받을 때 먼저 읽는 문서다. 규칙은 [CLAUDE.md](../CLAUDE.md), 기능 위치는 [FEATURE_MAP.md](FEATURE_MAP.md), 남은 출시 일은 [GO_LIVE.md](GO_LIVE.md)와 [런북 체크리스트](go-live/runbook.md)가 기준이다. 이 문서는 PR #54 완료 상태와 **2026-09-30 09:00 UTC QA의 당시 기록 및 후속 작업 승인 범위**를 함께 담는다.

## 1. 지금 상태

- [PR #54](https://github.com/songch9511/taskforce-new/pull/54)는 Draft 해제 후 2026-09-30 11:56:31 UTC `b944b40` merge commit으로 `MERGED` 됐다. PR 최종 HEAD는 `35a24ec`이며 merge tree와 완전히 같다.
- PR #54 최종 HEAD `35a24ec`에서 `npm run lint`, `npm run typecheck`, 전체 테스트 128 파일 · 1,645 테스트, 실제 모델 eval, `npm run build`가 통과했다. merge commit의 코드 tree가 같아 이 결과를 재사용한다. GitHub Actions [`check`와 `apple`](https://github.com/songch9511/taskforce-new/actions/runs/36708650219)도 모두 `SUCCESS`다. CI의 eval 단계는 키 없이 실행하는 라벨 검사이며 실제 모델 eval과 구분한다.
- 실제 모델 eval은 2026-09-30 11:26 UTC 개발 키로 실행했다. 자동 반영과 확인 요청 합계: precision 91.5%, recall 92.9%, 담당 정확도 96.9%, 기한 정확도 98.5%. 자동 반영만: precision 98.2%, recall 81.8%, 담당·기한 정확도 100%. 시퀀스 28/28 정답, 추가 0, pending 2; 질문 8/8; 오류 0; 비용 $0.164.
- 운영 배포 `6758727983`은 SHA `b944b40`로 11:57:24 UTC에 GitHub의 Vercel Production deployment 상태 `success` / `Deployment has completed`임을 확인했다. [배포 URL](https://taskforce-chah5ca8a-songch9511s-projects.vercel.app). `GET https://api.taskforcelabs.dev/api/v1/now`의 무인증 요청은 HTTP 401이었다. 이것은 인증이 없는 요청의 기본 응답만 확인한 것이며 유효 토큰 로그인이나 E2E 증거가 아니다.
- 이번 단계에서 실제 제공자 OAuth, 로그인·연결, 서명 기기 E2E는 실행하지 않았고 운영 DB 변경도 없었다.
- **당시 기준선 (2026-09-30 09:00 UTC, 읽기 전용 집계; 현재 상태로 간주하지 않음):**
  - 연결 4개(Notion 3 · Gmail 1) 모두 `active`, 마지막 동기화 08:45 UTC, 오류 · 걸린 잠금 없음. Slack · Google(Calendar · Meet) 연결은 없다 (Google은 심사 전이라 닫혀 있다).
  - 원문 294건: 처리 완료 292, 실패 2, 멈춘 것 0. 실패 2건은 모두 `빈 응답 (finish_reason: length)` (9/27 · 9/29, 재시도 수정 전).
  - 판정 후보 75건: 자동 반영 26 · 확인 요청 32 · 기각 17. 확인 요청 32건 중 31건이 "내 일인지 불확실(`NOT_MY_ACTION`)"이다. 화자(`quote_speaker`)가 있는 후보는 3건뿐이다.
  - 할 일 90개(전부 owner `me`): 열림 62(그중 확인 대기 16), 끝남 8, `dropped` 20.
  - 프로필 4개 중 3개만 AI 동의를 마쳤다. 동의 없는 프로필 1개는 동기화 대상에서 빠진다 (`syncable_connections`).
  - 원문이 있는 계정은 모두 열린 할 일이 있다. "할 일이 아예 안 생기는 계정"은 이 집계에서 보이지 않았다.

## 2. 작업 규칙 (저장소 소유자와 합의)

- 코드 작성은 GPT-6 Luna Max에 위임한다. 최신 `origin/main` 기반 전용 worktree에서 작업하고, 공유 원본 checkout의 미커밋 상태는 보존한다 (`reset` · `clean` · `stash` · 브랜치 전환 금지).
- **PR #54 최종 수정과 merge는 승인되어 완료됐다.** W1–W5 진단, 코드 수정, 회귀 테스트, 후속 PR 초안 작성은 승인되어 있으며 일반 버그마다 다시 승인받을 필요는 없다. 각 단계가 끝나면 근거와 결과를 보고하고 멈춘다. 3장의 W1–W5는 승인된 후속 작업 범위다. 문서에 적힌 방향 선택 등 제품 선택이 필요한 변경은 답을 얻을 때까지 보류한다.
- 이 핸드오프 갱신 시점에 W1–W5는 아직 시작하지 않았다. 현재 단계는 PR #54 완료 처리에서 멈춘다.
- 후속 PR merge(운영 배포), 운영 DB 쓰기, 계정 통합, 파괴적인 정리는 별도 승인이 필요하다. 확인된 인증 우회, 타인 데이터 접근, 데이터 손실, 잘못된 자동 완료는 아래 우선순위보다 먼저 다룬다.
- 후속 작업 순서: W3 치명적 인증·계정·세션 → W2 잘못된 담당·상태 변경 → W3 나머지 UX → W1 확인 부담 → W4 처리 실패·복구 → W5 누락·갱신.
- **`npx supabase db query --linked`는 운영 프로젝트다.** 조회는 `SELECT` 집계만, 원문 본문 · 이메일은 읽지 않는다. 쓰기와 새 마이그레이션 적용은 사용자 승인 뒤 파일 하나씩 `db query --linked -f`로 한다. `db push` 금지 ([런북 4장](go-live/runbook.md)).
- **`main` 병합은 Vercel 운영 배포다.** PR #54 배포는 완료됐으며, 후속 PR은 별도 merge 승인 뒤 배포한다. 새 마이그레이션이 있으면 승인된 운영 DB 적용을 merge보다 먼저 해야 한다. `db push` 금지 ([런북 4장](go-live/runbook.md), [google-integration.md](go-live/google-integration.md) 마이그레이션 적용 대상).
- **키:** `.env.local`은 개발 키(누적 한도 $20), 운영 키 `taskforce-prod`는 하루 $5다. `npm run eval` 1회가 약 $0.16이다. 9/30에 키를 같이 쓰다 $10 한도에 걸려 모든 AI 호출이 403이었다 ([런북](go-live/runbook.md) I9). 로컬에서 운영 키를 쓰지 않는다.
- **PR 흐름:** 브랜치 → PR → CI(`check`: lint · typecheck · test · eval · build, `apple`: `swift test` + iOS · macOS 빌드) → `gh pr merge --merge`. 프롬프트 · 파이프라인을 바꾸면 `npm run eval` 결과를 PR에 적는다 (CLAUDE.md).
- 사용자 원문을 로그에 평문으로 남기지 않는다. 마이그레이션 · RLS 규칙은 CLAUDE.md의 기술 스택 절을 따른다.

## 3. W1–W5 후속 작업 기록 (2026-09-30 09:00 UTC 기준)

아래 수치와 관찰은 2026-09-30 09:00 UTC 읽기 전용 집계와 당시 코드·문서 조사 기록이다. `확인`은 그때 코드를 읽어 확인, `보고`는 당시 조사 보고에 근거, `추정`은 가설을 뜻한다. PR #54 단계에서 이 항목들을 새로 재검증하지 않았으므로 현재 상태나 새로 확인된 버그로 해석하지 않는다. W1–W5의 진단·수정·회귀 테스트·후속 PR 작성은 2장의 범위에 따라 진행하되, 제품 선택이 필요한 안은 보류한다. 파일은 함수 이름으로 찾는다 (줄 번호는 바뀐다).

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

## 5. 외부 제공자·기기 E2E 미실행 항목

아래 실제 제공자·서명 기기 E2E는 PR #54 단계에서 실행하지 않았다. 운영 배포 완료나 무인증 HTTP 401은 이 검증을 대신하지 않는다. 항목 번호는 [런북 체크리스트](go-live/runbook.md#go-live-체크리스트)와 같다.

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
