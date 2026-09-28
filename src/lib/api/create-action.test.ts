import { describe, expect, it, vi } from "vitest";

import type { NewUserAction } from "@/lib/actions/service";

import { apiErrorSchema, createActionResponseSchema, type ActionSummary } from "./contract";
import { handleCreateAction, type CreateActionDeps, type RelatedSource } from "./create-action";

type User = { id: string };

const SOURCE_ID = "2b1c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d";
const MEETING: RelatedSource = { kind: "meeting", raw_text: "민수: 금요일까지 견적서 보내드릴게요.\n지영: 좋아요.", raw_text_purged_at: null };
const VECTOR = [0.1, 0.2, 0.3];
/** 그 구절로 이미 만든 Action (사용자가 끝낸 것) */
const TRACKED: ActionSummary = {
  id: "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f",
  title: "견적서 발송",
  owner: "me",
  status: "done",
  due_date: "2026-10-03",
  counterpart: "지영",
  needs_confirmation: false,
  confirm_reasons: [],
  started_at: null,
  last_activity_at: "2026-09-27T01:00:00.000Z",
};

function setup(
  options: {
    user?: User | null;
    source?: RelatedSource | null;
    tracked?: ActionSummary | null;
    retryAt?: Date | null;
    consent?: boolean;
    embed?: () => Promise<number[]>;
    create?: () => Promise<ActionSummary>;
  } = {},
) {
  const created: NewUserAction[] = [];
  const embedded: string[] = [];
  const loaded: string[] = [];
  const trackedLookups: { sourceId: string; quote: string }[] = [];
  let rateLimited = 0;
  const deps: CreateActionDeps<User> = {
    authenticate: async () => (options.user === undefined ? { id: "u1" } : options.user),
    loadSource: async (_user, id) => {
      loaded.push(id);
      return options.source === undefined ? MEETING : options.source;
    },
    trackedAction: async (_user, sourceId, quote) => {
      trackedLookups.push({ sourceId, quote });
      return options.tracked ?? null;
    },
    rateLimit: async () => {
      rateLimited++;
      return options.retryAt ?? null;
    },
    hasConsent: async () => options.consent ?? true,
    embed: async (_user, text) => {
      embedded.push(text);
      return options.embed ? options.embed() : VECTOR;
    },
    create: async (_user, action) => {
      created.push(action);
      if (options.create) return options.create();
      return {
        id: "9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d",
        title: action.title,
        owner: "me",
        status: "open",
        due_date: action.dueDate,
        counterpart: null,
        needs_confirmation: false,
        confirm_reasons: [],
        started_at: null,
        last_activity_at: "2026-09-28T01:00:00.000Z",
      };
    },
    now: () => new Date("2026-09-28T01:00:00Z"),
  };
  return { deps, created, embedded, loaded, trackedLookups, rateLimits: () => rateLimited };
}

const post = (body: unknown) => new Request("http://localhost/api/v1/actions", { method: "POST", body: JSON.stringify(body) });

