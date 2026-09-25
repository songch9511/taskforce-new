import { z } from "zod";

// 생성형 LLM 호출 (OpenRouter chat completions). 구조화 출력(JSON 스키마)으로만 받고 zod로 검증한다.
// eval 스크립트에서도 그대로 쓰도록 server-only를 걸지 않고, 설정은 인자로 받는다.

const OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions";

export type LlmConfig = {
  apiKey: string;
  model: string;
  fetch?: typeof fetch;
};

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
};

export class LlmError extends Error {
  constructor(
    message: string,
    readonly detail?: unknown,
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
  return { apiKey, model };
}

export async function completeJson<T extends z.ZodType>(
  config: LlmConfig,
  request: JsonCompletionRequest<T>,
): Promise<JsonCompletion<z.infer<T>>> {
  const doFetch = config.fetch ?? fetch;
  const response = await doFetch(OPENROUTER_CHAT_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: config.model,
      ...(request.temperature === undefined ? {} : { temperature: request.temperature }),
      max_tokens: request.maxTokens ?? 4096,
      messages: [
        { role: "system", content: request.system },
        { role: "user", content: request.user },
      ],
      response_format: {
        type: "json_schema",
        json_schema: { name: request.schemaName, strict: true, schema: z.toJSONSchema(request.schema) },
      },
      // 구조화 출력을 지원하는 공급자에게만 보낸다.
      provider: { require_parameters: true },
    }),
  });

  if (!response.ok) {
    // 응답 본문에는 원문이 들어 있지 않지만, 길이를 제한해 로그가 커지지 않게 한다.
    const body = (await response.text()).slice(0, 500);
    throw new LlmError(`OpenRouter 요청 실패 (${response.status})`, body);
  }

  const parsed = chatResponseSchema.safeParse(await response.json());
  if (!parsed.success) throw new LlmError("OpenRouter 응답 형식이 예상과 다릅니다", parsed.error.issues);

  const choice = parsed.data.choices[0];
  if (!choice.message.content) throw new LlmError(`빈 응답 (finish_reason: ${choice.finish_reason ?? "?"})`);

  let json: unknown;
  try {
    json = JSON.parse(choice.message.content);
  } catch {
    throw new LlmError(`JSON이 아닌 응답 (finish_reason: ${choice.finish_reason ?? "?"})`);
  }

  const data = request.schema.safeParse(json);
  if (!data.success) throw new LlmError("응답이 스키마와 맞지 않습니다", data.error.issues);

  return { data: data.data, model: parsed.data.model, usage: parsed.data.usage };
}
