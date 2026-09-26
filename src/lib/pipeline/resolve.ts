import type { SourceKind } from "./extract";

// 진실 판정 (docs/TRUTH_RULES.md 2장). Claim(누가 언제 무엇을 말했나)들로부터 Action 필드의 현재 값을 계산한다.
// LLM은 여기 관여하지 않는다. 같은 Claim이면 항상 같은 답이 나오고, 모든 값에 "왜"를 붙인다. Claim은 지우지 않는다.

export type ClaimField = "due" | "scope" | "owner" | "status";

export type Claim = {
  id: string;
  field: ClaimField;
  /** due: YYYY-MM-DD, owner: "me" | "other" | 이름, status: "open" | "done" | "dropped", scope: 자유 문장 */
  value: string | null;
  /** 발언 시점 (입력 시점 아님, 규칙 4) */
  occurredAt: Date;
  speakerRole: "me" | "counterpart" | "third_party";
  certainty: "firm" | "tentative";
  directness: "first_hand" | "reported";
  audience: "shared" | "private";
  channel: SourceKind;
};

/** 규칙 번호 (TRUTH_RULES 2장) */
export type RuleId = 0 | 1 | 2 | 3 | 4 | 5 | 6;

export type Risk =
  /** 규칙 1: 내 메모와 상대에게 한 말이 다름 ("상대는 금요일로 알고 있음") */
  | { kind: "private_differs"; claimId: string; value: string | null }
  /** 규칙 2: 확정되지 않은 변경 가능성 ("기한 변경 가능성") */
  | { kind: "tentative_change"; claimId: string; value: string | null }
  /** 규칙 0: 결정권 없는 쪽의 변경 (예: 내가 혼자 기한을 늦춤) */
  | { kind: "unauthorized_change"; claimId: string; value: string | null };

export type Resolution = {
  field: ClaimField;
  value: string | null;
  winningClaimId: string | null;
  /** 이 값을 정하는 데 쓴 규칙 */
  rules: RuleId[];
  /** 사용자에게 보여줄 판정 이유 */
  reason: string;
  /** 규칙 3 · 6 등으로 사람이 골라야 함 */
  needsConfirmation: boolean;
  /** 확인이 필요한 Claim (전언 · 결정권 없는 변경 · 동점) */
  pending: string[];
  /** 더 새로운 유효한 Claim에 밀린 Claim */
  superseded: string[];
  risks: Risk[];
};

// 규칙 5: 서면 확인 > 채팅 > 회의록(음성인식 오류 가능)
const CHANNEL_RANK: Record<SourceKind, number> = { email: 3, doc: 3, message: 2, note: 2, meeting: 1 };

const byTime = (a: Claim, b: Claim) => a.occurredAt.getTime() - b.occurredAt.getTime();
const isStrong = (c: Claim) => c.certainty === "firm" && c.directness === "first_hand";

type Authority = "apply" | "needs_confirmation" | "reject";

/** 규칙 0: 이 사람이 이 필드를 이렇게 바꿀 권한이 있는가 */
function authority(field: ClaimField, current: string | null, next: Claim, confirmedBy: Claim[]): Authority {
  if (next.speakerRole === "third_party") return "needs_confirmation";
  switch (field) {
    case "due": {
      if (current === null || next.value === null) return "apply";
      // 기한을 당기는 건 누구나(스스로 부담을 늘림), 늦추는 건 요청한 쪽만
      if (next.value < current) return "apply";
      return next.speakerRole === "counterpart" ? "apply" : "reject";
    }
    case "scope":
      // 범위가 늘었는지 줄었는지는 글만으로 알 수 없어, 내가 바꾼 범위는 확인을 받는다.
      return next.speakerRole === "counterpart" ? "apply" : "needs_confirmation";
    case "owner": {
      // 넘기는 사람과 받는 사람 모두 확인되어야 확정: 양쪽이 같은 값을 말했으면 적용
      const roles = new Set([next, ...confirmedBy].filter((c) => c.value === next.value).map((c) => c.speakerRole));
      return roles.has("me") && roles.has("counterpart") ? "apply" : "needs_confirmation";
    }
    case "status":
      // 완료는 전달이 원문으로 확인될 때(누구의 말이든 직접 발언), 취소는 요청한 쪽이
      if (next.value === "done" || next.value === "open") return "apply";
      return next.speakerRole === "counterpart" ? "apply" : "needs_confirmation";
  }
}

const RULE_TEXT: Record<RuleId, string> = {
  0: "결정권",
  1: "공유된 약속 우선",
  2: "확정 발언 우선",
  3: "직접 발언 우선",
  4: "나중 발언 우선",
  5: "서면 채널 우선",
  6: "판단 불가",
};

