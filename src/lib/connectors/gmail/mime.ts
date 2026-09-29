import { personSchema } from "@/lib/api/contract";

// 메일 글자 풀기 (순수 함수): 문자 집합, 머리글의 RFC 2047 인코딩, 주소 목록 (docs/go-live/google-integration.md 2-6).

/** TextDecoder가 모르는 이름 → 같은 인코딩의 이름 */
const CHARSET_ALIASES: Record<string, string> = { cp949: "euc-kr", "x-windows-949": "euc-kr", ms949: "euc-kr", utf8: "utf-8" };

/**
 * ISO-2022-KR(7비트 한국어) → EUC-KR 바이트. TextDecoder는 이 인코딩을 풀지 않는다(WHATWG "replacement").
 * SO(0x0E) ~ SI(0x0F) 사이의 두 바이트 글자에 높은 비트를 세우면 EUC-KR이 된다. 지정 순서(ESC $ ) C)는 버린다.
 */
function iso2022krToEucKr(bytes: Uint8Array): Uint8Array {
  const out: number[] = [];
  let shifted = false;
  for (let i = 0; i < bytes.length; i++) {
    const b = bytes[i];
    if (b === 0x1b && bytes[i + 1] === 0x24 && bytes[i + 2] === 0x29 && bytes[i + 3] === 0x43) {
      i += 3;
    } else if (b === 0x0e) {
      shifted = true;
    } else if (b === 0x0f) {
      shifted = false;
    } else {
      if (b === 0x0a || b === 0x0d) shifted = false;
      out.push(shifted && b >= 0x21 && b <= 0x7e ? b | 0x80 : b);
    }
  }
  return Uint8Array.from(out);
}

/**
 * Postgres text · jsonb가 받지 않는 글자를 뺀다: NUL, 짝이 없는 서로게이트(잘린 이모지 · 깨진 글자 참조는 U+FFFD로).
 * 하나라도 남으면 원문 저장이 실패하고, 그 메일이 든 창이 끝나지 않아 동기화가 거기서 멈춘다.
 */
export const storableText = (text: string) => text.replace(/\u0000/g, "").toWellFormed();

/** 바이트를 문자 집합대로 글자로. 모르는 문자 집합이면 UTF-8 */
export function decodeCharset(bytes: Uint8Array, charset: string | null | undefined): string {
  let label = (charset ?? "utf-8").trim().toLowerCase();
  label = CHARSET_ALIASES[label] ?? label;
  if (label === "iso-2022-kr") {
    bytes = iso2022krToEucKr(bytes);
    label = "euc-kr";
  }
  let text: string;
  try {
    text = new TextDecoder(label).decode(bytes);
  } catch {
    text = new TextDecoder("utf-8").decode(bytes);
  }
  return storableText(text);
}

/** Content-Type 등의 매개변수 값 (예: charset). 없으면 null */
export function headerParam(value: string | undefined, name: string): string | null {
  const match = value?.match(new RegExp(`(?:^|;)\\s*${name}\\s*=\\s*(?:"([^"]*)"|([^;\\s]+))`, "i"));
  return match ? (match[1] ?? match[2]) : null;
}

function qDecode(text: string): Uint8Array {
  const bytes: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === "_") bytes.push(0x20);
    else if (c === "=" && /^[0-9a-f]{2}$/i.test(text.slice(i + 1, i + 3))) {
      bytes.push(parseInt(text.slice(i + 1, i + 3), 16));
      i += 2;
    } else bytes.push(c.charCodeAt(0) & 0xff);
  }
  return Uint8Array.from(bytes);
}

/**
 * 머리글의 RFC 2047 인코딩 낱말(=?UTF-8?B?…?= · =?EUC-KR?Q?…?=)을 푼다. Gmail API는 보통 풀어서 주지만, 풀리지 않은 채 오는 경우를 대비한다.
 * 이어진 두 인코딩 낱말 사이의 공백은 버린다 (RFC 2047 6.2).
 */
