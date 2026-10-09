# 맥락층 (0.2.0 B1) — 결정 기록과 위치

0.2.0 구현 계획 B1. 기억 · 범위 · 사람 · 신원 링크 · 원문 조각 · 맥락 묶음을 서버 코드와 DB 규칙으로 붙였다. 보이는 행동은 없다:
gate `MEMORY_ENABLED` · `SOURCE_CHUNKS_ENABLED`(`src/lib/flags.ts`)가 기본 꺼짐이고, 꺼져 있으면 서버는 새 표를 읽지도 쓰지도 않고 임베딩을 부르지 않는다.
route(대화 v2 · 기억 편집 API)는 B2가 붙인다.

| 무엇 | 위치 |
|---|---|
| 순수 규칙 | `src/lib/context/memory.ts`(주제 정규화 · 쓰기 입력) · `retrieve.ts`(읽을 때의 해석 · 원문 거르기) · `bundle.ts`(묶음 · manifest) · `chunks.ts`(조각 나누기 · 만들기) · `people.ts`(상대 계정) · `identity-links.ts`("나"의 주소) · `contexts.ts`(멤버 열 · stale) |
| DB 쪽 (service role) | `src/lib/context/store.ts` |
| 스키마 · 규칙 · 전파 | `supabase/migrations/20261104000000_context_layer.sql` (A2 `20261103000000_context_core.sql` 위에 더함) |
| 기존 경로에 붙인 곳 | `src/lib/connectors/store.ts`: `loadIdentity`(링크 합치기, `MEMORY_ENABLED`) · `ingestDeps().process`(처리 뒤 조각, `SOURCE_CHUNKS_ENABLED`) · `saveConnection`(oauth 링크, `MEMORY_ENABLED`) |
| 권한 경계 | `src/lib/context/boundary.test.ts` + `eslint.config.mjs`(맥락층은 `src/lib/execution`을 가져오지 않는다) + DB 확인(`tests/db/context-layer.scenarios.ts` "권한 · 경계") |
| 테스트 | 단위 `src/lib/context/*.test.ts` · `src/lib/connectors/store-context.test.ts`(gate 꺼짐 회귀), DB `tests/db/context-layer.test.ts`(PGlite) · `tests/pg/context-layer.test.ts`(같은 시나리오 + 경합, 실제 Postgres), A2 회귀 `tests/db/memory-history.scenarios.ts`(PGlite · 실제 Postgres) |

## 1. 기억 정정 규칙 (사용자 결정 2026-10-10)

> 같은 범위 · 같은 사실의 명시적 정정은 영구 이력(`superseded_at`)이다. 범위 사이의 우선은 읽을 때만, 그 범위 안에서만 적용한다.
> 프로젝트의 예외는 다른 프로젝트나 전체 기본값을 지우지 않는다. kind가 같다는 것만으로 관계없는 사실을 덮지 않는다.

