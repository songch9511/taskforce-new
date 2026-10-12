-- 0.2.0 C3 — 제안(suggestions) · 복귀 요약 · Clear (구현 계획 C3, 런타임 계약 1 · 6 · 8 · 12장, A08 · A09 · A39 · A40 · ARCH25).
-- 표 3개(suggestions · return_summary_state · return_summary_reads)와 서비스 롤 전용 함수 8개. 기존 표 · 함수 · 제약 · 트리거는 한 글자도 바꾸지 않는다(additive).
-- 읽고 쓰는 코드는 REVIEW_V2_ENABLED gate 뒤에만 있다(src/lib/review, /api/v2/review · /api/v2/return-summary · /api/v2/suggestions). 꺼져 있으면 표는 비어 있다.
--
-- 이 파일이 하는 일 / 하지 않는 일
--   1) suggestions: 능동 제안. 글 · 원문이 없다 — kind(코드 토큰) · 가리키는 Action/run id · subject_key · revision(계기) · 상태 · 시각뿐이다.
--      dedup_key = kind + subject + 계기 revision이고 날짜가 아니다 (같은 계기는 하루가 지나도 다시 제안하지 않는다, A08). (user_id, dedup_key) 유일.
--      dismiss_scope = 'topic'은 같은 kind + subject의 새 계기도 막는다. 상태 전이는 state + version 조건부 쓰기(suggestion_transition)뿐이다.
--      비긴급은 하루 한 묶음 · 3개까지만 처음 노출한다(batch_day, suggestions_expose). 긴급(urgent)은 상한 밖이다. 이미 노출한 비긴급은 처리하기 전까지 남는다.
--      자동 만료 · 보관 · 정리가 없다: expired는 증거가 있을 때만(기한이 바뀜 · Action이 닫힘 · run이 끝남/바뀜) 쓰고, 나이만으로는 쓰지 않는다.
--   2) return_summary_reads: Clear가 읽음으로 표시한 사건의 id(원천 + 사건 id뿐, 글 없음). return_summary_state: 마지막으로 Clear한 시각 하나(표시용 "Since …"
--      · "Clear한 적이 있다"의 표시일 뿐 읽음의 근거가 아니다. 단조 증가 트리거). 새 원문 · 요약 저장소가 아니다.
--   3) 복귀 요약 읽기(return_summary_scan)는 새 표 없이 action_events · execution_events · conversation_messages · conversations.last_read_at에서 계산한다.
--      **읽음은 시각이 아니라 사건 id로 정한다.** action_events.created_at 등은 트랜잭션 시작 시각이라 commit 순서와 다르다: "지평(horizon) 이전은 다 봤다"를
--      시각으로는 증명할 수 없다(아직 commit하지 않았거나 아직 쓰지 않은 트랜잭션의 행이 나중에 그 시각으로 나타난다). 그래서 Clear는 조회가 본 사건 집합
--      (지평까지 보인 후보 전부)을 digest로 확인한 뒤 **그 집합의 id만** 읽음으로 표시한다. 확인과 표시는 한 문장(스냅샷 하나)이다 —
--      조회 뒤 Clear 전에 commit된 사건이 있으면 digest가 달라 거절하고(stale), Clear 때도 아직 commit되지 않은 사건은 집합에 없으므로 읽음이 되지 않아
--      commit된 뒤 다음 조회에 보인다.
--   4) 하지 않는 것: Action 값 · Claim · 근거 · run · 단계 · 정책 · 승인 hash · intent · lease · 크레딧을 읽어 판단하거나 바꾸지 않는다(I04 · I14 · D13).
--      기존 user_seen(markActionSeen) 경로를 쓰지 않는다. 새 결정 outcome · Undo · 미구현 효과가 없다(제안 accept는 이 묶음에 없다).
--
-- 모든 함수는 service_role 전용이고 search_path = '' 이다(앱 · 익명 호출 불가). 모든 읽기 · 쓰기는 p_user_id로 좁히고, 남의 id는 "없음"으로 같다.
--
-- 적용: 운영 DB에는 병합 직전 승인을 받고 `supabase db query --linked -f`로 한다(db push 금지). 한 트랜잭션으로 돈다.
-- 되돌리기(rollback): 이 파일이 만든 표 3개 · 함수 10개(트리거 함수 2개 포함)를 지우면 된다 — 다른 객체는 건드리지 않았다. 순서대로 (시험이 이 문장들을 그대로 실행해 확인한다):
--   drop function public.return_summary_scan(uuid, text[], timestamptz, integer), public.return_summary_clear(uuid, text[], timestamptz, text, timestamptz), public.return_summary_digest(uuid, text[], timestamptz), public.return_summary_candidates(uuid, text[], timestamptz), public.suggestions_expose(uuid, date, integer, timestamptz), public.suggestions_produce(uuid, timestamptz, integer, boolean), public.suggestion_transition(uuid, uuid, integer, text, timestamptz, text, timestamptz), public.suggestion_stale_evidence(public.suggestions);
--   drop table public.return_summary_reads, public.return_summary_state, public.suggestions;
--   drop function public.suggestions_guard(), public.return_summary_state_guard();

