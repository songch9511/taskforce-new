import { describe, expect, it } from "vitest";

import type { GmailMessage, GmailPart } from "./client";
import { gmailThreadUrl, htmlToText, MAX_EMAIL_BODY, messageBody, messageToItem, normalizeBody } from "./message";

// 메일 한 통 → 원문 (G6, docs/go-live/google-integration.md 2-6 본문 받기 · 본문 형식 · 관련자 · 원본 링크).

const INTERNAL_DATE = Date.parse("2026-10-05T16:45:00.000Z");

const base64url = (data: string | Uint8Array) => Buffer.from(data).toString("base64url");

/** 글 부분 하나 (Gmail API format=full의 payload 모양) */
function textPart(mimeType: "text/plain" | "text/html", text: string, extra: Partial<GmailPart> = {}): GmailPart {
  return {
    mimeType,
    filename: "",
    headers: [{ name: "Content-Type", value: `${mimeType}; charset="UTF-8"` }],
    body: { data: base64url(text), size: text.length },
    ...extra,
  };
}

const multipart = (mimeType: string, parts: GmailPart[]): GmailPart => ({ mimeType, filename: "", headers: [], body: { size: 0 }, parts });

function message(payload: GmailPart, headers: Record<string, string> = {}): GmailMessage {
  return {
    id: "18c0ffee",
    threadId: "thread-1",
    labelIds: ["INBOX"],
    internalDate: INTERNAL_DATE,
    headers: { from: "Jordan Lee <jordan@example.com>", to: "me@company.dev", subject: "Hello", ...headers },
    payload,
  };
}

/** 문서 2-6의 본문 형식 예: Gmail이 보낸 답장 (text/plain + text/html) */
const GMAIL_REPLY_PLAIN = [
  "Sure, I'll send it by Monday.",
  "",
  "Alex",
  "",
  "On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <jordan@example.com> wrote:",
  "> Could you send the signed contract by Monday?",
  "",
].join("\r\n");
const GMAIL_REPLY_HTML =
  '<div dir="ltr">Sure, I&#39;ll send it by Monday.<div><br></div><div>Alex</div></div><br>' +
  '<div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee &lt;<a href="mailto:jordan@example.com">jordan@example.com</a>&gt; wrote:<br></div>' +
  '<blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"><div dir="ltr">Could you send the signed contract by Monday?</div></blockquote></div>\r\n';

const gmailReply = () =>
  message(multipart("multipart/alternative", [textPart("text/plain", GMAIL_REPLY_PLAIN), textPart("text/html", GMAIL_REPLY_HTML)]), {
    from: "Alex Kim <me@company.dev>",
    to: "Jordan Lee <jordan@example.com>",
    cc: "legal@acme.io",
    subject: "RE: Signed contract",
  });

describe("messageToItem: Postgres가 받지 않는 글자", () => {
  // 하나라도 남으면 원문 저장이 실패하고 그 메일이 든 창에서 동기화가 멈춘다
  const storable = (text: string) => !text.includes("\u0000") && text.isWellFormed();

  it("본문 · 제목 · 관련자 이름의 NUL을 뺀다", () => {
    const item = messageToItem(message(textPart("text/plain", "Please\u0000 review"), { subject: "Hi\u0000 there", from: "Jor\u0000dan <jordan@example.com>" }), null);
    expect(item.text).toBe("제목: Hi there\n\nPlease review");
    expect(item.title).toBe("Hi there");
    expect(item.participants?.from).toEqual({ name: "Jordan", email: "jordan@example.com" });
  });

  it("2만 자 · 제목 200자에서 자를 때 이모지를 반으로 가르지 않는다(반쪽은 U+FFFD)", () => {
    const body = `${"a".repeat(MAX_EMAIL_BODY - 1)}😀 tail`;
    const item = messageToItem(message(textPart("text/plain", body), { subject: `${"s".repeat(199)}😀` }), null);
    expect(storable(item.text)).toBe(true);
    expect(storable(item.title!)).toBe(true);
  });

  it("짝이 없는 서로게이트 글자 참조(&#xD800;)도 저장할 수 있는 글자로", () => {
    const item = messageToItem(message(textPart("text/html", "<p>Broken &#xD800; ref</p>")), null);
    expect(storable(item.text)).toBe(true);
  });
});

