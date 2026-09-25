import { z } from "zod";

// Jev 판정 호출 (OpenRouter Decisions API, docs/TRUTH_RULES.md 1장). chat completions와 다른 API라 fetch로 직접 부른다.
// Decisions API는 alpha라 요청 · 응답 형식이 바뀔 수 있다. 호출은 이 파일에만 두고 응답은 zod로 검증한다.

const OPENROUTER_DECISIONS_URL = "https://openrouter.ai/api/alpha/decisions";

export type JevConfig = {
  apiKey: string;
  /** 버전 고정 (예: typesafe/jev-1.13) */
  model: string;
  fetch?: typeof fetch;
};

export type JevQuestion =
  | { type: "noul"; instructions: string }
  | { type: "choice"; instructions: string; criteria: Record<string, string> }
  | { type: "score"; instructions: string; criteria?: Record<string, string> };

const noulAnswer = z.object({ type: z.literal("noul"), noul: z.number().min(0).max(1) });
const choiceAnswer = z.object({
  type: z.literal("choice"),
  choice: z.string(),
  confidence: z.number().optional(),
  probabilities: z.record(z.string(), z.number()),
});
const scoreAnswer = z.object({
  type: z.literal("score"),
  score: z.number(),
  probabilities: z.record(z.string(), z.number()).optional(),
});

export const jevAnswerSchema = z.discriminatedUnion("type", [noulAnswer, choiceAnswer, scoreAnswer]);
export type JevAnswer = z.infer<typeof jevAnswerSchema>;

const decisionResponseSchema = z.object({
  model: z.string(),
  answers: z.record(z.string(), jevAnswerSchema),
  usage: z.object({ input_tokens: z.number(), output_tokens: z.number().optional(), cost: z.number().optional() }).optional(),
});

export type JevDecision = z.infer<typeof decisionResponseSchema>;

export class JevError extends Error {
  constructor(
    message: string,
    readonly detail?: unknown,
  ) {
    super(message);
    this.name = "JevError";
  }
}

export function jevConfigFromEnv(env: Record<string, string | undefined> = process.env): JevConfig {
  const apiKey = env.OPENROUTER_API_KEY;
  const model = env.JEV_MODEL;
  if (!apiKey || !model) {
    throw new JevError("OPENROUTER_API_KEY와 JEV_MODEL이 필요합니다. .env.example을 참고해 .env.local을 채우세요.");
  }
  return { apiKey, model };
}

export async function decide(
  config: JevConfig,
  request: { state: unknown; questions: Record<string, JevQuestion> },
): Promise<JevDecision> {
  const doFetch = config.fetch ?? fetch;
  const response = await doFetch(OPENROUTER_DECISIONS_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: config.model, state: request.state, questions: request.questions }),
  });

  if (!response.ok) {
    throw new JevError(`Decisions API 요청 실패 (${response.status})`, (await response.text()).slice(0, 500));
  }

  const parsed = decisionResponseSchema.safeParse(await response.json());
  if (!parsed.success) throw new JevError("Decisions API 응답 형식이 예상과 다릅니다", parsed.error.issues);

  const missing = Object.keys(request.questions).filter((key) => !(key in parsed.data.answers));
  if (missing.length > 0) throw new JevError(`답이 없는 질문: ${missing.join(", ")}`);

  for (const [key, question] of Object.entries(request.questions)) {
    if (parsed.data.answers[key].type !== question.type) {
      throw new JevError(`질문 ${key}의 답 형식이 다릅니다: ${parsed.data.answers[key].type}`);
    }
  }

  return parsed.data;
}