begin;
-- 기존 표(actions · execution_runs)를 가리키는 외래키를 만든다: 운영에서 오래 기다리지 않고 실패하게 한다(그때는 그대로 다시 적용한다. 한 트랜잭션이라 남는 객체가 없다)
set local lock_timeout = '5s';

-- ─────────────────────────────────────────────
-- 1) suggestions: 능동 제안 (런타임 계약 8장)
--    action_id는 모든 kind의 주제 Action이다(복합 외래키: 남의 Action을 가리킬 수 없고 Action을 지우면 함께 사라진다). run_id는 run을 가리키는 kind에서만.
--    subject_key = 'action:<id>' | 'run:<id>' (kind와 계기 없이 주제만): topic 거절의 열쇠. revision = 계기(기한 값 · run id · 사건 키).
--    batch_day = 비긴급이 처음 노출된 사용자 현지 날짜(하루 한 묶음의 열쇠). 긴급은 null.
-- ─────────────────────────────────────────────
create table public.suggestions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind ~ '^[a-z][a-z0-9_]{0,63}$'),
  action_id uuid not null,
  run_id uuid,
  subject_key text not null check (char_length(subject_key) between 1 and 200),
  revision text not null check (char_length(revision) between 1 and 200),
  dedup_key text not null check (char_length(dedup_key) between 1 and 500),
  reason_refs jsonb not null default '{}',
  state text not null default 'open' check (state in ('open', 'accepted', 'snoozed', 'dismissed', 'expired')),
  snooze_until timestamptz,
  dismiss_scope text check (dismiss_scope in ('this', 'topic')),
  urgent boolean not null default false,
  batch_day date,
  version integer not null default 1 check (version >= 1),
  created_at timestamptz not null default now(),
  shown_at timestamptz,
  decided_at timestamptz,
  -- expired의 근거 종류(닫힌 목록). 나이만으로 만든 근거는 없다
  stale_evidence text check (stale_evidence in ('action_closed', 'revision_changed', 'run_superseded', 'run_ended')),
  -- reason_refs는 id · 종류 토큰 · 숫자만 (C2 inbox_refs_valid와 같은 모양): 원문 · 발화 글이 들어올 길이 없다
  constraint suggestions_reason_refs check (public.inbox_refs_valid(reason_refs)),
  constraint suggestions_shape check (
    (state = 'snoozed') = (snooze_until is not null)
    and (state = 'dismissed') = (dismiss_scope is not null)
    and (state in ('accepted', 'dismissed', 'expired')) = (decided_at is not null)
    and (state = 'expired') = (stale_evidence is not null)
  ),
  unique (user_id, dedup_key),
  unique (id, user_id),
  foreign key (action_id, user_id) references public.actions (id, user_id) on delete cascade,
  foreign key (run_id, user_id) references public.execution_runs (id, user_id) on delete cascade
);

create index suggestions_user_state_idx on public.suggestions (user_id, state, created_at, id);
-- topic 거절 확인(생산 때): 같은 kind + subject
create index suggestions_topic_idx on public.suggestions (user_id, kind, subject_key) where state = 'dismissed' and dismiss_scope = 'topic';

-- 제안의 사실(누구 · 무슨 계기 · 긴급 여부)은 바뀌지 않고, version은 줄지 않는다. 고치는 정식 경로는 아래 함수뿐이다
create function public.suggestions_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.user_id, new.kind, new.action_id, new.run_id, new.subject_key, new.revision, new.dedup_key, new.urgent, new.created_at)
     is distinct from (old.user_id, old.kind, old.action_id, old.run_id, old.subject_key, old.revision, old.dedup_key, old.urgent, old.created_at) then
    raise exception 'suggestions: 제안의 사실(user_id · kind · action_id · run_id · subject_key · revision · dedup_key · urgent · created_at)은 immutable이다 (%)', old.id
      using errcode = 'check_violation';
  end if;
  if new.version < old.version then
    raise exception 'suggestions: version은 줄지 않는다 (%)', old.id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger suggestions_guard
  before update on public.suggestions
  for each row execute function public.suggestions_guard();