describe("messageToItem", () => {
  it("문서의 본문 형식 그대로: 머리줄은 제목만, 빈 줄, 메일 앱이 쓴 본문(인용 포함)", () => {
    const item = messageToItem(gmailReply(), "me@company.dev");
    expect(item.text).toBe(
      "제목: RE: Signed contract\n" +
        "\n" +
        "Sure, I'll send it by Monday.\n" +
        "\n" +
        "Alex\n" +
        "\n" +
        "On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <jordan@example.com> wrote:\n" +
        "> Could you send the signed contract by Monday?",
    );
  });

  it("종류 · 버전 · 시각 · 관련자 · 원본 링크 · writtenByMe", () => {
    const at = new Date(INTERNAL_DATE);
    expect(messageToItem(gmailReply(), "me@company.dev")).toEqual({
      externalId: "18c0ffee",
      externalVersion: "1",
      kind: "email",
      title: "RE: Signed contract",
      text: expect.any(String),
      occurredAt: at,
      lastEditedAt: at,
      externalUrl: "https://mail.google.com/mail/?authuser=me%40company.dev#all/thread-1",
      participants: {
        from: { name: "Alex Kim", email: "me@company.dev" },
        to: [{ name: "Jordan Lee", email: "jordan@example.com" }],
        cc: [{ email: "legal@acme.io" }],
      },
      writtenByMe: null,
    });
  });

  it("보낸 사람 · 받는 사람 줄은 본문에 넣지 않는다", () => {
    const { text } = messageToItem(gmailReply(), "me@company.dev");
    expect(text).not.toMatch(/^(From|To|보낸 ?사람|받는 ?사람):/m);
  });

  it("제목이 없거나 공백뿐이면 `제목: (제목 없음)`, title은 null", () => {
    const plain = textPart("text/plain", "OK");
    for (const subject of ["", "   "]) {
      const item = messageToItem(message(plain, { subject }), null);
      expect(item.text).toBe("제목: (제목 없음)\n\nOK");
      expect(item.title).toBeNull();
    }
    const withoutSubject: Record<string, string> = { ...message(plain).headers };
    delete withoutSubject.subject;
    expect(messageToItem({ ...message(plain), headers: withoutSubject }, null).title).toBeNull();
  });

  it("제목의 인코딩 낱말을 풀고 공백을 하나로", () => {
    const item = messageToItem(message(textPart("text/plain", "OK"), { subject: "RE:  =?UTF-8?B?7JWI64WV?=\r\n\tworld" }), null);
    expect(item.title).toBe("RE: 안녕 world");
    expect(item.text).toBe("제목: RE: 안녕 world\n\nOK");
  });

  it("title은 200자에서 자른다", () => {
    const subject = "가".repeat(250);
    const item = messageToItem(message(textPart("text/plain", "OK"), { subject }), null);
    expect(item.title).toBe("가".repeat(200));
  });

  it("본문은 2만 자에서 자른다", () => {
    expect(MAX_EMAIL_BODY).toBe(20_000);
    const item = messageToItem(message(textPart("text/plain", "a".repeat(25_000)), { subject: "Long" }), null);
    expect(item.text).toBe(`제목: Long\n\n${"a".repeat(20_000)}`);
  });

  it("본문이 비면 제목 줄만", () => {
    expect(messageToItem(message(textPart("text/plain", "\r\n  \r\n")), null).text).toBe("제목: Hello");
    expect(messageToItem(message(multipart("multipart/mixed", [])), null).text).toBe("제목: Hello");
  });

  it("관련자는 있는 것만 남기고, 하나도 없으면 뺀다", () => {
    const onlyFrom = messageToItem({ ...message(textPart("text/plain", "OK")), headers: { from: "jordan@example.com", subject: "x" } }, null);
    expect(onlyFrom.participants).toEqual({ from: { email: "jordan@example.com" } });
    const none = messageToItem({ ...message(textPart("text/plain", "OK")), headers: { subject: "x", to: "undisclosed-recipients:;" } }, null);
    expect(none.participants).toBeUndefined();
  });

  it("받는 사람은 100명까지", () => {
    const to = Array.from({ length: 120 }, (_, i) => `p${i}@example.com`).join(", ");
    expect(messageToItem(message(textPart("text/plain", "OK"), { to }), null).participants?.to).toHaveLength(100);
  });
});

describe("gmailThreadUrl", () => {
  it("연결한 주소를 authuser로 (인코딩), 없으면 authuser 없이", () => {
    expect(gmailThreadUrl("thread-1", "me+work@company.dev")).toBe("https://mail.google.com/mail/?authuser=me%2Bwork%40company.dev#all/thread-1");
    expect(gmailThreadUrl("thread-1", null)).toBe("https://mail.google.com/mail/#all/thread-1");
  });
});

