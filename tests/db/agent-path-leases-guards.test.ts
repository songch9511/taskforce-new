import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
const sql=readFileSync(new URL("../../supabase/migrations/20261123000000_agent_path_leases.sql",import.meta.url),"utf8");
const body=(name:string)=>sql.split(`create function public.${name}(`)[1]?.split("$$;")[0] ?? "";
it("static P2 path keys are acquired in sorted order",()=>{
  expect(body("decide_agent_tool_call")).toMatch(/jsonb_array_elements\(p_decision->'targets'\) order by key loop/);
});
it("static P3/P4 shared session then run then task precede lease locks",()=>{
  const fn=body("decide_agent_tool_call");
  const session=fn.indexOf("where id=p_session_id and user_id=p_user_id for share");
  const run=fn.indexOf("where id=t.run_id and user_id=p_user_id for share");
  const task=fn.indexOf("where id=p_task_id and user_id=p_user_id for share");
  const lease=fn.indexOf("and released_at is null for update");
  expect(session).toBeGreaterThan(-1);expect(run).toBeGreaterThan(session);expect(task).toBeGreaterThan(run);expect(lease).toBeGreaterThan(task);
  expect(fn).toContain("set lock_timeout = '250ms'");
});
it("static P9 conflict Stop orders run then cancellation then lease and never locks Action",()=>{
  const fn=body("stop_agent_run_for_path_conflict");
  expect(fn.indexOf("for no key update")).toBeGreaterThan(-1);
  expect(fn.indexOf("public.request_agent_task_cancel")).toBeGreaterThan(fn.indexOf("for no key update"));
  expect(fn.indexOf("update public.agent_path_leases")).toBeGreaterThan(fn.indexOf("public.request_agent_task_cancel"));
  expect(fn).not.toMatch(/(?:from|update|into) public\.actions\b/);
  expect(fn).not.toMatch(/from public\.agent_sessions[^;]*for (?:share|update|no key update)/);
});
it.each(["agent_path_leases_task_state","agent_path_leases_run_end","agent_path_leases_session_external","agent_path_leases_on_artifact"])("static R-P4 %s writes only leases or artifact metric",name=>{
  const writes=[...body(name).matchAll(/(?:update|insert into|delete from) public\.([a-z_]+)/g)].map(m=>m[1]);
  expect(writes.length).toBeGreaterThan(0);
  for(const table of writes)expect(name==="agent_path_leases_on_artifact"?["agent_path_leases","metric_events"]:["agent_path_leases"]).toContain(table);
});
it("metric v3 is embedded literally and all existing rate kinds remain",()=>{
  expect(sql).toContain("'tool_call_decided', 'path_conflict_found', 'path_conflict_resolved'");
  expect(sql).toContain("'bridge_poll','bridge_decide'");
  expect(sql).toContain("p_max - 1 limit 1");
});

it("static holder retains nullable action_number without recursive null stripping",()=>{
  expect(body("decide_agent_tool_call")).toContain("|| case when v_holder is null then '{}'::jsonb else jsonb_build_object('holder',v_holder) end");
});

it("R7 private SQLSTATEs and R11 bridges NOWAIT coverage",()=>{
 expect(sql).not.toMatch(/P000[23]/);
 expect(sql.split("create table")[0]).toMatch(/lock table public\.bridges,[^;]+nowait/);
});
