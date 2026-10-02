import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { changeEvents, projectAction } from "@/lib/actions/project";
import { actionRowValues, claimToRow } from "@/lib/actions/rows";
import { userClaims } from "@/lib/actions/user-claims";
import { ReceiptWriteError, writeDraftReceipt, writeMissingReceipts, type ReceiptStore } from "@/lib/execution/receipt";
import { USER_REASON, type Claim } from "@/lib/pipeline/resolve";

import { pgliteReceiptStore } from "../execution/pglite-receipt-store";
import { asUser, createLocalSupabase } from "./local-supabase";

// 실행 receipt → Claim/Evidence (20261023000000_execution_receipts, docs/EXECUTION.md 9장, A38 · A55 · A57).
// 실행기(U2 PR6)가 부를 순서 그대로: run → 계획 단계 → 초안 단계(complete_internal_step, 산출물) → writeDraftReceipt.
// receipt 쓰기는 운영과 같은 TS(receipt.ts)가 PGlite store로 같은 SQL 함수를 부른다.

const MIGRATION = path.resolve(__dirname, "../../supabase/migrations/20261023000000_execution_receipts.sql");

// 테스트 시계 (execution-credits.test.ts와 같은 판): 마이그레이션을 적용한 뒤 테스트 안에서만 바꾼다. app.now가 비면 now()
const TEST_CLOCK = `
  create or replace function public.db_now() returns timestamptz language sql stable set search_path = '' as $$
    select coalesce(nullif(current_setting('app.now', true), '')::timestamptz, now())
  $$;
`;

const ARTIFACT = { title: "제안서 초안\n(김 대표님께)", body: "안녕하세요, 지난 회의에서 말씀드린 제안서를 보내드립니다.", model: "z-ai/glm-5.3-flash", prompt_version: "draft-v1" };
const RECEIPT_LINE = "초안 저장: 제안서 초안 (김 대표님께)";

let db: PGlite;
let store: ReceiptStore;

const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];
const count = async (sql: string, params: unknown[] = []) => (await one<{ n: number }>(`select count(*)::int as n from (${sql}) x`, params)).n;

async function newUser() {
  const userId = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [userId, `${userId}@example.com`]);
  await db.query("insert into public.execution_actors (user_id) values ($1)", [userId]);
  await db.query("select public.grant_credits($1, 1000, gen_random_uuid())", [userId]);
  return userId;
}

const claim = (field: Claim["field"], value: string, over: Partial<Claim> = {}): Claim => ({
  id: randomUUID(),
  field,
  value,
  occurredAt: new Date("2026-10-01T01:00:00Z"),
  speakerRole: "me",
  certainty: "firm",
  directness: "first_hand",
  audience: "shared",
  channel: "meeting",
  origin: "source",
  ...over,
});

/** 회의록에서 나온 열린 Action (원문 Claim · 근거 · created 이벤트, 파이프라인과 같은 write_action) */
async function newAction(userId: string, claims: Claim[] = [claim("scope", "제안서 보내기"), claim("due", "2026-10-09"), claim("owner", "me"), claim("status", "open")]) {
  const quote = "금요일까지 제안서 보내드릴게요";
  const sourceId = (await one<{ id: string }>(
    "insert into public.sources (user_id, kind, raw_text, occurred_at, processing_status) values ($1, 'meeting', $2, '2026-10-01T01:00:00Z', 'done') returning id",
    [userId, quote],
  )).id;
  const actionId = randomUUID();
  const projected = projectAction("제안서 보내기", claims);
  await db.query("select public.write_action($1, $2, null, $3::jsonb, $4::jsonb, $5::jsonb, $6::jsonb)", [
    userId,
    actionId,
    JSON.stringify({ ...actionRowValues(projected), counterpart: "김 대표", embedding: null }),
    JSON.stringify(claims.map((c) => claimToRow(c, userId, actionId, { sourceId, quote }))),
    JSON.stringify([{ source_id: sourceId, quote, role: "created" }]),
    JSON.stringify(changeEvents(null, projected, "created").map((e) => ({ ...e, actor: "ai", source_id: sourceId }))),
  ]);
  return actionId;
}

