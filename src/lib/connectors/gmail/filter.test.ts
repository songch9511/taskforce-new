import { describe, expect, it } from "vitest";

import { companyDomain, filterMessage, type GmailFilterContext } from "./filter";

// Gmail 거르기 표 (G7, docs/go-live/google-integration.md 2-6 거르기): 위에서부터 처음 맞는 규칙 ①~⑨.

const context: GmailFilterContext = { userEmails: ["me@company.dev", "me.personal@gmail.com"], companyDomain: "company.dev" };

/** 거를 규칙에 걸리지 않는 받은 메일 (바깥 사람이 보냄) */
const inbound = (headers: Record<string, string> = {}, labelIds: string[] = ["INBOX", "UNREAD"]) => ({
  labelIds,
  headers: { from: "Jordan Lee <jordan@acme.io>", to: "me@company.dev", subject: "Signed contract", ...headers },
});

const decide = (message: Parameters<typeof filterMessage>[0], ctx: GmailFilterContext = context) => filterMessage(message, ctx);

describe("companyDomain", () => {
  it("연결한 주소의 도메인 (소문자)", () => {
    expect(companyDomain("me@Company.dev")).toBe("company.dev");
  });

  it("공용 메일 도메인 · 주소 없음 · @ 없음은 null", () => {
    for (const email of ["me@gmail.com", "me@googlemail.com", "me@naver.com", "me@hanmail.net", "me@outlook.com", "me@icloud.com"]) {
      expect(companyDomain(email)).toBeNull();
    }
    expect(companyDomain(null)).toBeNull();
    expect(companyDomain("not-an-address")).toBeNull();
  });
});

describe("① 임시 보관 · 스팸 · 휴지통 · 채팅 → excluded_label", () => {
  it.each(["DRAFT", "SPAM", "TRASH", "CHAT"])("%s 표시면 버린다", (label) => {
    expect(decide(inbound({}, ["INBOX", label]))).toEqual({ keep: false, reason: "excluded_label" });
  });

  it("사용자가 보낸 메일(SENT)이어도 휴지통이면 버린다 (③보다 먼저)", () => {
    expect(decide(inbound({ from: "me@company.dev" }, ["SENT", "TRASH"]))).toEqual({ keep: false, reason: "excluded_label" });
  });

  it("자동 발송 머리글보다 먼저 본다 (②보다 먼저)", () => {
    expect(decide(inbound({ "auto-submitted": "auto-replied" }, ["SPAM"]))).toEqual({ keep: false, reason: "excluded_label" });
  });
});

describe("② Auto-Submitted가 있고 no가 아님 → auto_submitted", () => {
  it.each(["auto-replied", "auto-generated", "Auto-Notified", "auto-replied; owner-email=\"x@y.com\""])("%s면 버린다", (value) => {
    expect(decide(inbound({ "auto-submitted": value }))).toEqual({ keep: false, reason: "auto_submitted" });
  });

  it("사용자가 보낸 것(SENT · 보낸 사람이 나)이어도 버린다 (부재 중 자동 답장)", () => {
    expect(decide(inbound({ "auto-submitted": "auto-replied" }, ["SENT"]))).toEqual({ keep: false, reason: "auto_submitted" });
    expect(decide(inbound({ from: "Me <me@company.dev>", "auto-submitted": "auto-replied" }))).toEqual({ keep: false, reason: "auto_submitted" });
  });

  it("Auto-Submitted: no는 버리지 않는다 (대소문자 · 매개변수 상관없이)", () => {
    expect(decide(inbound({ "auto-submitted": "no" }))).toEqual({ keep: true, reason: "inbound" });
    expect(decide(inbound({ "auto-submitted": " No ; comment" }))).toEqual({ keep: true, reason: "inbound" });
  });
});

describe("③ 사용자가 보낸 메일 → 남김 (sent)", () => {
  it("SENT 표시가 있으면 목록 머리글 · 대량 발송 · 프로모션이어도 남긴다", () => {
    const sent = inbound(
      { from: "Me Alias <alias@other.dev>", "list-unsubscribe": "<mailto:u@list.dev>", "list-id": "<news.list.dev>", precedence: "bulk" },
      ["SENT", "CATEGORY_PROMOTIONS"],
    );
    expect(decide(sent)).toEqual({ keep: true, reason: "sent" });
  });

  it("보낸 사람이 사용자 주소면(대소문자 상관없이) SENT 표시가 없어도 남긴다", () => {
    expect(decide(inbound({ from: "Me <ME@Company.dev>", precedence: "bulk" }, ["INBOX"]))).toEqual({ keep: true, reason: "sent" });
    expect(decide(inbound({ from: "me.personal@gmail.com", "list-id": "<x.list.dev>" }))).toEqual({ keep: true, reason: "sent" });
  });

  it("no-reply 모양의 사용자 주소도 사용자가 보낸 것으로 본다 (⑦보다 먼저)", () => {
    expect(decide(inbound({ from: "noreply@company.dev" }), { ...context, userEmails: ["noreply@company.dev"] })).toEqual({ keep: true, reason: "sent" });
  });
});

