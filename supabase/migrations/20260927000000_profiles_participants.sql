-- 원문 속에서 사용자를 알아보는 정보 (별칭 · 이메일)와 원문 관련자
-- 받아쓰기 회의록은 이름이 틀리기 쉬워 별칭이 필요하고, 메일은 주소로 사용자를 확실히 찾는다.

create table public.profiles (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  display_name text check (char_length(display_name) between 1 and 50),
  aliases text[] not null default '{}' check (cardinality(aliases) <= 20),
  emails text[] not null default '{}' check (cardinality(emails) <= 10),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
create policy "owner_all" on public.profiles for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- 메일의 보낸 사람 · 받는 사람 · 참조, 회의 참석자 ({ from, to, cc, attendees })
alter table public.sources add column participants jsonb;
