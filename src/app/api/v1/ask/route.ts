import { DeadlineExceededError, interactiveDeadline, logDeadlineExceeded } from "@/lib/ai/deadline";
import { authenticateRequest } from "@/lib/api/auth";
import { handleAsk } from "@/lib/api/ask";
import { askDepsFromEnv, askRateLimit } from "@/lib/api/ask-store";
import { hasAiConsent } from "@/lib/api/profile-store";
import { answerQuestion } from "@/lib/pipeline/ask";
import { createAdminClient } from "@/lib/supabase/admin";

// 물어보기: 내 할 일 · 근거 원문에서 찾아 답한다 (인용은 원문과 대조해 확인한 것만). 질문 · 답은 로그에 남기지 않는다.
// 앱도 60초 기다린다 (lib/ai/deadline.ts INTERACTIVE_MAX_DURATION_S와 같아야 한다, route.test.ts). 모델 호출(임베딩 · LLM)은 실행 한도보다
// 8초 먼저 끝내고, LLM은 첫 호출부터 추론량을 제한한다 (lib/ai/llm.ts). 마감 안에 끝내지 못하면 500과 함께 deadline_exceeded 한 줄을 남긴다.
export const maxDuration = 60;

export async function POST(request: Request) {
  const startedAt = Date.now();
  const deadline = interactiveDeadline(maxDuration, startedAt);
  return handleAsk(request, {
    authenticate: authenticateRequest,
    hasConsent: hasAiConsent,
    rateLimit: ({ user }) => askRateLimit(createAdminClient(), user.id),
    answer: async ({ user }, question) => {
      try {
        const { answer, unknown, citations } = await answerQuestion(question, askDepsFromEnv(createAdminClient(), user.id, deadline));
        return { answer, unknown, citations };
      } catch (error) {
        if (error instanceof DeadlineExceededError) logDeadlineExceeded("ask", error, startedAt);
        throw error;
      }
    },
  });
}