/** 실행기 흐름: run → 계획 단계(초안 단계를 붙이고 끝냄) → 초안 단계(산출물과 함께 끝냄). 초안 단계 id */
async function finishedDraft(userId: string, actionId: string): Promise<{ runId: string; stepId: string; artifactId: string }> {
  const runId = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '제안서 초안 써 줘') as id", [userId, actionId])).id;
  const call = async (stepId: string) => {
    const { version } = await one<{ version: number }>("select version from public.execution_steps where id = $1", [stepId]);
    expect((await one<{ ok: boolean }>("select public.prepare_step($1, $2) as ok", [stepId, version])).ok).toBe(true);
    expect((await one<{ g: { gate: string } }>("select public.begin_call($1, 'fn-1', $2) as g", [stepId, version + 1])).g.gate).toBe("ok");
  };
  const attempts = (cost: number) => JSON.stringify([{ generationId: `gen-${randomUUID()}`, model: "m", usage: { prompt_tokens: 10, completion_tokens: 5, cost } }]);
  const planId = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1 and seq = 1", [runId])).id;
  await call(planId);
  const stepId = (await one<{ id: string }>(
    `select public.append_step($1, 2, '{"kind": "draft", "provider": "taskforce", "tool": "draft", "purpose": "draft", "estimate_credits": 10}') as id`,
    [runId],
  )).id;
  expect((await one<{ ok: boolean }>("select public.complete_internal_step($1, 'fn-1', '{}', $2::jsonb) as ok", [planId, attempts(0.0007)])).ok).toBe(true);
  await call(stepId);
  expect(
    (await one<{ ok: boolean }>("select public.complete_internal_step($1, 'fn-1', '{}', $2::jsonb, $3::jsonb, 'draft_ready') as ok", [
      stepId,
      attempts(0.004),
      JSON.stringify(ARTIFACT),
    ])).ok,
  ).toBe(true);
  const artifactId = (await one<{ id: string }>("select id from public.execution_artifacts where step_id = $1", [stepId])).id;
  return { runId, stepId, artifactId };
}

type ActionSnapshot = {
  title: string;
  owner: string;
  due_date: string | null;
  status: string;
  needs_confirmation: boolean;
  confirm_reasons: string[];
  resolution: unknown;
  version: number;
};
const actionRow = (actionId: string) =>
  one<ActionSnapshot>(
    "select title, owner, due_date::text, status, needs_confirmation, confirm_reasons, resolution, version from public.actions where id = $1",
    [actionId],
  );

/** 사용자가 앱에서 완료로 바꿈 (service.ts applyUserChanges와 같은 계산: 사용자 Claim → 다시 판정 → write_action) */
async function userComplete(userId: string, actionId: string) {
  const row = await actionRow(actionId);
  const existing = (
    await db.query<{ id: string; field: Claim["field"]; value: string; occurred_at: Date; speaker_role: Claim["speakerRole"]; certainty: Claim["certainty"]; directness: Claim["directness"]; audience: Claim["audience"]; origin: NonNullable<Claim["origin"]>; channel: Claim["channel"] | null; state: Claim["state"] }>(
      "select id, field, value, occurred_at, speaker_role, certainty, directness, audience, origin, channel, state from public.claims where action_id = $1",
      [actionId],
    )
  ).rows.map((r): Claim => ({ id: r.id, field: r.field, value: r.value, occurredAt: new Date(r.occurred_at), speakerRole: r.speaker_role, certainty: r.certainty, directness: r.directness, audience: r.audience, origin: r.origin, channel: r.channel ?? "note", state: r.state }));
  const before = projectAction(row.title, existing);
  const added = userClaims([{ field: "status", value: "done" }], new Date(), randomUUID);
  const after = projectAction(row.title, [...existing, ...added]);
  const ok = await one<{ ok: boolean }>("select public.write_action($1, $2, $3, $4::jsonb, $5::jsonb, '[]', $6::jsonb) as ok", [
    userId,
    actionId,
    row.version,
    JSON.stringify(actionRowValues(after)),
    JSON.stringify(added.map((c) => claimToRow(c, userId, actionId, { sourceId: null, quote: null }))),
    JSON.stringify(changeEvents(before, after, "updated").map((e) => ({ ...e, type: "user_edited", rule: "user", actor: "user" }))),
  ]);
  expect(ok.ok).toBe(true);
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.exec(TEST_CLOCK);
  // 처음 상태는 전체 스위치가 막혀 있다 (execution-core.test.ts). 여기서는 receipt만 본다
  await db.query("update public.execution_controls set blocked = false where scope = 'global'");
  store = pgliteReceiptStore(db);
}, 60_000);

