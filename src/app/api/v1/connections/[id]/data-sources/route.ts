import { z } from "zod";

import { authenticateRequest } from "@/lib/api/auth";
import { errorResponse, unauthorized } from "@/lib/api/respond";
import { DataSourceError, listDataSources } from "@/lib/connectors/notion/data-sources";
import { createAdminClient } from "@/lib/supabase/admin";

// 연결에 공유된 Notion 데이터베이스와 역할(할 일 · 회의 · 무시). 확인 전이면 제안값을 보여준다.
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const { id } = await params;
  if (!z.uuid().safeParse(id).success) return errorResponse(404, "not_found", "연결이 없습니다.");

  try {
    return Response.json({ dataSources: await listDataSources(createAdminClient(), context.user.id, id) });
  } catch (error) {
    if (error instanceof DataSourceError) return errorResponse(error.status, error.status === 404 ? "not_found" : "invalid_request", error.message);
    console.error("데이터베이스 목록 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "Notion 데이터베이스를 불러오지 못했습니다.");
  }
}
