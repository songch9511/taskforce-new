import { describe, expect, it } from "vitest";

import { authorizeUrl, exchangeCode, notionClient, NotionError, NOTION_VERSION } from "./api";

type Call = { url: string; init: RequestInit };

function fakeFetch(responses: Array<{ status?: number; body?: unknown; headers?: Record<string, string> }>) {
  const calls: Call[] = [];
  let i = 0;
  const fetch = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    const r = responses[Math.min(i++, responses.length - 1)];
    return new Response(JSON.stringify(r.body ?? {}), { status: r.status ?? 200, headers: r.headers });
  }) as typeof globalThis.fetch;
  return { fetch, calls };
}

const page = {
  object: "page",
  id: "p1",
  url: "https://www.notion.so/p1",
  created_time: "2026-09-22T05:00:00.000Z",
  last_edited_time: "2026-09-22T07:20:38.000Z",
  parent: { type: "data_source_id", data_source_id: "ds1" },
  properties: { "Meeting name": { type: "title", title: [{ plain_text: "sft 논의" }] } },
};

describe("Notion OAuth", () => {
  it("권한 요청 주소에 client_id · redirect_uri · state를 담는다", () => {
    const url = new URL(authorizeUrl({ clientId: "cid", redirectUri: "https://x.dev/cb" }, "st"));
    expect(url.pathname).toBe("/v1/oauth/authorize");
    expect(Object.fromEntries(url.searchParams)).toEqual({
      client_id: "cid",
      redirect_uri: "https://x.dev/cb",
      response_type: "code",
      owner: "user",
      state: "st",
    });
  });

  it("code를 Basic 인증으로 토큰과 바꾼다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { access_token: "tok", refresh_token: "ref", bot_id: "b", workspace_id: "w", workspace_name: "WS" } }]);
    const token = await exchangeCode({ clientId: "cid", clientSecret: "sec", redirectUri: "https://x.dev/cb", fetch }, "code1");
    expect(token).toMatchObject({ access_token: "tok", workspace_id: "w" });
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe(`Basic ${Buffer.from("cid:sec").toString("base64")}`);
    expect(JSON.parse(calls[0].init.body as string)).toEqual({ grant_type: "authorization_code", code: "code1", redirect_uri: "https://x.dev/cb" });
  });
});

describe("notionClient", () => {
  it("페이지만 골라 최근 수정순으로 찾고 다음 쪽 커서를 돌려준다", async () => {
    const { fetch, calls } = fakeFetch([{ body: { results: [page, { object: "data_source", id: "ds1" }], has_more: true, next_cursor: "n2" } }]);
    const result = await notionClient("tok", { fetch }).searchPages();
    expect(result.pages.map((p) => p.id)).toEqual(["p1"]);
    expect(result.nextCursor).toBe("n2");
    const headers = calls[0].init.headers as Record<string, string>;
    expect(headers["Notion-Version"]).toBe(NOTION_VERSION);
    expect(JSON.parse(calls[0].init.body as string).sort).toEqual({ timestamp: "last_edited_time", direction: "descending" });
  });

  it("429면 Retry-After만큼 기다렸다가 다시 부른다", async () => {
    const waits: number[] = [];
    const { fetch, calls } = fakeFetch([{ status: 429, headers: { "retry-after": "2" } }, { body: { markdown: "# hi" } }]);
    const md = await notionClient("tok", { fetch, sleep: async (ms) => void waits.push(ms) }).pageMarkdown("p1");
    expect(md).toEqual({ markdown: "# hi", truncated: false });
    expect(waits).toEqual([2000]);
    expect(calls).toHaveLength(2);
  });

  it("401은 상태 코드를 담은 NotionError", async () => {
    const { fetch } = fakeFetch([{ status: 401, body: { code: "unauthorized" } }]);
    const error = await notionClient("tok", { fetch }).pageMarkdown("p1").catch((e) => e);
    expect(error).toBeInstanceOf(NotionError);
    expect(error).toMatchObject({ status: 401, code: "unauthorized" });
  });

  it("사용자 정보 권한이 없으면 사용자는 null", async () => {
    const { fetch } = fakeFetch([{ status: 403, body: { code: "restricted_resource" } }]);
    expect(await notionClient("tok", { fetch }).user("u1")).toBeNull();
  });
});
