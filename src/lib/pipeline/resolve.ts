import type { SourceKind } from "./extract";

// 진실 판정 (docs/TRUTH_RULES.md 2장). Claim(누가 언제 무엇을 말했나)들로부터 Action 필드의 현재 값을 계산한다.
// LLM은 여기 관여하지 않는다. 같은 Claim이면 항상 같은 답이 나오고, 모든 값에 "왜"를 붙인다. Claim은 지우지 않는다.

export type ClaimField = "due" | "scope" | "owner" | "status";

/**
 * 실행 결과 Claim의 필드 (origin `execution`, docs/EXECUTION.md 9장): 값은 산출물 id(`execution_artifacts.id`).
 * 진실 판정은 이 필드를 계산하지 않는다: Action 필드(기한 · 내용 · 담당 · 상태)를 바꾸지 않으므로 초안은 완료가 아니다 (A38).
 */
export type ArtifactField = "artifact";

/** 원문 종류 + 구조화된 할 일(task) */
export type ClaimChannel = SourceKind | "task";

export type Claim = {
  id: string;
  field: ClaimField | ArtifactField;
  /** due: YYYY-MM-DD, owner: "me" | "other" | 이름, status: "open" | "done" | "dropped", scope: 자유 문장, artifact: 산출물 id */
  value: string | null;
  /** 발언 시점 (입력 시점 아님, 규칙 4) */
  occurredAt: Date;
  speakerRole: "me" | "counterpart" | "third_party" | "unknown";
  certainty: "firm" | "tentative";
  directness: "first_hand" | "reported";
  audience: "shared" | "private";
  channel: ClaimChannel;
  state?: "active" | "superseded" | "disputed";
  /**
   * user: 사용자가 앱에서 직접 고친 값. 그 시점까지의 어떤 발언보다 우선한다 (이후의 유효한 발언은 다시 바꿀 수 있다).
   * tracker: 사용자가 할 일 도구(Notion 할 일 DB 등)에서 직접 고친 값. 판정에서는 user와 같고, AI 오판으로 세지 않는다.
   * execution: 실행 결과(receipt). 사용자가 정한 값이 아니다 — 실행을 허락한 것은 값을 정한 것이 아니다 (A55). 지금은 artifact 필드뿐이다.
   */
  origin?: "source" | "user" | "tracker" | "execution";
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

// 규칙 5: 서면 기록(메일 · 문서 · 할 일 DB) > 채팅 > 회의록(음성인식 오류 가능)
const CHANNEL_RANK: Record<ClaimChannel, number> = { email: 3, doc: 3, task: 3, message: 2, note: 2, meeting: 1 };

const byTime = (a: Claim, b: Claim) => a.occurredAt.getTime() - b.occurredAt.getTime();
/** 사용자가 직접 정한 값 (앱 또는 할 일 도구) */
const isUser = (c: Claim) => c.origin === "user" || c.origin === "tracker";
const isUnresolvedSource = (c: Claim) => !isUser(c) && (c.speakerRole === "unknown" || c.state === "disputed");
const isStrong = (c: Claim) =>
  isUser(c) || (!isUnresolvedSource(c) && c.certainty === "firm" && c.directness === "first_hand");

type Authority = "apply" | "needs_confirmation" | "reject";

/** 규칙 0: 이 사람이 이 필드를 이렇게 바꿀 권한이 있는가 */
function authority(field: ClaimField, current: string | null, next: Claim, confirmedBy: Claim[]): Authority {
  if (isUser(next)) return "apply";
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

export const USER_REASON = "사용자가 직접 정함";
export const TRACKER_REASON = "사용자가 할 일 도구에서 정함";

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

  const shared = all.filter((c) => isStrong(c) && (c.audience === "shared" || isUser(c)));
  const privateStrong = all.filter((c) => isStrong(c) && c.audience === "private" && !isUser(c));
  const unresolvedSource = all.filter(isUnresolvedSource);
  const reported = all.filter((c) => !isUnresolvedSource(c) && c.directness === "reported");
  const tentative = all.filter((c) => !isUnresolvedSource(c) && c.certainty === "tentative" && c.directness === "first_hand");

  // 규칙 1: 공유된 확정 발언이 있으면 그것들로 정한다. 없을 때만 내 메모를 쓴다.
  const basis = shared.length > 0 ? shared : privateStrong;
  const result: Resolution = { ...empty, rules: shared.length > 0 ? [] : privateStrong.length > 0 ? [1] : [] };

  if (basis.length === 0) {
    // 적용할 확정 발언이 없다: 가장 최근의 추정 · 전언 · 불명확한 화자를 보여주되 확인을 받는다.
    const latest = [...tentative, ...reported, ...unresolvedSource].sort(byTime).at(-1)!;
    if (isUnresolvedSource(latest)) {
      return {
        ...result,
        value: latest.value,
        winningClaimId: latest.id,
        rules: [0],
        reason: "화자 또는 판정이 불확실해 확인이 필요합니다",
        needsConfirmation: true,
        pending: [latest.id],
      };
    }
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

  // 규칙 0 · 4 · 5: 같은 시각의 Claims는 권한부터 판정하고, 허용된 값끼리 채널을 비교한다.
  let winner = basis[0];
  let hasWinner = false;
  const rules = new Set<RuleId>(result.rules);
  for (let start = 0; start < basis.length; ) {
    let end = start + 1;
    while (end < basis.length && basis[end].occurredAt.getTime() === basis[start].occurredAt.getTime()) end++;
    const group = basis.slice(start, end);
    if (
      !hasWinner &&
      field === "status" &&
      group.some((c) => c.value === "done" || c.value === "dropped") &&
      group.every((c) => authority(field, null, c, group) !== "apply")
    ) {
      rules.add(0);
      result.pending.push(...group.map((c) => c.id));
      start = end;
      continue;
    }
    if (hasWinner && group.every((c) => c.value === winner.value) && !group.some(isUser)) {
      start = end;
      continue;
    }

    const distinct = new Set(group.map((c) => c.value));
    if (hasWinner) distinct.add(winner.value);
    if (distinct.size === 1) {
      if (!hasWinner || group.some(isUser)) winner = group.find(isUser) ?? group[0];
      hasWinner = true;
      start = end;
      continue;
    }

    const before = hasWinner ? winner : null;
    const confirmedBy = [...basis.slice(0, start), ...group];
    const allowed: Claim[] = [];
    for (const next of group) {
      if (before && next.value === before.value && !isUser(next)) continue;
      const decision = authority(field, before?.value ?? null, next, confirmedBy);
      if (decision === "apply") allowed.push(next);
      else {
        rules.add(0);
        if (decision === "needs_confirmation") result.pending.push(next.id);
        else result.risks.push({ kind: "unauthorized_change", claimId: next.id, value: next.value });
      }
    }

    if (allowed.length > 0) {
      const userClaims = allowed.filter(isUser);
      const eligible = userClaims.length > 0 ? userClaims : allowed;
      const ranks = eligible.map((c) => CHANNEL_RANK[c.channel]);
      const maxRank = Math.max(...ranks);
      const top = eligible.filter((c) => CHANNEL_RANK[c.channel] === maxRank);
      const topValues = new Set(top.map((c) => c.value));
      const chosen = top[0];

      if (new Set(eligible.map((c) => c.value)).size > 1 && new Set(ranks).size > 1) rules.add(5);
      if (topValues.size > 1) {
        rules.add(6);
        result.pending.push(...top.map((c) => c.id));
      }
      if (before && before.value !== chosen.value && !isUser(chosen)) rules.add(0).add(4);
      if (before && before.value !== chosen.value) result.superseded.push(before.id);
      for (const c of eligible) {
        if (c.value !== chosen.value && CHANNEL_RANK[c.channel] < maxRank) result.superseded.push(c.id);
      }
      winner = chosen;
      hasWinner = true;
    } else if (!hasWinner) {
      // 확인 대기 중에도 기존 표시값을 유지한다.
      winner = group[0];
      hasWinner = true;
    }
    start = end;
  }

  if (!hasWinner) {
    const pending = [...new Set(result.pending)];
    const finalRules = [...rules].sort((a, b) => a - b);
    return {
      ...result,
      value: null,
      winningClaimId: null,
      rules: finalRules,
      reason: `규칙 ${finalRules.join(" + ")}: ${finalRules.map((r) => RULE_TEXT[r]).join(", ")}`,
      needsConfirmation: pending.length > 0,
      pending,
    };
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
  for (const c of unresolvedSource) {
    if (c.value !== winner.value && c.occurredAt >= winner.occurredAt) {
      rules.add(0);
      result.pending.push(c.id);
      result.needsConfirmation = true;
    }
  }

  // 확인 대기였던 발언이 나중에 같은 값으로 확정됐다면 더 이상 물을 필요가 없다. (규칙 6 동점은 그대로 묻는다)
  const valueOf = (id: string) => all.find((c) => c.id === id)?.value;
  // 사용자가 그 뒤에 직접 정했거나 확인했으면(사용자 Claim) 그 전의 확인 대기는 더 묻지 않는다.
  const lastUserAt = Math.max(-Infinity, ...all.filter(isUser).map((c) => c.occurredAt.getTime()));
  const occurredOf = (id: string) => all.find((c) => c.id === id)!.occurredAt.getTime();
  const stillPending = [...new Set(result.pending)].filter(
    (id) => occurredOf(id) > lastUserAt && (rules.has(6) || valueOf(id) !== winner.value),
  );
  const finalRules = [...rules].sort((a, b) => a - b);
  const reason = isUser(winner)
    ? winner.origin === "tracker"
      ? TRACKER_REASON
      : USER_REASON
    : finalRules.length
      ? `규칙 ${finalRules.join(" + ")}: ${finalRules.map((r) => RULE_TEXT[r]).join(", ")}`
      : "처음 합의된 값";
  return {
    ...result,
    value: winner.value,
    winningClaimId: winner.id,
    rules: finalRules,
    reason,
    pending: stillPending,
    needsConfirmation: stillPending.length > 0,
  };
}

export type ActionState = Record<ClaimField, Resolution>;

/** Action 필드마다 판정한다. 실행 결과 Claim(field artifact)은 어느 필드에도 들지 않아 값 · 확인 · 위험 신호에 영향이 없다 */
export function resolveAction(claims: Claim[]): ActionState {
  return {
    due: resolveField("due", claims),
    scope: resolveField("scope", claims),
    owner: resolveField("owner", claims),
    status: resolveField("status", claims),
  };
}
