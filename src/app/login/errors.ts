import type { AuthError } from "@supabase/supabase-js";

// Supabase Auth 오류를 화면 문구로 바꾼다 (웹 /login은 내부 도구지만 공개 주소다).
// 내부 설정 안내(환경 변수 · 대시보드 · 공급자 이름 · 문서 경로)는 화면에 싣지 않는다: 원인은 서버 로그(code, status)로 확인한다.
export function loginCodeErrorMessage(error: Pick<AuthError, "code" | "status">): string {
  switch (error.code) {
    case "over_email_send_rate_limit":
      return "메일 발송 한도를 넘었습니다. 잠시 후 다시 시도해 주세요.";
    case "email_address_invalid":
    case "email_address_not_authorized":
      return "이 이메일 주소로는 메일을 보낼 수 없습니다.";
    case "email_provider_disabled":
      return "지금은 이메일 로그인을 쓸 수 없습니다.";
  }
  return "로그인 코드를 보내지 못했습니다. 잠시 후 다시 시도해 주세요.";
}

/** 오류 문구에 섞인 이메일 주소를 가린다 (대소문자 무시, 주소의 . · +는 글자 그대로). 로그에 남기기 전에 쓴다 */
export function maskEmail(message: string, email: string): string {
  if (!email) return message;
  return message.replace(new RegExp(email.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"), "<email>");
}
