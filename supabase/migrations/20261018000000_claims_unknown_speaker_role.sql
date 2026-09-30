alter table public.claims drop constraint claims_speaker_role_check;
alter table public.claims add constraint claims_speaker_role_check
  check (speaker_role in ('me', 'counterpart', 'third_party', 'unknown'));
