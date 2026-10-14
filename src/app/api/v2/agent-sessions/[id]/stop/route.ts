import { handleStopSession, realStopSessionDeps } from "@/lib/api/agent-conversations";

// 세션 패널의 Stop (OA D1d, 계약 5장): 대화 Stop과 같은 동작 (surface session_panel). 본문 없음({}).
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleStopSession(request, id, realStopSessionDeps());
}