- **같은 사실의 열쇠** = `memory_items.subject` (정규화한 짧은 문자열: NFKC · 소문자 · 공백 하나, `normalizeMemorySubject`). 주제가 없는 행은 아무것도 덮지 않고 덮이지도 않는다.
- **DB가 막는 것** (`memory_items_keep_history`를 바꿔 만듦): `superseded_by`는 같은 사용자 · 같은 `scope_kind` · 같은 대상(`context_id` · `action_id` · `person_id` · `agent_adapter`) · 같은 kind · 같은 (비어 있지 않은) subject의 행만 가리킨다. 행의 kind · 범위 · 대상 · subject는 고칠 수 없다. subject가 바뀌는 경우는 둘뿐이다: 주제 없던 항목을 정정할 때 `memory:<그 id>`로, 원문 글이 지워진 observed 항목의 주제를 비울 때(주제도 원문에서 온 글자다). A2의 보장은 그대로다: `superseded_at` · `revoked_at`은 한 방향, 포인터는 `on delete set null`, 새 행이 지워져도 옛 행은 살아나지 않는다.
- **쓰기** (`remember_memory_item`, `store.ts` `rememberMemory`): 같은 범위 · 같은 사실의 지금 행과 견준다(같은 사실의 쓰기는 advisory 잠금으로 한 줄. 잠그는 순서는 원문 글 지우기와 같게 인용 원문 → 기억 행(id 순) → commit 직전 범위. 글이 지워진 행은 끼지 않는다, 사용자가 그 행을 가리켜 정정할 때만 낀다). 사용자가 다시 말함(explicit)은 이긴다(= 정정). observed는 explicit을 이기지 못하고(처음부터 정정된 이력으로 들어간다) observed끼리는 늦게 읽은 쪽이 이긴다. inferred는 후보로만 들어간다. 사용자가 가리킨 항목의 정정(`p_corrects`)은 그 항목의 범위 · kind · subject를 물려받고, 주제가 없던 항목이면 `memory:<그 id>`가 주제가 된다(그 항목 자체가 사실의 열쇠). version이 다르거나 이미 정정 · 잊은 항목이면 conflict.
- **읽기** (`retrieve.ts` `effectiveMemory`): 요청 범위(전체 + 그 범위 · 할 일 · 상대 · 에이전트)에 해당하는 지금 행만 보고, 같은 사실이면 좁은 범위 수준부터 대상마다 하나를 남기고, 그 수준이 요청한 대상을 모두 덮으면 넓은 수준은 가려진다. 덮지 못하면(할 일 둘 중 하나에만 예외) 넓은 수준의 기본값도 남는다. 대상이 다른 같은 수준의 행(할 일 둘 · 상대 둘)은 둘 다 남는다. id는 대소문자를 가리지 않는다. 순서는 할 일 > 범위 > 상대 > 에이전트 > 전체(`SCOPE_RANK`, B1 결정: 범위 · 상대 · 에이전트 사이의 순서는 같은 사실이 셋 이상에 겹칠 때만 의미가 있다). 같은 범위면 explicit > observed > inferred, 그다음 늦게 말한 것. 다른 범위의 행은 처음부터 보지 않는다. 추정 · 글이 지워진 행 · 유효 구간 밖 · 읽을 수 없는 원문의 observed는 쓰지 않는다.
- **출처 · 후보 · 예약 주제**: 새로 가리키는 출처 원문은 그 사용자의 원문이어야 한다(없거나 남의 원문이면 거절, 이미 가리키던 원문이 지워진 행은 그대로 고칠 수 있다). 추정(inferred) 후보는 explicit · observed 항목을 정정하지 못한다(확인되면 explicit 새 행이 정정한다). `memory:`로 시작하는 주제는 정정만 만든다(새 기억 · 쓰기 입력은 거절).
- **A2 시나리오 (3)을 바꿨다**: 범위가 다른 새 행으로 옛 전체 행을 정정하던 시나리오는 이제 DB가 거절한다. (3)은 "범위 예외와 전체 기본값이 둘 다 지금 것이고, 읽을 때 그 범위 안에서만 예외가 이긴다. 범위를 지우면(cascade) 예외만 사라지고 전체 기본값은 정정된 적이 없어 그대로 지금 것이다"이다 (`tests/db/memory-history.scenarios.ts`, PGlite와 실제 Postgres).

## 2. 삭제 전파 (아키텍처 6.5) — 사건마다 따로

원문 글이 지워지면 `sources` 트리거(`sources_purge_context` → `purge_source_context`)가 같은 트랜잭션에서 전파한다. 기존 정리 함수(`purge_expired_source_text` · `purge_slack_sources`)는 그대로이고, 매일 cron(`/api/cron/retention`)과 Slack 끊기 경로가 그 함수를 부르면 전파가 따라온다. 지운 원문에는 조각 · observed 글 · inferred를 새로 쓰지 못한다(가드 트리거가 원문 행을 `for share`로 잠가 지우기와 한 줄로 선다: 실제 Postgres 경합 테스트). 여러 번 불러도 같다.

