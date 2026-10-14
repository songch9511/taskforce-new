import { handleGetDeliveries, realDeliveryReadDeps } from "@/lib/api/agent-conversations";

// 전달 읽기 (OA D1d, OD-13): ?since_seq= 뒤의 사용자 메시지 ≤ 100개의 전달 표시(sent · accepted · unknown 포함)를 서버 계산으로 돌려준다. 읽기만 한다 (CSRF 대상 아님).
export async function GET(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleGetDeliveries(request, id, realDeliveryReadDeps());
}
