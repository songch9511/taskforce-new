import { isUser, type Participants, type Person, type UserIdentity } from "@/lib/pipeline/identity";

// 상대(people, 아키텍처 5.5)의 순수 규칙. 저장은 store.ts observePerson → observe_person_handle (DB가 1차 키 · 2차 키로 사람을 고른다).
// - 1차 키는 서비스 계정 (provider, account_ref). 같은 계정은 사용자마다 한 사람에게만 붙는다 (people_handles unique).
// - 2차 키는 이메일: 정확히 한 사람과 같을 때만 그 사람에게 붙인다.
// - 이름은 보조 단서다: 이름만 같은 두 사람은 두 행이고, 이름만 있는 관찰(계정 · 이메일 없음)은 사람을 만들지 않는다.
// - 출처(어느 연결이 보여 준 계정 · 이름 · 이메일인지)를 people_handles에 남겨, Slack 끊기(D3) 때 Slack에서만 온 값을 지운다.

/** 원문 · 연결이 보여 준 계정 하나 */
export type PersonObservation = {
  provider: string;
  accountRef: string;
  displayName: string | null;
  email: string | null;
};

const EMAIL_PROVIDERS = new Set(["gmail", "google"]);
const normalizeEmail = (email: string) => email.trim().toLowerCase();
const looksLikeEmail = (value: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());

/** 계정 id 정규화: 메일 서비스는 주소(소문자), 그 밖은 앞뒤 공백만 뺀다 */
export function normalizeAccountRef(provider: string, accountRef: string): string {
  return EMAIL_PROVIDERS.has(provider) ? normalizeEmail(accountRef) : accountRef.trim();
}

/** Slack 사용자 계정: 워크스페이스까지 붙인다 (다른 워크스페이스의 같은 사용자 id는 다른 계정) */
export function slackObservation(teamId: string, slackUserId: string, name: string | null, email: string | null = null): PersonObservation {
  return { provider: "slack", accountRef: `${teamId}:${slackUserId}`, displayName: name?.trim() || null, email: email && looksLikeEmail(email) ? normalizeEmail(email) : null };
}

/**
 * 메일 · 캘린더 원문의 관련자에서 상대 계정을 뽑는다: 주소가 있는 사람만(계정 = 주소), 사용자 자신은 뺀다(isUser는 그대로 쓴다),
 * 같은 주소는 한 번. 이름만 있는 관련자는 사람을 만들지 않는다 (이름만으로 합치거나 만들지 않는다).
 */
export function observationsFromParticipants(provider: "gmail" | "google", participants: Participants | null | undefined, identity: UserIdentity): PersonObservation[] {
  if (!participants) return [];
  const people: (Person | undefined)[] = [participants.from, ...(participants.to ?? []), ...(participants.cc ?? []), ...(participants.attendees ?? [])];
  const seen = new Set<string>();
  const observations: PersonObservation[] = [];
  for (const person of people) {
    if (!person?.email || !looksLikeEmail(person.email) || isUser(person, identity, participants)) continue;
    const email = normalizeEmail(person.email);
    if (seen.has(email)) continue;
    seen.add(email);
    observations.push({ provider, accountRef: email, displayName: person.name?.trim() || null, email });
  }
  return observations;
}
