// Google 문서만으로는 확인되지 않아 dev 회의(Meet 전사 둘)로 확인할 가정들. 가정마다 이름 붙인 상수 · 함수 하나로 모아,
// dev 결과가 다르면 여기 한 줄만 바꾼다 (docs/go-live/google-integration.md 9장 "PR 3 dev에서 확인할 것").
// 나머지 코드(calendar.ts · meet.ts · sync.ts · transcript.ts)는 이 파일을 거쳐서만 가정을 쓴다.

/** Calendar 범위 (google-verification.md 1장). 상대가 보낸 초대가 이 범위로 보이는지 문서에 없다 (9장 "Calendar 범위").
 * dev에서 초대가 안 보이면 "https://www.googleapis.com/auth/calendar.events.readonly"로 바꾸고 심사 문안 · 처리방침 권한 이름을 함께 고친다 */
export const CALENDAR_EVENTS_SCOPE = "https://www.googleapis.com/auth/calendar.events.owned.readonly";

/** Meet 범위 (전사 항목 · 참가자 · 회의 공간 읽기, 민감) */
export const MEET_READONLY_SCOPE = "https://www.googleapis.com/auth/meetings.space.readonly";

/**
 * G2 ②: 참석한(주최하지 않은) 회의의 전사도 찾는가. Calendar에서 참석한 Meet 일정의 회의 코드로 `conferenceRecords.list`를 부른다.
 * Google 문서가 서로 달라(가이드: "list는 주최한 회의만" / 릴리스 노트: "참가자도 회의 기록을 조회") dev에서 두 계정으로 시험한다.
 * 참석한 회의를 못 찾으면(빈 목록 · 403) false로 바꾸고 처리방침 3장 · 앱 문구를 "내가 주최한 회의"로 적는다
 * (앱은 `Connections.swift` `readsBeforeConnecting`의 Meet 한 줄 "…meetings you attend" → "…meetings you host").
 */
export const LIST_ATTENDED_MEETINGS: boolean = true;

/**
 * G5: Meet 참가자(`signedinUser.user` = "users/{id}")가 연결한 Google 계정(OIDC `sub`)인가.
 * 두 id가 같은 값이라는 문장은 Google 문서에 없다 (9장 "Meet 참가자 → 사용자"). 다르면 이 함수만 바꾼다:
 * 범위 `profile`(비민감)을 더해 `id_token`의 계정 이름을 Meet 표시 이름과 비교하는 것이 계획의 대안이다 (지금은 범위를 더하지 않는다).
 */
export function isConnectedAccount(participantUser: string | undefined, accountSub: string | null): boolean {
  return Boolean(participantUser && accountSub) && participantUser === `users/${accountSub}`;
}

/**
 * Calendar `conferenceData.conferenceId`와 Meet 회의 공간 `meetingCode`가 같은 회의인가.
 * 둘 다 "aaa-bbbb-ccc" 모양이지만 같은 값이라는 문장은 없다 (9장 "Meet 코드 ↔ 일정"). 대소문자 · 하이픈은 무시하고 비교한다.
 * 다르면(예: 다른 형식) 이 함수만 바꾼다.
 */
export function sameMeetingCode(conferenceId: string | undefined, meetingCode: string | undefined): boolean {
  const normalize = (code: string | undefined) => (code ?? "").toLowerCase().replace(/-/g, "");
  return normalize(conferenceId) !== "" && normalize(conferenceId) === normalize(meetingCode);
}
