// OpenRouter 공급자 고정 (개인정보 처리방침: 미국 소재 · 데이터 보존 없음(ZDR) 공급자에게만 보낸다).
// 모든 호출은 이 조건으로만 나간다: 저장 · 학습 금지(data_collection: deny) + ZDR 공급자만(zdr: true)
// + 아래 목록의 공급자만, 이 순서로(only · order), 목록 밖으로 넘어가지 않음(allow_fallbacks: false).
// 목록에 있는 공급자가 모두 내려가면 요청은 실패한다 (다른 나라 · 다른 공급자로 새지 않게 일부러 닫힌 쪽으로 둔다).
// 목록은 환경변수로 바꿀 수 있다 (쉼표로 구분한 OpenRouter 공급자 slug). 모델을 바꾸면 그 모델을 서비스하는 공급자로 목록도 바꾼다.
// 고른 근거 (2026-09-27, OpenRouter /api/v1/models/{model}/endpoints · /api/v1/endpoints/zdr · /api/v1/providers):
// - LLM z-ai/glm-5.3-flash: Fireworks · Together · DeepInfra — 모두 ZDR 목록에 있고 본사 US, 구조화 출력(structured_outputs) 지원
//   순서 (2026-09-29 측정): Fireworks가 가장 빠르다(초당 약 140토큰, Together는 19~85토큰이라 90초 제한에 자주 걸림).
//   DeepInfra는 기본으로 추론하지 않아 빠르지만 결과가 다를 수 있어 마지막에 둔다. BaseTen은 이 모델 제공자 목록에서 빠졌다.
// - 임베딩 openai/text-embedding-3-small: Azure — ZDR 목록에 있는 유일한 공급자 (OpenAI 직접은 ZDR 목록에 없음), 본사 US
// - Jev typesafe/jev-1.13: TypeSafe — 유일한 공급자, ZDR 목록에 있음 (OpenRouter에 본사 국가 표기 없음, 공개 자료상 미국 샌프란시스코)

export const DEFAULT_LLM_PROVIDERS = ["fireworks", "together", "deepinfra"];
export const DEFAULT_EMBED_PROVIDERS = ["azure"];
export const DEFAULT_JEV_PROVIDERS = ["typesafe"];

/** "a, b" → ["a", "b"]. 비어 있으면 기본 목록 (고정을 끌 수는 없다) */
export function parseProviders(value: string | undefined, fallback: string[]): string[] {
  const list = (value ?? "")
    .split(",")
    .map((slug) => slug.trim().toLowerCase())
    .filter(Boolean);
  return list.length > 0 ? [...new Set(list)] : fallback;
}

/** OpenRouter 요청 본문의 provider 필드 */
export function providerRouting(providers: string[] | undefined): Record<string, unknown> {
  return {
    data_collection: "deny",
    zdr: true,
    ...(providers && providers.length > 0 ? { only: providers, order: providers, allow_fallbacks: false } : {}),
  };
}
