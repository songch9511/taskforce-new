import "server-only";

import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import { MATCH_THRESHOLDS, type OpenAction } from "@/lib/pipeline/match";
import type { ActionStore, Evidence, TrackedAction } from "@/lib/pipeline/merge";
import type { Claim } from "@/lib/pipeline/resolve";

import { changeEvents, projectAction, type EventDraft } from "./project";
import { actionRowValues, CLAIM_COLUMNS, claimFromRow, claimToRow, storedReasons, toPgVector, type ClaimRow } from "./rows";

// Phase 2 병합 결과를 DB에 쓴다 (service role). 쿼리마다 user_id로 범위를 좁힌다.
// actions 행은 claims를 판정한 결과이고, 값이 바뀔 때마다 action_events를 남긴다.

export async function loadClaims(admin: SupabaseClient, userId: string, actionId: string): Promise<Claim[]> {
  const { data } = await admin.from("claims").select(CLAIM_COLUMNS).eq("user_id", userId).eq("action_id", actionId).returns<ClaimRow[]>().throwOnError();
  return (data ?? []).map(claimFromRow);
}

export type ActionWrite = {
  /** null이면 새 Action. 아니면 읽었던 버전 (그 사이 누가 썼으면 쓰지 않는다) */
  expectedVersion: number | null;
  action: Record<string, unknown>;
  claims: Claim[];
  evidence: { sourceId: string | null; quote: string | null; role?: Evidence["role"] };
  events: EventDraft[];
  actor: "ai" | "user";
};

/** Action 행 · Claim · 근거 · 이벤트를 한 트랜잭션으로 쓴다 (DB 함수 write_action). 버전이 어긋나면 false. */
export async function writeAction(admin: SupabaseClient, userId: string, actionId: string, write: ActionWrite): Promise<boolean> {
  const { data } = await admin
    .rpc("write_action", {
      p_user_id: userId,
      p_action_id: actionId,
      p_expected_version: write.expectedVersion,
      p_action: write.action,
      p_claims: write.claims.map((c) => claimToRow(c, userId, actionId, write.evidence)),
      p_evidence: write.evidence.role ? [{ source_id: write.evidence.sourceId, quote: write.evidence.quote, role: write.evidence.role }] : [],
      p_events: write.events.map((e) => ({ type: e.type, before: e.before, after: e.after, rule: e.rule, actor: write.actor, source_id: write.evidence.sourceId })),
    })
    .throwOnError();
  return data === true;
}

export class WriteConflictError extends Error {
  constructor() {
    super("동시에 같은 Action을 고치고 있습니다. 잠시 뒤 다시 시도해 주세요.");
    this.name = "WriteConflictError";
  }
}

/** 읽기 → 계산 → 쓰기를 버전이 맞을 때까지 다시 한다 (최대 3번). */
export async function retryOnConflict<T>(attempt: () => Promise<T | null>): Promise<T> {
  for (let i = 0; i < 3; i++) {
    const result = await attempt();
    if (result !== null) return result;
  }
  throw new WriteConflictError();
}

type StoredRow = { title: string; confirm_reasons: string[]; needs_confirmation: boolean; version: number };

export async function loadStoredRow(admin: SupabaseClient, userId: string, actionId: string): Promise<StoredRow | null> {
  const { data } = await admin
    .from("actions")
    .select("title, confirm_reasons, needs_confirmation, version")
    .eq("user_id", userId)
    .eq("id", actionId)
    .maybeSingle()
    .throwOnError();
  return data as StoredRow | null;
}

export class SupabaseActionStore implements ActionStore {
  /** 이번 처리에서 확인 요청이 새로 생긴 Action (알림용) */
  readonly needsConfirmation = new Set<string>();

  constructor(
    private readonly admin: SupabaseClient,
    private readonly userId: string,
  ) {}

  async shortlist(vector: number[]): Promise<OpenAction[]> {
    const { data } = await this.admin
      .rpc("match_open_actions", { p_user_id: this.userId, p_embedding: toPgVector(vector), p_count: MATCH_THRESHOLDS.shortlistSize })
      .throwOnError();
    const matches = (data ?? []) as { id: string; similarity: number }[];
    const ids = matches.filter((m) => m.similarity >= MATCH_THRESHOLDS.minSimilarity).map((m) => m.id);
    if (ids.length === 0) return [];

    const [{ data: actions }, { data: evidence }] = await Promise.all([
      this.admin.from("actions").select("id, title, counterpart, due_date").eq("user_id", this.userId).in("id", ids).throwOnError(),
      this.admin.from("evidence").select("action_id, quote, created_at").eq("user_id", this.userId).in("action_id", ids).order("created_at").throwOnError(),
    ]);
    const latest = new Map((evidence ?? []).map((e) => [e.action_id as string, e.quote as string]));
    return ids.flatMap((id) => {
      const a = (actions ?? []).find((row) => row.id === id);
      return a ? [{ id, title: a.title, counterpart: a.counterpart, due: a.due_date, latestQuote: latest.get(id) ?? null, embedding: null }] : [];
    });
  }

  async create(action: Omit<TrackedAction, "id">): Promise<TrackedAction> {
    const id = randomUUID();
    const projected = projectAction(action.title, action.claims, action.confirmReasons);
    const first = action.evidence[0];
    await writeAction(this.admin, this.userId, id, {
      expectedVersion: null,
      action: { ...actionRowValues(projected), counterpart: action.counterpart, embedding: action.embedding ? toPgVector(action.embedding) : null },
      claims: action.claims,
      evidence: first,
      events: changeEvents(null, projected, first.role),
      actor: "ai",
    });
    if (projected.needs_confirmation) this.needsConfirmation.add(id);
    return { ...action, id };
  }

  async append(actionId: string, update: { claims: Claim[]; evidence: Evidence; confirmReason?: string }): Promise<void> {
    await retryOnConflict(async () => {
      const row = await loadStoredRow(this.admin, this.userId, actionId);
      if (!row) throw new Error(`없는 Action: ${actionId}`);
      const existing = await loadClaims(this.admin, this.userId, actionId);
      const kept = storedReasons(row.confirm_reasons);
      const before = projectAction(row.title, existing, kept);
      const after = projectAction(row.title, [...existing, ...update.claims], update.confirmReason ? [...kept, update.confirmReason] : kept);

      const written = await writeAction(this.admin, this.userId, actionId, {
        expectedVersion: row.version,
        action: actionRowValues(after),
        claims: update.claims,
        evidence: update.evidence,
        events: changeEvents(before, after, update.evidence.role),
        actor: "ai",
      });
      if (!written) return null;
      if (after.needs_confirmation && !row.needs_confirmation) this.needsConfirmation.add(actionId);
      return true;
    });
  }
}
