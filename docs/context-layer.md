# 맥락층 (0.2.0 B1) — 결정 기록과 위치

0.2.0 구현 계획 B1. 기억 · 범위 · 사람 · 신원 링크 · 원문 조각 · 맥락 묶음을 서버 코드와 DB 규칙으로 붙였다. 보이는 행동은 없다:
gate `MEMORY_ENABLED` · `SOURCE_CHUNKS_ENABLED`(`src/lib/flags.ts`)가 기본 꺼짐이고, 꺼져 있으면 서버는 새 표를 읽지도 쓰지도 않고 임베딩을 부르지 않는다.
대화 v2 route는 B2가 붙였다(7장, gate `CONVERSATIONS_V2_ENABLED` 기본 꺼짐). 기억 확인 · 정정 · 잊기 · 범위 옮기기 route와 대화 범위 바꾸기는 B3 PR1이 붙였다(8장, gate `MEMORY_ENABLED` · `CONVERSATIONS_V2_ENABLED` 기본 꺼짐).

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
| (d) 접근 상실 (403 · 삭제 감지) | 남음 | 남음 | 남음 | 남음 | 남음 | 남음 | `sources.access_lost_at`(서버 `set_sources_access`가 같은 문서의 모든 revision에 함께 쓴다. revision 하나라도 잃으면 그 문서를 뺀다. 늦게 들어온 새 revision은 되찾음이 아니다): 범위 검색(`match_context_chunks`)과 기억 · 묶음(`context_source_states` → `loadSourceStates`)에서 같은 기준으로 빠짐. 되찾으면(null) 다시 나옴 | 오름 (잃을 때 · 되찾을 때) |
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
- 공용 표시는 inferred 링크의 것이면 보지 않는다(확인 전 후보가 확인된 주소를 빼지 않게). 링크를 읽지 못하면 던진다(넓히지 않는다): 링크 없이 이어 가면 공용으로 확인한 계정의 제외가 사라져 그 주소가 다시 "나"가 된다. 수집은 그 원문을 처리하지 않고 대기로 남기고, 재처리(`src/lib/sources/retry.ts`) · 다음 동기화가 다시 읽는다. 조각은 신원과 상관없어 그때 바로 만든다(재처리 경로는 조각을 만들지 않는다). 이름만 필요한 곳(실행 초안의 이름 · Calendar 일정 잇기)은 `loadUserName`(프로필 · 로그인 계정만)을 써서 링크 읽기 실패와 상관없다.

## 4. 원문 조각 · 범위 version · 묶음