-- ─────────────────────────────────────────────
-- 2) return_summary_state: Clear 위치. 사용자당 한 행, 뒤로 가지 않는다
-- ─────────────────────────────────────────────
create table public.return_summary_state (
  user_id uuid primary key references auth.users (id) on delete cascade,
  cleared_through timestamptz not null,
  version bigint not null default 1 check (version >= 1),
  updated_at timestamptz not null default now()
);

create function public.return_summary_state_guard() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.cleared_through < old.cleared_through then
    raise exception 'return_summary_state: cleared_through는 뒤로 가지 않는다 (%)', old.user_id using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger return_summary_state_guard
  before update on public.return_summary_state
  for each row execute function public.return_summary_state_guard();

-- Clear가 읽음으로 표시한 사건: (원천, 사건 id). action_event = action_events.id(uuid), run_event = execution_events.id(bigint), message = conversation_messages.id(uuid).
-- 읽음은 쌓이기만 한다(지우지 않는다 · 만료 정책 없음). 사건이 지워지면 표시는 아무것도 가리키지 않는 채 남는다(되살아날 것이 없다). 글이 없고 id뿐이다.
create table public.return_summary_reads (
  user_id uuid not null references auth.users (id) on delete cascade,
  source text not null check (source in ('action_event', 'run_event', 'message')),
  event_ref text not null check (
    event_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or event_ref ~ '^[0-9]{1,19}$'),
  read_at timestamptz not null default now(),
  primary key (user_id, source, event_ref)
);

-- ─────────────────────────────────────────────
-- 3) RLS · 권한: 본인 행만 읽는다 (owner_all). 쓰기 권한은 없다 — 서버(service role, RLS 우회)만 쓴다
-- ─────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array['suggestions', 'return_summary_state', 'return_summary_reads'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "owner_all" on public.%I for all to authenticated
         using (user_id = (select auth.uid()))
         with check (user_id = (select auth.uid()))',
      t
    );
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end;
$$;

-- ─────────────────────────────────────────────
-- 4) 증거 있는 stale: 제안의 주제가 아직 유효한가 (null = 유효, 아니면 근거 종류)
--    나이는 근거가 아니다. 기한이 바뀜(그 기한의 제안이 아니다) · Action이 닫힘 · run이 새 run으로 바뀜/끝남만.
-- ─────────────────────────────────────────────
create function public.suggestion_stale_evidence(s public.suggestions) returns text
language sql
stable
set search_path = ''
as $$
  select case
    when a.id is null or a.status <> 'open' then 'action_closed'
    when s.kind = 'due_window' then
      case when a.due_at is not null and floor(extract(epoch from a.due_at))::bigint::text = s.revision then null else 'revision_changed' end
    when s.kind = 'run_failed' then
      case when r.state = 'failed'
                and not exists (
                  select 1 from public.execution_runs n
                   where n.user_id = r.user_id and n.action_id = r.action_id and (n.created_at, n.id) > (r.created_at, r.id))
           then null else 'run_superseded' end
    when s.kind = 'source_revised_run' then
      case when r.state in ('queued', 'running', 'waiting_approval') then null else 'run_ended' end
    else null
  end
  from (select 1) x
  left join public.actions a on a.id = s.action_id and a.user_id = s.user_id
  left join public.execution_runs r on r.id = s.run_id and r.user_id = s.user_id
$$;

