import type { ApnsPayload } from "@/lib/notify/apns";

// 일일 보고 알림 내용 (0.2.0 H1, D06 "Notifications carry a short status and a deep link only, never source text or messages").
// 본문은 숫자와 고정된 영어 낱말로만 만든다: 할 일 제목 · 원문 · 인용 · 메모 · 상대 이름 · 이메일 · action id를 싣지 않는다.
// 숫자는 DB 함수 report_status_counts가 센 것뿐이다(글 열을 읽지 않는다). 누르면 앱이 url(All work)을 연다 —
// 지금 앱(0.1.x)은 모르는 kind를 받으면 앱만 연다(PushNotifications.swift NotificationTarget .other). url 처리는 H2.
//
// interruption-level: Respect Focus가 켜져 있으면 active(집중 모드가 붙잡을 수 있는 보통 수준)만 쓴다.
// 꺼져 있으면 time-sensitive를 요청한다 — 실제로 집중 모드를 뚫는지는 앱의 Time Sensitive Notifications 권한(entitlement, 아직 없음)과
// 사용자의 집중 모드 설정이 정한다. 권한이 없을 때 OS가 active로 낮춰 다루는지는 미검증이다(H2 기기 확인 전). critical은 쓰지 않는다.

/** 열린 할 일 개수 (report_status_counts). 겹치지 않는다: review는 확인 요청, 나머지는 내 일 */
export type ReportStatusCounts = { review: number; overdue: number; due_today: number; in_progress: number };

/** 누르면 여는 곳: All work (H2가 처리한다) */
export const DAILY_REPORT_URL = "taskforce://work";

/**
 * 같은 collapse id의 새 알림은 알림 센터에서 앞의 보고 항목을 바꾼다 (어제 상태가 남지 않고, 보내다 멈춰 다시 보낸 것도 항목은 하나).
 * 기기가 다시 울리지 않는다는 보장은 아니다
 */
export const DAILY_REPORT_COLLAPSE_ID = "daily-report";

const count = (n: number) => (Number.isSafeInteger(n) && n > 0 ? n : 0);

/** 모두 0이면 보낼 것이 없다 (job은 보내지 않고 skipped · empty로 남긴다) */
export function isEmptyReport(counts: ReportStatusCounts): boolean {
  return count(counts.review) + count(counts.overdue) + count(counts.due_today) + count(counts.in_progress) === 0;
}

/** "2 to review · 1 overdue · 3 due today · 1 in progress" (0인 것은 뺀다) */
export function dailyReportBody(counts: ReportStatusCounts): string {
  return [
    [count(counts.review), "to review"],
    [count(counts.overdue), "overdue"],
    [count(counts.due_today), "due today"],
    [count(counts.in_progress), "in progress"],
  ]
    .filter(([n]) => (n as number) > 0)
    .map(([n, label]) => `${n} ${label}`)
    .join(" · ");
}

export function dailyReportPayload(counts: ReportStatusCounts, options: { respectFocus: boolean }): ApnsPayload {
  return {
    aps: {
      alert: { title: "Daily report", body: dailyReportBody(counts) },
      sound: "default",
      "thread-id": "reports",
      "interruption-level": options.respectFocus ? "active" : "time-sensitive",
    },
    kind: "daily_report",
    url: DAILY_REPORT_URL,
  };
}