- 조각: `chunkText`(1–2k자, 문단 · 줄 · 문장 경계, 원문 하나에 200조각까지) → 동의 확인(`withConsentGate`) 뒤 임베딩(원문 처리와 같은 모델 · 같은 AI 원가 한도, 64조각씩) → `replace_source_chunks` 한 번. revision의 순서는 **수집 순서**(`created_at`, `id`)다: `occurred_at`은 Notion에서 날짜 속성 · 만든 시각이라 날짜를 앞당기거나 지운 새 revision을 옛 것으로 보게 된다. 범위 검색(`match_context_chunks`)은 멤버 원문과 같은 문서의 다른 revision 조각까지 본다(조각은 최신 revision에 붙는다). 같은 문서(같은 연결 · 같은 외부 id)의 새 revision은 옛 revision 조각을 한 트랜잭션에서 바꾸고, 늦게 끝난 옛 처리는 `stale`로 아무것도 바꾸지 않는다. Slack 원문은 만들지 않는다. 실패해도 수집을 막지 않는다(로그에 원문 글 없음).
- 범위 version (`context_version`): 멤버 추가 · 빼기 · 다시 넣기 · 후보 확인, 범위 기억 추가 · 정정 · 잊기 · 삭제 · 비움, 멤버 원문의 새 revision · 글 지움 · 접근 상실 · 되찾음, 범위의 지금 쓰는 observed 기억이 인용한 원문(멤버가 아니어도)의 글 지움 · 접근 상실 · 되찾음(새 revision은 인용한 기억을 바꾸지 않아 올리지 않는다), 멤버 문서의 조각이 실제로 바뀔 때(`replace_source_chunks`가 `replaced`일 때. 글 · 순번 · revision · 개수가 같으면 `unchanged`로 바꾸지도 올리지도 않고 저장된 임베딩을 둔다: 다시 임베딩한 값은 공급자에 따라 조금씩 달라 임베딩으로 견주지 않는다. 같은 글도 임베딩 호출은 한다 — 비용을 줄이는 미리 보기는 B2 이후)에 오른다. 원문을 넣은 뒤 조각 · 임베딩이 비동기로 늦게 붙어도 그 사이에 만든 묶음이 stale로 잡힌다. 행 트리거는 바뀐 범위를 트랜잭션 변수(`taskforce.context_bumps`)에 모으기만 하고, commit 직전 deferred constraint trigger가 범위 id 순으로 한 번 올린다(트랜잭션마다 범위당 1). 범위 행 잠금이 트랜잭션 끝에 같은 순서로만 잡혀 기억 쓰기 · 원문 글 지우기와 교착하지 않는다. 한 문장 update라 동시에 올려도 잃지 않는다(실제 Postgres 경합 테스트). 멤버 Action의 Claim 변경은 아직 올리지 않는다(C2 코디네이터).
- 모델 후보(inferred 멤버 · inferred 기억)는 묶음에 들지 않으므로 범위 version을 올리지 않는다(거짓 stale 신호, CTX12). 후보가 확인되면 오른다.
- version 큐는 트랜잭션 변수가 아니라 내부 표 `context_version_bumps`(txid, 범위)다: 소유자 권한 함수만 쓰고 앱 · 익명은 권한이 없어, 다른 역할이 남의 범위를 큐에 넣어 올리게 할 수 없다. 큐 표에 걸린 deferred constraint trigger가 commit 직전에 그 트랜잭션의 행을 꺼내 지운다(큐에 넣는 길이 어디든 비워진다. 되돌린 트랜잭션 · savepoint의 행은 함께 사라진다).
- **묶음을 만드는 쪽(B2 · C2)은 `context_version`을 기억 · 멤버 · 조각과 같은 스냅샷에서 읽는다**(한 트랜잭션 repeatable read, 또는 version을 먼저 읽는다). version을 나중에 읽으면 그 사이 바뀐 내용이 옛 version으로 기록돼 stale을 놓친다.
- 트리거 함수 중 cascade · 앱의 원문 쓰기로도 도는 것(범위 version · 사람 계산 · 원문 전파)은 소유자 권한(security definer)이다: Supabase Auth의 계정 삭제(`supabase_auth_admin`)가 막히지 않는다(실제 Postgres에서 그 역할로 지우는 테스트).
- 묶음 (`bundle.ts` `buildContextBundle`): `{context_id, context_version, identity:{me}, memory:[{id, kind, statement, origin, observed_at}], people:[{id, display_name, role}], materials:[{ref, source_id, version, tier: "T1", text}]}` + manifest(id만) + hash. 실행 모드 · 대상 · 예산 · 권한은 넣지 않는다(I04 · I11). 보내기(dispatch)는 D3.

## 5. 열린 질문 (정하지 않음, 구현하지 않음)

- **(a) Slack D3와 Slack 후보에서 확인한 explicit 기억.** Slack 원문에서 모델이 뽑은 inferred 후보를 사용자가 확인하면 explicit 새 행이 되고, D3는 explicit의 글 · 값을 남긴다(인용만 뺀다). 그 글은 모델이 Slack 글에서 만든 문장이다. Slack "associated Data"에 드는지(지울지) 정하려면 출처 표시(예: 확인 전 출처가 Slack이었다는 플래그)와 법무 판단(docs/legal/self-review.md 2번과 같은 방식)이 필요하다. 또 B2 화면은 인용이 빠진 자리를 "Slack 연결을 끊어 지웠어요"로 보여야 한다(Evidence와 같은 문구).
- **(b) 조각 교체와 보관 기간 정리의 교착 가능성.** `replace_source_chunks`(원문 for share → 문서 advisory → 조각 delete)와 보관 기간 정리(원문 update → 조각 delete)가 같은 문서의 여러 revision을 다른 순서로 잡으면 교착할 수 있다. Postgres가 한쪽을 되돌린다: 조각 만들기는 실패로 남고(수집은 막지 않는다) 정리는 다음 cron에서 이어진다. 다시 시도 규칙(조각 만들기 재시도)을 둘지는 B2 이후.
- **(c) 두 Slack 연결이 본 같은 사람 계정.** 계정 행은 마지막으로 본 연결만 기억한다. 같은 워크스페이스를 두 연결(다시 연결 전후 등)이 보면, 먼저 본 연결의 D3가 계정을 남기거나 나중 연결의 D3가 지운다. 연결별 출처 행(계정 × 연결)로 나눌지 정한다.