describe("초안 receipt 붙이기 (writeDraftReceipt → write_execution_receipt)", () => {
  it("receipt 원문(execution) · Claim(origin execution, 값 = 산출물) · 근거(executed) · 이벤트(agent)를 붙이고, Action 값은 그대로다 (A38)", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const { runId, stepId, artifactId } = await finishedDraft(user, actionId);
    const before = await actionRow(actionId);

    expect(await writeDraftReceipt(store, stepId)).toBe("written");

    const source = await one<{ id: string; kind: string; title: string; raw_text: string; external_url: string; external_id: string; processing_status: string; same_time: boolean }>(
      `select s.id, s.kind, s.title, s.raw_text, s.external_url, s.external_id, s.processing_status, s.occurred_at = a.created_at as same_time
       from public.sources s, public.execution_artifacts a where s.user_id = $1 and s.kind = 'execution' and a.id = $2`,
      [user, artifactId],
    );
    expect(source).toMatchObject({
      kind: "execution",
      title: "제안서 초안 (김 대표님께)",
      raw_text: RECEIPT_LINE,
      external_url: `taskforce://artifacts/${artifactId}`,
      external_id: stepId,
      processing_status: "done", // 추출 처리(재처리 cron)에 들어가지 않는다
      same_time: true, // 발언 시점 = 산출물을 저장한 DB 시각
    });

    const claims = (await db.query("select field, value, quote, origin, source_id, channel, speaker_role, audience, state from public.claims where action_id = $1 and origin = 'execution'", [actionId])).rows;
    expect(claims).toEqual([
      { field: "artifact", value: artifactId, quote: RECEIPT_LINE, origin: "execution", source_id: source.id, channel: null, speaker_role: "me", audience: "private", state: "active" },
    ]);
    expect((await db.query("select quote, role from public.evidence where source_id = $1", [source.id])).rows).toEqual([{ quote: RECEIPT_LINE, role: "executed" }]);
    const events = (await db.query("select type, actor, before, after, rule from public.action_events where source_id = $1", [source.id])).rows;
    expect(events).toEqual([{ type: "artifact_created", actor: "agent", before: null, after: { artifact_id: artifactId, run_id: runId, step_id: stepId }, rule: null }]);
    // 값이 바뀐 이벤트(완료 · 기한 변경 등)는 없다
    expect(await count("select 1 from public.action_events where action_id = $1 and type <> 'created' and type <> 'artifact_created'", [actionId])).toBe(0);

    // 초안 ≠ 완료: 상태 · 기한 · 담당 · 제목 · 확인 · 판정 이유 그대로, 버전만 하나 오른다
    const after = await actionRow(actionId);
    expect(after).toEqual({ ...before, version: before.version + 1 });
    expect(after.status).toBe("open");

    // 기준 17 검사 쿼리: 원문 · 인용 없는 실행 Claim 0
    expect(await count("select 1 from public.claims where origin = 'execution' and (source_id is null or quote is null)")).toBe(0);
  });

  it("다시 불러도 한 번만 붙는다: 이미 붙었으면 버전과 상관없이 exists, 아무것도 더 쓰지 않는다", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const { stepId } = await finishedDraft(user, actionId);
    expect(await writeDraftReceipt(store, stepId)).toBe("written");
    const version = (await actionRow(actionId)).version;
    const rows = () =>
      Promise.all([
        count("select 1 from public.sources where user_id = $1 and kind = 'execution'", [user]),
        count("select 1 from public.claims where action_id = $1 and origin = 'execution'", [actionId]),
        count("select 1 from public.evidence where action_id = $1 and role = 'executed'", [actionId]),
        count("select 1 from public.action_events where action_id = $1 and type = 'artifact_created'", [actionId]),
      ]);
    expect(await rows()).toEqual([1, 1, 1, 1]);

    expect(await writeDraftReceipt(store, stepId)).toBe("exists");
    // 앞 시도가 commit한 뒤 응답만 잃은 실행기가 옛 버전으로 다시 불러도 exists (conflict로 되풀이하지 않는다)
    const receipt = { source: { title: null, raw_text: "초안 저장", external_url: "taskforce://artifacts/x" }, claim: { id: randomUUID(), quote: "초안 저장" } };
    expect((await one<{ r: string }>("select public.write_execution_receipt($1, $2, '{}', $3::jsonb) as r", [stepId, version - 1, JSON.stringify(receipt)])).r).toBe("exists");
    expect(await rows()).toEqual([1, 1, 1, 1]);
    expect((await actionRow(actionId)).version).toBe(version);
  });

  it("버전이 어긋나면 아무것도 쓰지 않고(conflict), 실행기는 다시 읽고 다시 계산해 붙인다", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const { stepId } = await finishedDraft(user, actionId);
    const { version } = await actionRow(actionId);
    const receipt = { source: { title: "x", raw_text: "초안 저장: x", external_url: "taskforce://artifacts/x" }, claim: { id: randomUUID(), quote: "초안 저장: x", speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "private" } };
    expect((await one<{ r: string }>("select public.write_execution_receipt($1, $2, '{}', $3::jsonb) as r", [stepId, version + 5, JSON.stringify(receipt)])).r).toBe("conflict");
    expect(await count("select 1 from public.sources where user_id = $1 and kind = 'execution'", [user])).toBe(0);
    expect(await count("select 1 from public.claims where action_id = $1 and origin = 'execution'", [actionId])).toBe(0);

    // 읽은 뒤 사용자가 고쳐 버전이 오름 → 첫 쓰기는 conflict → 다시 읽어 붙인다
    let stale = true;
    const racing: ReceiptStore = {
      ...store,
      async loadAction(userId, id) {
        const loaded = await store.loadAction(userId, id);
        if (loaded && stale) {
          stale = false;
          await db.query("update public.actions set version = version + 1 where id = $1", [id]);
        }
        return loaded;
      },
    };
    expect(await writeDraftReceipt(racing, stepId)).toBe("written");
    expect(await count("select 1 from public.claims where action_id = $1 and origin = 'execution'", [actionId])).toBe(1);
  });

  it("사용자가 직접 끝낸 할 일은 초안 receipt가 다시 열지 않는다 (A57)", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const { stepId } = await finishedDraft(user, actionId);
    await userComplete(user, actionId); // 초안을 기다리는 사이 사용자가 끝냄
    const before = await actionRow(actionId);
    expect(before.status).toBe("done");

    expect(await writeDraftReceipt(store, stepId)).toBe("written");
    const after = await actionRow(actionId);
    expect(after).toEqual({ ...before, version: before.version + 1 });
    expect((after.resolution as { status: { reason: string } }).status.reason).toBe(USER_REASON);
  });

  it("확인을 기다리는 할 일도 확인 이유 · 판정을 바꾸지 않는다 (확인 요청을 늘리거나 풀지 않는다)", async () => {
    const user = await newUser();
    // 담당을 모르는 할 일: "담당 확인"
    const actionId = await newAction(user, [claim("scope", "견적서 정리"), claim("status", "open")]);
    const { stepId } = await finishedDraft(user, actionId);
    const before = await actionRow(actionId);
    expect(before.confirm_reasons).toEqual(["담당 확인"]);
    expect(await writeDraftReceipt(store, stepId)).toBe("written");
    expect(await actionRow(actionId)).toEqual({ ...before, version: before.version + 1 });
  });

  it("값은 서버가 정한다: 호출자가 다른 값 · origin · 필드를 넘겨도 산출물 id · execution · artifact로 쓴다 (A55: user Claim으로 위조 못 함)", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const { stepId, artifactId } = await finishedDraft(user, actionId);
    const row = await actionRow(actionId);
    const forged = {
      source: { title: "x", raw_text: "초안 저장: x", external_url: "taskforce://artifacts/x" },
      claim: { id: randomUUID(), quote: "초안 저장: x", field: "status", value: "done", origin: "user", source_id: null, speaker_role: "me", certainty: "firm", directness: "first_hand", audience: "private" },
    };
    // Action 값은 지금 행 그대로 (실행기가 다시 판정한 값과 같다)
    const { action } = await one<{ action: Record<string, unknown> }>(
      `select jsonb_build_object('title', title, 'owner', owner, 'due_date', due_date, 'due_at', due_at, 'status', status,
         'needs_confirmation', needs_confirmation, 'confirm_reasons', to_jsonb(confirm_reasons), 'resolution', resolution) as action
       from public.actions where id = $1`,
      [actionId],
    );
    expect((await one<{ r: string }>("select public.write_execution_receipt($1, $2, $3::jsonb, $4::jsonb) as r", [stepId, row.version, JSON.stringify(action), JSON.stringify(forged)])).r).toBe("written");
    const stored = await one("select field, value, origin, source_id is not null as has_source from public.claims where action_id = $1 and origin <> 'source'", [actionId]);
    expect(stored).toEqual({ field: "artifact", value: artifactId, origin: "execution", has_source: true });
    expect((await actionRow(actionId)).status).toBe("open");
  });

  it("끝낸 초안 단계 · 산출물이 아니면 쓰지 않는다 (계획 단계 · 부르는 중 · 없는 단계), 인용이 receipt 글에 없어도 거절", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const { runId, stepId } = await finishedDraft(user, actionId);
    const planId = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1 and seq = 1", [runId])).id;
    const receipt = (quote: string) => JSON.stringify({ source: { title: "x", raw_text: "초안 저장: x", external_url: "taskforce://artifacts/x" }, claim: { id: randomUUID(), quote } });
    for (const step of [planId, randomUUID()]) {
      await expect(db.query("select public.write_execution_receipt($1, 0, '{}', $2::jsonb)", [step, receipt("초안 저장: x")])).rejects.toThrow(/끝낸 초안 단계가 아니다/);
      await expect(writeDraftReceipt(store, step)).rejects.toThrow(ReceiptWriteError);
    }
    await expect(db.query("select public.write_execution_receipt($1, 0, '{}', $2::jsonb)", [stepId, receipt("완료했습니다")])).rejects.toThrow(/인용이 receipt 글에 없다/);
    await expect(db.query("select public.write_execution_receipt($1, 0, '{}', $2::jsonb)", [stepId, receipt("")])).rejects.toThrow(/인용이 receipt 글에 없다/);

    // 부르는 중인 초안 단계 (아직 산출물 없음)
    const run2 = (await one<{ id: string }>("select public.create_run($1, $2, 'draft', '하나 더') as id", [user, actionId])).id;
    const plan2 = (await one<{ id: string }>("select id from public.execution_steps where run_id = $1", [run2])).id;
    await db.query("select public.prepare_step($1, 0)", [plan2]);
    expect((await one<{ g: { gate: string } }>("select public.begin_call($1, 'fn-2', 1) as g", [plan2])).g.gate).toBe("ok");
    await expect(writeDraftReceipt(store, plan2)).rejects.toMatchObject({ code: "not_found" });
    expect(await count("select 1 from public.sources where user_id = $1 and kind = 'execution'", [user])).toBe(0);
  });
});

