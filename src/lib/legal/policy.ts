import type { LegalResponse, PolicyVersion } from "@/lib/api/contract";

// 개인정보 처리방침의 판 · 시행일 (한 곳). 앱은 GET /api/v1/legal로 받아 변경 안내를 보인다 (처리방침 17장: 앱과 페이지에 알린다).
// 처리방침을 바꿀 때 여기 버전 · 시행일을 함께 바꾼다 (docs/go-live/runbook.md 7장 8번).
// - 기본 (go live 뒤의 모든 실질 변경): upcoming에 새 판을 둔다 → 모든 계정에 "Privacy Policy changes <날짜>".
//   17장의 약속대로 시행 7일 전부터, 수집 항목 · 목적 · 받는 곳이 늘어나는 변경은 30일 전부터 둔다.
//   upcoming.url은 그 판의 버전 주소(`/{lang}/privacy/{version}`)여야 한다: 알리는 동안 `/{lang}/privacy`는 아직 현재 판이다.
//   시행일이 지나면 배포 없이 현재 판이 된다(policyAt). 다음에 고칠 때 current로 옮기고 upcoming을 비운다.
// - current만 바꾸기 (게시와 함께 시행, 알림은 시행 뒤): 처리 내용이 바뀌지 않는 고침(오탈자 · 문장 다듬기 · 연락처)이거나
//   계정이 운영자 것뿐일 때만 (베타 1.1이 그랬다, docs/legal/README.md 게시 기록). 그 전에 가입한 계정에 30일 동안 "Privacy Policy updated".

export type PrivacyPolicy = { current: PolicyVersion; upcoming: PolicyVersion | null };

const PRIVACY_URL = { ko: "https://www.taskforcelabs.dev/ko/privacy", en: "https://www.taskforcelabs.dev/en/privacy" };

export const PRIVACY_POLICY: PrivacyPolicy = {
  current: { version: "beta-1.1", effective_date: "2026-09-30", url: PRIVACY_URL },
  upcoming: null,
};

/** 시행된 판의 "updated" 안내를 보이는 기간. 몇 달 뒤 처음 앱을 연 옛 계정에 지난 안내를 보이지 않는다 */
export const UPDATED_NOTICE_DAYS = 30;

/** 시행일은 한국 시간 그날 0시부터 */
export function effectiveAt(version: PolicyVersion): Date {
  return new Date(`${version.effective_date}T00:00:00+09:00`);
}

/** 이 시각의 판: 시행일이 지난 시행 예정 판은 현재 판이 된다 */
export function policyAt(policy: PrivacyPolicy, now: Date): PrivacyPolicy {
  if (policy.upcoming && effectiveAt(policy.upcoming) <= now) return { current: policy.upcoming, upcoming: null };
  return policy;
}

/** 현재 판의 "updated" 안내 기간 안인지 (시행일부터 30일) */
function withinUpdatedWindow(current: PolicyVersion, now: Date): boolean {
  const since = now.getTime() - effectiveAt(current).getTime();
  return since >= 0 && since < UPDATED_NOTICE_DAYS * 86_400_000;
}

/**
 * 안내를 정하려면 가입 시각이 필요한지. 시행 예정 판이 있으면 모두에게 알리고,
 * 현재 판 시행 뒤 30일이 지났으면 아무에게도 알리지 않아 필요 없다 (auth 사용자를 읽지 않는다).
 */
export function needsAccountCreatedAt(policy: PrivacyPolicy, now: Date): boolean {
  const { current, upcoming } = policyAt(policy, now);
  return !upcoming && withinUpdatedWindow(current, now);
}

/**
 * 이 계정에 보일 판과 안내 (순수 함수).
 * 시행 예정 판이 있으면 그 안내가 먼저다(지금 있는 계정은 모두 그 시행일 전에 가입했다).
 * 없으면 현재 판의 시행일 전에 가입한 계정만, 시행 뒤 30일 동안 "updated". 가입 시각이 필요 없을 때는 null을 넘긴다(`needsAccountCreatedAt`).
 */
export function privacyPolicyStatus(policy: PrivacyPolicy, accountCreatedAt: Date | null, now: Date): LegalResponse["privacy"] {
  const { current, upcoming } = policyAt(policy, now);
  const notice = upcoming
    ? { ...upcoming, kind: "upcoming" as const }
    : accountCreatedAt && accountCreatedAt < effectiveAt(current) && withinUpdatedWindow(current, now)
      ? { ...current, kind: "updated" as const }
      : null;
  return { current, upcoming, notice };
}
