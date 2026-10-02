import { z } from "zod";

// OpenRouter generation 메타데이터 조회 (GET /api/v1/generation?id=). LLM 시도 기록(llm.ts LlmAttempt)의 비용을 나중에 확정할 때 쓴다
// (응답에 usage.cost가 없던 시도, 실행기 sweep의 원가 확정).
// 사용자 글은 보내지도 받지도 않는다: 요청은 generation id뿐이고, 응답에는 모델 · 공급자 · 토큰 수 · 비용만 있다.
// 2026-10-02 개발 키로 확인: 응답의 id("gen-…")가 generation id다. 생성 직후 몇 초는 404("Generation … not found")이고
// 10~20초 뒤 200이 됐다. total_cost는 같은 응답의 usage.cost와 같았다(Together, glm-5.3-flash).

const OPENROUTER_GENERATION_URL = "https://openrouter.ai/api/v1/generation";

/** OpenRouter 문서의 generation id 형식 (최대 128자). 이 형식이 아니면 부르지 않는다 */
const GENERATION_ID = /^gen-[0-9A-Za-z-]{1,124}$/;

export const GENERATION_TIMEOUT_MS = 10_000;

export type GenerationConfig = { apiKey: string; fetch?: typeof fetch; timeoutMs?: number };

const generationResponseSchema = z.object({
  data: z.object({
    id: z.string(),
    model: z.string(),
    total_cost: z.number(),
    created_at: z.string(),
    provider_name: z.string().nullable().optional(),
    // native_*: 공급자 토크나이저 기준 (청구 기준, 응답의 usage 토큰 수와 같다). tokens_*: OpenRouter 정규화 값
    native_tokens_prompt: z.number().nullable().optional(),
    native_tokens_completion: z.number().nullable().optional(),
    native_tokens_reasoning: z.number().nullable().optional(),
    tokens_prompt: z.number().nullable().optional(),
    tokens_completion: z.number().nullable().optional(),
    cancelled: z.boolean().nullable().optional(),
  }),
});

export type Generation = {
  id: string;
  model: string;
  /** 확정 비용 (USD) */
  costUsd: number;
  provider: string | null;
  promptTokens: number | null;
  completionTokens: number | null;
  reasoningTokens: number | null;
  cancelled: boolean | null;
  createdAt: string;
};

/** found: 비용 확정. pending: 아직 조회되지 않음 (생성 직후 · 없는 id 모두 404라 가르지 않는다. 다시 물을지는 부르는 쪽이 정한다) */
export type GenerationLookup = { status: "found"; generation: Generation } | { status: "pending" };

export class GenerationError extends Error {
  constructor(
    message: string,
    readonly detail?: unknown,
  ) {
    super(message);
    this.name = "GenerationError";
  }
}

export function generationConfigFromEnv(env: Record<string, string | undefined> = process.env): GenerationConfig {
  const apiKey = env.OPENROUTER_API_KEY;
  if (!apiKey) throw new GenerationError("OPENROUTER_API_KEY가 필요합니다. .env.example을 참고해 .env.local을 채우세요.");
  return { apiKey };
}

export async function fetchGeneration(config: GenerationConfig, id: string): Promise<GenerationLookup> {
  if (!GENERATION_ID.test(id)) throw new GenerationError("generation id 형식이 아닙니다");
  const doFetch = config.fetch ?? fetch;
  // 시간 초과 · 네트워크 오류 · JSON이 아닌 본문도 GenerationError로 바꾼다 (부르는 쪽은 이 오류만 보고 다음에 다시 묻는다)
  try {
    const response = await doFetch(`${OPENROUTER_GENERATION_URL}?id=${encodeURIComponent(id)}`, {
      signal: AbortSignal.timeout(config.timeoutMs ?? GENERATION_TIMEOUT_MS),
      headers: { Authorization: `Bearer ${config.apiKey}` },
    });
    if (response.status === 404) return { status: "pending" };
    if (!response.ok) throw new GenerationError(`generation 조회 실패 (${response.status})`, (await response.text()).slice(0, 500));
    return toLookup(id, await response.json());
  } catch (error) {
    if (error instanceof GenerationError) throw error;
    throw new GenerationError(`generation 조회 실패 (${error instanceof Error ? error.name : "unknown"})`, error instanceof Error ? error.message : undefined);
  }
}

function toLookup(id: string, body: unknown): GenerationLookup {
  const parsed = generationResponseSchema.safeParse(body);
  if (!parsed.success) throw new GenerationError("generation 응답 형식이 예상과 다릅니다", parsed.error.issues);
  const d = parsed.data.data;
  if (d.id !== id) throw new GenerationError("다른 generation의 응답입니다");
  return {
    status: "found",
    generation: {
      id: d.id,
      model: d.model,
      costUsd: d.total_cost,
      provider: d.provider_name ?? null,
      promptTokens: d.native_tokens_prompt ?? d.tokens_prompt ?? null,
      completionTokens: d.native_tokens_completion ?? d.tokens_completion ?? null,
      reasoningTokens: d.native_tokens_reasoning ?? null,
      cancelled: d.cancelled ?? null,
      createdAt: d.created_at,
    },
  };
}
