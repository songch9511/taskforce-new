-- 이메일 8자리 코드 로그인을 모두에게 연다 (OA 이메일 로그인 계약 5.5 · 5.6 · 19).
-- 1) Before User Created 훅(20261007000000)을 새로 만든다: 이메일 가입을 열되 일회용 메일 도메인 · 가입 때 심은 user_metadata · 한 시간 미확인 가입 상한만 막는다.
--    이름 · 인자가 그대로라 대시보드 훅 설정(Authentication → Hooks → Before User Created → public.hook_before_user_created)은 바꿀 것이 없다.
-- 2) 코드를 요청하고 넣지 않은 가입(미확인 이메일 행)을 24시간 뒤 지우는 함수. retention cron(src/app/api/cron/retention)이 매일 부른다.
-- 3) auth.users 트리거: 심사 계정 밖 이메일 사용자는 비밀번호를 가질 수 없다 (가입 전 비밀번호 탈취 막기).
-- 4) 웹 /login의 코드 확인 시도를 이메일 해시별로 세는 표 · 함수 (가입 전이라 user_id 키인 take_rate_limit을 쓸 수 없다).
-- 이 마이그레이션은 여는 날 적용한다: 그 전에는 지금 훅이 이메일 가입을 막는다. `db push`가 아니라 새 파일만 `--linked -f`로 적용한다.
-- Supabase에 Resend SMTP를 켜는 일은 이 마이그레이션을 적용하고 이 코드를 배포한 뒤다 (켜는 순간 기존 계정이 공개 OTP API에 노출된다, docs/PLATFORMS.md 4장).

-- 1) 일회용 도메인 표 (서버 전용). 사용자 데이터가 아니라 user_id · owner_all 패턴의 대상이 아니다:
--    review_accounts와 같은 방식(RLS 켬 · anon/authenticated 권한 없음 · Auth(supabase_auth_admin)만 읽음). 쓰기는 service role뿐이다.
--    목록은 자주 바뀌어 마이그레이션에 넣지 않고 scripts/sync-blocked-email-domains.ts가 고정 커밋에서 채운다.
create table public.blocked_email_domains (
  domain text primary key check (domain = lower(domain) and char_length(domain) between 3 and 253),
  source text not null,
  created_at timestamptz not null default now()
);

alter table public.blocked_email_domains enable row level security;
revoke all on public.blocked_email_domains from anon, authenticated;
grant usage on schema public to supabase_auth_admin;
grant select on public.blocked_email_domains to supabase_auth_admin;
create policy "auth_admin_select" on public.blocked_email_domains for select to supabase_auth_admin using (true);

-- 2) Before User Created 훅. 허락하면 {}, 거절하면 { error: { http_code, message } } (Supabase Auth Hooks 형식).
--    provider가 email일 때만 본다 (Apple · Google은 그대로 통과). 순서:
--      주소가 비었거나 @가 없음(403) → 심사 허용 목록(통과) → user_metadata가 비어 있지 않음(403)
--      → 차단 도메인 또는 그 상위 도메인(403, 절대 막지 않을 도메인은 제외) → 한 시간 미확인 가입 15 이상(429) → 통과
--    상한: 지난 1시간에 만들어진 미확인 이메일 사용자. Supabase 메일 한도(시간당 30)와 Resend 하루 상한(무료 100)을 한 곳이 바닥내지 못하게 하는 전체 차단기다.
--    숫자는 함수 안 상수다 (바꾸려면 새 마이그레이션). IP별 제한은 여기서 하지 않는다: 훅은 stable이라 기록할 수 없고, Supabase IP 제한(5분 30)이 한다.
--    user_metadata: 가입 요청의 data가 그대로 들어오는 칸이다. 이 앱은 가입 때 아무것도 싣지 않으므로 비어 있어야 한다. 로컬 GoTrue v2.197.0은 가입 훅에 빈 객체를 준다(Auth가 스스로 넣는 키는 훅 뒤에 생긴다): 키가 하나라도 있으면 막는다.
--    메시지는 앱에 보이지 않는다 (앱은 HTTP 상태로 고른다).
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_provider text := event -> 'user' -> 'app_metadata' ->> 'provider';
  v_email text := lower(nullif(trim(event -> 'user' ->> 'email'), ''));
  -- 마지막 @ 뒤, 끝 점 없이 (user@mailinator.com. 로 우회하지 못하게)
  v_domain text;
  v_hourly_limit constant integer := 15;
  -- 가입 요청의 user_metadata: 키 없음 → null, JSON null → 'null', 그 밖에는 빈 object여야 한다
  v_meta jsonb := event -> 'user' -> 'user_metadata';
  v_meta_type text := jsonb_typeof(event -> 'user' -> 'user_metadata');
  -- 외부 차단 목록에 잘못 들어와도 막지 않을 흔한 개인 메일 (scripts/sync-blocked-email-domains.ts의 NEVER_BLOCK_DOMAINS와 같다). 정확히 같은 도메인만 면제한다
  v_never_block constant text[] := array[
    'gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'msn.com', 'icloud.com', 'me.com', 'mac.com',
    'yahoo.com', 'ymail.com', 'aol.com', 'proton.me', 'protonmail.com', 'pm.me', 'fastmail.com', 'zoho.com',
    'naver.com', 'daum.net', 'hanmail.net', 'kakao.com', 'nate.com'
  ];
