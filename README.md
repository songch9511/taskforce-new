# Taskforce

AI 프로젝트 매니저 — 회의록·메시지·메일에서 내가 약속한 Action을 자동으로 추적하고, 맥락과 함께 "지금 할 일"을 보여줍니다.

사용자용 앱은 iOS · macOS 네이티브이고, 이 저장소의 Next.js는 서버 API와 내부 도구(시험대 · eval · 지표)입니다.

- [PRD](docs/PRD.md)
- [시스템 아키텍처](docs/ARCHITECTURE.md)
- [플랫폼 전략: iOS · macOS](docs/PLATFORMS.md)
- [오탐 방지와 진실 판정 기준](docs/TRUTH_RULES.md)
- [바이브코딩 플랜](docs/VIBE_CODING_PLAN.md)
- [에이전트 작업 규칙](CLAUDE.md)

## 로컬 실행

필요한 것: Node.js 22 이상, [Supabase](https://supabase.com) 프로젝트 (무료 플랜으로 충분)

### 1. 설치

```bash
npm install
cp .env.example .env.local
```

### 2. Supabase 준비

1. Supabase에서 새 프로젝트를 만듭니다.
2. **Project Settings → API Keys**에서 Project URL과 Publishable key를 `.env.local`에 넣습니다.
3. 스키마를 적용합니다. 둘 중 하나를 고르세요.
   - SQL Editor에 `supabase/migrations/`의 파일을 **이름 순서대로** 하나씩 붙여넣고 실행
     (`20260925000000_init.sql` → `20260926000000_source_processing.sql` → `20260927000000_profiles_participants.sql` → …)
   - 또는 Supabase CLI: `npx supabase link --project-ref <프로젝트 ref>` 후 `npx supabase db push`
4. **Authentication → URL Configuration**
   - Site URL: `http://localhost:3000`
   - Redirect URLs에 `http://localhost:3000/auth/confirm` 추가 (배포 후에는 배포 주소도 추가)

### 3. 실행

```bash
npm run dev
```

http://localhost:3000 에 접속하면 로그인 화면이 나옵니다. 이메일로 받은 링크를 **같은 브라우저에서** 열면 로그인됩니다.
Supabase 기본 메일 발송은 시간당 횟수 제한이 있으니, 베타 테스터를 받기 전에 Authentication → SMTP Settings에서 자체 SMTP를 연결하세요.

## 명령어

| 명령어 | 설명 |
|---|---|
| `npm run dev` | 개발 서버 |
| `npm run lint` | ESLint |
| `npm run typecheck` | 라우트 타입 생성 후 TypeScript 검사 |
| `npm run test` | 단위 테스트 + DB 마이그레이션·RLS 테스트 (PGlite, 별도 DB 불필요) |
| `npm run eval` | 골든셋 검증 (Phase 1부터 추출 품질 측정) |
| `npm run build` | 프로덕션 빌드 |

## 구조

```
src/
  app/                 화면과 라우트 (login, auth/confirm, auth/signout, 지금 할 일)
  components/ui/       shadcn/ui 컴포넌트
  lib/
    auth.ts            requireUser(): 서버에서 로그인 사용자 확인
    env.ts             환경변수 검증
    supabase/          브라우저·서버·proxy용 Supabase 클라이언트
    eval/              골든셋 형식과 검증
  proxy.ts             세션 갱신 + 비로그인 사용자 리다이렉트 (Next.js 16의 middleware)
supabase/migrations/   DB 스키마 (RLS 포함)
evals/golden/          골든셋
tests/db/              마이그레이션·RLS 테스트
```
