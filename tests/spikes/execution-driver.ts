import { PGlite } from "@electric-sql/pglite";

// A29 fixture (B2 = Postgres 상태 머신). docs/EXECUTION.md의 실행 가능한 명세이고, U2가 만들 실제 실행기가 아니다 (그래서 src/ 밖에 둔다).
// 모든 상태는 DB에 있다. Driver는 메모리에 아무것도 들고 있지 않아서, 중간에 버리고 새로 만들어도 DB만 보고 이어 간다.

/** maxDuration 300초 + 여유: 살아 있는 함수의 lease는 만료되지 않는다 */
export const LEASE_MS = 330_000;

const SCHEMA = `
  create table runs (
    id text primary key, action_id text not null,
    mode text not null check (mode in ('manual', 'auto', 'full')),
    auto_recipients jsonb not null default '[]', -- Auto 규칙: 승인 없이 보내도 되는 수신자
    policy_version int not null default 1,
    state text not null default 'queued' check (state in ('queued', 'running', 'waiting_approval', 'done', 'failed', 'stopped'))
  );
  create table steps (
    id text primary key, run_id text not null references runs (id), seq int not null, unique (run_id, seq),
    provider text not null, tool text not null, purpose text not null, occurrence int not null default 1,
    args jsonb not null, recipient_origin text not null check (recipient_origin in ('user', 'source', 'tool_output')),
    source_revision int not null default 1,
    state text not null default 'pending'
      check (state in ('pending', 'prepared', 'calling', 'called', 'unknown_outcome', 'failed', 'skipped')),
    version int not null default 0, needs_approval boolean, intent_key text,
    lease_owner text, lease_expires_at timestamptz, receipt jsonb
  );
  create table approvals (
    id serial primary key, step_id text not null references steps (id), hash text not null, expires_at timestamptz not null, revoked_at timestamptz
  );
  create table intents (intent_key text primary key, step_id text not null references steps (id));
  create table execution_controls (
    scope text not null check (scope in ('global', 'provider', 'mode')), key text not null, blocked boolean not null default false,
    primary key (scope, key)
  );
  insert into execution_controls (scope, key) values
    ('global', '*'), ('provider', 'gmail'), ('mode', 'manual'), ('mode', 'auto'), ('mode', 'full');
  -- 가짜 공급자의 외부 효과. 실행기 트랜잭션 밖에서만 쓴다 (실제로는 다른 시스템이다)
  create table provider_ledger (id serial primary key, marker text not null, recipients jsonb not null, visible_at timestamptz not null);

  -- 승인 hash: 도구 · 인자 · 수신자(정규화) · 본문 hash · 원문 revision · 정책 버전 · 만료. 하나라도 바뀌면 값이 바뀐다
  create function approval_hash(p_step text, p_expires timestamptz) returns text language sql stable as $$
    select encode(sha256(convert_to(jsonb_build_object(
      'tool', s.tool,
      'args', s.args - 'to' - 'body',
      'recipients', (select jsonb_agg(lower(trim(t)) order by lower(trim(t))) from jsonb_array_elements_text(s.args->'to') t),
      'body_sha256', encode(sha256(convert_to(s.args->>'body', 'UTF8')), 'hex'),
      'source_revision', s.source_revision,
      'policy_version', r.policy_version,
      'expires_at', p_expires)::text, 'UTF8')), 'hex')
    from steps s join runs r on r.id = s.run_id where s.id = p_step
  $$;

  -- prepared → calling. 차단 스위치 · 승인 · intent · CAS를 한 트랜잭션(이 함수 하나)에서 확인한다.
  -- route · 자기 호출 · sweep 모두 이 함수만 지나서 외부를 부른다
  create function begin_call(p_step text, p_owner text, p_version int, p_now timestamptz, p_lease_until timestamptz)
  returns text language plpgsql as $$
  declare
    s steps;
    r runs;
    locked int;
    blocked boolean;
    holder text;
  begin
    select * into s from steps where id = p_step for update;
    if s.state <> 'prepared' or s.version <> p_version then return 'stale'; end if;
    select * into r from runs where id = s.run_id for share;
    if r.state = 'stopped' then return 'stopped'; end if;
    -- 세 행을 잠그고(for share) 읽는다: 끄는 쪽의 update는 이 트랜잭션이 끝날 때까지 기다린다. 행이 없으면 막힌 것으로 본다
    select count(*), coalesce(bool_or(c.blocked), false) into locked, blocked from (
      select e.blocked from execution_controls e
      where (e.scope, e.key) in (('global', '*'), ('provider', s.provider), ('mode', r.mode)) for share
    ) c;
    if locked < 3 or blocked then return 'blocked'; end if;
    -- 원문 · 도구 출력에서 나온 수신자는 준비 단계의 판단과 상관없이 승인이 있어야 한다 (불변식을 DB에서 다시 막는다)
    if s.needs_approval or s.recipient_origin <> 'user' or r.mode = 'manual' then
      if not exists (
        select 1 from approvals a
        where a.step_id = s.id and a.revoked_at is null and a.expires_at > p_now and a.hash = approval_hash(s.id, a.expires_at)
      ) then return 'not_approved'; end if;
    end if;
    insert into intents (intent_key, step_id) values (s.intent_key, s.id) on conflict (intent_key) do nothing;
    select i.step_id into holder from intents i where i.intent_key = s.intent_key;
    if holder <> s.id then
      update steps set state = 'skipped', version = version + 1, receipt = jsonb_build_object('duplicate_of', holder) where id = s.id;
      return 'duplicate';
    end if;
    update steps set state = 'calling', version = version + 1, lease_owner = p_owner, lease_expires_at = p_lease_until where id = s.id;
    return 'ok';
  end $$;
`;

