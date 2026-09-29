import type { ParticipantsInput } from "@/lib/api/contract";

import type { IngestItem } from "../types";

import { headerMap, type GmailMessage, type GmailPart } from "./client";
import { decodeCharset, decodeEncodedWords, headerParam, parseAddressList, storableText } from "./mime";

// 메일 한 통 → 원문 (G6, docs/go-live/google-integration.md 2-6 본문 받기 · 본문 형식). 순수 함수다.
// 본문은 보낸 그대로(메일 앱이 붙인 이전 메일 인용 포함) 쓰고 2만 자에서 자른다. 첨부는 읽지 않는다.
// 보낸 사람 · 받는 사람은 본문이 아니라 participants로 넘긴다 (화자 이름표 읽기가 머리글을 이름표로 오해하지 않게).

/** 본문 상한 (인용된 옛 메일이 길게 이어지는 스레드의 비용 상한). 원문 한도(20만 자)보다 작다 */
export const MAX_EMAIL_BODY = 20_000;
const MAX_TITLE = 200;
const MAX_LIST = 100;
/** 글로 바꾸기 전에 자르는 길이 (몇 MB짜리 HTML을 통째로 정규식에 넣지 않게). 2만 자 본문에 충분하다 */
const MAX_PART_CHARS = 200_000;

const isAttachment = (part: GmailPart) =>
  Boolean(part.filename) || /^\s*attachment\b/i.test(headerMap(part.headers)["content-disposition"] ?? "") || Boolean(part.body?.attachmentId);

/** 본문 글 부분 (첨부 · 전달된 메일 파일은 빼고). 깊이 우선으로 모은다 */
function textParts(part: GmailPart, found: { plain: GmailPart[]; html: GmailPart[] }): void {
  if (isAttachment(part)) return;
  const mime = (part.mimeType ?? "").toLowerCase();
  if (mime.startsWith("multipart/")) {
    for (const child of part.parts ?? []) textParts(child, found);
  } else if (mime === "text/plain" && part.body?.data) {
    found.plain.push(part);
  } else if (mime === "text/html" && part.body?.data) {
    found.html.push(part);
  }
}

function decodePart(part: GmailPart): string {
  const charset = headerParam(headerMap(part.headers)["content-type"], "charset");
  return decodeCharset(Uint8Array.from(Buffer.from(part.body?.data ?? "", "base64url")), charset);
}

const ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  middot: "·",
  hellip: "…",
  mdash: "—",
  ndash: "–",
  lsquo: "‘",
  rsquo: "’",
  ldquo: "“",
  rdquo: "”",
  copy: "©",
};

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (entity, body: string) => {
    if (body[0] === "#") {
      const code = body[1].toLowerCase() === "x" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity;
    }
    return ENTITIES[body.toLowerCase()] ?? entity;
  });
}

const stripTags = (html: string) => html.replace(/<[^>]*>/g, "");

const QUOTE_OPEN = "\u0001";
const QUOTE_CLOSE = "\u0002";

