import { z } from "zod";

// 임베딩 (OpenRouter embeddings). 새 후보와 비슷한 열린 Action을 찾는 데 쓴다 (docs/TRUTH_RULES.md, Phase 2 매칭).
// 차원은 DB의 actions.embedding(1536)과 맞아야 한다.

const OPENROUTER_EMBEDDINGS_URL = "https://openrouter.ai/api/v1/embeddings";
export const DEFAULT_EMBEDDING_MODEL = "openai/text-embedding-3-small";
export const EMBEDDING_DIMENSIONS = 1536;

export type EmbedConfig = { apiKey: string; model: string; fetch?: typeof fetch; timeoutMs?: number };

export class EmbedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EmbedError";
  }
}

const embeddingResponseSchema = z.object({
  data: z.array(z.object({ index: z.number(), embedding: z.array(z.number()) })),
  usage: z.object({ cost: z.number().optional() }).optional(),
});

export function embedConfigFromEnv(env: Record<string, string | undefined> = process.env): EmbedConfig {
  if (!env.OPENROUTER_API_KEY) throw new EmbedError("OPENROUTER_API_KEY가 필요합니다.");
  return { apiKey: env.OPENROUTER_API_KEY, model: env.EMBEDDING_MODEL || DEFAULT_EMBEDDING_MODEL };
}

export async function embed(config: EmbedConfig, texts: string[]): Promise<{ vectors: number[][]; cost?: number }> {
  if (texts.length === 0) return { vectors: [] };
  const response = await (config.fetch ?? fetch)(OPENROUTER_EMBEDDINGS_URL, {
    signal: AbortSignal.timeout(config.timeoutMs ?? 30_000),
    method: "POST",
    headers: { Authorization: `Bearer ${config.apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: config.model, input: texts, provider: { data_collection: "deny" } }),
  });
  if (!response.ok) throw new EmbedError(`임베딩 요청 실패 (${response.status})`);

  const parsed = embeddingResponseSchema.safeParse(await response.json());
  if (!parsed.success) throw new EmbedError("임베딩 응답 형식이 예상과 다릅니다");
  const vectors = [...parsed.data.data].sort((a, b) => a.index - b.index).map((d) => d.embedding);
  if (vectors.length !== texts.length || vectors.some((v) => v.length !== EMBEDDING_DIMENSIONS)) {
    throw new EmbedError(`임베딩 개수나 차원이 다릅니다 (기대 ${EMBEDDING_DIMENSIONS}차원)`);
  }
  return { vectors, cost: parsed.data.usage?.cost };
}

export function cosine(a: number[], b: number[]): number {
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return na === 0 || nb === 0 ? 0 : dot / Math.sqrt(na * nb);
}
