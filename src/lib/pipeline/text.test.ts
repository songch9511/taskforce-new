import { describe, expect, it } from "vitest";

import { findQuoteSpan, quotedHistoryStart, quoteContext, quoteInText, quoteLineIndexes } from "./text";

const text = ["a: 1", "b: 2", "c: 3", "나: 금요일까지 제안서", "보내드릴게요.", "d: 4", "e: 5"].join("\n");

describe("quoteInText", () => {
  it("공백 · 문장부호를 무시하고 찾는다", () => {
    expect(quoteInText("금요일까지  제안서 보내드릴게요!", text)).toBe(true);
    expect(quoteInText("월요일까지", text)).toBe(false);
    expect(quoteInText(" ", text)).toBe(false);
  });

  it("'...'로 이은 조각은 순서대로 모두 있어야 한다", () => {
    expect(quoteInText("b: 2 ... 금요일까지 제안서", text)).toBe(true);
    expect(quoteInText("금요일까지 제안서 … b: 2", text)).toBe(false);
    expect(quoteInText("b: 2 ... 없는 말", text)).toBe(false);
  });
});

describe("quoteContext", () => {
  it("인용이 걸친 줄 앞뒤를 잘라 준다", () => {
    expect(quoteContext(text, "금요일까지 제안서 보내드릴게요", 1)).toBe("c: 3\n나: 금요일까지 제안서\n보내드릴게요.\nd: 4");
  });

  it("긴 문단을 자를 때도 인용이 남는다 (앞쪽을 조금 더)", () => {
    const long = `${"가".repeat(5000)} 금요일까지 제안서 보내드릴게요. ${"나".repeat(5000)}`;
    const context = quoteContext(long, "금요일까지 제안서 보내드릴게요", 4, 300)!;
    expect(context).toContain("금요일까지 제안서 보내드릴게요");
    expect(context.startsWith("…") && context.endsWith("…")).toBe(true);
    expect(context.indexOf("금요일")).toBeGreaterThan(90);
    expect(context.length).toBeLessThanOrEqual(302);
  });

  it("없는 인용은 null", () => {
    expect(quoteContext(text, "없는 말")).toBeNull();
  });

  it("10줄보다 길게 걸친 인용은 maxSpan을 늘렸을 때만 찾는다 (기본 동작은 그대로)", () => {
    // 짧은 줄 15개에 걸친 인용 + 앞뒤 한 줄씩
    const span = Array.from({ length: 15 }, (_, i) => `줄${i + 1}`);
    const long = ["앞", "", ...span, "뒤"].join("\n");
    const quote = span.join("\n");
    expect(quoteInText(quote, long)).toBe(true);
    expect(quoteContext(long, quote, 1)).toBeNull();
    expect(quoteContext(long, quote, 1, 1500, Infinity)).toBe(["", ...span, "뒤"].join("\n"));
    expect(quoteContext(long, quote, 1, 1500, 13)).toBeNull();
    // 10줄 안의 인용은 늘려도 같은 결과
    expect(quoteContext(text, "금요일까지 제안서 보내드릴게요", 1, 1500, Infinity)).toBe(quoteContext(text, "금요일까지 제안서 보내드릴게요", 1));
    expect(quoteContext(long, "없는 말", 1, 1500, Infinity)).toBeNull();
  });
});