-- ─────────────────────────────────────────────
-- 5) 생산자: 지금 있는 결정적 사실에서만 (같은 계기는 on conflict do nothing — 몇 번을 불러도 새 제안 0)
--    due_window        : 기한이 지금~p_window_hours 안인 내 열린 Action (지난 기한은 쌓지 않는다: 오래된 일이 한꺼번에 제안이 되지 않게). 긴급.
--    run_failed        : 그 Action의 가장 최근 run이 failed (열린 Action). 긴급.
--    source_revised_run: C2 코디네이터가 처리한 source_revised(impact_recorded)가 가리키는 살아 있는 run (p_with_coordinator일 때만 읽는다). 비긴급.
--    topic 거절이 있는 (kind, subject_key)는 새 계기도 만들지 않는다. 같은 사용자의 제안 쓰기는 advisory lock으로 직렬이다(topic 거절 확인과 거절 사이의 틈이 없다).
--    Action · run · Claim · 정책을 읽어 바꾸지 않는다 — 읽기만 하고 쓰는 곳은 suggestions뿐이다. 만든 개수를 돌려준다
-- ─────────────────────────────────────────────
create function public.suggestions_produce(p_user_id uuid, p_now timestamptz, p_window_hours integer, p_with_coordinator boolean)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_total integer := 0;
  v_rows integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('suggestions:' || p_user_id::text, 0));

  insert into public.suggestions (user_id, kind, action_id, subject_key, revision, dedup_key, reason_refs, urgent)
  select a.user_id, 'due_window', a.id, 'action:' || a.id::text, floor(extract(epoch from a.due_at))::bigint::text,
         'due_window:action:' || a.id::text || ':' || floor(extract(epoch from a.due_at))::bigint::text,
         jsonb_build_object('action_id', a.id), true
    from public.actions a
   where a.user_id = p_user_id and a.status = 'open' and a.owner <> 'other'
     and a.due_at > p_now and a.due_at <= p_now + make_interval(hours => p_window_hours)
     and not exists (
       select 1 from public.suggestions t
        where t.user_id = a.user_id and t.kind = 'due_window' and t.subject_key = 'action:' || a.id::text
          and t.state = 'dismissed' and t.dismiss_scope = 'topic')
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_rows = row_count;
  v_total := v_total + v_rows;

  insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key, reason_refs, urgent)
  select r.user_id, 'run_failed', r.action_id, r.id, 'action:' || r.action_id::text, r.id::text,
         'run_failed:action:' || r.action_id::text || ':' || r.id::text,
         jsonb_build_object('action_id', r.action_id, 'run_id', r.id), true
    from public.execution_runs r
    join public.actions a on a.id = r.action_id and a.user_id = r.user_id
   where r.user_id = p_user_id and r.state = 'failed' and a.status = 'open'
     and not exists (
       select 1 from public.execution_runs n
        where n.user_id = r.user_id and n.action_id = r.action_id and (n.created_at, n.id) > (r.created_at, r.id))
     and not exists (
       select 1 from public.suggestions t
        where t.user_id = r.user_id and t.kind = 'run_failed' and t.subject_key = 'action:' || r.action_id::text
          and t.state = 'dismissed' and t.dismiss_scope = 'topic')
  on conflict (user_id, dedup_key) do nothing;
  get diagnostics v_rows = row_count;
  v_total := v_total + v_rows;

  if p_with_coordinator then
    insert into public.suggestions (user_id, kind, action_id, run_id, subject_key, revision, dedup_key, reason_refs, urgent)
    select distinct r.user_id, 'source_revised_run', r.action_id, r.id, 'run:' || r.id::text, e.dedup_key,
           'source_revised_run:run:' || r.id::text || ':' || e.dedup_key,
           jsonb_build_object('run_id', r.id, 'event_id', e.id), false
      from public.inbox_events e
      cross join lateral jsonb_array_elements_text(
        case when jsonb_typeof(e.result_ids -> 'run_ids') = 'array' then e.result_ids -> 'run_ids' else '[]'::jsonb end) as rid
      join public.execution_runs r on r.user_id = e.user_id and r.id = rid::uuid
      join public.actions a on a.id = r.action_id and a.user_id = r.user_id
     where e.user_id = p_user_id and e.type = 'source_revised' and e.processed_at is not null and e.result_kind = 'impact_recorded'
       and r.state in ('queued', 'running', 'waiting_approval') and a.status = 'open'
       and not exists (
         select 1 from public.suggestions t
          where t.user_id = r.user_id and t.kind = 'source_revised_run' and t.subject_key = 'run:' || r.id::text
            and t.state = 'dismissed' and t.dismiss_scope = 'topic')
    on conflict (user_id, dedup_key) do nothing;
    get diagnostics v_rows = row_count;
    v_total := v_total + v_rows;
  end if;

  return v_total;
end;
$$;

