import { handleRenameSession, realRenameSessionDeps } from "@/lib/api/agent-conversations";

// 세션 이름 바꾸기 (OA D1d, 계약 3.8): { display_name } trim 1–200자. 남의 · 없는 세션은 404. gate CONVERSATIONS_V2_ENABLED가 꺼져 있으면 404.
export async function PATCH(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleRenameSession(request, id, realRenameSessionDeps());
}