export function decodeEncodedWords(value: string): string {
  return storableText(value).replace(/=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?=(?:\s+(?==\?[^?\s]+\?[bBqQ]\?))?/g, (_, charset: string, encoding: string, text: string) => {
    const bytes = encoding.toUpperCase() === "B" ? Uint8Array.from(Buffer.from(text, "base64")) : qDecode(text);
    return decodeCharset(bytes, charset.split("*")[0]);
  });
}

export type Address = { name?: string; email?: string };

const EMAIL = /^[^\s@<>()",;:]+@[^\s@<>()",;:]+\.[^\s@<>()",;:]+$/;

function unquote(value: string): string {
  const trimmed = value.trim();
  const inner = trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length >= 2 ? trimmed.slice(1, -1).replace(/\\(.)/g, "$1") : trimmed;
  return inner.replace(/\s+/g, " ").trim();
}

/** 주소 하나: `이름 <주소>`, `"성, 이름" <주소>`, `주소 (이름)`, `주소` */
function parseAddress(raw: string): Address | null {
  let name: string | undefined;
  let email: string | undefined;
  const angle = raw.match(/^([\s\S]*?)<([^<>]*)>\s*(?:\(([^()]*)\))?\s*$/);
  if (angle) {
    name = unquote(angle[1]) || (angle[3] ? unquote(angle[3]) : undefined);
    email = angle[2].trim();
  } else {
    const comment = raw.match(/\(([^()]*)\)/);
    name = comment ? unquote(comment[1]) : undefined;
    email = raw.replace(/\([^()]*\)/g, "").trim();
  }
  email = email && EMAIL.test(email) ? email.toLowerCase() : undefined;
  if (!name || name.toLowerCase() === email) name = undefined;
  const person = { ...(name ? { name: storableText(name.slice(0, 100)) } : {}), ...(email ? { email } : {}) };
  // 관련자 형식(contract personSchema)을 지나지 못하는 주소는 이름만 남긴다
  if (personSchema.safeParse(person).success) return person;
  return person.name ? { name: person.name } : null;
}

/**
 * 주소 목록 머리글(From · To · Cc)을 사람 목록으로. 따옴표 · <> · () 안의 쉼표는 가르지 않는다.
 * 그룹 표기(`팀: a@x.com, b@y.com;` · `undisclosed-recipients:;`)는 그룹 이름을 버리고 주소만 남긴다.
 */
export function parseAddressList(raw: string | undefined): Address[] {
  if (!raw) return [];
  const value = decodeEncodedWords(raw);
  const items: string[] = [];
  let current = "";
  let quoted = false;
  let angle = 0;
  let paren = 0;
  for (let i = 0; i < value.length; i++) {
    const c = value[i];
    if (quoted && c === "\\") {
      current += c + (value[i + 1] ?? "");
      i++;
      continue;
    }
    if (c === '"') quoted = !quoted;
    else if (!quoted) {
      if (c === "<") angle++;
      else if (c === ">") angle = Math.max(0, angle - 1);
      else if (c === "(") paren++;
      else if (c === ")") paren = Math.max(0, paren - 1);
      else if ((c === "," || c === ";") && angle === 0 && paren === 0) {
        items.push(current);
        current = "";
        continue;
      }
    }
    current += c;
  }
  items.push(current);
  return items.flatMap((item) => {
    // 그룹 이름 (콜론 앞에 주소 · 따옴표 · <가 없으면 그룹 표기다)
    const text = item.replace(/^\s*[^"<>@,:]*:\s*/, "").trim();
    if (!text) return [];
    const address = parseAddress(text);
    return address ? [address] : [];
  });
}

/** 머리글의 첫 주소 (소문자). 없으면 null */
export function firstEmail(raw: string | undefined): string | null {
  return parseAddressList(raw).find((a) => a.email)?.email ?? null;
}

/** 주소의 도메인 (소문자) */
export const emailDomain = (email: string) => email.slice(email.lastIndexOf("@") + 1).toLowerCase();
