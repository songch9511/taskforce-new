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
  /** keepTitle = true: 요청에 title 칸이 없었다 (저장된 제목을 그대로 둔다). false: title을 그대로 쓴다 (null이면 지운다) */
  const save = (owner: string, bridgeId: string, sessionRef: string, title: string | null, messages: unknown, keepTitle = false) =>
    one("select public.save_claude_app_chat($1, $2, $3, $4, $5::jsonb, $6) as result", [owner, bridgeId, sessionRef, title, JSON.stringify(messages), keepTitle]).then((r) => r.result as SaveResult);
  const SIGNATURE = "save_claude_app_chat(uuid,uuid,text,text,jsonb,boolean)";
  const QUOTA_BYTES = 52_428_800;
  const QUOTA_CHATS = 2000;
  const QUOTA_ROWS = 200_000;
  /** 행마다 본문 바이트에 더해 세는 몫 (행 · 인덱스 · 도구 이름 · 키 따위): 한 줄짜리 글을 수십만 개 넣어 한도를 우회하지 못하게 한다 */
  const ROW_OVERHEAD = 512;
  const TOMBSTONE_CAP = 10_000;
  /** 무거운 시나리오(수만 행 · 수십 MiB를 SQL로 채움)의 시험별 제한: 부하가 큰 CI에서도 기본 5초에 걸리지 않는다 */
  const HEAVY = { timeout: 300_000 };
  /**
   * 실제 Postgres 시험 연결은 statement_timeout 15초(교착 감지용)이라 큰 채우기 SQL이 부하에서 15초를 넘을 수 있다. 그동안만 풀고 원래 값으로 돌려 놓는다
   * (PGlite는 제한이 없어 '0'이다)
   */
  async function withLongStatements<T>(fn: () => Promise<T>): Promise<T> {
    const previous = String((await one("show statement_timeout")).statement_timeout);
    await q("set statement_timeout = '240s'");
    try {
      return await fn();
    } finally {
      await q(`set statement_timeout = '${previous}'`);
    }
  }
  /** SQL로 한꺼번에 채운다 (사용자 글 하나가 든 채팅이 있어야 한다): 답 글 n개, 각 bytes바이트 */
  async function fillBytes(owner: string, chatId: string, userRowRef: string, n: number, bytes: number, from = 100_000) {
    const userRow = String((await one("select id from public.claude_app_chat_messages where chat_id = $1 and mac_ref = $2", [chatId, userRowRef])).id);
    await q(
      `insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, reply_to, body, truncated, said_at)
       select $1, $2, 'assistant', lpad(to_hex(g), 64, '0'), $3, repeat('a', $4::int), false, now() from generate_series($5::int, $5::int + $6::int - 1) g`,
      [owner, chatId, userRow, bytes, from, n],
    );
  }
  /** 한도가 세는 값: 사용자의 모든 행의 (본문 바이트 + 행 몫 512)의 합. 구현의 생성 열이 아니라 octet_length로 따로 센다 */
  const chargedBytes = async (owner: string) => Number((await one(`select coalesce(sum(octet_length(body) + ${ROW_OVERHEAD}), 0)::bigint as n from public.claude_app_chat_messages where user_id = $1`, [owner])).n);
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
    for (const fn of [SIGNATURE, "delete_claude_app_chat(uuid,uuid)"]) {
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
    // 이름 길이: 실제 Claude Code MCP 이름은 `mcp__<서버 이름 또는 uuid>__<도구>`라 64자를 넘는다 (예: mcp__<uuid 36자>__notion-show-advanced-analysis-next-steps = 83자) → 128자까지
    const mcpLong = "mcp__2efc4ad4-301d-4293-82c1-3118287aa3b4__notion-show-advanced-analysis-next-steps";
    expect(mcpLong.length).toBeGreaterThan(64);
    await insert({ role: "assistant", mac_ref: ref(22), reply_to: userRow, tool_names: `{${mcpLong},${"x".repeat(128)}}` });
    for (const bad of ['{"/Users/me/project/a.ts"}', '{"Bash(git status)"}', '{"rm -rf /"}', '{""}', '{"a,b"}', `{${"x".repeat(129)}}`, "{NULL}", '{"한글"}']) {
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

  it("제목: 생략하면 저장된 제목을 그대로 두고, 명시한 값이면 바뀌고, 명시한 null이면 지운다. 새 행이 없는 재시도(saved = 0)는 제목도 last_message_at도 건드리지 않는다", async () => {
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), "처음 제목", [userMsg(1)]);
    const chatId = String(made.chat_id);
    const title = async () => (await one("select title from public.claude_app_chats where id = $1", [chatId])).title;
    expect(await title()).toBe("처음 제목");
    // 생략(keepTitle): 새 행이 들어가도 제목은 그대로다
    await save(w.owner, w.bridge, ref(1), null, [asstMsg(2, 1)], true);
    expect(await title()).toBe("처음 제목");
    // 명시한 값: 새 행이 들어가면 바뀐다
    await save(w.owner, w.bridge, ref(1), "바뀐 제목", [asstMsg(3, 1)]);
    expect(await title()).toBe("바뀐 제목");
    // 명시한 null: 지운다
    await save(w.owner, w.bridge, ref(1), null, [asstMsg(4, 1)]);
    expect(await title()).toBeNull();
    // 새 행이 없는 재시도(saved = 0)는 제목을 바꾸지 않는다 (명시한 값이어도, 명시한 null이어도)
    await save(w.owner, w.bridge, ref(1), "재시도가 바꾸면 안 되는 제목", [asstMsg(4, 1)]);
    expect(await title()).toBeNull();
    await save(w.owner, w.bridge, ref(1), "다시 정함", [asstMsg(5, 1)]);
    expect(await title()).toBe("다시 정함");
    await save(w.owner, w.bridge, ref(1), null, [asstMsg(5, 1)]);
    expect(await title()).toBe("다시 정함");
    // 처음 만들 때: 생략이면 제목 없음 (p_keep_title이면 p_title을 쓰지 않는다)
    const bare = await save(w.owner, w.bridge, ref(2), "무시돼야 할 제목", [userMsg(10)], true);
    expect((await one("select title from public.claude_app_chats where id = $1", [String(bare.chat_id)])).title).toBeNull();
    // last_message_at: 새 행이 없는 재시도는 올리지 않는다
    await q("update public.claude_app_chats set last_message_at = '2026-01-01T00:00:00Z' where id = $1", [chatId]);
    await save(w.owner, w.bridge, ref(1), null, [userMsg(1)]);
    expect((await one("select last_message_at from public.claude_app_chats where id = $1", [chatId])).last_message_at).toEqual(new Date("2026-01-01T00:00:00Z"));
    await save(w.owner, w.bridge, ref(1), null, [asstMsg(6, 1)]);
    expect(Number((await one("select extract(epoch from now() - last_message_at) as age from public.claude_app_chats where id = $1", [chatId])).age)).toBeLessThan(60);
  });

  it("said_at은 서버 시각 + 1일까지만 받는다 (그보다 먼 미래는 잘라 저장한다). 과거 값은 그대로", async () => {
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), null, [userMsg(1, { said_at: "2099-01-01T00:00:00Z" }), asstMsg(2, 1, { said_at: "2020-05-05T05:05:05Z" }), asstMsg(3, 1, { said_at: "9999-12-31T23:59:59+09:00" })]);
    const stored = await q("select mac_ref, said_at, extract(epoch from said_at - now()) as ahead from public.claude_app_chat_messages where chat_id = $1 order by seq", [String(made.chat_id)]);
    expect(Number(stored[0].ahead)).toBeLessThanOrEqual(86_400 + 5);
    expect(Number(stored[0].ahead)).toBeGreaterThan(86_400 - 3600);
    expect(stored[1].said_at).toEqual(new Date("2020-05-05T05:05:05Z"));
    expect(Number(stored[2].ahead)).toBeLessThanOrEqual(86_400 + 5);
    // 내일 정오 같은 가까운 미래(시계 어긋남)는 그대로다
    const soon = new Date(Date.now() + 3600_000).toISOString();
    const near = await save(w.owner, w.bridge, ref(2), null, [userMsg(20, { said_at: soon })]);
    expect((await one("select said_at from public.claude_app_chat_messages where chat_id = $1", [String(near.chat_id)])).said_at).toEqual(new Date(soon));
  });

  it("said_at의 소수 초는 자릿수 제한 없이 받는다 (zod가 받는 모양을 SQL이 500으로 거절하지 않는다)", async () => {
    const w = await world();
    const result = await save(w.owner, w.bridge, ref(1), null, [userMsg(1, { said_at: "2026-10-22T09:00:00.123456789012Z" }), userMsg(2, { said_at: `2026-10-22T09:00:00.${"1".repeat(30)}+09:00` }), userMsg(3, { said_at: "2026-10-22T09:00:00.5Z" })]);
    expect(result).toMatchObject({ status: "ok", saved: 3 });
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
      ["도구 이름 129자", [good, asstMsg(2, 1, { tool_names: ["x".repeat(129)] })]],
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
    // 경계: 20개 · 16,000자 · 64 KiB · 도구 40개 · 도구 이름 128자는 받는다
    const edge = [userMsg(1, { body: "가".repeat(16_000) }), asstMsg(2, 1, { body: "a".repeat(65_536), tool_names: [...Array.from({ length: 39 }, (_, i) => `Tool_${i}-x`), "m".repeat(128)] }), ...Array.from({ length: 18 }, (_, n) => asstMsg(3 + n, 1))];
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

  // ───────────────────────── 모두 지우기 (OA D3v-s, 계약 27장): delete_all_claude_app_chats ─────────────────────────

  const deleteAll = (owner: string) => one("select public.delete_all_claude_app_chats($1) as result", [owner]).then((r) => r.result);
  const tombstoneCount = (owner: string) => count("select 1 from public.claude_app_chat_tombstones where user_id = $1", [owner]);

  it("delete_all_claude_app_chats: 호출한 사용자의 채팅 · 메시지를 모두 지우고 {deleted: 채팅 수}를 돌려준다 — Mac이 둘이어도 bridge가 해제됐어도 지우고, 다른 사용자의 것은 그대로다", async () => {
    const alice = await world();
    const bob = await world();
    const second = await bridge(alice.owner);
    const a1 = await save(alice.owner, alice.bridge, ref(1), "첫째", [userMsg(1), asstMsg(2, 1, { tool_names: ["Read"] })]);
    await save(alice.owner, alice.bridge, ref(2), "둘째", [userMsg(1), userMsg(3), asstMsg(4, 3)]);
    await save(alice.owner, second, ref(1), "다른 Mac", [userMsg(1)]);
    const b1 = await save(bob.owner, bob.bridge, ref(1), "밥 하나", [userMsg(1), asstMsg(2, 1)]);
    const b2 = await save(bob.owner, bob.bridge, ref(2), "밥 둘", [userMsg(1)]);
    // bridge가 해제된 뒤에도 사용자는 자기 대화를 지울 수 있다 (사용자의 기록이다)
    await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [alice.bridge]);
    expect(await chatCount(alice.owner)).toBe(3);
    expect(await messageCount(alice.owner)).toBe(6);

    expect(await deleteAll(alice.owner)).toEqual({ deleted: 3 });
    expect(await chatCount(alice.owner)).toBe(0);
    expect(await messageCount(alice.owner)).toBe(0);
    expect(await count("select 1 from public.claude_app_chat_messages where chat_id = $1", [String(a1.chat_id)])).toBe(0);
    // 다른 사용자: 채팅 · 행 · 묘비 · 지표 모두 그대로다
    expect(await chatCount(bob.owner)).toBe(2);
    expect(await messageCount(bob.owner)).toBe(3);
    expect((await rows(String(b1.chat_id))).map((r) => r.mac_ref)).toEqual([ref(1), ref(2)]);
    expect((await rows(String(b2.chat_id))).length).toBe(1);
    expect(await tombstoneCount(bob.owner)).toBe(0);
    expect(await events(bob.owner, "claude_app_chats_deleted_all")).toEqual([]);
    // RLS 눈으로 본 결과: 앱 역할로 읽으면 앨리스는 0, 밥은 자기 것 둘 그대로다 (남의 것은 어느 쪽에도 보이지 않는다)
    await db().asUser(alice.owner, async () => {
      expect(await count("select 1 from public.claude_app_chats")).toBe(0);
      expect(await count("select 1 from public.claude_app_chat_messages")).toBe(0);
    });
    await db().asUser(bob.owner, async () => {
      expect(await count("select 1 from public.claude_app_chats")).toBe(2);
      expect(await count("select 1 from public.claude_app_chat_messages")).toBe(3);
    });
    // 두 번째 호출은 지울 것이 없다
    expect(await deleteAll(alice.owner)).toEqual({ deleted: 0 });
    // 지우면 사용자별 한도도 비워진다
    expect(await chargedBytes(alice.owner)).toBe(0);
    // 같은 사용자가 새 글을 보내면 새 채팅이 생긴다 (해제된 bridge 말고 새로 등록한 Mac으로)
    const fresh = await bridge(alice.owner);
    expect(await save(alice.owner, fresh, ref(1), "새 채팅", [userMsg(50)])).toMatchObject({ status: "ok", saved: 1 });
  });

  it("delete_all_claude_app_chats: 지울 것이 없으면 {deleted: 0}이고 묘비도 지표도 남기지 않는다. 채팅이 없는 사용자 · 없는 사용자 id도 같다. null은 22023", async () => {
    const w = await world();
    const other = await world();
    await save(other.owner, other.bridge, ref(1), null, [userMsg(1)]);
    expect(await deleteAll(w.owner)).toEqual({ deleted: 0 });
    expect(await deleteAll(randomUUID())).toEqual({ deleted: 0 });
    expect(await tombstoneCount(w.owner)).toBe(0);
    expect(await events(w.owner, "claude_app_chats_deleted_all")).toEqual([]);
    expect(await chatCount(other.owner)).toBe(1);
    await expect(one("select public.delete_all_claude_app_chats(null)")).rejects.toMatchObject({ code: "22023" });
    expect(await chatCount(other.owner)).toBe(1);
  });

  it("DT10: delete_all_claude_app_chats는 service role만 부른다 (앱 · 익명은 실행 권한 없음), invoker + search_path 빈 값 — 앱 권한으로 부르면 거절되고 아무것도 지워지지 않는다", async () => {
    const fn = "delete_all_claude_app_chats(uuid)";
    for (const role of ["anon", "authenticated"]) {
      expect(await one("select has_function_privilege($1, $2, 'EXECUTE') as run", [role, `public.${fn}`]), role).toEqual({ run: false });
    }
    expect(await one("select has_function_privilege('service_role', $1, 'EXECUTE') as run", [`public.${fn}`])).toEqual({ run: true });
    expect(await one("select proconfig, prosecdef as definer from pg_proc where oid = $1::regprocedure", [`public.${fn}`])).toEqual({ proconfig: ['search_path=""'], definer: false });
    const alice = await world();
    const bob = await world();
    await save(alice.owner, alice.bridge, ref(1), null, [userMsg(1)]);
    await save(bob.owner, bob.bridge, ref(1), null, [userMsg(1)]);
    // 자기 id로도, 남의 id로도 앱 역할은 부르지 못한다
    await db().asUser(alice.owner, async () => {
      await expect(q("select public.delete_all_claude_app_chats($1)", [alice.owner])).rejects.toMatchObject({ code: "42501" });
      await expect(q("select public.delete_all_claude_app_chats($1)", [bob.owner])).rejects.toMatchObject({ code: "42501" });
    });
    await q("set role anon");
    try {
      await expect(q("select public.delete_all_claude_app_chats($1)", [alice.owner])).rejects.toMatchObject({ code: "42501" });
    } finally {
      await q("reset role");
    }
    expect(await chatCount(alice.owner)).toBe(1);
    expect(await chatCount(bob.owner)).toBe(1);
  });

  it("묘비: 모두 지울 때 그 사용자의 **사용자 글 mac_ref만** (bridge, session_ref)별로 남기고, 지운 대화의 재시도는 orphan이다 — 저장도 지표도 되살아나지 않는다. 새 글(새 ref)은 새 채팅을 만든다", async () => {
    const alice = await world();
    const bob = await world();
    const second = await bridge(alice.owner);
    const batch1 = [userMsg(1), asstMsg(2, 1, { tool_names: ["Read"] })];
    const batch2 = [userMsg(3), asstMsg(4, 3), userMsg(5)];
    const batch3 = [userMsg(6)];
    const first = await save(alice.owner, alice.bridge, ref(1), "첫째", batch1);
    await save(alice.owner, alice.bridge, ref(2), "둘째", batch2);
    await save(alice.owner, second, ref(1), "다른 Mac", batch3);
    await save(bob.owner, bob.bridge, ref(1), "밥", [userMsg(1)]);
    const sentBefore = (await events(alice.owner, "claude_app_message_sent")).length;
    expect(sentBefore).toBe(4);
    // 해제된 bridge의 대화에도 묘비가 남는다 (bridge 행이 있으므로 복합 외래키를 만족한다)
    await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [second]);
    expect(await deleteAll(alice.owner)).toEqual({ deleted: 3 });
    // 묘비 = 사용자 글의 (bridge, session_ref, mac_ref)뿐 (답 글 ref · 글 · 제목 없음)
    const key = (r: Record<string, unknown>) => `${r.bridge_id}|${r.session_ref}|${r.mac_ref}`;
    expect((await q("select bridge_id, session_ref, mac_ref from public.claude_app_chat_tombstones where user_id = $1", [alice.owner])).map(key).sort()).toEqual(
      [
        { bridge_id: alice.bridge, session_ref: ref(1), mac_ref: ref(1) },
        { bridge_id: alice.bridge, session_ref: ref(2), mac_ref: ref(3) },
        { bridge_id: alice.bridge, session_ref: ref(2), mac_ref: ref(5) },
        { bridge_id: second, session_ref: ref(1), mac_ref: ref(6) },
      ]
        .map(key)
        .sort(),
    );
    expect(JSON.stringify(await q("select * from public.claude_app_chat_tombstones where user_id = $1", [alice.owner]))).not.toMatch(/보낸 글|답 글|첫째|둘째|Read/);
    expect(await tombstoneCount(bob.owner)).toBe(0);
    // 응답을 못 받은 Mac이 같은 묶음을 다시 보낸다: 채팅 · 행 · 지표 0, 사용자 글과 답 글 모두 orphan
    expect(await save(alice.owner, alice.bridge, ref(1), "첫째", batch1)).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 2 });
    expect(await save(alice.owner, alice.bridge, ref(2), "둘째", batch2)).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 3 });
    expect(await chatCount(alice.owner)).toBe(0);
    expect(await messageCount(alice.owner)).toBe(0);
    expect((await events(alice.owner, "claude_app_message_sent")).length).toBe(sentBefore);
    // 늦게 온 답 글만 있는 묶음도 대화를 되살리지 못한다
    expect(await save(alice.owner, alice.bridge, ref(1), "첫째", [asstMsg(7, 1)])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 1 });
    // 새로 보낸 글(새 ref)은 새 채팅이다. 같은 세션에서도 옛 묶음의 재시도는 여전히 막힌다
    const fresh = await save(alice.owner, alice.bridge, ref(1), "첫째", [userMsg(20), asstMsg(21, 20)]);
    expect(fresh).toMatchObject({ status: "ok", saved: 2 });
    expect(fresh.chat_id).not.toBe(first.chat_id);
    expect(await save(alice.owner, alice.bridge, ref(1), "첫째", batch1)).toEqual({ status: "ok", chat_id: fresh.chat_id, saved: 0, existing: 0, orphan: 2 });
    expect((await rows(String(fresh.chat_id))).map((r) => r.mac_ref)).toEqual([ref(20), ref(21)]);
    expect((await events(alice.owner, "claude_app_message_sent")).length).toBe(sentBefore + 1);
    // 다른 사용자의 같은 ref는 막지 않는다
    expect(await save(bob.owner, bob.bridge, ref(9), "밥", [userMsg(1)])).toMatchObject({ status: "ok", saved: 1 });
  });

  it("claude_app_chats_deleted_all: 지운 채팅이 있을 때 한 번, props는 {deleted: 채팅 수}뿐이다 (글 · 제목 · id 0). 채팅마다 claude_app_chat_deleted를 남기지 않는다", async () => {
    const w = await world();
    const other = await world();
    for (let n = 1; n <= 3; n++) await save(w.owner, w.bridge, ref(n), `비밀 제목 ${n}`, [userMsg(1, { body: "비밀 글" }), asstMsg(2, 1, { body: "비밀 답" })]);
    await save(other.owner, other.bridge, ref(1), null, [userMsg(1)]);
    expect(await events(w.owner, "claude_app_chats_deleted_all")).toEqual([]);
    expect(await deleteAll(w.owner)).toEqual({ deleted: 3 });
    expect(await events(w.owner, "claude_app_chats_deleted_all")).toEqual([{ props: { deleted: 3 } }]);
    expect(await events(w.owner, "claude_app_chat_deleted")).toEqual([]);
    expect(JSON.stringify(await q("select props from public.metric_events where user_id = $1 and type like 'claude_app%'", [w.owner]))).not.toMatch(/비밀|0{10}/);
    // 지울 것이 없는 호출은 지표를 더하지 않는다
    expect(await deleteAll(w.owner)).toEqual({ deleted: 0 });
    expect(await events(w.owner, "claude_app_chats_deleted_all")).toHaveLength(1);
    expect(await events(other.owner, "claude_app_chats_deleted_all")).toEqual([]);
    // 하나씩 지우는 길은 그대로 claude_app_chat_deleted다 (props 없음)
    const single = await save(w.owner, w.bridge, ref(9), null, [userMsg(30)]);
    await one("select public.delete_claude_app_chat($1, $2)", [w.owner, String(single.chat_id)]);
    expect(await events(w.owner, "claude_app_chat_deleted")).toEqual([{ props: {} }]);
    expect(await events(w.owner, "claude_app_chats_deleted_all")).toHaveLength(1);
  });

  it("delete_all_claude_app_chats는 한 트랜잭션이다: 바깥 트랜잭션이 롤백되면 채팅 · 행 · 묘비 · 지표가 모두 그대로다 (일부만 지워진 상태가 없다)", async () => {
    const w = await world();
    for (let n = 1; n <= 3; n++) await save(w.owner, w.bridge, ref(n), "제목", [userMsg(1), asstMsg(2, 1)]);
    await q("begin");
    try {
      expect(await deleteAll(w.owner)).toEqual({ deleted: 3 });
      expect(await chatCount(w.owner)).toBe(0);
    } finally {
      await q("rollback");
    }
    expect(await chatCount(w.owner)).toBe(3);
    expect(await messageCount(w.owner)).toBe(6);
    expect(await tombstoneCount(w.owner)).toBe(0);
    expect(await events(w.owner, "claude_app_chats_deleted_all")).toEqual([]);
    // 롤백되었으니 재시도는 되살아난 것이 아니라 그대로 existing이다
    expect(await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1), asstMsg(2, 1)])).toMatchObject({ status: "ok", saved: 0, existing: 2, orphan: 0 });
  });

  it(
    "묘비 상한: 모두 지울 때 사용자 글이 1만 개를 넘으면 **가장 최근에 저장된** 1만 개만 묘비로 남기고, 옛 묘비도 합쳐 사용자당 1만 개를 넘지 않는다. 채팅 2,000개 · 10만 행도 한 번에 지운다 (정상 statement_timeout 아래)",
    HEAVY,
    async () => {
      const w = await world();
      const other = await world();
      const otherChat = await save(other.owner, other.bridge, ref(1), null, [userMsg(1)]);
      const chats = 2000;
      const perChat = 51;
      const total = chats * perChat; // 102,000 (행 몫 포함 52,326,000 < 50 MiB)
      // 사용자 글 n(1..total, 클수록 최근)의 mac_ref = ref(BASE - n): 최근 글일수록 ref가 **작다**. 묘비가 ref 순서로 골라지면(= 가장 최근이 아니라) 아래 단언이 틀어진다 (HMAC ref는 저장 순서와 무관하다)
      const BASE = 1_000_000;
      const macOf = (n: number) => ref(BASE - n);
      await withLongStatements(async () => {
        // 옛 묘비 다섯 (이틀 전): 모두 지울 때 상한 때문에 밀려나야 한다
        await q(
          `insert into public.claude_app_chat_tombstones (user_id, bridge_id, session_ref, mac_ref, created_at)
           select $1::uuid, $2::uuid, lpad(to_hex(7777), 64, '0'), lpad(to_hex(g), 64, '0'), now() - interval '2 days' from generate_series(1, 5) g`,
          [w.owner, w.bridge],
        );
        await q(`insert into public.claude_app_chats (user_id, bridge_id, session_ref) select $1::uuid, $2::uuid, lpad(to_hex(k + 5000000), 64, '0') from generate_series(1, ${chats}) k`, [w.owner, w.bridge]);
        // 사용자 글 n = 1..102,000 (저장 순서 = n, 클수록 최근)
        await q(
          `insert into public.claude_app_chat_messages (user_id, chat_id, role, mac_ref, body, truncated, said_at, created_at)
           select $1::uuid, c.id, 'user', lpad(to_hex(${BASE} - g.n), 64, '0'), 'x', false, now(), timestamp with time zone '2026-01-01 00:00:00+00' + g.n * interval '1 second'
             from (select k, (k - 1) * ${perChat} + j as n from generate_series(1, ${chats}) k, generate_series(1, ${perChat}) j) g
             join public.claude_app_chats c on c.user_id = $1::uuid and c.session_ref = lpad(to_hex(g.k + 5000000), 64, '0')
            order by g.n`,
          [w.owner],
        );
        // 운영에서는 자동 analyze가 통계를 채운다. 방금 SQL로 채운 표는 통계가 없어 계획기가 표를 작다고 보고 지우기의 cascade 조회를 순차 스캔으로 짠다 (실제 Postgres에서 3초 → 29초)
        await q("analyze public.claude_app_chats");
        await q("analyze public.claude_app_chat_messages");
      });
      expect(await chatCount(w.owner)).toBe(chats);
      expect(await messageCount(w.owner)).toBe(total);
      expect(await tombstoneCount(w.owner)).toBe(5);
      // 정상 statement_timeout 아래에서 한 번에 (실제 Postgres 시험 연결은 15초)
      expect(await deleteAll(w.owner)).toEqual({ deleted: chats });
      expect(await chatCount(w.owner)).toBe(0);
      expect(await messageCount(w.owner)).toBe(0);
      expect(await tombstoneCount(w.owner)).toBe(TOMBSTONE_CAP);
      // 남은 묘비 = 가장 최근에 저장된 사용자 글 1만 개 (n = 92,001..102,000). 옛 묘비 다섯은 밀려났다
      expect(
        await count(`select 1 from public.claude_app_chat_tombstones t where t.user_id = $1 and t.mac_ref in (select lpad(to_hex(${BASE} - n), 64, '0') from generate_series(${total - TOMBSTONE_CAP + 1}, ${total}) n)`, [w.owner]),
      ).toBe(TOMBSTONE_CAP);
      expect(await count("select 1 from public.claude_app_chat_tombstones where user_id = $1 and session_ref = lpad(to_hex(7777), 64, '0')", [w.owner])).toBe(0);
      expect((await events(w.owner, "claude_app_chats_deleted_all")).map((e) => e.props)).toEqual([{ deleted: chats }]);
      // 지운 10만 행의 죽은 튜플을 바로 치운다: 자동 vacuum이 뒤 시험 한복판에서 돌며 통계 · 계획을 흔들지 않게 한다 (같은 표를 쓰는 다음 시험이 10만 행을 다시 채우고 지운다)
      await withLongStatements(async () => {
        for (const table of ["claude_app_chat_messages", "claude_app_chats", "claude_app_chat_tombstones"]) await q(`vacuum (analyze) public.${table}`);
      });
      // 다른 사용자는 그대로
      expect(await chatCount(other.owner)).toBe(1);
      expect((await rows(String(otherChat.chat_id))).length).toBe(1);
      // 가장 최근 글의 재시도는 막히고, 상한 밖의 가장 오래된 글은 막히지 않는다 (재시도는 몇 분 안의 일이다)
      expect(await save(w.owner, w.bridge, ref(chats + 5_000_000), null, [userMsg(total, { mac_ref: macOf(total) })])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 1 });
      expect(await save(w.owner, w.bridge, ref(1 + 5_000_000), null, [userMsg(1, { mac_ref: macOf(1) })])).toMatchObject({ status: "ok", saved: 1 });
    },
  );

  // ───────────────────────── 사용자별 한도 (보안 검토 P2-1) ─────────────────────────

  it("사용자별 한도 · 본문: 저장된 (본문 + 행마다 512바이트) 합계가 50 MiB(경계 포함)를 넘기는 묶음은 quota_exceeded이고 아무것도 쓰지 않는다. 재시도 · 다른 사용자 · 지운 뒤는 영향 없다", HEAVY, async () => {
    await withLongStatements(async () => {
      const w = await world();
      const other = await world();
      const made = await save(w.owner, w.bridge, ref(1), null, [userMsg(1)]);
      const chatId = String(made.chat_id);
      // 거의 가득: 793 × (65,536바이트 = 답 글 한 줄 상한 + 행 몫 512) + 사용자 글
      await fillBytes(w.owner, chatId, ref(1), 793, 65_536);
      const filled = await chargedBytes(w.owner);
      const remaining = QUOTA_BYTES - filled;
      expect(remaining).toBeGreaterThan(ROW_OVERHEAD + 1000);
      expect(remaining).toBeLessThan(65_536 + ROW_OVERHEAD);
      // 새 행 하나가 차지하는 몫 = 본문 + 512이므로, 남은 자리 remaining에 꼭 맞는 본문은 remaining − 512바이트다
      const fits = remaining - ROW_OVERHEAD;
      const eventsBefore = (await events(w.owner, "claude_app_message_sent")).length;
      // 넘기는 묶음 (사용자 글 + 1바이트 초과 답 글): 아무것도 쓰지 않고 지표도 없다
      expect(await save(w.owner, w.bridge, ref(1), null, [userMsg(2), asstMsg(3, 2, { body: "a".repeat(fits + 1) })])).toEqual({ status: "quota_exceeded" });
      expect(await chargedBytes(w.owner)).toBe(filled);
      expect(await messageCount(w.owner)).toBe(794);
      expect((await events(w.owner, "claude_app_message_sent")).length).toBe(eventsBefore);
      // 본문 1바이트가 넘치는 한 줄도 거절 (행 몫을 세지 않으면 이만큼 더 들어간다)
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(4, 1, { body: "a".repeat(fits + 1) })])).toEqual({ status: "quota_exceeded" });
      // 정확히 한도인 묶음은 받는다 (경계 포함)
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(4, 1, { body: "a".repeat(fits) })])).toMatchObject({ status: "ok", saved: 1 });
      expect(await chargedBytes(w.owner)).toBe(QUOTA_BYTES);
      // 한도에 닿은 뒤: 이미 저장된 행의 재시도는 늘리지 않으므로 받는다 (existing), 새 행은 1바이트도 안 된다
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(4, 1, { body: "a".repeat(fits) })])).toMatchObject({ status: "ok", saved: 0, existing: 1 });
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(5, 1, { body: "x" })])).toEqual({ status: "quota_exceeded" });
      // 합계가 이미 한도를 넘은 사용자(직접 들어간 행 · 나중에 낮춘 한도)도 이미 저장된 행의 재시도는 받는다 — 새 행이 없으면 한도를 묻지 않는다. 새 행은 여전히 거절
      await fillBytes(w.owner, chatId, ref(1), 1, 1000, 200_000);
      expect(await chargedBytes(w.owner)).toBeGreaterThan(QUOTA_BYTES);
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(4, 1, { body: "a".repeat(fits) })])).toMatchObject({ status: "ok", saved: 0, existing: 1 });
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(5, 1, { body: "x" })])).toEqual({ status: "quota_exceeded" });
      await q("delete from public.claude_app_chat_messages where chat_id = $1 and mac_ref = lpad(to_hex(200000), 64, '0')", [chatId]);
      expect(await chargedBytes(w.owner)).toBe(QUOTA_BYTES);
      // 소유 확인이 먼저다: 남의 bridge는 한도 때문이 아니라 not_found (한도 상태를 알리지 않는다)
      expect(await save(w.owner, other.bridge, ref(1), null, [userMsg(9)])).toEqual({ status: "not_found" });
      // 다른 사용자는 영향 없다
      expect(await save(other.owner, other.bridge, ref(1), null, [userMsg(1)])).toMatchObject({ status: "ok", saved: 1 });
      // 지우면 바로 다시 쓸 수 있다
      expect(await one("select public.delete_claude_app_chat($1, $2) as result", [w.owner, chatId])).toEqual({ result: { status: "deleted" } });
      expect(await chargedBytes(w.owner)).toBe(0);
      expect(await save(w.owner, w.bridge, ref(1), null, [userMsg(30), asstMsg(31, 30, { body: "a".repeat(65_536) })])).toMatchObject({ status: "ok", saved: 2 });
    });
  });

  it("사용자별 한도 · 행 몫: 본문이 1바이트인 행도 512바이트씩 센다 — 한 줄짜리 글을 십만 개 넣어 한도를 우회하지 못한다 (행 몫을 세지 않으면 이 묶음이 받아들여진다)", HEAVY, async () => {
    await withLongStatements(async () => {
      const w = await world();
      const made = await save(w.owner, w.bridge, ref(1), null, [userMsg(1)]);
      const chatId = String(made.chat_id);
      // 1바이트 답 글 102,198개 (각 513바이트) + 사용자 글(524): 한도까지 702바이트가 남는다. 본문만 세면 100 KB도 안 된다
      await fillBytes(w.owner, chatId, ref(1), 102_198, 1);
      // 운영에서는 자동 analyze가 통계를 채운다. SQL로 막 채운 표는 통계가 없거나 낡아서 아래 지우기의 cascade 조회(행마다 둘)를 순차 스캔으로 짜 부하에서 시간 제한(240초)을 넘길 수 있다
      await q("analyze public.claude_app_chat_messages");
      const filled = await chargedBytes(w.owner);
      expect(QUOTA_BYTES - filled).toBe(702);
      const bodyOnly = Number((await one("select sum(octet_length(body))::bigint as n from public.claude_app_chat_messages where user_id = $1", [w.owner])).n);
      expect(bodyOnly).toBeLessThan(150_000);
      expect(await messageCount(w.owner)).toBe(102_199);
      // 1바이트 글 하나(513)는 들어간다. 그다음 하나(513 > 189)는 본문이 1바이트인데도 거절된다
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(2, 1, { body: "x" })])).toMatchObject({ status: "ok", saved: 1 });
      expect(QUOTA_BYTES - (await chargedBytes(w.owner))).toBe(189);
      expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(3, 1, { body: "y" })])).toEqual({ status: "quota_exceeded" });
      expect(await messageCount(w.owner)).toBe(102_200);
      // 지우면 다시 쓸 수 있다. 이 채팅은 사용자 글 하나에 답 글 10만 개가 매달린 극단적으로 치우친 모양이다 (실제는 사용자 글 하나에 답 글 40개 이하).
      // 지우기의 cascade 조회(reply_to = $1)는 SPI가 저장한 계획이라 처음 다섯 번을 맞춤 계획으로 짜고 그 평균 비용을 일반 계획 비용과 견주는데, 첫 번째가 부모(10만 행 순차 스캔)라 평균이 부풀어
      // 일반 계획(사용자 인덱스 + 필터: 행마다 10만 행 훑기)이 뽑히는 판이 있다 (실제 Postgres에서 자동 vacuum · analyze의 계획 무효화 시점에 따라 어쩌다 240초를 넘겼다). 이 시험은 맞춤 계획으로 고정한다
      await q("set plan_cache_mode = force_custom_plan");
      try {
        expect(await one("select public.delete_claude_app_chat($1, $2) as result", [w.owner, chatId])).toEqual({ result: { status: "deleted" } });
      } finally {
        await q("reset plan_cache_mode");
      }
      expect(await messageCount(w.owner)).toBe(0);
      expect(await save(w.owner, w.bridge, ref(1), null, [userMsg(40), asstMsg(41, 40, { body: "z" })])).toMatchObject({ status: "ok", saved: 2 });
    });
  });

  it("사용자별 한도 · 합계를 싸게 센다: 행마다 본문 바이트를 생성 열 body_bytes에 두고 (user_id) include (body_bytes) 인덱스가 덮어서 index-only scan으로 합친다. 생성 열은 쓸 수 없고 octet_length(body)와 같다", async () => {
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), null, [userMsg(1), asstMsg(2, 1, { body: "가나다" })]);
    const generated = await one(
      "select a.attgenerated as generated, format_type(a.atttypid, a.atttypmod) as type from pg_attribute a where a.attrelid = 'public.claude_app_chat_messages'::regclass and a.attname = 'body_bytes' and not a.attisdropped",
    );
    expect(generated).toEqual({ generated: "s", type: "integer" });
    expect((await rows(String(made.chat_id))).map((r) => r.body)).toEqual(["보낸 글 1", "가나다"]);
    expect((await q("select body_bytes, octet_length(body) as n from public.claude_app_chat_messages where chat_id = $1 order by seq", [String(made.chat_id)])).map((r) => [Number(r.body_bytes), Number(r.n)])).toEqual([
      [12, 12],
      [9, 9],
    ]);
    await expect(q("update public.claude_app_chat_messages set body_bytes = 1 where chat_id = $1", [String(made.chat_id)])).rejects.toBeDefined();
    const index = String((await one("select pg_get_indexdef('public.claude_app_chat_messages_user_idx'::regclass) as def")).def);
    expect(index).toMatch(/\(user_id\) INCLUDE \(body_bytes\)/);
    // 합계 SQL이 이 인덱스를 index-only로 읽는다 (작은 표라 계획기가 순차 스캔을 고르지 못하게 끄고, 가시성 맵을 채우려고 vacuum 한 번 하고 본다)
    await q("vacuum (analyze) public.claude_app_chat_messages");
    await q("set enable_seqscan = off");
    try {
      const plan = (await q("explain (costs off) select coalesce(sum(body_bytes + 512), 0), count(*) from public.claude_app_chat_messages where user_id = $1", [w.owner])).map((r) => String(Object.values(r)[0])).join("\n");
      expect(plan).toMatch(/Index Only Scan using claude_app_chat_messages_user_idx/);
    } finally {
      await q("reset enable_seqscan");
    }
  });

  it("사용자별 한도 · 행 수: 사용자당 20만 행 하드 상한과 행 몫 512바이트는 함수 안의 SQL 상수이고, 같은 잠금 아래 같은 합계 질의로 확인한다", async () => {
    const def = String((await one(`select pg_get_functiondef('public.${SIGNATURE}'::regprocedure) as def`)).def);
    expect(def).toMatch(new RegExp(`c_max_user_rows constant integer := ${QUOTA_ROWS};`));
    expect(def).toMatch(new RegExp(`c_row_overhead constant integer := ${ROW_OVERHEAD};`));
    expect(def).toMatch(/c_max_user_bytes constant bigint := 52428800;/);
    // 한 질의로 (합계, 행 수)를 구한다 — 두 번 훑지 않는다
    expect(def).toMatch(/sum\(m\.body_bytes \+ c_row_overhead\)[\s\S]*count\(\*\)[\s\S]*from public\.claude_app_chat_messages m where m\.user_id = p_user_id/);
    expect(def).toMatch(/v_used > c_max_user_bytes or v_rows > c_max_user_rows/);
    // 사용자별 잠금은 이 확인보다 앞에서 잡는다
    expect(def.indexOf("pg_advisory_xact_lock")).toBeGreaterThan(-1);
    expect(def.indexOf("pg_advisory_xact_lock")).toBeLessThan(def.indexOf("v_used > c_max_user_bytes or v_rows > c_max_user_rows"));
  });

  it("사용자별 한도 · 채팅: 채팅이 2,000개이면 새 채팅을 만드는 묶음은 quota_exceeded. 있는 채팅에 붙이기 · 답 글만 온 묶음은 영향 없고, 지우면 다시 만들 수 있다", HEAVY, async () => {
    const w = await world();
    const other = await world();
    // 1,999개를 SQL로 채운다 (Mac이 둘 이상이어도 사용자 합계로 센다)
    const second = await bridge(w.owner);
    await q(`insert into public.claude_app_chats (user_id, bridge_id, session_ref) select $1, $2, lpad(to_hex(g + 1000000), 64, '0') from generate_series(1, 1000) g`, [w.owner, w.bridge]);
    await q(`insert into public.claude_app_chats (user_id, bridge_id, session_ref) select $1, $2, lpad(to_hex(g + 1000000), 64, '0') from generate_series(1, 999) g`, [w.owner, second]);
    expect(await chatCount(w.owner)).toBe(QUOTA_CHATS - 1);
    // 2,000번째는 만들어진다
    const last = await save(w.owner, w.bridge, ref(1), null, [userMsg(1)]);
    expect(last).toMatchObject({ status: "ok", saved: 1 });
    expect(await chatCount(w.owner)).toBe(QUOTA_CHATS);
    // 2,001번째 (다른 session_ref, 다른 Mac이어도 같다)는 quota_exceeded: 채팅도 지표도 만들지 않는다
    const events0 = (await events(w.owner, "claude_app_message_sent")).length;
    expect(await save(w.owner, w.bridge, ref(2), null, [userMsg(1)])).toEqual({ status: "quota_exceeded" });
    expect(await save(w.owner, second, ref(3), null, [userMsg(1)])).toEqual({ status: "quota_exceeded" });
    expect(await chatCount(w.owner)).toBe(QUOTA_CHATS);
    expect((await events(w.owner, "claude_app_message_sent")).length).toBe(events0);
    // 있는 채팅에 붙이기와 재시도는 된다. 채팅을 만들지 않는 묶음(답 글만)은 한도를 묻지 않는다
    expect(await save(w.owner, w.bridge, ref(1), null, [asstMsg(2, 1)])).toMatchObject({ status: "ok", saved: 1, chat_id: last.chat_id });
    expect(await save(w.owner, w.bridge, ref(1), null, [userMsg(1)])).toMatchObject({ status: "ok", saved: 0, existing: 1 });
    expect(await save(w.owner, w.bridge, ref(4), null, [asstMsg(5, 4)])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 1 });
    // 다른 사용자는 영향 없다
    expect(await save(other.owner, other.bridge, ref(2), null, [userMsg(1)])).toMatchObject({ status: "ok" });
    // 하나 지우면 새 채팅을 만들 수 있다
    expect(await one("select public.delete_claude_app_chat($1, $2) as result", [w.owner, String(last.chat_id)])).toEqual({ result: { status: "deleted" } });
    expect(await save(w.owner, w.bridge, ref(2), null, [userMsg(11)])).toMatchObject({ status: "ok", saved: 1 });
  });

  // ───────────────────────── 지운 대화는 재시도로 되살아나지 않는다 (코드 검토 P2-4: 묘비) ─────────────────────────

  it("묘비: 지울 때 **사용자 글의 mac_ref만** (bridge, session_ref)별로 남기고, 묘비에 든 사용자 글은 orphan으로 거절된다 — 저장도 지표도 없다 (지운 뒤 재시도가 대화를 되살리지 못한다)", async () => {
    const w = await world();
    const batch = [userMsg(1), asstMsg(2, 1, { tool_names: ["Read"] })];
    const first = await save(w.owner, w.bridge, ref(1), "제목", batch);
    expect((await events(w.owner, "claude_app_message_sent")).length).toBe(1);
    expect(await one("select public.delete_claude_app_chat($1, $2) as result", [w.owner, String(first.chat_id)])).toEqual({ result: { status: "deleted" } });
    // 묘비 = 사용자 글의 ref뿐 (답 글 ref · 글 · 제목 없음)
    expect(await q("select session_ref, mac_ref, bridge_id, user_id from public.claude_app_chat_tombstones where user_id = $1", [w.owner])).toEqual([{ session_ref: ref(1), mac_ref: ref(1), bridge_id: w.bridge, user_id: w.owner }]);
    // 응답을 못 받은 Mac이 같은 묶음을 다시 보낸다: 채팅 · 행 · 지표 0, 사용자 글과 답 글 모두 orphan
    expect(await save(w.owner, w.bridge, ref(1), "제목", batch)).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 2 });
    expect(await chatCount(w.owner)).toBe(0);
    expect(await messageCount(w.owner)).toBe(0);
    expect((await events(w.owner, "claude_app_message_sent")).length).toBe(1);
    // 새로 보낸 글(새 ref)은 새 채팅을 만든다
    const fresh = await save(w.owner, w.bridge, ref(1), "제목", [userMsg(5), asstMsg(6, 5)]);
    expect(fresh).toMatchObject({ status: "ok", saved: 2 });
    expect(fresh.chat_id).not.toBe(first.chat_id);
    expect((await events(w.owner, "claude_app_message_sent")).length).toBe(2);
    // 새 채팅이 있는 동안에도 옛 묶음의 재시도는 되살아나지 않는다
    expect(await save(w.owner, w.bridge, ref(1), "제목", batch)).toEqual({ status: "ok", chat_id: fresh.chat_id, saved: 0, existing: 0, orphan: 2 });
    expect((await rows(String(fresh.chat_id))).map((r) => r.mac_ref)).toEqual([ref(5), ref(6)]);
    expect((await events(w.owner, "claude_app_message_sent")).length).toBe(2);
    // 섞인 묶음: 묘비에 든 사용자 글만 orphan, 나머지는 저장 (지표는 새 사용자 글 하나)
    expect(await save(w.owner, w.bridge, ref(1), "제목", [userMsg(1), userMsg(7), asstMsg(8, 7)])).toEqual({ status: "ok", chat_id: fresh.chat_id, saved: 2, existing: 0, orphan: 1 });
    expect((await events(w.owner, "claude_app_message_sent")).length).toBe(3);
    // 같은 ref라도 다른 session_ref(다른 대화) · 다른 Mac은 막지 않는다
    expect(await save(w.owner, w.bridge, ref(2), "다른 세션", [userMsg(1)])).toMatchObject({ status: "ok", saved: 1 });
    const otherBridge = await bridge(w.owner);
    expect(await save(w.owner, otherBridge, ref(1), "다른 Mac", [userMsg(1)])).toMatchObject({ status: "ok", saved: 1 });
  });

  it("묘비는 불투명한 ref뿐이다: 열이 (user_id, bridge_id, session_ref, mac_ref, created_at)뿐이고 글 · 제목이 없으며, 앱은 읽지도 못한다", async () => {
    const w = await world();
    const made = await save(w.owner, w.bridge, ref(1), "비밀 제목", [userMsg(1, { body: "비밀 글" }), asstMsg(2, 1, { body: "비밀 답", tool_names: ["Bash"] })]);
    await one("select public.delete_claude_app_chat($1, $2)", [w.owner, String(made.chat_id)]);
    const columns = (await q("select column_name from information_schema.columns where table_schema = 'public' and table_name = 'claude_app_chat_tombstones' order by column_name")).map((r) => r.column_name);
    expect(columns).toEqual(["bridge_id", "created_at", "mac_ref", "session_ref", "user_id"]);
    expect(JSON.stringify(await q("select * from public.claude_app_chat_tombstones where user_id = $1", [w.owner]))).not.toMatch(/비밀|Bash/);
    expect(await one("select relrowsecurity as enabled from pg_class where oid = 'public.claude_app_chat_tombstones'::regclass")).toEqual({ enabled: true });
    expect(await one("select count(*)::int as n from pg_policies where schemaname = 'public' and tablename = 'claude_app_chat_tombstones' and policyname = 'owner_all'")).toEqual({ n: 1 });
    for (const role of ["anon", "authenticated"]) {
      expect(await one("select has_table_privilege($1, 'public.claude_app_chat_tombstones', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') as granted", [role]), role).toEqual({ granted: false });
    }
    await db().asUser(w.owner, async () => {
      await expect(q("select 1 from public.claude_app_chat_tombstones")).rejects.toMatchObject({ code: "42501" });
      await expect(q("insert into public.claude_app_chat_tombstones (bridge_id, session_ref, mac_ref) values ($1, $2, $3)", [w.bridge, ref(9), ref(9)])).rejects.toMatchObject({ code: "42501" });
    });
    // 모양: ref는 소문자 hex 64자, 남의 bridge를 가리킬 수 없다
    await expect(q("insert into public.claude_app_chat_tombstones (user_id, bridge_id, session_ref, mac_ref) values ($1, $2, $3, $4)", [w.owner, w.bridge, ref(9), "Z".repeat(64)])).rejects.toMatchObject({ code: "23514" });
    const bob = await world();
    await expect(q("insert into public.claude_app_chat_tombstones (user_id, bridge_id, session_ref, mac_ref) values ($1, $2, $3, $4)", [bob.owner, w.bridge, ref(9), ref(9)])).rejects.toMatchObject({ code: "23503" });
  });

  it("묘비: bridge를 해제해도 남고, bridge를 지우거나 계정을 지우면 함께 지워진다. 남의 채팅 삭제는 묘비를 만들지 않는다", async () => {
    const alice = await world();
    const bob = await world();
    const a = await save(alice.owner, alice.bridge, ref(1), null, [userMsg(1)]);
    const spare = await bridge(alice.owner);
    const b = await save(alice.owner, spare, ref(1), null, [userMsg(1)]);
    const c = await save(bob.owner, bob.bridge, ref(1), null, [userMsg(1)]);
    const tombs = (owner: string) => count("select 1 from public.claude_app_chat_tombstones where user_id = $1", [owner]);
    // 남의 id · 없는 id 삭제는 묘비 0
    expect(await one("select public.delete_claude_app_chat($1, $2) as result", [bob.owner, String(a.chat_id)])).toEqual({ result: { status: "not_found" } });
    expect(await tombs(bob.owner)).toBe(0);
    await one("select public.delete_claude_app_chat($1, $2)", [alice.owner, String(a.chat_id)]);
    await one("select public.delete_claude_app_chat($1, $2)", [alice.owner, String(b.chat_id)]);
    await one("select public.delete_claude_app_chat($1, $2)", [bob.owner, String(c.chat_id)]);
    expect(await tombs(alice.owner)).toBe(2);
    expect(await tombs(bob.owner)).toBe(1);
    await q("update public.bridges set status = 'revoked', revoked_at = now() where id = $1", [alice.bridge]);
    expect(await tombs(alice.owner)).toBe(2);
    await q("delete from public.bridges where id = $1", [spare]);
    expect(await tombs(alice.owner)).toBe(1);
    await q("delete from auth.users where id = $1", [alice.owner]);
    expect(await tombs(alice.owner)).toBe(0);
    expect(await tombs(bob.owner)).toBe(1);
  });

  it(`묘비는 사용자별 ${"10,000"}개까지만 둔다 (가장 오래된 것부터 지운다): 재시도는 몇 분 안의 일이라 새 것이면 충분하다`, HEAVY, async () => {
    await withLongStatements(async () => {
      const w = await world();
      await q(
        `insert into public.claude_app_chat_tombstones (user_id, bridge_id, session_ref, mac_ref, created_at)
         select $1, $2, lpad(to_hex(9999), 64, '0'), lpad(to_hex(g), 64, '0'), now() - interval '2 days' from generate_series(1, $3::int) g`,
        [w.owner, w.bridge, TOMBSTONE_CAP],
      );
      const made = await save(w.owner, w.bridge, ref(1), null, [userMsg(1), userMsg(2), userMsg(3), asstMsg(4, 1)]);
      await one("select public.delete_claude_app_chat($1, $2)", [w.owner, String(made.chat_id)]);
      expect(await count("select 1 from public.claude_app_chat_tombstones where user_id = $1", [w.owner])).toBe(TOMBSTONE_CAP);
      // 새 묘비 셋(사용자 글 셋)은 남고, 가장 오래된 셋이 밀려났다
      expect(await count("select 1 from public.claude_app_chat_tombstones where user_id = $1 and session_ref = $2", [w.owner, ref(1)])).toBe(3);
      expect(await count("select 1 from public.claude_app_chat_tombstones where user_id = $1 and session_ref <> $2", [w.owner, ref(1)])).toBe(TOMBSTONE_CAP - 3);
      // 방금 지운 대화의 재시도는 여전히 막힌다
      expect(await save(w.owner, w.bridge, ref(1), null, [userMsg(1), userMsg(2), userMsg(3)])).toEqual({ status: "ok", chat_id: null, saved: 0, existing: 0, orphan: 3 });
    });
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
    for (const fn of ["save_claude_app_chat", "delete_claude_app_chat", "delete_all_claude_app_chats"]) {
      const def = String((await one("select pg_get_functiondef(p.oid) as def from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = $1", [fn])).def);
      expect(def, fn).not.toMatch(/bridge_commands|agent_tasks|agent_sessions|conversations|conversation_messages|start_agent_turn|execution_|pg_notify|net\.http/i);
    }
  });
}
