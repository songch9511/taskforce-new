import "server-only";

import type { SupabaseClient } from "@supabase/supabase-js";

import { toPgVector } from "@/lib/actions/rows";
import { embed, embedConfigFromEnv } from "@/lib/ai/embed";
import { completeJson, llmConfigFromEnv } from "@/lib/ai/llm";
import { withConsentGate } from "@/lib/consent/gate";
import { consentCheck } from "@/lib/consent/store";
import type { AskAction, AskContext, AskDeps, AskSource } from "@/lib/pipeline/ask";

import { ASK_LIMIT } from "./rate-limit";
import { takeRateLimit } from "./rate-limit-store";

// 물어보기의 DB 쪽: 횟수 제한과 검색. 모두 service role로 부르고 쿼리마다 user_id로 범위를 좁힌다.

/** 질문과 가까운 Action 수 */
const ASK_TOP_K = 8;
/** 끝나거나 취소된 Action은 이 기간 안에 바뀐 것만 찾는다 */
const ASK_CLOSED_DAYS = 30;

/** 한도에 찼으면 다시 할 수 있는 시각. 아니면 시도를 남기고(모델을 부르기 전에) null. 질문은 남기지 않는다. */
export function askRateLimit(admin: SupabaseClient, userId: string): Promise<Date | null> {
  return takeRateLimit(admin, userId, "ask", ASK_LIMIT);
}

type ActionRow = Omit<AskAction, "quotes">;
type QuoteRow = { action_id: string; source_id: string | null; quote: string | null; created_at: string };
type SourceRow = {
  id: string;
  title: string | null;
  kind: string;
  occurred_at: string | null;
  external_url: string | null;
  raw_text: string;
  raw_text_purged_at: string | null;
};

/** 질문 임베딩과 가까운 Action(열린 것 + 최근에 끝난 것)과 그 근거 구절(evidence · 원문 Claim) · 근거 원문 */
export async function retrieveAskContext(admin: SupabaseClient, userId: string, vector: number[], now = new Date()): Promise<AskContext> {
  const { data: matches } = await admin
    .rpc("match_actions_for_ask", {
      p_user_id: userId,
      p_embedding: toPgVector(vector),
      p_count: ASK_TOP_K,
      p_closed_since: new Date(now.getTime() - ASK_CLOSED_DAYS * 86_400_000).toISOString(),
    })
    .throwOnError();
  const ids = ((matches ?? []) as { id: string }[]).map((m) => m.id);
  if (ids.length === 0) return { actions: [], sources: [] };

  const [{ data: actionRows }, { data: evidenceRows }, { data: claimRows }] = await Promise.all([
    admin.from("actions").select("id, title, status, owner, due_date, counterpart").eq("user_id", userId).in("id", ids).throwOnError(),
    admin.from("evidence").select("action_id, source_id, quote, created_at").eq("user_id", userId).in("action_id", ids).throwOnError(),
    admin
      .from("claims")
      .select("action_id, source_id, quote, created_at")
      .eq("user_id", userId)
      .eq("origin", "source")
      .in("action_id", ids)
      .throwOnError(),
  ]);

  // 같은 원문의 같은 구절은 한 번만, 최근 것부터
  const quotes = new Map<string, { sourceId: string; quote: string; at: string }[]>();
  for (const row of [...((evidenceRows ?? []) as QuoteRow[]), ...((claimRows ?? []) as QuoteRow[])]) {
    if (!row.source_id || !row.quote) continue;
    const list = quotes.get(row.action_id) ?? [];
    if (!list.some((q) => q.sourceId === row.source_id && q.quote === row.quote)) list.push({ sourceId: row.source_id, quote: row.quote, at: row.created_at });
    quotes.set(row.action_id, list);
  }

  const byId = new Map(((actionRows ?? []) as ActionRow[]).map((a) => [a.id, a]));
  // 가까운 순서를 지킨다
  const actions: AskAction[] = ids.flatMap((id) => {
    const action = byId.get(id);
    if (!action) return [];
    const list = (quotes.get(id) ?? []).sort((a, b) => b.at.localeCompare(a.at)).map(({ sourceId, quote }) => ({ sourceId, quote }));
    return [{ ...action, quotes: list }];
  });

  const sourceIds = [...new Set(actions.flatMap((a) => a.quotes.map((q) => q.sourceId)))];
  if (sourceIds.length === 0) return { actions, sources: [] };
  const { data: sourceRows } = await admin
    .from("sources")
    .select("id, title, kind, occurred_at, external_url, raw_text, raw_text_purged_at")
    .eq("user_id", userId)
    .in("id", sourceIds)
    .throwOnError();
  const sources: AskSource[] = ((sourceRows ?? []) as SourceRow[]).map((s) => ({
    id: s.id,
    title: s.title,
    kind: s.kind,
    occurredAt: s.occurred_at ? new Date(s.occurred_at) : null,
    externalUrl: s.external_url,
    // 보관 기간(90일)이 지나 글이 지워졌으면 저장된 근거 구절로만 답하고 확인한다 (pipeline/ask.ts)
    text: s.raw_text_purged_at ? null : s.raw_text,
  }));
  return { actions, sources };
}

/** 모델 호출(임베딩 · LLM) 직전마다 외부 AI 처리 동의를 다시 확인한다 (도중에 철회하면 ConsentRequiredError) */
export function askDepsFromEnv(admin: SupabaseClient, userId: string): AskDeps {
  const llm = llmConfigFromEnv();
  const embedding = embedConfigFromEnv();
  return withConsentGate<AskDeps>(
    {
      embed: async (texts) => (await embed(embedding, texts)).vectors,
      retrieve: (vector) => retrieveAskContext(admin, userId, vector),
      complete: (request) => completeJson(llm, request),
    },
    consentCheck(admin, userId),
  );
}
