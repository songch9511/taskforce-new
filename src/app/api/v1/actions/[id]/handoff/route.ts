import { handoffAction } from "@/lib/actions/service";
import { actionWriteRoute } from "@/lib/api/action-routes";

// AI에게 넘기기: 맥락 · 근거 인용을 묶은 마크다운 (handoff_used 지표, 지표 2)
export const POST = actionWriteRoute(async ({ admin, supabase, user }, id) => Response.json(await handoffAction(supabase, admin, user.id, id)));
