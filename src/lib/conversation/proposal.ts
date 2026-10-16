import { createHash } from "node:crypto";

import { actionRowValues, claimToRow } from "@/lib/actions/rows";
import { userCreatedAction } from "@/lib/actions/user-claims";
import type { Proposal, ProposalPayloadV2 } from "@/lib/api/contract";
import { normalizeForMatch } from "@/lib/pipeline/text";

// 제안(proposal)과 채택 (런타임 계약 2장, A41). 제안은 Action · run이 아니다: adopt가 오면 그때 만든다.
// 제안은 create_action(B2)과 이동 · 삭제 · 병합(move · delete · merge, D4c-2)이다. run · modify · stop 제안은 실행 연결(C/D)이 생길 때 붙인다 — 대화는 실행 객체를 만들지 않는다.
// 채택한 목표는 기존 경로와 같은 모양으로 저장한다: Action + 원문(kind note, 채택한 한 줄) + origin user Claim + user_created 이벤트.
// AI는 due Claim을 쓰지 않는다: 제안에는 기한이 없다 (런타임 계약 3장). 임베딩은 만들지 않는다(모델 호출 없음): 다음 원문 처리가 채운다.

export type ProposalPayload = ProposalPayloadV2;
type CreateActionPayload = Extract<ProposalPayload, { kind: "create_action" }>;

/** Action 제목 상한 (직접 추가 createActionRequestSchema와 같다) */
export const PROPOSAL_TITLE_MAX_CHARS = 200;

/** 해시에 넣는 내용. 종류마다 "무엇이 같으면 같은 확인인가"만 담는다: 이동 · 삭제 · 병합은 대상 id + 카드가 본 Action.version(낡음 판정), 제목 · 숫자 · 세션 수는 넣지 않는다 */
function hashed(payload: ProposalPayload): Record<string, unknown> {
  const targets = (list: readonly { action_id: string; version: number }[]) =>
    list.map((t) => ({ action_id: t.action_id, version: t.version })).sort((a, b) => (a.action_id < b.action_id ? -1 : a.action_id > b.action_id ? 1 : 0));
  switch (payload.kind) {
    case "create_action":
      return { kind: payload.kind, title: payload.title };
    case "move":
      return { kind: payload.kind, targets: targets(payload.targets), from: payload.from?.id ?? null, to: payload.to?.id ?? null };
    case "delete":
      return { kind: payload.kind, targets: targets(payload.targets) };
    case "merge":
      return { kind: payload.kind, targets: targets([payload.from, payload.into]), into: payload.into.action_id };
  }
}

/** 키 이름순으로 정렬한 JSON의 sha256 (create_action은 { kind, title }이라 B2의 값과 같다) */
function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    return `{${Object.entries(value as Record<string, unknown>)
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
      .map(([key, v]) => `${JSON.stringify(key)}:${stableJson(v)}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function payloadHash(payload: ProposalPayload): string {
  return `sha256:${createHash("sha256").update(stableJson(hashed(payload))).digest("hex")}`;
}

/**
 * 모델이 낸 제안 → 저장할 제안. 제목이 비었거나 길거나, 이미 있는 할 일(열린 것 · 최근 끝낸 것)과 같은 제목이면 내지 않는다
 * (원칙 4: 중복을 만들지 않는다, A01: 끝낸 일을 다시 만들지 않는다).
 */
export function proposalFromModel(
  raw: { title: string } | null,
  knownTitles: readonly string[],
  newId: () => string,
): { ref: Proposal; payload: ProposalPayload } | null {
  const title = raw?.title.replace(/\s+/g, " ").trim() ?? "";
  if (!title || [...title].length > PROPOSAL_TITLE_MAX_CHARS) return null;
  const key = normalizeForMatch(title);
  if (!key || knownTitles.some((existing) => normalizeForMatch(existing) === key)) return null;
  const payload: CreateActionPayload = { kind: "create_action", title };
  return { ref: { id: newId(), kind: "create_action", payload_hash: payloadHash(payload), state: "open" }, payload };
}

/** 제안을 새로 내는 쓰기 (이동을 묻는 글 · 삭제 · 병합 카드): 새 id, hash는 내용에서. 앞 열린 제안은 conversation_finish_turn이 superseded로 바꾼다 */
export function newProposal(payload: ProposalPayload, newId: () => string): { ref: Proposal; payload: ProposalPayload } {
  return { ref: { id: newId(), kind: payload.kind, payload_hash: payloadHash(payload), state: "open" }, payload };
}

/** 저장된 제안을 다시 낼 때(채택 확인 질문 · 카드 뒤 대상이 바뀜): 같은 종류 · 새 id. 앞 제안은 conversation_finish_turn이 superseded로 바꾼다 */
export const reissueProposal = newProposal;

/** 저장된 제안의 내용이 hash와 같은가 (글이 지워졌거나 바뀐 제안은 채택하지 않는다) */
export function proposalIntact(ref: Pick<Proposal, "payload_hash" | "kind">, payload: ProposalPayload | null): payload is ProposalPayload {
  if (!payload || ref.kind !== payload.kind) return false;
  if (payload.kind === "create_action" && payload.title.trim() === "") return false;
  return payloadHash(payload) === ref.payload_hash;
}

/** 말로 이동의 한 건 (conversation_finish_turn의 move · adopt.moves): version은 organize_lookup이 읽은 범위 version이다 */
export type MovePlanItem = {
  action_id: string;
  add: { context_id: string; expected_version: number } | null;
  remove: { context_id: string; expected_version: number } | null;
};

/** 이동 제안의 채택 (kind move): 채택한 시점에 다시 푼 이동. 제안 id · hash는 conversation_finish_turn이 열린 제안과 대조한다 */
export type MoveAdoptPlan = { kind: "move"; proposal_message_id: string; proposal_id: string; payload_hash: string; moves: MovePlanItem[] };

/** 삭제 · 병합 한 건의 쓰기 (SQL apply_organize_change의 p_writes 항목): action이 null이면 확인만(병합의 남는 쪽: 값 변화 0, 읽은 version이 그대로인지만 본다) */
export type ChangeWrite = {
  action_id: string;
  expected_version: number;
  action: Record<string, unknown> | null;
  claims: Record<string, unknown>[];
  events: Record<string, unknown>[];
};

/** 삭제 · 병합 카드의 채택(글 "응"): 카드 버튼(conversation_confirm_proposal)과 같은 쓰기 */
export type ChangeAdoptPlan = { kind: "delete" | "merge"; proposal_message_id: string; proposal_id: string; payload_hash: string; writes: ChangeWrite[] };

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
  payload: CreateActionPayload;
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
