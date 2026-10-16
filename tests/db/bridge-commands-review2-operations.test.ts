import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, expect, it } from "vitest";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

let db: PGlite;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
const f = bridgeCommandFixtures(() => ({ query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows, asUser: (user, fn) => asUser(db, user, fn) }));
const body = async (name: string) => String((await f.one("select prosrc from pg_proc where proname=$1", [name])).prosrc);

it("review2 heartbeat sweep reports isolated failures and warns with only bridge identity", async () => {
  const bad = await f.world(), good = await f.world();
  await f.lease(bad); await f.lease(good);
  await f.q("update public.bridges set last_heartbeat_at='2000-01-01' where id=any($1)", [[bad.bridge, good.bridge]]);
  await f.q(`create function public.review2_fail_bridge() returns trigger language plpgsql as $$ begin if new.id='${bad.session}'::uuid then raise exception 'private failure text'; end if; return new; end $$`);
  await f.q("create trigger review2_fail_bridge before update on public.agent_sessions for each row execute function public.review2_fail_bridge()");
  try {
    const rows = await f.q("select * from public.sweep_bridge_heartbeats(null,1000)");
    expect(rows).toContainEqual({user_id:null,bridge_id:null,agent_session_id:null,agent_task_id:null,turn_seq:null,failure_count:1});
    expect(rows).toContainEqual({user_id:good.user,bridge_id:good.bridge,agent_session_id:good.session,agent_task_id:good.task,turn_seq:1,failure_count:0});
    expect(await f.one("select status from public.agent_sessions where id=$1", [bad.session])).toEqual({status:"bound"});
    const source = await body("sweep_bridge_heartbeats");
    expect(source.match(/raise warning[^;]+;/gi)).toEqual(["raise warning 'sweep_bridge_heartbeats: bridge %', b.id;"]);
  } finally {
    await f.q("drop trigger review2_fail_bridge on public.agent_sessions");
    await f.q("drop function public.review2_fail_bridge()");
  }
});

it("review2 lease sweep ignores caller clocks in both directions", async () => {
  const w = await f.world(); await f.lease(w);
  expect(await f.one("select public.sweep_agent_step_leases('2100-01-01') as count")).toEqual({count:0});
  expect(await f.one("select state from public.execution_steps where id=$1", [w.step])).toEqual({state:"calling"});
  await f.updateRow("execution_steps", w.step, {lease_expires_at:"2000-01-01"});
  expect(await f.one("select public.sweep_agent_step_leases('1900-01-01') as count")).toEqual({count:1});
  expect(await f.one("select state from public.execution_steps where id=$1", [w.step])).toEqual({state:"unknown_outcome"});
});

it("review2 actual bridge rate query naturally uses device index", async () => {
  const user = await f.user();
  const bridges: string[] = [];
  for (let i=0; i<100; i++) bridges.push(await f.bridge(user));
  // F1s 항목 8: 자료와 기준 시각을 고정해 통계가 실행마다 같게 한다. 이 파일 전용 PGlite라 표를 비워도 된다.
  // 예전 실패 9번 중 2번은 계획이 아니라 test 5초 제한 초과였다(적재 100+30,000행이 느린 기계에서 5초를 넘는다): 제한을 이 시험에만 늘린다.
  const base = "2026-10-15T00:00:00Z";
  await f.q("delete from public.rate_limit_events");
  await f.q("insert into public.rate_limit_events(user_id,bridge_id,kind,created_at) select $1,b,'bridge_poll',$2::timestamptz-n*interval '0.1 second' from unnest($3::uuid[]) b cross join generate_series(1,300) n order by b,n", [user,base,bridges]);
  const source = await body("take_rate_limit");
  const query = source.match(/select e.created_at into v_nth from public.rate_limit_events e[\s\S]*?limit 1;/)![0]
    .replace("into v_nth ", "").replaceAll("p_user_id", "$1::uuid").replaceAll("p_kind", "$2::text")
    .replaceAll("p_bridge_id", "$3::uuid").replaceAll("v_since", "$4::timestamptz").replaceAll("p_max", "90");
  const since = new Date(Date.parse(base) - 60_000).toISOString();
  const plans: string[] = [];
  await f.q("set default_statistics_target = 1000"); // 표본이 전 행이라 통계가 같다
  try {
    for (let i=0; i<3; i++) {
      await f.q("analyze public.rate_limit_events");
      plans.push((await f.q(`explain (costs off) ${query}`, [user,"bridge_poll",bridges[0],since])).map(row=>row["QUERY PLAN"]).join("\n"));
    }
  } finally {
    await f.q("reset default_statistics_target");
  }
  console.info("review2 rate-limit EXPLAIN (100 bridges x 300 rows):\n" + plans[0]);
  expect(plans[1]).toBe(plans[0]);
  expect(plans[2]).toBe(plans[0]);
  expect(plans[0]).toContain("rate_limit_events_bridge_idx");
  expect(plans[0]).toMatch(/Index Cond:.*bridge_id/);
}, 60_000);

it("review3 registration caps new rows and reactivation while preserving rotation", async () => {
  const user = await f.user();
  const register = async (device: string, reactivate=false) => (await f.one("select public.register_bridge($1,$2,$3,'1',$4::jsonb,'{}'::text[],$5) as result", [user,device,"a".repeat(64),JSON.stringify({adapters:{}}),reactivate])).result;
  const revoked = await f.bridge(user);
  await f.q("select public.revoke_bridge($1,$2)", [user,revoked]);
  const device = String((await f.one("select device_ref from public.bridges where id=$1", [revoked])).device_ref);
  for(let i=0;i<10;i++) expect(await register(`active-${i}`)).toMatchObject({status:"registered"});
  expect(await register(randomUUID())).toEqual({status:"too_many_bridges"});
  expect(await register("active-0")).toMatchObject({status:"rotated"});
  expect(await register(device)).toMatchObject({status:"revoked"});
  const before = await f.q("select * from public.bridges where user_id=$1 order by id", [user]);
  expect(await register(device,true)).toEqual({status:"too_many_bridges"});
  expect(await f.q("select * from public.bridges where user_id=$1 order by id", [user])).toEqual(before);
  expect(await f.one("select count(*)::int as count from public.bridges where user_id=$1 and status='active'", [user])).toEqual({count:10});
  expect(await register(randomUUID())).toEqual({status:"too_many_bridges"});
  await f.q("select public.revoke_bridge($1,id) from public.bridges where user_id=$1 and device_ref='active-0'", [user]);
  expect(await register(device,true)).toMatchObject({status:"reactivated"});
  expect(await f.one("select count(*)::int as count from public.bridges where user_id=$1 and status='active'", [user])).toEqual({count:10});
});

it("review2 heartbeat only locks runs with live or reported tasks", async () => {
  const source = await body("bridge_heartbeat");
  const runLock = source.match(/for r in select[\s\S]*?for no key update loop/)![0];
  expect(runLock).toContain("exists(select 1 from public.agent_tasks");
  expect(runLock).toContain("state in ('dispatched','accepted','running','awaiting_answer','unreachable')");
  expect(runLock).toContain("jsonb_array_elements(p_tasks)");
});
