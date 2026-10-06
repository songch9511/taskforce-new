import { ConsentRequiredError } from "@/lib/consent/gate";
import { z } from "zod";

import { DeadlineExceededError, interactiveDeadline, logDeadlineExceeded } from "@/lib/ai/deadline";
import { generateAssistedHandoffFromEnv } from "@/lib/ai/handoff";
import { handoffAction } from "@/lib/actions/service";
import { authenticateRequest } from "@/lib/api/auth";
import { handleHandoff } from "@/lib/api/handoff";
import { hasAiConsent } from "@/lib/api/profile-store";
import { askRateLimit } from "@/lib/api/ask-store";
import { RateLimitedError } from "@/lib/api/rate-limit";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { createAdminClient } from "@/lib/supabase/admin";

// Assisted handoff is synchronous and bounded; the legacy empty-body request stays deterministic and unchanged.
export const maxDuration = 60;

type Params = { params: Promise<{ id: string }> };

export async function POST(request: Request, { params }: Params): Promise<Response> {
  const startedAt = Date.now();
  const deadline = interactiveDeadline(maxDuration, startedAt);
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const { id } = await params;
  if (!z.uuid().safeParse(id).success) return errorResponse(404, "not_found", "Action이 없습니다.");

  const admin = createAdminClient();
  return handleHandoff(request, {
    handoff: (assisted) =>
      handoffAction(
        context.supabase,
        admin,
        context.user.id,
        id,
        assisted
          ? async (deterministicMarkdown) => {
              // The service has already confirmed RLS ownership and built bounded context before this callback runs.
              if (!(await hasAiConsent(context))) throw new ConsentRequiredError();
              const retryAt = await askRateLimit(admin, context.user.id);
              if (retryAt) throw new RateLimitedError(retryAt);
              return generateAssistedHandoffFromEnv(deterministicMarkdown, admin, context.user.id, deadline);
            }
          : undefined,
      ),
    onDeadlineExceeded: (error: DeadlineExceededError) => logDeadlineExceeded("handoff", error, startedAt),
  });
}
