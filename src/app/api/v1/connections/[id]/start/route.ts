import { authenticateRequest } from "@/lib/api/auth";
import { handleConnectionStart } from "@/lib/api/connections";
import { hasAiConsent } from "@/lib/api/profile-store";
import { CONNECTION_START_LIMIT } from "@/lib/api/rate-limit";
import { takeRateLimit } from "@/lib/api/rate-limit-store";
import { newOAuthState } from "@/lib/connectors/oauth-state";
import { connectorFor } from "@/lib/connectors/registry";
import { saveOAuthNonce } from "@/lib/connectors/store";
import { oauthStateSecret } from "@/lib/env";
import { createAdminClient } from "@/lib/supabase/admin";

// 앱의 연결 시작: POST /api/v1/connections/{provider}/start → { url } (서명된 state를 담은 권한 화면 주소).
// 권한 화면 뒤에는 taskforce://connections/{provider}?handoff=…로 돌아오고, 앱이 POST …/complete로 연결을 마친다.
// 같은 위치의 동적 경로가 이미 [id](DELETE /connections/:id)라서 폴더 이름이 [id]다. 여기서는 id가 서비스 이름이다.
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id: provider } = await params;
  return handleConnectionStart(request, provider, {
    authenticate: authenticateRequest,
    hasConsent: hasAiConsent,
    authorizer: (p) => {
      const connector = connectorFor(p);
      return connector ? (state) => connector.authorizeUrl(state) : null;
    },
    rateLimit: ({ user }) => takeRateLimit(createAdminClient(), user.id, "connection_start", CONNECTION_START_LIMIT),
    newState: ({ user }, p) => newOAuthState({ userId: user.id, provider: p }, oauthStateSecret()),
    saveNonce: (payload) => saveOAuthNonce(createAdminClient(), payload),
  });
}
