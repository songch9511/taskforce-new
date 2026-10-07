import { isUser, type UserIdentity } from "./identity";
import { quoteLineIndexes } from "./text";

/**
 * 문서의 "준혁님 PR 업데이트" 같은 담당자 선두 항목만 읽는다.
 * 화자(준혁님:), 받는 사람(준혁님께), 동료(준혁님과)는 담당 근거가 아니다.
 * 인용에서 이름이 빠질 수 있어 원문 줄을 읽고, 반복 인용은 모든 줄의 담당이 같아야 한다.
 * 자유로운 문장 · 이름 없는 항목의 담당은 추측하지 않는다.
 */
export function hasExplicitOtherAssignee(text: string, quote: string, identity: UserIdentity): boolean {
  const lines = text.split("\n");
  const indexes = quoteLineIndexes(text, quote);
  if (indexes.length === 0) return false;
  const names = indexes.map((index) => {
    const line = lines[index]
      .trim()
      .replace(/^(?:[-*•]|\d+[.)])\s+/, "")
      .replace(/^\[[ xX]\]\s*/, "")
      .replace(/\*\*|__/g, "");
    const match = line.match(/^@?([가-힣]{2,4})\s*(?:님|씨)\s+(?:[-–]\s+)?(.+)$/);
    if (!match) return null;
    const [, name, task] = match;
    // 띄어 쓴 화자 구분, 공동 담당, 요청자의 설명은 단독 담당으로 확정할 수 없다.
    if (/^(?:[:,/&·]|및\s|요청|부탁|말씀|제안)/.test(task)) return null;
    if (/^@?[가-힣]{2,4}\s*(?:님|씨)(?:\s|[,/&·])/.test(task)) return null;
    // "준혁님 제가 할게요"의 선두 이름은 호칭이다. 대화 문장까지 담당자 항목으로 해석하지 않는다.
    if (/(?:^|\s)(?:제가|저는|저희가|저희는|내가|나는|우리가|우리는|전)\s/.test(task)) return null;
    if (/[?!]|(?:요|니다|할게|할께|할래)[.!。]*$/.test(task)) return null;
    return name;
  });
  const [name] = names;
  // 한 음절이 비슷하다는 추측은 담당 근거가 아니다. 본인 이름 · 등록한 별칭만 인정한다.
  return name !== null && names.every((other) => other === name) && !isUser({ name }, identity);
}
