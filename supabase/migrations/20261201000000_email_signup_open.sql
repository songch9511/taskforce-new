-- 이메일 6자리 코드 로그인을 모두에게 연다 (OA 이메일 로그인 계약 5.5 · 5.6).
-- 1) Before User Created 훅(20261007000000)을 새로 만든다: 이메일 가입을 열되 일회용 메일 도메인과 한 시간 미확인 가입 상한만 막는다.
--    이름 · 인자가 그대로라 대시보드 훅 설정(Authentication → Hooks → Before User Created → public.hook_before_user_created)은 바꿀 것이 없다.
-- 2) 코드를 요청하고 넣지 않은 가입(미확인 이메일 행)을 24시간 뒤 지우는 함수. retention cron(src/app/api/cron/retention)이 매일 부른다.
-- 이 마이그레이션은 여는 날 적용한다: 그 전에는 지금 훅이 이메일 가입을 막는다. `db push`가 아니라 새 파일만 `--linked -f`로 적용한다.

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
--      주소가 비었거나 @가 없음(403) → 심사 허용 목록(통과) → 차단 도메인 또는 그 상위 도메인(403) → 한 시간 미확인 가입 100 이상(429) → 통과
--    상한: 지난 1시간에 만들어진 미확인 이메일 사용자. 메일 비용과 스팸 신고로 메일 공급자 계정이 막히는 것을 막는 전체 차단기다.
--    숫자는 함수 안 상수다 (바꾸려면 새 마이그레이션). IP별 제한은 여기서 하지 않는다: 훅은 stable이라 기록할 수 없고, Supabase IP 제한(5분 30)이 한다.
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
  v_hourly_limit constant integer := 100;
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

  v_domain := rtrim(substring(v_email from '@([^@]*)$'), '.');
  -- 도메인 자신 또는 그 하위 도메인 (x.mailinator.com → mailinator.com). 글자 그대로 비교한다: LIKE의 _ · %는 패턴 문자라 쓰지 않는다
  if v_domain = '' or exists (
    select 1 from public.blocked_email_domains b
    where v_domain = b.domain or right(v_domain, char_length(b.domain) + 1) = '.' || b.domain
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

-- 3) 미확인 이메일 가입 정리. Supabase는 코드를 보낼 때 auth.users에 미확인 행을 만든다 (세션 · 앱 데이터 없음, 트리거 없음).
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