| 사건 | 원문 조각 (글 + 임베딩) | observed 기억 | inferred 기억 | explicit 기억 | 사람 (이름 · 계정 · 이메일) | 신원 링크 | 검색 · 묶음 | 범위 version |
|---|---|---|---|---|---|---|---|---|
| (a) 보관 기간 90일 | 지움 | 글 · 인용 · 원문에서 읽은 값 · 주제 비움, `source_purged` | 지움 | 그대로 (인용 포함, 근거 인용처럼) | 그대로 (관련자는 보관 기간에 남는다) | 그대로 | 빠짐 (조각 없음 · 글 없음) | 오름 |
| (b) Slack 끊기 · 앱 제거 (D3) | 지움 | 위와 같음 | 지움 | 글 · 값 그대로, **인용(Slack 글자)만 뺌** | 그 연결이 본 Slack 계정을 지우고 다시 계산: Slack에서만 온 이름 · 이메일 · `handles.slack`은 없어지고, 다른 출처가 보여 준 값과 사용자가 만든 사람(origin user)의 이름 · 이메일은 남는다 | 그 연결의 oauth · inferred 지움, profile · user_confirmed 남김 | 빠짐. Slack 원문은 처음부터 조각을 만들지 않고 묶음에 넣지 않는다 | 오름 |
| (c) 그 밖의 연결 끊기 | 남음 (원문은 보관 정책대로, 범위 검색도 그대로: 아래 "같은 문서") | 남음 | 남음 | 남음 | 남음 (계정 행의 `connection_id`만 빔) | 그 연결의 oauth · inferred 지움 (외래키 cascade, inferred도 그 연결의 자료에서 본 후보라서. 6.5 "그 provider 링크"), profile · user_confirmed 남김 | 남음 | — |
| (d) 접근 상실 (403 · 삭제 감지) | 남음 | 남음 | 남음 | 남음 | 남음 | 남음 | `sources.access_lost_at`(서버 `set_sources_access`가 같은 문서의 모든 revision에 함께 쓴다. revision 하나라도 잃으면 그 문서를 뺀다): 범위 검색(`match_context_chunks`) · 묶음에서 빠짐. 되찾으면(null) 다시 나옴 | 오름 (잃을 때 · 되찾을 때) |
| (e) 사용자가 기억을 지움 · 잊음 | — | 행 삭제 또는 `revoked_at` | 〃 | 〃 | — | — | 다음 묶음에서 빠짐. 이미 보낸 묶음은 회수할 수 없다: manifest(id만, 글 없음)로 어디까지 나갔는지 남긴다 | 오름 (범위 기억이면) |
| (f) 계정 삭제 | cascade | cascade | cascade | cascade | cascade (`people_handles` 포함) | cascade | — | — |
| 원문 행 삭제 | 외래키 cascade | 비움 | 지움 | 인용만 뺌 | — | — | — | 오름 |

**같은 문서(revision들)** = `source_document_ids`: 같은 사용자 · 같은 외부 id이고, 같은 연결이거나 한쪽 연결이 끊겨 비었다(수집의 "이미 넣은 원문"과 같은 기준). 연결을 끊은 뒤에도 조각 교체 · 범위 검색 · version이 같은 문서로 묶이고, 다시 연결해 들어온 새 revision도 옛 행과 묶인다. 서로 다른 두 살아 있는 연결의 같은 외부 id는 다른 문서다(연결이 다른 같은 자료의 수렴은 D0 ARCH-V04).

**서버만 쓰는 원문 열**: `raw_text_purged_at` · `raw_text_purge_reason` · `access_lost_at`은 앱 역할(authenticated · anon)이 바꾸지 못한다(`sources_server_columns_guard`). 앱은 원문 행에 owner_all 정책이 있어 다른 열은 지금처럼 고친다. 바꿀 수 있으면 지운 원문 가드 · 검색 제외를 풀 수 있기 때문이다.

**출처(provenance)를 위해 더한 것**: `people_handles` — 한 행 = 연결 · 원문이 보여 준 계정 하나(`provider`, `account_ref`, 그 계정의 이름 · 이메일, `origin` source · user, 본 `connection_id`). `(user_id, provider, account_ref)` unique가 사람 1차 키의 유일성이다(A2 열린 항목). `people.handles`와 origin이 user가 아닌 사람의 `display_name` · `emails`는 이 표에서 계산한다(트리거 `people_handles_refresh`): 출처가 사라진 값은 남지 않고, 다른 계정이 같은 이름을 보여 주면 남는다.

**한계**
- B1이 만드는 출처 사람은 계정(서비스 id 또는 주소)이 있는 관찰뿐이다 (`observe_person_handle`). 이름만 있는 관찰(회의록 화자 등)은 사람을 만들지 않는다. 이 경로 밖에서 `people`의 이름 · `handles`를 직접 쓴 행은 출처가 없어 D3가 알아보지 못한다 — B1 코드는 그렇게 쓰지 않는다.
- 한 사람이 같은 서비스에 계정이 둘이면(워크스페이스 둘) `people.handles`에는 가장 최근 계정 하나만 보인다. 계정 행은 둘 다 있다.
- 같은 Slack 계정을 두 연결이 보면 계정 행의 `connection_id`는 마지막으로 본 연결이다: 그 연결을 끊을 때 계정이 지워진다(다른 연결이 다시 보면 다시 생긴다). 반대로 먼저 본 연결을 끊으면 계정은 남는다 — 아래 "열린 질문" (c).
- 접근 상실을 감지해 `access_lost_at`을 쓰는 연동 쪽 연결은 아직 없다 (`store.ts` `setSourcesAccessLost`만 있다. Notion의 DB 단위 감지를 원문 단위로 옮기는 것은 B2 이후).
- 확인되지 않은 inferred 기억을 보관 기한 뒤 지우는 정리(아키텍처 5.3)는 아직 없다. 원문 글이 지워지면 그 원문에서 온 inferred는 지운다.
- 접근을 잃은 원문의 observed 행은 같은 사실의 비교에 그대로 낀다(행 · 주제가 남는다): 그보다 옛날에 읽은 새 관찰은 진다. 읽을 때(묶음)는 빠진다.
- `people.handles`는 계정 행에서 계산하므로, 계정 행 없이 `people.handles`에 직접 적은 값은 그 사람의 계정 행이 생기거나 바뀔 때 덮인다(사용자가 적는 계정도 `people_handles` origin user로 쓴다). 출처 사람의 이메일은 50개까지(`people.emails` CHECK).