describe("제약: 실행 Claim에는 근거가 강제되고, Action 필드를 정하지 못한다", () => {
  it("원문 · 인용 없는 실행 Claim, 실행 Claim으로 상태 · 기한, 실행이 아닌 artifact Claim은 들어가지 못한다", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const sourceId = (await one<{ id: string }>(
      "insert into public.sources (user_id, kind, raw_text, occurred_at, external_id, processing_status) values ($1, 'execution', '초안 저장: x', now(), $2, 'done') returning id",
      [user, randomUUID()],
    )).id;
    const insert = (field: string, origin: string, source: string | null, quote: string | null) =>
      db.query(
        `insert into public.claims (user_id, action_id, source_id, field, value, quote, occurred_at, speaker_role, certainty, directness, audience, origin)
         values ($1, $2, $3, $4, 'v', $5, now(), 'me', 'firm', 'first_hand', 'private', $6)`,
        [user, actionId, source, field, quote, origin],
      );
    await expect(insert("artifact", "execution", null, null)).rejects.toThrow(/claims_source_origin/);
    await expect(insert("artifact", "execution", sourceId, null)).rejects.toThrow(/claims_source_origin/);
    await expect(insert("status", "execution", sourceId, "초안 저장: x")).rejects.toThrow(/claims_execution_artifact/);
    await expect(insert("due", "execution", sourceId, "초안 저장: x")).rejects.toThrow(/claims_execution_artifact/);
    await expect(insert("artifact", "source", sourceId, "초안 저장: x")).rejects.toThrow(/claims_execution_artifact/);
    await expect(insert("artifact", "user", null, null)).rejects.toThrow(/claims_execution_artifact/);
    await insert("artifact", "execution", sourceId, "초안 저장: x"); // 근거가 있는 실행 Claim은 들어간다
  });

  it("receipt 원문은 처리를 마친 것으로만 있고(추출 처리가 processing으로 바꾸지 못한다), 단계 하나에 하나다", async () => {
    const user = await newUser();
    const step = randomUUID();
    const insert = (status: string, externalId: string | null) =>
      db.query("insert into public.sources (user_id, kind, raw_text, occurred_at, external_id, processing_status) values ($1, 'execution', '초안 저장', now(), $2, $3) returning id", [
        user,
        externalId,
        status,
      ]);
    await expect(insert("pending", step)).rejects.toThrow(/sources_execution_receipt/);
    await expect(insert("done", null)).rejects.toThrow(/sources_execution_receipt/);
    const id = (await insert("done", step)).rows[0] as { id: string };
    await expect(insert("done", step)).rejects.toThrow(/sources_execution_receipt_idx/);
    // lib/sources/process.ts가 처리를 시작할 때 쓰는 update
    await expect(db.query("update public.sources set processing_status = 'processing' where id = $1", [id.id])).rejects.toThrow(/sources_execution_receipt/);
    // 다른 사용자의 같은 외부 id는 따로다 (unique는 사용자마다)
    await db.query("insert into public.sources (user_id, kind, raw_text, occurred_at, external_id, processing_status) values ($1, 'execution', '초안 저장', now(), $2, 'done')", [
      await newUser(),
      step,
    ]);
  });

  it("기존 값은 그대로 받는다 (원문 종류 · 근거 역할 · 이벤트 종류 · 주체)", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    for (const kind of ["meeting", "message", "email", "doc", "note", "task"]) {
      await db.query("insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, $2, 'x', now())", [user, kind]);
    }
    for (const actor of ["ai", "user"]) {
      await db.query("insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_unstarted', $3)", [user, actionId, actor]);
    }
    await expect(db.query("insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'created', 'robot')", [user, actionId])).rejects.toThrow(/action_events_actor_check/);
    await expect(db.query("insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'receipt', 'x', now())", [user])).rejects.toThrow(/sources_kind_check/);
  });
});

