import { AiBudgetError } from "@/lib/ai/budget-error";
import { actionEmbedText } from "./merge";

// 임베딩이 없는 열린 Action 채우기. match_open_actions는 embedding이 없는 Action을 후보로 보지 않아서,
// 직접 추가할 때(POST /api/v1/actions) 외부 AI 처리 동의 전이었거나 임베딩이 실패한 Action은 나중 원문에서 같은 일이 나와도
// 새 Action이 하나 더 생긴다 (원칙 4). 원문을 처리할 때 매칭 전에 몇 개씩 채운다 (sources/process.ts).

/** 한 번에 채우는 최대 수 (오래된 것부터). 남은 것은 다음 처리가 채운다 */
export const EMBEDDING_BACKFILL_LIMIT = 20;

export type UnembeddedAction = { id: string; title: string; /** 처음 근거(created) 구절. 원문 없이 직접 추가했으면 null */ quote: string | null };

export interface EmbeddingBackfillStore {
  /** 임베딩이 없는 열린 Action, 오래된 것부터 limit개 */
  unembedded(limit: number): Promise<UnembeddedAction[]>;
  /** 아직 비어 있을 때만 쓴다 */
  saveEmbedding(actionId: string, vector: number[]): Promise<void>;
}

/**
 * 채운 수를 돌려준다. 실패해도 던지지 않는다: 원문 처리를 막지 않고, 남은 Action은 다음 처리가 다시 채운다.
 * 로그에는 오류 메시지만 남긴다 (제목 · 구절 없이).
 */
export async function backfillEmbeddings(
  store: EmbeddingBackfillStore,
  embed: (texts: string[]) => Promise<number[][]>,
  limit = EMBEDDING_BACKFILL_LIMIT,
): Promise<number> {
  try {
    const actions = await store.unembedded(limit);
    if (actions.length === 0) return 0;
    // 직접 추가할 때와 같은 글 (api/create-action.ts): 매칭할 때 후보(제목 + 구절)와 같은 기준으로 잰다.
    const vectors = await embed(actions.map((a) => actionEmbedText(a.title, a.quote)));
    for (const [i, action] of actions.entries()) await store.saveEmbedding(action.id, vectors[i]);
    return actions.length;
  } catch (error) {
    if (error instanceof AiBudgetError) throw error;
    console.error("임베딩 채우기 실패:", error instanceof Error ? error.message : error);
    return 0;
  }
}
