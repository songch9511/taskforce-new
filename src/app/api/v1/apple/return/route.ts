import { APPLE_RETURN_MAX_BYTES } from "@/lib/api/contract";
import { appleReturnLocation } from "@/lib/apple/web-return";

// Mac의 Apple 웹 로그인 · 계정 삭제 재확인이 돌아오는 곳 (Apple Developer › Services ID › Return URLs).
// Apple은 https return URL로 form_post(application/x-www-form-urlencoded)만 보내므로, 결과를 taskforce://auth/apple?… 로 넘겨 앱에 돌려준다.
// 로그인 없이 부른다(아직 로그인 전이고 Apple이 보낸다): 이 route는 아무것도 저장 · 확인하지 않고 주소만 만든다. DB · 외부 호출 0.
// Slack events route처럼 로그인이 없는 이유: 받는 쪽(앱)이 자기가 만든 state일 때만 쓰고, Supabase가 ID 토큰의 서명 · aud · nonce를 확인한다.
// 누구나 POST할 수 있어도 결과는 상수 주소 하나(taskforce://auth/apple)로 가는 것뿐이라 열린 리다이렉트가 아니다.
// 로그 0: 본문 · Location · 토큰 · code · 이메일을 남기지 않는다 (console을 쓰지 않는다). code가 쿼리 문자열(접근 로그)에 남지 않게 form_post로만 받는다.
export const maxDuration = 10;

const FORM_TYPE = "application/x-www-form-urlencoded";

/** 본문을 상한까지만 읽는다. 넘으면 null (content-length가 없거나 거짓이어도 실제로 읽은 바이트로 센다) */
async function readLimited(request: Request, limit: number): Promise<string | null> {
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  return new TextDecoder().decode(Buffer.concat(chunks));
}

export async function POST(request: Request) {
  if (!request.headers.get("content-type")?.toLowerCase().startsWith(FORM_TYPE)) return new Response(null, { status: 415 });
  if (Number(request.headers.get("content-length") ?? 0) > APPLE_RETURN_MAX_BYTES) return new Response(null, { status: 413 });
  const body = await readLimited(request, APPLE_RETURN_MAX_BYTES);
  if (body === null) return new Response(null, { status: 413 });
  return new Response(null, {
    status: 303,
    headers: { Location: appleReturnLocation(body), "Cache-Control": "no-store", "Referrer-Policy": "no-referrer" },
  });
}

/** Apple은 form_post로만 보낸다: 주소를 열어 본 사람에게 아무것도 보여 주지 않는다 */
export async function GET() {
  return new Response(null, { status: 405, headers: { Allow: "POST", "Cache-Control": "no-store" } });
}