- **(d) 같은 문서 판정은 연결을 지운 뒤 추이적이지 않다.** `source_document_ids`는 "같은 연결이거나 한쪽 연결이 비었다"로 묶는다. 연결 X를 지워 X의 revision들이 연결 없음이 된 뒤, 같은 외부 id를 가진 두 살아 있는 연결 Y · Z의 revision은 각각 X의 옛 revision과는 묶이지만 서로는 묶이지 않는다(A~B, B~C인데 A≁C). 그 문서의 조각 교체 · 접근 상실 · 검색이 어느 revision에서 출발하느냐에 따라 묶음이 달라질 수 있다. 연결이 다른 같은 자료의 수렴(D0 ARCH-V04)과 함께 정한다.
- **(e) loadIdentity는 프로필 · 연결 설정을 읽지 못하면 조용히 좁아진다(B1 전부터).** 프로필 · `connections` 읽기는 오류를 던지지 않고 빈 값으로 이어 가, "나"의 이름 · 별칭 · 주소가 줄어든 채 처리된다(신원 링크 읽기 실패는 B1에서 던지도록 했다). 좁아지는 쪽은 남의 요청을 내 것으로 넓히지 않지만, 내 발언을 남의 것으로 볼 수 있다. 같은 방식(던지고 재처리)으로 맞출지 정한다.

## 6. B2 이후로 남긴 것

- 대화 만들기 멱등, `client_message_id`를 사용자 메시지에만 두는 규칙 (B2 대화 v2).
- 앱의 `inbox_events` · `source_chunks` 읽기 권한(지금 A2대로 select 허용)을 둘지 정하기.
- 합친 사람(`people.merged_into`)의 대상을 지우면 합침이 풀리는 것 (사람 합치기 기능이 생길 때).
- 접근 상실 감지 연결, inferred 기억 보관 기한 정리, 멤버 Action Claim 변경의 version, Notion user id oauth 링크.

## 7. 대화 v2 (B2)가 이 층을 쓰는 방식 · 처리한 것 · 남긴 것

B2(대화 v2, gate `CONVERSATIONS_V2_ENABLED`, 기본 꺼짐)는 이 층을 **읽고**, 기억은 `remember_memory_item`으로만 **쓴다**. 위치와 정식 경로는 [FEATURE_MAP](FEATURE_MAP.md) 2장 "대화 v2" · 3-7.

