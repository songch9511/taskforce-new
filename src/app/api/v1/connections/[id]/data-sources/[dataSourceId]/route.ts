import { z } from "zod";

import { authenticateRequest } from "@/lib/api/auth";
import { saveDataSourceRequestSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { DataSourceError, saveDataSource } from "@/lib/connectors/notion/data-sources";
import { createAdminClient } from "@/lib/supabase/admin";

// 데이터베이스 역할 · 속성 매핑 확인. 확인한 할 일 DB만 다음 동기화부터 구조화된 할 일로 처리한다.
export async function PUT(request: Request, { params }: { params: Promise<{ id: string; dataSourceId: string }> }) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const { id, dataSourceId } = await params;
  if (!z.uuid().safeParse(id).success || !z.guid().safeParse(dataSourceId).success) {
    return errorResponse(404, "not_found", "연결이나 데이터베이스가 없습니다.");
  }
  const body = await parseBody(request, saveDataSourceRequestSchema);
  if ("error" in body) return body.error;

  try {
    return Response.json({ dataSource: await saveDataSource(createAdminClient(), context.user.id, id, dataSourceId, body.data) });
  } catch (error) {
    if (error instanceof DataSourceError) return errorResponse(error.status, error.status === 404 ? "not_found" : "invalid_request", error.message);
    console.error("데이터베이스 설정 저장 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "저장하지 못했습니다.");
  }
}
