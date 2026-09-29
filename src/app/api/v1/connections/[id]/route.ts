import { authenticateRequest } from "@/lib/api/auth";
import { handleConnectionDelete } from "@/lib/api/connections";
import { connectProviderSchema } from "@/lib/api/contract";
import { tokenRevokerFor } from "@/lib/connectors/registry";
import { loadToken } from "@/lib/connectors/store";
import type { Provider } from "@/lib/connectors/types";
import { createAdminClient } from "@/lib/supabase/admin";

// 연결 끊기: DELETE /api/v1/connections/:id → 204. 서버 권한으로 서비스 쪽 토큰을 폐기하고, Slack이면 Slack에서 온 글자를 지운 뒤(D3) 연결을 지운다.
// 할 일은 남는다. Notion 원문은 남고, Slack 원문은 본문 · 인용이 지워진다 (lib/api/connections.ts handleConnectionDelete).
// 앱은 연결 행을 직접 지울 수 없다 (20261014000000에서 owner_delete 정책을 지운다).
export const maxDuration = 30;

export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const admin = createAdminClient();
  return handleConnectionDelete(request, id, {
    authenticate: async (req) => (await authenticateRequest(req))?.user ?? null,
    load: async (user, connectionId) => {
      const { data } = await admin
        .from("connections")
        .select("provider")
        .eq("id", connectionId)
        .eq("user_id", user.id)
        .maybeSingle<{ provider: Provider }>()
        .throwOnError();
      if (!data) return null;
      return { provider: data.provider, token: await loadToken(admin, connectionId).catch(() => null) };
    },
    revoker: (provider) => {
      const parsed = connectProviderSchema.safeParse(provider);
      return parsed.success ? tokenRevokerFor(parsed.data) : null;
    },
    disconnect: async (user, connectionId) => {
      const { data } = await admin.rpc("disconnect_connection", { p_user_id: user.id, p_connection_id: connectionId }).throwOnError();
      return data === true;
    },
  });
}