## 3. 신원 (`identity_links`)

- 추정 링크를 연결 결과로 oauth로 올릴 때 추정 때의 공용 표시(`shared_account`)도 푼다(그 계정으로 연결했다).
- `loadIdentity`는 `MEMORY_ENABLED`일 때 링크를 합친다 (`identity-links.ts` `identityEmails`): oauth · profile · user_confirmed이고 공용이 아닌 링크의 주소만 "나"다. inferred · 공용 계정은 올리지 않고, 공용으로 표시한 주소는 연결 설정의 주소(google · gmail `settings.email`)에서도 뺀다. 프로필 · 로그인 주소는 빼지 않는다. `pipeline/identity.ts`의 `isUser` 규칙은 그대로다.
- CHECK `identity_links_connection_bound`: oauth · inferred는 연결이 있어야 하고 profile · user_confirmed는 연결이 없다. 그래서 연결을 끊으면(행 삭제) 그 연결의 링크만 지워지고 사용자가 적거나 확인한 링크는 남는다. Slack 앱 제거는 연결 행을 지우지 않으므로 `purge_slack_identity`가 지운다.
- **로그인 계정**(Sign in with Apple · Google)은 연결이 아니어서 링크로 쓰지 않는다: `loadIdentity`가 로그인 주소를 그대로 "나"로 본다. 적어야 하면 profile(연결 없음)이다.
- oauth 링크는 `saveConnection`이 쓴다(`MEMORY_ENABLED`): Slack "팀:사용자", Google · Gmail 계정 sub + 주소. Notion 연결 id는 워크스페이스라 쓰지 않는다(Notion user id 링크는 B2 이후). 같은 계정의 inferred 링크는 oauth로 올리고, profile · user_confirmed 링크는 바꾸지 않는다(사용자가 확인한 링크를 연결에 묶지 않게). 실패해도 연결은 맺는다.
- 공용 표시는 inferred 링크의 것이면 보지 않는다(확인 전 후보가 확인된 주소를 빼지 않게). 링크를 읽지 못하면 로그만 남기고 링크 없이(지금처럼) 처리를 이어 간다.

## 4. 원문 조각 · 범위 version · 묶음

