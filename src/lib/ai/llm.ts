import { z } from "zod";

import { DeadlineExceededError } from "./deadline";
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
  /**
   * 추론량 제한. 배경 처리는 출력 · 시간 한도를 넘긴 호출을 다시 물을 때만, 마감이 있는 호출은 첫 호출부터 건다.
   * 지정하지 않으면 OVERRUN_RETRY_REASONING, null이면 어느 쪽에서도 걸지 않는다 (LLM_OVERRUN_REASONING_EFFORT=off)
   */
  overrunReasoning?: OverrunReasoning | null;
  /**
   * 사용자가 기다리는 호출(빠진 할 일 신고 · 물어보기)의 마감 시각 (epoch ms, deadline.ts interactiveDeadline). 있으면:
   * - 한도를 넘긴 뒤 다시 물을 시간이 없으므로 첫 호출부터 추론량을 제한하고(overrunReasoning), 그래도 넘기면 low로 줄여 다시 묻는다
   * - 시도마다 남은 시간으로 시간 한도를 정한다(attemptTimeoutMs). 시간이 모자라 끝내지 못하면 DeadlineExceededError
   * - 추론 옵션을 받는 공급자가 없다고 거절되면 한 번, 추론 옵션 없이 다시 묻는다
   * 없으면 배경 처리(원문 처리 · 동기화 · 재처리 cron · eval 추출): 시도마다 timeoutMs, 한도를 넘긴 호출을 다시 물을 때만 제한한다.
   */
  deadline?: number;
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

export type LlmUsage = { prompt_tokens: number; completion_tokens: number; cost?: number };

/**
 * 시도 한 번의 원가 기록. 형식이 깨져 다시 물은 시도도 공급자 비용이 들어 시도마다 남긴다 (원가 · 청구 기록, A51).
 * - generationId: 응답의 id (OpenRouter generation id, "gen-…"). 이 id로 비용을 나중에 확정할 수 있다 (generation.ts).
 *   응답을 받지 못한 시도(시간 초과 · 본문을 읽지 못함)는 null: 공급자가 생성을 마쳐 비용이 났을 수 있지만 확인할 수 없다 (미확정).
 * - usage.cost: 응답에 담긴 비용(USD). OpenRouter는 모든 응답에 넣는다 (usage: { include: true }는 폐기돼 효과가 없다, 2026-10-02 문서 · 개발 키 확인).
 * - model: 요청한 모델 (LlmConfig.model). 시도마다 같은 값이라 모델별로 모을 수 있다. 응답의 날짜 붙은 판은 JsonCompletion.model · generation 조회에 있다.
 * HTTP 오류로 거절된 요청(402 · 429 · 5xx 등)은 생성 id가 없고 청구되지 않아(OpenRouter zero completion insurance) 남기지 않는다.
 * 시간 초과가 아닌 네트워크 오류(연결 끊김 등)도 남기지 않는다: 요청이 닿기 전인지 뒤인지 가를 수 없고, 미확정으로 두면 청구를 막아 둬야 해서다(드묾).
 */
export type LlmAttempt = { generationId: string | null; model: string; usage?: LlmUsage };

export type JsonCompletion<T> = {
  data: T;
  model: string;
  /** 답을 받은 마지막 시도의 사용량. 다시 물은 시도까지 합한 원가는 attempts에 있다 */
  usage?: LlmUsage;
  /**
   * 추론량을 제한해 받은 답인가 (품질이 조금 낮을 수 있어 기록한다). 배경 처리는 한도를 넘긴 첫 호출을 제한해 다시 물은 답,
   * 마감이 있는 호출은 첫 호출부터 제한하므로 추론량 제한을 끄지 않았으면 늘 true다.
   */
  reasoningLimited?: boolean;
  /** 이 답을 받기까지의 모든 시도 (다시 묻기 포함, 차례대로). completeJson은 늘 채운다 */
  attempts?: LlmAttempt[];
};

export class LlmError extends Error {
  /** 이 오류로 끝난 completeJson 호출의 모든 시도 (원가 기록용). 다른 오류로 끝났을 때는 llmAttemptsOf로 읽는다 */
  attempts: LlmAttempt[] = [];

  constructor(
    message: string,
    readonly detail?: unknown,
    /** 모델 출력 형식 문제라 다시 물으면 나을 수 있는 오류 */
    readonly retryable = false,
    /** 출력 한도(finish_reason length)나 시간 한도를 넘긴 오류: 추론이 길어져서일 수 있다 */
    readonly overran = false,
    /** timeout: 응답 시간 한도를 넘김. unsupported_parameters: 요청의 매개변수(추론 옵션 등)를 모두 받는 공급자가 없음 */
    readonly kind?: "timeout" | "unsupported_parameters",
  ) {
    super(message);
    this.name = "LlmError";
  }
}

const usageSchema = z.object({ prompt_tokens: z.number(), completion_tokens: z.number(), cost: z.number().optional() });

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
  usage: usageSchema.optional(),
});

