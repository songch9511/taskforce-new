import { describe, expect, it } from "vitest";

import {
  connections,
  gmailFiltering,
  googleActivity,
  kstWeek,
  meetingLinkage,
  missed,
  misjudgment,
  retention,
  shadowList,
  timeToStart,
  type ActionEventRow,
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

const noStages = { processing_failed: 0, not_extracted: 0, judge_rejected: 0, merge_absorbed: 0, unknown: 0 };

describe("missed (지표 4)", () => {
  it("누락 신고 기능 전에는 측정 전", () => {
    const m = misjudgment([created("a")], period);
    expect(missed([], m, period, false)).toEqual({ reported: 0, added: 0, rate: null, available: false, byStage: noStages });
    expect(missed([ev("r", "user_reported_missing", "2026-09-23T00:00:00Z")], m, period, true)).toEqual({
      reported: 1,
      added: 0,
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
    const events = [created("a"), ...reported("r1", "not_extracted"), ...reported("r2", "judge_rejected"), ...reported("r3", "not_extracted")];
    const m = misjudgment(events, period);
    expect(m).toMatchObject({ aiCreated: 1, corrected: 0 });
    expect(missed(events, m, period, true)).toEqual({ reported: 3, added: 0, rate: 0.75, available: true, byStage: { ...noStages, not_extracted: 2, judge_rejected: 1 } });
  });

  it("직접 추가한 Action은 지표 1에서 빼고 지표 4의 누락으로 센다 (단계는 모름이 아니라 따로 센다)", () => {
    const added = (id: string, at = "2026-09-22T01:00:00Z") => [
      ev(id, "user_created", at, { after: { title: true, due: true, owner: true, status: "open", needs_confirmation: false } }),
      // 직접 추가한 Action을 나중 원문이 갱신하고 사용자가 고쳐도 AI 오판이 아니다
      ev(id, "due_changed", "2026-09-23T00:00:00Z", { after: { due: true } }),
      ev(id, "user_edited", "2026-09-24T00:00:00Z", { after: { due: true } }),
    ];
    const events = [created("a"), created("b"), ...added("u1"), ...added("u2"), ...added("old", "2026-09-10T00:00:00Z")];
    const m = misjudgment(events, period);
    expect(m).toMatchObject({ aiCreated: 2, corrected: 0 });
    // (신고 0 + 직접 추가 2) / (AI 생성 2 + 0 + 2). 기간 밖의 추가는 세지 않는다
    expect(missed(events, m, period, true)).toEqual({ reported: 0, added: 2, rate: 0.5, available: true, byStage: noStages });
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
      requests: [
        { provider: "zoom", count: 2 },
        { provider: "jira", count: 1 },
        { provider: "linear", count: 1 },
      ],
    });
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
    expect(meetingLinkage(rows)).toEqual({ notion: { total: 3, linked: 2, withTranscript: 1 }, meet: { total: 2, linked: 1 } });
  });

  it("같은 일정 id라도 다른 사용자의 Meet 전사는 같은 회의로 세지 않는다 (같은 회의에 초대된 사람마다 자기 캘린더에 사본이 있다)", () => {
    const rows = [
      { user_id: "u1", external_id: "notion-page-1", calendar_event_id: "evt-1" },
      { user_id: "u2", external_id: "conferenceRecords/c1/transcripts/t1", calendar_event_id: "evt-1" },
    ];
    expect(meetingLinkage(rows)).toEqual({ notion: { total: 1, linked: 1, withTranscript: 0 }, meet: { total: 1, linked: 1 } });
  });

  it("원문이 없으면 모두 0", () => {
    expect(meetingLinkage([])).toEqual({ notion: { total: 0, linked: 0, withTranscript: 0 }, meet: { total: 0, linked: 0 } });
  });
});