begin
  if v_provider is distinct from 'email' then
    return '{}'::jsonb;
  end if;
  if v_email is null or position('@' in v_email) = 0 then
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', 'This email address can''t be used.'));
  end if;
  if exists (select 1 from public.review_accounts r where r.email = v_email) then
    return '{}'::jsonb;
  end if;

  if v_meta_type is not null and v_meta_type <> 'null' and v_meta <> '{}'::jsonb then
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', 'This email address can''t be used.'));
  end if;

  v_domain := rtrim(substring(v_email from '@([^@]*)$'), '.');
  -- 도메인 자신 또는 그 하위 도메인 (x.mailinator.com → mailinator.com). 글자 그대로 비교한다: LIKE의 _ · %는 패턴 문자라 쓰지 않는다
  if v_domain = '' or (
    v_domain <> all (v_never_block) and exists (
      select 1 from public.blocked_email_domains b
      where v_domain = b.domain or right(v_domain, char_length(b.domain) + 1) = '.' || b.domain
    )
  ) then
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', 'This email address can''t be used.'));
  end if;

  if (
    select count(*) from auth.users u
    where u.raw_app_meta_data ->> 'provider' = 'email'
      and u.email_confirmed_at is null
      and u.created_at > now() - interval '1 hour'
  ) >= v_hourly_limit then
    return jsonb_build_object('error', jsonb_build_object('http_code', 429, 'message', 'Too many new sign-ups. Try again later.'));
  end if;

  return '{}'::jsonb;
end;
$$;

grant execute on function public.hook_before_user_created to supabase_auth_admin;
revoke execute on function public.hook_before_user_created from public, anon, authenticated;

-- 3) 미확인 이메일 가입 정리. Supabase는 코드를 보낼 때 auth.users에 미확인 행을 만든다 (세션 · 앱 데이터 없음, 이 행을 지울 때 도는 트리거 없음: 아래 4)의 트리거는 넣기 · 고치기 때만 돈다).
--    지우는 행(모두): 이메일로 가입 · 확인 안 됨 · 로그인한 적 없음 · 만든 지 24시간 지남 · SSO 아님 · 이메일이 아닌 identity 없음 · 심사 허용 목록에 없음.
--    identity는 auth.users 삭제로 함께 지워진다. 한 번에 오래된 것부터 1,000행, 지운 수를 돌려준다. service_role만 실행한다.
create function public.purge_unconfirmed_email_signups()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  with picked as (
    select u.id from auth.users u
    where u.raw_app_meta_data ->> 'provider' = 'email'
      and u.email_confirmed_at is null
      and u.last_sign_in_at is null
      and u.created_at < now() - interval '24 hours'
      and u.is_sso_user = false
      and not exists (select 1 from auth.identities i where i.user_id = u.id and i.provider <> 'email')
      and not exists (select 1 from public.review_accounts r where r.email = lower(u.email))
    order by u.created_at, u.id
    limit 1000
    for update of u skip locked
  )
  delete from auth.users where id in (select id from picked);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.purge_unconfirmed_email_signups() from public, anon, authenticated;
grant execute on function public.purge_unconfirmed_email_signups() to service_role;

