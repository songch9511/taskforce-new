import type { LegalResponse, PolicyVersion } from "@/lib/api/contract";

// 개인정보 처리방침의 판 · 시행일 (한 곳). 앱은 GET /api/v1/legal로 받아 변경 안내를 보인다 (처리방침 17장: 앱과 페이지에 알린다).
// 처리방침을 바꿀 때 여기 버전 · 시행일을 함께 바꾼다 (docs/go-live/runbook.md 7장).
// - 게시와 함께 시행: current를 새 판으로 바꾼다 → 그 전에 가입한 계정에 "Privacy Policy updated".
// - 미리 알림(시행 7일 전, 이용자에게 불리하면 30일 전): upcoming에 새 판을 둔다 → 모든 계정에 "Privacy Policy changes <날짜>".
//   시행일이 지나면 배포 없이 현재 판이 된다(privacyPolicyStatus). 다음에 고칠 때 current로 옮기고 upcoming을 비운다.

export type PrivacyPolicy = { current: PolicyVersion; upcoming: PolicyVersion | null };

const PRIVACY_URL = { ko: "https://www.taskforcelabs.dev/ko/privacy", en: "https://www.taskforcelabs.dev/en/privacy" };

export const PRIVACY_POLICY: PrivacyPolicy = {
  current: { version: "beta-1.1", effective_date: "2026-09-30", url: PRIVACY_URL },
  upcoming: null,
};

/** 시행일은 한국 시간 그날 0시부터 */
export function effectiveAt(version: PolicyVersion): Date {
  return new Date(`${version.effective_date}T00:00:00+09:00`);
}

/**
 * 이 계정에 보일 판과 안내 (순수 함수).
 * 시행 예정 판이 있으면 그 안내가 먼저다(지금 있는 계정은 모두 그 시행일 전에 가입했다). 없으면 현재 판의 시행일 전에 가입한 계정만 "updated".
 */
export function privacyPolicyStatus(policy: PrivacyPolicy, accountCreatedAt: Date, now: Date): LegalResponse["privacy"] {
  let { current, upcoming } = policy;
  if (upcoming && effectiveAt(upcoming) <= now) {
    current = upcoming;
    upcoming = null;
  }
  const notice = upcoming
    ? { ...upcoming, kind: "upcoming" as const }
    : accountCreatedAt < effectiveAt(current)
      ? { ...current, kind: "updated" as const }
      : null;
  return { current, upcoming, notice };
}
