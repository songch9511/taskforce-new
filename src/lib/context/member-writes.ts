import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { contextMemberSchema, type ContextMember } from "@/lib/api/contract";
import { flagEnabled } from "@/lib/flags";

import { ContextGateOffError } from "./store";

// 사용자가 하는 멤버십 쓰기의 DB 쪽 (S3b, service role): 할 일을 범위에 넣기 · 빼기 · 옮기기 (ProjectLink "Set by you" · Undo). 모든 쿼리를 user_id로 좁힌다:
// 남의 · 없는 · 보관된 범위와 남의 · 없는 할 일은 같은 not_found다. 규칙은 DB 함수 change_context_membership_by_user(20261108000000)에 있고 여기는 부르기만 한다
// (origin user로 넣기 · 승격 · 빼기 표시 removed_at · 요청이 본 범위 version과 지금이 다르면 쓰기 0인 조건부 쓰기 · 실제 변화 · 두 범위를 검증한 뒤에만 쓰는 옮기기 · 잠금 순서).
// AI를 부르지 않는다. 실행(src/lib/execution)은 가져오지 않는다. gate: MEMORY_ENABLED. 꺼져 있으면 DB를 부르지 않는다 (ContextGateOffError).

type Env = Record<string, string | undefined>;

export type ContextMemberChange = {
  actionId: string;
  /** 넣을 범위 (내 active 범위)와 요청이 본 그 범위의 version. 없으면 빼기만 */
  add?: { contextId: string; expectedVersion: number };
  /** 뺄 범위 (내 active 범위)와 요청이 본 그 범위의 version. 없으면 넣기만. 둘 다 주면 옮기기(한 트랜잭션)이고 서로 달라야 한다 */
  remove?: { contextId: string; expectedVersion: number };
};

/** 쓴 뒤의 행, 쓰기 직후의 범위 version, 확인된 멤버가 실제로 바뀌었나 (이미 멤버였거나 멤버가 아니던 범위는 false) */
export type ContextMemberWritten = { member: ContextMember; contextVersion: number; changed: boolean };

export type ContextMemberOutcome =
  | { status: "ok"; added: ContextMemberWritten | null; removed: ContextMemberWritten | null }
  | { status: "conflict" | "context_not_found" | "action_not_found" };

type Row = {
  status: string;
  added_member: unknown;
  removed_member: unknown;
  added_changed: boolean;
  removed_changed: boolean;
  added_version: number | null;
  removed_version: number | null;
};

const written = (member: unknown, version: number | null, changed: boolean): ContextMemberWritten | null =>
  member && version !== null ? { member: contextMemberSchema.parse(member), contextVersion: Number(version), changed } : null;

/**
 * 사용자 멤버십 쓰기. 요청이 본 범위 version이 지금과 다르면 쓰지 않고 conflict (옛 요청 · 응답을 잃은 재전송 · 늦은 Undo가 더 새 결정을 덮지 못한다).
 * 돌려주는 행 · version은 쓰기와 같은 트랜잭션에서 읽은 값이다. 이미 그 상태면 행을 쓰지 않는다(조건은 통과해야 한다)
 */
export async function changeContextMembership(admin: SupabaseClient, userId: string, change: ContextMemberChange, env: Env = process.env): Promise<ContextMemberOutcome> {
  if (!flagEnabled("MEMORY_ENABLED", env)) throw new ContextGateOffError("MEMORY_ENABLED");
  const { data } = await admin
    .rpc("change_context_membership_by_user", {
      p_user_id: userId,
      p_action_id: change.actionId,
      p_add_context_id: change.add?.contextId ?? null,
      p_expected_add_version: change.add?.expectedVersion ?? null,
      p_remove_context_id: change.remove?.contextId ?? null,
      p_expected_remove_version: change.remove?.expectedVersion ?? null,
    })
    .single<Row>()
    .throwOnError();
  if (data.status === "conflict" || data.status === "context_not_found" || data.status === "action_not_found") return { status: data.status };
  return {
    status: "ok",
    added: written(data.added_member, data.added_version, data.added_changed),
    removed: written(data.removed_member, data.removed_version, data.removed_changed),
  };
}
