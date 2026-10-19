import type { AuthError } from "@supabase/supabase-js";

// Supabase Auth 오류를 운영자가 스스로 해결할 수 있는 문구로 바꾼다 (웹 /login은 내부 도구).
// 알 수 없는 오류는 서버 터미널 로그(code, status)로 원인을 확인한다.
export function loginCodeErrorMessage(error: Pick<AuthError, "code" | "status">): string {
  switch (error.code) {
    case "over_email_send_rate_limit":
      return "메일 발송 한도를 넘었습니다. 잠시 후 다시 시도해 주세요. Resend 무료의 하루 상한에 닿았다면 Pro로 올립니다 (docs/go-live/runbook.md).";
    case "email_address_invalid":
    case "email_address_not_authorized":
      return "이 이메일 주소로는 메일을 보낼 수 없습니다. Supabase 기본 메일은 프로젝트 팀원 주소로만 발송될 수 있습니다.";
    case "email_provider_disabled":
      return "이메일 로그인이 꺼져 있습니다. Supabase → Authentication → Sign In / Providers에서 Email을 켜 주세요.";
  }
  if (error.status === 401 || error.status === 403) {
    return "Supabase 키가 맞지 않습니다. .env.local의 NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY를 확인해 주세요.";
  }
  if (!error.status) {
    return "Supabase에 연결하지 못했습니다. .env.local의 NEXT_PUBLIC_SUPABASE_URL을 확인해 주세요.";
  }
  return "로그인 코드를 보내지 못했습니다. 개발 서버 터미널에 찍힌 오류를 확인해 주세요.";
}
