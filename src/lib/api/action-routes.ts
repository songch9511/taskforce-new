import "server-only";

import { z } from "zod";

import { WriteConflictError } from "@/lib/actions/db-store";
import { ActionNotFoundError } from "@/lib/actions/service";
import type { ActionSummary } from "@/lib/api/contract";
import { createAdminClient } from "@/lib/supabase/admin";

import { authenticateRequest, type ApiContext } from "./auth";
import { errorResponse, unauthorized } from "./respond";

// /api/v1/actions/:id/* 공통: 인증 → id 확인 → 쓰기(service role) → { action } 응답

type Params = { params: Promise<{ id: string }> };
type Write = (context: ApiContext & { admin: ReturnType<typeof createAdminClient> }, actionId: string, request: Request) => Promise<ActionSummary | Response>;

export function actionWriteRoute(write: Write) {
  return async (request: Request, { params }: Params): Promise<Response> => {
    const context = await authenticateRequest(request);
    if (!context) return unauthorized();
    const { id } = await params;
    if (!z.uuid().safeParse(id).success) return errorResponse(404, "not_found", "Action이 없습니다.");

    try {
      const result = await write({ ...context, admin: createAdminClient() }, id, request);
      return result instanceof Response ? result : Response.json({ action: result });
    } catch (error) {
      if (error instanceof ActionNotFoundError) return errorResponse(404, "not_found", "Action이 없습니다.");
      if (error instanceof WriteConflictError) return errorResponse(409, "conflict", error.message);
      console.error("Action 쓰기 실패:", error instanceof Error ? error.message : error);
      return errorResponse(500, "internal_error", "저장하지 못했습니다.");
    }
  };
}
