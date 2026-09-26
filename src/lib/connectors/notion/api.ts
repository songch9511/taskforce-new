import { z } from "zod";

// Notion 공개 API 호출 (https://developers.notion.com). 응답은 필요한 필드만 zod로 검증하고 나머지는 흘려보낸다.
// 속도 제한(429 · 529)은 Retry-After만큼 기다렸다가 다시 부른다.

export const NOTION_API = "https://api.notion.com";
export const NOTION_VERSION = "2026-03-11";

export class NotionError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly code?: string,
  ) {
    super(message);
    this.name = "NotionError";
  }
}

export type NotionFetch = typeof fetch;
type Sleep = (ms: number) => Promise<void>;
const defaultSleep: Sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ─── OAuth ────────────────────────────────────────────────

export const notionTokenSchema = z.object({
  access_token: z.string().min(1),
  refresh_token: z.string().nullish(),
  bot_id: z.string(),
  workspace_id: z.string(),
  workspace_name: z.string().nullish(),
});
export type NotionToken = z.infer<typeof notionTokenSchema>;

export type NotionOAuthConfig = { clientId: string; clientSecret: string; redirectUri: string; fetch?: NotionFetch };

export function authorizeUrl(config: Pick<NotionOAuthConfig, "clientId" | "redirectUri">, state: string): string {
  const url = new URL("/v1/oauth/authorize", NOTION_API);
  url.search = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: config.redirectUri,
    response_type: "code",
    owner: "user",
    state,
  }).toString();
  return url.toString();
}

async function tokenRequest(config: NotionOAuthConfig, body: Record<string, string>): Promise<NotionToken> {
  const response = await (config.fetch ?? fetch)(`${NOTION_API}/v1/oauth/token`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${Buffer.from(`${config.clientId}:${config.clientSecret}`).toString("base64")}`,
      "Content-Type": "application/json",
      "Notion-Version": NOTION_VERSION,
    },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new NotionError(`Notion 토큰 요청 실패 (${response.status})`, response.status);
  const parsed = notionTokenSchema.safeParse(await response.json());
  if (!parsed.success) throw new NotionError("Notion 토큰 응답 형식이 예상과 다릅니다", 502);
  return parsed.data;
}

export function exchangeCode(config: NotionOAuthConfig, code: string): Promise<NotionToken> {
  return tokenRequest(config, { grant_type: "authorization_code", code, redirect_uri: config.redirectUri });
}

export function refreshToken(config: NotionOAuthConfig, refresh: string): Promise<NotionToken> {
  return tokenRequest(config, { grant_type: "refresh_token", refresh_token: refresh });
}

// ─── 읽기 ─────────────────────────────────────────────────

const userSchema = z.looseObject({
  object: z.literal("user"),
  id: z.string(),
  name: z.string().nullish(),
  type: z.string().nullish(),
  person: z.object({ email: z.string().nullish() }).nullish(),
});
export type NotionUser = z.infer<typeof userSchema>;

const propertySchema = z.looseObject({
  type: z.string(),
  title: z.array(z.looseObject({ plain_text: z.string() })).optional(),
  date: z.object({ start: z.string(), end: z.string().nullish() }).nullish(),
  people: z.array(userSchema).optional(),
});

export const pageSchema = z.looseObject({
  object: z.literal("page"),
  id: z.string(),
  url: z.string(),
  created_time: z.string(),
  last_edited_time: z.string(),
  in_trash: z.boolean().optional(),
  archived: z.boolean().optional(),
  parent: z.looseObject({ type: z.string() }),
  properties: z.record(z.string(), propertySchema),
});
export type NotionPage = z.infer<typeof pageSchema>;

const searchResponseSchema = z.object({
  // 페이지가 아닌 결과(데이터 소스 등)는 걸러낸다.
  results: z.array(z.looseObject({ object: z.string() })),
  has_more: z.boolean(),
  next_cursor: z.string().nullish(),
});

const markdownSchema = z.object({ markdown: z.string(), truncated: z.boolean().optional() });

export type NotionClient = {
  /** 최근에 고친 페이지부터 한 쪽씩 */
  searchPages: (cursor?: string) => Promise<{ pages: NotionPage[]; nextCursor: string | null }>;
  pageMarkdown: (pageId: string) => Promise<{ markdown: string; truncated: boolean }>;
  user: (userId: string) => Promise<NotionUser | null>;
};

export function notionClient(accessToken: string, options: { fetch?: NotionFetch; sleep?: Sleep; maxRetries?: number } = {}): NotionClient {
  const doFetch = options.fetch ?? fetch;
  const sleep = options.sleep ?? defaultSleep;
  const maxRetries = options.maxRetries ?? 3;

  async function call(path: string, init: { method: "GET" | "POST"; body?: unknown }): Promise<unknown> {
    for (let attempt = 0; ; attempt++) {
      const response = await doFetch(`${NOTION_API}${path}`, {
        method: init.method,
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Notion-Version": NOTION_VERSION,
          ...(init.body ? { "Content-Type": "application/json" } : {}),
        },
        body: init.body ? JSON.stringify(init.body) : undefined,
      });
      if ((response.status === 429 || response.status === 529) && attempt < maxRetries) {
        const seconds = Number(response.headers.get("retry-after")) || 2 ** attempt;
        await sleep(Math.min(seconds, 30) * 1000);
        continue;
      }
      if (!response.ok) {
        const body = (await response.json().catch(() => ({}))) as { code?: string };
        throw new NotionError(`Notion API 요청 실패 (${response.status} ${body.code ?? ""})`.trim(), response.status, body.code);
      }
      return response.json();
    }
  }

  return {
    async searchPages(cursor) {
      const body = searchResponseSchema.parse(
        await call("/v1/search", {
          method: "POST",
          body: {
            filter: { property: "object", value: "page" },
            sort: { timestamp: "last_edited_time", direction: "descending" },
            page_size: 50,
            ...(cursor ? { start_cursor: cursor } : {}),
          },
        }),
      );
      const pages = body.results.flatMap((result) => {
        const page = pageSchema.safeParse(result);
        return page.success ? [page.data] : [];
      });
      return { pages, nextCursor: body.has_more ? (body.next_cursor ?? null) : null };
    },

    async pageMarkdown(pageId) {
      const body = markdownSchema.parse(await call(`/v1/pages/${encodeURIComponent(pageId)}/markdown`, { method: "GET" }));
      return { markdown: body.markdown, truncated: body.truncated ?? false };
    },

    async user(userId) {
      try {
        return userSchema.parse(await call(`/v1/users/${encodeURIComponent(userId)}`, { method: "GET" }));
      } catch (error) {
        // 사용자 정보 권한이 없거나 워크스페이스를 떠난 사람
        if (error instanceof NotionError && (error.status === 403 || error.status === 404)) return null;
        throw error;
      }
    },
  };
}