- 조각: `chunkText`(1–2k자, 문단 · 줄 · 문장 경계, 원문 하나에 200조각까지) → 동의 확인(`withConsentGate`) 뒤 임베딩(원문 처리와 같은 모델 · 같은 AI 원가 한도, 64조각씩) → `replace_source_chunks` 한 번. revision의 순서는 **수집 순서**(`created_at`, `id`)다: `occurred_at`은 Notion에서 날짜 속성 · 만든 시각이라 날짜를 앞당기거나 지운 새 revision을 옛 것으로 보게 된다. 범위 검색(`match_context_chunks`)은 멤버 원문과 같은 문서의 다른 revision 조각까지 본다(조각은 최신 revision에 붙는다). 같은 문서(같은 연결 · 같은 외부 id)의 새 revision은 옛 revision 조각을 한 트랜잭션에서 바꾸고, 늦게 끝난 옛 처리는 `stale`로 아무것도 바꾸지 않는다. Slack 원문은 만들지 않는다. 실패해도 수집을 막지 않는다(로그에 원문 글 없음).
- 범위 version (`context_version`): 멤버 추가 · 빼기 · 다시 넣기 · 후보 확인, 범위 기억 추가 · 정정 · 잊기 · 삭제 · 비움, 멤버 원문의 새 revision · 글 지움 · 접근 상실에 오른다. 행 트리거는 바뀐 범위를 트랜잭션 변수(`taskforce.context_bumps`)에 모으기만 하고, commit 직전 deferred constraint trigger가 범위 id 순으로 한 번 올린다(트랜잭션마다 범위당 1). 범위 행 잠금이 트랜잭션 끝에 같은 순서로만 잡혀 기억 쓰기 · 원문 글 지우기와 교착하지 않는다. 한 문장 update라 동시에 올려도 잃지 않는다(실제 Postgres 경합 테스트). 멤버 Action의 Claim 변경은 아직 올리지 않는다(C2 코디네이터).
- 모델 후보(inferred 멤버 · inferred 기억)는 묶음에 들지 않으므로 범위 version을 올리지 않는다(거짓 stale 신호, CTX12). 후보가 확인되면 오른다.
- version 큐는 트랜잭션 변수가 아니라 내부 표 `context_version_bumps`(txid, 범위)다: 소유자 권한 함수만 쓰고 앱 · 익명은 권한이 없어, 다른 역할이 남의 범위를 큐에 넣어 올리게 할 수 없다. commit 직전에 그 트랜잭션의 행을 꺼내 지운다(되돌린 트랜잭션 · savepoint의 행은 함께 사라진다).
- **묶음을 만드는 쪽(B2 · C2)은 `context_version`을 기억 · 멤버 · 조각과 같은 스냅샷에서 읽는다**(한 트랜잭션 repeatable read, 또는 version을 먼저 읽는다). version을 나중에 읽으면 그 사이 바뀐 내용이 옛 version으로 기록돼 stale을 놓친다.
- 트리거 함수 중 cascade · 앱의 원문 쓰기로도 도는 것(범위 version · 사람 계산 · 원문 전파)은 소유자 권한(security definer)이다: Supabase Auth의 계정 삭제(`supabase_auth_admin`)가 막히지 않는다(실제 Postgres에서 그 역할로 지우는 테스트).
- 묶음 (`bundle.ts` `buildContextBundle`): `{context_id, context_version, identity:{me}, memory:[{id, kind, statement, origin, observed_at}], people:[{id, display_name, role}], materials:[{ref, source_id, version, tier: "T1", text}]}` + manifest(id만) + hash. 실행 모드 · 대상 · 예산 · 권한은 넣지 않는다(I04 · I11). 보내기(dispatch)는 D3.

## 5. 열린 질문 (정하지 않음, 구현하지 않음)

- **(a) Slack D3와 Slack 후보에서 확인한 explicit 기억.** Slack 원문에서 모델이 뽑은 inferred 후보를 사용자가 확인하면 explicit 새 행이 되고, D3는 explicit의 글 · 값을 남긴다(인용만 뺀다). 그 글은 모델이 Slack 글에서 만든 문장이다. Slack "associated Data"에 드는지(지울지) 정하려면 출처 표시(예: 확인 전 출처가 Slack이었다는 플래그)와 법무 판단(docs/legal/self-review.md 2번과 같은 방식)이 필요하다. 또 B2 화면은 인용이 빠진 자리를 "Slack 연결을 끊어 지웠어요"로 보여야 한다(Evidence와 같은 문구).
- **(b) 조각 교체와 보관 기간 정리의 교착 가능성.** `replace_source_chunks`(원문 for share → 문서 advisory → 조각 delete)와 보관 기간 정리(원문 update → 조각 delete)가 같은 문서의 여러 revision을 다른 순서로 잡으면 교착할 수 있다. Postgres가 한쪽을 되돌린다: 조각 만들기는 실패로 남고(수집은 막지 않는다) 정리는 다음 cron에서 이어진다. 다시 시도 규칙(조각 만들기 재시도)을 둘지는 B2 이후.
- **(c) 두 Slack 연결이 본 같은 사람 계정.** 계정 행은 마지막으로 본 연결만 기억한다. 같은 워크스페이스를 두 연결(다시 연결 전후 등)이 보면, 먼저 본 연결의 D3가 계정을 남기거나 나중 연결의 D3가 지운다. 연결별 출처 행(계정 × 연결)로 나눌지 정한다.

## 6. B2 이후로 남긴 것

- 대화 만들기 멱등, `client_message_id`를 사용자 메시지에만 두는 규칙 (B2 대화 v2).
- 앱의 `inbox_events` · `source_chunks` 읽기 권한(지금 A2대로 select 허용)을 둘지 정하기.
- 합친 사람(`people.merged_into`)의 대상을 지우면 합침이 풀리는 것 (사람 합치기 기능이 생길 때).
- 접근 상실 감지 연결, inferred 기억 보관 기한 정리, 멤버 Action Claim 변경의 version, Notion user id oauth 링크.