-- 4) 사용자는 비밀번호를 가질 수 없다 (심사 허용 목록의 계정만 예외, 제공자와 상관없이). 가입 전 비밀번호 탈취(pre-account takeover)를 막는다:
--    이메일 로그인을 모두에게 열면 누구나 피해자 주소를 비밀번호와 함께 미리 가입(미확인)해 둘 수 있다. 피해자가 나중에 자기 메일의 코드로 확인하면
--    그 행이 확인되고, 공격자는 처음 정한 비밀번호로 로그인한다. 그래서 (심사 계정이 아닌) 모든 행의 encrypted_password는 넣을 때와 바뀔 때마다 빈 문자열로 만든다
--    (비밀번호 없는 사용자의 GoTrue 값과 같다: Apple · Google 사용자도 빈 값이고, 빈 해시는 어떤 비밀번호와도 맞지 않아 비밀번호 로그인이 거절된다.
--    NULL이 아닌 빈 문자열인 것은 열의 NOT NULL 여부에 기대지 않으려는 것이다). 이 트리거는 대시보드 단계 없이 SQL만으로 막는다.
--    - 넣을 때: 공격자가 정한 비밀번호가 저장되지 않는다. 확인 전 사용자가 다시 가입하며 비밀번호를 갈아 끼우는 갱신(UPDATE)도 같다.
--    - 처음 확인할 때: 이 트리거가 생기기 전에 만든 행에 비밀번호가 남아 있어도 확인하는 갱신에서 비운다 (GoTrue는 갱신 때 모든 열을 다시 쓴다).
--    - 예외: review_accounts에 있는 주소 (create-review-account.ts가 허용 목록에 먼저 넣고 비밀번호와 함께 만든다).
--    - 제공자를 가리지 않는다 (최종 보안 검토): 앱에 비밀번호 로그인이 없으므로 Apple · Google로 만든 계정도 비밀번호를 가질 수 없다. 이 값들은 원래 빈 값이라 평소에는 아무것도 바뀌지 않는다.
--    시험 DB의 auth.users에는 이 열들이 없을 수 있어(tests/db/local-supabase.ts) 열을 직접 쓰지 않고 행을 jsonb로 바꿔 읽고 되돌린다.
--    security definer: 행을 넣는 Auth 역할의 권한과 상관없이 review_accounts를 읽는다.
create function public.strip_unverified_email_password()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb := to_jsonb(new);
  v_email text := lower(nullif(trim(v_row ->> 'email'), ''));
begin
  if coalesce(v_row ->> 'encrypted_password', '') = '' then
    return new;
  end if;
  if v_email is not null and exists (select 1 from public.review_accounts r where r.email = v_email) then
    return new;
  end if;
  new := jsonb_populate_record(new, jsonb_build_object('encrypted_password', ''));
  return new;
end;
$$;

revoke execute on function public.strip_unverified_email_password() from public, anon, authenticated;

create trigger strip_unverified_email_password
  before insert or update on auth.users
  for each row execute function public.strip_unverified_email_password();

-- 5) 웹 /login의 코드 확인 시도 (src/lib/api/rate-limit-store.ts takeEmailCodeAttempt). 서버 전용 표: 주소는 소문자 sha256만 둔다 (원본 이메일은 남기지 않는다).
--    사용자 데이터가 아니라 user_id · owner_all 패턴의 대상이 아니다 (blocked_email_domains와 같다). 운영자 주소만 닿는다: 웹이 목록 밖 주소는 여기까지 보내지 않는다.
create table public.login_code_attempts (
  id uuid primary key default gen_random_uuid(),
  email_hash text not null check (email_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);

create index login_code_attempts_hash_created_idx on public.login_code_attempts (email_hash, created_at);

alter table public.login_code_attempts enable row level security;
revoke all on public.login_code_attempts from anon, authenticated;

-- 최근 p_window_seconds 안의 시도가 p_max개 미만이면 한 번을 남기고 null, 아니면 남기지 않고 다시 할 수 있는 시각을 돌려준다 (take_rate_limit과 같은 약속).
-- 같은 해시의 호출은 advisory lock으로 한 줄로 세우므로 동시 요청도 한도를 넘지 못한다. 창 밖의 같은 해시 행은 이때 지운다 (표가 커지지 않는다).
create function public.take_login_code_attempt(p_email_hash text, p_max int, p_window_seconds int)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_window interval := make_interval(secs => p_window_seconds);
  v_since timestamptz;
  v_nth timestamptz;
begin
  if p_email_hash is null or p_email_hash !~ '^[0-9a-f]{64}$' or p_max < 1 or p_window_seconds < 1 then
    raise exception 'take_login_code_attempt: 잘못된 인자';
  end if;
  perform pg_advisory_xact_lock(hashtext('login_code_attempts:' || p_email_hash));
  v_since := clock_timestamp() - v_window;

  delete from public.login_code_attempts a where a.email_hash = p_email_hash and a.created_at <= v_since;

  select a.created_at into v_nth from public.login_code_attempts a
  where a.email_hash = p_email_hash and a.created_at > v_since
  order by a.created_at desc offset p_max - 1 limit 1;
  if v_nth is not null then
    return v_nth + v_window;
  end if;

  insert into public.login_code_attempts (email_hash, created_at) values (p_email_hash, clock_timestamp());
  return null;
end;
$$;

revoke execute on function public.take_login_code_attempt(text, int, int) from public, anon, authenticated;
grant execute on function public.take_login_code_attempt(text, int, int) to service_role;
