import type { LegalResponse, PolicyNotice, PolicyVersion } from "@/lib/api/contract";

// 개인정보 처리방침의 판 · 시행일 (한 곳). 앱은 GET /api/v1/legal로 받아 변경 안내를 보인다 (처리방침 17장: 앱과 페이지에 알린다).
// 처리방침을 바꿀 때 여기 버전 · 시행일을 함께 바꾼다 (docs/go-live/runbook.md 7장 8번).
// - 기본 (go live 뒤의 모든 실질 변경): upcoming에 새 판을 둔다 → 모든 계정에 "Privacy Policy changes <날짜>".
//   17장의 약속대로 시행 7일 전부터, 수집 항목 · 목적 · 받는 곳이 늘어나는 변경은 30일 전부터 둔다.
//   upcoming.url은 그 판의 버전 주소(`/{lang}/privacy/{version}`)여야 한다: 알리는 동안 `/{lang}/privacy`는 아직 현재 판이다.
//   시행일이 지나면 배포 없이 현재 판이 된다(policyAt). 다음에 고칠 때 current로 옮기고 upcoming을 비운다.
// - 판이 둘 이상 쌓일 때 (docs/legal/README.md 게시 규칙 6, 예: 1.6을 먼저 게시하고 그 위에 1.7): upcoming에 배열로 둔다.
//   배열은 **판 순서**(먼저 게시할 판이 앞)로 쓰고, 항목마다 고지 시작일 `notice_from`(한국 날짜)을 적는다. 30일 고지가 겹쳐 돈다:
//   각 판의 시행일 ≥ 자기 고지 시작일 + 30일, 그리고 앞 판의 시행일 이후. 이 규칙은 validatePrivacyPolicy가 읽고 policy.test.ts가 PRIVACY_POLICY에 건다.
//   응답(GET /api/v1/legal)의 모양은 그대로다: `upcoming` · `notice`는 **먼저 시행될 판** 하나이고, 그 판이 시행되면 다음 판으로 넘어간다.
//   둘을 한꺼번에 보이려면 privacyNotices(전부, 시행 순서)를 응답 계약(`legalResponseSchema`)에 더하고 앱이 읽어야 한다: 그 전에는 둘째 판의 앱 안 안내가
//   첫째 판이 시행된 뒤에야 나온다(웹 페이지의 안내는 처음부터 둘 다).
// - current만 바꾸기 (게시와 함께 시행, 알림은 시행 뒤): 처리 내용이 바뀌지 않는 고침(오탈자 · 문장 다듬기 · 연락처)이거나
//   계정이 운영자 것뿐일 때만 (베타 1.1 · 1.2 · 1.3 · 1.4가 그랬다, docs/legal/README.md 게시 기록). 그 전에 가입한 계정에 30일 동안 "Privacy Policy updated".

/**
 * 시행 예정 판. `notice_from`(알리기 시작하는 한국 날짜 YYYY-MM-DD)과 `notice_days`(기본 30)는 이 파일의 규칙 검사용이고 응답에 싣지 않는다.
 * 옛 모양(`notice_from` 없음)도 받는다: 동작은 같고 validatePrivacyPolicy만 고지 시작일이 없다고 알린다.
 */
export type UpcomingPolicy = PolicyVersion & { notice_from?: string; notice_days?: number };

/** upcoming: 없음 · 하나 · 판 순서의 배열 (옛 모양 `PolicyVersion | null`과 호환) */
export type PrivacyPolicy = { current: PolicyVersion; upcoming: UpcomingPolicy | readonly UpcomingPolicy[] | null };

const PRIVACY_URL = { ko: "https://www.taskforcelabs.dev/ko/privacy", en: "https://www.taskforcelabs.dev/en/privacy" };

export const PRIVACY_POLICY: PrivacyPolicy = {
  current: { version: "beta-1.5", effective_date: "2026-10-07", url: PRIVACY_URL },
  upcoming: null,
};