- **읽기 (상담 근거):** `src/lib/conversation/store.ts` `loadConsultContext`가 범위 version을 먼저 읽고(4장 끝 규칙), `loadScopeMemory` + `buildContextBundle`로 기억 · 조각을 고른다: 요청 범위(대화 범위 + 전체)의 지금 explicit · observed만, 추정 · 다른 범위 · 정정 · 잊음 · 유효 구간 밖 · 접근을 잃었거나 글이 지워졌거나 Slack에서 온 원문의 observed 기억 · 조각은 빠진다. 할 일 근거 원문도 문서 단위 접근 상실(`context_source_states`)이면 넣지 않는다. 답에는 본 것의 id와 그때의 version만 남긴다(`conversation_messages.content.used`, 글 없음).
- **쓰기 (기억):** 사용자 메시지에서 나온 explicit만, 인용을 그 메시지와 기계로 대조하고 Jev 판정(인용이 문장을 그대로 말하는가, 정정이면 같은 대상의 이전 기억을 바꾸는가, "기억해 둘까요?"에 대한 답이면 동의했는가)을 통과한 것만(`src/lib/conversation/memory.ts`). 아키텍처 7.3 J7(기계 검증만)보다 보수적이고, 기억을 쓰는 turn은 모델 호출이 3번(J1 · J2 · 판정)이다. 판정이 실패하면 기억만 버리고 답은 남긴다. 가리킨 정정 대상은 kind(와 주제)가 같아야 한다. 기억 쓰기는 의도 확신 ≥ 0.8에서만(상담 중 함께 말한 사실도). 출처는 `source_ref.message_id` + 인용(원문 id가 아니다: Slack D3 · 보관 기간 전파와 상관없다). 범위는 대화 범위(범위가 없으면 전체). 같은 범위 기억의 정정은 그 행을 `p_corrects`로(version 확인), 더 넓은 범위(전체) 기억의 정정은 전체 행을 두고 대화 범위에 같은 사실(kind + subject)의 새 행을 쓴다 — 읽을 때 그 범위 안에서만 이긴다(1장 규칙 그대로). 모델이 만든 인용 · 기억은 저장하지 않고 inferred로도 쓰지 않는다.
- **Slack D3 · 원문 삭제:** 답 내용(`conversation_messages.content.citations`)의 인용 · 제목은 가드 `conversation_messages_citation_guard`가 쓸 때마다 원문의 지금 상태로 고친다: Slack 끊기 · 앱 제거로 지운 원문(`raw_text_purge_reason = 'disconnected'`)이면 근거 인용과 같은 자리 표시 · `Slack`, 원문 행이 없으면 인용 · 제목 · 링크를 비운다. 가드는 원문 행을 `for share`로 잠가 원문 글 지우기와 한 줄로 서고(B1 지운 원문 가드와 같은 방식), 원문 쪽 트리거 `sources_refresh_conversation_citations`가 끊기 · 삭제 때 그 원문을 인용한 답을 다시 쓴다(인용 원문 id GIN 인덱스로 찾는다). `conversation_finish_turn`은 답이 인용한 원문을 맨 먼저(id 순) 잠근다. 보관 기간 정리 · 접근 상실은 근거 인용처럼 남긴다.
- **Slack D3 범위 (출시 gate의 제품 · 법무 결정, 이번에 정하지 않음):** 답 글(text · segments)과 다음 turn 창에 실리는 앞 답에는 Slack에서 온 글자(모델이 옮긴 문장)가 남을 수 있다. 선택지: 끊을 때 Slack 인용이 든 답의 T1 구간을 비우기 / 프롬프트에 원문을 그대로 옮기지 말라고 두기 / 지금처럼 유지(할 일 제목처럼 모델 요약은 남김).
- **B1 코드에 더한 것 (additive):** `loadScopeMemory`가 `version`도 읽는다(정정의 `p_expected_version`), `searchContextChunks`가 마감(`options.deadline`)을 받는다(사용자가 기다리는 요청).
- **6장에서 처리:** 대화 만들기 멱등(앱이 정한 대화 id, 같은 사용자의 같은 id면 그 대화) · `client_message_id`는 사용자 메시지에만(답은 `reply_to`로 잇고 사용자 메시지 하나에 답 하나).
- **5장 열린 질문 — B2가 정하지 않았다 (그대로 열림):**
  - (a) Slack 후보에서 확인한 explicit 기억: B2는 추정 확인(confirm) route를 만들지 않았고, 대화에서 쓰는 기억은 사용자 메시지 출처뿐이라 Slack 글자를 기억 글로 옮기지 않는다. 확인 경로를 붙일 때(B3 Remembered · 기억 편집 API) 정한다.
  - (b) 조각 교체와 보관 기간 정리의 교착 · (c) 두 Slack 연결이 본 같은 계정 · (d) 같은 문서 판정의 추이성 · (e) `loadIdentity`가 조용히 좁아짐: B2는 이 경로를 바꾸지 않는다(신원을 쓰지 않고 조각을 만들지 않는다).
