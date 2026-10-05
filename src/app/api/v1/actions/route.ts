import { budgetFetch } from "@/lib/ai/budget";
import { createUserAction } from "@/lib/actions/service";
import { embed, embedConfigFromEnv } from "@/lib/ai/embed";
import { authenticateRequest } from "@/lib/api/auth";
import { handleCreateAction, type RelatedSource } from "@/lib/api/create-action";
import { hasAiConsent } from "@/lib/api/profile-store";
import { ACTION_CREATE_LIMIT } from "@/lib/api/rate-limit";
import { takeRateLimit } from "@/lib/api/rate-limit-store";
import { trackedActionSummary } from "@/lib/sources/process";
import { createAdminClient } from "@/lib/supabase/admin";

// 직접 추가 (Mac 런처): 제목 → 찾는 할 일이 없으면 추가 → 기한 · 관련 원문 구절은 선택.
// 201 { action, status: "created" }. 고른 구절이 이미 Action의 근거면 200 { action, status: "already_tracked" } (그 Action 그대로).
// 원문은 사용자 권한(RLS)으로 읽어 본인 것인지 확인하고, Action 쓰기는 service role로 한다.
export async function POST(request: Request) {
  return handleCreateAction(request, {
    authenticate: authenticateRequest,
    loadSource: async ({ supabase }, sourceId) => {
      const { data } = await supabase.from("sources").select("kind, raw_text, raw_text_purged_at, raw_text_purge_reason").eq("id", sourceId).maybeSingle().throwOnError();
      return data as RelatedSource | null;
    },
    // 원문이 본인 것인지는 loadSource(RLS)가 먼저 확인했다.
    trackedAction: ({ user }, sourceId, quote) => trackedActionSummary(createAdminClient(), { id: sourceId, userId: user.id }, quote),
    rateLimit: ({ user }) => takeRateLimit(createAdminClient(), user.id, "action_create", ACTION_CREATE_LIMIT),
    hasConsent: hasAiConsent,
    embed: async ({ user }, text) => (await embed({ ...embedConfigFromEnv(), fetch: budgetFetch(createAdminClient(), user.id) }, [text])).vectors[0],
    create: ({ user }, action) => createUserAction(createAdminClient(), user.id, action),
  });
}
