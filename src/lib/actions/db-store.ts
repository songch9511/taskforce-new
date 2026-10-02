import "server-only";

import { randomUUID } from "node:crypto";

import type { SupabaseClient } from "@supabase/supabase-js";

import type { EmbeddingBackfillStore, UnembeddedAction } from "@/lib/pipeline/backfill-embeddings";
import { MATCH_THRESHOLDS, type OpenAction } from "@/lib/pipeline/match";
import { withoutJudgeReasons, type ActionStore, type AppendUpdate, type Evidence, type TrackedAction } from "@/lib/pipeline/merge";
import type { LinkedAction, TaskLinkStore } from "@/lib/pipeline/merge-task";
import { USER_REASON } from "@/lib/pipeline/resolve";
import type { Claim } from "@/lib/pipeline/resolve";
import { SLACK_DISCONNECTED_QUOTE } from "@/lib/retention";

import { changeEvents, projectAction, withConfirmationChange, type ActionStatus, type EventDraft } from "./project";
import { isConfirmationEligible } from "./rank";
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

/** write_action · set_action_progress에 넘기는 인자 */
function writeParams(userId: string, actionId: string, write: ActionWrite) {
  return {
    p_user_id: userId,
    p_action_id: actionId,
    p_expected_version: write.expectedVersion,
    p_action: write.action,
    p_claims: write.claims.map((c) => claimToRow(c, userId, actionId, write.evidence)),
    p_evidence: write.evidence.role ? [{ source_id: write.evidence.sourceId, quote: write.evidence.quote, role: write.evidence.role }] : [],
    p_events: write.events.map((e) => ({ type: e.type, before: e.before, after: e.after, rule: e.rule, actor: e.actor ?? write.actor, source_id: write.evidence.sourceId })),
  };
}

/** Action 행 · Claim · 근거 · 이벤트를 한 트랜잭션으로 쓴다 (DB 함수 write_action). 버전이 어긋나면 false. */
export async function writeAction(admin: SupabaseClient, userId: string, actionId: string, write: ActionWrite): Promise<boolean> {
  const { data } = await admin.rpc("write_action", writeParams(userId, actionId, write)).throwOnError();
  return data === true;
}

/**
 * 작업 상태 바꾸기를 한 트랜잭션으로 쓴다 (DB 함수 set_action_progress): 상태 쓰기(write_action과 같은 것, null이면 상태는 그대로)
 * 뒤에 착수 시각을 바꾼다. started: true 착수(start_action) · false 착수 되돌리기(user_unstarted) · null 그대로.
 * 버전이 어긋나면(그 사이 누가 썼으면) 아무것도 쓰지 않고 false.
 */