export async function createExecutionDb(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(SCHEMA);
  return db;
}

export class Clock {
  now = Date.parse("2026-10-02T00:00:00Z");
  date = (offsetMs = 0) => new Date(this.now + offsetMs);
}

/** 함수가 그 자리에서 죽었다 (테스트는 이 Driver를 버린다) */
export class Crash extends Error {}

export class FakeProvider {
  /** 받은 효과가 재조회에 보이기까지 걸리는 시간 (Gmail history · 검색 색인 지연) */
  readbackLagMs = 0;
  /** 공급자가 효과를 받은 직후 (응답이 돌아가기 전) */
  onAccepted?: () => void | Promise<void>;

  constructor(
    private db: PGlite,
    private clock: Clock,
  ) {}

  async send(marker: string, to: string[]): Promise<{ id: number }> {
    const { rows } = await this.db.query<{ id: number }>(
      "insert into provider_ledger (marker, recipients, visible_at) values ($1, $2::jsonb, $3) returning id",
      [marker, JSON.stringify(to), this.clock.date(this.readbackLagMs)],
    );
    await this.onAccepted?.();
    return rows[0];
  }

  async readback(marker: string): Promise<{ id: number } | null> {
    const { rows } = await this.db.query<{ id: number }>("select id from provider_ledger where marker = $1 and visible_at <= $2", [
      marker,
      this.clock.date(),
    ]);
    return rows[0] ?? null;
  }
}

type Run = { id: string; action_id: string; mode: "manual" | "auto" | "full"; auto_recipients: string[]; state: string };
type Step = {
  id: string;
  purpose: string;
  occurrence: number;
  args: { to: string[]; body: string };
  recipient_origin: "user" | "source" | "tool_output";
  state: string;
  version: number;
  intent_key: string | null;
};
type Hooks = { afterPrepare?: () => void; beforeBeginCall?: () => Promise<void> };

/** intent key = (Action · 목적 · 정규화한 대상 · 회차). DB unique */
export const intentKey = (actionId: string, purpose: string, to: string[], occurrence: number) =>
  [actionId, purpose, [...new Set(to.map((t) => t.trim().toLowerCase()))].sort().join(","), occurrence].join("|");

export class Driver {
  constructor(
    private db: PGlite,
    readonly owner: string,
    private provider: FakeProvider,
    private clock: Clock,
    private hooks: Hooks = {},
  ) {}

  // 입구 셋. route(POST /runs · 승인 뒤)와 자기 호출(commit 뒤 깨우기)은 advance, cron은 sweep. 모두 begin_call을 지난다
  start = (runId: string) => this.advance(runId);
  wake = (runId: string) => this.advance(runId);

  async sweep(): Promise<void> {
    // ① lease가 끝난 calling: 다시 부르지 않고 결과 불명으로
    await this.db.query(
      "update steps set state = 'unknown_outcome', version = version + 1, lease_owner = null where state = 'calling' and lease_expires_at < $1",
      [this.clock.date()],
    );
    // ② 결과 불명: readback 양성이면 called. 음성이면 그대로 둔다 (비멱등 효과는 재발송하지 않는다)
    const unknown = await this.db.query<Step>("select * from steps where state = 'unknown_outcome'");
    for (const step of unknown.rows) {
      const found = await this.provider.readback(step.intent_key!);
      if (found) await this.finish(step.id, { provider_id: found.id, via: "readback" }, "state = 'unknown_outcome'", []);
    }
    // ③ 깨우기를 놓친 run
    const runs = await this.db.query<{ id: string }>("select id from runs where state in ('queued', 'running') order by id");
    for (const run of runs.rows) await this.advance(run.id);
  }

