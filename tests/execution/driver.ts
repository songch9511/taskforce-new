import { PGlite } from "@electric-sql/pglite";

// A29 fixture (B2 = Postgres 상태 머신). docs/EXECUTION.md의 실행 가능한 명세이고, U2가 만들 실제 실행기가 아니다 (그래서 src/ 밖에 둔다).
// 모든 상태는 DB에 있다. Driver는 메모리에 아무것도 들고 있지 않아서, 중간에 버리고 새로 만들어도 DB만 보고 이어 간다.
// 판단(정규화 · 정책 · 승인 · 스위치)은 SQL 함수에만 있다. U2도 supabase-js에서 RPC로 부른다 (write_action처럼).

/** 실행 route의 maxDuration(300초) + 여유. 살아 있는 함수의 lease는 만료되지 않는다. 시각은 DB 시각(db_now)으로 잰다 */
export const LEASE_SECONDS = 330;
/** 결과 불명이 된 뒤 sweep이 readback을 시도하는 기간. 지나면 사용자가 정한다 */
export const READBACK_WINDOW_HOURS = 24;

const SCHEMA = `
  -- 테스트 시계: app.now가 있으면 그 시각, 없으면 now(). 운영의 db_now()는 now()뿐이다 (세션 설정은 풀링된 연결에 남을 수 있다)
  create function db_now() returns timestamptz language sql stable as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;

  create table policies (
    id text primary key,
    mode text not null check (mode in ('manual', 'auto', 'full')),
    auto_recipients jsonb not null default '[]', -- Auto/Full 규칙: 승인 없이 보내도 되는 주소
    version int not null default 1
  );
  create table runs (
    id text primary key, action_id text not null, policy_id text not null references policies (id),
    state text not null default 'queued' check (state in ('queued', 'running', 'waiting_approval', 'done', 'failed', 'stopped'))
  );
  create table steps (
    id text primary key, run_id text not null references runs (id), seq int not null, unique (run_id, seq),
    provider text not null, tool text not null, purpose text not null, occurrence int not null default 1,
    connection_id text not null, -- 보내는 연결(계정). 계획의 일부라 pending을 떠나면 바꿀 수 없다
    recipients jsonb not null, -- [{address, origin}], origin: user | source | tool_output | model
    body text not null, args jsonb not null default '{}', source_revision int not null default 1,
    state text not null default 'pending'
      check (state in ('pending', 'prepared', 'calling', 'called', 'unknown_outcome', 'failed', 'skipped')),
    version int not null default 0, policy_version int, needs_approval boolean, intent_key text,
    lease_owner text, lease_expires_at timestamptz, unknown_since timestamptz, receipt jsonb,
    constraint prepared_has_policy_version check (state = 'pending' or policy_version is not null)
  );
  create table approvals (
    id serial primary key, step_id text not null references steps (id), hash text not null, expires_at timestamptz not null, revoked_at timestamptz
  );
  -- 표식(marker)은 외부로 나가는 유일한 값이다: 수신자 · Action id · 본문을 담지 않는 임의 값
  create table intents (
    intent_key text primary key, step_id text not null references steps (id), marker text not null unique default gen_random_uuid()::text
  );
  create table execution_controls (
    scope text not null check (scope in ('global', 'provider', 'mode')), key text not null, blocked boolean not null default false,
    primary key (scope, key)
  );
  -- 가짜 공급자의 외부 효과. 실행기 트랜잭션 밖에서만 쓴다 (실제로는 다른 시스템이다)
  create table provider_ledger (
    id serial primary key, marker text not null, connection_id text not null, recipients jsonb not null, body text not null, visible_at timestamptz not null
  );

  -- 정규화 규칙은 하나: 승인 hash · intent key · Auto 규칙 비교가 모두 이것을 쓴다
  create function norm_address(p text) returns text language sql immutable as $$ select lower(trim(p)) $$;
  create function norm_addresses(p jsonb) returns jsonb language sql immutable as $$
    select coalesce(jsonb_agg(distinct norm_address(x->>'address') order by norm_address(x->>'address')), '[]') from jsonb_array_elements(p) x
  $$;

  -- 승인 없이 나갈 수 있는가: Auto/Full + 모든 수신자가 사용자에게서 + 규칙 안 + 준비할 때의 정책 버전 그대로
  create function auto_allowed(p_step text) returns boolean language sql stable as $$
    select p.mode in ('auto', 'full') and s.policy_version = p.version
      and not exists (select 1 from jsonb_array_elements(s.recipients) x where coalesce(x->>'origin', '') <> 'user')
      and norm_addresses(s.recipients) <@ (select coalesce(jsonb_agg(norm_address(a)), '[]') from jsonb_array_elements_text(p.auto_recipients) a)
    from steps s join runs r on r.id = s.run_id join policies p on p.id = r.policy_id where s.id = p_step
  $$;

  -- 승인 hash: 도구 · 연결 · 인자 · 수신자 · 본문 hash · 원문 revision · 정책 버전 · 만료(UTC, 초 단위). 하나라도 바뀌면 값이 바뀐다
  create function approval_hash(p_step text, p_expires timestamptz) returns text language sql stable as $$
    select encode(sha256(convert_to(jsonb_build_object(
      'tool', s.tool, 'connection', s.connection_id, 'args', s.args, 'recipients', norm_addresses(s.recipients),
      'body_sha256', encode(sha256(convert_to(s.body, 'UTF8')), 'hex'), 'source_revision', s.source_revision, 'policy_version', p.version,
      'expires_at', to_char(date_trunc('second', p_expires) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))::text, 'UTF8')), 'hex')
    from steps s join runs r on r.id = s.run_id join policies p on p.id = r.policy_id where s.id = p_step
  $$;

  -- 계획(도구 · 연결 · 수신자 · 본문 · 인자 · 원문 revision)을 바꾸면 늘 pending으로 되돌리고 version을 올린다. 부르는 중 · 끝난 단계는 못 바꾼다
  create function steps_replan() returns trigger language plpgsql as $$
  begin
    if (new.provider, new.tool, new.connection_id, new.recipients, new.body, new.args, new.source_revision)
       is distinct from (old.provider, old.tool, old.connection_id, old.recipients, old.body, old.args, old.source_revision) then
      if old.state not in ('pending', 'prepared') then raise exception 'step % is %: plan is frozen', old.id, old.state; end if;
      new.state := 'pending'; new.version := old.version + 1;
      new.intent_key := null; new.policy_version := null; new.needs_approval := null;
    end if;
    return new;
  end $$;
  create trigger steps_replan before update on steps for each row execute function steps_replan();

  -- pending → prepared: intent key · 정책 버전 · 승인 필요 표시
  create function prepare_step(p_step text, p_version int) returns boolean language plpgsql as $$
  begin
    update steps s set state = 'prepared', version = s.version + 1, policy_version = p.version,
      intent_key = concat_ws('|', r.action_id, s.provider, s.tool, s.purpose, norm_addresses(s.recipients)::text, s.occurrence)
    from runs r join policies p on p.id = r.policy_id
    where s.id = p_step and s.state = 'pending' and s.version = p_version and r.id = s.run_id;
    if not found then return false; end if;
    update steps set needs_approval = auto_allowed(id) is not true where id = p_step;
    update runs set state = 'running' where id = (select run_id from steps where id = p_step) and state = 'queued';
    return true;
  end $$;

  -- route: 사용자가 본 계획의 hash. 승인할 때 다시 계산해 같아야 기록한다. 만료는 초 단위 (앱의 Date는 밀리초라 마이크로초가 사라진다)
  create function show_plan(p_step text) returns table (hash text, expires_at timestamptz) language sql stable as $$
    select approval_hash(p_step, e), e from (select date_trunc('second', db_now() + interval '1 hour') as e) t
  $$;
  create function approve_step(p_step text, p_shown_hash text, p_expires timestamptz) returns boolean language plpgsql as $$
  begin
    if p_expires <= db_now() or approval_hash(p_step, p_expires) is distinct from p_shown_hash then return false; end if;
    insert into approvals (step_id, hash, expires_at) values (p_step, p_shown_hash, p_expires);
    update runs set state = 'running' where id = (select run_id from steps where id = p_step) and state = 'waiting_approval';
    return true;
  end $$;

  -- prepared → calling. RPC 하나 = READ COMMITTED 트랜잭션 하나, 외부 호출 전에 commit된다 (외부 호출은 이 안에 없다).
  -- 중복 · 차단 스위치 · 승인/Auto 규칙 · intent · lease · run 전이를 여기서만 정한다. 검증한 그대로의 내용을 돌려준다
  create function begin_call(p_step text, p_owner text, p_version int) returns jsonb language plpgsql as $$
  declare
    s steps; r runs; p policies; held text; m text; locked int; blocked boolean;
  begin
    select * into s from steps where id = p_step for update;
    if not found or s.state <> 'prepared' or s.version <> p_version then return '{"gate": "stale"}'; end if;
    select * into r from runs where id = s.run_id for no key update;
    if r.state = 'stopped' then return '{"gate": "stopped"}'; end if;
    if r.state not in ('running', 'waiting_approval') then return '{"gate": "stale"}'; end if;
    select * into p from policies where id = r.policy_id for share;

    -- 같은 목적을 다른 단계가 이미 가졌으면 승인을 묻지 않고 건너뛴다
    select step_id into held from intents where intent_key = s.intent_key;
    if held is not null and held <> s.id then
      update steps set state = 'skipped', version = version + 1, receipt = jsonb_build_object('duplicate_of', held) where id = s.id;
      update runs set state = 'running' where id = r.id and state = 'waiting_approval'; -- 승인을 기다릴 이유가 없어졌다
      return '{"gate": "duplicate"}';
    end if;

    -- 차단 스위치: 세 행을 잠그고(for share) 읽는다. 끄는 쪽의 update는 이 트랜잭션이 끝날 때까지 기다린다. 행이 없으면 막힘
    select count(*), coalesce(bool_or(c.blocked), false) into locked, blocked from (
      select e.blocked from execution_controls e where (e.scope, e.key) in (('global', '*'), ('provider', s.provider), ('mode', p.mode)) for share
    ) c;
    if locked < 3 or blocked then return '{"gate": "blocked"}'; end if;

    -- 유효한 승인이 없으면 Auto/Full 규칙을 지금 다시 확인한다 (준비 단계의 needs_approval을 믿지 않는다)
    if auto_allowed(s.id) is not true and not exists ( -- NULL(모름)이면 막는다
      select 1 from approvals a
      where a.step_id = s.id and a.revoked_at is null and a.expires_at > db_now() and a.hash = approval_hash(s.id, a.expires_at)
    ) then
      update runs set state = 'waiting_approval' where id = r.id and state = 'running';
      return '{"gate": "not_approved"}';
    end if;
    update runs set state = 'running' where id = r.id and state = 'waiting_approval';

    insert into intents (intent_key, step_id) values (s.intent_key, s.id) on conflict (intent_key) do nothing returning marker into m;
    if m is null then -- 위 확인과 이 insert 사이에 다른 단계가 먼저 commit했다
      select step_id into held from intents where intent_key = s.intent_key;
      update steps set state = 'skipped', version = version + 1, receipt = jsonb_build_object('duplicate_of', held) where id = s.id;
      return '{"gate": "duplicate"}';
    end if;
    update steps set state = 'calling', version = version + 1, lease_owner = p_owner,
      lease_expires_at = db_now() + make_interval(secs => ${LEASE_SECONDS}) where id = s.id;
    return jsonb_build_object('gate', 'ok', 'marker', m, 'connection', s.connection_id, 'recipients', norm_addresses(s.recipients), 'body', s.body, 'args', s.args);
  end $$;
`;

