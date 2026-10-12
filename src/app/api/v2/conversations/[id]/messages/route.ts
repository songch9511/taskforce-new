import { randomUUID } from "node:crypto";

import { DeadlineExceededError, interactiveDeadline, logDeadlineExceeded } from "@/lib/ai/deadline";
import { authenticateRequest } from "@/lib/api/auth";
import { handlePostConversationMessage } from "@/lib/api/conversations";
import { hasAiConsent } from "@/lib/api/profile-store";
import { ASK_LIMIT } from "@/lib/api/rate-limit";
import { takeRateLimit } from "@/lib/api/rate-limit-store";
import { respondToMessage } from "@/lib/conversation/respond";
import {
  conversationModelsFromEnv,
  finishTurn,
  loadConsultContext,
  loadConversation,
  loadMessage,
  loadWindow,
  postUserMessage,
  releaseLease,
  userMessageExists,
  verifySelected,
} from "@/lib/conversation/store";
import { flagEnabled } from "@/lib/flags";
import { createAdminClient } from "@/lib/supabase/admin";

// 메시지 보내기 (대화 v2, 구현 계획 B2): 저장 → 의도(Jev) → 필요하면 기록 읽기 + 상담(LLM 한 번, 기억 후보 포함) → 한 트랜잭션으로 답 · 기억 · 채택 쓰기.
// gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404 (인증 · DB · 모델을 부르지 않는다). 동의 전 409, 횟수는 물어보기와 같은 한도(10분 20번, 새 제출은 저장 전에 센다).
// 같은 client_message_id는 같은 제출: 답이 있으면 저장된 답을 그대로(모델 호출 없음), 처리 중이면 409.
// 앱도 60초 기다린다 (lib/ai/deadline.ts INTERACTIVE_MAX_DURATION_S와 같아야 한다, route.test.ts). 메시지 · 답은 로그에 남기지 않는다.
export const maxDuration = 60;

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const startedAt = Date.now();
  const deadline = interactiveDeadline(maxDuration, startedAt);
  const { id } = await params;
  return handlePostConversationMessage(request, id, {
    enabled: () => flagEnabled("CONVERSATIONS_V2_ENABLED"),
    memoryEnabled: () => flagEnabled("MEMORY_ENABLED"),
    authenticate: authenticateRequest,
    hasConsent: hasAiConsent,
    rateLimit: ({ user }) => takeRateLimit(createAdminClient(), user.id, "ask", ASK_LIMIT),
    loadConversation: ({ user }, conversationId) => loadConversation(createAdminClient(), user.id, conversationId),
    verifySelected: ({ user }, refs) => verifySelected(createAdminClient(), user.id, refs),
    messageExists: ({ user }, conversationId, clientMessageId) => userMessageExists(createAdminClient(), user.id, conversationId, clientMessageId),
    post: ({ user }, conversationId, clientMessageId, text, selected) => postUserMessage(createAdminClient(), user.id, conversationId, clientMessageId, text, selected),
    loadMessage: ({ user }, messageId) => loadMessage(createAdminClient(), user.id, messageId),
    loadWindow: ({ user }, conversationId, uptoSeq) => loadWindow(createAdminClient(), user.id, conversationId, uptoSeq),
    respond: ({ user }, input) => {
      const admin = createAdminClient();
      return respondToMessage(input, {
        ...conversationModelsFromEnv(admin, user.id, deadline),
        retrieve: (query) =>
          loadConsultContext(admin, user.id, { contextId: input.conversation.contextId, query: query.text, chunks: query.chunks, deadline, now: input.now }),
        newId: randomUUID,
      });
    },
    finish: ({ user }, messageId, plan) => finishTurn(createAdminClient(), user.id, messageId, plan),
    release: ({ user }, messageId) => releaseLease(createAdminClient(), user.id, messageId),
    onDeadlineExceeded: (error: DeadlineExceededError) => logDeadlineExceeded("conversation", error, startedAt),
  });
}
