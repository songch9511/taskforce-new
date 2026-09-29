import { describe, expect, it, vi } from "vitest";

import { GoogleApiError, type GoogleAccess } from "../google/token";

import { gmailClient, headerMap, METADATA_HEADERS } from "./client";

// Gmail API 호출 (docs/go-live/google-integration.md 2-6 목록 · 머리글 읽기 · 본문 받기). 토큰은 GoogleAccess가 붙인다.

const API = "https://gmail.googleapis.com/gmail/v1/users/me";

/** 부른 주소를 남기고 준비한 응답을 차례로 돌려주는 가짜 GoogleAccess */
function fakeAccess(...responses: Response[]) {
  let calls = 0;
  const get = vi.fn<(url: string) => Promise<Response>>(async () => responses[calls++] ?? new Response("{}", { status: 500 }));
  const access: GoogleAccess = { get };
  const url = (index = 0) => new URL(get.mock.calls[index][0]);
  return { access, get, url };
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
const googleError = (status: number, reason: string) =>
  json({ error: { code: status, message: "…", status: "X", errors: [{ reason, domain: "global", message: "…" }] } }, status);

const metadataBody = {
  id: "m1",
  threadId: "t1",
  labelIds: ["INBOX", "UNREAD"],
  internalDate: "1790000000000",
  payload: {
    headers: [
      { name: "From", value: "Jordan <jordan@example.com>" },
      { name: "Subject", value: "Contract" },
      { name: "List-Id", value: "<team.company.dev>" },
    ],
  },
};

describe("listMessages", () => {
  it("검색어 · 한 쪽 500개 · 필요한 필드만 · 다음 쪽 토큰으로 부른다", async () => {
    const { access, url } = fakeAccess(json({ messages: [{ id: "m2", threadId: "t2" }], nextPageToken: "page-2" }), json({}));
    const client = gmailClient(access);

    const first = await client.listMessages("after:1 before:2 -in:chats");
    const second = await client.listMessages("after:1 before:2 -in:chats", "page-2");

    expect(url(0).origin + url(0).pathname).toBe(`${API}/messages`);
    expect(url(0).searchParams.get("q")).toBe("after:1 before:2 -in:chats");
    expect(url(0).searchParams.get("maxResults")).toBe("500");
    expect(url(0).searchParams.get("fields")).toBe("messages(id,threadId),nextPageToken");
    expect(url(0).searchParams.has("pageToken")).toBe(false);
    expect(url(1).searchParams.get("pageToken")).toBe("page-2");
    expect(first).toEqual({ messages: [{ id: "m2", threadId: "t2" }], nextPageToken: "page-2" });
    // 결과가 없으면 messages가 빠져 온다
    expect(second).toEqual({ messages: [], nextPageToken: null });
  });

  it("결과가 없는 창은 fields가 모두 걸러 204(본문 없음)로 온다: 빈 목록 (dev에서 확인)", async () => {
    const { access } = fakeAccess(new Response(null, { status: 204 }));
    await expect(gmailClient(access).listMessages("q")).resolves.toEqual({ messages: [], nextPageToken: null });
  });

  it("404도 오류로 던진다 (목록에는 null이 없다)", async () => {
    await expect(gmailClient(fakeAccess(googleError(404, "notFound")).access).listMessages("q")).rejects.toMatchObject({ status: 404 });
  });
});

describe("metadata", () => {
  it("format=metadata, 거르기에 쓰는 머리글 하나하나를 metadataHeaders로, snippet 없이 필드를 좁힌다", async () => {
    const { access, url } = fakeAccess(json(metadataBody));
    await gmailClient(access).metadata("m/1");

    expect(url().pathname).toBe("/gmail/v1/users/me/messages/m%2F1");
    expect(url().searchParams.get("format")).toBe("metadata");
    expect(url().searchParams.getAll("metadataHeaders")).toEqual([...METADATA_HEADERS]);
    expect(url().searchParams.get("fields")).toBe("id,threadId,labelIds,internalDate,payload/headers");
    expect(url().searchParams.get("fields")).not.toContain("snippet");
  });

  it("거르기 머리글을 모두 요청한다 (문서 2-6 머리글 읽기)", () => {
    for (const header of ["From", "To", "Cc", "Subject", "Date", "Message-ID", "List-Id", "List-Unsubscribe", "Precedence", "Auto-Submitted", "Sender", "Content-Type"]) {
      expect(METADATA_HEADERS).toContain(header);
    }
  });

  it("라벨 · 받은 시각(숫자) · 소문자 머리글로 돌려준다", async () => {
    const meta = await gmailClient(fakeAccess(json(metadataBody)).access).metadata("m1");
    expect(meta).toEqual({
      id: "m1",
      threadId: "t1",
      labelIds: ["INBOX", "UNREAD"],
      internalDate: 1_790_000_000_000,
      headers: { from: "Jordan <jordan@example.com>", subject: "Contract", "list-id": "<team.company.dev>" },
    });
  });

  it("라벨 · 머리글이 없으면 빈 값", async () => {
    const meta = await gmailClient(fakeAccess(json({ id: "m1", threadId: "t1", internalDate: "1" })).access).metadata("m1");
    expect(meta).toMatchObject({ labelIds: [], headers: {} });
  });

  it("그 사이 지워졌으면(404) null", async () => {
    expect(await gmailClient(fakeAccess(googleError(404, "notFound")).access).metadata("gone")).toBeNull();
  });
});

describe("message", () => {
  it("format=full, snippet 없이 payload까지 받는다", async () => {
    const payload = { mimeType: "text/plain", headers: [{ name: "Subject", value: "Hi" }], body: { data: "SGk", size: 2 } };
    const { access, url } = fakeAccess(json({ ...metadataBody, payload }));
    const message = await gmailClient(access).message("m1");

    expect(url().searchParams.get("format")).toBe("full");
    expect(url().searchParams.get("fields")).toBe("id,threadId,labelIds,internalDate,payload");
    expect(url().searchParams.has("metadataHeaders")).toBe(false);
    expect(message).toMatchObject({ id: "m1", headers: { subject: "Hi" }, payload });
  });

  it("그 사이 지워졌으면(404) null", async () => {
    expect(await gmailClient(fakeAccess(googleError(404, "notFound")).access).message("gone")).toBeNull();
  });
});

describe("오류", () => {
  it("그 밖의 오류는 상태와 이유(errors[0].reason)를 담은 GoogleApiError", async () => {
    const error = await gmailClient(fakeAccess(googleError(429, "rateLimitExceeded")).access)
      .metadata("m1")
      .catch((e: unknown) => e);
    expect(error).toBeInstanceOf(GoogleApiError);
    expect(error).toMatchObject({ status: 429, reason: "rateLimitExceeded" });

    await expect(gmailClient(fakeAccess(googleError(403, "insufficientPermissions")).access).message("m1")).rejects.toMatchObject({
      status: 403,
      reason: "insufficientPermissions",
    });
    await expect(gmailClient(fakeAccess(new Response("Service Unavailable", { status: 503 })).access).listMessages("q")).rejects.toMatchObject({
      name: "GoogleApiError",
      status: 503,
      reason: undefined,
    });
  });

  it("응답 모양이 다르면 502 GoogleApiError", async () => {
    await expect(gmailClient(fakeAccess(json({ id: "m1" })).access).metadata("m1")).rejects.toMatchObject({ name: "GoogleApiError", status: 502 });
    await expect(gmailClient(fakeAccess(json({ ...metadataBody, internalDate: "not-a-number" })).access).metadata("m1")).rejects.toMatchObject({
      status: 502,
    });
    await expect(gmailClient(fakeAccess(new Response("not json")).access).listMessages("q")).rejects.toMatchObject({ status: 502 });
    await expect(gmailClient(fakeAccess(json({ messages: [{ id: "" }] })).access).listMessages("q")).rejects.toMatchObject({ status: 502 });
  });
});

describe("headerMap", () => {
  it("이름은 소문자로, 같은 이름이 여럿이면 `, `로 잇는다", () => {
    expect(
      headerMap([
        { name: "Received", value: "a" },
        { name: "received", value: "b" },
        { name: "Content-Type", value: "text/plain" },
      ]),
    ).toEqual({ received: "a, b", "content-type": "text/plain" });
    expect(headerMap(undefined)).toEqual({});
  });
});