describe("권한: receipt는 본인만 읽고, 서버만 쓴다", () => {
  it("본인은 receipt 원문 · Claim · 근거 · 이벤트를 읽고, 다른 사용자에게는 하나도 보이지 않는다", async () => {
    const alice = await newUser();
    const bob = await newUser();
    const actionId = await newAction(alice);
    const { stepId } = await finishedDraft(alice, actionId);
    await writeDraftReceipt(store, stepId);
    const visible = () =>
      Promise.all([
        count("select 1 from public.sources where kind = 'execution'"),
        count("select 1 from public.claims where origin = 'execution'"),
        count("select 1 from public.evidence where role = 'executed'"),
        count("select 1 from public.action_events where actor = 'agent'"),
      ]);
    expect(await asUser(db, alice, visible)).toEqual([1, 1, 1, 1]);
    expect(await asUser(db, bob, visible)).toEqual([0, 0, 0, 0]);
  });

  it("클라이언트는 receipt 원문을 만들거나 고치거나 지우지 못한다 (다른 종류의 원문은 전과 같다)", async () => {
    const alice = await newUser();
    const actionId = await newAction(alice);
    const { stepId } = await finishedDraft(alice, actionId);
    await writeDraftReceipt(store, stepId);
    const receiptId = (await one<{ id: string }>("select id from public.sources where user_id = $1 and kind = 'execution'", [alice])).id;

    await asUser(db, alice, async () => {
      await expect(
        db.query("insert into public.sources (kind, raw_text, occurred_at, external_id, processing_status) values ('execution', '초안 저장: 가짜', now(), $1, 'done')", [randomUUID()]),
      ).rejects.toThrow(/row-level security/);
      // 고치기 · 지우기는 보이지 않는 행처럼 0행 (오류 없이 아무것도 바뀌지 않는다)
      expect((await db.query("update public.sources set raw_text = '바꿈' where id = $1", [receiptId])).affectedRows).toBe(0);
      expect((await db.query("delete from public.sources where id = $1", [receiptId])).affectedRows).toBe(0);
      // 일반 원문을 receipt로 바꾸지도 못한다
      const note = (await db.query<{ id: string }>("insert into public.sources (kind, raw_text, occurred_at) values ('note', '메모', now()) returning id")).rows[0].id;
      await expect(db.query("update public.sources set kind = 'execution', external_id = $2, processing_status = 'done' where id = $1", [note, randomUUID()])).rejects.toThrow(/row-level security/);
      expect((await db.query("delete from public.sources where id = $1", [note])).affectedRows).toBe(1);
    });
    expect(await one("select raw_text from public.sources where id = $1", [receiptId])).toEqual({ raw_text: RECEIPT_LINE });
    expect(await count("select 1 from public.claims where source_id = $1", [receiptId])).toBe(1);
  });

  it("receipt 함수는 서버 전용이다: anon · authenticated 실행 권한 없음, service_role만, search_path = '', 소유자 권한 없음", async () => {
    const sql = await readFile(MIGRATION, "utf8");
    const names = [...new Set([...sql.matchAll(/create (?:or replace )?function public\.(\w+)/g)].map((m) => m[1]))].sort();
    expect(names).toEqual(["missing_execution_receipts", "write_execution_receipt"]);
    const { rows } = await db.query<{ name: string; anon: boolean; authenticated: boolean; service_role: boolean; definer: boolean; config: string[] | null }>(
      `select p.proname as name,
              has_function_privilege('anon', p.oid, 'execute') as anon,
              has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
              has_function_privilege('service_role', p.oid, 'execute') as service_role,
              p.prosecdef as definer, p.proconfig as config
       from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = any ($1)
       order by p.proname`,
      [names],
    );
    expect(rows.map((r) => r.name)).toEqual(names);
    for (const row of rows) {
      expect(row, row.name).toMatchObject({ anon: false, authenticated: false, service_role: true, definer: false });
      expect(row.config, row.name).toContain('search_path=""');
    }
    const user = await newUser();
    await asUser(db, user, async () => {
      await expect(db.query("select public.write_execution_receipt(gen_random_uuid(), 0, '{}', '{}')")).rejects.toThrow(/permission denied/);
      await expect(db.query("select * from public.missing_execution_receipts()")).rejects.toThrow(/permission denied/);
    });
  });

  it("service_role은 RPC로 receipt를 붙인다 (write_action · 원문 insert가 service_role 권한으로 돈다)", async () => {
    const user = await newUser();
    const actionId = await newAction(user);
    const { stepId } = await finishedDraft(user, actionId);
    await db.exec("set role service_role");
    try {
      expect(await writeDraftReceipt(store, stepId)).toBe("written");
    } finally {
      await db.exec("reset role");
    }
  });
});

