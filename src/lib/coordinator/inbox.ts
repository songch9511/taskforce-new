import { envelopeSchema, type InboxEnvelope, type InboxEventType } from "./types";

// 사건 봉투 (순수). 생산자가 쌓는 사건의 모양 · dedup_key 규칙 · 아직 원천이 없는 생산자의 어댑터를 둔다. DB는 store.ts.
// 봉투에는 원문 · 발화 글이 없다: refs는 id · 종류 토큰 · 작은 정수뿐이고 DB가 같은 모양을 한 번 더 막는다 (inbox_refs_valid).

/** 사건 종류마다 생산자가 실제로 붙었는가. "연결"은 지금 코드의 실제 성공 경로에 붙은 것만이다 (docs/coordinator.md 표) */
export type ProducerStatus =
  | { status: "connected"; via: string }
  | { status: "envelope_only"; why: string };

export const PRODUCERS: Record<InboxEventType, ProducerStatus> = {
  source_processed: { status: "connected", via: "sources 트리거: processing_status가 done이 되는 UPDATE (같은 트랜잭션)" },
  source_revised: { status: "connected", via: "같은 트리거: 같은 문서(source_document_ids)의 두 번째 revision부터" },
  user_message: { status: "connected", via: "conversation_messages 트리거: role user INSERT (conversation_post_message)" },
  decision_made: { status: "connected", via: "트리거: 사용자 Action 결정(action_events actor user) · 실행 승인 · 승인 철회 · 사용자 멈춤" },
  memory_changed: { status: "connected", via: "work_contexts 트리거: context_version 상승 (기억 · 멤버십 · 멤버 원문 revision)" },
  timer_due: { status: "connected", via: "coordinator_enqueue_due_timers: 코디네이터 sweep이 기한 창(24시간) 안의 열린 Action마다 한 번" },
  reply_observed: { status: "envelope_only", why: "회신 관찰 원천(D5/D6 의존 · 메일 관찰)이 아직 없다" },
  agent_event: { status: "envelope_only", why: "에이전트 게이트웨이(D1) 사건 원천이 아직 없다" },
  dependency_changed: { status: "envelope_only", why: "action_dependencies 표(D6)가 아직 없다" },
  connection_changed: { status: "envelope_only", why: "연결 상태 변화 생산자는 C2 범위 밖이다" },
  bridge_unreachable: { status: "envelope_only", why: "Mac bridge(D2)가 아직 없다" },
};

export const CONNECTED_TYPES = (Object.keys(PRODUCERS) as InboxEventType[]).filter((type) => PRODUCERS[type].status === "connected");

/** 봉투를 만든다 (모양이 틀리면 던진다). 글이 든 refs · 알 수 없는 종류는 여기서 막힌다 */
export function buildEnvelope(input: { userId: string; type: InboxEventType; dedupKey: string; refs: Record<string, unknown> }): InboxEnvelope {
  return envelopeSchema.parse({ user_id: input.userId, type: input.type, dedup_key: input.dedupKey, refs: input.refs });
}

// ───────────────────────── dedup_key (SQL 트리거 · 회수와 같은 규칙. tests/coordinator/producers.test.ts가 실제 사건과 견준다) ─────────────────────────

export const sourceDedupKey = (sourceId: string) => `source:${sourceId}`;
export const messageDedupKey = (messageId: string) => `message:${messageId}`;
export const actionEventDedupKey = (actionEventId: string) => `action_event:${actionEventId}`;
export const approvalDedupKey = (approvalId: string, revoked = false) => `${revoked ? "approval_revoked" : "approval"}:${approvalId}`;
export const runStopDedupKey = (runId: string) => `run_stop:${runId}`;
export const memoryChangedDedupKey = (contextId: string, contextVersion: number) => `memory_changed:${contextId}:${contextVersion}`;
/** 기한 값마다 한 번: 기한이 바뀌면(Claim) 키가 달라져 새 사건이다 */
export const timerDedupKey = (actionId: string, dueAt: Date) => `timer:due_window:${actionId}:${Math.floor(dueAt.getTime() / 1000)}`;

/** timer 사건의 dedup_key에서 그때의 기한(epoch 초). 형식이 아니면 null */
export function timerDueEpoch(dedupKey: string): number | null {
  const match = /^timer:due_window:[0-9a-f-]{36}:(\d{1,12})$/i.exec(dedupKey);
  return match ? Number(match[1]) : null;
}

