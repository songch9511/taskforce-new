import type { PGlite } from "@electric-sql/pglite";

import { setClock } from "../coordinator/support";

// OA D4b-s P3: gate 꺼짐 바이트 동일의 기준 fixture. 모든 id · 시각을 직접 정해서 어느 실행에서나 같은 JSON이 나온다 (새 DB 하나 + 고정 시계 + 고정 지평).
// 이 fixture로 **D4b-s 이전 코드(base 97a43e1)**가 낸 Review · 복귀 요약 전체 JSON을 `review-agents-golden.json`에 기록했다 (기록 방법은 그 파일의 `recorded` 항목).
// 시험은 같은 fixture에서 HEAD가 gate를 닫고 낸 전체 JSON(complete · sources · changes · cursor · init_token 포함)이 그 기록과 글자 단위로 같음을 본다.
// 에이전트 입력(질문 · 결과 준비 · 경로 충돌)이 같은 사용자에게 **들어 있다** — 기록 때(base)는 그 입력을 읽는 코드가 없었고, HEAD는 gate가 닫혀 있으면 읽지 않아야 한다.

export const GOLDEN_NOW = new Date("2026-10-12T21:00:00Z");
export const GOLDEN_HORIZON = "2026-10-12T20:00:00.000000Z";
export const GOLDEN_USER = "11111111-1111-4111-8111-111111111111";
export const GOLDEN_START = new Date("2026-10-12T00:00:00Z");