/** 줄을 나누는 태그 (앞 줄에 글이 있을 때만 새 줄. Gmail 편집기는 첫 줄 뒤의 줄을 <div>로 감싼다) */
const LINE_TAGS = new Set(["div", "li", "tr", "dd", "dt", "section", "article", "header", "footer", "center", "address"]);
/** 문단 태그 (앞뒤에 빈 줄 하나) */
const PARAGRAPH_TAGS = new Set(["p", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul", "ol", "pre", "hr"]);

/**
 * HTML 본문 → 글 (text/plain 부분이 없을 때만). 태그 · 스타일 · 스크립트를 지우고, 브라우저가 보이는 대로 줄을 나누고,
 * 링크는 `글 (주소)`로. 인용(blockquote)은 줄마다 `> `를 붙인다 (text/plain 메일의 인용 모양과 같게).
 */
export function htmlToText(html: string): string {
  const cleaned = html
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<(head|style|script|title)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "")
    .replace(/<a\b[^>]*?\bhref\s*=\s*(["'])(.*?)\1[^>]*>([\s\S]*?)<\/a\s*>/gi, (_, _q, href: string, inner: string) => {
      const label = stripTags(inner).replace(/\s+/g, " ").trim();
      const url = decodeEntities(href).trim();
      // 이미지만 있는 링크(버튼 · 추적 이미지)는 버리고, 메일 주소 · 글과 같은 주소는 글만 남긴다 (글자 참조는 아래에서 한꺼번에 푼다)
      if (!label) return "";
      return /^https?:\/\//i.test(url) && decodeEntities(label) !== url ? `${label} (${href.trim()})` : label;
    });

  let out = "";
  const atLineStart = () => out === "" || out.endsWith("\n");
  const newLine = () => {
    if (!atLineStart()) out += "\n";
  };
  const blankLine = () => {
    newLine();
    if (out !== "" && !out.endsWith("\n\n")) out += "\n";
  };
  for (const part of cleaned.split(/(<[^>]*>)/)) {
    const tag = part.match(/^<\s*(\/)?\s*([a-z][a-z0-9]*)/i);
    if (!tag) {
      if (!part.startsWith("<")) {
        const text = decodeEntities(part).replace(/[ \t\r\n\f\u00a0]+/g, " ");
        out += atLineStart() ? text.trimStart() : text;
      }
      continue;
    }
    const [, closing, rawName] = tag;
    const name = rawName.toLowerCase();
    if (name === "br") out += "\n";
    else if (name === "blockquote") {
      newLine();
      out += `${closing ? QUOTE_CLOSE : QUOTE_OPEN}\n`;
    } else if (LINE_TAGS.has(name)) newLine();
    else if (PARAGRAPH_TAGS.has(name)) blankLine();
    else if (closing && (name === "td" || name === "th")) out += " ";
  }

  const lines: string[] = [];
  let depth = 0;
  for (const raw of out.split("\n")) {
    const line = raw.trim();
    if (line === QUOTE_OPEN) depth++;
    else if (line === QUOTE_CLOSE) depth = Math.max(0, depth - 1);
    else lines.push(depth > 0 ? `${"> ".repeat(depth)}${line}`.trimEnd() : line);
  }
  return lines.join("\n");
}

/** 줄 끝 공백을 지우고, 빈 줄은 두 줄까지, 앞뒤 빈 줄은 지운다 */
export function normalizeBody(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    .replace(/﻿/g, "")
    .split("\n")
    .map((line) => line.trimEnd())
    .join("\n")
    .replace(/\n{4,}/g, "\n\n\n")
    .replace(/^\n+|\n+$/g, "");
}

/** 메일 본문 (text/plain을 먼저, 없으면 text/html을 글로) */
export function messageBody(payload: GmailPart): string {
  const found = { plain: [] as GmailPart[], html: [] as GmailPart[] };
  textParts(payload, found);
  const decoded = (part: GmailPart) => decodePart(part).slice(0, MAX_PART_CHARS);
  const text = found.plain.length > 0 ? found.plain.map(decoded).join("\n\n") : found.html.map((part) => htmlToText(decoded(part))).join("\n\n");
  return normalizeBody(text);
}

/**
 * Gmail 웹에서 그 스레드를 여는 주소. Gmail API 문서에 공식 형식은 없다 (9장). authuser로 여러 계정에 로그인한 브라우저에서도
 * 연결한 계정의 메일함을 연다.
 */
export function gmailThreadUrl(threadId: string, accountEmail: string | null): string {
  const account = accountEmail ? `?authuser=${encodeURIComponent(accountEmail)}` : "";
  return `https://mail.google.com/mail/${account}#all/${encodeURIComponent(threadId)}`;
}

function participantsOf(headers: Record<string, string>): ParticipantsInput | undefined {
  const [from] = parseAddressList(headers.from);
  const to = parseAddressList(headers.to).slice(0, MAX_LIST);
  const cc = parseAddressList(headers.cc).slice(0, MAX_LIST);
  const participants: ParticipantsInput = {
    ...(from ? { from } : {}),
    ...(to.length > 0 ? { to } : {}),
    ...(cc.length > 0 ? { cc } : {}),
  };
  return Object.keys(participants).length > 0 ? participants : undefined;
}

export function messageToItem(message: GmailMessage, accountEmail: string | null): IngestItem {
  const subject = decodeEncodedWords(message.headers.subject ?? "").replace(/\s+/g, " ").trim();
  // 자른 끝에 서로게이트 반쪽이 남지 않게 한 번 더 (글자 참조로 들어온 것도)
  const body = storableText(messageBody(message.payload).slice(0, MAX_EMAIL_BODY).trimEnd());
  const at = new Date(message.internalDate);
  return {
    externalId: message.id,
    // 메일은 고쳐지지 않는다
    externalVersion: "1",
    kind: "email",
    title: subject ? storableText(subject.slice(0, MAX_TITLE)) : null,
    text: `제목: ${subject || "(제목 없음)"}${body ? `\n\n${body}` : ""}`,
    occurredAt: at,
    lastEditedAt: at,
    externalUrl: gmailThreadUrl(message.threadId, accountEmail),
    participants: participantsOf(message.headers),
    // 메일에는 인용된 남의 글이 섞인다: "직접 쓴 문서" 질문을 쓰지 않는다
    writtenByMe: null,
  };
}
