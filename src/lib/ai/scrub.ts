// OpenRouter 오류 본문을 `.detail` 같은 곳에 담기 전에 거치는 가리개 (BYOK, 결제 계약 6.4).
// 제공자는 거절한 키를 본문에 되풀이할 수 있다. 사용자 키는 로그 · 오류 · 이벤트 어디에도 남지 않는다.
// 순서: 먼저 가리고 나중에 500자로 자른다(계약 6.4 "가린 뒤에만 담는다"). 접두만 남은 조각까지 가리므로 경계에 걸린 키도 새지 않는다.

// sk-or- 뒤에 이어지는 키 글자 전부(접두만 남은 경우도). 뒤에서 따옴표 · 공백 · 괄호를 만나면 끝난다.
const OPENROUTER_KEY = /sk-or-[\w.~+/=-]*/gi;

export const SCRUBBED_KEY = "sk-or-[가림]";

export function scrubSecrets(text: string): string {
  return text.replace(OPENROUTER_KEY, SCRUBBED_KEY);
}
