import type { NextConfig } from "next";

// 보안 응답 헤더 (docs/go-live/runbook.md C8).
// 이 서버가 내보내는 것: 앱용 JSON API(/api/**), 내부 도구 화면(/lab · /admin/metrics · /login),
// OAuth 콜백(/api/connectors/**/callback)의 taskforce:// 리다이렉트.
// 리다이렉트 응답에는 CSP가 적용되지 않고(문서가 만들어지지 않는다), taskforce://로 가는 이동은 폼 제출이 아니라
// 권한 화면(외부 사이트)에서 시작된 이동이라 form-action에도 걸리지 않는다.

const commonHeaders = [
  // 2년, 하위 도메인 포함. preload 목록 등록은 되돌리기 어려워 넣지 않는다.
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=(), browsing-topics=()" },
  { key: "Cross-Origin-Opener-Policy", value: "same-origin" },
];

/** Supabase 프로젝트 주소(https · wss). 브라우저 클라이언트(src/lib/supabase/client.ts)가 붙을 곳이다 */
function supabaseSources(): string[] {
  const raw = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!raw) return [];
  try {
    const { host, origin } = new URL(raw);
    return [origin, `wss://${host}`];
  } catch {
    return [];
  }
}

// 화면용 CSP. nonce 없이 쓴다: App Router는 인라인 스크립트(RSC 페이로드 self.__next_f)를 넣는데,
// nonce를 붙이려면 proxy에서 요청마다 nonce를 만들고 모든 화면을 동적 렌더링해야 한다.
// 내부 도구 화면뿐이라 그 비용 대신 script-src에 'unsafe-inline'을 둔다 (사용자 HTML을 그대로 넣는 곳이 없고,
// 외부 스크립트 출처는 막는다). 개발 모드에서만 React 디버깅용 'unsafe-eval'을 더한다.
// upgrade-insecure-requests는 넣지 않는다: 로컬 `next start`(http://localhost)를 깨고, 배포에서는 HSTS가 같은 일을 한다.
function pageCsp(): string {
  const isDev = process.env.NODE_ENV === "development";
  return [
    "default-src 'self'",
    `script-src 'self' 'unsafe-inline'${isDev ? " 'unsafe-eval'" : ""}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' blob: data:",
    "font-src 'self'",
    ["connect-src 'self'", ...supabaseSources()].join(" "),
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join("; ");
}

// JSON API는 아무것도 불러오지 않는다.
const API_CSP = "default-src 'none'; frame-ancestors 'none'";

const nextConfig: NextConfig = {
  poweredByHeader: false,
  async headers() {
    return [
      { source: "/:path*", headers: [...commonHeaders, { key: "Content-Security-Policy", value: pageCsp() }] },
      // 같은 키는 뒤의 규칙이 덮어쓴다: /api/**만 API용 CSP로 바꾼다.
      { source: "/api/:path*", headers: [{ key: "Content-Security-Policy", value: API_CSP }] },
    ];
  },
};

export default nextConfig;
