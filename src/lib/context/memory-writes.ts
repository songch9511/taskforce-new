import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { memoryItemSchema, type MemoryEditRequest, type MemoryItem, type MemoryScopeRequest } from "@/lib/api/contract";
import { flagEnabled } from "@/lib/flags";

import { planConfirm, planEdit, type MemoryWriteOutcome } from "./memory-edit";
import type { MemoryScope } from "./memory";
import { isSlackDerived } from "./retrieve";
import { ContextGateOffError, loadSourceStates, rememberMemory } from "./store";

// 기억 확인 · 정정 · 잊기 · 범위 옮기기의 DB 쪽 (B3, service role). 모든 쿼리를 user_id로 좁힌다: 남의 · 없는 id는 같은 not_found다.
// 규칙은 순수 모듈(memory-edit)과 DB 함수에 있다: 쓰기는 B1 remember_memory_item(확인 · 정정, p_corrects + p_expected_version) ·
// forget_memory_item · move_memory_item(20261107000000_memory_writes) 뿐이고 여기는 부르기만 한다. AI를 부르지 않는다. 실행(src/lib/execution)은 가져오지 않는다.
// gate: MEMORY_ENABLED. 꺼져 있으면 DB를 부르지 않는다 (ContextGateOffError).

type Env = Record<string, string | undefined>;

const MEMORY_ITEM_COLUMNS =
  "id, kind, scope_kind, context_id, action_id, person_id, agent_adapter, subject, statement, value, origin, source_ref, observed_at, valid_from, valid_until, superseded_by, superseded_at, revoked_at, confidence, source_purged, version, created_at, updated_at";

function requireMemoryGate(env: Env) {
  if (!flagEnabled("MEMORY_ENABLED", env)) throw new ContextGateOffError("MEMORY_ENABLED");
}

/** 내 기억 하나 (앱이 RLS로 읽는 memory_items 행과 같은 모양). 없거나 남의 것이면 null */
export async function loadMemoryItem(admin: SupabaseClient, userId: string, id: string): Promise<MemoryItem | null> {
  const { data } = await admin.from("memory_items").select(MEMORY_ITEM_COLUMNS).eq("user_id", userId).eq("id", id).maybeSingle().throwOnError();
  return data ? memoryItemSchema.parse(data) : null;
}

/**
 * 출처 원문이 확인(승격)을 막는 상태인가 — 출처 기반 확인 경로의 정책 보류 (docs/context-layer.md 8장 (a) (d)):
 *  - (a) Slack에서 왔다: 맥락층의 기준(retrieve.ts isSlackDerived) 그대로 — 연결이 Slack이거나, Slack 끊기로 지운 원문이거나, 링크가 Slack이다
 *  - (d) 접근을 잃었다: B1 loadSourceStates의 accessLost(문서 단위: 같은 문서의 revision 하나라도 잃으면 잃은 문서, 명시 복원 전 새 revision도 마찬가지)
 * 출처 상태를 읽지 못하면 던지고(쓰기 0), 상태가 비어 돌아와도(원문이 없다) 막는다: 확인할 수 없는 출처를 근거로 explicit을 만들지 않는다 (fail-closed).
 * 출처 id가 없는 항목(대화 메시지 · 산출물 · 사건 출처)은 막지 않는다.
 * 한계: 이 읽기는 쓰기 트랜잭션 밖이다. 읽은 뒤 쓰기 전에 접근 상실이 커밋되면 확인이 통과할 수 있다 — 그 결과는 "접근 상실 직전에 끝난 확인"과 구별되지 않고
 * (B1은 확인된 explicit을 접근 상실 뒤에도 보존한다) 창은 두 문장 사이(밀리초)다. 접근 상실을 쓰는 연동 쪽은 아직 없다.
 */
async function restrictedSource(admin: SupabaseClient, userId: string, sourceRef: MemoryItem["source_ref"]): Promise<boolean> {
  const sourceId = sourceRef?.source_id;
  if (!sourceId) return false;
  const [state] = await loadSourceStates(admin, userId, [sourceId]);
  if (!state) return true;
  return isSlackDerived(state) || state.accessLost;
}

function scopeOf(row: MemoryItem): MemoryScope {
  switch (row.scope_kind) {
    case "context":
      return { kind: "context", contextId: row.context_id! };
    case "action":
      return { kind: "action", actionId: row.action_id! };
    case "counterpart":
      return { kind: "counterpart", personId: row.person_id! };
    case "agent":
      return { kind: "agent", agentAdapter: row.agent_adapter! };
    default:
      return { kind: "global" };
  }
}

/** DB가 던진 "그 기억이 없다"(remember_memory_item의 P0002: 읽은 뒤 그 사이 지워짐) */
const isMemoryGone = (error: unknown) => typeof error === "object" && error !== null && (error as { code?: unknown }).code === "P0002";

/**
 * 가리킨 행을 정정하는 새 explicit 행을 쓰고(remember_memory_item p_corrects) 그 지금 행을 돌려준다.
 * 범위 · kind · subject는 DB가 옛 행에서 물려받는다(subject는 'memory:' 예약 접두어일 수 있어 넘기지 않는다). 출처는 호출자가 정한다
 */