export function resolveField(field: ClaimField, claims: Claim[]): Resolution {
  const all = claims.filter((c) => c.field === field).sort(byTime);
  const empty: Resolution = {
    field,
    value: null,
    winningClaimId: null,
    rules: [],
    reason: "근거 없음",
    needsConfirmation: false,
    pending: [],
    superseded: [],
    risks: [],
  };
  if (all.length === 0) return empty;

  const shared = all.filter((c) => isStrong(c) && c.audience === "shared");
  const privateStrong = all.filter((c) => isStrong(c) && c.audience === "private");
  const reported = all.filter((c) => c.directness === "reported");
  const tentative = all.filter((c) => c.certainty === "tentative" && c.directness === "first_hand");

  // 규칙 1: 공유된 확정 발언이 있으면 그것들로 정한다. 없을 때만 내 메모를 쓴다.
  const basis = shared.length > 0 ? shared : privateStrong;
  const result: Resolution = { ...empty, rules: shared.length > 0 ? [] : privateStrong.length > 0 ? [1] : [] };

  if (basis.length === 0) {
    // 확정 · 직접 발언이 하나도 없다: 가장 최근의 추정 · 전언을 보여주되 확인을 받는다 (규칙 2 · 3).
    const latest = [...tentative, ...reported].sort(byTime).at(-1)!;
    return {
      ...result,
      value: latest.value,
      winningClaimId: latest.id,
      rules: [latest.directness === "reported" ? 3 : 2],
      reason: latest.directness === "reported" ? "전해 들은 말뿐이라 확인이 필요합니다" : "확정되지 않은 말뿐이라 확인이 필요합니다",
      needsConfirmation: true,
      pending: [latest.id],
    };
  }

  // 규칙 0 · 4 · 5: 시간순으로 유효한 변경만 적용한다.
  let winner = basis[0];
  const rules = new Set<RuleId>(result.rules);
  for (let i = 1; i < basis.length; i++) {
    const next = basis[i];
    if (next.value === winner.value) continue;

    // 규칙 5 · 6: 같은 시점에 다른 값
    if (next.occurredAt.getTime() === winner.occurredAt.getTime()) {
      const diff = CHANNEL_RANK[next.channel] - CHANNEL_RANK[winner.channel];
      if (diff === 0) {
        rules.add(6);
        result.pending.push(winner.id, next.id);
        result.needsConfirmation = true;
        continue;
      }
      rules.add(5);
      if (diff > 0) {
        result.superseded.push(winner.id);
        winner = next;
      } else {
        result.superseded.push(next.id);
      }
      continue;
    }

    // 앞서 확인 대기로 둔 발언도 "양쪽이 말했는가"를 볼 때는 센다.
    const decision = authority(field, winner.value, next, basis.slice(0, i));
    if (decision === "apply") {
      rules.add(0).add(4);
      result.superseded.push(winner.id);
      winner = next;
    } else if (decision === "needs_confirmation") {
      rules.add(0);
      result.pending.push(next.id);
      result.needsConfirmation = true;
    } else {
      rules.add(0);
      result.risks.push({ kind: "unauthorized_change", claimId: next.id, value: next.value });
    }
  }

  // 규칙 1 · 2 · 3: 반영하지 않은 발언 중 값이 다른 것은 위험 신호 · 확인으로 남긴다.
  if (basis === shared) {
    for (const c of privateStrong) {
      if (c.value !== winner.value) {
        rules.add(1);
        result.risks.push({ kind: "private_differs", claimId: c.id, value: c.value });
      }
    }
  }
  for (const c of tentative) {
    if (c.value !== winner.value && c.occurredAt >= winner.occurredAt) {
      rules.add(2);
      result.risks.push({ kind: "tentative_change", claimId: c.id, value: c.value });
    }
  }
  for (const c of reported) {
    if (c.value !== winner.value && c.occurredAt >= winner.occurredAt) {
      rules.add(3);
      result.pending.push(c.id);
      result.needsConfirmation = true;
    }
  }

  // 확인 대기였던 발언이 나중에 같은 값으로 확정됐다면 더 이상 물을 필요가 없다. (규칙 6 동점은 그대로 묻는다)
  const valueOf = (id: string) => all.find((c) => c.id === id)?.value;
  const stillPending = [...new Set(result.pending)].filter((id) => rules.has(6) || valueOf(id) !== winner.value);
  const finalRules = [...rules].sort((a, b) => a - b);
  return {
    ...result,
    value: winner.value,
    winningClaimId: winner.id,
    rules: finalRules,
    reason: finalRules.length ? `규칙 ${finalRules.join(" + ")}: ${finalRules.map((r) => RULE_TEXT[r]).join(", ")}` : "처음 합의된 값",
    pending: stillPending,
    needsConfirmation: stillPending.length > 0,
  };
}

export type ActionState = Record<ClaimField, Resolution>;

export function resolveAction(claims: Claim[]): ActionState {
  return {
    due: resolveField("due", claims),
    scope: resolveField("scope", claims),
    owner: resolveField("owner", claims),
    status: resolveField("status", claims),
  };
}
