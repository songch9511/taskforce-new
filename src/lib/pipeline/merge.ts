import type { SourceKind } from "./extract";
import type { UserIdentity } from "./identity";
import type { Decide, JudgeSignals } from "./judge";
import { matchCandidate, shortlistActions, type MatchRelation, type OpenAction } from "./match";
import { resolveAction, type Claim } from "./resolve";
import type { JudgedCandidate } from "./run";
import type { VerifiedCandidate } from "./verify";

// 병합 (Phase 2): 판정을 거친 후보를 기존 Action에 붙이거나 새 Action을 만든다.
// Action을 직접 고치지 않는다. 필드별 Claim을 더하고, 현재 값은 resolveAction(claims)가 계산한다.

export type EvidenceRole = "created" | "updated" | "completed" | "duplicate";
export type Evidence = { sourceId: string; quote: string; role: EvidenceRole };

export type TrackedAction = {
  id: string;
  title: string;
  counterpart: string | null;
  embedding: number[] | null;
  claims: Claim[];
  evidence: Evidence[];
  /** 담당이 불확실하거나 Jev가 확인 요청으로 보냈거나 병합이 애매함 */
  confirmReasons: string[];
};

export interface ActionStore {
  /** 아직 끝나지 않은(열린) Action */
  openActions(): Promise<TrackedAction[]>;
  create(action: Omit<TrackedAction, "id">): Promise<TrackedAction>;
  append(actionId: string, update: { claims: Claim[]; evidence: Evidence; confirmReason?: string }): Promise<void>;
}

/** eval · 테스트용. Phase 3에서 같은 인터페이스로 DB 저장소를 붙인다. */
export class InMemoryActionStore implements ActionStore {
  private readonly actions: TrackedAction[] = [];
  private seq = 0;

  all(): TrackedAction[] {
    return this.actions;
  }

  async openActions(): Promise<TrackedAction[]> {
    return this.actions.filter((a) => {
      const status = resolveAction(a.claims).status.value;
      return status !== "done" && status !== "dropped";
    });
  }

  async create(action: Omit<TrackedAction, "id">): Promise<TrackedAction> {
    const created = { ...action, id: `a${++this.seq}` };
    this.actions.push(created);
    return created;
  }

  async append(actionId: string, update: { claims: Claim[]; evidence: Evidence; confirmReason?: string }): Promise<void> {
    const action = this.actions.find((a) => a.id === actionId);
    if (!action) throw new Error(`없는 Action: ${actionId}`);
    action.claims.push(...update.claims);
    action.evidence.push(update.evidence);
    if (update.confirmReason) action.confirmReasons.push(update.confirmReason);
  }
}

export type MergeSource = { id: string; text: string; kind: SourceKind; occurredAt: Date };

/** 후보 하나와 Jev 신호로 Claim을 만든다. 발언 속성(누가 · 얼마나 확정 · 직접 · 공유)은 Jev 판정을 쓴다. */
export function candidateClaims(
  candidate: VerifiedCandidate,
  signals: JudgeSignals,
  source: MergeSource,
  relation: MatchRelation,
  newId: () => string,
): Claim[] {
  const base = {
    occurredAt: source.occurredAt,
    speakerRole: signals.speaker_role.choice,
    certainty: signals.statement_certainty.choice,
    directness: signals.directness.choice,
    audience: signals.audience.choice,
    channel: source.kind,
  };
  const claim = (field: Claim["field"], value: string | null): Claim => ({ id: newId(), field, value, ...base });

  switch (relation) {
    case "new":
      return [
        claim("scope", candidate.title),
        claim("owner", candidate.owner === "me" ? "me" : "unknown"),
        claim("status", "open"),
        ...(candidate.due ? [claim("due", candidate.due)] : []),
      ];
    case "duplicate":
    case "update":
      return candidate.due ? [claim("due", candidate.due)] : [];
    case "complete":
      return [claim("status", "done")];
    case "cancel":
      return [claim("status", "dropped")];
    case "unmatched":
      return [];
  }
}

const EVIDENCE_ROLE: Record<Exclude<MatchRelation, "unmatched">, EvidenceRole> = {
  new: "created",
  duplicate: "duplicate",
  update: "updated",
  complete: "completed",
  cancel: "updated",
};

export type MergeDeps = {
  embed: (texts: string[]) => Promise<number[][]>;
  decide: Decide;
  newId: () => string;
};

export type MergeOutcome = {
  quote: string;
  signal: VerifiedCandidate["signal"];
  relation: MatchRelation | "rejected";
  actionId: string | null;
  confidence: number;
};

const embedText = (title: string, quote: string) => `${title}\n${quote}`;

export async function mergeJudged(
  store: ActionStore,
  judged: JudgedCandidate[],
  source: MergeSource,
  identity: UserIdentity,
  deps: MergeDeps,
): Promise<MergeOutcome[]> {
  const outcomes: MergeOutcome[] = [];
  for (const { candidate, judge } of judged) {
    // Jev가 기각한 새 약속은 버린다. 변화 발언(완료 · 연장 등)은 "내 새 약속"이 아니어서 기각되기 쉬우므로 매칭까지 보낸다.
    if (candidate.signal === "commitment" && judge.decision === "reject") {
      outcomes.push({ quote: candidate.quote, signal: candidate.signal, relation: "rejected", actionId: null, confidence: 1 });
      continue;
    }

    const [vector] = await deps.embed([embedText(candidate.title, candidate.quote)]);
    const open = await store.openActions();
    const openViews: OpenAction[] = open.map((a) => ({
      id: a.id,
      title: a.title,
      counterpart: a.counterpart,
      due: resolveAction(a.claims).due.value,
      latestQuote: a.evidence.at(-1)?.quote ?? null,
      embedding: a.embedding,
    }));
    const match = await matchCandidate(candidate, source, identity, shortlistActions(vector, openViews), deps.decide);
    outcomes.push({ quote: candidate.quote, signal: candidate.signal, relation: match.relation, actionId: match.actionId, confidence: match.confidence });
    if (match.relation === "unmatched") continue;

    const claims = candidateClaims(candidate, judge.signals, source, match.relation, deps.newId);
    const evidence: Evidence = { sourceId: source.id, quote: candidate.quote, role: EVIDENCE_ROLE[match.relation] };

    if (match.relation === "new") {
      const reasons = [
        ...(judge.decision === "confirm" ? [`판정 확인: ${judge.reasons.join(", ")}`] : []),
        ...(candidate.owner !== "me" ? ["담당 확인"] : []),
      ];
      const created = await store.create({
        title: candidate.title,
        counterpart: candidate.counterpart,
        embedding: vector,
        claims,
        evidence: [evidence],
        confirmReasons: reasons,
      });
      outcomes[outcomes.length - 1].actionId = created.id;
    } else {
      await store.append(match.actionId!, {
        claims,
        evidence,
        confirmReason: match.needsConfirmation ? `병합 확인 (${Math.round(match.confidence * 100)}%)` : undefined,
      });
    }
  }
  return outcomes;
}
