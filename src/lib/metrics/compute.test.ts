import { describe, expect, it } from "vitest";

import {
  connections,
  discoveryCost,
  execution,
  gmailFiltering,
  googleActivity,
  kstWeek,
  meetingLinkage,
  metricActivity,
  missed,
  misjudgment,
  retention,
  shadowList,
  sourceFailures,
  timeToStart,
  type ActionEventRow,
  type ExecutionRows,
  type MetricEventRow,
  type WeeklyCheckRow,
} from "./compute";

const period = { from: new Date("2026-09-21T00:00:00Z"), to: new Date("2026-09-28T00:00:00Z") };

const ev = (actionId: string, type: string, at: string, over: Partial<ActionEventRow> = {}): ActionEventRow => ({
  actionId,
  userId: "u1",
  type,
  actor: type.startsWith("user_") ? "user" : "ai",
  before: null,
  after: null,
  at,
  sourceKind: type.startsWith("user_") ? null : "meeting",
  hasSource: !type.startsWith("user_"),
  ...over,
});
const created = (id: string, at = "2026-09-22T01:00:00Z", kind = "meeting") => ev(id, "created", at, { sourceKind: kind });

describe("misjudgment (지표 1)", () => {
  it("AI가 만든 Action 중 사용자가 고치거나 지운 비율, 필드별", () => {
    const m = misjudgment(
      [
        created("a"),
        ev("a", "user_edited", "2026-09-23T00:00:00Z", { before: { due: "2026-09-26" }, after: { due: "2026-09-29" } }),
        created("b"),
        ev("b", "user_deleted", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "dropped" } }),
        created("c"),
        created("d"),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 4, corrected: 2, rate: 0.5 });
    expect(m.byField).toMatchObject({ due: 1, deleted: 1, title: 0 });
  });

  it("메모 저장은 필드 수정을 뜻하지 않아 오판 지표에 넣지 않는다", () => {
    const m = misjudgment(
      [created("notes"), ev("notes", "user_notes_updated", "2026-09-23T00:00:00Z", { before: { revision: 0 }, after: { revision: 1 } })],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 1, corrected: 0, rate: 0 });
    expect(m.byField).toEqual({ title: 0, due: 0, owner: 0, status: 0, deleted: 0 });
  });

  it("끝낸 일을 지운 것 · 지운 뒤 되살린 것(되돌리기)은 삭제 오판으로 세지 않는다", () => {
    const m = misjudgment(
      [
        created("done-cleanup"),
        ev("done-cleanup", "user_deleted", "2026-09-23T00:00:00Z", { before: { status: "done" }, after: { status: "dropped" } }),
        created("undone"),
        ev("undone", "user_deleted", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "dropped" } }),
        ev("undone", "user_edited", "2026-09-23T00:00:04Z", { before: { status: "dropped" }, after: { status: "open" } }),
        created("gone"),
        ev("gone", "user_deleted", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "dropped" } }),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 3, corrected: 1 });
    expect(m.byField).toMatchObject({ deleted: 1, status: 0 });
  });

  it("완료로 바꾼 것 · 자기가 완료한 것을 되돌린 것은 오판이 아니다. AI가 끝냈다고 본 일을 다시 여는 것은 오판이다", () => {
    const m = misjudgment(
      [
        created("done"),
        ev("done", "user_edited", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
        ev("done", "user_edited", "2026-09-23T01:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
        created("reopen"),
        ev("reopen", "completed", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
        ev("reopen", "user_edited", "2026-09-24T00:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 2, corrected: 1, byField: { status: 1 }, byStage: { extract: 0, update: 1 } });
  });

  it("단계: 처음 만들 때 정한 값을 고치면 추출, 나중 원문으로 바뀐 값을 고치면 매칭 · 갱신", () => {
    const m = misjudgment(
      [
        created("x"),
        ev("x", "user_edited", "2026-09-23T00:00:00Z", { before: { title: "a" }, after: { title: "b" } }),
        created("y"),
        ev("y", "due_changed", "2026-09-23T00:00:00Z", { before: { due: "2026-09-26" }, after: { due: "2026-09-29" } }),
        ev("y", "user_edited", "2026-09-24T00:00:00Z", { before: { due: "2026-09-29" }, after: { due: "2026-09-26" } }),
      ],
      period,
    );
    expect(m.byStage).toEqual({ extract: 1, update: 1 });
  });

  it("할 일 DB에서 가져온 것 · 기간 밖에 만든 것은 세지 않고, 확인은 오판이 아니다", () => {
    const m = misjudgment(
      [
        created("t", "2026-09-22T01:00:00Z", "task"),
        ev("t", "user_deleted", "2026-09-23T00:00:00Z"),
        created("old", "2026-09-01T00:00:00Z"),
        ev("old", "user_deleted", "2026-09-23T00:00:00Z"),
        created("ok"),
        ev("ok", "user_confirmed", "2026-09-23T00:00:00Z"),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 1, imported: 1, corrected: 0, rate: 0, confirmed: 1 });
  });

  it("만들 때 바로 반영한 것과 확인 요청으로 물은 것을 나눈다 (구분 전 이벤트는 unknown)", () => {
    const m = misjudgment(
      [
        ev("auto", "created", "2026-09-22T01:00:00Z", { after: { needs_confirmation: false } }),
        ev("auto", "user_edited", "2026-09-23T00:00:00Z", { after: { due: "2026-09-29" } }),
        ev("asked", "created", "2026-09-22T01:00:00Z", { after: { needs_confirmation: true } }),
        ev("asked", "user_deleted", "2026-09-23T00:00:00Z"),
        created("old"),
      ],
      period,
    );
    expect(m.byConfirmation).toEqual({ auto: { created: 1, corrected: 1 }, asked: { created: 1, corrected: 1 }, unknown: { created: 1, corrected: 0 } });
  });

  it("물어서 만들었어도 AI가 나중 원문으로 물음을 풀었으면 자동으로 센다 (그 뒤에 고치면 자동 반영의 오판)", () => {
    const cleared = ev("cleared", "merged", "2026-09-22T05:00:00Z", {
      before: { needs_confirmation: true, confirm_reasons: ["판정 확인: NOT_MY_ACTION"] },
      after: { needs_confirmation: false, confirm_reasons: [] },
    });
    const m = misjudgment(
      [
        ev("cleared", "created", "2026-09-22T01:00:00Z", { after: { needs_confirmation: true } }),
        cleared,
        ev("cleared", "user_edited", "2026-09-23T00:00:00Z", { after: { due: "2026-09-29" } }),
        // 일부만 풀렸거나(아직 확인이 남음) 풀림이 없는 병합은 그대로 asked
        ev("partly", "created", "2026-09-22T01:00:00Z", { after: { needs_confirmation: true } }),
        ev("partly", "merged", "2026-09-22T05:00:00Z", { before: { needs_confirmation: true }, after: { needs_confirmation: true } }),
        ev("partly", "user_deleted", "2026-09-23T00:00:00Z"),
      ],
      period,
    );
    expect(m.byConfirmation).toEqual({ auto: { created: 1, corrected: 1 }, asked: { created: 1, corrected: 1 }, unknown: { created: 0, corrected: 0 } });
  });

  it("확인을 푼 전후가 기한 변경 같은 값 이벤트에 얹혀 있어도 자동으로 센다 (created 이벤트는 해당 없음)", () => {
    const m = misjudgment(
      [
        ev("due", "created", "2026-09-22T01:00:00Z", { after: { needs_confirmation: true } }),
        ev("due", "due_changed", "2026-09-22T05:00:00Z", {
          before: { due: null, needs_confirmation: true, confirm_reasons: ["기한 확인"] },
          after: { due: "2026-09-26", needs_confirmation: false, confirm_reasons: [] },
        }),
        ev("due", "user_deleted", "2026-09-23T00:00:00Z"),
      ],
      period,
    );
    expect(m.byConfirmation).toEqual({ auto: { created: 1, corrected: 1 }, asked: { created: 0, corrected: 0 }, unknown: { created: 0, corrected: 0 } });
  });

  it("AI 생성이 없으면 비율은 없음", () => {
    expect(misjudgment([], period).rate).toBeNull();
  });

  it("작업 상태: 착수 · 착수 되돌리기와 자기가 완료한 것을 다시 여는 것은 오판이 아니다. AI가 끝냈다고 본 일을 다시 열면 오판이다", () => {
    // load.ts는 before · after에서 started_at을 버린다 (빈 객체). 한 트랜잭션의 이벤트는 시각이 같다.
    const m = misjudgment(
      [
        created("started"),
        ev("started", "user_started", "2026-09-23T00:00:00Z", { after: {} }),
        ev("started", "user_unstarted", "2026-09-23T01:00:00Z", { before: {}, after: {} }),
        ev("started", "user_started", "2026-09-23T02:00:00Z", { after: {} }),
        created("own"),
        ev("own", "user_started", "2026-09-23T00:00:00Z", { after: {} }),
        ev("own", "user_edited", "2026-09-23T01:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
        // 완료 → 할 일: 다시 열기 + 착수 되돌리기
        ev("own", "user_unstarted", "2026-09-23T02:00:00Z", { before: {}, after: {} }),
        ev("own", "user_edited", "2026-09-23T02:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
        created("ai"),
        ev("ai", "completed", "2026-09-23T00:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
        // 완료 → 진행 중: 다시 열기 + 착수
        ev("ai", "user_started", "2026-09-24T00:00:00Z", { after: {} }),
        ev("ai", "user_edited", "2026-09-24T00:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 3, corrected: 1, byField: { status: 1, title: 0, due: 0, owner: 0, deleted: 0 }, byStage: { extract: 0, update: 1 } });
  });

  it("실행 receipt(artifact_created, actor agent)는 AI 생성 · 오판 · 물음 풀기에 섞이지 않는다 (U2 PR7)", () => {
    // load.ts의 keep()은 receipt 이벤트의 after(산출물 · run · 단계 id)를 빈 객체로 남긴다
    const receipt = (id: string, at: string) => ev(id, "artifact_created", at, { actor: "agent", sourceKind: "execution", after: {} });
    const m = misjudgment(
      [
        { ...created("drafted"), after: { needs_confirmation: false } },
        receipt("drafted", "2026-09-23T00:00:00Z"),
        { ...created("asked"), after: { needs_confirmation: true } },
        receipt("asked", "2026-09-23T00:00:00Z"),
        // 사용자가 끝낸 뒤 초안이 붙고, 사용자가 다시 연다: 자기가 끝낸 것을 다시 연 것이라 오판이 아니다
        { ...created("own"), after: { needs_confirmation: false } },
        ev("own", "user_edited", "2026-09-23T01:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
        receipt("own", "2026-09-23T02:00:00Z"),
        ev("own", "user_edited", "2026-09-23T03:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
        // 직접 추가한 할 일의 초안: 지표 1에 넣지 않는다
        ev("mine", "user_created", "2026-09-22T01:00:00Z"),
        receipt("mine", "2026-09-23T00:00:00Z"),
      ],
      period,
    );
    expect(m).toMatchObject({ aiCreated: 3, corrected: 0, rate: 0 });
    expect(m.byConfirmation).toEqual({ auto: { created: 2, corrected: 0 }, asked: { created: 1, corrected: 0 }, unknown: { created: 0, corrected: 0 } });
  });
});

describe("timeToStart (지표 2)", () => {
  const me = (type: string, at: string, userId = "u1"): MetricEventRow => ({ userId, type, actionId: null, at });

  it("열고 한 시간 안의 첫 착수까지 걸린 시간, 다시 열면 새로 센다", () => {
    const m = timeToStart(
      [
        me("app_opened", "2026-09-22T00:00:00Z"),
        me("action_started", "2026-09-22T00:10:00Z"),
        me("handoff_used", "2026-09-22T00:12:00Z"),
        me("app_opened", "2026-09-22T05:00:00Z"),
        me("app_opened", "2026-09-22T09:00:00Z"),
        me("handoff_used", "2026-09-22T09:30:00Z"),
        me("app_opened", "2026-09-23T00:00:00Z", "u2"),
        me("action_started", "2026-09-23T03:00:00Z", "u2"), // 한 시간이 지나 착수로 보지 않는다
      ],
      period,
    );
    expect(m).toEqual({ opens: 4, startedRate: 0.5, medianMinutes: 20 });
  });

  it("연 적이 없으면 비율 · 시간은 없음", () => {
    expect(timeToStart([], period)).toEqual({ opens: 0, startedRate: null, medianMinutes: null });
  });

  it("Action마다 처음 착수만 센다: 착수를 되돌렸다가 다시 시작해도 새 착수가 아니다 (기간 전의 첫 착수도 본다)", () => {
    const started = (actionId: string, at: string): MetricEventRow => ({ userId: "u1", type: "action_started", actionId, at });
    const m = timeToStart(
      [
        started("old", "2026-09-10T00:05:00Z"), // 기간 전 첫 착수
        me("app_opened", "2026-09-22T00:00:00Z"),
        started("a1", "2026-09-22T00:10:00Z"),
        me("app_opened", "2026-09-23T00:00:00Z"),
        started("a1", "2026-09-23T00:05:00Z"), // 할 일로 되돌렸다가 다시 시작
        started("a2", "2026-09-23T00:20:00Z"),
        me("app_opened", "2026-09-24T00:00:00Z"),
        started("a1", "2026-09-24T00:05:00Z"),
        me("app_opened", "2026-09-25T00:00:00Z"),
        started("old", "2026-09-25T00:05:00Z"),
      ],
      period,
    );
    expect(m).toEqual({ opens: 4, startedRate: 0.5, medianMinutes: 15 });
  });
});

describe("retention (지표 3)", () => {
  it("한국 시간 월요일 기준 주", () => {
    expect(kstWeek("2026-09-27T14:59:00Z")).toBe("2026-09-21"); // 일요일 23:59 KST
    expect(kstWeek("2026-09-27T15:00:00Z")).toBe("2026-09-28"); // 월요일 00:00 KST
  });

  it("첫 활동 주 기준 N주 뒤 활동 비율 (아직 오지 않은 주는 분모에서 뺀다)", () => {
    const opened = (userId: string, at: string) => ({ userId, at });
    const r = retention(
      [opened("u1", "2026-09-08T01:00:00Z"), opened("u1", "2026-09-22T01:00:00Z"), opened("u2", "2026-09-15T01:00:00Z"), opened("u2", "2026-09-16T01:00:00Z")],
      new Date("2026-09-29T00:00:00Z"), // 9/28 주가 진행 중 → 마지막으로 끝난 주는 9/21
      2,
    );
    expect(r.cohortSize).toBe(2);
    expect(r.weeklyActive).toEqual([
      { week: "2026-09-07", users: 1 },
      { week: "2026-09-14", users: 1 },
      { week: "2026-09-21", users: 1 },
    ]);
    // 1주 뒤: u1(9/14 활동 없음) · u2(9/21 활동 없음) → 0 / 2. 2주 뒤: u1만 대상(9/21 활동) → 1 / 1
    expect(r.retention).toEqual([1, 0, 1]);
  });

  it("진행 중인 주는 N주 뒤 판단에 쓰지 않는다 (기간으로 잘린 활동이 아니라 처음 활동부터 본다)", () => {
    const r = retention([{ userId: "u1", at: "2026-09-08T01:00:00Z" }, { userId: "u2", at: "2026-09-15T01:00:00Z" }], new Date("2026-09-23T00:00:00Z"), 1);
    // 이번 주(9/21) 진행 중 → 1주 뒤는 u1(9/14)만 대상, 활동 없음
    expect(r.retention).toEqual([1, 0]);
  });
});

const noStages = { processing_failed: 0, not_extracted: 0, quoted_history: 0, judge_rejected: 0, merge_absorbed: 0, unknown: 0 };

describe("missed (지표 4)", () => {
  it("누락 신고 기능 전에는 측정 전", () => {
    const m = misjudgment([created("a")], period);
    expect(missed([], m, period, false)).toEqual({ reported: 0, added: 0, addedPlain: 0, rate: null, available: false, byStage: noStages });
    expect(missed([ev("r", "user_reported_missing", "2026-09-23T00:00:00Z")], m, period, true)).toEqual({
      reported: 1,
      added: 0,
      addedPlain: 0,
      rate: 0.5,
      available: true,
      byStage: { ...noStages, unknown: 1 },
    });
  });

  it("신고로 생긴 Action은 지표 1의 AI 생성에서 빼고, 놓친 단계별로 센다", () => {
    const reported = (id: string, stage: string) => [
      created(id),
      ev(id, "user_reported_missing", "2026-09-22T01:00:00Z", { after: { stage } }),
      // 신고로 생긴 Action을 사용자가 고쳐도 AI 오판이 아니다
      ev(id, "user_edited", "2026-09-23T00:00:00Z", { after: { title: true } }),
    ];
    const events = [created("a"), ...reported("r1", "not_extracted"), ...reported("r2", "judge_rejected"), ...reported("r3", "not_extracted"), ...reported("r4", "quoted_history")];
    const m = misjudgment(events, period);
    expect(m).toMatchObject({ aiCreated: 1, corrected: 0 });
    // 연결 메일의 인용된 옛 메일 속이라 버린 것(quoted_history)은 따로 센다
    expect(missed(events, m, period, true)).toEqual({
      reported: 4,
      added: 0,
      addedPlain: 0,
      rate: 0.8,
      available: true,
      byStage: { ...noStages, not_extracted: 2, judge_rejected: 1, quoted_history: 1 },
    });
  });

  // 직접 추가: 원문 구절을 고르면 이벤트에 source_id가 남는다 (lib/actions/service.ts createUserAction → write_action의 이벤트 source_id)
  const added = (id: string, at = "2026-09-22T01:00:00Z", fromSource = true) => [
    ev(id, "user_created", at, { hasSource: fromSource, after: { title: true, due: true, owner: true, status: "open", needs_confirmation: false } }),
    // 직접 추가한 Action을 나중 원문이 갱신하고 사용자가 고쳐도 AI 오판이 아니다
    ev(id, "due_changed", "2026-09-23T00:00:00Z", { after: { due: true } }),
    ev(id, "user_edited", "2026-09-24T00:00:00Z", { after: { due: true } }),
  ];

  it("원문 구절을 고른 직접 추가는 지표 1에서 빼고 지표 4의 누락으로 센다 (단계는 모름이 아니라 따로 센다)", () => {
    const events = [created("a"), created("b"), ...added("u1"), ...added("u2"), ...added("old", "2026-09-10T00:00:00Z")];
    const m = misjudgment(events, period);
    expect(m).toMatchObject({ aiCreated: 2, corrected: 0 });
    // (신고 0 + 구절을 고른 직접 추가 2) / (AI 생성 2 + 0 + 2). 기간 밖의 추가는 세지 않는다
    expect(missed(events, m, period, true)).toEqual({ reported: 0, added: 2, addedPlain: 0, rate: 0.5, available: true, byStage: noStages });
  });

  it("구절 없는 직접 추가는 일반 입력으로 따로 세고 분자 · 분모에 넣지 않는다. 지표 1에서도 뺀다 (A42)", () => {
    const events = [created("a"), created("b"), created("c"), ...added("q1"), ...added("p1", undefined, false), ...added("p2", undefined, false), ...added("p3", undefined, false)];
    const m = misjudgment(events, period);
    expect(m).toMatchObject({ aiCreated: 3, corrected: 0 });
    // (0 + 1) / (3 + 0 + 1). 구절 없는 추가 3개는 비율을 움직이지 않는다
    expect(missed(events, m, period, true)).toEqual({ reported: 0, added: 1, addedPlain: 3, rate: 0.25, available: true, byStage: noStages });
  });

  it("원문을 연결하지 않은(무료 · 플러그인 미사용) 사용자가 손으로만 적은 할 일은 AI 누락으로 세지 않는다", () => {
    // AI가 만든 Action도, 신고도, 구절을 고른 추가도 없이 손으로만 적은 사용자
    const free = [...added("f1", undefined, false), ...added("f2", "2026-09-25T00:00:00Z", false)].map((e) => ({ ...e, userId: "free" }));
    const m = misjudgment(free, period);
    expect(m.aiCreated).toBe(0);
    expect(missed(free, m, period, true)).toEqual({ reported: 0, added: 0, addedPlain: 2, rate: null, available: true, byStage: noStages });

    // 원문을 연결한 사용자와 섞여도 그 사용자의 비율만 남는다
    const connected = [created("a"), ...added("q1")];
    const mixed = [...connected, ...free];
    expect(missed(mixed, misjudgment(mixed, period), period, true)).toMatchObject({ added: 1, addedPlain: 2, rate: 0.5 });
  });
});

describe("discoveryCost: 발견 원가 (A43)", () => {
  it("기간 안에 처리를 마친 원문의 처리 요약 원가를 UTC 날짜별로 더한다. 원가가 없는 요약 · 기간 밖은 뺀다", () => {
    const metric = discoveryCost(
      [
        { processedAt: "2026-09-22T23:59:00Z", cost: 0.002 },
        { processedAt: "2026-09-22T01:00:00Z", cost: 0.001 },
        // 한국 시간으로는 9월 23일 오전이지만 키의 하루 한도는 UTC 0시에 풀린다
        { processedAt: "2026-09-23T00:30:00Z", cost: 0.004 },
        { processedAt: "2026-09-23T02:00:00Z", cost: undefined },
        { processedAt: "2026-09-23T03:00:00Z", cost: "0.5" },
        { processedAt: null, cost: 0.1 },
        { processedAt: "2026-09-20T23:00:00Z", cost: 0.1 },
        { processedAt: "2026-09-28T00:00:00Z", cost: 0.1 },
      ],
      period,
    );
    expect(metric.days).toEqual([
      { day: "2026-09-22", usd: 0.003, sources: 2 },
      { day: "2026-09-23", usd: 0.004, sources: 1 },
    ]);
    expect(metric.sources).toBe(3);
    expect(metric.totalUsd).toBeCloseTo(0.007, 10);
    expect(discoveryCost([], period)).toEqual({ totalUsd: 0, sources: 0, days: [] });
  });
});

describe("sourceFailures: 원문 처리 실패로 닫음 (W4)", () => {
  it("기간 안의 source_failed를 서비스별로 많은 순서로 센다. 직접 넣은 원문(서비스 없음)은 direct", () => {
    const failed = (at: string, provider: string | null): MetricEventRow => ({ userId: "u1", type: "source_failed", actionId: null, at, provider });
    expect(
      sourceFailures(
        [
          failed("2026-09-22T00:00:00Z", "notion"),
          failed("2026-09-23T00:00:00Z", null),
          failed("2026-09-24T00:00:00Z", "notion"),
          failed("2026-09-10T00:00:00Z", "gmail"),
          { userId: "u1", type: "connection_reauth", actionId: null, at: "2026-09-22T00:00:00Z", provider: "gmail" },
        ],
        period,
      ),
    ).toEqual({
      closed: 3,
      byProvider: [
        { provider: "notion", count: 2 },
        { provider: "direct", count: 1 },
      ],
    });
  });
});

describe("execution: 실행 (U2)", () => {
  const empty: ExecutionRows = { runs: [], events: [], unknownOutcome: 0, usage: [], settles: [] };

  it("기간 안에 만든 run을 지금 상태별로 센다. 기간 밖 run은 뺀다", () => {
    const metric = execution(
      {
        ...empty,
        runs: [
          { state: "done", createdAt: "2026-09-22T00:00:00Z" },
          { state: "done", createdAt: "2026-09-23T00:00:00Z" },
          { state: "running", createdAt: "2026-09-24T00:00:00Z" },
          { state: "stopped", createdAt: "2026-09-25T00:00:00Z" },
          { state: "failed", createdAt: "2026-09-20T23:59:59Z" },
          { state: "queued", createdAt: "2026-09-28T00:00:00Z" },
        ],
      },
      period,
    );
    expect(metric.runs).toBe(4);
    expect(metric.byState).toEqual({ queued: 0, running: 1, waiting_approval: 0, done: 2, failed: 0, stopped: 1 });
  });

  it("승인 요청 = run이 승인 대기로 간 수, 막힘 = 이유가 정해진 hold 이벤트(풀림은 세지 않는다). 결과 불명은 받은 지금 수 그대로", () => {
    const metric = execution(
      {
        ...empty,
        unknownOutcome: 2,
        events: [
          { type: "run", toState: "waiting_approval", at: "2026-09-22T00:00:00Z" },
          { type: "run", toState: "waiting_approval", at: "2026-09-23T00:00:00Z" },
          { type: "run", toState: "running", at: "2026-09-23T00:01:00Z" },
          { type: "hold", toState: "credit", at: "2026-09-22T00:00:00Z" },
          { type: "hold", toState: null, at: "2026-09-22T01:00:00Z" },
          { type: "hold", toState: "credit", at: "2026-09-24T00:00:00Z" },
          { type: "hold", toState: "actor", at: "2026-09-24T00:00:00Z" },
          { type: "hold", toState: "blocked", at: "2026-09-10T00:00:00Z" },
          { type: "step", toState: "unknown_outcome", at: "2026-09-24T00:00:00Z" },
        ],
      },
      period,
    );
    expect(metric.approvalRequests).toBe(2);
    expect(metric.holds).toEqual({ blocked: 0, actor: 1, needs_connection: 0, credit: 2 });
    expect(metric.unknownOutcome).toBe(2);
  });

  it("AI 원가는 청구 대상 · 플랫폼으로 나누고 미확정은 0원으로 더하지 않고 센다. 청구는 정산 크레딧 × 그때 요율", () => {
    const metric = execution(
      {
        ...empty,
        usage: [
          { costUsd: 0.004, confirmed: true, billable: true, at: "2026-09-22T00:00:00Z" },
          { costUsd: 0.0015, confirmed: true, billable: true, at: "2026-09-22T00:00:01Z" },
          { costUsd: 0.001, confirmed: true, billable: false, at: "2026-09-22T00:00:02Z" },
          { costUsd: null, confirmed: false, billable: true, at: "2026-09-23T00:00:00Z" },
          { costUsd: null, confirmed: false, billable: false, at: "2026-09-23T00:00:00Z" },
          { costUsd: 9, confirmed: true, billable: true, at: "2026-09-10T00:00:00Z" },
        ],
        settles: [
          { credits: 6, usdPerCredit: 0.001, at: "2026-09-22T00:00:03Z" },
          { credits: 3, usdPerCredit: 0.001, at: "2026-09-23T00:00:00Z" },
          { credits: 100, usdPerCredit: 0.001, at: "2026-09-28T00:00:00Z" },
        ],
      },
      period,
    );
    expect(metric.cost.billableUsd).toBeCloseTo(0.0055, 10);
    expect(metric.cost.platformUsd).toBeCloseTo(0.001, 10);
    expect(metric.cost.unconfirmed).toBe(2);
    expect(metric.charged.credits).toBe(9);
    expect(metric.charged.usd).toBeCloseTo(0.009, 10);
  });

  it("아무것도 없으면 모두 0", () => {
    expect(execution(empty, period)).toEqual({
      runs: 0,
      byState: { queued: 0, running: 0, waiting_approval: 0, done: 0, failed: 0, stopped: 0 },
      unknownOutcome: 0,
      approvalRequests: 0,
      holds: { blocked: 0, actor: 0, needs_connection: 0, credit: 0 },
      cost: { billableUsd: 0, platformUsd: 0, unconfirmed: 0 },
      charged: { credits: 0, usd: 0 },
    });
  });
});

describe("shadowList (지표 5)", () => {
  const check = (answer: WeeklyCheckRow["answer"], at = "2026-09-23T00:00:00Z"): WeeklyCheckRow => ({ userId: "u1", weekStart: "2026-09-21", answer, at });

  it("있다 / (있다 + 없다). 건너뛰기는 응답 수에만 들어간다", () => {
    expect(shadowList([check("yes"), check("no"), check("no"), check("no"), check("skipped")], period)).toEqual({
      responses: 5,
      yes: 1,
      no: 3,
      skipped: 1,
      rate: 0.25,
    });
  });

  it("기간 밖 응답은 빼고, 있다 · 없다가 없으면 측정 전", () => {
    expect(shadowList([check("yes", "2026-09-01T00:00:00Z"), check("skipped")], period)).toEqual({ responses: 1, yes: 0, no: 0, skipped: 1, rate: null });
  });
});

describe("metricActivity: 리텐션의 활동", () => {
  it("서버가 남기는 이벤트(연결 완료 · 만료 · 재연결 알림 · 원문 처리 실패로 닫음)는 활동이 아니다", () => {
    const events: MetricEventRow[] = [
      { userId: "a", type: "app_opened", actionId: null, at: "2026-09-10T00:00:00Z" },
      { userId: "a", type: "action_started", actionId: "x", at: "2026-09-10T01:00:00Z" },
      { userId: "a", type: "connection_created", actionId: null, at: "2026-09-11T00:00:00Z", provider: "gmail" },
      { userId: "a", type: "connection_reauth", actionId: null, at: "2026-09-12T00:00:00Z", provider: "gmail" },
      { userId: "a", type: "reconnect_notified", actionId: null, at: "2026-09-12T00:00:01Z", provider: "gmail" },
      { userId: "b", type: "source_failed", actionId: null, at: "2026-09-13T00:00:00Z", provider: "notion" },
    ];
    expect(metricActivity(events)).toEqual([
      { userId: "a", at: "2026-09-10T00:00:00Z" },
      { userId: "a", at: "2026-09-10T01:00:00Z" },
    ]);
  });
});

describe("connections (연결 · 2단계 연동 요청)", () => {
  const period = { from: new Date("2026-09-01T00:00:00Z"), to: new Date("2026-09-30T00:00:00Z") };
  it("기간 안의 연결 완료 수 · 사용자 수와, 서비스별 요청 수를 많은 순서로 센다", () => {
    const events: MetricEventRow[] = [
      { userId: "a", type: "connection_created", actionId: null, at: "2026-09-10T00:00:00Z" },
      { userId: "a", type: "connection_created", actionId: null, at: "2026-09-11T00:00:00Z" },
      { userId: "b", type: "connection_created", actionId: null, at: "2026-09-12T00:00:00Z" },
      { userId: "c", type: "connection_created", actionId: null, at: "2026-08-01T00:00:00Z" },
      { userId: "a", type: "app_opened", actionId: null, at: "2026-09-10T00:00:00Z" },
    ];
    const requests = [{ provider: "zoom" }, { provider: "linear" }, { provider: "zoom" }, { provider: "jira" }];
    expect(connections(events, requests, period)).toEqual({
      created: 3,
      users: 2,
      expired: 0,
      notified: 0,
      reconnect: [],
      requests: [
        { provider: "zoom", count: 2 },
        { provider: "jira", count: 1 },
        { provider: "linear", count: 1 },
      ],
    });
  });

  it("만료(connection_reauth)와 알림(reconnect_notified)을 서비스별로 세고, 알림이 못 간 만료가 드러난다", () => {
    const e = (type: string, at: string, provider: string | null, userId = "a"): MetricEventRow => ({ userId, type, actionId: null, at, provider });
    const events: MetricEventRow[] = [
      // Gmail: 만료 3번 중 알림은 2번, 이후 다시 연결 1번
      e("connection_reauth", "2026-09-10T00:00:00Z", "gmail"),
      e("reconnect_notified", "2026-09-10T00:00:01Z", "gmail"),
      e("connection_created", "2026-09-10T05:00:00Z", "gmail"),
      e("connection_reauth", "2026-09-17T00:00:00Z", "gmail"),
      e("reconnect_notified", "2026-09-17T00:00:01Z", "gmail"),
      e("connection_reauth", "2026-09-18T00:00:00Z", "gmail", "b"),
      // Notion: 만료 1번, 알림 없음(기기 없음)
      e("connection_reauth", "2026-09-11T00:00:00Z", "notion"),
      // 기간 밖
      e("connection_reauth", "2026-08-01T00:00:00Z", "gmail"),
      e("reconnect_notified", "2026-08-01T00:00:01Z", "gmail"),
      // 옛 connection_created(provider 없음)는 합계에만 들어가고 서비스별 표에는 없다
      e("connection_created", "2026-09-05T00:00:00Z", null),
    ];
    const result = connections(events, [], period);
    expect(result).toMatchObject({ created: 2, users: 1, expired: 4, notified: 2 });
    expect(result.reconnect).toEqual([
      { provider: "gmail", expired: 3, notified: 2, created: 1 },
      { provider: "notion", expired: 1, notified: 0, created: 0 },
    ]);
  });
});

describe("gmailFiltering: Gmail 거르기 개수", () => {
  it("연결마다 쌓은 이유 코드별 개수를 더하고, 통계가 없는 연결은 세지 않는다", () => {
    const stats = [
      { since: "2026-09-29T00:00:00Z", counts: { ingested: 3, sent: 2, inbound: 1, mailing_list: 7 } },
      { since: "2026-09-30T00:00:00Z", counts: { inbound: 4, mailing_list: 1, no_reply: 2, broken: "x" } },
      null,
      { since: "2026-09-30T00:00:00Z" },
    ];
    expect(gmailFiltering(stats)).toEqual({ connections: 2, counts: { ingested: 3, sent: 2, inbound: 5, mailing_list: 8, no_reply: 2 } });
  });
});

describe("googleActivity: Google(Calendar · Meet) 연결의 개수", () => {
  it("전사 수 · 일정 잇기 결과를 연결마다 더한다 (Gmail 거르기와 같은 모양)", () => {
    const stats = [
      { since: "2026-10-01T00:00:00Z", counts: { meet_transcripts: 2, meet_link_attached: 1, meet_link_none: 1, notion_link_attached: 3 } },
      { since: "2026-10-02T00:00:00Z", counts: { meet_transcripts: 1, notion_link_ambiguous: 2, notion_link_attached: 1 } },
      null,
    ];
    expect(googleActivity(stats)).toEqual({
      connections: 2,
      counts: { meet_transcripts: 3, meet_link_attached: 1, meet_link_none: 1, notion_link_attached: 4, notion_link_ambiguous: 2 },
    });
  });
});

describe("meetingLinkage: 회의 원문에 일정이 붙은 비율", () => {
  it("Notion 회의록과 Meet 전사를 외부 id로 가르고, 붙은 일정과 그 일정에 Meet 전사도 있는 것을 센다", () => {
    const rows = [
      { user_id: "u1", external_id: "notion-page-1", calendar_event_id: "evt-1" },
      { user_id: "u1", external_id: "notion-page-2", calendar_event_id: "evt-2" },
      { user_id: "u1", external_id: "notion-page-3", calendar_event_id: null },
      { user_id: "u1", external_id: "conferenceRecords/c1/transcripts/t1", calendar_event_id: "evt-1" },
      { user_id: "u1", external_id: "conferenceRecords/c2/transcripts/t1", calendar_event_id: null },
      { user_id: "u1", external_id: null, calendar_event_id: null },
    ];
    expect(meetingLinkage(rows, new Set(["u1"]))).toEqual({ notion: { total: 3, linked: 2, withTranscript: 1 }, meet: { total: 2, linked: 1 } });
  });

  it("같은 일정 id라도 다른 사용자의 Meet 전사는 같은 회의로 세지 않는다 (같은 회의에 초대된 사람마다 자기 캘린더에 사본이 있다)", () => {
    const rows = [
      { user_id: "u1", external_id: "notion-page-1", calendar_event_id: "evt-1" },
      { user_id: "u2", external_id: "conferenceRecords/c1/transcripts/t1", calendar_event_id: "evt-1" },
    ];
    expect(meetingLinkage(rows, new Set(["u1", "u2"]))).toEqual({ notion: { total: 1, linked: 1, withTranscript: 0 }, meet: { total: 1, linked: 1 } });
  });

  it("원문이 없으면 모두 0", () => {
    expect(meetingLinkage([], new Set())).toEqual({ notion: { total: 0, linked: 0, withTranscript: 0 }, meet: { total: 0, linked: 0 } });
  });

  it("Notion 회의록은 Calendar를 허용한 google 연결이 있는 사용자의 것만 센다: 그 밖의 사용자(연결 없음 · Meet만)의 회의록은 일정이 붙을 수 없어 분모에 넣지 않는다", () => {
    const rows = [
      { user_id: "u1", external_id: "notion-page-1", calendar_event_id: "evt-1" },
      { user_id: "u1", external_id: "notion-page-2", calendar_event_id: null },
      { user_id: "u-no-google", external_id: "notion-page-3", calendar_event_id: null },
      { user_id: "u-meet-only", external_id: "notion-page-4", calendar_event_id: null },
      { user_id: "u-meet-only", external_id: "conferenceRecords/c1/transcripts/t1", calendar_event_id: null },
    ];
    // Meet 전사는 Meet만 허용한 사용자의 것도 센다 (전사 자체는 일정 없이도 들어온다)
    expect(meetingLinkage(rows, new Set(["u1"]))).toEqual({ notion: { total: 2, linked: 1, withTranscript: 0 }, meet: { total: 1, linked: 0 } });
    expect(meetingLinkage(rows, new Set()).notion).toEqual({ total: 0, linked: 0, withTranscript: 0 });
  });
});

describe("본 것 표시(user_seen, U1 바뀜 점)는 지표가 세지 않는다", () => {
  it("오판 · 확인 · 누락 어디에도 들어가지 않고, AI가 끝낸 일을 다시 연 판정도 그대로다", () => {
    const seen = (id: string, at: string) => ev(id, "user_seen", at);
    const events = [
      created("a"),
      seen("a", "2026-09-22T02:00:00Z"),
      created("b"),
      ev("b", "completed", "2026-09-22T03:00:00Z", { before: { status: "open" }, after: { status: "done" } }),
      seen("b", "2026-09-22T04:00:00Z"),
      ev("b", "user_edited", "2026-09-22T05:00:00Z", { before: { status: "done" }, after: { status: "open" } }),
    ];
    const m = misjudgment(events, period);
    expect(m).toMatchObject({ aiCreated: 2, corrected: 1, confirmed: 0 });
    expect(m.byField).toMatchObject({ status: 1, title: 0, due: 0, owner: 0, deleted: 0 });
    expect(missed(events, m, period, true)).toMatchObject({ reported: 0, added: 0, addedPlain: 0 });
  });
});
