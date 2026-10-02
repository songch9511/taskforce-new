import { createHash } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";

import { createLocalSupabase } from "../db/local-supabase";

// A29 드라이버 (B2 = Postgres 상태 머신). docs/EXECUTION.md의 실행 가능한 명세이고, U2가 만들 실제 실행기가 아니다 (그래서 src/ 밖에 둔다).
// SQL은 따로 두지 않는다: 운영 마이그레이션(supabase/migrations/20261021000000_execution_core.sql)을 PGlite에 그대로 적용해 시험한다.
// 모든 상태는 DB에 있다. Driver는 메모리에 아무것도 들고 있지 않아서, 중간에 버리고 새로 만들어도 DB만 보고 이어 간다.
// 판단(정규화 · 정책 · 승인 · 스위치 · 허용 목록)은 SQL 함수에만 있다. U2 실행기도 supabase-js에서 같은 RPC를 부른다.

/** 실행 route의 maxDuration(300초) + 여유. begin_call이 DB 시각으로 잰다 (마이그레이션의 330초와 같은 값) */
export const LEASE_SECONDS = 330;
/** 결과 불명이 된 뒤 sweep이 readback을 시도하는 기간. 지나면 사용자가 정한다 */
export const READBACK_WINDOW_HOURS = 24;

/** 시험하는 사용자 (실행 주체 허용 목록 안). 시험 Action · 정책 · 연결은 모두 이 사용자 것이다 */
export const USER = "00000000-0000-0000-0000-0000000000a1";

/** 사례의 이름표('r1', 'r1-s1', 'conn-1')를 고정된 uuid로 바꾼다. 같은 이름표는 늘 같은 uuid다 */
export function uid(label: string): string {
  const h = createHash("md5").update(label).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// 테스트 시계: 운영의 db_now()는 now()뿐이다. 마이그레이션을 적용한 뒤 테스트 안에서만 app.now 판으로 바꾼다
const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;

// 시험에만 있는 것: 가짜 공급자의 외부 효과 원장(실행기 트랜잭션 밖에서만 쓴다, 실제로는 다른 시스템이다),
// 시험 전용 외부 도구(fake.send · fake.reply), 시험 사용자와 보내는 연결 둘
const TEST_SETUP = `
  create schema fake;
  create table fake.ledger (
    id serial primary key, marker text not null, connection_id uuid, recipients jsonb not null, body text not null, visible_at timestamptz not null
  );
  insert into public.execution_tools (provider, tool, effect_class) values ('fake', 'send', 'external'), ('fake', 'reply', 'external');
  insert into auth.users (id, email) values ('${USER}', 'operator@example.com');
  insert into public.connections (id, user_id, provider, external_account_id) values
    ('${uid("conn-1")}', '${USER}', 'gmail', 'me-1@example.com'), ('${uid("conn-2")}', '${USER}', 'gmail', 'me-2@example.com');
`;

// 테스트마다 처음 상태: 스위치는 모두 켜짐(시험 공급자 fake · 내장 taskforce), 시험 사용자는 실행 주체 허용 목록 안,
// 사례의 주소는 모두 수신자 허용 목록 안. 테스트 시계는 2026-10-02 00:00 UTC
const SEED = `
  delete from public.execution_controls;
  insert into public.execution_controls (scope, key) values
    ('global', '*'), ('provider', 'fake'), ('provider', 'taskforce'), ('mode', 'manual'), ('mode', 'auto'), ('mode', 'full');
  insert into public.execution_actors (user_id) values ('${USER}') on conflict do nothing;
  delete from public.execution_recipient_allowlist;
  insert into public.execution_recipient_allowlist (address) values ('rule@example.com'), ('rule2@example.com'), ('other@example.com');
  select set_config('app.now', '2026-10-02T00:00:00Z', false);
`;

export async function createExecutionDb(): Promise<PGlite> {
  const db = await createLocalSupabase();
  await db.exec(TEST_CLOCK + TEST_SETUP + SEED);
  return db;
}

/** 테스트마다 처음 상태로 (DB를 새로 만드는 것보다 빠르다). Action을 지우면 run · step · 승인 · intent · 이벤트가 함께 지워진다 */
export const resetExecutionDb = (db: PGlite) =>
  db.exec("truncate fake.ledger, public.actions, public.execution_policies restart identity cascade;" + SEED);

/** 테스트 시계를 앞으로 돌린다 (DB 시각) */
export const advanceClock = (db: PGlite, ms: number) =>
  db.query("select set_config('app.now', (public.db_now() + make_interval(secs => $1::float8 / 1000))::text, false)", [ms]);

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

  async send(marker: string, connection: string | null, recipients: string[], body: string): Promise<{ id: number }> {
    if (this.reject) throw new Rejected("400 invalid recipient header");
    const { rows } = await this.db.query<{ id: number }>(
      `insert into fake.ledger (marker, connection_id, recipients, body, visible_at)
       values ($1, $2, $3::jsonb, $4, public.db_now() + make_interval(secs => $5::float8 / 1000)) returning id`,
      [marker, connection, JSON.stringify(recipients), body, this.readbackLagMs],
    );
    await this.onAccepted?.();
    return rows[0];
  }

  async readback(marker: string): Promise<{ id: number } | null> {
    const { rows } = await this.db.query<{ id: number }>("select id from fake.ledger where marker = $1 and visible_at <= public.db_now()", [marker]);
    return rows[0] ?? null;
  }
}

