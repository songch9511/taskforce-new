import { participantsSchema } from "@/lib/api/contract";
import type { Participants } from "@/lib/pipeline/identity";
import { SLACK_DISCONNECTED_QUOTE } from "@/lib/retention";

import { buildExecutionContext, type ExecutionAction, type ExecutionContext, type ExecutionContextInput, type ExecutionSource } from "./context";
import type { ExecutionStore, RunRow } from "./types";

// 실행 자료(context.ts 입력)를 DB 행에서 만든다. 읽기(store.ts · 테스트 store)와 나눈 순수 함수라 DB 모양 그대로 시험한다.
// 원문이 어디서 왔는지는 sources.connection_id가 가리키는 connections.provider로 정한다 (행에 provider 열이 없다).
// Slack 판단이 빈 provider에 기대지 않게, 출처를 확인할 수 없는 원문은 근거째 뺀다:
//   - 연결이 있는데 그 연결 행을 찾지 못함 (읽는 사이에 연결을 끊음)
//   - 연결 없이 외부 항목 id(external_id)만 있음: 연동으로 들어왔는데 연결 행이 지워졌다 (Slack일 수 있다)
// 연결도 외부 id도 없는 원문은 사용자가 직접 넣은 원문이다 (POST /api/v1/sources). 남은 Slack 판단(지운 이유 · 링크)은 context.ts가 한다.
// 실행 receipt(kind execution, U2 PR7)는 연결 없이 외부 id(단계 id)를 갖지만 출처가 분명한 내부 기록이다: 출처 모름으로 빼지 않고 넘겨
// context.ts가 receipt로 빼고 센다(excluded.receipts).

export type ActionRow = { title: string; status: ExecutionAction["status"]; owner: ExecutionAction["owner"]; due_date: string | null; counterpart: string | null };
export type EvidenceRow = { source_id: string; quote: string };
export type SourceRow = {
  id: string;
  kind: string;
  title: string | null;
  raw_text: string | null;
  raw_text_purged_at: string | null;
  raw_text_purge_reason: string | null;
  occurred_at: string | null;
  participants: unknown;
  external_url: string | null;
  external_id: string | null;
  connection_id: string | null;
};
export type ConnectionRow = { id: string; provider: string };


function participantsOf(value: unknown): Participants | null {
  const parsed = participantsSchema.safeParse(value);
  return parsed.success ? parsed.data : null;
}

/** 원문을 가져온 서비스. undefined면 출처를 확인할 수 없다 (뺀다), null이면 직접 넣은 원문 */
function providerOf(source: SourceRow, providers: Map<string, string>): string | null | undefined {
  if (source.kind === "execution") return null;
  if (source.connection_id) return providers.get(source.connection_id);
  return source.external_id ? undefined : null;
}

export function materialFromRows(rows: {
  action: ActionRow;
  evidence: EvidenceRow[];
  sources: SourceRow[];
  connections: ConnectionRow[];
}): ExecutionContextInput {
  const providers = new Map(rows.connections.map((c) => [c.id, c.provider]));
  const sources: ExecutionSource[] = [];
  const unknown = new Set<string>();
  for (const s of rows.sources) {
    const provider = providerOf(s, providers);
    if (provider === undefined) {
      unknown.add(s.id);
      continue;
    }
    const purged = Boolean(s.raw_text_purged_at);
    sources.push({
      id: s.id,
      kind: s.kind,
      title: s.title,
      occurredAt: s.occurred_at ? new Date(s.occurred_at) : null,
      provider,
      purgeReason: s.raw_text_purge_reason === "retention" || s.raw_text_purge_reason === "disconnected" ? s.raw_text_purge_reason : purged ? "retention" : null,
      text: purged ? null : s.raw_text,
      participants: participantsOf(s.participants),
      externalUrl: s.external_url,
    });
  }
  // Slack 연결을 끊어 지운 인용 자리 표시는 근거가 아니다 (retention.ts)
  const evidence = rows.evidence
    .filter((e) => e.quote && e.quote !== SLACK_DISCONNECTED_QUOTE && !unknown.has(e.source_id))
    .map((e) => ({ sourceId: e.source_id, quote: e.quote }));
  const a = rows.action;
  return { action: { title: a.title, status: a.status, owner: a.owner, due_date: a.due_date, counterpart: a.counterpart }, sources, evidence };
}

/** run을 만든 뒤 Action이 지워졌다: 다시 해도 같으므로 단계를 실패로 끝낸다 */
export class ExecutionInputError extends Error {
  constructor(readonly code: "action_missing") {
    super(`실행 자료 없음 (${code})`);
    this.name = "ExecutionInputError";
  }
}

/** 계획 · 초안 단계가 모델에 줄 자료와 사용자 이름 (lease를 잡은 뒤 읽는다) */
export async function loadExecutionContext(store: ExecutionStore, run: RunRow): Promise<{ context: ExecutionContext; name: string }> {
  const [material, name] = await Promise.all([store.loadMaterial(run.user_id, run.action_id), store.userName(run.user_id)]);
  if (!material) throw new ExecutionInputError("action_missing");
  return { context: buildExecutionContext(material), name };
}