// 처음 상태: 스위치 행은 모두 켜짐, 테스트 시계는 2026-10-02 00:00 UTC
const SEED = `
  insert into execution_controls (scope, key) values
    ('global', '*'), ('provider', 'gmail'), ('mode', 'manual'), ('mode', 'auto'), ('mode', 'full');
  select set_config('app.now', '2026-10-02T00:00:00Z', false);
`;

export async function createExecutionDb(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(SCHEMA + SEED);
  return db;
}

/** 테스트마다 처음 상태로 (DB를 새로 만드는 것보다 빠르다) */
export const resetExecutionDb = (db: PGlite) =>
  db.exec("truncate provider_ledger, intents, approvals, steps, runs, policies, execution_controls restart identity cascade;" + SEED);

/** 테스트 시계를 앞으로 돌린다 (DB 시각) */
export const advanceClock = (db: PGlite, ms: number) =>
  db.query("select set_config('app.now', (db_now() + make_interval(secs => $1::float8 / 1000))::text, false)", [ms]);

/** 함수가 그 자리에서 죽었다 (테스트는 이 Driver를 버린다) */
export class Crash extends Error {}
/** 공급자가 확정적으로 거절했다 (예: 형식 오류 400) */
export class Rejected extends Error {}

export class FakeProvider {
  /** 받은 효과가 readback에 보이기까지 걸리는 시간 (Gmail history · 색인 지연) */
  readbackLagMs = 0;
  reject = false;
  /** 공급자가 효과를 받은 직후 (응답이 돌아가기 전) */
  onAccepted?: () => void | Promise<void>;