describe("보조 안전망: receipt를 쓰기 전에 죽은 실행기 (missing_execution_receipts → writeMissingReceipts)", () => {
  it("receipt가 없는 끝낸 초안 단계를 찾아 붙이고, 붙은 단계 · 하루가 지난 산출물은 고르지 않는다", async () => {
    await db.query("select set_config('app.now', '', false)");
    for (const stepId of await store.missingReceipts(1000)) await writeDraftReceipt(store, stepId); // 앞 테스트가 남긴 것
    const user = await newUser();
    const actionId = await newAction(user);
    const a = await finishedDraft(user, actionId);
    const b = await finishedDraft(user, actionId);
    expect((await store.missingReceipts(20)).sort()).toEqual([a.stepId, b.stepId].sort());

    expect(await writeMissingReceipts(store, 20)).toEqual({ written: 2, failed: 0 });
    expect(await store.missingReceipts(20)).toEqual([]);
    expect(await count("select 1 from public.claims where action_id = $1 and origin = 'execution'", [actionId])).toBe(2);

    const c = await finishedDraft(user, actionId);
    expect(await store.missingReceipts(20)).toEqual([c.stepId]);
    await db.query("select set_config('app.now', (now() + interval '2 days')::text, false)");
    try {
      expect(await store.missingReceipts(20)).toEqual([]);
    } finally {
      await db.query("select set_config('app.now', '', false)");
    }
  });
});