-- ─────────────────────────────────────────────
-- 6) 노출: 증거 있는 stale 정리 → snooze가 끝난 것 다시 열기 → (하루 한 묶음) 처음 노출 → 보이는 것
--    비긴급 상한: 사용자 현지 날짜(p_local_day, TS가 계산해서 넘긴다) 하나에 처음 노출 묶음은 하나(p_batch_size개까지). 그 날 한 번이라도 묶음이 있었으면
--    (그 묶음을 전부 처리했어도) 새 비긴급을 더 내지 않는다. 날짜가 null이면(시간대를 모름) 새 비긴급 노출 0 — 이미 노출한 것과 긴급은 그대로 보인다.
--    긴급은 상한 밖이다. 이미 노출한 비긴급은 처리하기 전까지 보이고 다시 "새로" 노출되지 않는다(변화 없는 반복 노출 없음, A09).
--    같은 사용자의 호출은 advisory lock으로 직렬이다(두 기기 · 재시도 · 두 worker가 같은 날 묶음을 둘 만들지 않는다).
--    제안을 보는 것은 Action · run을 만들지 않는다 — 쓰는 곳은 suggestions의 상태 · 노출 표시뿐이다.
-- ─────────────────────────────────────────────
create function public.suggestions_expose(p_user_id uuid, p_local_day date, p_batch_size integer, p_now timestamptz default null)
returns setof public.suggestions
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, public.db_now());
begin
  perform pg_advisory_xact_lock(hashtextextended('suggestions:' || p_user_id::text, 0));

  -- 증거가 있을 때만 expired (나이만으로는 아니다)
  update public.suggestions s
     set state = 'expired', stale_evidence = e.evidence, decided_at = v_now, snooze_until = null, version = s.version + 1
    from (
      select s2.id, public.suggestion_stale_evidence(s2) as evidence
        from public.suggestions s2
       where s2.user_id = p_user_id and s2.state in ('open', 'snoozed')
    ) e
   where s.id = e.id and e.evidence is not null;

  -- 사용자가 고른 snooze 시점이 지나면 다시 열린다 (하루 상한에 걸리지 않는다: 새 노출이 아니다)
  update public.suggestions
     set state = 'open', snooze_until = null, version = version + 1
   where user_id = p_user_id and state = 'snoozed' and snooze_until <= v_now;

  if p_local_day is not null and not exists (
    select 1 from public.suggestions where user_id = p_user_id and not urgent and batch_day = p_local_day
  ) then
    update public.suggestions
       set batch_day = p_local_day
     where id in (
       select id from public.suggestions
        where user_id = p_user_id and not urgent and state = 'open' and batch_day is null
        order by created_at, id
        limit p_batch_size
     );
  end if;

  update public.suggestions
     set shown_at = v_now
   where user_id = p_user_id and state = 'open' and shown_at is null and (urgent or batch_day is not null);

  return query
    select * from public.suggestions
     where user_id = p_user_id and state = 'open' and (urgent or batch_day is not null)
     order by urgent desc, created_at, id;
end;
$$;

-- ─────────────────────────────────────────────
-- 7) 전이: snooze(사용자가 고른 미래 시점) · dismiss(this | topic). state + version 조건부 — 옛 version · 끝난 상태는 conflict(아무것도 쓰지 않는다).
--    남의 제안 · 없는 제안은 not_found로 같다. accept는 이 묶음에 없다(채택이 낳는 효과가 아직 정의되지 않았다).
-- ─────────────────────────────────────────────
create function public.suggestion_transition(
  p_user_id uuid, p_id uuid, p_expected_version integer, p_op text,
  p_snooze_until timestamptz default null, p_dismiss_scope text default null, p_now timestamptz default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, public.db_now());
  v_row public.suggestions;
begin
  perform pg_advisory_xact_lock(hashtextextended('suggestions:' || p_user_id::text, 0));

  select * into v_row from public.suggestions where id = p_id and user_id = p_user_id for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;
  if v_row.version <> p_expected_version or v_row.state not in ('open', 'snoozed') then
    return jsonb_build_object('status', 'conflict');
  end if;

  if p_op = 'snooze' then
    if p_snooze_until is null or p_snooze_until <= v_now then
      return jsonb_build_object('status', 'invalid');
    end if;
    update public.suggestions
       set state = 'snoozed', snooze_until = p_snooze_until, version = version + 1
     where id = p_id and user_id = p_user_id
    returning * into v_row;
  elsif p_op = 'dismiss' then
    if p_dismiss_scope is null or p_dismiss_scope not in ('this', 'topic') then
      return jsonb_build_object('status', 'invalid');
    end if;
    update public.suggestions
       set state = 'dismissed', dismiss_scope = p_dismiss_scope, snooze_until = null, decided_at = v_now, version = version + 1
     where id = p_id and user_id = p_user_id
    returning * into v_row;
  else
    return jsonb_build_object('status', 'invalid');
  end if;

  return jsonb_build_object('status', 'ok', 'suggestion', to_jsonb(v_row));
