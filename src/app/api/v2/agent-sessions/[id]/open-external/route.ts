import { handleOpenExternal, realOpenExternalDeps } from "@/lib/api/agent-conversations";

// Open in Terminal의 서버 몫 (OA D1d, 계약 3.8 · AC-36): bound 세션을 external로 바꿔 Taskforce 전달을 막는다. 턴이 돌거나 답을 기다리면 409 session_busy. 본문 없음({}).
// 실제 터미널 열기 · Codex thread/unsubscribe는 Mac 앱과 bridge가 이 뒤에 한다 (OD-22).
export async function POST(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return handleOpenExternal(request, id, realOpenExternalDeps());
}
