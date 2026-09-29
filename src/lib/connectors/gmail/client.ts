import { z } from "zod";

import { GoogleApiError, googleErrorReason, type GoogleAccess } from "../google/token";

// Gmail API 호출 (읽기만, gmail.readonly). 응답은 zod로 확인한다. 본문 · 주소는 로그에 남기지 않는다.
// fields로 받을 필드를 좁힌다: 머리글 읽기는 snippet(본문 앞부분)도 받지 않는다 (거른 메일의 본문은 서버로 오지 않는다, 2-6).

const GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me";

/** 거르기 · 관련자에 쓰는 머리글만 받는다 (2-6 머리글 읽기) */
export const METADATA_HEADERS = [
  "From",
  "To",
  "Cc",
  "Subject",
  "Date",
  "Message-ID",
  "List-Id",
  "List-Unsubscribe",
  "Precedence",
  "Auto-Submitted",
  "Sender",
  "Content-Type",
  "Content-Class",
] as const;

export type GmailPart = {
  mimeType?: string;
  filename?: string;
  headers?: { name: string; value: string }[];
  body?: { data?: string; attachmentId?: string; size?: number };
  parts?: GmailPart[];
};

const headerSchema = z.object({ name: z.string(), value: z.string() });
const partSchema: z.ZodType<GmailPart> = z.lazy(() =>
  z.object({
    mimeType: z.string().optional(),
    filename: z.string().optional(),
    headers: z.array(headerSchema).optional(),
    body: z.object({ data: z.string().optional(), attachmentId: z.string().optional(), size: z.number().optional() }).optional(),
    parts: z.array(partSchema).optional(),
  }),
);

const listSchema = z.object({
  messages: z.array(z.object({ id: z.string().min(1), threadId: z.string().min(1) })).optional(),
  nextPageToken: z.string().optional(),
});

const metadataSchema = z.object({
  id: z.string().min(1),
  threadId: z.string().min(1),
  labelIds: z.array(z.string()).optional(),
  internalDate: z.string().regex(/^\d+$/),
  payload: z.object({ headers: z.array(headerSchema).optional() }).optional(),
});

const messageSchema = metadataSchema.extend({ payload: partSchema });

export type GmailMessageRef = { id: string; threadId: string };

/** 메일 한 통의 머리글. headers는 소문자 이름 → 값 (같은 이름이 여럿이면 ", "로 잇는다) */
export type GmailMetadata = { id: string; threadId: string; labelIds: string[]; internalDate: number; headers: Record<string, string> };
export type GmailMessage = GmailMetadata & { payload: GmailPart };

export type GmailClient = {
  /** 검색어(q)에 맞는 메일 id 한 쪽 (최대 500). 스팸 · 휴지통은 빠진다 */
  listMessages: (query: string, pageToken?: string) => Promise<{ messages: GmailMessageRef[]; nextPageToken: string | null }>;
  /** 머리글 · 라벨만 (format=metadata). 그 사이 지워졌으면 null */
  metadata: (id: string) => Promise<GmailMetadata | null>;
  /** 본문까지 (format=full). 그 사이 지워졌으면 null */
  message: (id: string) => Promise<GmailMessage | null>;
};

export function headerMap(headers: { name: string; value: string }[] | undefined): Record<string, string> {
  const map: Record<string, string> = {};
  for (const { name, value } of headers ?? []) {
    const key = name.toLowerCase();
    map[key] = map[key] === undefined ? value : `${map[key]}, ${value}`;
  }
  return map;
}

export function gmailClient(access: GoogleAccess): GmailClient {
  async function call<T>(path: string, params: [string, string][], schema: z.ZodType<T>, options: { notFound?: "null" } = {}): Promise<T | null> {
    const url = `${GMAIL_API}${path}?${new URLSearchParams(params).toString()}`;
    const response = await access.get(url);
    if (response.status === 404 && options.notFound === "null") return null;
    if (!response.ok) {
      const reason = await googleErrorReason(response);
      throw new GoogleApiError(`Gmail 요청 실패 (${response.status}${reason ? ` ${reason}` : ""})`, response.status, reason);
    }
    // 결과가 없으면 fields가 모든 필드를 걸러 204(본문 없음)로 온다 (빈 창의 messages.list)
    const body = response.status === 204 ? {} : await response.json().catch(() => null);
    const parsed = schema.safeParse(body);
    if (!parsed.success) throw new GoogleApiError("Gmail 응답 형식이 예상과 다릅니다", 502, "bad_response");
    return parsed.data;
  }

  const metadataOf = (m: z.infer<typeof metadataSchema>): GmailMetadata => ({
    id: m.id,
    threadId: m.threadId,
    labelIds: m.labelIds ?? [],
    internalDate: Number(m.internalDate),
    headers: headerMap(m.payload?.headers),
  });

  return {
    listMessages: async (query, pageToken) => {
      const params: [string, string][] = [
        ["q", query],
        ["maxResults", "500"],
        ["fields", "messages(id,threadId),nextPageToken"],
      ];
      if (pageToken) params.push(["pageToken", pageToken]);
      const data = (await call("/messages", params, listSchema))!;
      return { messages: data.messages ?? [], nextPageToken: data.nextPageToken ?? null };
    },
    metadata: async (id) => {
      const params: [string, string][] = [
        ["format", "metadata"],
        ...METADATA_HEADERS.map((h): [string, string] => ["metadataHeaders", h]),
        ["fields", "id,threadId,labelIds,internalDate,payload/headers"],
      ];
      const data = await call(`/messages/${encodeURIComponent(id)}`, params, metadataSchema, { notFound: "null" });
      return data ? metadataOf(data) : null;
    },
    message: async (id) => {
      const params: [string, string][] = [
        ["format", "full"],
        ["fields", "id,threadId,labelIds,internalDate,payload"],
      ];
      const data = await call(`/messages/${encodeURIComponent(id)}`, params, messageSchema, { notFound: "null" });
      return data ? { ...metadataOf(data), payload: data.payload } : null;
    },
  };
}
