import { saveActionNotes } from "@/lib/actions/service";
import { actionWriteRoute } from "@/lib/api/action-routes";
import { actionNotesRequestSchema } from "@/lib/api/contract";
import { parseBody } from "@/lib/api/respond";

// Notes are user-authored handoff context, not a judged Action field or source-backed Claim.
export const PUT = actionWriteRoute(async ({ admin, supabase, user }, id, request) => {
  const body = await parseBody(request, actionNotesRequestSchema);
  if ("error" in body) return body.error;
  return Response.json(await saveActionNotes(supabase, admin, user.id, id, body.data));
});
