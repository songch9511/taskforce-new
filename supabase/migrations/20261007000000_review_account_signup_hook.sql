-- App Store 심사용 로그인: 이메일 + 비밀번호 가입은 허용 목록(review_accounts)에 있는 주소만 받는다.
-- 사용자 로그인은 Sign in with Apple이다. Supabase Auth의 "Before User Created" 훅으로 이 함수를 켜면
-- (대시보드 Authentication → Hooks → Before User Created → Postgres function → public.hook_before_user_created)
-- 새로 만들어지는 사용자 중 provider가 email인데 목록에 없는 주소는 거절한다. 이미 있는 사용자 · Apple 가입은 그대로다.
-- 심사 계정은 scripts/create-review-account.ts가 목록에 넣고 만든다.

-- 1) 허용 목록 (서버 전용). 주소는 소문자로 둔다. Auth(supabase_auth_admin)만 읽는다.
create table public.review_accounts (
  email text primary key check (email = lower(email) and char_length(email) between 3 and 320),
  note text,
  created_at timestamptz not null default now()
);

alter table public.review_accounts enable row level security;
revoke all on public.review_accounts from anon, authenticated;
grant usage on schema public to supabase_auth_admin;
grant select on public.review_accounts to supabase_auth_admin;
create policy "auth_admin_select" on public.review_accounts for select to supabase_auth_admin using (true);

-- 2) Before User Created 훅. 허용하면 {}, 거절하면 { error: { http_code, message } } (Supabase Auth Hooks 형식).
create function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_provider text := event -> 'user' -> 'app_metadata' ->> 'provider';
  v_email text := lower(nullif(trim(event -> 'user' ->> 'email'), ''));
begin
  if v_provider = 'email' and (v_email is null or not exists (select 1 from public.review_accounts r where r.email = v_email)) then
    return jsonb_build_object(
      'error', jsonb_build_object('http_code', 403, 'message', '이메일로는 새로 가입할 수 없어요. Sign in with Apple을 사용해 주세요.')
    );
  end if;
  return '{}'::jsonb;
end;
$$;

grant execute on function public.hook_before_user_created to supabase_auth_admin;
revoke execute on function public.hook_before_user_created from public, anon, authenticated;
