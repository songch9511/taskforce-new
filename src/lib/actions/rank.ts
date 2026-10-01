// "지금 할 일" 순서 (순수 함수). 앱은 이 순서를 그대로 보여준다.
// 점수 = 기한 임박 + 외부 약속(상대가 있는 일) + 방치 기간. 확인 요청은 별도 목록으로 뺀다.

export type RankInput = {
  id: string;
  title: string;
  owner: "me" | "other" | "unknown";
  status: "open" | "done" | "dropped";
  due_date: string | null;
  counterpart: string | null;
  needs_confirmation: boolean;
  started_at: string | null;
  last_activity_at: string;
};

/** Review 목록과 확인 요청 알림이 함께 쓰는 표시 조건. */
export function isConfirmationEligible(action: Pick<RankInput, "status" | "owner" | "needs_confirmation">): boolean {
  return action.status === "open" && action.owner !== "other" && action.needs_confirmation;
}

export type RankReason = "overdue" | "due_today" | "due_soon" | "external" | "neglected" | "started";

export type RankedAction<T extends RankInput = RankInput> = T & { score: number; reasons: RankReason[]; days_until_due: number | null };

const DAY = 86_400_000;

function kstToday(now: Date): number {
  const kst = new Date(now.getTime() + 9 * 3_600_000);
  return Date.UTC(kst.getUTCFullYear(), kst.getUTCMonth(), kst.getUTCDate());
}

export function daysUntil(dueDate: string, now: Date): number {
  return Math.round((Date.parse(`${dueDate}T00:00:00Z`) - kstToday(now)) / DAY);
}

export function scoreAction<T extends RankInput>(action: T, now: Date): RankedAction<T> {
  const reasons: RankReason[] = [];
  let score = 0;

  const days = action.due_date ? daysUntil(action.due_date, now) : null;
  if (days !== null) {
    if (days < 0) {
      score += 100 + Math.min(-days, 14) * 5;
      reasons.push("overdue");
    } else if (days === 0) {
      score += 90;
      reasons.push("due_today");
    } else if (days <= 3) {
      score += 70 - days * 10;
      reasons.push("due_soon");
    } else {
      score += Math.max(0, 30 - days * 2);
    }
  }

  // 상대가 기다리는 약속은 내 일보다 먼저
  if (action.counterpart) {
    score += 20;
    reasons.push("external");
  }

  // 오래 손대지 않은 일 (기한이 없을수록 잊히기 쉽다)
  const idleDays = Math.floor((now.getTime() - Date.parse(action.last_activity_at)) / DAY);
  if (idleDays >= 3) {
    score += Math.min(idleDays, 14) * (days === null ? 3 : 1.5);
    reasons.push("neglected");
  }

  // 이미 시작한 일은 이어서 하도록 조금 올린다
  if (action.started_at) {
    score += 10;
    reasons.push("started");
  }

  return { ...action, score, reasons, days_until_due: days };
}

/** 열린 내 일 중 확인이 끝난 것을 점수순으로, 확인 요청은 따로 (오래된 것부터) */
export function rankNow<T extends RankInput>(actions: T[], now: Date): { now: RankedAction<T>[]; confirmations: RankedAction<T>[] } {
  const open = actions.filter((a) => a.status === "open" && a.owner !== "other").map((a) => scoreAction(a, now));
  const byScore = (a: RankedAction<T>, b: RankedAction<T>) => b.score - a.score || (a.due_date ?? "9999").localeCompare(b.due_date ?? "9999");
  return {
    now: open.filter((a) => !a.needs_confirmation).sort(byScore),
    confirmations: open.filter(isConfirmationEligible).sort((a, b) => a.last_activity_at.localeCompare(b.last_activity_at)),
  };
}