describe("messageBody", () => {
  it("multipart/alternative에서 text/plain을 먼저 쓴다", () => {
    const payload = multipart("multipart/alternative", [textPart("text/html", "<p>From HTML</p>"), textPart("text/plain", "From plain")]);
    expect(messageBody(payload)).toBe("From plain");
  });

  it("text/plain이 없으면(또는 비었으면) text/html을 글로 바꾼다", () => {
    expect(messageBody(multipart("multipart/alternative", [textPart("text/html", "<p>Hello <b>there</b></p>")]))).toBe("Hello there");
    const emptyPlain = textPart("text/plain", "", { body: { size: 0 } });
    expect(messageBody(multipart("multipart/alternative", [emptyPlain, textPart("text/html", "<div>Only HTML</div>")]))).toBe("Only HTML");
  });

  it("한 부분짜리 메일(payload가 바로 text/plain)", () => {
    expect(messageBody(textPart("text/plain", "Single part"))).toBe("Single part");
  });

  it("multipart/mixed의 첨부(파일 이름이 있는 부분)는 읽지 않는다 (글 파일이어도)", () => {
    const payload = multipart("multipart/mixed", [
      multipart("multipart/alternative", [textPart("text/plain", "See attached."), textPart("text/html", "<p>See attached.</p>")]),
      { mimeType: "application/pdf", filename: "contract.pdf", headers: [], body: { attachmentId: "att-1", size: 12_345 } },
      textPart("text/plain", "SECRET NOTES FROM FILE", { filename: "notes.txt" }),
    ]);
    expect(messageBody(payload)).toBe("See attached.");
  });

  it("Content-Disposition: attachment인 부분은 파일 이름이 없어도 읽지 않는다", () => {
    const attached = textPart("text/plain", "ATTACHED BODY", {
      headers: [
        { name: "Content-Type", value: "text/plain" },
        { name: "Content-Disposition", value: "attachment" },
      ],
    });
    expect(messageBody(multipart("multipart/mixed", [textPart("text/plain", "Main"), attached]))).toBe("Main");
  });

  it("body.attachmentId가 있는 부분은 읽지 않는다", () => {
    const large = textPart("text/plain", "LARGE PART", { body: { data: base64url("LARGE PART"), attachmentId: "att-2", size: 10 } });
    expect(messageBody(multipart("multipart/mixed", [textPart("text/plain", "Main"), large]))).toBe("Main");
  });

  it("본문 글 부분이 여럿이면 빈 줄로 잇는다", () => {
    expect(messageBody(multipart("multipart/mixed", [textPart("text/plain", "First"), textPart("text/plain", "Second")]))).toBe("First\n\nSecond");
  });

  it("Content-Type의 문자 집합(EUC-KR)으로 푼다", () => {
    const euckr = Uint8Array.from(Buffer.from("bec8b3e7c7cfbcbcbfe4", "hex")); // 안녕하세요
    const part: GmailPart = {
      mimeType: "text/plain",
      headers: [{ name: "content-type", value: 'text/plain; charset="EUC-KR"' }],
      body: { data: base64url(euckr), size: euckr.length },
    };
    expect(messageBody(multipart("multipart/alternative", [part]))).toBe("안녕하세요");
  });

  it("MIME 형식 이름의 대소문자는 가리지 않는다", () => {
    expect(messageBody(textPart("text/plain", "Upper", { mimeType: "TEXT/PLAIN" } as Partial<GmailPart>))).toBe("Upper");
  });

  it("HTML만 있는 Gmail 답장도 인용 줄(> …)과 보낸 사람 줄을 살린다", () => {
    const body = messageBody(multipart("multipart/alternative", [textPart("text/html", GMAIL_REPLY_HTML)]));
    const lines = body.split("\n");
    expect(lines[0]).toBe("Sure, I'll send it by Monday.");
    expect(lines).toContain("Alex");
    expect(lines).toContain("On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <jordan@example.com> wrote:");
    expect(lines).toContain("> Could you send the signed contract by Monday?");
  });
});