  constructor(private db: PGlite) {}

  async send(marker: string, connection: string, recipients: string[], body: string): Promise<{ id: number }> {
    if (this.reject) throw new Rejected("400 invalid recipient header");
    const { rows } = await this.db.query<{ id: number }>(
      `insert into provider_ledger (marker, connection_id, recipients, body, visible_at)
       values ($1, $2, $3::jsonb, $4, db_now() + make_interval(secs => $5::float8 / 1000)) returning id`,
      [marker, connection, JSON.stringify(recipients), body, this.readbackLagMs],
    );
    await this.onAccepted?.();
    return rows[0];
  }

  async readback(marker: string): Promise<{ id: number } | null> {
    const { rows } = await this.db.query<{ id: number }>("select id from provider_ledger where marker = $1 and visible_at <= db_now()", [marker]);
    return rows[0] ?? null;
  }
}

type Gate = { gate: string; marker?: string; connection?: string; recipients?: string[]; body?: string };
type Hooks = { beforeBeginCall?: () => Promise<void>; afterGate?: (gate: string) => void | Promise<void> };
export type ShownPlan = { hash: string; expires_at: Date };

export class Driver {
  constructor(
    private db: PGlite,
    readonly owner: string,
    private provider: FakeProvider,
    private hooks: Hooks = {},
  ) {}

