import { startAction } from "@/lib/actions/service";
import { actionWriteRoute } from "@/lib/api/action-routes";

// 착수 (user_started + metric action_started, 지표 2)
export const POST = actionWriteRoute(({ admin, user }, id) => startAction(admin, user.id, id));