/** 같은 사용자의 처리 순서: 쌓인 시각, 같은 시각이면 쌓인 순서(seq). SQL coordinator_claim의 머리 선택과 같다 */
export function compareEventOrder(a: { created_at: string | Date; seq: number | string | bigint }, b: { created_at: string | Date; seq: number | string | bigint }): number {
  const at = new Date(a.created_at).getTime() - new Date(b.created_at).getTime();
  if (at !== 0) return at < 0 ? -1 : 1;
  const sa = BigInt(a.seq);
  const sb = BigInt(b.seq);
  return sa === sb ? 0 : sa < sb ? -1 : 1;
}

// ───────────────────────── 아직 원천이 없는 생산자의 어댑터 (순수, 연결 0) ─────────────────────────
// 지금 코드에는 이 사건을 만드는 곳이 없다. 후속 레인(D1 게이트웨이 · D2 bridge · D5/D6 회신 · 의존 · C3 제안)이 붙을 때 이 함수로 봉투를 만든다.
// fixture 시험(ARCH14 등)이 이 어댑터로 만든 봉투를 쓴다. "연결 완료"가 아니다 — PRODUCERS가 envelope_only로 말한다.

const EXTERNAL_ID = /^[A-Za-z0-9._:-]{1,120}$/;
const externalId = (value: string, what: string) => {
  // dedup_key에만 들어간다 (refs에는 넣지 않는다): 외부 id도 공백 · 한글 · 긴 글이 아니어야 한다
  if (!EXTERNAL_ID.test(value)) throw new Error(`${what}: 외부 id 모양이 아니다`);
  return value;
};

/** 회신 분류 종류 (런타임 계약 J6) */
export type ReplyKind = "out_of_office" | "bounce" | "decline" | "requirement_change" | "accept";

export function replyObservedEnvelope(input: { userId: string; actionId: string; replySourceId: string; kind: ReplyKind; dependencyId?: string }): InboxEnvelope {
  return buildEnvelope({
    userId: input.userId,
    type: "reply_observed",
    dedupKey: `reply:${input.replySourceId}`,
    refs: { action_id: input.actionId, reply_source_id: input.replySourceId, kind: input.kind, ...(input.dependencyId ? { dependency_id: input.dependencyId } : {}) },
  });
}

/** 에이전트 사건 종류 (런타임 계약 5장 사건 봉투) */
export type AgentEventKind = "accepted" | "progress" | "question" | "artifact" | "completed" | "failed" | "cancelled" | "unreachable" | "reconcile";

/** (session, event_id)로 한 번 (I07). directive_version · result_revision은 결과 귀속의 입력이다 (도착 순서가 아니다) */
export function agentEventEnvelope(input: {
  userId: string;
  runId: string;
  sessionId: string;
  eventId: string;
  kind: AgentEventKind;
  directiveVersion?: number;
  resultRevision?: number;
}): InboxEnvelope {
  return buildEnvelope({
    userId: input.userId,
    type: "agent_event",
    dedupKey: `agent:${externalId(input.sessionId, "sessionId")}:${externalId(input.eventId, "eventId")}`,
    refs: {
      run_id: input.runId,
      kind: input.kind,
      ...(input.directiveVersion !== undefined ? { directive_version: input.directiveVersion } : {}),
      ...(input.resultRevision !== undefined ? { result_revision: input.resultRevision } : {}),
    },
  });
}

export function dependencyChangedEnvelope(input: { userId: string; actionId: string; dependencyId: string; state: "satisfied" | "cancelled" | "unobservable" | "superseded" }): InboxEnvelope {
  return buildEnvelope({
    userId: input.userId,
    type: "dependency_changed",
    dedupKey: `dependency:${input.dependencyId}:${input.state}`,
    refs: { action_id: input.actionId, dependency_id: input.dependencyId, kind: input.state },
  });
}

export function bridgeUnreachableEnvelope(input: { userId: string; bridgeId: string; sinceEpochSeconds: number }): InboxEnvelope {
  return buildEnvelope({
    userId: input.userId,
    type: "bridge_unreachable",
    dedupKey: `bridge:${input.bridgeId}:unreachable:${input.sinceEpochSeconds}`,
    refs: { bridge_id: input.bridgeId },
  });
}

/** 제안(suggestions)에 대한 사용자 결정. 제안 표(C3)가 없어 연결되지 않았다 */
export function suggestionDecisionEnvelope(input: { userId: string; suggestionId: string; decision: "accepted" | "snoozed" | "dismissed" }): InboxEnvelope {
  return buildEnvelope({
    userId: input.userId,
    type: "decision_made",
    dedupKey: `suggestion:${input.suggestionId}:${input.decision}`,
    refs: { suggestion_id: input.suggestionId, kind: `suggestion_${input.decision}` },
  });
}
