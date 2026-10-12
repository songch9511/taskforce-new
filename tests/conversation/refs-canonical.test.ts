import { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { handlePostConversationMessage, type PostMessageDeps, type PostResult } from "@/lib/api/conversations";
import type { TurnPlan } from "@/lib/conversation/respond";
import type { SelectedRefs } from "@/lib/conversation/referent";
import { verifySelected } from "@/lib/conversation/store";

import { emptyRefs, id } from "./fakes";
import { uuidAdmin } from "./uuid-admin";

// Codex 최종 delta P2: 대소문자만 다른 같은 uuid를 함께 보내면 (요청 스키마는 통과) 소유 확인이 대상 수를 다르게 세어 404가 났다.
// 소유 확인(verifySelected)은 실제 코드를 쓰고, uuid 열 비교는 작은 PGlite(id = any($::uuid[]))로 한다 (uuid-admin.ts: sql-admin.ts의 id::text와 다르다).
// 나머지 의존(인증 · 저장 · 모델)은 가짜: 모델은 부르지 않는다.

vi.mock("server-only", () => ({}));

type User = { user: { id: string } };
const ME = id(1, "11111111");
const THEM = id(2, "22222222");
const USER: User = { user: { id: ME } };
const CONVERSATION = id(1, "cccccccc");
const MESSAGE = id(1, "dddddddd");
const REPLY = id(2, "dddddddd");
const TEXT = "이거 마무리해줘";

// 16진 글자가 있어야 대문자로 바꿀 때 달라진다
const MINE_1 = id(1, "abcdefab");
const MINE_2 = id(2, "abcdefab");
const THEIRS = id(3, "abcdefab");
const MISSING = id(9, "abcdefab");
const CLIENT = id(1, "c1c1c1c1");

const KINDS = [
  { kind: "action", table: "actions", key: "action_ids" },
  { kind: "run", table: "execution_runs", key: "run_ids" },
  { kind: "artifact", table: "execution_artifacts", key: "artifact_ids" },
] as const;

let db: PGlite;

beforeAll(async () => {
  db = new PGlite();
  await db.exec(`
    create table public.actions (id uuid primary key, user_id uuid not null, title text not null);
    create table public.execution_runs (id uuid primary key, user_id uuid not null);
    create table public.execution_artifacts (id uuid primary key, user_id uuid not null);
  `);
}, 60_000);
beforeEach(async () => {
  for (const { table } of KINDS) {
    await db.query(`truncate public.${table}`);
    const extra = table === "actions" ? ", '견적서 보내기'" : "";
    const columns = table === "actions" ? "(id, user_id, title)" : "(id, user_id)";
    for (const [row, owner] of [[MINE_1, ME], [MINE_2, ME], [THEIRS, THEM]] as const) {
      await db.query(`insert into public.${table} ${columns} values ($1::uuid, $2::uuid${extra})`, [row, owner]);
    }
  }
});
afterAll(() => db.close());

const plan = () =>
  ({
    intent: { kind: "consult", confidence: 0.9, judge_version: "intent-v1" },
    route: "consult",
    user: { refs: emptyRefs() },
    reply: { text: "x", segments: [{ text: "x", tier: "T5" }], citations: [], refs: emptyRefs(), content: {} },
    memory: [],
    adopt: null,
    summary: {},
  }) as unknown as TurnPlan;

/** conversation_post_message의 같은 제출 비교(처음 고른 대상과 정규화한 선택이 같은가)를 흉내 낸 저장. 실제 SQL은 tests/db/conversations-v2.scenarios.ts */
function makeDeps() {
  const first = new Map<string, string>();
  const post = vi.fn(async (_u: User, _c: string, client: string, _text: string, selected: SelectedRefs): Promise<PostResult> => {
    const key = JSON.stringify(selected);
    if (!first.has(client)) {
      first.set(client, key);
      return { status: "created", messageId: MESSAGE, seq: 1, replyId: null };
    }
    return first.get(client) === key ? { status: "answered", messageId: MESSAGE, seq: 1, replyId: REPLY } : { status: "refs_mismatch", messageId: MESSAGE, seq: 1, replyId: null };
  });
  const verify = vi.fn((_u: User, refs: Parameters<typeof verifySelected>[2]) => verifySelected(uuidAdmin(db), ME, refs));
  const respond = vi.fn(async () => plan());
  const row = (rowId: string, role: "user" | "assistant") => ({
    id: rowId,
    conversation_id: CONVERSATION,
    seq: role === "user" ? 1 : 2,
    role,
    client_message_id: role === "user" ? CLIENT : null,
    text: TEXT,
    refs: emptyRefs(),
    intent: null,
    created_at: "2026-10-10T01:00:00.000Z",
    reply_to: role === "assistant" ? MESSAGE : null,
    content: role === "assistant" ? { segments: [{ text: "x", tier: "T5" as const }], citations: [], proposal: null, asks: null, used: null, window: null } : null,
  });
  const deps: PostMessageDeps<User> = {
    enabled: () => true,
    memoryEnabled: () => true,
    authenticate: async () => USER,
    hasConsent: async () => true,
    rateLimit: async () => null,
    loadConversation: async () => ({ id: CONVERSATION, contextId: null, contextName: null }),
    verifySelected: verify,
    messageExists: async (_u, _c, client) => first.has(client),
    post,
    loadMessage: async (_u, messageId) => row(messageId, messageId === REPLY ? "assistant" : "user"),
    loadWindow: async () => ({ messages: [{ id: MESSAGE, seq: 1, role: "user", text: TEXT, textExpired: false, createdAt: "2026-10-10T01:00:00.000Z", refs: emptyRefs(), content: null }], omitted: 0 }),
    respond,
    finish: async () => ({ status: "written", replyId: REPLY }),
    release: async () => undefined,
  };
  return { deps, post, verify, respond };
}

const send = (deps: PostMessageDeps<User>, refs: Record<string, string[]>, client = CLIENT) =>
  handlePostConversationMessage(
    new Request(`https://api.example.dev/api/v2/conversations/${CONVERSATION}/messages`, { method: "POST", body: JSON.stringify({ client_message_id: client, text: TEXT, refs }) }),
    CONVERSATION,
    deps,
  );

const norm = (key: string, ids: string[]) => ({ action_ids: [], run_ids: [], artifact_ids: [], [key]: ids });

describe("고른 대상 정규화 (소유 확인 전에 한 번): 실제 verifySelected + uuid 열 비교", () => {
  it("전제: 같은 uuid의 [소문자, 대문자]는 요청 스키마를 통과하고 uuid 열에서는 한 행이다 (id::text 비교가 아니다)", async () => {
    const { rows } = await db.query("select id from public.actions where user_id = $1::uuid and id = any($2::uuid[])", [ME, [MINE_1, MINE_1.toUpperCase()]]);
    expect(rows).toHaveLength(1);
    const { postConversationMessageRequestSchema } = await import("@/lib/api/contract");
    expect(postConversationMessageRequestSchema.safeParse({ client_message_id: CLIENT, text: TEXT, refs: { action_ids: [MINE_1, MINE_1.toUpperCase()] } }).success).toBe(true);
  });

  describe.each(KINDS)("$kind", ({ kind, key }) => {
    it("대소문자만 다른 중복은 유효한 대상 1개: 404가 아니라 200 · 소문자 한 개로 저장 · 그 대상 하나로 답한다", async () => {
      for (const refs of [[MINE_1, MINE_1.toUpperCase()], [MINE_1.toUpperCase(), MINE_1], [MINE_1.toUpperCase()], [MINE_1, MINE_1]]) {
        const { deps, post, respond } = makeDeps();
        const response = await send(deps, { [key]: refs });
        expect(response.status, JSON.stringify(refs)).toBe(200);
        expect(post.mock.calls[0][4]).toEqual(norm(key, [MINE_1]));
        expect(respond).toHaveBeenCalledTimes(1);
        const input = (respond.mock.calls as unknown as [User, { selected: { kind: string; id: string }[] }][])[0][1];
        expect(input.selected.map((t) => [t.kind, t.id])).toEqual([[kind, MINE_1]]);
      }
    });

    it("소유 확인에는 정규화한 선택이 간다 (저장에 넘기는 것과 같은 값)", async () => {
      const { deps, post, verify } = makeDeps();
      await send(deps, { [key]: [MINE_2.toUpperCase(), MINE_1, MINE_2] });
      expect(verify.mock.calls[0][1]).toEqual(norm(key, [MINE_1, MINE_2]));
      expect(post.mock.calls[0][4]).toEqual(verify.mock.calls[0][1]);
    });

    it("순서 · 대소문자 · 중복만 다른 같은 선택의 재시도 = 같은 제출 (저장된 답), 다른 소유 대상 = 409 refs_mismatch", async () => {
      const { deps, post, respond } = makeDeps();
      expect((await send(deps, { [key]: [MINE_1, MINE_2] })).status).toBe(200);
      expect(respond).toHaveBeenCalledTimes(1);

      const retry = await send(deps, { [key]: [MINE_2.toUpperCase(), MINE_1, MINE_2, MINE_1.toUpperCase()] });
      expect(retry.status).toBe(200);
      expect(post.mock.calls[1][4]).toEqual(post.mock.calls[0][4]);
      expect(respond).toHaveBeenCalledTimes(1); // 같은 제출: 다시 답하지 않는다

      const other = await send(deps, { [key]: [MINE_1] }); // 내 것이지만 처음과 다른 대상
      expect(other.status).toBe(409);
      expect((await other.json()).error.message).toBe("같은 client_message_id로 다른 대상을 보냈습니다.");
      expect(respond).toHaveBeenCalledTimes(1);
    });

    it("남의 대상 · 없는 대상은 404: 저장 · 답 0 (대소문자를 바꿔도 같다)", async () => {
      for (const refs of [[THEIRS], [THEIRS.toUpperCase()], [MISSING], [MISSING.toUpperCase()], [MINE_1, THEIRS], [MINE_1, MINE_1.toUpperCase(), MISSING]]) {
        const { deps, post, respond } = makeDeps();
        const response = await send(deps, { [key]: refs });
        expect(response.status, JSON.stringify(refs)).toBe(404);
        expect(post).not.toHaveBeenCalled();
        expect(respond).not.toHaveBeenCalled();
      }
    });

    it("store.verifySelected 자체도 대소문자 섞인 중복을 하나로 센다 (정규화하지 않은 호출에도 404가 되지 않는다)", async () => {
      const admin = uuidAdmin(db);
      const found = await verifySelected(admin, ME, { [key]: [MINE_1, MINE_1.toUpperCase()] });
      expect(found).toEqual({ targets: [expect.objectContaining({ kind, id: MINE_1 })] });
      expect(await verifySelected(admin, ME, { [key]: [MINE_1, THEIRS.toUpperCase()] })).toEqual({ missing: true });
      expect(await verifySelected(admin, ME, { [key]: [MINE_1, MINE_1.toUpperCase(), MISSING] })).toEqual({ missing: true });
    });
  });

  it("세 종류를 함께 보내도 종류마다 같은 규칙 (대상 3개)", async () => {
    const { deps, post, respond } = makeDeps();
    const response = await send(deps, { action_ids: [MINE_1, MINE_1.toUpperCase()], run_ids: [MINE_2.toUpperCase(), MINE_2], artifact_ids: [MINE_1.toUpperCase()] });
    expect(response.status).toBe(200);
    expect(post.mock.calls[0][4]).toEqual({ action_ids: [MINE_1], run_ids: [MINE_2], artifact_ids: [MINE_1] });
    const input = (respond.mock.calls as unknown as [User, { selected: { kind: string; id: string }[] }][])[0][1];
    expect(input.selected.map((t) => [t.kind, t.id])).toEqual([["action", MINE_1], ["run", MINE_2], ["artifact", MINE_1]]);
  });
});
