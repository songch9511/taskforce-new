import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import { expect, it } from "vitest";

// Claude 데스크톱 세션과 나눈 대화 저장 (OA PR-D3s, 계약 handoffs/oa-external-sessions-contract.md 25 · 26장): Mac이 보낸 글 + 그 뒤 세션의 답 글 + 도구 단계 **이름만**.
// 표 둘(claude_app_chats · claude_app_chat_messages), 서버 전용 함수(save · delete), RLS · 복합 FK · cascade · 멱등 · orphan · 지표를 본다.
// 26장(사용자 결정): 직접 지울 때까지 보관한다 — 자동 정리 함수 · cron은 **없다** (아래 마지막 시험이 고정한다).
// PGlite(tests/db/claude-app-chats.test.ts)와 실제 Postgres(tests/pg/claude-app-chats.test.ts)가 같은 시나리오를 돌린다.

export type ClaudeAppChatsDb = {
  query: (sql: string, params?: unknown[]) => Promise<Record<string, unknown>[]>;
  asUser: <T>(user: string, fn: () => Promise<T>) => Promise<T>;
};

export type Msg = {
  mac_ref: string;
  role: "user" | "assistant";
  reply_to_ref?: string;
  body: string;
  truncated: boolean;
  said_at: string;
  /** 이 글 앞에서 쓴 도구 단계의 **이름만** (순서대로, 최대 40). 도구 입력 · 결과 · 경로 · 명령은 없다 */
  tool_names?: string[];
};
export type SaveResult = { status: string; chat_id?: string | null; saved?: number; existing?: number; orphan?: number };

export const ref = (n: number) => n.toString(16).padStart(64, "0");
const at = (n: number) => `2026-10-22T09:${String(n % 60).padStart(2, "0")}:00Z`;
/** 사용자 글: mac_ref = ref(n) */
export const userMsg = (n: number, over: Partial<Msg> = {}): Msg => ({ mac_ref: ref(n), role: "user", body: `보낸 글 ${n}`, truncated: false, said_at: at(n), ...over });
/** 답 글: mac_ref = ref(n), 사용자 글 ref(reply)에 답한다 */
export const asstMsg = (n: number, reply: number, over: Partial<Msg> = {}): Msg => ({
  mac_ref: ref(n),
  role: "assistant",
  reply_to_ref: ref(reply),
  body: `답 글 ${n}`,
  truncated: false,
  said_at: at(n),
  tool_names: [],
  ...over,
});