describe("htmlToText", () => {
  const text = (html: string) => normalizeBody(htmlToText(html));

  it("head · title · style · script · 주석을 지운다", () => {
    const html =
      "<html><head><title>Newsletter</title><style>p { color: red; }</style></head>" +
      "<body><script type=\"text/javascript\">alert('x')</script><!-- tracking --><p>Hello</p></body></html>";
    expect(text(html)).toBe("Hello");
  });

  it("br · p · div는 줄을 바꾼다", () => {
    expect(text("Hi Alex,<br>See below.<br/><p>First para</p><p>Second para</p>")).toBe("Hi Alex,\nSee below.\n\nFirst para\n\nSecond para");
    expect(text("<div>Line one</div><div>Line two</div>")).toBe("Line one\nLine two");
  });

  it("Gmail 편집기 모양(첫 줄 뒤에 <div>로 이어지는 줄)도 줄을 나눈다", () => {
    // Gmail · 많은 편집기는 첫 줄을 바깥 div에 바로 두고, 다음 줄부터 <div>로 감싼다
    expect(text('<div dir="ltr">Line one<div>Line two</div></div>')).toBe("Line one\nLine two");
  });

  it("Gmail 답장 HTML: 빈 줄 div는 빈 줄 하나, 인용 머리줄 뒤 blockquote는 `> `, 인용 끝에 빈 `>` 줄이 남지 않는다", () => {
    const html =
      '<div dir="ltr">Sure, I\'ll send it by Monday.<div><br></div><div>Alex</div></div><br>' +
      '<div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, Oct 5, 2026 at 9:30 AM Jordan Lee &lt;<a href="mailto:jordan@example.com">jordan@example.com</a>&gt; wrote:<br></div>' +
      '<blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex">Could you send the signed contract by Monday?<br></blockquote></div>';
    expect(text(html)).toBe(
      "Sure, I'll send it by Monday.\n\nAlex\n\nOn Mon, Oct 5, 2026 at 9:30 AM Jordan Lee <jordan@example.com> wrote:\n> Could you send the signed contract by Monday?",
    );
  });

  it("글자 참조를 푼다 (이름 · 10진 · 16진, 모르는 이름은 그대로)", () => {
    expect(text("Tom &amp; Jerry &lt;3 &quot;hi&quot; &#39;x&#39; &#x2014; &hellip;&nbsp;end &unknown;")).toBe(`Tom & Jerry <3 "hi" 'x' — … end &unknown;`);
  });

  it("링크는 `글 (주소)`, 메일 주소 링크 · 주소와 같은 글은 글만, 이미지만 있는 링크는 버린다", () => {
    expect(text('Read <a href="https://example.com/doc?a=1&amp;b=2" target="_blank">the doc</a>.')).toBe("Read the doc (https://example.com/doc?a=1&b=2).");
    expect(text("<a href='mailto:jordan@example.com'>Email Jordan</a>")).toBe("Email Jordan");
    expect(text('<a href="https://example.com">https://example.com</a>')).toBe("https://example.com");
    expect(text('Before<a href="https://t.example/c"><img src="https://t.example/p.png" alt=""></a>After')).toBe("BeforeAfter");
  });

  it("blockquote 줄에 `> `를 붙이고, 겹친 인용은 `> > `", () => {
    const lines = text("<p>Reply</p><blockquote>Level one<blockquote>Level two</blockquote></blockquote><p>After</p>").split("\n");
    expect(lines[0]).toBe("Reply");
    const one = lines.indexOf("> Level one");
    const two = lines.indexOf("> > Level two");
    expect(one).toBeGreaterThan(0);
    expect(two).toBeGreaterThan(one);
    // 인용이 끝나면 다시 표시 없이
    expect(lines.at(-1)).toBe("After");
  });

  it("연달아 있는 공백 · 탭은 하나로, 줄 앞뒤 공백은 지운다", () => {
    expect(text("<p>  a \t  b  </p>")).toBe("a b");
  });
});

describe("normalizeBody", () => {
  it("CRLF · CR을 LF로, 줄 끝 공백을 지우고, 빈 줄은 두 줄까지, 앞뒤 빈 줄은 지운다", () => {
    expect(normalizeBody("\r\n\r\n  \r\nHello  \r\nWorld\t\r\n\r\n\r\n\r\n\r\nEnd\r\n\r\n")).toBe("Hello\nWorld\n\n\nEnd");
    expect(normalizeBody("a\rb")).toBe("a\nb");
  });

  it("빈 줄 두 줄은 그대로 둔다", () => {
    expect(normalizeBody("a\n\n\nb")).toBe("a\n\n\nb");
  });

  it("BOM은 지우고 첫 줄의 들여쓰기는 둔다", () => {
    expect(normalizeBody("﻿  indented\n")).toBe("  indented");
  });
});
