import type { SupabaseClient } from "@supabase/supabase-js";

import type { Attachment, AttachmentKind } from "@/lib/api/contract";

// 맥락 칩 (Assistant 계약 v3 2.1–2.3): 정규화 · selected 모양 · 소유 확인. 두 대상(taskforce · agent)이 같은 규칙을 쓴다.
// 칩 id는 로그에 남기지 않는다. 소유 확인은 사용자 id로 좁힌 읽기뿐이다 (쓰기 0).

const compare = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

/** (kind, id) 소문자 · 중복 제거 · 정렬(종류 → id). 같은 (kind, id)가 auto와 added로 함께 오면 added 하나 */
export function normalizeAttachments(attachments: readonly Attachment[] | undefined): Attachment[] {
  const byKey = new Map<string, Attachment>();
  for (const item of attachments ?? []) {
    const id = item.id.toLowerCase();
    const key = `${item.kind}:${id}`;
    const existing = byKey.get(key);
    if (!existing || (existing.origin === "auto" && item.origin === "added")) byKey.set(key, { kind: item.kind, id, origin: item.origin });
  }
  return [...byKey.values()].sort((a, b) => compare(a.kind, b.kind) || compare(a.id, b.id));
}

/** 옛 refs(action_ids · run_ids · artifact_ids)는 모두 added 칩이다 */
export function attachmentsFromLegacyRefs(refs: { action_ids?: string[]; run_ids?: string[]; artifact_ids?: string[] } | undefined): Attachment[] {
  return [
    ...(refs?.action_ids ?? []).map((id): Attachment => ({ kind: "action", id, origin: "added" })),
    ...(refs?.run_ids ?? []).map((id): Attachment => ({ kind: "run", id, origin: "added" })),
    ...(refs?.artifact_ids ?? []).map((id): Attachment => ({ kind: "artifact", id, origin: "added" })),
  ];
}

const added = (attachments: readonly Attachment[], kind: AttachmentKind) => attachments.filter((item) => item.kind === kind && item.origin === "added").map((item) => item.id);

/** 대상 agent의 selected (OD-3): 재개 경로(startNextQueuedTurn)가 { action_ids, context_ids }를 그대로 읽고, 같은 제출 비교는 칩 전체를 본다. auto 칩은 id 목록에 넣지 않는다 */
export function agentSelected(attachments: readonly Attachment[]) {
  return { action_ids: added(attachments, "action"), context_ids: added(attachments, "context"), attachments: [...attachments] };
}

/**
 * 대상 taskforce의 저장용 selected (OD-5): 기존 { action_ids, run_ids, artifact_ids } + attachments. 칩에서만 정해진다 — 존재 확인과 무관하다.
 * 같은 제출 비교(멱등)가 칩이 지워진 뒤에도 처음 제출과 같게 하려는 것이다(검토 반영 7-3). 칩이 없으면 attachments 키를 만들지 않는다: 옛 제출과 같은 제출로 비교된다
 */
export function taskforceSelected(attachments: readonly Attachment[]) {
  const refs = { action_ids: added(attachments, "action"), run_ids: added(attachments, "run"), artifact_ids: added(attachments, "artifact") };
  return attachments.length ? { ...refs, attachments: [...attachments] } : refs;
}

/**
 * 대상 taskforce의 처리용 refs: 지금의 지시 대상 규칙 1에 쓰는 것. added action · run · (execution_artifacts의) artifact만이고,
 * 지워진(missing) 칩과 에이전트 산출물은 뺀다 — 저장만 한다 (검토 반영 7-3: 처리 입력에서는 dropped 첨부를 뺀다)
 */
export function taskforceRefs(attachments: readonly Attachment[], check: { missing: readonly Attachment[]; executionArtifactIds: readonly string[] }) {
  const gone = new Set(check.missing.map((item) => `${item.kind}:${item.id.toLowerCase()}`));
  const execution = new Set(check.executionArtifactIds);
  const live = (kind: AttachmentKind) => added(attachments, kind).filter((id) => !gone.has(`${kind}:${id}`));
  return { action_ids: live("action"), run_ids: live("run"), artifact_ids: live("artifact").filter((id) => execution.has(id)) };
}

export type AttachmentCheck = {
  /** 내 것이 아니거나 없다 */
  missing: Attachment[];
  /** 내 source인데 Slack 연결 해제로 글이 지워졌다 (받되 에이전트로는 보내지 않는다) */
  purged: Attachment[];
  /** artifact 칩 중 execution_artifacts의 id (taskforce의 지시 대상 규칙 1에 쓸 수 있는 것) */
  executionArtifactIds: string[];
};

const TABLE: Record<Exclude<AttachmentKind, "artifact">, string> = {
  action: "actions",
  context: "work_contexts",
  agent_session: "agent_sessions",
  run: "execution_runs",
  source: "sources",
};

async function ownedIds(admin: SupabaseClient, table: string, userId: string, ids: string[], columns = "id"): Promise<Record<string, unknown>[]> {
  const { data } = await admin.from(table).select(columns).eq("user_id", userId).in("id", ids).throwOnError();
  return (data ?? []) as unknown as Record<string, unknown>[];
}

/** 정규화한 칩이 모두 이 사용자의 것인지 종류별로 한 번씩 읽는다 (AC-1). 남의 id와 없는 id는 구별하지 않는다 */
export async function checkAttachments(admin: SupabaseClient, userId: string, attachments: readonly Attachment[]): Promise<AttachmentCheck> {
  const ids = (kind: AttachmentKind) => attachments.filter((item) => item.kind === kind).map((item) => item.id.toLowerCase());
  const found = new Map<AttachmentKind, Set<string>>();
  const purgedSources = new Set<string>();
  const executionArtifacts = new Set<string>();
  const lower = (rows: Record<string, unknown>[]) => rows.map((row) => String(row.id).toLowerCase());

  await Promise.all(
    (Object.keys(TABLE) as (keyof typeof TABLE)[]).map(async (kind) => {
      const wanted = ids(kind);
      if (!wanted.length) return;
      const rows = await ownedIds(admin, TABLE[kind], userId, wanted, kind === "source" ? "id, raw_text_purge_reason" : "id");
      found.set(kind, new Set(lower(rows)));
      if (kind === "source") for (const row of rows) if (row.raw_text_purge_reason === "disconnected") purgedSources.add(String(row.id).toLowerCase());
    }),
  );

  const artifactIds = ids("artifact");
  if (artifactIds.length) {
    // 두 표 어느 쪽 id든 받는다 (OD-24: 내장 초안 execution_artifacts · 에이전트 산출물 agent_artifacts)
    const [execution, agent] = await Promise.all([ownedIds(admin, "execution_artifacts", userId, artifactIds), ownedIds(admin, "agent_artifacts", userId, artifactIds)]);
    for (const id of lower(execution)) executionArtifacts.add(id);
    found.set("artifact", new Set([...lower(execution), ...lower(agent)]));
  }

  return {
    missing: attachments.filter((item) => !found.get(item.kind)?.has(item.id.toLowerCase())),
    purged: attachments.filter((item) => item.kind === "source" && purgedSources.has(item.id.toLowerCase())),
    executionArtifactIds: [...executionArtifacts].sort(),
  };
}
