// 웹 /login 로그용 도우미. 보내기 실패는 화면에 내지 않는다(actions.ts: 운영자 목록 안 · 밖이 같은 응답이어야 한다) — 원인은 서버 로그(code · status)로 본다.
/** 오류 문구에 섞인 이메일 주소를 가린다 (대소문자 무시, 주소의 . · +는 글자 그대로). 로그에 남기기 전에 쓴다 */
export function maskEmail(message: string, email: string): string {
  if (!email) return message;
  return message.replace(new RegExp(email.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"), "<email>");
}