export function claudeAppChatsTests(db: () => ClaudeAppChatsDb) {
  const q = (sql: string, params?: unknown[]) => db().query(sql, params);
  const one = async (sql: string, params?: unknown[]) => (await q(sql, params))[0];
  const count = async (sql: string, params?: unknown[]) => Number((await one(`select count(*)::int as n from (${sql}) t`, params)).n);

  async function user() {
    const id = randomUUID();
    await q("insert into auth.users (id, email) values ($1, $2)", [id, `${id}@example.com`]);
    return id;
  }
  async function bridge(owner: string, status: "active" | "revoked" = "active") {
    const id = randomUUID();
    await q("insert into public.bridges (id, user_id, device_ref) values ($1, $2, $3)", [id, owner, `dev-${id}`]);
    if (status === "revoked") await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [id]);
    return id;
  }
  const save = (owner: string, bridgeId: string, sessionRef: string, title: string | null, messages: unknown) =>
    one("select public.save_claude_app_chat($1, $2, $3, $4, $5::jsonb) as result", [owner, bridgeId, sessionRef, title, JSON.stringify(messages)]).then((r) => r.result as SaveResult);
  const world = async () => {
    const owner = await user();
    return { owner, bridge: await bridge(owner) };
  };
  const rows = (chatId: string) => q("select role, mac_ref, body, tool_names::text[] as tool_names, truncated, reply_to, seq from public.claude_app_chat_messages where chat_id = $1 order by seq", [chatId]);
  const chatCount = (owner: string) => count("select 1 from public.claude_app_chats where user_id = $1", [owner]);
  const messageCount = (owner: string) => count("select 1 from public.claude_app_chat_messages where user_id = $1", [owner]);
  const events = (owner: string, type: string) => q("select props from public.metric_events where user_id = $1 and type = $2 order by at, id", [owner, type]);

  // ───────────────────────── 표 · 권한 · RLS (DT10) ─────────────────────────

  it("표 둘은 RLS가 켜져 있고 owner_all 정책이 있다. 앱은 읽기만, 익명은 아무것도 못 한다", async () => {
    for (const table of ["claude_app_chats", "claude_app_chat_messages"]) {
      expect(await one("select relrowsecurity as enabled from pg_class where oid = $1::regclass", [`public.${table}`]), table).toEqual({ enabled: true });
      expect(await one("select count(*)::int as n from pg_policies where schemaname = 'public' and tablename = $1 and policyname = 'owner_all'", [table]), table).toEqual({ n: 1 });
      for (const role of ["anon", "authenticated"]) {
        expect(await one("select has_table_privilege($1, $2, 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') as writes", [role, `public.${table}`]), `${table} ${role}`).toEqual({ writes: false });
      }
      expect(await one("select has_table_privilege('authenticated', $1, 'SELECT') as reads", [`public.${table}`]), table).toEqual({ reads: true });
      expect(await one("select has_table_privilege('anon', $1, 'SELECT') as reads", [`public.${table}`]), table).toEqual({ reads: false });
      expect(await one("select has_table_privilege('service_role', $1, 'SELECT,INSERT,UPDATE,DELETE') as all", [`public.${table}`]), table).toEqual({ all: true });
    }
  });

  it("DT10: 다른 사용자는 저장된 대화를 읽지도 쓰지도 못한다 (select 0 · insert/update/delete 42501)", async () => {
    const alice = await world();
    const bob = await world();
    const a = await save(alice.owner, alice.bridge, ref(1), "앨리스 세션", [userMsg(1), asstMsg(2, 1, { tool_names: ["Read"] })]);
    await save(bob.owner, bob.bridge, ref(1), "밥 세션", [userMsg(1)]);
    const chatId = String(a.chat_id);
    await db().asUser(alice.owner, async () => {
      expect(await count("select 1 from public.claude_app_chats")).toBe(1);
      expect((await q("select body from public.claude_app_chat_messages order by seq")).map((r) => r.body)).toEqual(["보낸 글 1", "답 글 2"]);
    });
    await db().asUser(bob.owner, async () => {
      expect(await count("select 1 from public.claude_app_chats where id = $1", [chatId])).toBe(0);
      expect(await count("select 1 from public.claude_app_chat_messages where chat_id = $1", [chatId])).toBe(0);
      // 자기 행은 읽는다
      expect(await count("select 1 from public.claude_app_chat_messages")).toBe(1);
      // 쓰기 권한이 아예 없다 (남의 행이든 자기 행이든)
      await expect(q("insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, body, truncated, said_at) values ($1, $2, 'user', $3, 'x', false, now())", [alice.owner, chatId, ref(9)])).rejects.toMatchObject({ code: "42501" });
      await expect(q("insert into public.claude_app_chats (bridge_id, session_ref) values ($1, $2)", [bob.bridge, ref(9)])).rejects.toMatchObject({ code: "42501" });
      await expect(q("update public.claude_app_chat_messages set body = '바꿈'")).rejects.toMatchObject({ code: "42501" });
      await expect(q("update public.claude_app_chats set title = '바꿈'")).rejects.toMatchObject({ code: "42501" });
      await expect(q("delete from public.claude_app_chat_messages")).rejects.toMatchObject({ code: "42501" });
      await expect(q("delete from public.claude_app_chats")).rejects.toMatchObject({ code: "42501" });
    });
    // 익명
    await q("set role anon");
    try {
      await expect(q("select 1 from public.claude_app_chats")).rejects.toMatchObject({ code: "42501" });
      await expect(q("select 1 from public.claude_app_chat_messages")).rejects.toMatchObject({ code: "42501" });
    } finally {
      await q("reset role");
    }
    expect(await messageCount(alice.owner)).toBe(2);
  });

  it("DT10: 함수는 service role만 부른다 (앱 · 익명은 실행 권한 없음), invoker + search_path 빈 값", async () => {
    for (const fn of ["save_claude_app_chat(uuid,uuid,text,text,jsonb)", "delete_claude_app_chat(uuid,uuid)"]) {
      for (const role of ["anon", "authenticated"]) {
        expect(await one("select has_function_privilege($1, $2, 'EXECUTE') as run", [role, `public.${fn}`]), `${fn} ${role}`).toEqual({ run: false });
      }
      expect(await one("select has_function_privilege('service_role', $1, 'EXECUTE') as run", [`public.${fn}`]), fn).toEqual({ run: true });
      expect(await one("select proconfig, prosecdef as definer from pg_proc where oid = $1::regprocedure", [`public.${fn}`]), fn).toEqual({ proconfig: ['search_path=""'], definer: false });
    }
    // 앱 권한으로 부르면 실제로 거절된다
    const w = await world();
    await db().asUser(w.owner, async () => {
      await expect(q("select public.save_claude_app_chat($1, $2, $3, null, $4::jsonb)", [w.owner, w.bridge, ref(1), JSON.stringify([userMsg(1)])])).rejects.toMatchObject({ code: "42501" });
      await expect(q("select public.delete_claude_app_chat($1, $2)", [w.owner, randomUUID()])).rejects.toMatchObject({ code: "42501" });
    });
    expect(await chatCount(w.owner)).toBe(0);
  });

  // ───────────────────────── 열 규칙 · 복합 FK ─────────────────────────

  it("열 규칙: ref는 소문자 hex 64자, 제목은 null이거나 1–200자, role · 답 연결 · 본문 크기 · 도구 이름", async () => {
    const w = await world();
    const chat = (over: Record<string, unknown> = {}) => {
      const v = { session_ref: ref(1), title: "ok", ...over };
      return one("insert into public.claude_app_chats (user_id, bridge_id, session_ref, title, last_message_at) values ($1, $2, $3, $4, now()) returning id", [w.owner, w.bridge, v.session_ref, v.title]);
    };
    await expect(chat({ session_ref: "0".repeat(63) })).rejects.toMatchObject({ code: "23514" });
    await expect(chat({ session_ref: "A".repeat(64) })).rejects.toMatchObject({ code: "23514" });
    await expect(chat({ title: "" })).rejects.toMatchObject({ code: "23514" });
    await expect(chat({ title: "가".repeat(201) })).rejects.toMatchObject({ code: "23514" });
    const chatId = String((await chat()).id);
    await chat({ session_ref: ref(2), title: null });
    await chat({ session_ref: ref(3), title: "가".repeat(200) });

    const insert = (over: Record<string, unknown>) => {
      const v = { role: "user", mac_ref: ref(10), reply_to: null, body: "글", tool_names: "{}", ...over };
      return q("insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, reply_to, body, truncated, said_at, tool_names) values ($1, $2, $3, $4, $5, $6, false, now(), $7::text[])", [w.owner, chatId, v.role, v.mac_ref, v.reply_to, v.body, v.tool_names]);
    };
    const userRow = String((await one("insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, body, truncated, said_at) values ($1, $2, 'user', $3, '질문', false, now()) returning id", [w.owner, chatId, ref(10)])).id);
    await expect(insert({ role: "system", mac_ref: ref(11) })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ mac_ref: "x".repeat(64) })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ mac_ref: ref(11), body: "" })).rejects.toMatchObject({ code: "23514" });
    // (role = assistant) = (reply_to 있음)
    await expect(insert({ role: "assistant", mac_ref: ref(11), reply_to: null })).rejects.toMatchObject({ code: "23514" });
    await expect(insert({ role: "user", mac_ref: ref(12), reply_to: userRow })).rejects.toMatchObject({ code: "23514" });
    await insert({ role: "assistant", mac_ref: ref(13), reply_to: userRow, tool_names:"{Read,Edit,mcp__server__tool-name}" });
    // 사용자 글 16,000자 · 답 글 64 KiB(바이트)
    await expect(insert({ mac_ref: ref(14), body: "가".repeat(16_001) })).rejects.toMatchObject({ code: "23514" });
    await insert({ mac_ref: ref(14), body: "가".repeat(16_000) });
    await expect(insert({ role: "assistant", mac_ref: ref(15), reply_to: userRow, body: "가".repeat(21_846) })).rejects.toMatchObject({ code: "23514" }); // 65,538바이트
    await insert({ role: "assistant", mac_ref: ref(15), reply_to: userRow, body: "가".repeat(21_845) }); // 65,535바이트
    await insert({ role: "assistant", mac_ref: ref(16), reply_to: userRow, body: "a".repeat(65_536) });
    await expect(insert({ role: "assistant", mac_ref: ref(17), reply_to: userRow, body: "a".repeat(65_537) })).rejects.toMatchObject({ code: "23514" });
    // 도구 단계는 이름만: 최대 40개 · 이름 모양(경로 · 명령 · 공백 · 괄호 불가) · null 원소 불가 · 답 글에만
    const names = (n: number) => `{${Array.from({ length: n }, (_, i) => `T${i}`).join(",")}}`;
    await insert({ role: "assistant", mac_ref: ref(18), reply_to: userRow, tool_names:names(40) });
    await expect(insert({ role: "assistant", mac_ref: ref(19), reply_to: userRow, tool_names:names(41) })).rejects.toMatchObject({ code: "23514" });
    for (const bad of ['{"/Users/me/project/a.ts"}', '{"Bash(git status)"}', '{"rm -rf /"}', '{""}', '{"a,b"}', `{${"x".repeat(65)}}`, "{NULL}", '{"한글"}']) {
      await expect(insert({ role: "assistant", mac_ref: ref(20), reply_to: userRow, tool_names:bad }), bad).rejects.toMatchObject({ code: expect.stringMatching(/^(23514|22P02)$/) });
    }
    await expect(insert({ role: "user", mac_ref: ref(21), tool_names: "{Read}" })).rejects.toMatchObject({ code: "23514" });
  });

  it("복합 외래키: 남의 bridge · 남의 chat · 다른 chat의 답 연결은 DB가 거절한다", async () => {
    const alice = await world();
    const bob = await world();
    const a = await save(alice.owner, alice.bridge, ref(1), null, [userMsg(1)]);
    const b = await save(alice.owner, alice.bridge, ref(2), null, [userMsg(1)]);
    const aUser = String((await one("select id from public.claude_app_chat_messages where chat_id = $1", [String(a.chat_id)])).id);
    // 남의 bridge
    await expect(q("insert into public.claude_app_chats (user_id, bridge_id, session_ref, last_message_at) values ($1, $2, $3, now())", [bob.owner, alice.bridge, ref(3)])).rejects.toMatchObject({ code: "23503" });
    // 남의 chat
    await expect(q("insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, body, truncated, said_at) values ($1, $2, 'user', $3, 'x', false, now())", [bob.owner, String(a.chat_id), ref(5)])).rejects.toMatchObject({ code: "23503" });
    // 같은 사용자의 다른 chat에 있는 사용자 글을 답 대상으로 삼을 수 없다
    await expect(
      q("insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, reply_to, body, truncated, said_at) values ($1, $2, 'assistant', $3, $4, 'x', false, now())", [alice.owner, String(b.chat_id), ref(6), aUser]),
    ).rejects.toMatchObject({ code: "23503" });
  });

  // ───────────────────────── save_claude_app_chat ─────────────────────────

  it("save: 채팅을 만들고 보낸 글 · 답 글 · 도구 이름(순서)을 넣는다. 응답은 개수뿐이다", async () => {
    const w = await world();
    const result = await save(w.owner, w.bridge, ref(7), "세션 제목", [userMsg(1), asstMsg(2, 1, { tool_names: ["Read", "Edit", "Read", "Bash"], truncated: true }), asstMsg(3, 1, { tool_names: [] })]);
    expect(result).toEqual({ status: "ok", chat_id: expect.any(String), saved: 3, existing: 0, orphan: 0 });
    const chat = await one("select bridge_id, session_ref, title, last_message_at is not null as has_last from public.claude_app_chats where id = $1", [String(result.chat_id)]);
    expect(chat).toEqual({ bridge_id: w.bridge, session_ref: ref(7), title: "세션 제목", has_last: true });
    const stored = await rows(String(result.chat_id));
    expect(stored.map((r) => [r.role, r.mac_ref, r.body, r.tool_names, r.truncated])).toEqual([
      ["user", ref(1), "보낸 글 1", [], false],
      ["assistant", ref(2), "답 글 2", ["Read", "Edit", "Read", "Bash"], true],
      ["assistant", ref(3), "답 글 3", [], false],
    ]);
    // 답 글의 reply_to는 사용자 글 행 id
    const userId = (await one("select id from public.claude_app_chat_messages where chat_id = $1 and role = 'user'", [String(result.chat_id)])).id;
    expect(stored.filter((r) => r.role === "assistant").map((r) => r.reply_to)).toEqual([userId, userId]);
    // seq는 보낸 순서대로 늘어난다
    const seqs = stored.map((r) => Number(r.seq));
    expect(seqs).toEqual([...seqs].sort((x, y) => x - y));
    expect(new Set(seqs).size).toBe(3);
  });

  it("DT15 멱등: 같은 묶음을 두 번 올려도 행 수 · 지표가 같다 (existing으로 센다)", async () => {
    const w = await world();
    const batch = [userMsg(1), asstMsg(2, 1, { tool_names: ["Read"] })];
    const first = await save(w.owner, w.bridge, ref(1), "제목", batch);
    expect(first).toMatchObject({ status: "ok", saved: 2, existing: 0, orphan: 0 });
    const again = await save(w.owner, w.bridge, ref(1), "제목", batch);
    expect(again).toEqual({ status: "ok", chat_id: first.chat_id, saved: 0, existing: 2, orphan: 0 });
    expect(await chatCount(w.owner)).toBe(1);
    expect(await messageCount(w.owner)).toBe(2);
    expect(await events(w.owner, "claude_app_message_sent")).toHaveLength(1);
    // 일부만 겹치는 묶음: 새 것만 들어간다 (seq는 뒤에 붙는다)
    const partial = await save(w.owner, w.bridge, ref(1), "제목", [asstMsg(2, 1, { tool_names: ["Read"] }), asstMsg(3, 1)]);
    expect(partial).toMatchObject({ saved: 1, existing: 1, orphan: 0 });
    expect((await rows(String(first.chat_id))).map((r) => r.mac_ref)).toEqual([ref(1), ref(2), ref(3)]);
    // 같은 mac_ref의 다른 내용은 덮어쓰지 않는다 (먼저 저장된 것이 이긴다)
    await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1, { body: "바꾼 글" })]);
    expect((await one("select body from public.claude_app_chat_messages where chat_id = $1 and mac_ref = $2", [String(first.chat_id), ref(1)])).body).toBe("보낸 글 1");
  });

  it("DT15 orphan: 답 글의 reply_to_ref는 **같은 채팅의 사용자 글**로만 풀린다. 못 풀면 그 행만 거절하고 나머지는 저장한다", async () => {
    const w = await world();
    const first = await save(w.owner, w.bridge, ref(1), null, [userMsg(1)]);
    // 같은 사용자의 다른 채팅에 있는 사용자 글 ref를 대도 풀리지 않는다
    const other = await save(w.owner, w.bridge, ref(2), null, [userMsg(5)]);
    const mixed = await save(w.owner, w.bridge, ref(1), null, [
      asstMsg(10, 1), // 풀림
      asstMsg(11, 99), // 없는 ref
      asstMsg(12, 5), // 다른 채팅의 사용자 글
      asstMsg(13, 10), // 답 글을 가리킴 (사용자 글이 아니다)
      asstMsg(14, 1),
    ]);
    expect(mixed).toEqual({ status: "ok", chat_id: first.chat_id, saved: 2, existing: 0, orphan: 3 });
    expect((await rows(String(first.chat_id))).map((r) => r.mac_ref)).toEqual([ref(1), ref(10), ref(14)]);
    expect(await messageCount(w.owner)).toBe(4);
    expect((await rows(String(other.chat_id))).map((r) => r.mac_ref)).toEqual([ref(5)]);
    // 같은 묶음 안에서 사용자 글이 앞서 있으면 풀린다. 뒤에 있으면 orphan (보낸 순서대로 올린다)
    const ordered = await save(w.owner, w.bridge, ref(3), null, [userMsg(20), asstMsg(21, 20)]);
    expect(ordered).toMatchObject({ saved: 2, orphan: 0 });
    const reversed = await save(w.owner, w.bridge, ref(4), null, [asstMsg(31, 30), userMsg(30)]);
    expect(reversed).toMatchObject({ saved: 1, orphan: 1 });
  });

  it("사용자 글 없이 답 글만 온 묶음은 채팅을 만들지 않는다 (지운 대화를 되살리지 않는다)", async () => {
    const w = await world();
    expect(await save(w.owner, w.bridge, ref(1), "제목", [asstMsg(2, 1)])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 1 });
    expect(await chatCount(w.owner)).toBe(0);
    // 사용자가 지운 뒤 같은 교환의 답 글이 늦게 와도 되살아나지 않는다
    const made = await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1)]);
    expect(await one("select public.delete_claude_app_chat($1, $2) as result", [w.owner, String(made.chat_id)])).toEqual({ result: { status: "deleted" } });
    expect(await save(w.owner, w.bridge, ref(1), "제목", [asstMsg(2, 1), asstMsg(3, 1)])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 2 });
    expect(await chatCount(w.owner)).toBe(0);
    expect(await messageCount(w.owner)).toBe(0);
    // 새 사용자 글(새 보내기)이 오면 새 채팅이 생긴다
    const fresh = await save(w.owner, w.bridge, ref(1), "제목", [userMsg(40), asstMsg(41, 40)]);
    expect(fresh).toMatchObject({ saved: 2 });
    expect(fresh.chat_id).not.toBe(made.chat_id);
  });

  it("제목은 마지막 묶음이 말한 값으로 바뀐다 (null이면 지운다). 새 행이 없으면 last_message_at은 그대로다", async () => {
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), "처음 제목", [userMsg(1)]);
    const chatId = String(made.chat_id);
    const title = async () => (await one("select title from public.claude_app_chats where id = $1", [chatId])).title;
    expect(await title()).toBe("처음 제목");
    await save(w.owner, w.bridge, ref(1), "바뀐 제목", [asstMsg(2, 1)]);
    expect(await title()).toBe("바뀐 제목");
    await save(w.owner, w.bridge, ref(1), null, [asstMsg(3, 1)]);
    expect(await title()).toBeNull();
    // last_message_at: 새 행이 없는 재시도는 올리지 않는다
    await q("update public.claude_app_chats set last_message_at = '2026-01-01T00:00:00Z' where id = $1", [chatId]);
    await save(w.owner, w.bridge, ref(1), null, [userMsg(1)]);
    expect((await one("select last_message_at from public.claude_app_chats where id = $1", [chatId])).last_message_at).toEqual(new Date("2026-01-01T00:00:00Z"));
    await save(w.owner, w.bridge, ref(1), null, [asstMsg(4, 1)]);
    expect(Number((await one("select extract(epoch from now() - last_message_at) as age from public.claude_app_chats where id = $1", [chatId])).age)).toBeLessThan(60);
  });

  it("같은 session_ref도 Mac(bridge)이 다르면 다른 채팅이다", async () => {
    const owner = await user();
    const b1 = await bridge(owner);
    const b2 = await bridge(owner);
    const first = await save(owner, b1, ref(1), null, [userMsg(1)]);
    const second = await save(owner, b2, ref(1), null, [userMsg(1)]);
    expect(first.chat_id).not.toBe(second.chat_id);
    expect(await chatCount(owner)).toBe(2);
  });

  it("없는 bridge · 남의 bridge · 해제된 bridge는 not_found이고 아무것도 쓰지 않는다 (지표 포함)", async () => {
    const alice = await world();
    const bob = await user();
    const revoked = await bridge(alice.owner, "revoked");
    expect(await save(alice.owner, randomUUID(), ref(1), "t", [userMsg(1)])).toEqual({ status: "not_found" });
    expect(await save(bob, alice.bridge, ref(1), "t", [userMsg(1)])).toEqual({ status: "not_found" });
    expect(await save(alice.owner, revoked, ref(1), "t", [userMsg(1)])).toEqual({ status: "not_found" });
    expect(await count("select 1 from public.claude_app_chats where user_id in ($1, $2)", [alice.owner, bob])).toBe(0);
    expect(await count("select 1 from public.metric_events where user_id in ($1, $2) and type like 'claude_app%'", [alice.owner, bob])).toBe(0);
  });

  it("소유를 확인한 뒤에야 잠금을 잡는다: 없는 · 남의 · 해제된 bridge로는 잠금을 잡지 못한다", async () => {
    const alice = await world();
    const bob = await user();
    const revoked = await bridge(alice.owner, "revoked");
    const advisory = async () => Number((await one("select count(*)::int as n from pg_locks where locktype = 'advisory' and pid = pg_backend_pid()")).n);
    await q("begin");
    try {
      expect(await advisory()).toBe(0);
      expect(await save(alice.owner, randomUUID(), ref(1), null, [userMsg(1)])).toEqual({ status: "not_found" });
      expect(await save(bob, alice.bridge, ref(1), null, [userMsg(1)])).toEqual({ status: "not_found" });
      expect(await save(alice.owner, revoked, ref(1), null, [userMsg(1)])).toEqual({ status: "not_found" });
      expect(await advisory()).toBe(0);
      expect(await save(alice.owner, alice.bridge, ref(1), null, [userMsg(1)])).toMatchObject({ status: "ok" });
      expect(await advisory()).toBe(1);
    } finally {
      await q("rollback");
    }
  });

  it("잘못된 묶음은 거절(22023)하고 **아무것도 쓰지 않는다** (유효한 행이 앞에 있어도)", async () => {
    const w = await world();
    const good = userMsg(1);
    const bad: [string, unknown][] = [
      ["배열 아님", { not: "array" }],
      ["빈 배열", []],
      ["21개", Array.from({ length: 21 }, (_, n) => userMsg(n + 1))],
      ["mac_ref 중복", [good, userMsg(1, { body: "다른 글" })]],
      ["객체 아닌 원소", [good, null]],
      ["모르는 칸(경로)", [good, { ...userMsg(2), cwd: "/Users/me/project" }]],
      ["모르는 칸(도구 입력)", [good, asstMsg(2, 1, { ...({ tool_input: "x" } as object) })]],
      ["role 틀림", [good, { ...userMsg(2), role: "system" }]],
      ["mac_ref 대문자", [good, userMsg(2, { mac_ref: "A".repeat(64) })]],
      ["mac_ref 63자", [good, userMsg(2, { mac_ref: "a".repeat(63) })]],
      ["본문이 글이 아님", [good, { ...userMsg(2), body: 5 }]],
      ["본문 빈 글", [good, userMsg(2, { body: "" })]],
      ["truncated가 불리언이 아님", [good, { ...userMsg(2), truncated: "no" }]],
      ["said_at 시각 아님", [good, userMsg(2, { said_at: "yesterday" })]],
      ["said_at 없음", [good, { mac_ref: ref(2), role: "user", body: "x", truncated: false }]],
      ["said_at 달력에 없는 날", [good, userMsg(2, { said_at: "2026-02-30T09:00:00Z" })]],
      ["said_at이 PG 특수 입력(now · infinity)", [good, userMsg(2, { said_at: "infinity" }), userMsg(3, { said_at: "now" })]],
      ["said_at에 시간대 없음", [good, userMsg(2, { said_at: "2026-10-22T09:00:00" })]],
      ["답 글에 reply_to_ref 없음", [good, { ...asstMsg(2, 1), reply_to_ref: undefined }]],
      ["사용자 글에 reply_to_ref", [good, userMsg(2, { reply_to_ref: ref(1) })]],
      ["reply_to_ref 대문자", [good, asstMsg(2, 1, { reply_to_ref: "B".repeat(64) })]],
      ["사용자 글에 도구 이름", [good, userMsg(2, { tool_names: ["Read"] })]],
      ["도구 41개", [good, asstMsg(2, 1, { tool_names: Array.from({ length: 41 }, (_, i) => `T${i}`) })]],
      ["도구 이름이 경로", [good, asstMsg(2, 1, { tool_names: ["/Users/me/a.ts"] })]],
      ["도구 이름이 명령", [good, asstMsg(2, 1, { tool_names: ["Bash(git status)"] })]],
      ["도구 이름이 글이 아님", [good, asstMsg(2, 1, { tool_names: [5 as unknown as string] })]],
      ["tool_names가 배열 아님", [good, asstMsg(2, 1, { tool_names: "Read" as unknown as string[] })]],
      ["사용자 글 16,001자", [good, userMsg(2, { body: "가".repeat(16_001) })]],
      ["답 글 64 KiB 초과", [good, asstMsg(2, 1, { body: "a".repeat(65_537) })]],
    ];
    for (const [name, payload] of bad) {
      await expect(save(w.owner, w.bridge, ref(1), "t", payload), name).rejects.toMatchObject({ code: expect.stringMatching(/^(22023|23514)$/) });
      expect(await chatCount(w.owner), name).toBe(0);
    }
    await expect(save(w.owner, w.bridge, "not-a-ref", null, [good])).rejects.toMatchObject({ code: "22023" });
    await expect(save(w.owner, w.bridge, ref(1), "", [good])).rejects.toMatchObject({ code: "22023" });
    await expect(save(w.owner, w.bridge, ref(1), "가".repeat(201), [good])).rejects.toMatchObject({ code: "22023" });
    expect(await chatCount(w.owner)).toBe(0);
    expect(await count("select 1 from public.metric_events where user_id = $1 and type like 'claude_app%'", [w.owner])).toBe(0);
    // 경계: 20개 · 16,000자 · 64 KiB · 도구 40개는 받는다
    const edge = [userMsg(1, { body: "가".repeat(16_000) }), asstMsg(2, 1, { body: "a".repeat(65_536), tool_names: Array.from({ length: 40 }, (_, i) => `Tool_${i}-x`) }), ...Array.from({ length: 18 }, (_, n) => asstMsg(3 + n, 1))];
    expect(edge).toHaveLength(20);
    expect(await save(w.owner, w.bridge, ref(1), "가".repeat(200), edge)).toMatchObject({ status: "ok", saved: 20 });
  });

  // ───────────────────────── 지표 (원칙 6) ─────────────────────────

  it("claude_app_message_sent: 새로 들어간 사용자 글마다 한 번, 같은 트랜잭션에서. 답 글 · 재시도 · orphan은 세지 않는다. 글 · id는 props에 없다", async () => {
    const w = await world();
    await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1), asstMsg(2, 1), userMsg(3), asstMsg(4, 3), asstMsg(5, 99)]);
    expect(await events(w.owner, "claude_app_message_sent")).toEqual([{ props: { result: "received" } }, { props: { result: "received" } }]);
    await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1), userMsg(3), asstMsg(6, 3)]);
    expect(await events(w.owner, "claude_app_message_sent")).toHaveLength(2);
    await save(w.owner, w.bridge, ref(1), "제목", [userMsg(7)]);
    expect(await events(w.owner, "claude_app_message_sent")).toHaveLength(3);
    // 묶음이 롤백되면 지표도 없다 (같은 트랜잭션)
    await q("begin");
    await save(w.owner, w.bridge, ref(1), "제목", [userMsg(8)]);
    await q("rollback");
    expect(await events(w.owner, "claude_app_message_sent")).toHaveLength(3);
    for (const row of await q("select props from public.metric_events where user_id = $1 and type like 'claude_app%'", [w.owner])) {
      expect(JSON.stringify(row.props)).not.toMatch(/보낸 글|답 글|제목|0{10}/);
    }
  });

  it("delete_claude_app_chat: 채팅과 모든 행을 지우고 지표를 남긴다. 없는 · 남의 id는 not_found이고 아무것도 지우지 않는다", async () => {
    const alice = await world();
    const bob = await world();
    const a = await save(alice.owner, alice.bridge, ref(1), "제목", [userMsg(1), asstMsg(2, 1, { tool_names: ["Read"] })]);
    const keep = await save(alice.owner, alice.bridge, ref(2), "남길 것", [userMsg(1)]);
    const b = await save(bob.owner, bob.bridge, ref(1), "밥", [userMsg(1)]);
    const del = (owner: string, id: string) => one("select public.delete_claude_app_chat($1, $2) as result", [owner, id]).then((r) => r.result);
    expect(await del(bob.owner, String(a.chat_id))).toEqual({ status: "not_found" });
    expect(await del(alice.owner, randomUUID())).toEqual({ status: "not_found" });
    expect(await messageCount(alice.owner)).toBe(3);
    expect(await events(alice.owner, "claude_app_chat_deleted")).toEqual([]);
    expect(await del(alice.owner, String(a.chat_id))).toEqual({ status: "deleted" });
    expect(await count("select 1 from public.claude_app_chat_messages where chat_id = $1", [String(a.chat_id)])).toBe(0);
    expect(await chatCount(alice.owner)).toBe(1);
    expect(await events(alice.owner, "claude_app_chat_deleted")).toEqual([{ props: {} }]);
    expect(await del(alice.owner, String(a.chat_id))).toEqual({ status: "not_found" });
    expect(await events(alice.owner, "claude_app_chat_deleted")).toHaveLength(1);
    // 다른 채팅 · 다른 사용자는 그대로
    expect((await rows(String(keep.chat_id))).length).toBe(1);
    expect((await rows(String(b.chat_id))).length).toBe(1);
    // bridge가 해제된 뒤에도 사용자는 자기 대화를 지울 수 있다
    await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [alice.bridge]);
    expect(await del(alice.owner, String(keep.chat_id))).toEqual({ status: "deleted" });
    await expect(one("select public.delete_claude_app_chat(null, $1)", [randomUUID()])).rejects.toMatchObject({ code: "22023" });
  });

  // ───────────────────────── 보관 · cascade ─────────────────────────

  it("bridge를 해제(revoke)해도 대화는 남는다 (사용자의 기록). 해제된 bridge로는 더 저장하지 못한다", async () => {
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1), asstMsg(2, 1)]);
    await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [w.bridge]);
    expect(await chatCount(w.owner)).toBe(1);
    expect((await rows(String(made.chat_id))).length).toBe(2);
    expect(await save(w.owner, w.bridge, ref(1), "제목", [asstMsg(3, 1)])).toEqual({ status: "not_found" });
    expect((await rows(String(made.chat_id))).length).toBe(2);
  });

  it("bridge를 지우면 대화도 함께 지워진다 (cascade)", async () => {
    const w = await world();
    const other = await bridge(w.owner);
    await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1), asstMsg(2, 1)]);
    await save(w.owner, other, ref(1), "다른 Mac", [userMsg(1)]);
    await q("delete from public.bridges where id = $1", [w.bridge]);
    expect(await chatCount(w.owner)).toBe(1);
    expect(await messageCount(w.owner)).toBe(1);
  });

  it("계정(auth.users)을 지우면 대화가 모두 지워지고 다른 사용자의 것은 그대로다", async () => {
    const alice = await world();
    const bob = await world();
    await save(alice.owner, alice.bridge, ref(1), "제목", [userMsg(1), asstMsg(2, 1, { tool_names: ["Read"] })]);
    await save(bob.owner, bob.bridge, ref(1), "밥", [userMsg(1)]);
    await q("delete from auth.users where id = $1", [alice.owner]);
    expect(await chatCount(alice.owner)).toBe(0);
    expect(await messageCount(alice.owner)).toBe(0);
    expect(await messageCount(bob.owner)).toBe(1);
  });

  it("사용자 글을 지우면(내부 정리) 그 답 글도 함께 지워진다 (reply_to cascade)", async () => {
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), null, [userMsg(1), asstMsg(2, 1), userMsg(3), asstMsg(4, 3)]);
    await q("delete from public.claude_app_chat_messages where chat_id = $1 and mac_ref = $2", [String(made.chat_id), ref(1)]);
    expect((await rows(String(made.chat_id))).map((r) => r.mac_ref)).toEqual([ref(3), ref(4)]);
  });

  // ───────────────────────── 26장: 자동 정리 없음 · 보내기 길 0 ─────────────────────────

  it("26장 Q-D3b: 자동 삭제가 없다 — purge 함수도, 오래된 행을 지우는 길도 없다 (직접 지우거나 계정을 지울 때까지)", async () => {
    expect(await count("select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like '%claude_app%' and p.proname like '%purge%'")).toBe(0);
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1, { said_at: "2020-01-01T00:00:00Z" }), asstMsg(2, 1, { said_at: "2020-01-01T00:00:05Z" })]);
    await q("update public.claude_app_chat_messages set created_at = now() - interval '5 years' where chat_id = $1", [String(made.chat_id)]);
    await q("update public.claude_app_chats set created_at = now() - interval '5 years', last_message_at = now() - interval '5 years' where id = $1", [String(made.chat_id)]);
    // 정리 크론 · 보존 문서가 이 표를 건드리지 않는다
    const root = path.resolve(__dirname, "../..");
    expect(readFileSync(path.join(root, "src/app/api/cron/retention/route.ts"), "utf8")).not.toMatch(/claude_app/);
    expect((await rows(String(made.chat_id))).length).toBe(2);
  });

  it("서버가 시작하는 보내기 길이 없다: 표 · 함수는 bridge 명령 · 작업 · 대화 · 트리거와 이어지지 않는다", async () => {
    // 이 표들을 가리키는 외래키는 두 표 자신뿐이다
    const referencing = await q(
      `select distinct conrelid::regclass::text as t from pg_constraint
       where contype = 'f' and confrelid in ('public.claude_app_chats'::regclass, 'public.claude_app_chat_messages'::regclass) order by 1`,
    );
    expect(referencing.map((r) => r.t)).toEqual(["claude_app_chat_messages"]);
    // 사용자 트리거는 updated_at 갱신뿐 (다른 표에 쓰는 트리거 0)
    const triggers = await q(
      `select c.relname as t, tg.tgname as name from pg_trigger tg join pg_class c on c.oid = tg.tgrelid
       where not tg.tgisinternal and c.relname in ('claude_app_chats', 'claude_app_chat_messages') order by 1, 2`,
    );
    expect(triggers).toEqual([{ t: "claude_app_chats", name: "claude_app_chats_set_updated_at" }]);
    for (const fn of ["save_claude_app_chat", "delete_claude_app_chat"]) {
      const def = String((await one("select pg_get_functiondef(p.oid) as def from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1", [fn])).def);
      expect(def, fn).not.toMatch(/bridge_commands|agent_tasks|agent_sessions|conversations|conversation_messages|start_agent_turn|execution_|pg_notify|net\.http/i);
    }
  });
}
