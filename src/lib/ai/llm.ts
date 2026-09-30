import { z } from "zod";

import { DEFAULT_LLM_PROVIDERS, parseProviders, providerRouting } from "./providers";

// 생성형 LLM 호출 (OpenRouter chat completions). 구조화 출력(JSON 스키마)으로만 받고 zod로 검증한다.
// eval 스크립트에서도 그대로 쓰도록 server-only를 걸지 않고, 설정은 인자로 받는다.

const OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions";

export type LlmConfig = {
  apiKey: string;
  model: string;
  /** 보낼 공급자 (OpenRouter slug, 이 순서로만). providers.ts */
  providers?: string[];
  fetch?: typeof fetch;
  timeoutMs?: number;
  /** 출력 · 시간 한도를 넘긴 호출을 다시 물을 때 거는 추론량 제한. 지정하지 않으면 OVERRUN_RETRY_REASONING, null이면 걸지 않는다 */
  overrunReasoning?: OverrunReasoning | null;
};

export type OverrunReasoning = { effort: "low" | "medium" | "high" };

export type JsonCompletionRequest<T extends z.ZodType> = {
  system: string;
  user: string;
  /** 응답 스키마 이름 (영문, 밑줄) */
  schemaName: string;
  schema: T;
  /** 최신 Claude 모델처럼 temperature를 받지 않는 모델이 있어 지정할 때만 보낸다. */
  temperature?: number;
  /**
   * 출력 토큰 상한. 지정하지 않으면 OpenRouter가 모델 최대치만큼 비용을 미리 잡아,
   * 키에 사용 한도가 있으면 잔액이 남아 있어도 402로 거절된다.
   */
  maxTokens?: number;
};

export type JsonCompletion<T> = {
  data: T;
  model: string;
  usage?: { prompt_tokens: number; completion_tokens: number; cost?: number };
  /** 한도를 넘긴 첫 호출 대신 추론량을 제한해 다시 물은 답인가 (품질이 조금 낮을 수 있어 기록한다) */
  reasoningLimited?: boolean;
};

export class LlmError extends Error {
  constructor(
    message: string,
    readonly detail?: unknown,
    /** 모델 출력 형식 문제라 다시 물으면 나을 수 있는 오류 */
    readonly retryable = false,
    /** 출력 한도(finish_reason length)나 시간 한도를 넘긴 오류: 추론이 길어져서일 수 있다 */
    readonly overran = false,
  ) {
    super(message);
    this.name = "LlmError";
  }
}

const chatResponseSchema = z.object({
  model: z.string(),
  choices: z
    .array(
      z.object({
        finish_reason: z.string().nullable().optional(),
        message: z.object({ content: z.string().nullable() }),
      }),
    )
    .min(1),
  usage: z
    .object({ prompt_tokens: z.number(), completion_tokens: z.number(), cost: z.number().optional() })
    .optional(),
});

export function llmConfigFromEnv(env: Record<string, string | undefined> = process.env): LlmConfig {
  const apiKey = env.OPENROUTER_API_KEY;
  const model = env.LLM_MODEL;
  if (!apiKey || !model) {
    throw new LlmError("OPENROUTER_API_KEY와 LLM_MODEL이 필요합니다. .env.example을 참고해 .env.local을 채우세요.");
  }
  return {
    apiKey,
    model,
    providers: parseProviders(env.LLM_PROVIDERS, DEFAULT_LLM_PROVIDERS),
    overrunReasoning: parseOverrunReasoning(env.LLM_OVERRUN_REASONING_EFFORT),
  };
}

/** LLM_OVERRUN_REASONING_EFFORT: 비우면 기본(high), off면 걸지 않는다 (추론하지 않는 모델로 바꿀 때) */
function parseOverrunReasoning(value: string | undefined): OverrunReasoning | null | undefined {
  const effort = value?.trim().toLowerCase();
  if (!effort) return undefined;
  if (effort === "off") return null;
  if (effort === "low" || effort === "medium" || effort === "high") return { effort };
  throw new LlmError(`LLM_OVERRUN_REASONING_EFFORT는 low · medium · high · off 중 하나여야 합니다 (${value})`);
}

/** 응답 형식이 깨졌거나 시간 안에 답이 없을 때 다시 시도하는 횟수. 같은 모델도 공급자에 따라 가끔 멈추거나 JSON이 아닌 답을 준다. */
const FORMAT_RETRIES = 1;

/** 한 번 호출의 응답 시간 한도. 넘기면 끊고 다시 시도한다 (실제 원문에서 5분 넘게 멈춘 경우가 있었다). */
export const LLM_TIMEOUT_MS = 90_000;