describe("findQuoteSpan", () => {
  it("공백 · 문장부호 · 대소문자 차이를 무시하고, 원문에 있는 그대로의 구간을 돌려준다", () => {
    const span = findQuoteSpan(text, "금요일까지  제안서 보내드릴게요!");
    expect(span).toEqual({ start: text.indexOf("금요일"), end: text.indexOf("보내드릴게요") + "보내드릴게요".length, quote: "금요일까지 제안서\n보내드릴게요" });
    expect(text.slice(span!.start, span!.end)).toBe(span!.quote);
    expect(findQuoteSpan("Please SEND the deck by Friday.", "send the deck")?.quote).toBe("SEND the deck");
  });

  it("모델이 바꾼 글자가 아니라 원문의 글자를 돌려준다 (따옴표 · 말줄임표 모양 등)", () => {
    const source = "박팀장: “견적서는 월요일에 받아도 괜찮아요…”";
    expect(findQuoteSpan(source, '"견적서는 월요일에 받아도 괜찮아요..."')?.quote).toBe("견적서는 월요일에 받아도 괜찮아요");
  });

  it("떨어진 구절을 '...'로 이어 붙인 인용은 받지 않는다 (quoteInText는 받는다)", () => {
    const stitched = "b: 2 ... 금요일까지 제안서";
    expect(quoteInText(stitched, text)).toBe(true);
    expect(findQuoteSpan(text, stitched)).toBeNull();
  });

  it("원문에 없거나 비어 있으면 null", () => {
    expect(findQuoteSpan(text, "월요일까지")).toBeNull();
    expect(findQuoteSpan(text, " ... ")).toBeNull();
    expect(findQuoteSpan("", "금요일")).toBeNull();
  });

  it("정규화로 길이가 바뀌는 글자(İ → i̇)가 있어도 위치가 맞는다", () => {
    const source = "İstanbul: 금요일까지 보낼게요";
    expect(findQuoteSpan(source, "금요일까지 보낼게요")?.quote).toBe("금요일까지 보낼게요");
    expect(findQuoteSpan(source, "İSTANBUL 금요일")?.quote).toBe("İstanbul: 금요일");
  });
});

describe("quoteLineIndexes", () => {
  it("인용이 있는 줄 번호를 돌려준다. 여러 줄에 걸치면 걸친 줄 모두", () => {
    expect(quoteLineIndexes(text, "금요일까지 제안서")).toEqual([3]);
    expect(quoteLineIndexes(text, "제안서 보내드릴게요")).toEqual([3, 4]);
    expect(quoteLineIndexes(text, "없는 문장")).toEqual([]);
  });

  it("같은 구절이 여러 줄에 있거나 ...로 이은 인용은 줄을 모두 돌려준다", () => {
    const chat = ["박지훈: 넵 확인했어요", "", "윤지호: 넵 월요일에 드릴게요"].join("\n");
    expect(quoteLineIndexes(chat, "넵")).toEqual([0, 2]);
    expect(quoteLineIndexes(chat, "확인했어요 ... 월요일에 드릴게요")).toEqual([0, 2]);
  });
});

