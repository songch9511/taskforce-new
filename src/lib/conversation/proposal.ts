import { createHash } from "node:crypto";

import { actionRowValues, claimToRow } from "@/lib/actions/rows";
import { userCreatedAction } from "@/lib/actions/user-claims";
import type { ConversationMessageContent, Proposal } from "@/lib/api/contract";
import { normalizeForMatch } from "@/lib/pipeline/text";

// 제안(proposal)과 채택 (런타임 계약 2장, A41). 제안은 Action · run이 아니다: adopt가 오면 그때 만든다.
// B2가 내는 제안은 create_action 하나뿐이다. run · modify · stop 제안은 실행 연결(C/D)이 생길 때 붙인다 — B2는 실행 객체를 만들지 않는다.
// 채택한 목표는 기존 경로와 같은 모양으로 저장한다: Action + 원문(kind note, 채택한 한 줄) + origin user Claim + user_created 이벤트.
// AI는 due Claim을 쓰지 않는다: 제안에는 기한이 없다 (런타임 계약 3장). 임베딩은 만들지 않는다(모델 호출 없음): 다음 원문 처리가 채운다.

export type ProposalPayload = NonNullable<ConversationMessageContent["proposal"]>;

/** Action 제목 상한 (직접 추가 createActionRequestSchema와 같다) */
export const PROPOSAL_TITLE_MAX_CHARS = 200;

/** 키 순서를 고정한 JSON의 sha256 */
export function payloadHash(payload: ProposalPayload): string {
  return `sha256:${createHash("sha256").update(JSON.stringify({ kind: payload.kind, title: payload.title })).digest("hex")}`;
}

/**
 * 모델이 낸 제안 → 저장할 제안. 제목이 비었거나 길거나, 이미 열려 있는 할 일과 같은 제목이면 내지 않는다 (원칙 4: 중복을 만들지 않는다).
 */
export function proposalFromModel(
  raw: { title: string } | null,
  openActionTitles: readonly string[],
  newId: () => string,
): { ref: Proposal; payload: ProposalPayload } | null {
  const title = raw?.title.replace(/\s+/g, " ").trim() ?? "";
  if (!title || [...title].length > PROPOSAL_TITLE_MAX_CHARS) return null;
  const key = normalizeForMatch(title);
  if (!key || openActionTitles.some((existing) => normalizeForMatch(existing) === key)) return null;
  const payload: ProposalPayload = { kind: "create_action", title };
  return { ref: { id: newId(), kind: "create_action", payload_hash: payloadHash(payload), state: "open" }, payload };
}

/** 저장된 제안을 다시 낼 때(채택 확인 질문): 같은 내용 · 새 id. 앞 제안은 conversation_finish_turn이 superseded로 바꾼다 */
export function reissueProposal(payload: ProposalPayload, newId: () => string): { ref: Proposal; payload: ProposalPayload } {
  return { ref: { id: newId(), kind: "create_action", payload_hash: payloadHash(payload), state: "open" }, payload };
}

/** 저장된 제안의 내용이 hash와 같은가 (글이 지워졌거나 바뀐 제안은 채택하지 않는다) */
export function proposalIntact(ref: Pick<Proposal, "payload_hash" | "kind">, payload: ProposalPayload | null): payload is ProposalPayload {
  return Boolean(payload) && ref.kind === "create_action" && payload!.kind === "create_action" && payload!.title.trim() !== "" && payloadHash(payload!) === ref.payload_hash;
}

export type AdoptPlan = {
  proposal_message_id: string;
  proposal_id: string;
  payload_hash: string;
  action_id: string;
  note: { id: string; title: string; raw_text: string; external_url: string };
  action: Record<string, unknown>;
  claims: Record<string, unknown>[];
  evidence: { source_id: string; quote: string; role: "created" }[];
  events: Record<string, unknown>[];
};

/** 채택한 발화(사용자 메시지)로 가는 링크 (런타임 계약 1장: taskforce://conversations/<id>#<message>) */
export function conversationLink(conversationId: string, messageId: string): string {
  return `taskforce://conversations/${conversationId}#${messageId}`;
}

/**
 * 채택 쓰기 계획 (conversation_finish_turn의 adopt). 값은 사용자 Claim에서 판정한다(원칙 5): 제목 · 담당 나 · 열림, 기한 없음.
 * 근거는 채택한 한 줄(note 원문)이고 그 인용이 Claim · 근거의 quote다 (원칙 2: 사용자가 직접 추가한 값은 사용자 Claim이 근거).
 */
export function adoptPlan(input: {
  userId: string;
  conversationId: string;
  adoptMessageId: string;
  proposalMessageId: string;
  proposal: Pick<Proposal, "id" | "payload_hash">;
  payload: ProposalPayload;
  now: Date;
  newId: () => string;
}): AdoptPlan {
  const actionId = input.newId();
  const noteId = input.newId();
  const title = input.payload.title;
  const { claims, projected, event } = userCreatedAction({ title, dueDate: null, sourceId: noteId }, input.now, input.newId);
  const evidence = { sourceId: noteId, quote: title };
  return {
    proposal_message_id: input.proposalMessageId,
    proposal_id: input.proposal.id,
    payload_hash: input.proposal.payload_hash,
    action_id: actionId,
    note: { id: noteId, title: "Taskforce 대화", raw_text: title, external_url: conversationLink(input.conversationId, input.adoptMessageId) },
    action: { ...actionRowValues(projected), counterpart: null, embedding: null },
    claims: claims.map((claim) => claimToRow(claim, input.userId, actionId, evidence)),
    evidence: [{ source_id: noteId, quote: title, role: "created" }],
    events: [{ type: event.type, before: event.before, after: event.after, rule: event.rule, actor: "user", source_id: noteId }],
  };
}
