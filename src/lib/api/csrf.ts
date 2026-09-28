// 쿠키로 인증하는 쓰기 요청의 CSRF 막기. 앱은 Authorization: Bearer로 오므로 해당하지 않는다.
// 웹(/lab)은 같은 출처에서 fetch로 부르므로, 다른 사이트에서 온 쓰기 요청(폼 전송 · text/plain fetch 등)을 거절한다.
// 브라우저가 붙이는 Sec-Fetch-Site를 먼저 보고, 없으면 Origin을 요청 주소의 출처와 비교한다. 둘 다 없으면(브라우저가 아님) 통과시킨다.
// (Supabase 세션 쿠키가 SameSite=Lax라 다른 사이트의 POST에는 쿠키가 실리지 않지만, 쿠키 설정에만 기대지 않는다.)

const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

export function isCrossSiteWrite(request: Request): boolean {
  if (SAFE_METHODS.has(request.method.toUpperCase())) return false;
  const site = request.headers.get("sec-fetch-site");
  if (site) return site !== "same-origin" && site !== "none";
  const origin = request.headers.get("origin");
  if (origin) return origin !== new URL(request.url).origin;
  return false;
}
