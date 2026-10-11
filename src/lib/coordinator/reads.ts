import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { timerDueEpoch } from "./inbox";
import type { Facts, LiveRun } from "./impact";
import type { ClaimedEvent } from "./types";

// 사건이 가리킨 객체를 DB에서 다시 확인해 사실로 바꾼다 (service role, 읽기만). 규칙:
//  - refs jsonb는 권한 증거가 아니다: 모든 읽기는 user_id = 사건의 사용자로 좁힌다. 남의 객체 · 없는 객체 · 지운 객체는 "없음"으로 같다 (남의 것이 있는지 확인하지 않는다).
//  - 후보는 DB의 실제 관계(evidence · claims · context_members · run의 action_id · 메시지의 선택)로 정한다. 글(원문 · 발화)은 읽지 않는다 — id · 상태 · 버전만.
//  - execution_* 표는 읽기만 한다 (살아 있는 run을 찾으려고). 어떤 표에도 쓰지 않는다.

const LIVE_RUN_STATES = ["queued", "running", "waiting_approval"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const asString = (value: unknown): string | null => (typeof value === "string" && UUID.test(value) ? value : null);
const asStrings = (value: unknown): string[] => (Array.isArray(value) ? value.flatMap((v) => (asString(v) ? [v as string] : [])) : []);
const asInt = (value: unknown): number | null => (typeof value === "number" && Number.isInteger(value) ? value : null);
const unique = <T>(values: T[]) => [...new Set(values)];

export interface CoordinatorReads {
  loadFacts(event: Pick<ClaimedEvent, "user_id" | "type" | "dedup_key" | "refs">): Promise<Facts>;
}

export function supabaseCoordinatorReads(admin: SupabaseClient): CoordinatorReads {
  type Row = Record<string, unknown>;
  const rows = async (query: PromiseLike<{ data: unknown }>) => ((await query).data ?? []) as Row[];

  /** 이 사용자의 Action 중 실제로 있는 id만 */
  async function ownedActions(userId: string, ids: string[]): Promise<Row[]> {
    if (ids.length === 0) return [];
    return rows(admin.from("actions").select("id, status, due_at").eq("user_id", userId).in("id", ids).throwOnError());
  }

  async function ownedRuns(userId: string, ids: string[]): Promise<Row[]> {
    if (ids.length === 0) return [];
    return rows(admin.from("execution_runs").select("id, action_id, state").eq("user_id", userId).in("id", ids).throwOnError());
  }

  async function liveRunsOfActions(userId: string, actionIds: string[]): Promise<LiveRun[]> {
    if (actionIds.length === 0) return [];
    const found = await rows(
      admin
        .from("execution_runs")
        .select("id, action_id, context_id, bundle_context_version, directive_version, state")
        .eq("user_id", userId)
        .in("action_id", actionIds)
        .in("state", LIVE_RUN_STATES)
        .throwOnError(),
    );
    return found.map(liveRun);
  }

  const liveRun = (r: Row): LiveRun => ({
    id: r.id as string,
    actionId: r.action_id as string,
    contextId: (r.context_id as string | null) ?? null,
    bundleContextVersion: (r.bundle_context_version as number | null) ?? null,
    directiveVersion: Number(r.directive_version ?? 1),
    //묶음 manifest는 아직 저장하지 않는다 (D1 이후): 모르면 null
    manifest: null,
  });

  async function sourceFacts(userId: string, refs: Row): Promise<Facts> {
    const sourceId = asString(refs.source_id);
    if (!sourceId) return { kind: "source", source: { present: false, accessLost: false }, actionIds: [], contextIds: [], liveRuns: [] };
    const source = (await admin.from("sources").select("id, access_lost_at").eq("user_id", userId).eq("id", sourceId).maybeSingle().throwOnError()).data as Row | null;
    if (!source) return { kind: "source", source: { present: false, accessLost: false }, actionIds: [], contextIds: [], liveRuns: [] };
    // 같은 문서의 revision들(이 원문 포함)로 관계를 찾는다
    const documentIds = asStrings((await admin.rpc("source_document_ids", { p_user_id: userId, p_source_id: sourceId }).throwOnError()).data);
    const ids = documentIds.length > 0 ? documentIds : [sourceId];
    const [evidence, claims, members] = await Promise.all([
      rows(admin.from("evidence").select("action_id").eq("user_id", userId).in("source_id", ids).throwOnError()),
      rows(admin.from("claims").select("action_id").eq("user_id", userId).in("source_id", ids).throwOnError()),
      rows(admin.from("context_members").select("context_id").eq("user_id", userId).in("source_id", ids).is("removed_at", null).throwOnError()),
    ]);
    const actionIds = (await ownedActions(userId, unique([...evidence, ...claims].map((r) => r.action_id as string)))).map((r) => r.id as string);
    const contextIds =
      members.length === 0
        ? []
        : (await rows(admin.from("work_contexts").select("id").eq("user_id", userId).in("id", unique(members.map((r) => r.context_id as string))).throwOnError())).map((r) => r.id as string);
    return {
      kind: "source",
      source: { present: true, accessLost: source.access_lost_at !== null && source.access_lost_at !== undefined },
      actionIds,
      contextIds,
      liveRuns: await liveRunsOfActions(userId, actionIds),
    };
  }

  async function messageFacts(userId: string, refs: Row): Promise<Facts> {
    const messageId = asString(refs.message_id);
    const message = messageId
      ? ((await admin.from("conversation_messages").select("id, role, selected").eq("user_id", userId).eq("id", messageId).maybeSingle().throwOnError()).data as Row | null)
      : null;
    if (!message) return { kind: "message", message: { present: false, isUser: false }, selectedActionIds: [], selectedRunIds: [], dropped: 0 };
    const selected = (message.selected ?? {}) as Row;
    const wantedActions = unique(asStrings(selected.action_ids));
    const wantedRuns = unique(asStrings(selected.run_ids));
    const [actions, runs] = await Promise.all([ownedActions(userId, wantedActions), ownedRuns(userId, wantedRuns)]);
    return {
      kind: "message",
      message: { present: true, isUser: message.role === "user" },
      selectedActionIds: actions.map((r) => r.id as string),
      selectedRunIds: runs.map((r) => r.id as string),
      // 고른 대상 중 이 사용자의 것이 아니거나 사라진 것: 개수만 센다
      dropped: wantedActions.length - actions.length + (wantedRuns.length - runs.length),
    };
  }

  async function decisionFacts(userId: string, refs: Row): Promise<Facts> {
    const none: Facts = { kind: "decision", present: false, actionId: null, liveRuns: [], runIds: [] };
    const kind = typeof refs.kind === "string" ? refs.kind : "";
    if (refs.action_event_id !== undefined) {
      const eventId = asString(refs.action_event_id);
      if (!eventId) return none;
      const found = (await admin.from("action_events").select("id, action_id").eq("user_id", userId).eq("id", eventId).maybeSingle().throwOnError()).data as Row | null;
      if (!found) return none;
      const actionId = found.action_id as string;
      const actions = await ownedActions(userId, [actionId]);
      return { kind: "decision", present: true, actionId: (actions[0]?.id as string | undefined) ?? null, liveRuns: await liveRunsOfActions(userId, actions.map((r) => r.id as string)), runIds: [] };
    }
    // 실행 결정(승인 · 승인 철회 · 멈춤): 가리킨 단계 · run이 이 사용자의 것으로 있어야 한다
    const stepId = asString(refs.step_id);
    let runId = asString(refs.run_id);
    if ((kind === "approval" || kind === "approval_revoked") && stepId) {
      const step = (await admin.from("execution_steps").select("id, run_id").eq("user_id", userId).eq("id", stepId).maybeSingle().throwOnError()).data as Row | null;
      runId = step ? (step.run_id as string) : null;
    }
    if (!runId) return none;
    const run = (await ownedRuns(userId, [runId]))[0];
    if (!run) return none;
    const actions = await ownedActions(userId, [run.action_id as string]);
    return {
      kind: "decision",
      present: true,
      actionId: (actions[0]?.id as string | undefined) ?? null,
      liveRuns: await liveRunsOfActions(userId, actions.map((r) => r.id as string)),
      runIds: [run.id as string],
    };
  }

  async function contextFacts(userId: string, refs: Row): Promise<Facts> {
    const contextId = asString(refs.context_id);
    const found = contextId ? ((await admin.from("work_contexts").select("id, context_version").eq("user_id", userId).eq("id", contextId).maybeSingle().throwOnError()).data as Row | null) : null;
    if (!found) return { kind: "context", context: { present: false, version: 0 }, eventVersion: null, liveRuns: [], changedItemIds: null };
    const live = await rows(
      admin
        .from("execution_runs")
        .select("id, action_id, context_id, bundle_context_version, directive_version, state")
        .eq("user_id", userId)
        .eq("context_id", contextId as string)
        .in("state", LIVE_RUN_STATES)
        .throwOnError(),
    );
    // 어떤 항목이 바뀌었는지는 사건에 없다(id만): 알 수 없으면 null (manifest와 견줄 수 없다)
    return { kind: "context", context: { present: true, version: Number(found.context_version) }, eventVersion: asInt(refs.context_version), liveRuns: live.map(liveRun), changedItemIds: null };
  }

  async function timerFacts(userId: string, refs: Row, dedupKey: string): Promise<Facts> {
    const actionId = asString(refs.action_id);
    const eventDueEpoch = timerDueEpoch(dedupKey);
    const found = actionId ? (await ownedActions(userId, [actionId]))[0] : undefined;
    return {
      kind: "timer",
      action: {
        id: actionId ?? "",
        present: Boolean(found),
        open: found?.status === "open",
        dueEpoch: found?.due_at ? Math.floor(new Date(found.due_at as string).getTime() / 1000) : null,
      },
      eventDueEpoch,
    };
  }

  return {
    async loadFacts(event) {
      const refs = (event.refs ?? {}) as Row;
      switch (event.type) {
        case "source_processed":
        case "source_revised":
          return sourceFacts(event.user_id, refs);
        case "user_message":
          return messageFacts(event.user_id, refs);
        case "decision_made":
          return decisionFacts(event.user_id, refs);
        case "memory_changed":
          return contextFacts(event.user_id, refs);
        case "timer_due":
          return timerFacts(event.user_id, refs, event.dedup_key);
        default:
          // 생산자가 아직 없는 종류 (reply_observed · agent_event · dependency_changed · connection_changed · bridge_unreachable)
          return { kind: "unsupported" };
      }
    },
  };
}