/** 시행된 판의 "updated" 안내를 보이는 기간. 몇 달 뒤 처음 앱을 연 옛 계정에 지난 안내를 보이지 않는다 */
export const UPDATED_NOTICE_DAYS = 30;

/** 수집 항목 · 목적 · 받는 곳이 늘어나는 변경의 고지 기간 (처리방침 17장). 항목에 notice_days가 없으면 이 값을 쓴다 */
export const UPCOMING_NOTICE_DAYS = 30;
/** 그 밖의 변경의 고지 기간 (처리방침 17장: 시행 7일 전부터). notice_days의 하한 */
export const MIN_NOTICE_DAYS = 7;

/** 시행일은 한국 시간 그날 0시부터 */
export function effectiveAt(version: PolicyVersion): Date {
  return new Date(`${version.effective_date}T00:00:00+09:00`);
}

/** 응답에 싣는 모양: 계약의 판 (규칙 검사용 열은 뺀다) */
function publicVersion(version: UpcomingPolicy): PolicyVersion {
  return { version: version.version, effective_date: version.effective_date, url: version.url };
}

function asList(upcoming: PrivacyPolicy["upcoming"]): UpcomingPolicy[] {
  if (upcoming === null) return [];
  return Array.isArray(upcoming) ? [...(upcoming as readonly UpcomingPolicy[])] : [upcoming as UpcomingPolicy];
}

/** 시행 예정 판을 시행 순서로 (같은 날이면 쓴 순서). 판 순서로 쓰면 그대로다 */
function upcomingInOrder(policy: PrivacyPolicy): UpcomingPolicy[] {
  return asList(policy.upcoming)
    .map((version, index) => ({ version, index }))
    .sort((a, b) => effectiveAt(a.version).getTime() - effectiveAt(b.version).getTime() || a.index - b.index)
    .map(({ version }) => version);
}

/**
 * 이 시각의 판: 시행일이 지난 시행 예정 판은 현재 판이 된다 (여럿이면 시행 순서대로 마지막 것이 현재 판).
 * 남은 시행 예정 판이 없으면 null, 하나면 그 판, 둘 이상이면 시행 순서의 배열
 */
