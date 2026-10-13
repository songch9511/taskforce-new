import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { AGENT_REGISTRY } from "./registry";

export const stopAgentSessionResultSchema = z.union([
  z.strictObject({ tasks: z.array(z.strictObject({
    agent_task_id: z.guid(), cancel: z.enum(["requested_only", "confirmed"]),
    processes: z.literal("may_continue").optional(),
  })) }),
  z.strictObject({ status: z.literal("not_found") }),
]);
export type StopAgentSessionResult = z.infer<typeof stopAgentSessionResultSchema>;

export async function stopAgentSession(admin: SupabaseClient, input: {
  userId: string; sessionId: string; surface: "assistant" | "session_panel";
}): Promise<StopAgentSessionResult> {
  const userId = z.guid().parse(input.userId);
  const sessionId = z.guid().parse(input.sessionId);
  const surface = z.enum(["assistant", "session_panel"]).parse(input.surface);
  const { data: sessionData } = await admin.from("agent_sessions").select("connection_id")
    .eq("user_id", userId).eq("id", sessionId).maybeSingle().throwOnError();
  if (!sessionData) return { status: "not_found" };
  const session = z.object({ connection_id: z.guid() }).parse(sessionData);
  const { data: connectionData } = await admin.from("agent_connections").select("adapter")
    .eq("user_id", userId).eq("id", session.connection_id).maybeSingle().throwOnError();
  if (!connectionData) return { status: "not_found" };
  const connection = z.object({ adapter: z.enum(["agent:claude-code", "agent:codex"]) }).parse(connectionData);
  for (let attempt = 1; ; attempt++) {
    try {
      const { data } = await admin.rpc("stop_agent_session", {
        p_user_id: userId, p_session_id: sessionId, p_surface: surface,
        p_cancel_scope: AGENT_REGISTRY[connection.adapter].cancel_scope ?? "unknown",
      }).throwOnError();
      return stopAgentSessionResultSchema.parse(data);
    } catch (error) {
      // NOWAIT contention rolls back Stop atomically, so a bounded retry is safe.
      if (attempt >= 3 || typeof error !== "object" || error === null || !("code" in error) || error.code !== "55P03") throw error;
    }
  }
}