describe("quotedHistoryStart", () => {
  /** 인용 시작 위치 앞의 글 (새로 쓴 부분) */
  const fresh = (mail: string) => {
    const at = quotedHistoryStart(mail);
    return at === null ? null : mail.slice(0, at);
  };

  it("Gmail식 답장: `On … wrote:` 머리줄부터 인용이다. 짧은 답은 그대로 남는다", () => {
    const mail = [
      "제목: RE: Signed contract",
      "",
      "Sure, I'll send it by Monday.",
      "",
      "Alex",
      "",
      "On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <jordan@harborline.example> wrote:",
      "",
      "> Could you send the signed contract by Monday?",
    ].join("\n");
    expect(fresh(mail)).toBe("제목: RE: Signed contract\n\nSure, I'll send it by Monday.\n\nAlex\n\n");
  });

  it("두 줄로 꺾인 머리줄, 한국어 Gmail의 `…님이 작성:`, Apple Mail식(머리줄도 `>`)도 찾는다", () => {
    const wrapped = ["Thanks!", "", "On Thu, Oct 8, 2026 at 3:20 PM Morgan Tate <morgan@quillstone.example>", "wrote:", "", "> Hi Alex"].join("\n");
    expect(fresh(wrapped)).toBe("Thanks!\n\n");
    const korean = ["감사합니다!", "", "2026년 10월 14일 (수) 오후 2:05, 문가은 <gaeun@lumenfield.example>님이 작성:", "", "> 배너 시안 보냈습니다."].join("\n");
    expect(fresh(korean)).toBe("감사합니다!\n\n");
    const apple = ["OK, will do.", "", "> On Oct 5, 2026, at 9:30 AM, Jordan Lee <j@harborline.example> wrote:", ">", "> Can you send it?"].join("\n");
    expect(fresh(apple)).toBe("OK, will do.\n\n");
  });

  it("겹겹이 인용된 스레드도 가장 위 인용부터", () => {
    const mail = ["Thanks!", "", "On Fri, Oct 9, 2026 at 11:05 AM A <a@x.example> wrote:", "", "> Wednesday works.", ">", "> On Thu, Oct 8, 2026 at 4:05 PM B <b@x.example> wrote:", ">", ">> by Monday"].join("\n");
    expect(fresh(mail)).toBe("Thanks!\n\n");
  });

  it("-----Original Message----- · -----원본 메시지-----부터는 `>` 없이도 인용이다", () => {
    const en = ["Will do.", "", "-----Original Message-----", "From: Jordan Lee", "Please send it by Monday."].join("\n");
    expect(fresh(en)).toBe("Will do.\n\n");
    const ko = ["제목: RE: 계약서", "", "내일까지 드리겠습니다.", "", "-----원본 메시지-----", "보낸 사람: 오세린", "다음 주에 정리해서 보내드리겠습니다."].join("\n");
    expect(fresh(ko)).toBe("제목: RE: 계약서\n\n내일까지 드리겠습니다.\n\n");
  });

  it("빈 줄 뒤에 `From:`/`보낸 사람:` 줄과 바로 이어지는 머리 줄이 있으면 인용이다", () => {
    const en = ["Sure.", "", "From: Jordan Lee <j@harborline.example>", "Sent: Monday, October 5, 2026 9:30 AM", "To: Alex Kim", "Subject: Contract", "", "Please send it by Monday."].join("\n");
    expect(fresh(en)).toBe("Sure.\n\n");
    const ko = ["네, 확인했습니다.", "", "보낸 사람: 오세린", "보낸 날짜: 2026년 10월 5일", "받는 사람: 한지우", "제목: 계약서", "", "월요일까지 부탁드립니다."].join("\n");
    expect(fresh(ko)).toBe("네, 확인했습니다.\n\n");
    const outlookLine = ["Sure.", "", "________________________________", "From: Jordan Lee", "Sent: Monday", "To: Alex Kim", "Subject: Contract", "", "Please send it by Monday."].join("\n");
    expect(fresh(outlookLine)).toBe("Sure.\n\n");
  });

  it("머리 묶음이 아닌 것은 인용으로 보지 않는다 (제목 바로 아래 머리 줄 · 전달 메일 · 본문 속 From:)", () => {
    // 제목 줄 바로 아래(빈 줄 없음)의 보낸사람 · 받는사람 머리는 이 메일 자신의 머리다
    expect(quotedHistoryStart(["제목: RE: 자료", "보낸사람: 최민호", "받는사람: 서지원", "날짜: 2026년 10월 14일", "", "금요일까지 드리겠습니다."].join("\n"))).toBeNull();
    // Gmail 전달: `From:` 앞이 빈 줄이 아니라 전달 표시 줄
    expect(quotedHistoryStart(["Could you take this by Friday, Sam?", "", "---------- Forwarded message ---------", "From: Casey <c@x.example>", "Date: Mon, Oct 12", "Subject: Invoice", "", "Hi Alex"].join("\n"))).toBeNull();
    // 빈 줄 뒤의 From:이라도 바로 이어지는 머리 줄이 없으면 본문이다
    expect(quotedHistoryStart(["Hi,", "", "From: my side we can start Monday.", "", "Thanks"].join("\n"))).toBeNull();
  });

  it("인용이 없으면 null. 문장이 우연히 wrote:로 끝나는 것은 머리줄이 아니다", () => {
    expect(quotedHistoryStart("제목: 안녕\n\nSure, I'll send it by Monday.")).toBeNull();
    expect(quotedHistoryStart("")).toBeNull();
    expect(quotedHistoryStart(["On the call yesterday Priya wrote:", "please keep this confidential"].join("\n"))).toBeNull();
  });

  it("머리줄 뒤에 `>` 없이 옛 메일이 이어져도 머리줄부터 인용이다", () => {
    const mail = ["Sure.", "", "On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <j@harborline.example> wrote:", "Could you send it by Monday?"].join("\n");
    expect(fresh(mail)).toBe("Sure.\n\n");
  });

  it("인용 사이사이에 답을 적었으면(인용 뒤에 새 글) 그 답을 인용으로 보지 않는다", () => {
    const inline = ["On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <j@harborline.example> wrote:", "", "> 1. Can you send the deck?", "Yes, by Tuesday.", "", "> 2. And the budget?", "I'll send it by Friday."].join("\n");
    expect(quotedHistoryStart(inline)).toBeNull();
    // 답 뒤에 통째로 붙은 인용 묶음이 따로 있으면 그 묶음부터
    const withTail = [inline, "", "On Sun, Oct 4, 2026 at 8:00 AM Jordan Lee <j@harborline.example> wrote:", "", "> older mail"].join("\n");
    expect(withTail.slice(quotedHistoryStart(withTail)!)).toBe("On Sun, Oct 4, 2026 at 8:00 AM Jordan Lee <j@harborline.example> wrote:\n\n> older mail");
  });

  it("인용 뒤에 서명 같은 새 글이 붙으면 애매하니 인용으로 보지 않는다", () => {
    expect(quotedHistoryStart(["Sure.", "", "> old", "", "--", "Alex"].join("\n"))).toBeNull();
  });

  it("머리줄로 보이는 글 속 문장은 인용이 아니다 (첫 줄이 'On …'인 새 글 · 주소 없는 문장 · 시각표)", () => {
    // 내 글 "On it, …" 바로 아래 진짜 머리줄이 와도 내 글을 머리줄 앞부분으로 잇지 않는다
    const mail = ["제목: Re: Deck", "", "On it, I will send the deck by Friday.", "On Mon, Oct 5, 2026 at 9:30 AM Jordan <j@x.example> wrote:", "> Can you send the deck?"].join("\n");
    expect(fresh(mail)).toBe("제목: Re: Deck\n\nOn it, I will send the deck by Friday.\n");
    // 주소 없이 날짜만 있는 문장
    expect(quotedHistoryStart(["On Tuesday at 3pm the client wrote:", '"We need the deck."', "", "I will prepare the deck by Thursday."].join("\n"))).toBeNull();
    expect(quotedHistoryStart(["on 10/7 the vendor wrote:", "", "I will call back by Friday."].join("\n"))).toBeNull();
    // From: / To: 두 줄뿐인 시각표 · 일정
    expect(quotedHistoryStart(["Can we meet?", "", "From: 10:00", "To: 11:00", "", "I will book the room by Monday."].join("\n"))).toBeNull();
    expect(quotedHistoryStart(["Flight:", "", "From: ICN", "To: SFO", "", "I will send the itinerary by Monday."].join("\n"))).toBeNull();
  });

  it("전달한 메일(제목이 Fwd: · FW: · 전달:)은 붙은 내용이 옛 메일 이력이 아니라 전달받은 글이라 인용이 없는 것으로 본다", () => {
    const outlookForward = ["제목: FW: 계약서 검토", "", "________________________________", "From: Jordan Lee", "Sent: Monday", "To: Alex Kim", "Subject: Contract", "", "Please send it by Monday."].join("\n");
    expect(quotedHistoryStart(outlookForward)).toBeNull();
    expect(quotedHistoryStart(outlookForward.replace("FW:", "전달:"))).toBeNull();
    // 가장 바깥 접두어가 전달일 때만: 전달된 메일에 답한 "Re: Fwd:"는 아래 인용이 옛 메일이다
    expect(quotedHistoryStart(["제목: Fwd: Re: Contract", "", "OK.", "", "> old"].join("\n"))).toBeNull();
    expect(quotedHistoryStart(["제목: Re: Fwd: Contract", "", "OK.", "", "> old"].join("\n"))).not.toBeNull();
    expect(quotedHistoryStart(["제목: Re: Contract", "", "OK.", "", "> old"].join("\n"))).not.toBeNull();
  });

  it("From:/보낸 사람: 줄이 있어도 날짜 머리와 제목 머리가 함께 이어지지 않으면 새 글이다 (배송 · 일정 정보)", () => {
    // 영어 일정: 제목 머리가 없다
    expect(quotedHistoryStart(["Flight details:", "", "From: ICN", "To: SFO", "Date: Oct 12", "", "I'll book the hotel by Monday."].join("\n"))).toBeNull();
    // 한국어 배송 정보: 제목 머리가 없다
    expect(quotedHistoryStart(["배송 정보입니다.", "", "보낸 사람: 새벽로지스 물류센터", "받는 사람: 한지우", "날짜: 10월 12일", "", "제가 금요일까지 송장 보내드릴게요."].join("\n"))).toBeNull();
    // 날짜 머리만 있고 제목 머리가 없어도 마찬가지, 반대로 제목 머리만 있어도
    expect(quotedHistoryStart(["Hi,", "", "From: Jordan", "Sent: Monday", "", "Will do."].join("\n"))).toBeNull();
    expect(quotedHistoryStart(["Hi,", "", "From: Jordan", "Subject: Deck", "", "Will do."].join("\n"))).toBeNull();
  });

  it("글 없이 자기 머리 묶음으로 시작하는 메일은 통째로 옛 메일로 보지 않는다 (위에 새로 쓴 글이 있을 때만)", () => {
    const englishHeader = ["제목: Contract", "", "From: Jordan Lee", "Sent: Monday, October 5, 2026", "To: Alex Kim", "Subject: Contract", "", "I will send the signed copy by Friday."].join("\n");
    expect(quotedHistoryStart(englishHeader)).toBeNull();
    const koreanHeader = ["제목: 계약서", "", "보낸 사람: 오세린", "보낸 날짜: 2026년 10월 5일", "받는 사람: 한지우", "제목: 계약서", "", "금요일까지 보내드리겠습니다."].join("\n");
    expect(quotedHistoryStart(koreanHeader)).toBeNull();
    // Original Message로 시작해도 마찬가지
    expect(quotedHistoryStart(["제목: RE: 계약서", "", "-----Original Message-----", "From: Jordan", "Please send it by Monday."].join("\n"))).toBeNull();
    // 위에 새 글이 있으면 인용이다
    expect(quotedHistoryStart(["제목: RE: 계약서", "", "Will do.", "", "-----Original Message-----", "From: Jordan", "Please send it by Monday."].join("\n"))).not.toBeNull();
  });

  it("머리줄 뒤에 `>` 없는 글이 빈 줄로 나뉜 덩어리로 이어지면 아래에 답을 적은 것일 수 있어 새 글로 본다", () => {
    const bottomPost = ["Hi Jordan,", "", "On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <j@x.example> wrote:", "Could you send the deck?", "", "Yes, I will send it by Friday."].join("\n");
    expect(quotedHistoryStart(bottomPost)).toBeNull();
    // 한 덩어리로 끝나면 옛 메일이다
    const oneBlock = ["Hi Jordan,", "", "On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <j@x.example> wrote:", "Could you send the deck?", "Thanks."].join("\n");
    expect(fresh(oneBlock)).toBe("Hi Jordan,\n\n");
  });

  it("줄바꿈이 CRLF여도 위치가 원문 기준이다", () => {
    const mail = "Sure.\r\n\r\nOn Mon, Oct 5, 2026 at 9:30 AM Jordan <j@x.example> wrote:\r\n\r\n> Could you?";
    expect(mail.slice(quotedHistoryStart(mail)!).startsWith("On Mon")).toBe(true);
  });
});
