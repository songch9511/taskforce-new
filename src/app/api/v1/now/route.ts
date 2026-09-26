import { nowList } from "@/lib/actions/service";
import { authenticateRequest } from "@/lib/api/auth";
import type { NowResponse } from "@/lib/api/contract";
import { errorResponse, unauthorized } from "@/lib/api/respond";

// 지금 할 일 순서와 확인 요청 목록. 순서 계산은 서버에만 둔다 (앱에 같은 로직을 두지 않는다).
export async function GET(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  try {
    return Response.json((await nowList(context.supabase)) satisfies NowResponse);
  } catch (error) {
    console.error("지금 할 일 조회 실패:", error instanceof Error ? error.message : error);
    return errorResponse(500, "internal_error", "목록을 불러오지 못했습니다.");
  }
}
