import { REFERENT_CANDIDATE_LIMIT } from "./intent.config";

// 지시 대상(referent) 규칙 (런타임 계약 2장, A34). 쓰기 의도의 대상은 순서대로 하나만 고른다. 제목 유사도만으로 고르지 않는다.
//   1. 앱이 보낸 refs(선택된 Action · run · 산출물) — 하나면 그것, 둘 이상이면 묻는다
//   2. 같은 대화의 직전 assistant 메시지가 낸 열린 proposal (채택)
//   3. 이 대화에 연결된(refs) 열린 Action이 하나뿐이면 그것
//   4. 그래도 둘 이상이면 후보 ≤ 3개를 들어 한 번 묻는다. 묻는 동안 아무것도 쓰지 않는다
// 정한 대상은 사용자 메시지 refs에 남는다 (store가 conversation_finish_turn으로 쓴다). DB와 분리된 순수 함수.

export type Target = { kind: "action"; id: string; title: string } | { kind: "run"; id: string } | { kind: "artifact"; id: string };

export type OpenProposalRef = { messageId: string; proposalId: string; payloadHash: string; title: string };

export type ReferentInput = {
  /** 1번: 앱이 보낸 대상 (소유를 확인한 것만) */
  selected: Target[];
  /** 2번: 바로 앞 assistant 메시지의 열린 제안 (없으면 null) */
  previousProposal: OpenProposalRef | null;
  /** 3 · 4번: 이 대화의 메시지 refs가 가리킨 열린 내 Action (최근 것부터) */
  linkedOpenActions: { id: string; title: string }[];
  /** 채택이면 제안만 대상이 된다 */
  wants: "proposal" | "work";
};

export type Referent =
  | { kind: "proposal"; proposal: OpenProposalRef }
  | { kind: "target"; target: Target; rule: 1 | 3 }
  | { kind: "ask"; candidates: Target[] }
  | { kind: "none" };

export function resolveReferent(input: ReferentInput): Referent {
  if (input.wants === "proposal") {
    return input.previousProposal ? { kind: "proposal", proposal: input.previousProposal } : { kind: "none" };
  }
  if (input.selected.length === 1) return { kind: "target", target: input.selected[0], rule: 1 };
  if (input.selected.length > 1) return { kind: "ask", candidates: input.selected.slice(0, REFERENT_CANDIDATE_LIMIT) };
  const linked = dedupe(input.linkedOpenActions);
  if (linked.length === 1) return { kind: "target", target: { kind: "action", ...linked[0] }, rule: 3 };
  if (linked.length > 1) return { kind: "ask", candidates: linked.slice(0, REFERENT_CANDIDATE_LIMIT).map((a) => ({ kind: "action", ...a })) };
  return { kind: "none" };
}

function dedupe<T extends { id: string }>(items: T[]): T[] {
  const seen = new Set<string>();
  return items.filter((item) => {
    const key = item.id.toLowerCase();
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
