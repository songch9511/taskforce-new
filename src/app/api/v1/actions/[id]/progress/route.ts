import { setActionProgress } from "@/lib/actions/service";
import { actionWriteRoute } from "@/lib/api/action-routes";
import { actionProgressRequestSchema } from "@/lib/api/contract";
import { parseBody } from "@/lib/api/respond";

// 작업 상태 { state: to_do | in_progress | done }: 다시 열기(user_edited) · 착수(user_started + action_started) · 착수 되돌리기(user_unstarted)
export const POST = actionWriteRoute(async ({ admin, user }, id, request) => {
  const body = await parseBody(request, actionProgressRequestSchema);
  if ("error" in body) return body.error;
  return setActionProgress(admin, user.id, id, body.data.state);
});