const id = (prefix: string, n: number) => `${prefix}0000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
export const GA = (n: number) => id("a", n); // Action
const R = (n: number) => id("d", n); // run
const T = (n: number) => id("e", n); // agent task
const SESSION = id("5", 1);
const BRIDGE = id("b", 1);
const CONNECTION = id("c", 1);
const POLICY = id("9", 1);
const CONVERSATION = id("f", 1);

export async function seedGoldenWorld(db: PGlite): Promise<void> {
  const q = async (sql: string, params: unknown[] = []) => (await db.query<Record<string, unknown>>(sql, params)).rows;
  await setClock(db, GOLDEN_START);
  await q(`insert into auth.users (id, email) values ($1, 'golden@example.com')`, [GOLDEN_USER]);
  const action = (n: number, title: string, extra: { confirm?: boolean } = {}) =>
    q(`insert into public.actions (id, user_id, title, needs_confirmation, last_activity_at) values ($1, $2, $3, $4, $5)`, [GA(n), GOLDEN_USER, title, extra.confirm ?? false, "2026-10-11T00:00:00Z"]);

  // ── C3 쪽 입력 (base에서도 같이 읽히는 것) ──
  await action(1, "확인이 필요한 일", { confirm: true }); // 결정 대기 confirm
  await action(2, "견적서 보내기"); // 미열람 Action 변화 둘
  await action(3, "초안 작성"); // run 결과(draft_ready)
  await action(4, "답이 필요한 일"); // run needs_input → 결정 대기 run_input
  // 사건 id도 직접 정한다: 복귀 요약 digest(커서)가 사건 id의 해시 합이라 id가 달라지면 커서가 달라진다
  await q(`insert into public.action_events (id, user_id, action_id, type, actor, created_at) values ($1, $3, $4, 'due_changed', 'ai', $5), ($2, $3, $4, 'merged', 'ai', $6)`, [
    id("7", 1), id("7", 2), GOLDEN_USER, GA(2), "2026-10-12T12:00:00.000000Z", "2026-10-12T12:30:00.000000Z",
  ]);
  await q(`insert into public.execution_policies (id, user_id) values ($1, $2)`, [POLICY, GOLDEN_USER]);
  const run = (n: number, actionN: number) =>
    q(`insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request, created_at) values ($1, $2, $3, $4, 'draft', '초안', $5)`, [R(n), GOLDEN_USER, GA(actionN), POLICY, "2026-10-12T00:10:00Z"]);
  await run(1, 3);
  await run(2, 4);
  for (const [n, at, outcome] of [[1, "2026-10-12T13:00:00Z", "draft_ready"], [2, "2026-10-12T14:00:00Z", "needs_input"]] as const) {
    await setClock(db, new Date(at));
    await q(`update public.execution_runs set state = 'running' where id = $1`, [R(n)]);
    await q(`update public.execution_runs set state = 'done', outcome = $2 where id = $1`, [R(n), outcome]);
  }
  await setClock(db, GOLDEN_START);
  await q(`insert into public.conversations (id, user_id) values ($1, $2)`, [CONVERSATION, GOLDEN_USER]);
  await q(`insert into public.conversation_messages (id, user_id, conversation_id, seq, role, text, refs, created_at) values ($1, $2, $3, 1, 'assistant', '답', $4, $5)`, [
    id("8", 1), GOLDEN_USER, CONVERSATION, JSON.stringify({ action_ids: [GA(2)] }), "2026-10-12T15:00:00Z",
  ]);

  // ── 에이전트 입력 (D4b-s가 gate 뒤에서 읽는 것): 질문 · 결과 준비 · 경로 충돌 ──
  await action(5, "에이전트 질문");
  await action(6, "에이전트 결과");
  await action(7, "에이전트 충돌");
  await q(`insert into public.bridges (id, user_id, device_ref) values ($1, $2, 'golden-mac')`, [BRIDGE, GOLDEN_USER]);
  await q(`insert into public.agent_connections (id, user_id, adapter, bridge_id) values ($1, $2, 'agent:codex', $3)`, [CONNECTION, GOLDEN_USER, BRIDGE]);
  await q(`insert into public.agent_sessions (id, user_id, connection_id, external_session_id, workspace_ref) values ($1, $2, $3, 'ext-golden', '/w/proj')`, [SESSION, GOLDEN_USER, CONNECTION]);
  const agentRun = (n: number, actionN: number) =>
    q(
      `insert into public.execution_runs (id, user_id, action_id, policy_id, goal, request, kind, agent_session_id, created_at) values ($1, $2, $3, $4, 'agent', '대화', 'conversation', $5, $6)`,
      [R(n), GOLDEN_USER, GA(actionN), POLICY, SESSION, "2026-10-12T00:20:00Z"],
    );
  await agentRun(5, 5);
  await agentRun(6, 6);
  await agentRun(7, 7);
  const question = {
    question_key: [T(5), "req-golden"], provider_request_id: "req-golden", kind: "input", structured: true, asked_at: "2026-10-12T16:00:00Z",
    questions: [{ id: "q0", header: "골든 질문 제목", text: "골든 질문 글", options: [], multi_select: false, allow_other: true, secret: false }],
  };
  await q(`insert into public.agent_tasks (id, user_id, run_id, agent_session_id, turn_seq, state, pending_question) values ($1, $2, $3, $4, 1, 'awaiting_answer', $5::jsonb)`, [T(5), GOLDEN_USER, R(5), SESSION, JSON.stringify(question)]);
  await q(`insert into public.agent_tasks (id, user_id, run_id, agent_session_id, turn_seq, state) values ($1, $2, $3, $4, 2, 'idle')`, [T(6), GOLDEN_USER, R(6), SESSION]);
  await q(`insert into public.agent_artifacts (user_id, run_id, agent_task_id, turn_seq, path, content_hash, summary, created_at) values ($1, $2, $3, 2, 'golden.md', 'hash', '골든 산출물', $4)`, [
    GOLDEN_USER, R(6), T(6), "2026-10-12T17:00:00Z",
  ]);
  await q(`insert into public.agent_tasks (id, user_id, run_id, agent_session_id, turn_seq, state) values ($1, $2, $3, $4, 3, 'idle')`, [T(7), GOLDEN_USER, R(7), SESSION]);
  await q(
    `insert into public.agent_path_leases (id, user_id, bridge_id, run_id, agent_session_id, workspace_ref, path_key, rel_path, source, conflict_run_id, conflict_at, conflict_version)
     values ($1, $2, $3, $4, $5, '/w/proj', '/w/proj/golden.mdx', '골든 경로.mdx', 'observed', $6, $7, 1)`,
    [id("c", 2), GOLDEN_USER, BRIDGE, R(5), SESSION, R(7), "2026-10-12T18:00:00Z"],
  );
  await setClock(db, GOLDEN_START);
}

/** 읽음 기준을 만든다 (Clear한 적 있음): 그 뒤에 도착한 run 결과 · 메시지가 변화로 올라와 `cleared` 응답의 changes·since·cursor를 기준에 담는다 */
export async function markGoldenCleared(db: PGlite): Promise<void> {
  await db.query(`insert into public.return_summary_state (user_id, cleared_through) values ($1, $2)`, [GOLDEN_USER, "2026-10-12T08:00:00.000000Z"]);
}
