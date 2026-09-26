import { authenticateRequest } from "@/lib/api/auth";

// 연결 끊기: 사용자 권한(RLS)으로 지운다. 토큰은 함께 지워지고, 이미 들어온 원문과 할 일은 남는다.
export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }) {
  const context = await authenticateRequest(request);
  if (!context) return Response.json({ error: { code: "unauthorized", message: "로그인이 필요합니다." } }, { status: 401 });

  const { id } = await params;
  const { data, error } = await context.supabase.from("connections").delete().eq("id", id).select("id");
  if (error) return Response.json({ error: { code: "internal_error", message: "연결을 끊지 못했습니다." } }, { status: 500 });
  if (!data?.length) return Response.json({ error: { code: "invalid_request", message: "연결이 없습니다." } }, { status: 404 });
  return new Response(null, { status: 204 });
}