type Gate = { gate: string; marker?: string; connection?: string | null; recipients?: string[]; body?: string };
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
    // ① lease가 끝난 calling: 외부 효과는 다시 부르지 않고 결과 불명으로, 내부 효과는 다시 준비
    await this.db.query("select public.sweep_expire()");
    // ② 결과 불명: readback 창 안에서만 표식을 찾는다. 양성이면 called, 음성이면 그대로 (다시 보내지 않는다)
    const unknown = await this.db.query<{ id: string; marker: string }>(
      `select s.id, i.marker from public.execution_steps s join public.execution_intents i on i.step_id = s.id
       where s.state = 'unknown_outcome' and s.unknown_since > public.db_now() - make_interval(hours => ${READBACK_WINDOW_HOURS})`,
    );
    for (const step of unknown.rows) {
      const found = await this.provider.readback(step.marker);
      if (found) await this.db.query("select public.readback_settle($1, $2::jsonb)", [step.id, JSON.stringify({ provider_id: found.id, via: "readback" })]);
    }
    // ③ 깨우기를 놓친 run, 승인이 들어온 승인 대기 run
    const runs = await this.db.query<{ id: string }>(
      "select id from public.execution_runs where state in ('queued', 'running', 'waiting_approval') order by created_at, id",
    );
    for (const run of runs.rows) await this.advance(run.id);
  }

  async showPlan(stepId: string): Promise<ShownPlan> {
    return (await this.db.query<ShownPlan>("select * from public.show_plan($1, $2)", [USER, stepId])).rows[0];
  }

  /** route: POST /approvals/[id]. 사용자가 본 hash가 지금 계획과 다르면 거절한다 */
  async approve(stepId: string, shown: ShownPlan): Promise<boolean> {
    const { rows } = await this.db.query<{ ok: boolean }>("select public.approve_step($1, $2, $3, $4) as ok", [USER, stepId, shown.hash, shown.expires_at]);
    return rows[0].ok;
  }

  async revoke(stepId: string): Promise<void> {
    await this.db.query("select public.revoke_approval($1, $2)", [USER, stepId]);
  }

  /** route: POST /runs/[id]/stop. 다음 단계만 막는다 */
  async stop(runId: string): Promise<void> {
    await this.db.query("select public.stop_run($1, $2)", [USER, runId]);
  }

  /** 함수 호출 한 번 = 단계 하나 */
  private async advance(runId: string): Promise<void> {
    const run = (await this.db.query<{ state: string }>("select state from public.execution_runs where id = $1", [runId])).rows[0];
    if (!["queued", "running", "waiting_approval"].includes(run.state)) return;
    const next = () =>
      this.db.query<{ id: string; state: string; version: number }>(
        "select id, state, version from public.execution_steps where run_id = $1 and state not in ('called', 'skipped') order by seq limit 1",
        [runId],
      );
    let step = (await next()).rows[0];
    if (!step) {
      await this.db.query("select public.finish_run($1)", [runId]);
      return;
    }
    if (step.state === "pending") {
      const prepared = await this.db.query<{ ok: boolean }>("select public.prepare_step($1, $2) as ok", [step.id, step.version]);
      if (!prepared.rows[0].ok) return; // 다른 함수가 먼저 준비했다
      step = (await next()).rows[0];
    }
    if (step.state !== "prepared") return; // calling(다른 함수가 부르는 중) · unknown_outcome(sweep이 확인) · failed

    await this.hooks.beforeBeginCall?.();
    const gate = (await this.db.query<{ g: Gate }>("select public.begin_call($1, $2, $3) as g", [step.id, this.owner, step.version])).rows[0].g;
    await this.hooks.afterGate?.(gate.gate);
    if (gate.gate !== "ok") return;

    // begin_call이 검증해 돌려준 내용만 보낸다. 외부로는 표식만 나가고 intent key는 나가지 않는다. try는 외부 호출만 감싼다
    let sent: { id: number };
    try {
      sent = await this.provider.send(gate.marker!, gate.connection ?? null, gate.recipients!, gate.body!);
    } catch (error) {
      if (error instanceof Crash) throw error;
      if (error instanceof Rejected) {
        await this.db.query("select public.settle_step($1, $2, 'failed', $3::jsonb)", [step.id, this.owner, JSON.stringify({ error: error.message })]);
        return;
      }
      // 시간 초과 · 연결 끊김: 받았는지 모른다. lease를 가진 함수가 결과 불명으로 옮긴다 (다시 부르지 않는다)
      await this.db.query("select public.mark_unknown($1, $2)", [step.id, this.owner]);
      return;
    }
    // 받은 뒤의 DB 오류는 결과 불명이 아니다: 세 번까지 다시 쓰고, 그래도 안 되면 오류를 낸다 (lease 만료 뒤 readback이 확인한다)
    for (let attempt = 1; ; attempt++) {
      try {
        await this.db.query("select public.settle_step($1, $2, 'called', $3::jsonb)", [step.id, this.owner, JSON.stringify({ provider_id: sent.id, via: "response" })]);
        return;
      } catch (error) {
        if (attempt === 3) throw error;
      }
    }
  }
}