  // 입구: route(POST /runs · 승인 뒤)와 자기 호출(commit 뒤 깨우기)은 advance, cron은 sweep. 모두 begin_call 하나를 지난다
  start = (runId: string) => this.advance(runId);
  wake = (runId: string) => this.advance(runId);

  async sweep(): Promise<void> {
    // ① lease가 끝난 calling: 다시 부르지 않고 결과 불명으로
    await this.db.query(
      `update steps set state = 'unknown_outcome', unknown_since = db_now(), version = version + 1, lease_owner = null
       where state = 'calling' and lease_expires_at < db_now()`,
    );
    // ② 결과 불명: readback 창 안에서만 표식을 찾는다. 양성이면 called, 음성이면 그대로 (다시 보내지 않는다)
    const unknown = await this.db.query<{ id: string; marker: string }>(
      `select s.id, i.marker from steps s join intents i on i.step_id = s.id
       where s.state = 'unknown_outcome' and s.unknown_since > db_now() - make_interval(hours => ${READBACK_WINDOW_HOURS})`,
    );
    for (const step of unknown.rows) {
      const found = await this.provider.readback(step.marker);
      if (found) await this.settle(step.id, "called", { provider_id: found.id, via: "readback" }, null);
    }
    // ③ 깨우기를 놓친 run, 승인이 들어온 승인 대기 run
    const runs = await this.db.query<{ id: string }>("select id from runs where state in ('queued', 'running', 'waiting_approval') order by id");
    for (const run of runs.rows) await this.advance(run.id);
  }

  async showPlan(stepId: string): Promise<ShownPlan> {
    return (await this.db.query<ShownPlan>("select * from show_plan($1)", [stepId])).rows[0];
  }

  /** route: POST /approvals/[id]. 사용자가 본 hash가 지금 계획과 다르면 거절한다 */
  async approve(stepId: string, shown: ShownPlan): Promise<boolean> {
    const { rows } = await this.db.query<{ ok: boolean }>("select approve_step($1, $2, $3) as ok", [stepId, shown.hash, shown.expires_at]);
    return rows[0].ok;
  }