export async function writeProgress(
  admin: SupabaseClient,
  userId: string,
  actionId: string,
  expectedVersion: number,
  statusWrite: ActionWrite | null,
  started: boolean | null,
): Promise<boolean> {
  const status = statusWrite
    ? writeParams(userId, actionId, statusWrite)
    : { p_user_id: userId, p_action_id: actionId, p_action: null, p_claims: [], p_evidence: [], p_events: [] };
  const { data } = await admin.rpc("set_action_progress", { ...status, p_expected_version: expectedVersion, p_started: started }).throwOnError();
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

export type StoredRow = {
  title: string;
  confirm_reasons: string[];
  needs_confirmation: boolean;
  version: number;
  status: ActionStatus;
  started_at: string | null;
};

export async function loadStoredRow(admin: SupabaseClient, userId: string, actionId: string): Promise<StoredRow | null> {
  const { data } = await admin
    .from("actions")
    .select("title, confirm_reasons, needs_confirmation, version, status, started_at")
    .eq("user_id", userId)
    .eq("id", actionId)
    .maybeSingle()
    .throwOnError();
  return data as StoredRow | null;
}

export class SupabaseActionStore implements ActionStore, EmbeddingBackfillStore {
  /** 이번 처리에서 확인 요청이 새로 생긴 Action (알림용) */
  readonly needsConfirmation = new Set<string>();

  constructor(
    private readonly admin: SupabaseClient,
    private readonly userId: string,
    /** 새 Action을 만들 때 같은 트랜잭션에 더 남길 이벤트 (누락 신고의 user_reported_missing) */
    private readonly options: { createEvents?: EventDraft[] } = {},
  ) {}

  async shortlist(vector: number[]): Promise<OpenAction[]> {
    const { data } = await this.admin
      .rpc("match_open_actions", { p_user_id: this.userId, p_embedding: toPgVector(vector), p_count: MATCH_THRESHOLDS.shortlistSize })
      .throwOnError();
    const matches = (data ?? []) as { id: string; similarity: number }[];
    const ids = matches.filter((m) => m.similarity >= MATCH_THRESHOLDS.minSimilarity).map((m) => m.id);
    if (ids.length === 0) return [];

    const [{ data: actions }, { data: evidence }] = await Promise.all([
      this.admin.from("actions").select("id, title, counterpart, due_date, owner").eq("user_id", this.userId).in("id", ids).throwOnError(),
      this.admin.from("evidence").select("action_id, quote, role, created_at").eq("user_id", this.userId).in("action_id", ids).order("created_at").throwOnError(),
    ]);
    // 빈 인용 · Slack 연결을 끊어 지운 인용 자리 표시는 근거가 아니다 (latest_quote에는 그 전 인용을 넘긴다).
    // 실행 receipt(role executed, "초안 저장: <모델이 쓴 제목>")도 원문 인용이 아니라 매칭 판정에 넘기지 않는다
    const latest = new Map(
      (evidence ?? [])
        .filter((e) => e.quote && e.quote !== SLACK_DISCONNECTED_QUOTE && e.role !== "executed")
        .map((e) => [e.action_id as string, e.quote as string]),
    );
    return ids.flatMap((id) => {
      const a = (actions ?? []).find((row) => row.id === id);
      return a ? [{ id, title: a.title, counterpart: a.counterpart, due: a.due_date, latestQuote: latest.get(id) ?? null, embedding: null, owner: a.owner }] : [];
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
      events: [...changeEvents(null, projected, first.role), ...(this.options.createEvents ?? [])],
      actor: "ai",
    });
    if (isConfirmationEligible(projected)) this.needsConfirmation.add(id);
    return { ...action, id };
  }

  async append(actionId: string, update: AppendUpdate): Promise<void> {
    await retryOnConflict(async () => {
      const row = await loadStoredRow(this.admin, this.userId, actionId);
      if (!row) throw new Error(`없는 Action: ${actionId}`);
      const existing = await loadClaims(this.admin, this.userId, actionId);
      const kept = storedReasons(row.confirm_reasons);
      const before = projectAction(row.title, existing, kept);
      const stays = update.clearJudgeReasons ? withoutJudgeReasons(kept) : kept;
      const confirmReasons = update.confirmReasons ?? [];
      const after = projectAction(
        row.title,
        [...existing, ...update.claims],
        [...stays, ...confirmReasons, ...(update.confirmReason ? [update.confirmReason] : [])],
      );

      const written = await writeAction(this.admin, this.userId, actionId, {
        expectedVersion: row.version,
        action: actionRowValues(after),
        claims: update.claims,
        evidence: update.evidence,
        events: withConfirmationChange(changeEvents(before, after, update.evidence.role), before, after),
        actor: "ai",
      });
      if (!written) return null;
      if (isConfirmationEligible(after)) {
        if (!isConfirmationEligible(before)) this.needsConfirmation.add(actionId);
      } else {
        this.needsConfirmation.delete(actionId);
      }
      return true;
    });
  }

  async unembedded(limit: number): Promise<UnembeddedAction[]> {
    const { data: actions } = await this.admin
      .from("actions")
      .select("id, title")
      .eq("user_id", this.userId)
      .eq("status", "open")
      .is("embedding", null)
      .order("created_at")
      .limit(limit)
      .throwOnError();
    const rows = (actions ?? []) as { id: string; title: string }[];
    if (rows.length === 0) return [];
    const { data: evidence } = await this.admin
      .from("evidence")
      .select("action_id, quote")
      .eq("user_id", this.userId)
      .eq("role", "created")
      .in("action_id", rows.map((r) => r.id))
      .order("created_at")
      .throwOnError();
    const quotes = new Map<string, string>();
    // Slack 연결을 끊어 지운 인용 자리 표시는 임베딩에 넣지 않는다 (제목만으로 만든다)
    for (const e of (evidence ?? []) as { action_id: string; quote: string }[]) {
      if (!quotes.has(e.action_id) && e.quote !== SLACK_DISCONNECTED_QUOTE) quotes.set(e.action_id, e.quote);
    }
    return rows.map((r) => ({ id: r.id, title: r.title, quote: quotes.get(r.id) ?? null }));
  }

  /** 매칭용 내부 값이라 버전 · 이벤트 없이 쓴다 (사용자에게 보이는 필드가 아니다). 그 사이 채워졌으면 두고 간다. */
  async saveEmbedding(actionId: string, vector: number[]): Promise<void> {
    await this.admin
      .from("actions")
      .update({ embedding: toPgVector(vector) })
      .eq("user_id", this.userId)
      .eq("id", actionId)
      .is("embedding", null)
      .throwOnError();
  }
}

/** 외부 할 일 ↔ Action 연결 (action_links). 연결마다 범위를 좁힌다. */
export class SupabaseTaskLinks implements TaskLinkStore {
  constructor(
    private readonly admin: SupabaseClient,
    private readonly userId: string,
    private readonly connectionId: string,
  ) {}

  async linkedAction(externalId: string): Promise<LinkedAction | null> {
    const { data: link } = await this.admin
      .from("action_links")
      .select("action_id")
      .eq("user_id", this.userId)
      .eq("connection_id", this.connectionId)
      .eq("external_id", externalId)
      .maybeSingle()
      .throwOnError();
    return link ? this.state(link.action_id as string) : null;
  }

  async actionFromTextSource(externalId: string): Promise<LinkedAction | null> {
    const { data: sources } = await this.admin
      .from("sources")
      .select("id")
      .eq("user_id", this.userId)
      .eq("connection_id", this.connectionId)
      .eq("external_id", externalId)
      .neq("kind", "task")
      .throwOnError();
    const sourceIds = ((sources ?? []) as { id: string }[]).map((s) => s.id);
    if (sourceIds.length === 0) return null;
    const { data: evidence } = await this.admin.from("evidence").select("action_id").eq("user_id", this.userId).in("source_id", sourceIds).throwOnError();
    const actionIds = [...new Set(((evidence ?? []) as { action_id: string }[]).map((e) => e.action_id))];
    return actionIds.length === 1 ? this.state(actionIds[0]) : null;
  }

  private async state(actionId: string): Promise<LinkedAction> {
    const { data: action } = await this.admin
      .from("actions")
      .select("status, resolution")
      .eq("user_id", this.userId)
      .eq("id", actionId)
      .single()
      .throwOnError();
    const status = action.status as LinkedAction["status"];
    const reason = (action.resolution as { status?: { reason?: string } } | null)?.status?.reason;
    return { actionId, status, deletedByUser: status === "dropped" && reason === USER_REASON };
  }

  async actionCreatedFrom(sourceId: string): Promise<string | null> {
    const { data } = await this.admin
      .from("evidence")
      .select("action_id")
      .eq("user_id", this.userId)
      .eq("source_id", sourceId)
      .eq("role", "created")
      .limit(1)
      .maybeSingle()
      .throwOnError();
    return (data?.action_id as string | undefined) ?? null;
  }

  async link(externalId: string, actionId: string): Promise<void> {
    // 이미 이어져 있으면 그대로 둔다 (처음 연결이 이긴다).
    await this.admin
      .from("action_links")
      .upsert(
        { user_id: this.userId, connection_id: this.connectionId, external_id: externalId, action_id: actionId },
        { onConflict: "connection_id,external_id", ignoreDuplicates: true },
      )
      .throwOnError();
  }
}
