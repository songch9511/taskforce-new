import { authenticateRequest } from "@/lib/api/auth";
import { handleAsk } from "@/lib/api/ask";
import { askDepsFromEnv, askRateLimit } from "@/lib/api/ask-store";
import { hasAiConsent } from "@/lib/api/profile-store";
import { answerQuestion } from "@/lib/pipeline/ask";
import { createAdminClient } from "@/lib/supabase/admin";

// 물어보기: 내 할 일 · 근거 원문에서 찾아 답한다 (인용은 원문과 대조해 확인한 것만). 질문 · 답은 로그에 남기지 않는다.
export const maxDuration = 60;

export async function POST(request: Request) {
  return handleAsk(request, {
    authenticate: authenticateRequest,
    hasConsent: hasAiConsent,
    rateLimit: ({ user }) => askRateLimit(createAdminClient(), user.id),
    answer: async ({ user }, question) => {
      const { answer, unknown, citations } = await answerQuestion(question, askDepsFromEnv(createAdminClient(), user.id));
      return { answer, unknown, citations };
    },
  });
}
