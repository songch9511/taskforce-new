-- Operator-managed grants for beta users who have not signed up yet.
-- An email alone is not sufficient: Supabase Auth must confirm ownership first.
create table public.billing_beta_email_grants (
 email text primary key check (email = lower(btrim(email)) and email <> ''),
 created_at timestamptz not null default now()
);
alter table public.billing_beta_email_grants enable row level security;
revoke all on public.billing_beta_email_grants from public, anon, authenticated;
grant select, insert, update, delete on public.billing_beta_email_grants to service_role;

create function public.billing_grant_beta_on_verified_email() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
 if new.email_confirmed_at is not null and exists (
  select 1 from public.billing_beta_email_grants where email = lower(btrim(new.email))
 ) then
  insert into public.billing_accounts(user_id, legacy_beta) values (new.id, true)
  on conflict (user_id) do update set legacy_beta = true
  where not public.billing_accounts.deleting;
 end if;
 return new;
end;
$$;
revoke all on function public.billing_grant_beta_on_verified_email() from public, anon, authenticated;

create trigger billing_beta_verified_email
 after insert or update of email, email_confirmed_at on auth.users
 for each row execute function public.billing_grant_beta_on_verified_email();