end;
$$;

-- ─────────────────────────────────────────────
-- 8) 복귀 요약: 후보 사건 · digest · 읽기 · Clear
--    후보 사건 = 지평(p_horizon)까지 보이는 세 원천의 사건 (읽음 표시와 무관한 원본 집합):
--      a) action_events: 사용자가 아닌 주체(ai · agent)가 쓴 changed.ts 종류 (p_change_types는 TS CHANGE_EVENT_TYPES — 한 곳에서 정한다)
--      b) run 결과: execution_events type run, to_state done | failed
--      c) 대화: assistant · event 메시지가 가리키는 내 Action마다 한 줄 (refs.action_ids)
--    digest = 후보 사건 id 집합의 지문: 원천마다 (개수, id 해시 합). 같은 지평으로 다시 세어 같으면 조회가 본 집합과 지금 집합이 같다.
--    후보 집합에는 읽음 표시 · 사용자의 본 시각(user_seen)이 들어가지 않는다 — 다른 기기에서 읽거나 본 것이 digest를 흔들지 않게.
-- ─────────────────────────────────────────────
create function public.return_summary_candidates(p_user_id uuid, p_change_types text[], p_horizon timestamptz)
returns table (source text, event_ref text, action_id uuid, kind text, at timestamptz, detail text, source_state text, is_current boolean, last_read_at timestamptz)
language sql
stable
set search_path = ''
as $$
  select 'action_event'::text, e.id::text, e.action_id, e.type, e.created_at, null::text,
         case when e.source_id is null or s.id is null then 'deleted'
              when s.access_lost_at is not null then 'access_lost'
              when s.raw_text_purged_at is not null then 'text_expired'
              else 'available' end,
         true, null::timestamptz
    from public.actions act
    join public.action_events e on e.action_id = act.id and e.user_id = act.user_id
    left join public.sources s on s.id = e.source_id and s.user_id = e.user_id
   where act.user_id = p_user_id and e.actor <> 'user' and e.type = any (p_change_types) and e.created_at <= p_horizon
  union all
  select 'run_event'::text, ev.id::text, run.action_id, ev.to_state, ev.at, run.outcome, null::text, (run.state = ev.to_state), null::timestamptz
    from public.execution_runs run
    join public.execution_events ev on ev.run_id = run.id and ev.user_id = run.user_id
   where run.user_id = p_user_id and ev.type = 'run' and ev.to_state in ('done', 'failed') and ev.at <= p_horizon
  union all
  select distinct 'message'::text, msg.id::text, act.id, msg.role, msg.created_at, null::text, null::text, true, c.last_read_at
    from public.conversation_messages msg
    join public.conversations c on c.id = msg.conversation_id and c.user_id = msg.user_id
    cross join lateral jsonb_array_elements_text(
      case when jsonb_typeof(msg.refs -> 'action_ids') = 'array' then msg.refs -> 'action_ids' else '[]'::jsonb end) as ref(aid)
    join public.actions act on act.user_id = msg.user_id and act.id::text = ref.aid
   where msg.user_id = p_user_id and msg.role in ('assistant', 'event') and msg.created_at <= p_horizon
$$;

create function public.return_summary_digest(p_user_id uuid, p_change_types text[], p_horizon timestamptz)
returns text
language sql
stable
set search_path = ''
as $$
  with c as (select distinct cd.source, cd.event_ref from public.return_summary_candidates(p_user_id, p_change_types, p_horizon) cd)
  select 'a:' || (count(*) filter (where c.source = 'action_event'))::text || ':' || coalesce(sum(hashtextextended(c.event_ref, 0)::numeric) filter (where c.source = 'action_event'), 0)::text
      || '|r:' || (count(*) filter (where c.source = 'run_event'))::text || ':' || coalesce(sum(hashtextextended(c.event_ref, 0)::numeric) filter (where c.source = 'run_event'), 0)::text
      || '|m:' || (count(*) filter (where c.source = 'message'))::text || ':' || coalesce(sum(hashtextextended(c.event_ref, 0)::numeric) filter (where c.source = 'message'), 0)::text
    from c
