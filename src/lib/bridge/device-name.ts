import type { SupabaseClient } from "@supabase/supabase-js";

import { BRIDGE_DEVICE_NAME_MAX } from "@/lib/api/contract";

// Mac 기기 이름은 화면에 보이는 표시용 글자다 (OA F1s). 식별에 쓰지 않고, 로그 · 지표 · 오류 문구 · AI 입력에 넣지 않는다.
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });

/**
 * 받은 이름을 저장할 모양으로 만든다: 공백 종류(탭 · 줄바꿈 · 폭 있는 공백)는 공백 하나로 → 제어(Cc) · 서식(Cf: 양방향 제어 · 폭 없는 문자) · 짝 없는 서로게이트 제거 →
 * NFC → 앞뒤 trim → 글자소 중간을 자르지 않고 64 코드 포인트까지. 비면 null (쓰지 않는다). DB CHECK(bridges_device_name_shape)는 마지막 방어다.
 */
export function normalizeDeviceName(raw: string | null | undefined): string | null {
  if (typeof raw !== "string") return null;
  const text = raw
    .replace(/[\p{Z}\t\n\v\f\r\u0085]/gu, " ")
    .replace(/[\p{Cc}\p{Cf}\p{Cs}]/gu, "")
    .normalize("NFC")
    .replace(/ {2,}/g, " ")
    .trim();
  let kept = "";
  let points = 0;
  for (const { segment } of graphemes.segment(text)) {
    const size = Array.from(segment).length;
    if (points + size > BRIDGE_DEVICE_NAME_MAX) break;
    kept += segment;
    points += size;
  }
  kept = kept.trim();
  return kept === "" ? null : kept;
}

/**
 * register · heartbeat가 이름을 한 번 쓴다. 이름은 부가 정보라 실패해도 bridge 응답을 바꾸지 않는다 (이미 secret을 회전했거나 생존을 알린 뒤다):
 * 로그에는 사건 이름만 남기고 이름 · id는 싣지 않는다. 같은 이름이면 SQL이 행을 쓰지 않으므로 평소 비용은 RPC 한 번이다.
 */
export async function saveBridgeDeviceName(admin: SupabaseClient, input: { userId: string; bridgeId: string; deviceName: string | undefined }) {
  const name = normalizeDeviceName(input.deviceName);
  if (name === null) return;
  try {
    await admin.rpc("set_bridge_device_name", { p_user_id: input.userId, p_bridge_id: input.bridgeId, p_device_name: name }).throwOnError();
  } catch {
    console.error(JSON.stringify({ event: "bridge_device_name_failed" }));
  }
}