- **6장에서 남긴 것 (B2 밖):** 앱의 `inbox_events` · `source_chunks` 읽기 권한, 접근 상실 감지 연결, inferred 기억 보관 기한 정리, 멤버 Action Claim 변경의 범위 version, Notion user id oauth 링크.
- **B2 독립 리뷰에서 기록만 한 것 (고치지 않음):** 다른 대화의 늦은 응답이 새 정정을 덮을 수 있다(같은 대화는 stale로 막고, 보여 준 같은 사실은 version으로 막지만 B1의 "explicit은 늘 이긴다" 규칙상 창 밖 · 다른 대화의 재진술은 version 없이 정정된다) · 채택 경합 뒤 재시도에는 처리 표시가 없어 같은 제출을 겹쳐 보내면 모델 비용만 두 번 든다 · 별개의 "응" 두 개가 겹치면 Action 0(보수적) · 열린 할 일 `limit(500)`은 정렬 없이 읽은 뒤 순서를 매기고 제안 중복 확인은 보여 준 50 + 최근 끝낸 20개 범위 · 채택 note 원문 = 제안 제목, 링크 = "응" 메시지(제품 확인 필요) · 처리 표시 소유 토큰 없음 · 채택 순간 그 사이 추출된 같은 Action을 다시 찾지 않음 · T1 강등은 기록이 하나도 없을 때만(제품 기준 필요) · 보관(archived) 대화도 메시지를 받는다(보관 route가 아직 없음).
- **Codex 리뷰에서 기록만 한 것 (조건부 우려 · 정책 검토):** 처리 표시가 시간으로 풀려 다른 요청이 다시 처리를 잡은 뒤 옛 요청의 답 쓰기가 늦게 와도 받아들여진다(시도 토큰 없음, 실제 SQL로 재현됨). route 실행 한도 60초 < 처리 표시 75초라 배포 환경에서는 옛 요청이 먼저 끝나야 하지만 보장은 플랫폼 실행 한도에 기댄다. 같은 제출이라 쓰기는 하나(answered)이고 글 · 대상이 같다. / 대화 창은 저장된 앞 답의 글을 그대로 모델에 다시 준다: 새 조회에서 접근 상실 · 기억 gate로 거른 자료에서 나온 문장이 앞 답에 남아 계속 쓰일 수 있다 — Slack D3 범위(위)와 함께 출시 gate 정책 검토.
- **재검토(APPROVE)에서 기록만 한 것:** 새 교착 가능성(추정 · 드묾): 한 답이 같은 끊기의 Slack 원문 둘 이상을 인용했거나 Slack 연결 둘을 동시에 끊으면 끊기 RPC가 40P01로 되돌려질 수 있다 — 호출부 재시도 또는 끊기 때 원문 id 순 선잠금이 후속 선택지 · 대명사 정정(후보 주제 없음)은 kind 일치 + Jev `previous_statement` 판정으로만 막는다(설계상 수용) · 동시에 같은 새 제출 둘이 오면 한도를 두 번 센다(비용만) · `selected`가 null인 행(운영 미적용이라 없음)은 빈 객체(`{}`)로 견주므로, 그런 행에 같은 client_message_id로 다시 보내면 서버가 늘 빈 목록 셋(`{action_ids: [], run_ids: [], artifact_ids: []}`)을 보내 `refs_mismatch`(409)가 된다 · 처음 고른 대상이 그 사이 지워진 같은 제출의 재전송은 404(의도, 앱은 RLS로 답을 읽을 수 있다).
- **B2가 새로 남긴 것:** 기억 편집 · 잊기 · 추정 확인 route(계약 `memoryEditRequestSchema` 등은 있음, B3 Remembered와 함께 → **B3 PR1에서 처리**, 8장), 대화의 범위 추정(첫 발화에 프로젝트 이름이 없을 때 `inferred` 멤버십 — 아키텍처 11장 ①, S3b), 대화 글 보관 기한과 정리(`text` · `content`를 함께 비움, 처리방침 V08), `last_read_at` 쓰기, 기억 · 재설명 지표 이벤트(ARCH26 `memory_corrected` 등, 지표 묶음 I).

## 8. 기억 쓰기 (B3 PR1) — 처리한 것 · 보류한 정책 · 남은 결정

B3 PR1(서버)은 Remembered(Settings › Account)와 대화 헤더 ProjectLink가 쓰는 **쓰기**만 붙인다. 읽기(목록 · 상세 · 대화 복원)는 앱이 Supabase에서 직접 한다(RLS select, 새 읽기 route 없음). 새 판정 엔진은 없다:
확인 · 정정은 B1 `remember_memory_item`(`p_corrects` + `p_expected_version`)이고, 잊기 · 옮기기만 한 트랜잭션이 필요해 새 SQL 두 개(`20261107000000_memory_writes.sql`)를 더했다. AI를 부르지 않고 run · Action · 정책 · 승인을 만들지 않는다(I04 · I14: `tests/db/memory-writes.scenarios.ts`가 실행 · 권한 · Action 표의 행 수가 그대로임을 확인한다). 위치는 [FEATURE_MAP](FEATURE_MAP.md) 3-7.