/**
 * 출력 한도 · 시간 한도를 넘겨 다시 물을 때만 거는 추론량 제한 (기본값). 추론 모델(glm-5.3-flash)은 추론 토큰도 출력 한도(8,192)에 들어가,
 * 긴 추론이 한도를 채우면 답이 비거나 잘린다. 처음부터 제한하면 품질이 조금 내려가(2026-09-29 eval: 병합 100% → 95%,
 * 담당 오류 1건) 평소에는 걸지 않고, 넘긴 호출을 다시 물을 때만 건다 (그 eval에서 호출 실패 0, 호출 시간 95%가 8초 안).
 * glm-5.3-flash · Fireworks에서 잰 값이다. 모델을 바꾸면 LLM_OVERRUN_REASONING_EFFORT로 다시 정한다
 * (기본 effort가 medium인 모델에서 high는 추론을 늘리고, 추론 옵션이 없는 모델은 require_parameters로 공급자가 없어진다).
 */
export const OVERRUN_RETRY_REASONING: OverrunReasoning = { effort: "high" };

export async function completeJson<T extends z.ZodType>(
  config: LlmConfig,
  request: JsonCompletionRequest<T>,
): Promise<JsonCompletion<z.infer<T>>> {
  const overrunReasoning = config.overrunReasoning === undefined ? OVERRUN_RETRY_REASONING : config.overrunReasoning;
  let reasoning: OverrunReasoning | null = null;
  for (let attempt = 0; ; attempt++) {
    try {
      const result = await completeJsonOnce(config, request, reasoning);
      return reasoning ? { ...result, reasoningLimited: true } : result;
    } catch (error) {
      // 응답 본문을 읽는 도중에도 시간 초과가 날 수 있다.
      const timedOut = error instanceof DOMException && error.name === "TimeoutError";
      const retryable = timedOut || (error instanceof LlmError && error.retryable);
      if (!retryable || attempt >= FORMAT_RETRIES) {
        throw timedOut ? new LlmError(`응답 시간 초과 (${Math.round((config.timeoutMs ?? LLM_TIMEOUT_MS) / 1000)}초)`) : error;
      }
      if (timedOut || (error instanceof LlmError && error.overran)) reasoning ??= overrunReasoning;
    }
  }
}

async function completeJsonOnce<T extends z.ZodType>(
  config: LlmConfig,
  request: JsonCompletionRequest<T>,
  reasoning: OverrunReasoning | null,
): Promise<JsonCompletion<z.infer<T>>> {
  const doFetch = config.fetch ?? fetch;
  const maxTokens = request.maxTokens ?? 8192;
  let response: Response;
  try {
    response = await doFetch(OPENROUTER_CHAT_URL, {
      signal: AbortSignal.timeout(config.timeoutMs ?? LLM_TIMEOUT_MS),
      method: "POST",
      headers: { Authorization: `Bearer ${config.apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        model: config.model,
        ...(request.temperature === undefined ? {} : { temperature: request.temperature }),
        max_tokens: maxTokens,
        messages: [
          { role: "system", content: request.system },
          { role: "user", content: request.user },
        ],
        response_format: {
          type: "json_schema",
          json_schema: { name: request.schemaName, strict: true, schema: z.toJSONSchema(request.schema) },
        },
        // 추론 내용은 받지 않는다 (원문을 풀어 쓴 글이라 응답에 담아 둘 이유가 없다)
        ...(reasoning ? { reasoning: { ...reasoning, exclude: true } } : {}),
        // 구조화 출력을 지원하고(추론량 제한을 걸면 그것도), 사용자 원문을 저장 · 학습에 쓰지 않는(ZDR) 미국 공급자(고정 목록)에게만 보낸다.
        provider: { require_parameters: true, ...providerRouting(config.providers) },
      }),
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "TimeoutError") {
      throw new LlmError(`응답 시간 초과 (${Math.round((config.timeoutMs ?? LLM_TIMEOUT_MS) / 1000)}초)`, undefined, true, true);
    }
    throw error;
  }

  if (!response.ok) {
    // 응답 본문에는 원문이 들어 있지 않지만, 길이를 제한해 로그가 커지지 않게 한다.
    const body = (await response.text()).slice(0, 500);
    throw new LlmError(`OpenRouter 요청 실패 (${response.status})`, body);
  }

  const parsed = chatResponseSchema.safeParse(await response.json());
  if (!parsed.success) throw new LlmError("OpenRouter 응답 형식이 예상과 다릅니다", parsed.error.issues);

  const choice = parsed.data.choices[0];
  // 공급자가 끝난 이유를 length로 알리지 않아도 출력 한도를 다 썼으면 넘긴 것으로 본다
  const overran = choice.finish_reason === "length" || (parsed.data.usage?.completion_tokens ?? 0) >= maxTokens;
  if (!choice.message.content) {
    throw new LlmError(`빈 응답 (finish_reason: ${choice.finish_reason ?? "?"})`, undefined, true, overran);
  }

  let json: unknown;
  try {
    json = JSON.parse(choice.message.content);
  } catch {
    throw new LlmError(`JSON이 아닌 응답 (finish_reason: ${choice.finish_reason ?? "?"})`, undefined, true, overran);
  }

  const data = request.schema.safeParse(json);
  if (!data.success) throw new LlmError("응답이 스키마와 맞지 않습니다", data.error.issues, true, overran);

  return { data: data.data, model: parsed.data.model, usage: parsed.data.usage };
}