/** 시도 기록에 남길 값만 너그럽게 읽는다: 응답 형식이 어긋나도(chatResponseSchema 실패) 생성 id · 비용은 남긴다 */
const attemptMetaSchema = z.object({
  id: z.string().optional().catch(undefined),
  usage: usageSchema.optional().catch(undefined),
});

/**
 * completeJson이 실패로 끝났을 때 그때까지의 시도 (원가 기록용). LlmError는 attempts 필드로도 읽을 수 있고,
 * 마감 오류(DeadlineExceededError) · 네트워크 오류처럼 다른 오류로 끝나도 같은 기록을 붙여 두므로 이 함수로 읽는다.
 */
export function llmAttemptsOf(error: unknown): LlmAttempt[] {
  const attempts = error instanceof Error ? (error as Error & { attempts?: unknown }).attempts : undefined;
  return Array.isArray(attempts) ? (attempts as LlmAttempt[]) : [];
}

function withAttempts<E>(error: E, attempts: LlmAttempt[]): E {
  if (error instanceof Error) Object.assign(error, { attempts: [...attempts] });
  return error;
}

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
 * 사용자가 기다리는 호출(LlmConfig.deadline)은 넘긴 뒤 다시 물을 시간이 없어 첫 호출부터 건다.
 * glm-5.3-flash · Fireworks에서 잰 값이다. 모델을 바꾸면 LLM_OVERRUN_REASONING_EFFORT로 다시 정한다
 * (기본 effort가 medium인 모델에서 high는 추론을 늘리고, 추론 옵션이 없는 모델은 require_parameters로 공급자가 없어진다).
 */
export const OVERRUN_RETRY_REASONING: OverrunReasoning = { effort: "high" };

/**
 * 마감이 있는 호출이 첫 호출부터 제한했는데도 출력 · 시간 한도를 넘겼을 때 다시 물을 추론량.
 * 2026-09-29 실험에서 늘 low는 호출 시간 95%가 5초 안이었지만 조건부 약속 오탐으로 정밀도가 약 5%p 내려가, 이 다시 묻기에만 쓴다.
 */
export const DEADLINE_OVERRUN_REASONING: OverrunReasoning = { effort: "low" };

/** 마감이 있을 때 한 번 시도에 주는 최소 시간. 남은 시간이 이보다 짧으면 (다시) 묻지 않는다 */
export const LLM_MIN_ATTEMPT_MS = 5_000;

/**
 * 이번 시도의 시간 한도 (ms). 마감이 없으면 timeoutMs(기본 90초).
 * 마감이 있으면 남은 시간을 남은 시도 수로 나눈다: 첫 시도가 멈춰도 다시 물을 시간이 남고, 첫 시도가 빨리 실패하면 다시 묻기가 남은 시간을 다 쓴다.
 * 나누면 한 시도가 LLM_MIN_ATTEMPT_MS보다 짧아질 만큼 남았으면 이 시도에 남은 시간을 다 준다(다시 묻기는 빠진다).
 * 남은 시간이 LLM_MIN_ATTEMPT_MS보다 짧으면 null (묻지 않는다).
 */
export function attemptTimeoutMs(config: Pick<LlmConfig, "timeoutMs" | "deadline">, attemptsLeft: number, now = Date.now()): number | null {
  const limit = config.timeoutMs ?? LLM_TIMEOUT_MS;
  if (config.deadline === undefined) return limit;
  const remaining = config.deadline - now;
  if (remaining < LLM_MIN_ATTEMPT_MS) return null;
  if (remaining < LLM_MIN_ATTEMPT_MS * attemptsLeft) return Math.min(limit, remaining);
  return Math.min(limit, Math.floor(remaining / attemptsLeft));
}

