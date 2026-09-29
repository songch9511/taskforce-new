import { z } from "zod";

import { authenticateRequest } from "@/lib/api/auth";
import { deviceRequestSchema } from "@/lib/api/contract";
import { errorResponse, parseBody, unauthorized } from "@/lib/api/respond";
import { createAdminClient } from "@/lib/supabase/admin";

/** 한 사용자가 알림을 받는 기기 수 상한. 넘으면 가장 오래 안 쓴 기기부터 뺀다. */
const MAX_DEVICES = 10;

// 알림용 기기 토큰 등록. 앱 실행 때마다 불러도 된다.
// 토큰은 앱 설치 하나에 하나라 전역에서 유일하다: 같은 기기에서 다른 계정으로 로그인하면 마지막 계정으로 옮겨 간다.
export async function POST(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const body = await parseBody(request, deviceRequestSchema);
  if ("error" in body) return body.error;

  const admin = createAdminClient();
  const { error } = await admin
    .from("devices")
    .upsert(
      { user_id: context.user.id, ...body.data, token: body.data.token.toLowerCase(), last_seen_at: new Date().toISOString() },
      { onConflict: "token" },
    );
  if (error) return errorResponse(500, "internal_error", "기기를 등록하지 못했습니다.");

  const { data: devices } = await admin
    .from("devices")
    .select("id")
    .eq("user_id", context.user.id)
    .order("last_seen_at", { ascending: false });
  const stale = (devices ?? []).slice(MAX_DEVICES).map((d) => d.id as string);
  if (stale.length > 0) await admin.from("devices").delete().eq("user_id", context.user.id).in("id", stale);
  return new Response(null, { status: 204 });
}

// 로그아웃할 때 앱이 부른다: 이 기기로 더는 알림을 보내지 않는다.
export async function DELETE(request: Request) {
  const context = await authenticateRequest(request);
  if (!context) return unauthorized();
  const body = await parseBody(request, z.object({ token: deviceRequestSchema.shape.token }));
  if ("error" in body) return body.error;
  const { error } = await createAdminClient().from("devices").delete().eq("user_id", context.user.id).eq("token", body.data.token.toLowerCase());
  // 실패를 204로 숨기면 로그아웃한 기기로 알림이 계속 간다 (앱은 결과와 상관없이 로그아웃한다)
  if (error) return errorResponse(500, "internal_error", "기기를 해제하지 못했습니다.");
  return new Response(null, { status: 204 });
}
