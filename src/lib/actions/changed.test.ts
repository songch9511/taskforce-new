import { describe, expect, it } from "vitest";

import { changedActionIds, changedSinceSeen, type SeenEvent } from "./changed";

// 바뀜 점 (U1 PR2): 사용자가 마지막으로 본 뒤 AI · 원문 · 실행기가 바꾼 할 일만 바뀜이다. 사용자 자신의 수정은 바뀜이 아니다.

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";

const at = (minute: number) => new Date(Date.UTC(2026, 9, 2, 1, minute)).toISOString();
const ev = (type: string, actor: SeenEvent["actor"], minute: number, action_id = A): SeenEvent => ({ action_id, type, actor, created_at: at(minute) });

describe("changedSinceSeen", () => {
  it.each<[string, SeenEvent[], boolean]>([
    ["AI가 만들기만 함 (새 할 일은 바뀜이 아니다)", [ev("created", "ai", 0)], false],
    ["사용자가 직접 추가하고 고치기만 함", [ev("user_created", "user", 0), ev("user_edited", "user", 5), ev("user_started", "user", 9)], false],
    ["AI가 만든 할 일을 사용자가 고치기만 함", [ev("created", "ai", 0), ev("user_edited", "user", 5)], false],
    ["AI가 원문으로 기한을 바꿈", [ev("created", "ai", 0), ev("due_changed", "ai", 5)], true],
    ["AI가 내용 · 담당을 바꿈", [ev("created", "ai", 0), ev("scope_changed", "ai", 5), ev("owner_changed", "ai", 5)], true],
    ["같은 할 일이 다른 원문에서 다시 언급됨 (merged)", [ev("created", "ai", 0), ev("merged", "ai", 5)], true],
    ["원문의 다시 열림 신호", [ev("created", "ai", 0), ev("completed", "ai", 3), ev("reopened", "ai", 5)], true],
    ["실행 receipt (실행기가 초안을 만듦)", [ev("created", "ai", 0), ev("artifact_created", "agent", 5)], true],
    ["바뀐 뒤 봄", [ev("created", "ai", 0), ev("due_changed", "ai", 5), ev("user_seen", "user", 6)], false],
    ["본 뒤 다시 바뀜", [ev("created", "ai", 0), ev("due_changed", "ai", 5), ev("user_seen", "user", 6), ev("merged", "ai", 8)], true],
    ["바뀐 뒤 사용자가 확인 요청을 확정함 (직접 손댄 것은 본 것)", [ev("created", "ai", 0), ev("owner_changed", "ai", 5), ev("user_confirmed", "user", 7)], false],
    ["사용자가 고친 뒤 AI가 바꿈", [ev("created", "ai", 0), ev("user_edited", "user", 2), ev("due_changed", "ai", 5)], true],
    ["시각이 같은 AI 변경과 사용자 이벤트는 본 것 (앞뒤를 가를 수 없다)", [ev("created", "ai", 0), ev("merged", "ai", 5), ev("user_seen", "user", 5)], false],
    ["사용자 이벤트 1분 뒤의 AI 변경은 바뀜", [ev("created", "ai", 0), ev("user_seen", "user", 5), ev("merged", "ai", 6)], true],
    ["모르는 종류 · 사용자 종류를 AI가 남긴 것은 세지 않는다", [ev("created", "ai", 0), ev("something_new", "ai", 5), ev("user_unstarted", "ai", 6)], false],
    ["이벤트가 없으면 바뀜이 아니다", [], false],
  ])("%s → %s", (_name, events, expected) => {
    expect(changedSinceSeen(events)).toBe(expected);
    // 받은 순서와 상관없다
    expect(changedSinceSeen([...events].reverse())).toBe(expected);
  });

  it("DB 시각(마이크로초 · +00:00)도 그대로 비교한다", () => {
    const events: SeenEvent[] = [
      { action_id: A, type: "due_changed", actor: "ai", created_at: "2026-10-02T01:05:00.123456+00:00" },
      { action_id: A, type: "user_seen", actor: "user", created_at: "2026-10-02T01:05:01.5+00:00" },
    ];
    expect(changedSinceSeen(events)).toBe(false);
    expect(changedSinceSeen([...events, { action_id: A, type: "merged", actor: "ai", created_at: "2026-10-02T01:06:00+00:00" }])).toBe(true);
  });
});

describe("changedActionIds", () => {
  it("할 일마다 따로 판정한다 (다른 할 일의 user_seen은 상관없다)", () => {
    const events = [ev("created", "ai", 0, A), ev("due_changed", "ai", 5, A), ev("created", "ai", 0, B), ev("due_changed", "ai", 5, B), ev("user_seen", "user", 6, B)];
    expect(changedActionIds(events)).toEqual(new Set([A]));
    expect(changedActionIds([])).toEqual(new Set());
  });
});