| route | 요청 | 동작 | 응답 |
|---|---|---|---|
| `POST /api/v2/memory/{id}/confirm` | `{ expected_version }` | 추정(inferred) 후보만. 새 explicit 행이 후보를 정정한다(같은 범위 · kind · subject 상속, 글 · 값 · 유효 구간 · 출처 그대로, 후보는 `superseded_*` + version + 1) | `200 { item }` 새 지금 행 |
| `PATCH /api/v2/memory/{id}` | `{ expected_version, statement, value?, valid_from?, valid_until? }` | 같은 사실 · 같은 범위 정정: 새 explicit 행 + 옛 행 정정된 이력. 요청에 없는 값은 옛 행에서 이어받는다. 비우려면 `value`는 `{}`(`null`은 400: `memoryEditRequestSchema`의 value는 nullable이 아니다), `valid_from` · `valid_until`만 `null` = 비움. **출처(source_ref)는 잇지 않는다**(새 글은 사용자의 것, 옛 행이 이력으로 출처를 남긴다). 범위는 바꾸지 않는다 | `200 { item }` |
| `POST /api/v2/memory/{id}/forget` | `{ expected_version }` | `revoked_at`(되돌릴 수 없음) + version + 1. 범위 기억이면 범위 version이 기존 트리거로 정확히 + 1. 이미 잊은 항목에 다시 보내면 200(멱등). 이미 보낸 묶음은 회수하지 않는다 | `200 { item }` 잊은 그 행 |
| `POST /api/v2/memory/{id}/scope` | `{ expected_version, scope_kind: "global" \| "context", context_id: uuid \| null }` | explicit 항목만 전체 ↔ 내 active 범위. 같은 kind · subject · 글 · 값 · 유효 구간 · 말한 시각으로 대상 범위에 새 explicit 행(`value.moved_from` = 옮긴 출처 id) + 옛 행 `revoked_at`, 한 트랜잭션. **정정 이력(`superseded_*`)이 아니다**. 대상 범위에 같은 사실의 지금 행이 있으면 B1 규칙대로 그 범위 안에서만 정정된다(전체 · 다른 범위의 같은 사실은 그대로). 이미 그 범위면 쓰지 않고 그 행을 돌려준다 | `200 { item }` 새 지금 행 |
| `PATCH /api/v2/conversations/{id}` | `{ context_id: uuid \| null }` | 사용자가 ProjectLink에서 명시적으로 고른 범위(null = All work). 내 대화 · 내 active 범위만. 멤버십 · 기억 · 범위 version을 쓰지 않는다(자동 범위 추정은 S3b) | `200 { conversation }` |

- **공통:** gate 꺼짐 = 404(인증 · DB 0). 인증은 Bearer + 쿠키(쿠키 쓰기는 CSRF 확인, PATCH 포함). 남의 · 없는 id(기억 · 대화 · 범위) = 404로 존재를 드러내지 않는다. version이 다르거나 이미 정정 · 잊은 항목 = 409 `conflict`. 정책 보류 = 409 `confirm_unavailable` / `scope_unavailable`(v1 `apiErrorCodeSchema`는 동결이라 v2 코드 `apiErrorV2Schema`를 따로 둔다; 모양 `{ error: { code, message } }`는 같다). 잘못된 본문 = 400, 요청 글은 로그에 남기지 않는다.
- **재시도 · 409:** 잊기만 같은 요청의 재전송이 200이다(이미 잊은 항목은 요청 version이 행의 version 이하이면 200, 큰 값이면 conflict). 이 200은 **"이 항목은 지금 기억이 아니다"만** 뜻한다: 다른 기기의 Forget · Move(옮김)로 이미 잊힌 항목에 보낸 forget도 200이다. 확인 · 정정 · 옮기기는 재전송하면 이미 정정 · 잊은 옛 행이라 409 `conflict`인데, **409는 "내 요청이 이미 적용됨"과 "다른 기기 · 다른 요청이 먼저 바꿈"을 구분하지 못한다.** 옛 행의 `superseded_by` · `revoked_at` · `value.moved_from` 후속 행은 다른 기기의 Edit · Move · Forget도 똑같이 만들어 내 요청 성공의 증거가 아니다(반례를 회귀로 고정: `tests/db/memory-writes.scenarios.ts` "409는 성공의 증거가 아니다"). 그래서 앱은 409를 성공으로 승격하지 않고, 그 id와 후속 행을 RLS로 다시 읽어 지금 상태를 보여 주며 "충돌 · 다시 확인"으로 둔다(사용자가 지금 값을 보고 다시 할지 정한다). 요청 결과를 식별할 근거(예: 200 응답의 새 행 id)가 없으면 성공으로 표시하지 않는다. 새 멱등성 저장소는 두지 않았다(서버의 version 확인은 그대로 맞다).
- **늦은 응답 · 동시 수정:** 모든 쓰기가 DB의 version 확인(`remember_memory_item`의 `p_expected_version`, `forget_memory_item` · `move_memory_item`의 행 잠금 뒤 확인)이라, 낡은 화면의 요청이나 B2 대화의 늦은 정정은 conflict가 되고 잊은 · 옮긴 기억을 살리지 못한다. 잠그는 순서는 B1과 같다(같은 사실의 잠금 → 인용 원문 → 기억 행 → commit 직전 범위). 옮기기는 옛 범위 · 새 범위의 같은 사실 잠금을 키 순서로 잡아 반대 방향의 옮기기와 교착하지 않는다(실제 Postgres 경합 테스트).
- **삭제 안전성:** 새 행은 지운 원문을 가리킬 수 없다. 옮기기는 원문 행이 지워졌으면 새 행에서 그 `source_id` · 인용을 뺀다(B1 지운 원문 가드), Slack 끊기로 인용이 빠진 원문은 인용 없이 잇는다. 옮기기와 Slack 끊기가 겹쳐도 새 행에 Slack 인용이 남지 않는다(끊기가 먼저면 옮기기는 version이 올라 conflict, 옮기기가 먼저면 끊기 전파가 새 행의 인용도 뺀다).
- **앱이 읽는 것 (RLS):** `memory_items`(id · kind · scope_kind · context_id · action_id · person_id · agent_adapter · subject · statement · value · origin · source_ref · observed_at · valid_from · valid_until · superseded_by · superseded_at · revoked_at · confidence · source_purged · version · created_at · updated_at). **지금 기억 = `superseded_at is null and revoked_at is null`**(범위 사이의 우선은 서버 판정이라 목록에서 흉내 내지 않는다). 옛 답의 `refs.memory_item_ids`가 가리키는 행은 정정 · 잊음으로 지금 기억이 아닐 수 있다: 상태를 그대로 보인다.

