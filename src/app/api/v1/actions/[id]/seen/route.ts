import { markActionSeen } from "@/lib/actions/service";
import { actionWriteRoute } from "@/lib/api/action-routes";

// 본 것 표시 (U1 바뀜 점): 지금 바뀐 할 일일 때만 user_seen 한 줄, 아니면 쓰지 않는다. 어느 쪽이든 204 (contract.ts)
export const POST = actionWriteRoute(async ({ admin, supabase, user }, id) => {
  await markActionSeen(supabase, admin, user.id, id);
  return new Response(null, { status: 204 });
});
