import { describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

import {
  pendingDecisionKindSchema,
  returnSummaryChangeSchema,
  returnSummaryItemSchema,
  returnSummaryResponseSchema,
  reviewResponseSchema,
  suggestionKindSchema,
  suggestionSchema,
  suggestionSnoozeRequestSchema,
} from "@/lib/api/contract";
import { PENDING_KINDS } from "@/lib/coordinator/pending";

import { suggestionDto } from "./dto";

// C3 JSON 계약의 서버 쪽 고정점 (Mac이 같은 JSON을 읽는다 — 한쪽을 고치면 notes의 "Mac에 넘기는 JSON 계약"도 고친다).

describe("C3 계약 일치", () => {
  it("결정 대기 종류는 C2 pending.ts와 같다 (순서까지)", () => {
    expect([...pendingDecisionKindSchema.options]).toEqual([...PENDING_KINDS]);
  });

  it("제안 종류는 마이그레이션이 만드는 세 가지뿐이다 (모르는 종류는 지어 보이지 않고 건너뛴다)", () => {
    expect([...suggestionKindSchema.options]).toEqual(["due_window", "run_failed", "source_revised_run"]);
    expect(suggestionDto({ id: "a5555555-5555-4555-8555-555555555555", kind: "from_the_future", action_id: "a6666666-6666-4666-8666-666666666666", state: "open", version: 1, urgent: false })).toBeNull();
  });

  it("변화 토큰은 이름 모양(소문자 · 숫자 · _)만, 시각은 마이크로초 UTC 글자만 받는다", () => {
    const good = { source: "action_event", kind: "due_changed", at: "2026-10-12T00:00:00.000123Z", detail: null, source_state: "available" };
    expect(returnSummaryChangeSchema.parse(good)).toEqual(good);
    for (const bad of [{ kind: "Due Changed" }, { kind: "한글" }, { at: "2026-10-12T00:00:00Z" }, { at: "2026-10-12T00:00:00.000123+00:00" }, { source: "inbox_event" }, { source_state: "gone" }]) {
      expect(returnSummaryChangeSchema.safeParse({ ...good, ...bad }).success, JSON.stringify(bad)).toBe(false);
    }
  });

  it("제안 snooze 요청: 시각은 오프셋이 있는 ISO만 (모호한 현지 시각은 받지 않는다), 알 수 없는 필드 거절", () => {
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00+09:00" }).success).toBe(true);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00Z" }).success).toBe(true);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00" }).success).toBe(false);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13" }).success).toBe(false);
    expect(suggestionSnoozeRequestSchema.safeParse({ expected_version: 1, snooze_until: "2026-10-13T09:00:00Z", extra: true }).success).toBe(false);
  });

  it("응답 모양의 필수 키 (Mac 디코딩 기준)", () => {
    expect(Object.keys(reviewResponseSchema.shape).sort()).toEqual(["complete", "decisions", "empty", "generated_at", "sources", "suggestion_batch", "suggestions"]);
    expect(Object.keys(returnSummaryResponseSchema.shape).sort()).toEqual(["baseline", "complete", "cursor", "empty", "generated_at", "init_token", "items", "since", "sources"]);
    expect(Object.keys(returnSummaryItemSchema.shape).sort()).toEqual(["action_id", "changes", "decisions", "needs_answer", "next", "state", "status", "title", "urgent", "version"]);
    expect(Object.keys(suggestionSchema.shape).sort()).toEqual(["action_id", "created_at", "id", "kind", "offered_on", "run_id", "shown_at", "snooze_until", "state", "urgent", "version"]);
  });
});
