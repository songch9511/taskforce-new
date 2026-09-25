import { describe, expect, it } from "vitest";

import { handleCreateSource, type CreateSourceDeps, type NewSource } from "./sources";

type User = { id: string };

function setup(user: User | null = { id: "u1" }, insert: () => Promise<string> = async () => "11111111-1111-4111-8111-111111111111") {
  const inserted: NewSource[] = [];
  const scheduled: { sourceId: string; userName?: string }[] = [];
  const deps: CreateSourceDeps<User> = {
    authenticate: async () => user,
    insertSource: async (_user, source) => {
      inserted.push(source);
      return insert();
    },
    schedule: (_user, sourceId, _source, userName) => scheduled.push({ sourceId, userName }),
    now: () => new Date("2026-09-25T01:00:00Z"),
  };
  return { deps, inserted, scheduled };
}

const post = (body: unknown) =>
  new Request("http://localhost/api/v1/sources", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

describe("handleCreateSource", () => {
  it("저장하고 202와 source_id를 돌려준 뒤 파이프라인을 예약한다", async () => {
    const { deps, inserted, scheduled } = setup();
    const response = await handleCreateSource(post({ kind: "meeting", text: "금요일까지 보내드릴게요", user_name: "도윤" }), deps);

    expect(response.status).toBe(202);
    expect(await response.json()).toEqual({ source_id: "11111111-1111-4111-8111-111111111111", status: "pending" });
    expect(inserted).toEqual([
      {
        kind: "meeting",
        raw_text: "금요일까지 보내드릴게요",
        occurred_at: "2026-09-25T01:00:00.000Z",
        title: null,
        external_url: null,
        participants: null,
      },
    ]);
    expect(scheduled).toEqual([{ sourceId: "11111111-1111-4111-8111-111111111111", userName: "도윤" }]);
  });

  it("관련자를 함께 저장한다", async () => {
    const { deps, inserted } = setup();
    const participants = { from: { name: "김대표", email: "ceo@x.com" }, cc: [{ email: "me@x.com" }] };
    await handleCreateSource(post({ kind: "email", text: "제안서 부탁드려요", participants }), deps);
    expect(inserted[0].participants).toEqual(participants);
  });

  it("이름도 이메일도 없는 관련자는 400", async () => {
    const { deps } = setup();
    expect((await handleCreateSource(post({ kind: "email", text: "x", participants: { to: [{}] } }), deps)).status).toBe(400);
  });

  it("로그인하지 않았으면 401", async () => {
    const { deps, inserted } = setup(null);
    const response = await handleCreateSource(post({ kind: "note", text: "a" }), deps);
    expect(response.status).toBe(401);
    expect((await response.json()).error.code).toBe("unauthorized");
    expect(inserted).toEqual([]);
  });

  it("잘못된 본문은 400이고 원문 값을 돌려주지 않는다", async () => {
    const { deps, scheduled } = setup();
    const bad = await handleCreateSource(post({ kind: "chat", text: "비밀 회의록" }), deps);
    expect(bad.status).toBe(400);
    const body = await bad.json();
    expect(body.error.message).toContain("kind");
    expect(JSON.stringify(body)).not.toContain("비밀 회의록");

    expect((await handleCreateSource(post("{not json"), deps)).status).toBe(400);
    expect(scheduled).toEqual([]);
  });

  it("저장에 실패하면 500이고 파이프라인을 돌리지 않는다", async () => {
    const { deps, scheduled } = setup({ id: "u1" }, async () => {
      throw new Error("db down");
    });
    const response = await handleCreateSource(post({ kind: "note", text: "a" }), deps);
    expect(response.status).toBe(500);
    expect(scheduled).toEqual([]);
  });
});