export async function completeJson<T extends z.ZodType>(
  config: LlmConfig,
  request: JsonCompletionRequest<T>,
): Promise<JsonCompletion<z.infer<T>>> {
  const overrunReasoning = config.overrunReasoning === undefined ? OVERRUN_RETRY_REASONING : config.overrunReasoning;
  const hasDeadline = config.deadline !== undefined;
  // 사용자가 기다리는 호출(마감 있음)은 한도를 넘긴 뒤 다시 물을 시간이 없어 첫 호출부터 제한한다.
  let reasoning: OverrunReasoning | null = hasDeadline ? overrunReasoning : null;
  let attemptsLeft = FORMAT_RETRIES + 1;
  let triedWithoutReasoning = false;
  // 시도마다 원가 기록. 성공하면 결과에, 실패하면 던지는 오류에 붙인다 (llmAttemptsOf)
  const attempts: LlmAttempt[] = [];
  const record = (attempt: LlmAttempt) => attempts.push(attempt);
  let timeoutMs = attemptTimeoutMs(config, attemptsLeft);
  if (timeoutMs === null) throw new DeadlineExceededError("llm", "남은 시간 없음");
  for (;;) {
    try {
      const result = await completeJsonOnce(config, request, reasoning, timeoutMs, record);
      return { ...result, ...(reasoning ? { reasoningLimited: true } : {}), attempts };
    } catch (error) {
      // 마감이 있는 호출은 첫 호출부터 추론 옵션을 보낸다. 그 옵션을 받는 공급자가 없다고 거절되면(추론하지 않는 모델로 바꿨는데
      // LLM_OVERRUN_REASONING_EFFORT를 끄지 않음) 한 번, 옵션 없이 다시 묻는다. 거절은 바로 오므로 다시 묻기 횟수에 넣지 않는다.
      if (hasDeadline && reasoning && !triedWithoutReasoning && error instanceof LlmError && error.kind === "unsupported_parameters") {
        console.warn("추론 옵션을 받는 공급자가 없어 추론량 제한 없이 다시 묻습니다. 이 모델이면 LLM_OVERRUN_REASONING_EFFORT=off로 두세요.");
        reasoning = null;
        triedWithoutReasoning = true;
        const next = attemptTimeoutMs(config, attemptsLeft);
        if (next === null) throw withAttempts(new DeadlineExceededError("llm", "남은 시간 없음"), attempts);
        timeoutMs = next;
        continue;
      }
      // 응답 본문을 읽는 도중에도 시간 초과가 날 수 있다.
      const bodyTimedOut = error instanceof DOMException && error.name === "TimeoutError";
      const timedOut = bodyTimedOut || (error instanceof LlmError && error.kind === "timeout");
      const retryable = bodyTimedOut || (error instanceof LlmError && error.retryable);
      attemptsLeft--;
      // 마감이 있으면 남은 시간이 한 번 더 물을 만큼일 때만 다시 묻는다.
      const next = retryable && attemptsLeft > 0 ? attemptTimeoutMs(config, attemptsLeft) : null;
      if (next === null) {
        const seconds = Math.round(timeoutMs / 1000);
        if (hasDeadline && timedOut) throw withAttempts(new DeadlineExceededError("llm", `응답 시간 초과 (${seconds}초)`), attempts);
        if (hasDeadline && retryable && attemptsLeft > 0) {
          throw withAttempts(new DeadlineExceededError("llm", `다시 물을 시간 없음 (${error instanceof Error ? error.message : String(error)})`), attempts);
        }
        throw withAttempts(bodyTimedOut ? new LlmError(`응답 시간 초과 (${seconds}초)`) : error, attempts);
      }
      timeoutMs = next;
      if (timedOut || (error instanceof LlmError && error.overran)) {
        // 배경 처리: 제한 없던 호출을 제한해 다시 묻는다. 마감: 이미 제한한 호출이 넘겼으니 더 줄여 다시 묻는다 (끈 경우는 그대로 없음).
        reasoning = hasDeadline ? reasoning && DEADLINE_OVERRUN_REASONING : (reasoning ?? overrunReasoning);
      }
    }
  }
}

/**
 * require_parameters로 요청의 매개변수(추론 옵션 등)를 모두 받는 공급자가 없을 때 OpenRouter의 거절: 404,
 * error.message "No endpoints found that can handle the requested parameters." (2026-09-30 공개 이슈 보고 기준, 직접 재현하지 못했다).
 * 모델이 없는 404("No endpoints found for <모델>")나 도구 · 옵션별 404와 가르려고 이 문구만 본다.
 */
const UNSUPPORTED_PARAMETERS = /No endpoints found that can handle the requested parameters/i;

async function completeJsonOnce<T extends z.ZodType>(
  config: LlmConfig,
  request: JsonCompletionRequest<T>,
  reasoning: OverrunReasoning | null,
  timeoutMs: number,
  record: (attempt: LlmAttempt) => void,
): Promise<JsonCompletion<z.infer<T>>> {
  const doFetch = config.fetch ?? fetch;
  const maxTokens = request.maxTokens ?? 8192;
  let response: Response;
  try {
    response = await doFetch(OPENROUTER_CHAT_URL, {
      signal: AbortSignal.timeout(timeoutMs),
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
      // 응답을 받지 못했다: 공급자는 생성을 마쳤을 수 있지만 id가 없어 비용을 확인할 수 없는 시도로 남긴다
      record({ generationId: null, model: config.model });
      throw new LlmError(`응답 시간 초과 (${Math.round(timeoutMs / 1000)}초)`, undefined, true, true, "timeout");
    }
    throw error;
  }

  if (!response.ok) {
    // 응답 본문에는 원문이 들어 있지 않지만, 길이를 제한해 로그가 커지지 않게 한다.
    const body = (await response.text()).slice(0, 500);
    const kind = response.status === 404 && UNSUPPORTED_PARAMETERS.test(body) ? "unsupported_parameters" : undefined;
    throw new LlmError(`OpenRouter 요청 실패 (${response.status})`, body, false, false, kind);
  }

  let body: unknown;
  try {
    body = await response.json();
  } catch (error) {
    // 본문을 읽다가 시간 한도가 울렸거나 본문이 JSON이 아니다: 생성은 됐을 수 있지만 id를 읽지 못한 시도
    record({ generationId: null, model: config.model });
    throw error;
  }
  const meta = attemptMetaSchema.safeParse(body).data;
  record({ generationId: meta?.id ?? null, model: config.model, ...(meta?.usage ? { usage: meta.usage } : {}) });

  const parsed = chatResponseSchema.safeParse(body);
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