export function policyAt(policy: PrivacyPolicy, now: Date): PrivacyPolicy {
  const list = upcomingInOrder(policy);
  let current = policy.current;
  let taken = 0;
  while (taken < list.length && effectiveAt(list[taken]) <= now) {
    current = publicVersion(list[taken]);
    taken += 1;
  }
  const rest = list.slice(taken);
  if (rest.length === 0) return { current, upcoming: null };
  return { current, upcoming: rest.length === 1 ? rest[0] : rest };
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

function updatedNotice(current: PolicyVersion, accountCreatedAt: Date | null, now: Date): PolicyNotice | null {
  return accountCreatedAt && accountCreatedAt < effectiveAt(current) && withinUpdatedWindow(current, now) ? { ...current, kind: "updated" } : null;
}

/**
 * 이 계정에 보일 판과 안내 (순수 함수, 응답 모양은 시행 예정 판이 하나였을 때와 같다).
 * 시행 예정 판이 있으면 그 안내가 먼저다(지금 있는 계정은 모두 그 시행일 전에 가입했다): 여럿이면 **먼저 시행될 판**의 안내이고 `upcoming`도 그 판이다.
 * 없으면 현재 판의 시행일 전에 가입한 계정만, 시행 뒤 30일 동안 "updated". 가입 시각이 필요 없을 때는 null을 넘긴다(`needsAccountCreatedAt`).
 */
export function privacyPolicyStatus(policy: PrivacyPolicy, accountCreatedAt: Date | null, now: Date): LegalResponse["privacy"] {
  const { current, upcoming } = policyAt(policy, now);
  const first = asList(upcoming)[0];
  const next = first ? publicVersion(first) : null;
  const notice: PolicyNotice | null = next ? { ...next, kind: "upcoming" } : updatedNotice(current, accountCreatedAt, now);
  return { current, upcoming: next, notice };
}

/**
 * 이 계정에 보일 안내 전부 (시행 순서). 시행 예정 판이 여럿이면 모두 "upcoming"으로 돌려주고, 없으면 "updated" 하나 또는 빈 배열.
 * 응답 계약이 이 목록을 싣게 되면 앱이 둘 다 보인다 (privacyPolicyStatus의 `notice`는 이 목록의 첫째).
 */
export function privacyNotices(policy: PrivacyPolicy, accountCreatedAt: Date | null, now: Date): PolicyNotice[] {
  const { current, upcoming } = policyAt(policy, now);
  const pending = asList(upcoming);
  if (pending.length > 0) return pending.map((version) => ({ ...publicVersion(version), kind: "upcoming" as const }));
  const updated = updatedNotice(current, accountCreatedAt, now);
  return updated ? [updated] : [];
}

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function isIsoDate(value: string | undefined): value is string {
  return typeof value === "string" && ISO_DATE.test(value) && new Date(`${value}T00:00:00Z`).toISOString().startsWith(value);
}

function addDays(date: string, days: number): string {
  return new Date(new Date(`${date}T00:00:00Z`).getTime() + days * 86_400_000).toISOString().slice(0, 10);
}

/**
 * 시행 예정 판의 규칙 검사. 어긋나는 곳을 글로 돌려준다 (빈 배열이면 통과). 요청 처리에서는 부르지 않는다 — 잘못 둔 판이 안내를 막지 않게 —
 * policy.test.ts가 PRIVACY_POLICY에 걸어 CI에서 잡는다. 규칙은 판 순서(배열 순서)로 본다:
 * 판 이름은 겹치지 않고, 시행일은 현재 판 이후이며 앞 판의 시행일 이후(같은 날은 허용), 고지 시작일이 있고 시행일 ≥ 고지 시작일 + 고지 기간(기본 30일, 하한 7일).
 */
export function validatePrivacyPolicy(policy: PrivacyPolicy): string[] {
  const problems: string[] = [];
  const names = new Set([policy.current.version]);
  const list = asList(policy.upcoming);
  list.forEach((entry, index) => {
    const name = entry.version;
    if (names.has(name)) problems.push(`${name}: 판 이름이 다른 판과 겹친다`);
    names.add(name);
    if (!isIsoDate(entry.effective_date)) {
      problems.push(`${name}: 시행일 ${entry.effective_date}이 YYYY-MM-DD가 아니다`);
      return;
    }
    if (entry.effective_date <= policy.current.effective_date) {
      problems.push(`${name}: 시행일 ${entry.effective_date}이 현재 판 ${policy.current.version}의 시행일 ${policy.current.effective_date} 이후가 아니다`);
    }
    const before = index > 0 ? list[index - 1] : null;
    if (before && entry.effective_date < before.effective_date) {
      problems.push(`${name}: 시행일 ${entry.effective_date}이 앞 판 ${before.version}의 시행일 ${before.effective_date}보다 이르다`);
    }
    const days = entry.notice_days ?? UPCOMING_NOTICE_DAYS;
    const daysOk = Number.isInteger(days) && days >= MIN_NOTICE_DAYS;
    if (!daysOk) problems.push(`${name}: 고지 기간 notice_days ${days}는 ${MIN_NOTICE_DAYS}일 이상의 정수여야 한다`);
    if (!isIsoDate(entry.notice_from)) {
      problems.push(`${name}: 고지 시작일 notice_from이 없거나 YYYY-MM-DD가 아니다`);
    } else if (daysOk && entry.effective_date < addDays(entry.notice_from, days)) {
      problems.push(`${name}: 시행일 ${entry.effective_date}이 고지 시작일 ${entry.notice_from} + ${days}일(${addDays(entry.notice_from, days)})보다 이르다`);
    }
  });
  return problems;
}
