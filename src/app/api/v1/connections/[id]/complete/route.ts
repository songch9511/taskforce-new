import { after } from "next/server";

import { authenticateRequest } from "@/lib/api/auth";
import { handleConnectionComplete } from "@/lib/api/connections";
import { hasAiConsent } from "@/lib/api/profile-store";
import { afterConnected, connectorFor } from "@/lib/connectors/registry";
import { consumeOAuthHandoff } from "@/lib/connectors/store";
import { createAdminClient } from "@/lib/supabase/admin";

// 앱의 연결 마치기: POST /api/v1/connections/{provider}/complete { handoff } → { status }.
// callback이 남긴 완료 대기(handoff)를 시작한 사용자만 2분 안에 한 번 쓸 수 있다. 연결되면 응답 뒤(after) 첫 동기화를 돌린다.
// 같은 위치의 동적 경로가 이미 [id]라서 폴더 이름이 [id]다. 여기서는 id가 서비스 이름이다.
export const maxDuration = 300;

export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id: provider } = await params;
  const admin = createAdminClient();
  return handleConnectionComplete(request, provider, {
    authenticate: authenticateRequest,
    hasConsent: hasAiConsent,
    implemented: (p) => connectorFor(p) !== null,
    consumeHandoff: ({ user }, p, handoff) => consumeOAuthHandoff(admin, { id: handoff, userId: user.id, provider: p }),
    connect: ({ user }, p, code) => connectorFor(p)!.connect(admin, user.id, code),
    onConnected: ({ user }, p) => after(() => afterConnected(admin, user.id, p, { firstSync: true })),
  });
}
