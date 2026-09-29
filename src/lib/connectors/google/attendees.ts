import type { Person } from "@/lib/pipeline/identity";

import { storableText } from "../gmail/mime";

// 회의 원문의 관련자(participants.attendees)를 합친다: Notion 사람 속성 · Calendar 일정 참석자 · Meet 참가자 (google-integration.md 2-4 5 · 2-5 관련자). 순수 함수.

/** 원문 관련자 한도 (participantsSchema의 attendees 상한과 같다) */
export const MAX_ATTENDEES = 200;
/** 이름 · 이메일 한 칸의 길이 상한 (personSchema와 같다) */
const MAX_NAME = 100;
const MAX_EMAIL = 320;

const nameKey = (name: string) => name.replace(/\s+/g, "").toLowerCase();

/** 이름 · 이메일을 다듬는다 (이메일은 소문자, Postgres가 받지 않는 글자는 뺀다). 둘 다 비면 null */
export function cleanPerson(input: { name?: string | null; email?: string | null }): Person | null {
  const name = input.name ? storableText(input.name.replace(/\s+/g, " ").trim().slice(0, MAX_NAME)).trim() : undefined;
  const email = input.email ? storableText(input.email.trim().toLowerCase().slice(0, MAX_EMAIL)) : undefined;
  if (!name && !email) return null;
  return { ...(name ? { name } : {}), ...(email ? { email } : {}) };
}

/** 같은 사람인가: 둘 다 이메일이 있으면 이메일이 같을 때만, 한쪽이라도 없으면 이름이 같을 때 (공백 · 대소문자 무시) */
function samePerson(a: Person, b: Person): boolean {
  if (a.email && b.email) return a.email === b.email;
  return Boolean(a.name && b.name) && nameKey(a.name!) === nameKey(b.name!);
}

/**
 * base에 extra를 합친다. 같은 사람이면 빠진 칸(이름 · 이메일)만 채우고, 새 사람은 뒤에 붙인다. limit을 넘는 새 사람은 버린다.
 * 순서는 base가 먼저다 (사용자 → 일정 참석자 → Meet 참가자).
 */
export function mergeAttendees(base: readonly Person[], extra: readonly Person[], limit = MAX_ATTENDEES): Person[] {
  const merged: Person[] = [];
  for (const person of [...base, ...extra]) {
    const clean = cleanPerson(person);
    if (!clean) continue;
    const existing = merged.find((m) => samePerson(m, clean));
    if (existing) {
      existing.name ??= clean.name;
      existing.email ??= clean.email;
    } else if (merged.length < limit) {
      merged.push(clean);
    }
  }
  return merged;
}