### 정책 보류 (활성화하지 않음) — 근거 · 보수안 · 남은 결정

네 경로 모두 코드에 막아 두었고(409 이유 코드), 테스트가 막혔음을 고정한다. 인계(B3)의 기준: 결정이 필요한 출처 기반 확인 경로는 활성화하지 않는다.

- **(a) Slack 원문에서 온 후보(inferred)의 확인 — 5장 (a), D3.** 근거: 확인하면 explicit 새 행이 되고, D3는 explicit의 글 · 값을 남긴다(인용만 뺀다). 그 글은 모델이 Slack 글에서 만든 문장이라 Slack "associated Data"에 드는지(지워야 하는지)는 법무 판단(docs/legal/self-review.md 2번과 같은 방식)이 필요하다. 보수안: `confirm_unavailable`(앱은 Confirm을 감춘다). **같은 이유로** Slack에서 온 observed · inferred 항목을 글자만 그대로(대소문자 · 공백만 달리) Edit하는 것도 막고(확인의 우회), 새 글을 쓰면 옛 행의 구조화 값 · 유효 구간도 잇지 않는다. 새 글을 쓰는 Edit와 Forget은 허용한다(사용자가 직접 쓴 글). "Slack 출처"의 기준은 맥락층의 기존 `isSlackDerived`다(연결이 Slack · Slack 끊기로 지운 원문 · 링크가 Slack). 남은 결정: Slack 출처 표시(확인 전 출처가 Slack이었다는 플래그)를 explicit 행에 남기고 D3가 지울지, 아니면 계속 막을지. 새 글을 쓴 Edit의 `subject`(사실의 열쇠, 후보의 짧은 정규화 문자열)는 후보에서 상속된다 — Slack 글자에서 나온 단어일 수 있다(정책 결정에 함께). 앱의 B2 답이 Slack 인용을 담았을 때 그 답의 글에서 만든 후보(`source_ref.message_id`)는 이 검사가 Slack으로 알아보지 못한다(Slack D3 범위 결정과 함께, 7장).
- **(b) observed · inferred의 범위 변경.** 근거: 자료에서 읽은 사실(observed)이나 모델 추정(inferred)의 범위는 그 자료 · 추정이 정한다. 사용자가 범위를 바꾸면 출처가 말하지 않은 범위로 자료 기반 사실이 번진다. 보수안: `scope_unavailable`(앱은 explicit만 범위를 바꾸게 한다; 바꾸려면 Edit로 explicit 새 글을 쓴다). 같은 이유로 **할 일 · 상대 · 에이전트 범위의 explicit 기억도 옮기지 않는다**(좁은 대상이 전체 · 프로젝트로 넓어진다). 남은 결정: 그 범위들을 Remembered에서 바꾸게 할지, observed의 범위 변경을 "새 explicit 사실로 확정"으로 볼지.
- **(c) 글이 지워진(`source_purged`) 항목의 확인.** 근거: 확인할 글이 없다. (이 상태는 observed에서만 생기고, 확인은 inferred만 받으므로 `confirm_unavailable`로 같이 막힌다. 원문이 지워지면 그 원문의 inferred 후보는 지워져 404다.) 보수안: 확인 불가. Edit(사용자가 새 글을 씀, 새 행의 주제는 `memory:<옛 id>`)와 Forget은 허용. 남은 결정 없음(UI 문구는 B3 PR2).
- **(d) 접근을 잃은(`access_lost_at`, 문서 단위) 원문에서 온 후보의 확인 — Codex 출처 경계 검토(2026-10-11)로 추가.** 근거: 접근 상실 원문은 새 검색 · 묶음에서 빠지는데(아키텍처 6.5 · ARCH08, 2장 (d)), 확인된 explicit은 B1 규칙대로 접근 상실 뒤에도 묶음에 든다. 그래서 접근을 잃은 원문에서 만든 후보를 확인하면 새 묶음의 기억이 0 → 1로 늘어 "빠졌어야 할 출처의 문장"이 승격된다(Codex 진단으로 재현). 처음에는 "남은 결정"으로 적고 허용했으나, 결정이 필요한 출처 기반 확인 경로를 활성화하지 말라는 인계와 어긋나 바로잡았다. 보수안: `confirm_unavailable`(문서 단위: 같은 문서의 revision 하나라도 잃었으면 잃은 문서이고, 잃은 뒤 들어온 새 revision도 마찬가지; B1 `loadSourceStates.accessLost`를 그대로 쓴다). (a)와 같은 방식으로 그 출처의 observed · inferred를 글자 그대로(대소문자 · 공백만 달리) Edit해 같은 승격을 하는 우회도 막고, 새 글 Edit · Forget은 허용한다(새 글 Edit는 옛 값 · 유효 구간 · 출처를 잇지 않는다). **바꾸지 않은 것:** 원래 explicit 사용자 기억(접근 상실 전에 확인한 것 포함)과 사용자가 새로 쓴 정정의 B1 보존 규칙. 복원(`access_lost_at` null)하면 다시 확인할 수 있다. 출처 상태를 읽지 못하면 던지고(쓰기 0), 상태가 비어 돌아와도 막는다(fail-closed). 출처 id가 없는 후보(대화 메시지 · 산출물 · 사건 출처)는 이 검사 대상이 아니다. 남은 결정: 접근을 잃은 원문의 후보를 제품이 확인하게 둘지(그동안 사용자는 새 글을 써서 저장할 수 있다: Edit). **동시성의 보장 범위:** 출처 상태 읽기는 쓰기 트랜잭션 밖이다(확인은 B1 `remember_memory_item`을 그대로 부르며 그 함수는 건드리지 않는다). 상실이 먼저 커밋되면 보류, 확인이 먼저 끝나면 확인된 explicit은 B1대로 보존된다. 읽은 직후 쓰기 전에 상실이 커밋되면 확인이 통과하는데, 그 결과는 "상실 직전에 끝난 확인"과 구별되지 않고 창은 두 문장 사이(밀리초)이며 접근 상실을 쓰는 연동 쪽은 아직 없다 (알려진 한계를 `tests/db/memory-writes.scenarios.ts`가 고정한다). 트랜잭션 안 가드는 B1 함수를 감싸는 새 SQL이 필요해 하지 않았다.