async function correctWith(
  admin: SupabaseClient,
  userId: string,
  row: MemoryItem,
  expectedVersion: number,
  write: { statement: string; value: Record<string, unknown>; valid_from: string | null; valid_until: string | null; source_ref: MemoryItem["source_ref"] },
  env: Env,
): Promise<MemoryWriteOutcome> {
  let result;
  try {
    result = await rememberMemory(
      admin,
      userId,
      { kind: row.kind, scope: scopeOf(row), subject: null, origin: "explicit", ...write },
      { corrects: { id: row.id, expectedVersion } },
      env,
    );
  } catch (error) {
    if (isMemoryGone(error)) return { status: "not_found" };
    throw error;
  }
  if (result.status !== "written") return { status: "conflict" };
  const item = await loadMemoryItem(admin, userId, result.id);
  return item ? { status: "ok", item } : { status: "not_found" };
}

/**
 * 후보(inferred) 확인: 새 explicit 행이 후보를 정정한다(글 · 값 · 유효 구간 · 출처 그대로, 같은 범위 · kind · subject).
 * Slack 원문 · 접근을 잃은 원문에서 온 후보 · 추정이 아닌 항목은 unavailable(정책 보류), 낡은 version · 이미 정정 · 잊은 항목은 conflict
 */
export async function confirmMemoryItem(admin: SupabaseClient, userId: string, id: string, expectedVersion: number, env: Env = process.env): Promise<MemoryWriteOutcome> {
  requireMemoryGate(env);
  const row = await loadMemoryItem(admin, userId, id);
  if (!row) return { status: "not_found" };
  const plan = planConfirm(row, expectedVersion, row.origin === "inferred" ? await restrictedSource(admin, userId, row.source_ref) : false);
  if (!plan.ok) return { status: plan.reason };
  return correctWith(
    admin,
    userId,
    row,
    expectedVersion,
    { statement: row.statement, value: row.value, valid_from: row.valid_from, valid_until: row.valid_until, source_ref: row.source_ref },
    env,
  );
}

/** 정정(Edit): 사용자가 쓴 새 글로 새 explicit 행 + 옛 행 정정된 이력. 범위는 바꾸지 않는다. 출처는 잇지 않는다(새 글은 사용자의 것) */
export async function editMemoryItem(admin: SupabaseClient, userId: string, id: string, request: MemoryEditRequest, env: Env = process.env): Promise<MemoryWriteOutcome> {
  requireMemoryGate(env);
  const row = await loadMemoryItem(admin, userId, id);
  if (!row) return { status: "not_found" };
  const plan = planEdit(row, request, row.origin !== "explicit" ? await restrictedSource(admin, userId, row.source_ref) : false);
  if (!plan.ok) return { status: plan.reason };
  return correctWith(admin, userId, row, request.expected_version, { ...plan.write, source_ref: null }, env);
}

/** 잊기: revoked_at(되돌릴 수 없음). 이미 잊은 항목의 재시도도 ok(현재 상태). 정정된 항목 · 낡은 version은 conflict */
export async function forgetMemoryItem(admin: SupabaseClient, userId: string, id: string, expectedVersion: number, env: Env = process.env): Promise<MemoryWriteOutcome> {
  requireMemoryGate(env);
  const { data } = await admin
    .rpc("forget_memory_item", { p_user_id: userId, p_id: id, p_expected_version: expectedVersion })
    .single<{ status: string }>()
    .throwOnError();
  switch (data.status) {
    case "forgotten":
    case "already_forgotten": {
      const item = await loadMemoryItem(admin, userId, id);
      return item ? { status: "ok", item } : { status: "not_found" };
    }
    case "conflict":
      return { status: "conflict" };
    default:
      return { status: "not_found" };
  }
}

/** 범위 옮기기: explicit 항목만 전체 · 내 active 범위로 (한 트랜잭션: 새 explicit 행 + 옛 행 잊음). 이미 그 범위면 ok(쓰기 없음) */
export async function moveMemoryItem(admin: SupabaseClient, userId: string, id: string, request: MemoryScopeRequest, env: Env = process.env): Promise<MemoryWriteOutcome> {
  requireMemoryGate(env);
  const { data } = await admin
    .rpc("move_memory_item", {
      p_user_id: userId,
      p_id: id,
      p_expected_version: request.expected_version,
      p_scope_kind: request.scope_kind,
      p_context_id: request.context_id,
    })
    .single<{ status: string; id: string | null }>()
    .throwOnError();
  switch (data.status) {
    case "moved":
    case "unchanged": {
      const item = data.id ? await loadMemoryItem(admin, userId, data.id) : null;
      return item ? { status: "ok", item } : { status: "not_found" };
    }
    case "conflict":
      return { status: "conflict" };
    case "unsupported":
      return { status: "unavailable" };
    default:
      return { status: "not_found" }; // 없는 · 남의 기억, 내 active 범위가 아닌 대상 (존재를 드러내지 않는다)
  }
}
