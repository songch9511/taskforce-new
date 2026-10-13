-- 0.2.0 OA D4c-3a: 이슈 번호 "#139" (서버 저장만). 화면이 이슈를 번호로 부르려면 actions에 사람이 읽는 번호가 있어야 한다.
-- 설계: docs/design/taskforce-0.2.0-assistant-contract-2026-10-12.md 7장. 새 표는 action_counters, 새 열은 actions.number다.
--
-- 1) actions.number: 사용자별 1부터 이어지는 번호. unique (user_id, number), not null, 1 이상.
--    - 번호는 insert 트리거(actions_assign_number)가 카운터에서 준다. 호출자가 준 number는 무시한다(호출자가 번호를 정하지 못한다).
--    - 한 번 받은 번호는 바뀌지 않는다(actions_number_immutable). 행을 지우거나 status를 dropped로 바꿔도 카운터는 내려가지 않아 번호를 다시 쓰지 않는다.
--    - 롤백한 insert는 번호를 쓰지 않는다: 카운터를 올리는 일이 그 insert와 같은 트랜잭션 안에 있다.
--    - 기존 행은 사용자별 created_at, id 순으로 1부터 채운다. 번호 말고는 아무것도 바꾸지 않는다(updated_at 트리거를 백필 동안만 끈다).
-- 2) action_counters (user_id pk, next): 사용자가 다음에 받을 번호. 사용자 한 줄을 insert 트리거가 for update와 같은 행 잠금으로 잡아 올린다.
--    새 표는 user_id + RLS 규칙(CLAUDE.md)을 지키되 앱 권한은 0이다: RLS를 켜고 정책을 두지 않으며 anon · authenticated의 모든 권한을 거둔다
--    (context_version_bumps와 같은 처리). 앱이 카운터를 되돌리면 unique 위반으로 그 사용자의 모든 생성이 막히기 때문이다(검토 F21).
--    앱은 RLS로 actions를 읽어 number를 본다. 서버 응답(v1 contract)은 바뀌지 않는다.
--    카운터 행은 계정 삭제(auth.users on delete cascade)로 함께 지워진다.
--
-- 새 사용자 쓰기 경로가 아니다(트리거): 측정 이벤트를 더하지 않는다.
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). actions 표에 짧은 access exclusive 잠금을 건다(행 수가 작다고 가정, lock_timeout 5초).

begin;
-- actions에 열 · 제약 · 트리거를 더하며 그 표에 잠금을 잡는다: 운영에서 오래 기다리지 않고 실패하게 한다 (그때는 그대로 다시 적용)
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) 카운터: 앱 권한 0인 내부 표
-- ─────────────────────────────────────────────
create table public.action_counters (
  user_id uuid primary key references auth.users (id) on delete cascade,
  next integer not null constraint action_counters_next_check check (next >= 1),  -- 다음에 줄 번호
  updated_at timestamptz not null default now()
);

alter table public.action_counters enable row level security;
revoke all on public.action_counters from anon, authenticated;

-- ─────────────────────────────────────────────
-- 2) actions.number: 백필 → 제약 → 카운터 채우기
-- ─────────────────────────────────────────────
alter table public.actions add column number integer;

-- 백필이 updated_at을 올리지 않게 이 트리거만 잠시 끈다(트랜잭션 안이라 실패하면 켜진 채로 돌아온다). 다른 사용자 트리거는 actions에 없다
alter table public.actions disable trigger actions_set_updated_at;
update public.actions a
   set number = r.n
  from (select x.id, row_number() over (partition by x.user_id order by x.created_at, x.id) as n from public.actions x) r
 where a.id = r.id;
alter table public.actions enable trigger actions_set_updated_at;

alter table public.actions
  alter column number set not null,
  add constraint actions_number_check check (number >= 1),
  add constraint actions_user_number_key unique (user_id, number);

-- 사용자별 다음 번호 = 가장 큰 번호 + 1. Action이 없는 사용자는 첫 insert 때 트리거가 만든다
insert into public.action_counters (user_id, next)
select a.user_id, max(a.number) + 1
  from public.actions a
 group by a.user_id;

-- ─────────────────────────────────────────────
-- 3) insert 트리거: 번호를 준다
--    카운터 행을 한 문장으로 만들거나 올린다(on conflict do update가 행 잠금을 잡는다). 같은 사용자의 동시 insert는 이 행에서 줄을 서고,
--    앞 트랜잭션이 commit하면 올린 값을, rollback하면 올리기 전 값을 본다. 그래서 번호는 겹치지 않고 빈틈이 없다.
--    소유자 권한이다: insert하는 역할(서버)이 카운터 표 권한에 기대지 않는다. 들어온 new.number는 항상 덮어쓴다
-- ─────────────────────────────────────────────
create function public.actions_assign_number() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_number integer;
begin
  insert into public.action_counters as c (user_id, next)
  values (new.user_id, 2)
  on conflict (user_id) do update set next = c.next + 1, updated_at = now()
  returning c.next - 1 into v_number;
  new.number := v_number;
  return new;
end;
$$;

create trigger actions_assign_number
  before insert on public.actions
  for each row execute function public.actions_assign_number();

-- ─────────────────────────────────────────────
-- 4) update 가드: number는 바뀌지 않는다 (같은 값으로 쓰는 것은 바꾸는 것이 아니다)
-- ─────────────────────────────────────────────
create function public.actions_number_immutable() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'actions_number_immutable: number is assigned once and never changes' using errcode = 'check_violation';
end;
$$;

create trigger actions_number_immutable
  before update of number on public.actions
  for each row
  when (old.number is distinct from new.number)
  execute function public.actions_number_immutable();

-- 트리거 함수는 앱 · 익명이 직접 부를 수 없게 거둔다 (트리거로는 돈다)
revoke all on function public.actions_assign_number() from public, anon, authenticated;
revoke all on function public.actions_number_immutable() from public, anon, authenticated;

commit;
