# 연동: 원문을 자동으로 가져오기

관련 문서: [플랫폼](PLATFORMS.md) · [바이브코딩 플랜](VIBE_CODING_PLAN.md) · [진실 판정](TRUTH_RULES.md)

사용자는 원문을 직접 넣지 않는다. Notion · Gmail · Slack · GitHub에서 원문을 가져와 지금의 파이프라인(추출 → 검증 → Jev)에 넣는다.
`/lab`의 직접 입력은 엔진을 시험하는 용도다.

## 구조

```
외부 서비스 ─(OAuth 연결 · 주기 동기화)─▶ 연동 모듈 ─▶ IngestItem ─▶ ingest.ts ─▶ sources ─▶ 파이프라인
             src/lib/connectors/<서비스>/          (공통 형태)   (중복 · 안정화 · 상한)
```

- **연동 모듈은 외부 항목을 `IngestItem`(원문 · 관련자 · 원본 링크 · 외부 id · 버전)으로 바꾸기만 한다.** 파이프라인은 건드리지 않는다.
- **토큰**은 `connection_secrets`에 AES-256-GCM으로 암호화해 둔다(`CONNECTOR_TOKEN_KEY`). 이 테이블은 RLS 정책이 없어 앱 · 웹 클라이언트는 읽을 수 없고, 서버의 service role만 읽는다.
- **연결 목록**(`connections`)은 사용자가 보고 끊을 수 있다. 만들기 · 동기화 기록은 서버가 한다.
- **주기 동기화**: `GET /api/cron/sync`(`Authorization: Bearer $CRON_SECRET`). `vercel.json`에 15분마다로 걸려 있다.
  Vercel Hobby 요금제는 cron이 하루 1회로 제한되므로, 15분 주기는 Pro 요금제나 Supabase `pg_cron` + `pg_net`으로 이 주소를 부른다.
- **수동 동기화**: `POST /api/v1/connections/sync` (로그인한 사용자의 연결만, 연결마다 1분에 한 번). 연결 끊기: `DELETE /api/v1/connections/:id`.
- **동시 실행 방지**: 동기화 전에 연결을 잡는다(`sync_started_at`, 10분 뒤 자동으로 풀림). cron과 수동 동기화가 같은 연결을 겹쳐 돌리지 않고, 실행 시간 한도에 가까워지면 남은 항목은 다음 차례로 미룬다.
- **한도**: 연동 원문도 직접 입력과 같은 한도(본문 20만 자, 제목 200자, 관련자 200명)를 따른다. 사용자에게는 짧은 오류만 보이고 자세한 내용은 서버 로그에만 남는다.
- **남은 일**: 연결을 끊을 때 우리 쪽 토큰만 지운다. Notion 쪽 권한도 함께 거두는 호출(토큰 폐기 API)은 문서 확인 후 붙인다. 그 전까지는 사용자가 Notion 설정 → 연결에서 직접 해제할 수 있다.

### 넣는 규칙 (`src/lib/connectors/ingest.ts`)

| 규칙 | 이유 |
|---|---|
| 마지막 수정 후 30분이 지난 항목만 | 회의록은 회의가 끝난 뒤 AI 요약이 채워진다. 쓰는 중인 페이지를 넣지 않는다 |
| 한 항목은 한 번만 | 고쳐진 페이지를 다시 넣으면 같은 약속이 두 번 생긴다. **Phase 2(매칭) 이후** 바뀐 부분만 넣도록 바꾼다 |
| 한 번에 20건까지, 오래된 것부터 | 비용 · 실행 시간 상한. 나머지는 다음 동기화에서 |
| 30자 미만은 넣지 않음 | 빈 페이지 |

## Notion

- 읽는 범위: 사용자가 Notion 권한 화면에서 고른 페이지 · 데이터베이스만. 하위 페이지는 함께 공유된다.
- 동기화: `POST /v1/search`로 최근 수정순 페이지를 훑고, 커서(`sync_cursor.after`) 이후의 새 페이지만 `GET /v1/pages/{id}/markdown`으로 본문을 받는다. 첫 동기화는 최근 14일.
- 변환 (`notion/map.ts`, `notion/markdown.ts`): 제목 · 회의 날짜 속성 · 사람 속성(참석자) → `participants.attendees`. 본문의 AI 요약 근거 각주 · 이미지 · 태그를 걷어 내고 사람 언급은 이름으로 바꾼다. AI 회의록 블록이 있거나 제목에 회의 · meeting이 있으면 `meeting`, 아니면 `doc`.
- 녹음 전사는 가져오지 않는다 (화자 표시가 없고 길다). AI 요약과 메모만 쓴다.
- 속도 제한: 연결당 분당 180회(Business 이상 600회). 429면 `Retry-After`만큼 기다린다.
- Notion API 버전: `2026-03-11`.

### Notion 연결 만들기 (한 번)

1. https://www.notion.so/profile/integrations → **새 연결** → 유형 **Public**.
2. 필수 항목: 회사 이름, 웹사이트(`https://www.taskforcelabs.dev`), 개인정보 처리방침 · 이용약관 주소, 이메일.
3. **Redirect URIs**: `http://localhost:3000/api/connectors/notion/callback` (배포 후 배포 주소도 추가).
4. **Capabilities**: 콘텐츠 읽기만 켠다 (업데이트 · 삽입은 끔). 사용자 정보는 **이메일 포함**으로 (참석자 이메일로 사용자를 알아본다).
5. 발급된 OAuth client ID · secret을 `.env.local`의 `NOTION_CLIENT_ID`, `NOTION_CLIENT_SECRET`에 넣는다.
6. `.env.local`에 `SUPABASE_SERVICE_ROLE_KEY`(Supabase → Project Settings → API Keys)도 넣는다.
7. 마이그레이션 `20260928000000_connections.sql`까지 적용한 뒤 `/lab` → **Notion 연결** → 회의록 데이터베이스를 고른다 → **지금 동기화**.

## 다음 연동

| 서비스 | 가져올 것 | 주의 |
|---|---|---|
| Gmail (+ Calendar) | 내가 보내거나 받은 스레드, 회의 참석자 | 메일 읽기 권한은 Google 심사 대상(테스트 사용자 100명까지는 심사 없이 가능). 뉴스레터 · 알림 메일 거르기 |
| GitHub | 나에게 배정된 이슈, 리뷰 요청, 나를 언급한 댓글 | 배정 · 리뷰 요청은 구조화된 데이터라 추출 없이 바로 할 일로 만들 수 있다 |
| Slack | 나에게 온 DM, 나를 언급한 글, 내가 쓴 약속 | 글이 많고 짧아 Jev 사전 필터가 필요. 비공개 배포 앱의 조회 속도 제한 확인 필요 |

두 번째 연동을 켜기 전에 Phase 2(매칭 · 병합)를 먼저 한다. 같은 약속이 회의록 · 메일 · 메시지에 연달아 나오기 때문이다.