$$;

-- 읽기: 문장 하나 = 스냅샷 하나. 후보 · digest · 작업별 변화가 같은 스냅샷에서 나온다. 아무것도 쓰지 않는다.
--   지평(horizon) = p_now(시험 · 서버 시각) 또는 DB 시각. 시각은 마이크로초까지 글자로 돌려준다(JS Date를 거치지 않는다).
--   보이는 변화 = 후보 중 **읽음 표시(return_summary_reads)가 없는 것**. 추가 규칙:
--     action_events 변화는 사용자 자기 수정 · 본 것 판정을 TS가 changed.ts 의미로 한다(last_user_at을 그대로 준다).
--     run 결과는 Clear한 적이 있을 때만(읽음 기준이 없으면 이력을 변화로 올리지 않는다) 그리고 지금도 그 상태일 때만.
--     대화 메시지는 conversations.last_read_at 이후만이고, Clear한 적도 last_read_at도 없으면 이력을 올리지 않는다.
--   since = 마지막 Clear의 지평(표시용). 원문 상태는 토큰이다(deleted · access_lost · text_expired · available). 원문 글 · 과거 값(before · after)은 읽지 않는다.
--   작업은 p_limit개까지 — 넘으면 truncated로 알린다(일부를 전체처럼 내지 않는다).
create function public.return_summary_scan(p_user_id uuid, p_change_types text[], p_now timestamptz default null, p_limit integer default 300)
returns jsonb
language sql
set search_path = ''
as $$
  with
  p as (
    select coalesce(p_now, clock_timestamp()) as h,
           (select st.cleared_through from public.return_summary_state st where st.user_id = p_user_id) as w
  ),
  shown as (
    select cd.*
      from p, public.return_summary_candidates(p_user_id, p_change_types, p.h) cd
     where not exists (
             select 1 from public.return_summary_reads r
              where r.user_id = p_user_id and r.source = cd.source and r.event_ref = cd.event_ref)
       and case cd.source
             when 'action_event' then true
             when 'run_event' then p.w is not null and cd.is_current
             else (p.w is not null or cd.last_read_at is not null) and cd.at > coalesce(cd.last_read_at, '-infinity'::timestamptz)
           end
  ),
  works as (
    select act.id as action_id, act.title, act.status, (act.started_at is not null) as started,
           (select to_char(max(ue.created_at) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
              from public.action_events ue
             where ue.user_id = p_user_id and ue.action_id = act.id and ue.actor = 'user') as last_user_at,
           max(ch.at) as latest,
           jsonb_agg(
             jsonb_build_object(
               'source', case ch.source when 'run_event' then 'run' when 'message' then 'message' else 'action_event' end,
               'kind', ch.kind,
               'at', to_char(ch.at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
               'detail', ch.detail, 'source_state', ch.source_state)
             order by ch.at, ch.source, ch.kind) as changes
      from shown ch
      join public.actions act on act.id = ch.action_id and act.user_id = p_user_id
     group by act.id, act.title, act.status, act.started_at
  )
  select jsonb_build_object(
    'since', (select to_char(p.w at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from p where p.w is not null),
    'horizon', (select to_char(p.h at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') from p),
    'digest', (select public.return_summary_digest(p_user_id, p_change_types, p.h) from p),
    'truncated', (select count(*) from works) > p_limit,
    'works', coalesce(
      (select jsonb_agg(
                jsonb_build_object(
                  'action_id', w.action_id, 'title', w.title, 'status', w.status, 'started', w.started,
                  'last_user_at', w.last_user_at, 'changes', w.changes)
                order by w.latest desc, w.action_id)
         from (select * from works order by latest desc, action_id limit p_limit) w),
      '[]'::jsonb)
  )
$$;

-- Clear: 조회가 본 사건 집합을 읽음으로 — 읽음일 뿐이다(해결 · 승인 · 완료 · 거절이 아니다). 쓰는 곳은 return_summary_reads · return_summary_state뿐이다.
--   cleared : 지평까지의 후보 집합이 조회 때와 같다(digest) → **그 집합의 사건 id만** 읽음으로 표시한다. 지평 뒤의 사건 · Clear 시점에 아직 commit되지 않은 사건은
--             집합에 없으므로 읽음이 되지 않는다(commit된 뒤 다음 조회에 보인다). applied=false는 쓸 것이 없었다(재시도 · 다른 기기에서 먼저 Clear) — 성공이다.
--   stale   : 조회 뒤 Clear 전에 집합이 달라졌다(늦게 commit됨 · 지워짐) → 아무것도 쓰지 않는다. 다시 조회해야 한다.
--   invalid : 지평이 서버 시각보다 미래다 → 아무것도 쓰지 않는다.
--   digest 확인과 표시는 **한 문장**이다(같은 스냅샷): 확인한 집합과 표시한 집합이 어긋날 틈이 없다.
--   같은 사용자의 Clear는 advisory lock으로 직렬이다(두 기기). 이 잠금은 writer를 막지 못하므로 정확성은 위의 "집합" 규칙이 만든다 — 잠금이 아니다.
--   표시한 사건은 다시 지우지 않는다(단조). 마지막 Clear 시각(cleared_through)은 greatest로만 움직인다.
create function public.return_summary_clear(
  p_user_id uuid, p_change_types text[], p_horizon timestamptz, p_digest text, p_now timestamptz default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, clock_timestamp());
  v_digest text;
  v_inserted bigint;
  v_before timestamptz;
  v_through timestamptz;
begin
  perform pg_advisory_xact_lock(hashtextextended('return_summary:' || p_user_id::text, 0));

  if p_horizon > v_now then
    return jsonb_build_object('status', 'invalid');
  end if;

  with ins as (
    insert into public.return_summary_reads (user_id, source, event_ref)
    select distinct p_user_id, cd.source, cd.event_ref
      from public.return_summary_candidates(p_user_id, p_change_types, p_horizon) cd
     where (select public.return_summary_digest(p_user_id, p_change_types, p_horizon)) = p_digest
    on conflict do nothing
    returning 1
  )
  select (select public.return_summary_digest(p_user_id, p_change_types, p_horizon)), (select count(*) from ins)
    into v_digest, v_inserted;
  if v_digest is distinct from p_digest then
    return jsonb_build_object('status', 'stale');
  end if;

  select st.cleared_through into v_before from public.return_summary_state st where st.user_id = p_user_id;
  insert into public.return_summary_state as st (user_id, cleared_through)
  values (p_user_id, p_horizon)
  on conflict (user_id) do update
    set cleared_through = excluded.cleared_through, version = st.version + 1, updated_at = now()
    where excluded.cleared_through > st.cleared_through;
  select st.cleared_through into v_through from public.return_summary_state st where st.user_id = p_user_id;

  return jsonb_build_object(
    'status', 'cleared',
    'applied', v_inserted > 0 or v_before is distinct from v_through,
    'cleared_through', to_char(v_through at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
end;
$$;

-- ─────────────────────────────────────────────
-- 9) 함수 권한: 서버(service role)만 부른다. 앱 · 익명은 부르지 못한다. 트리거 함수는 아무도 부르지 못한다
-- ─────────────────────────────────────────────
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.suggestion_stale_evidence(public.suggestions)',
    'public.suggestions_produce(uuid, timestamptz, integer, boolean)',
    'public.suggestions_expose(uuid, date, integer, timestamptz)',
    'public.suggestion_transition(uuid, uuid, integer, text, timestamptz, text, timestamptz)',
    'public.return_summary_candidates(uuid, text[], timestamptz)',
    'public.return_summary_digest(uuid, text[], timestamptz)',
    'public.return_summary_scan(uuid, text[], timestamptz, integer)',
    'public.return_summary_clear(uuid, text[], timestamptz, text, timestamptz)',
    'public.suggestions_guard()',
    'public.return_summary_state_guard()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', f);
  end loop;
  foreach f in array array[
    'public.suggestion_stale_evidence(public.suggestions)',
    'public.suggestions_produce(uuid, timestamptz, integer, boolean)',
    'public.suggestions_expose(uuid, date, integer, timestamptz)',
    'public.suggestion_transition(uuid, uuid, integer, text, timestamptz, text, timestamptz)',
    'public.return_summary_candidates(uuid, text[], timestamptz)',
    'public.return_summary_digest(uuid, text[], timestamptz)',
    'public.return_summary_scan(uuid, text[], timestamptz, integer)',
    'public.return_summary_clear(uuid, text[], timestamptz, text, timestamptz)'
  ] loop
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;

commit;
