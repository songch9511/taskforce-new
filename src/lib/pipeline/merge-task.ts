import type { UserIdentity } from "./identity";
import { matchCandidate, type MatchRelation } from "./match";
import { embedText, type ActionStore, type EvidenceRole, type MergeDeps, type TrackedAction } from "./merge";
import { resolveAction, USER_REASON, type ClaimField } from "./resolve";
import { renderSnapshot, snapshotChanges, taskClaims, type SnapshotChange, type TaskEdit, type TaskSnapshot } from "./structured";

// 구조화된 할 일 병합 (docs/INTEGRATIONS.md "Notion 할 일 DB").
// 처음 보는 할 일은 기존 열린 Action과 매칭한다(회의에서 이미 생긴 같은 일일 수 있다). 결과를 연결해 두고,
// 이후 버전은 매칭 없이 그 Action에 바뀐 필드만 Claim으로 붙인다.

export type LinkedAction = {
  actionId: string;
  status: "open" | "done" | "dropped";
  /** 사용자가 앱에서 지운(취소한) Action */
  deletedByUser: boolean;
};

/** 외부 할 일 ↔ Action 연결 (DB에서는 action_links) */
export interface TaskLinkStore {
  linkedAction(externalId: string): Promise<LinkedAction | null>;
  link(externalId: string, actionId: string): Promise<void>;
  /** 이 원문으로 만든 Action (근거 역할 created) */
  actionCreatedFrom(sourceId: string): Promise<string | null>;
}

export class InMemoryTaskLinks implements TaskLinkStore {
  readonly links = new Map<string, string>();
  constructor(private readonly actions: () => TrackedAction[] = () => []) {}

  async linkedAction(externalId: string): Promise<LinkedAction | null> {
    const actionId = this.links.get(externalId);
    if (!actionId) return null;
    const action = this.actions().find((a) => a.id === actionId);
    const status = action ? resolveAction(action.claims).status : null;
    const value = (status?.value ?? "open") as LinkedAction["status"];
    return { actionId, status: value, deletedByUser: value === "dropped" && status?.reason === USER_REASON };
  }

  async link(externalId: string, actionId: string) {
    if (!this.links.has(externalId)) this.links.set(externalId, actionId);
  }

  async actionCreatedFrom(sourceId: string) {
    return this.actions().find((a) => a.evidence.some((e) => e.sourceId === sourceId && e.role === "created"))?.id ?? null;
  }
}

export type TaskInput = {
  externalId: string;
  snapshot: TaskSnapshot;
  /** 이어진 Action이 있을 때 비교할 직전 스냅샷 */
  prev: TaskSnapshot | null;
  edit: TaskEdit;
};

export type TaskMergeOutcome = {
  /** linked: 이미 이어진 Action에 붙임, skipped: 처음 보는데 내 열린 할 일이 아님 */
  relation: MatchRelation | "linked" | "skipped";
  actionId: string | null;
  changes: ClaimField[];
  confidence: number;
};

const roleOf = (change: SnapshotChange): EvidenceRole => (change.field === "status" && change.value === "done" ? "completed" : "updated");

export async function mergeTask(
  store: ActionStore,
  links: TaskLinkStore,
  task: TaskInput,
  source: { id: string; occurredAt: Date },
  identity: UserIdentity,
  deps: MergeDeps,
): Promise<TaskMergeOutcome> {
  const linked = await links.linkedAction(task.externalId);
  if (linked) {
    // 사용자가 앱에서 지운 일은 더 따라가지 않는다. 이미 닫힌 일은 그대로 쌓는다: 확인 큐 · 알림은 열린 Action만 보여서
    // 확인 요청이 늘지 않고, 다시 열렸을 때 닫혀 있던 동안 바뀐 기한 · 담당이 빠지지 않는다.
    const changes = linked.deletedByUser ? [] : snapshotChanges(task.prev, task.snapshot);
    // 필드마다 근거 인용(그 필드의 줄)이 달라서 따로 붙인다.
    for (const change of changes) {
      await store.append(linked.actionId, {
        claims: taskClaims([change], task.edit, deps.newId),
        evidence: { sourceId: source.id, quote: change.quote, role: roleOf(change) },
      });
    }
    return { relation: "linked", actionId: linked.actionId, changes: changes.map((c) => c.field), confidence: 1 };
  }

  // 앞선 처리가 Action을 만든 뒤 연결 직전에 멈췄으면(다시 처리 중) 그 Action에 다시 잇는다: 중복을 만들지 않는다.
  const orphan = await links.actionCreatedFrom(source.id);
  if (orphan) {
    await links.link(task.externalId, orphan);
    return { relation: "linked", actionId: orphan, changes: [], confidence: 1 };
  }

  const { snapshot } = task;
  if (snapshot.owner !== "me" || snapshot.status !== "open") return { relation: "skipped", actionId: null, changes: [], confidence: 1 };

  const changes = snapshotChanges(null, snapshot);
  const claims = taskClaims(changes, task.edit, deps.newId);
  const text = renderSnapshot(snapshot);
  const [vector] = await deps.embed([embedText(snapshot.title, text)]);
  const shortlist = await store.shortlist(vector);
  const match = await matchCandidate(
    { title: snapshot.title, quote: text, due_text: null, due: snapshot.due, signal: "commitment" },
    { text, kind: "task", occurredAt: source.occurredAt },
    identity,
    shortlist,
    deps.decide,
  );
  const fields = changes.map((c) => c.field);

  // 같은 일이 이미 있다 (예: 회의록에서 생긴 Action): 할 일 DB의 값을 Claim으로 더하고 이어 둔다.
  if (match.relation !== "new" && match.actionId && !match.needsConfirmation) {
    await store.append(match.actionId, { claims, evidence: { sourceId: source.id, quote: text, role: "duplicate" } });
    await links.link(task.externalId, match.actionId);
    return { relation: match.relation, actionId: match.actionId, changes: fields, confidence: match.confidence };
  }

  // 새 일이거나, 같은 일인지 확신이 낮다. 확신이 낮을 때 합쳐 버리면 이 할 일의 값(사용자 권한일 수 있음)이 다른 Action을 덮고
  // 이후 완료까지 그쪽에 붙는다. 따로 만들고 중복일 수 있다고 확인을 받는다.
  const similar = match.actionId ? shortlist.find((a) => a.id === match.actionId) : undefined;
  const created = await store.create({
    title: snapshot.title,
    counterpart: null,
    embedding: vector,
    claims,
    evidence: [{ sourceId: source.id, quote: text, role: "created" }],
    confirmReasons: similar ? [`중복 확인 (${Math.round(match.confidence * 100)}%): ${similar.title}`] : [],
  });
  await links.link(task.externalId, created.id);
  return { relation: "new", actionId: created.id, changes: fields, confidence: match.confidence };
}
