import type { CompleteJson } from "@/lib/pipeline/extract";
import type { Decide } from "@/lib/pipeline/judge";

// 외부 AI 처리 동의의 마지막 관문 (App Store 5.1.2(i), docs/GO_LIVE.md 1장).
// 원문 처리(processSource · processTaskSource) · 누락 신고(reportMissing) · 물어보기는 모델 호출(LLM · Jev · 임베딩)을
// 이 래퍼로 감싼 deps로만 부른다. 호출 직전마다 동의를 다시 확인하므로, 동기화 · 처리 도중에 철회하면 다음 호출부터 멈춘다.
// 요청 입구(409)와 동기화 대상 고르기(syncable_connections)의 확인은 그대로 두고, 여기는 그 뒤에 철회된 경우를 막는다.

export const CONSENT_WITHDRAWN_MESSAGE = "외부 AI 처리 동의가 없어 처리하지 않았어요.";

/** 동의가 없어서 모델을 부르지 않았다. 부르는 쪽은 남은 항목을 처리하지 말고 멈춘다. */
export class ConsentRequiredError extends Error {
  constructor() {
    super(CONSENT_WITHDRAWN_MESSAGE);
    this.name = "ConsentRequiredError";
  }
}

/** 지금 이 사용자가 동의한 상태인가 (호출할 때마다 DB에서 다시 읽는다) */
export type ConsentCheck = () => Promise<boolean>;

export async function assertConsent(check: ConsentCheck): Promise<void> {
  if (!(await check())) throw new ConsentRequiredError();
}

type AiDeps = {
  complete?: CompleteJson;
  decide?: Decide;
  embed?: (texts: string[]) => Promise<number[][]>;
};

/** deps의 모델 호출(complete · decide · embed)마다 먼저 동의를 확인한다. 다른 함수(retrieve 등)는 그대로 둔다. */
export function withConsentGate<D extends AiDeps>(deps: D, check: ConsentCheck): D {
  const gated: AiDeps = {};
  if (deps.complete) {
    const complete = deps.complete;
    gated.complete = (async (request) => {
      await assertConsent(check);
      return complete(request);
    }) as CompleteJson;
  }
  if (deps.decide) {
    const decide = deps.decide;
    gated.decide = async (request) => {
      await assertConsent(check);
      return decide(request);
    };
  }
  if (deps.embed) {
    const embed = deps.embed;
    gated.embed = async (texts) => {
      await assertConsent(check);
      return embed(texts);
    };
  }
  return { ...deps, ...gated };
}