  async revoke(stepId: string): Promise<void> {
    await this.db.query("update approvals set revoked_at = db_now() where step_id = $1 and revoked_at is null", [stepId]);
  }

  /** route: POST /runs/[id]/stop. 다음 단계만 막는다 */
  async stop(runId: string): Promise<void> {
    await this.db.query("update runs set state = 'stopped' where id = $1 and state in ('queued', 'running', 'waiting_approval')", [runId]);
  }

  /** 함수 호출 한 번 = 단계 하나 */
  private async advance(runId: string): Promise<void> {
    const run = (await this.db.query<{ state: string }>("select state from runs where id = $1", [runId])).rows[0];
    if (!["queued", "running", "waiting_approval"].includes(run.state)) return;
    const next = () =>
      this.db.query<{ id: string; state: string; version: number }>(
        "select id, state, version from steps where run_id = $1 and state not in ('called', 'skipped') order by seq limit 1",
        [runId],
      );
    let step = (await next()).rows[0];
    if (!step) {
      await this.db.query("update runs set state = 'done' where id = $1 and state = 'running'", [runId]);
      return;
    }
    if (step.state === "pending") {
      const prepared = await this.db.query<{ ok: boolean }>("select prepare_step($1, $2) as ok", [step.id, step.version]);
      if (!prepared.rows[0].ok) return; // 다른 함수가 먼저 준비했다
      step = (await next()).rows[0];
    }
    if (step.state !== "prepared") return; // calling(다른 함수가 부르는 중) · unknown_outcome(sweep이 확인) · failed

    await this.hooks.beforeBeginCall?.();
    const gate = (await this.db.query<{ g: Gate }>("select begin_call($1, $2, $3) as g", [step.id, this.owner, step.version])).rows[0].g;
    await this.hooks.afterGate?.(gate.gate);
    if (gate.gate !== "ok") return;

    // begin_call이 검증해 돌려준 내용만 보낸다. 외부로는 표식만 나가고 intent key는 나가지 않는다. try는 외부 호출만 감싼다
    let sent: { id: number };
    try {
      sent = await this.provider.send(gate.marker!, gate.connection!, gate.recipients!, gate.body!);
    } catch (error) {
      if (error instanceof Crash) throw error;
      if (error instanceof Rejected) return this.settle(step.id, "failed", { error: error.message }, this.owner);
      // 시간 초과 · 연결 끊김: 받았는지 모른다. lease를 가진 함수가 결과 불명으로 옮긴다 (다시 부르지 않는다)
      await this.db.query(
        `update steps set state = 'unknown_outcome', unknown_since = db_now(), version = version + 1, lease_owner = null
         where id = $1 and state = 'calling' and lease_owner = $2`,
        [step.id, this.owner],
      );
      return;
    }
    // 받은 뒤의 DB 오류는 결과 불명이 아니다: 세 번까지 다시 쓰고, 그래도 안 되면 오류를 낸다 (lease 만료 뒤 readback이 확인한다)
    for (let attempt = 1; ; attempt++) {
      try {
        return await this.settle(step.id, "called", { provider_id: sent.id, via: "response" }, this.owner);
      } catch (error) {
        if (attempt === 3) throw error;
      }
    }
  }

  /** calling(owner = lease 소유자) 또는 unknown_outcome(owner = null, readback)에서 끝 상태로 */
  private async settle(stepId: string, state: "called" | "failed", receipt: object, owner: string | null): Promise<void> {
    const from = owner === null ? "state = 'unknown_outcome'" : "state = 'calling' and lease_owner = $4";
    const { rows } = await this.db.query<{ run_id: string }>(
      `update steps set state = $3, receipt = $2::jsonb, version = version + 1, lease_owner = null, lease_expires_at = null
       where id = $1 and ${from} returning run_id`,
      [stepId, JSON.stringify(receipt), state, ...(owner === null ? [] : [owner])],
    );
    if (rows.length === 0) return;
    await this.db.query(
      `update runs set state = $2 where id = $1 and state = 'running'
       and ($2 = 'failed' or not exists (select 1 from steps where run_id = $1 and state not in ('called', 'skipped')))`,
      [rows[0].run_id, state === "failed" ? "failed" : "done"],
    );
  }
}
