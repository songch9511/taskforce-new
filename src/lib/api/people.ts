import type { ParticipantsInput } from "./contract";

type Person = NonNullable<ParticipantsInput["from"]>;

const EMAIL = /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/;

/** "김대표 <ceo@x.com>, me@x.com, 태오" 같은 입력을 사람 목록으로 바꾼다. 쉼표 · 세미콜론 · 줄바꿈으로 나눈다. */
export function parsePeople(input: string): Person[] {
  return input
    .split(/[,;\n]/)
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part): Person => {
      const bracket = part.match(/^(.*?)\s*<([^<>]+)>$/);
      if (bracket) {
        const name = bracket[1].replace(/^["']|["']$/g, "").trim();
        return name ? { name, email: bracket[2].trim() } : { email: bracket[2].trim() };
      }
      return EMAIL.test(part) ? { email: part } : { name: part };
    });
}

/** 쉼표로 나눈 목록 ("도연, Doyun") */
export function parseList(input: string): string[] {
  return input
    .split(/[,;\n]/)
    .map((part) => part.trim())
    .filter(Boolean);
}
