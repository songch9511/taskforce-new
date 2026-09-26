import { deleteAction, editAction } from "@/lib/actions/service";
import { actionWriteRoute } from "@/lib/api/action-routes";
import { editActionRequestSchema } from "@/lib/api/contract";
import { parseBody } from "@/lib/api/respond";

// PATCH: 사용자 수정 (user_edited). DELETE: 취소 처리 (user_deleted, 실제로 지우지 않음).
export const PATCH = actionWriteRoute(async ({ admin, user }, id, request) => {
  const body = await parseBody(request, editActionRequestSchema);
  if ("error" in body) return body.error;
  return editAction(admin, user.id, id, body.data);
});

export const DELETE = actionWriteRoute(({ admin, user }, id) => deleteAction(admin, user.id, id));