describe("POST /api/v1/actions (직접 추가)", () => {
  it("원문 없이 제목 · 기한으로 만들고 201 { action, status: created }", async () => {
    const { deps, created, embedded, loaded, trackedLookups } = setup();
    const response = await handleCreateAction(post({ title: "  견적서 보내기 ", due_date: "2026-10-02" }), deps);
    expect(response.status).toBe(201);
    const { action, status } = createActionResponseSchema.parse(await response.json());
    expect(status).toBe("created");
    expect(action).toMatchObject({ title: "견적서 보내기", owner: "me", status: "open", due_date: "2026-10-02", needs_confirmation: false });
    expect(created).toEqual([{ title: "견적서 보내기", dueDate: "2026-10-02", source: null, embedding: VECTOR }]);
    expect(embedded).toEqual(["견적서 보내기"]);
    expect(loaded).toEqual([]);
    expect(trackedLookups).toEqual([]);
  });

  it("기한은 없어도 된다 (null · 생략)", async () => {
    for (const body of [{ title: "견적서 보내기" }, { title: "견적서 보내기", due_date: null }]) {
      const { deps, created } = setup();
      expect((await handleCreateAction(post(body), deps)).status).toBe(201);
      expect(created[0].dueDate).toBeNull();
    }
  });

  it("관련 원문과 구절을 고르면 본인 원문인지 · 구절이 있는지 · 이미 근거인지 확인하고 근거로 넘긴다", async () => {
    const { deps, created, embedded, loaded, trackedLookups, rateLimits } = setup();
    const response = await handleCreateAction(post({ title: "견적서 보내기", source_id: SOURCE_ID, quote: " 금요일까지 견적서 보내드릴게요 " }), deps);
    expect(response.status).toBe(201);
    expect(createActionResponseSchema.parse(await response.json()).status).toBe("created");
    expect(loaded).toEqual([SOURCE_ID]);
    expect(trackedLookups).toEqual([{ sourceId: SOURCE_ID, quote: "금요일까지 견적서 보내드릴게요" }]);
    expect(rateLimits()).toBe(1);
    expect(created).toEqual([{ title: "견적서 보내기", dueDate: null, source: { id: SOURCE_ID, quote: "금요일까지 견적서 보내드릴게요" }, embedding: VECTOR }]);
    // 파이프라인 후보와 같은 형식 (제목 + 구절)
    expect(embedded).toEqual(["견적서 보내기\n금요일까지 견적서 보내드릴게요"]);
  });

  it.each([
    ["구절만", { title: "견적서 보내기", quote: "금요일까지 견적서 보내드릴게요" }, "source_id"],
    ["원문만", { title: "견적서 보내기", source_id: SOURCE_ID }, "quote"],
  ])("%s 보내면 400", async (_label, body, field) => {
    const { deps, created, loaded } = setup();
    const response = await handleCreateAction(post(body), deps);
    expect(response.status).toBe(400);
    expect(apiErrorSchema.parse(await response.json()).error).toEqual({ code: "invalid_request", message: `잘못된 필드: ${field}` });
    expect(loaded).toEqual([]);
    expect(created).toEqual([]);
  });

  it("그 구절이 이미 Action의 근거면 200 already_tracked로 그 Action을 그대로 돌려준다 (만들지 않고 횟수에 세지 않는다)", async () => {
    const { deps, created, embedded, rateLimits } = setup({ tracked: TRACKED });
    const response = await handleCreateAction(
      post({ title: "견적서 다시 보내기", due_date: "2026-10-09", source_id: SOURCE_ID, quote: "금요일까지 견적서 보내드릴게요" }),
      deps,
    );
    expect(response.status).toBe(200);
    // 보낸 제목 · 기한은 반영하지 않는다 (끝낸 Action도 그대로)
    expect(createActionResponseSchema.parse(await response.json())).toEqual({ action: TRACKED, status: "already_tracked" });
    expect(created).toEqual([]);
    expect(embedded).toEqual([]);
    expect(rateLimits()).toBe(0);
  });

  it("횟수 한도에 차 있어도 이미 있는 Action은 돌려준다", async () => {
    const { deps } = setup({ tracked: TRACKED, retryAt: new Date("2026-09-28T01:05:00Z") });
    const response = await handleCreateAction(post({ title: "견적서 보내기", source_id: SOURCE_ID, quote: "금요일까지 견적서 보내드릴게요" }), deps);
    expect(response.status).toBe(200);
    expect(createActionResponseSchema.parse(await response.json()).status).toBe("already_tracked");
  });

  it("원문 확인에 실패하면 이미 있는 Action을 찾지 않는다", async () => {
    const { deps, trackedLookups } = setup({ tracked: TRACKED });
    const response = await handleCreateAction(post({ title: "견적서 보내기", source_id: SOURCE_ID, quote: "다음 주에 계약서 보내드릴게요" }), deps);
    expect(response.status).toBe(400);
    expect(trackedLookups).toEqual([]);
  });

  it("없거나 남의 원문이면 404이고 만들지 않는다", async () => {
    const { deps, created, rateLimits } = setup({ source: null });
    const response = await handleCreateAction(post({ title: "견적서 보내기", source_id: SOURCE_ID, quote: "금요일까지 견적서 보내드릴게요" }), deps);
    expect(response.status).toBe(404);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("not_found");
    expect(created).toEqual([]);
    expect(rateLimits()).toBe(0);
  });

  it.each([
    ["원문에 없는 구절", MEETING, "다음 주에 계약서 보내드릴게요", "원문에 없는 구절입니다."],
    ["할 일 DB 항목", { ...MEETING, kind: "task" }, "금요일까지 견적서 보내드릴게요", "할 일 DB에서 가져온 항목은 고를 수 없습니다."],
    ["보관 기간이 지난 원문", { kind: "meeting", raw_text: "", raw_text_purged_at: "2026-09-01T00:00:00Z" }, "금요일까지 견적서 보내드릴게요", "원문이 보관 기간(90일)이 지나 지워졌어요."],
  ])("%s이면 400", async (_label, source, quote, message) => {
    const { deps, created } = setup({ source });
    const response = await handleCreateAction(post({ title: "견적서 보내기", source_id: SOURCE_ID, quote }), deps);
    expect(response.status).toBe(400);
    expect(apiErrorSchema.parse(await response.json()).error).toEqual({ code: "invalid_request", message });
    expect(created).toEqual([]);
  });

  it.each([
    [{}],
    [{ title: "   " }],
    [{ title: "가".repeat(201) }],
    [{ title: 3 }],
    [{ title: "견적서", due_date: "10월 2일" }],
    [{ title: "견적서", source_id: "not-a-uuid", quote: "견적서" }],
    [{ title: "견적서", source_id: SOURCE_ID, quote: "가".repeat(2001) }],
  ])("잘못된 본문은 400 %#", async (body) => {
    const { deps, created } = setup();
    const response = await handleCreateAction(post(body), deps);
    expect(response.status).toBe(400);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("invalid_request");
    expect(created).toEqual([]);
  });

  it("제목은 200자까지", async () => {
    const { deps } = setup();
    expect((await handleCreateAction(post({ title: "가".repeat(200) }), deps)).status).toBe(201);
  });

  it("횟수 한도에 차면 429와 Retry-After, 임베딩 · 쓰기를 하지 않는다", async () => {
    const { deps, created, embedded } = setup({ retryAt: new Date("2026-09-28T01:05:00Z") });
    const response = await handleCreateAction(post({ title: "견적서 보내기" }), deps);
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("300");
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("rate_limited");
    expect(embedded).toEqual([]);
    expect(created).toEqual([]);
  });

  it("로그인하지 않았으면 401", async () => {
    const { deps, created } = setup({ user: null });
    expect((await handleCreateAction(post({ title: "견적서 보내기" }), deps)).status).toBe(401);
    expect(created).toEqual([]);
  });

  it("외부 AI 처리 동의 전이면 임베딩 없이 만든다 (모델을 부르지 않는다)", async () => {
    const { deps, created, embedded } = setup({ consent: false });
    expect((await handleCreateAction(post({ title: "견적서 보내기" }), deps)).status).toBe(201);
    expect(embedded).toEqual([]);
    expect(created[0].embedding).toBeNull();
  });

  it("임베딩이 실패해도 만든다. 로그에 제목을 남기지 않는다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { deps, created } = setup({
      embed: async () => {
        throw new Error("임베딩 요청 실패 (502)");
      },
    });
    expect((await handleCreateAction(post({ title: "비밀 프로젝트 견적서" }), deps)).status).toBe(201);
    expect(created[0].embedding).toBeNull();
    expect(log).toHaveBeenCalledWith("직접 추가 임베딩 실패:", "임베딩 요청 실패 (502)");
    expect(JSON.stringify(log.mock.calls)).not.toContain("비밀 프로젝트");
    log.mockRestore();
  });

  it("저장하지 못하면 500, 로그에 제목 · 구절을 남기지 않는다", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => {});
    const { deps } = setup({
      create: async () => {
        throw new Error("write_action failed");
      },
    });
    const response = await handleCreateAction(post({ title: "비밀 프로젝트 견적서", source_id: SOURCE_ID, quote: "금요일까지 견적서 보내드릴게요" }), deps);
    expect(response.status).toBe(500);
    expect(apiErrorSchema.parse(await response.json()).error.code).toBe("internal_error");
    expect(log).toHaveBeenCalledWith("직접 추가 실패:", "write_action failed");
    expect(JSON.stringify(log.mock.calls)).not.toContain("비밀 프로젝트");
    expect(JSON.stringify(log.mock.calls)).not.toContain("견적서 보내드릴게요");
    log.mockRestore();
  });
});