describe("④ 프로모션 · 소셜 탭 → category", () => {
  it.each(["CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL"])("%s면 버린다", (label) => {
    expect(decide(inbound({}, ["INBOX", label]))).toEqual({ keep: false, reason: "category" });
  });

  it("업데이트 · 포럼 탭은 남긴다", () => {
    expect(decide(inbound({}, ["INBOX", "CATEGORY_UPDATES"]))).toEqual({ keep: true, reason: "inbound" });
    expect(decide(inbound({}, ["INBOX", "CATEGORY_FORUMS"]))).toEqual({ keep: true, reason: "inbound" });
  });

  it("대량 발송 · 목록 머리글보다 먼저 본다 (⑤ · ⑥보다 먼저)", () => {
    expect(decide(inbound({ precedence: "bulk", "list-unsubscribe": "<https://x.io/u>" }, ["CATEGORY_SOCIAL"]))).toEqual({ keep: false, reason: "category" });
  });
});

describe("⑤ Precedence bulk · junk → bulk", () => {
  it.each(["bulk", "junk", " Bulk "])("Precedence: %s면 버린다", (value) => {
    expect(decide(inbound({ precedence: value }))).toEqual({ keep: false, reason: "bulk" });
  });

  it("Precedence: list는 여기서 버리지 않는다", () => {
    expect(decide(inbound({ precedence: "list" }))).toEqual({ keep: true, reason: "inbound" });
  });

  it("같은 회사 도메인의 대량 발송도 버린다 (⑥보다 먼저)", () => {
    expect(decide(inbound({ from: "ceo@company.dev", precedence: "bulk", "list-id": "<all.company.dev>" }))).toEqual({ keep: false, reason: "bulk" });
  });
});

describe("⑥ 목록 머리글이 있고 회사 밖에서 옴 → mailing_list", () => {
  it("List-Unsubscribe가 있고 보낸 사람이 회사 밖이면 버린다", () => {
    expect(decide(inbound({ "list-unsubscribe": "<https://acme.io/unsub>" }))).toEqual({ keep: false, reason: "mailing_list" });
  });

  it("List-Id가 있고 보낸 사람이 회사 밖이면 버린다", () => {
    expect(decide(inbound({ "list-id": "Acme News <news.acme.io>" }))).toEqual({ keep: false, reason: "mailing_list" });
  });

  it("보낸 사람이 회사 도메인(하위 도메인 포함)이면 남긴다", () => {
    expect(decide(inbound({ from: "Ops <ops@company.dev>", "list-id": "<ops.company.dev>" }))).toEqual({ keep: true, reason: "inbound" });
    expect(decide(inbound({ from: "Bot <team@eng.company.dev>", "list-unsubscribe": "<https://x/u>" }))).toEqual({ keep: true, reason: "inbound" });
  });

  it("보낸 사람이 밖이어도 List-Id가 회사 도메인의 그룹(<team.company.dev>)이면 남긴다", () => {
    expect(decide(inbound({ from: "Jordan <jordan@acme.io>", "list-id": "Team <team.company.dev>" }))).toEqual({ keep: true, reason: "inbound" });
    expect(decide(inbound({ from: "Jordan <jordan@acme.io>", "list-id": "team.company.dev" }))).toEqual({ keep: true, reason: "inbound" });
  });

  it("이름만 비슷한 도메인(evilcompany.dev · company.dev.evil.io)은 회사 도메인이 아니다", () => {
    expect(decide(inbound({ from: "x@evilcompany.dev", "list-unsubscribe": "<https://x/u>" }))).toEqual({ keep: false, reason: "mailing_list" });
    expect(decide(inbound({ "list-id": "<team.company.dev.evil.io>" }))).toEqual({ keep: false, reason: "mailing_list" });
  });

  it("회사 도메인이 없으면(공용 메일로 연결) 목록 메일은 모두 버린다", () => {
    const personal = { userEmails: ["me@gmail.com"], companyDomain: companyDomain("me@gmail.com") };
    expect(decide(inbound({ from: "friend@gmail.com", "list-id": "<club.gmail.com>" }), personal)).toEqual({ keep: false, reason: "mailing_list" });
  });

  it("no-reply 보낸 주소보다 먼저 본다 (⑦보다 먼저)", () => {
    expect(decide(inbound({ from: "noreply@acme.io", "list-unsubscribe": "<https://x/u>" }))).toEqual({ keep: false, reason: "mailing_list" });
  });
});