  /** route: POST /approvals/[id]. 지금 계획의 hash에 묶는다 */
  async approve(stepId: string, expiresInMs = 3_600_000): Promise<void> {
    await this.db.query("insert into approvals (step_id, hash, expires_at) values ($1, approval_hash($1, $2), $2)", [stepId, this.clock.date(expiresInMs)]);
    await this.db.query("update runs set state = 'running' where id = (select run_id from steps where id = $1) and state = 'waiting_approval'", [stepId]);
  }

  async revoke(stepId: string): Promise<void> {
    await this.db.query("update approvals set revoked_at = $2 where step_id = $1 and revoked_at is null", [stepId, this.clock.date()]);
  }

  /** route: POST /runs/[id]/stop. 다음 단계만 막는다 */
  async stop(runId: string): Promise<void> {
    await this.db.query("update runs set state = 'stopped' where id = $1 and state in ('queued', 'running', 'waiting_approval')", [runId]);
  }

  /** 함수 호출 한 번 = 단계 하나 */
  private async advance(runId: string): Promise<void> {
    const run = (await this.db.query<Run>("select * from runs where id = $1", [runId])).rows[0];
    if (run.state !== "queued" && run.state !== "running") return;
    let step: Step | undefined = (
      await this.db.query<Step>("select * from steps where run_id = $1 and state not in ('called', 'skipped') order by seq limit 1", [runId])
    ).rows[0];
    if (!step) {
      await this.db.query("update runs set state = 'done' where id = $1 and state = 'running'", [runId]);
      return;
    }
    if (step.state === "pending") {
      step = await this.prepare(run, step);
      if (!step) return;
      this.hooks.afterPrepare?.();
    }
    if (step.state !== "prepared") return; // calling(다른 함수가 부르는 중) · unknown_outcome(sweep이 확인) · failed

    await this.hooks.beforeBeginCall?.();
    const { rows } = await this.db.query<{ gate: string }>("select begin_call($1, $2, $3, $4, $5) as gate", [
      step.id,
      this.owner,
      step.version,
      this.clock.date(),
      this.clock.date(LEASE_MS),
    ]);
    if (rows[0].gate === "not_approved") await this.db.query("update runs set state = 'waiting_approval' where id = $1 and state = 'running'", [runId]);
    if (rows[0].gate !== "ok") return;

    const sent = await this.provider.send(step.intent_key!, step.args.to);
    await this.finish(step.id, { provider_id: sent.id, via: "response" }, "state = 'calling' and lease_owner = $3", [this.owner]);
  }

  private async prepare(run: Run, step: Step): Promise<Step | undefined> {
    // 불변식: 원문 · 도구 출력에서 나온 수신자는 Auto/Full 규칙을 자동으로 충족하지 못한다
    const auto = run.mode !== "manual" && step.recipient_origin === "user" && step.args.to.every((to) => run.auto_recipients.includes(to));
    const { rows } = await this.db.query<Step>(
      `update steps set state = 'prepared', intent_key = $2, needs_approval = $3, version = version + 1
       where id = $1 and state = 'pending' and version = $4 returning *`,
      [step.id, intentKey(run.action_id, step.purpose, step.args.to, step.occurrence), !auto, step.version],
    );
    if (rows.length > 0) await this.db.query("update runs set state = 'running' where id = $1 and state = 'queued'", [run.id]);
    return rows[0]; // 없으면 다른 함수가 먼저 준비했다
  }

  private async finish(stepId: string, receipt: object, where: string, params: unknown[]): Promise<void> {
    const { rows } = await this.db.query<{ run_id: string }>(
      `update steps set state = 'called', receipt = $2::jsonb, version = version + 1, lease_owner = null, lease_expires_at = null
       where id = $1 and ${where} returning run_id`,
      [stepId, JSON.stringify(receipt), ...params],
    );
    if (rows.length === 0) return;
    await this.db.query(
      `update runs set state = 'done' where id = $1 and state = 'running'
       and not exists (select 1 from steps where run_id = $1 and state not in ('called', 'skipped'))`,
      [rows[0].run_id],
    );
  }
}
