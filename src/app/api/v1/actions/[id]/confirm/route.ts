import { confirmAction } from "@/lib/actions/service";
import { actionWriteRoute } from "@/lib/api/action-routes";

// 확인 요청을 한 번 탭으로 확정한다 (user_confirmed). 고쳐서 확정하려면 PATCH 뒤에 부른다.
export const POST = actionWriteRoute(({ admin, user }, id) => confirmAction(admin, user.id, id));