describe("⑦ no-reply류 보낸 주소 → no_reply", () => {
  it.each([
    "noreply@acme.io",
    "no-reply@acme.io",
    "no_reply@acme.io",
    "No.Reply@acme.io",
    "donotreply@acme.io",
    "do-not-reply@acme.io",
    "do_not_reply@acme.io",
    "notification@acme.io",
    "notifications@github.com",
    "MAILER-DAEMON@googlemail.com",
    "postmaster@acme.io",
    "bounce@acme.io",
    "bounces+123@acme.io",
    "noreply+abc@acme.io",
    // 구분자 뒤의 no-reply 낱말 (dev 메일함의 Google 시스템 메일)
    "workspace-noreply@google.com",
    "notify-noreply@google.com",
    "platformnotifications-noreply@google.com",
    "alerts.no-reply@acme.io",
  ])("%s는 버린다", (from) => {
    expect(decide(inbound({ from: `Acme <${from}>` }))).toEqual({ keep: false, reason: "no_reply" });
  });

  it.each(["reply@acme.io", "snoreply@acme.io", "info@acme.io", "calendar-notification@acme.io"])("%s는 남긴다 (no-reply 낱말 · 알림 주소가 아님)", (from) => {
    expect(decide(inbound({ from }))).toEqual({ keep: true, reason: "inbound" });
  });

  it("회사 도메인의 no-reply도 버린다 (⑥을 지나도)", () => {
    expect(decide(inbound({ from: "no-reply@company.dev", "list-id": "<alerts.company.dev>" }))).toEqual({ keep: false, reason: "no_reply" });
  });

  it("일정 초대보다 먼저 본다 (⑧보다 먼저)", () => {
    expect(decide(inbound({ from: "noreply@acme.io", "content-type": "text/calendar; method=REQUEST" }))).toEqual({ keep: false, reason: "no_reply" });
  });
});

describe("⑧ 일정 초대 · 알림 → calendar", () => {
  it("Content-Type이 text/calendar를 담으면 버린다", () => {
    expect(decide(inbound({ "content-type": 'text/calendar; charset="UTF-8"; method=REQUEST' }))).toEqual({ keep: false, reason: "calendar" });
    expect(decide(inbound({ "content-type": "multipart/mixed; boundary=x; type=Text/Calendar" }))).toEqual({ keep: false, reason: "calendar" });
  });

  it("Content-Class가 calendarmessage면 버린다 (Outlook 초대)", () => {
    expect(decide(inbound({ "content-class": "urn:content-classes:calendarmessage" }))).toEqual({ keep: false, reason: "calendar" });
  });

  it("보낸 사람 · Sender가 Google Calendar 알림 주소면 버린다", () => {
    expect(decide(inbound({ from: "Google Calendar <calendar-notification@google.com>" }))).toEqual({ keep: false, reason: "calendar" });
    expect(decide(inbound({ from: "Jordan Lee <jordan@acme.io>", sender: "Google Calendar <calendar-notification@google.com>" }))).toEqual({
      keep: false,
      reason: "calendar",
    });
  });

  it("일반 multipart 메일은 초대가 아니다", () => {
    expect(decide(inbound({ "content-type": "multipart/alternative; boundary=abc" }))).toEqual({ keep: true, reason: "inbound" });
  });
});

describe("⑨ 나머지 → 남김 (inbound)", () => {
  it("거를 규칙에 걸리지 않은 받은 메일은 남긴다", () => {
    expect(decide(inbound())).toEqual({ keep: true, reason: "inbound" });
  });

  it("보낸 사람이 없거나 주소를 읽을 수 없어도 남긴다", () => {
    expect(decide({ labelIds: ["INBOX"], headers: { subject: "no from" } })).toEqual({ keep: true, reason: "inbound" });
    expect(decide(inbound({ from: "Someone <not-an-email>" }))).toEqual({ keep: true, reason: "inbound" });
  });
});