### 정책 밖에서 이번에 정한 것 (되돌리려면 근거 필요)

- **잊은 항목의 version.** 잊은 뒤 원문 삭제 전파가 version을 더 올릴 수 있어(observed 비움 등), 이미 잊은 항목의 재시도는 요청 version이 행 version 이하이면 성공으로 본다(같은 요청의 재전송 구별).
- **gate 꺼짐 중에는 잊기도 404.** 계약대로다(꺼진 동안 기억은 읽히지도 쓰이지도 않는다). 켜기 전에 사용자가 기억을 지울 수 있어야 하는지는 출시 gate 결정.
- **보관된 범위로는 기억을 옮기거나 대화 범위를 고를 수 없다(404).** active 범위만.
- **한도 · 크기.** 기억 쓰기에는 요청 횟수 한도가 없다(AI 비용 0). `value`(구조화 값)의 크기 상한은 B1 계약 그대로 없다(플랫폼 본문 한도에 기댄다): 남은 것.

### 남긴 것 (B3 PR1 밖)

- 기억 · 재설명 지표 이벤트(ARCH26 `memory_corrected` 등, 지표 묶음 I): 이벤트 표가 없어 기록하지 않았다. "측정할 수 없으면 출시하지 않는다"의 대상으로 남는다.
- 대화 글 보관 기한(V08)과 B3 대화 범위 바꾸기의 관계 없음(범위는 글이 아니다).
- 대화 범위를 바꿔도 이미 진행 중인 답은 시작할 때의 범위를 쓴다(답의 `content.used.context_id`가 그때의 범위를 남긴다).
- Mac 쪽(Chats · Remembered 화면, DTO)은 PR2.
