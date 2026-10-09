import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 0.2.0 맥락층 · 대화 뼈대 (20261102000000_context_core): 표 9개의 RLS · 권한 · 복합 외래키 · CHECK · on delete.
// 앱은 자기 행을 읽기만 하고(owner_all + select 권한), 쓰기는 서버(service role)만 한다. 아직 이 표를 쓰는 코드는 없다.

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";

const TABLES = [
  "people",
  "work_contexts",
  "context_members",
  "memory_items",
  "identity_links",
  "source_chunks",
  "inbox_events",
  "conversations",
  "conversation_messages",
] as const;
type Table = (typeof TABLES)[number];

const vector = (hot: number, length = 1536) => `[${Array.from({ length }, (_, i) => (i === hot ? 1 : 0)).join(",")}]`;

type Seed = Record<Table, string> & { connection: string; source: string; action: string };

let db: PGlite;
let alice: Seed;
let bob: Seed;

async function one(sql: string, params: unknown[] = []): Promise<string> {
  return (await db.query<{ id: string }>(sql, params)).rows[0].id;
}

/** 서버(service role)가 쓰듯 한 사용자의 행을 9개 표 모두에 하나 이상 넣는다 */
async function seed(userId: string): Promise<Seed> {
  const connection = await one(
    `insert into public.connections (user_id, provider, external_account_id) values ($1, 'notion', 'ws') returning id`,
    [userId],
  );
  const source = await one(
    `insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id, external_id, external_version)
     values ($1, 'doc', 'Shape 출시 준비', now(), $2, 'page-1', 'v1') returning id`,
    [userId, connection],
  );
  const action = await one(`insert into public.actions (user_id, title) values ($1, 'Shape 디자인') returning id`, [userId]);
  const people = await one(
    `insert into public.people (user_id, display_name, emails, handles, origin)
     values ($1, '지훈', '{jihoon@example.com}', '{"slack": "T1:U2"}', 'source') returning id`,
    [userId],
  );
  const work_contexts = await one(`insert into public.work_contexts (user_id, name, kind) values ($1, 'Shape 출시 준비', 'project') returning id`, [
    userId,
  ]);
  const context_members = await one(
    `insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user') returning id`,
    [userId, work_contexts, action],
  );
  const conversations = await one(`insert into public.conversations (user_id, title, context_id) values ($1, 'Shape', $2) returning id`, [
    userId,
    work_contexts,
  ]);
  const conversation_messages = await one(
    `insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text)
     values ($1, $2, 1, 'user', gen_random_uuid(), '디자인 확정 뒤 개발 시작') returning id`,
    [userId, conversations],
  );
  const memory_items = await one(
    `insert into public.memory_items (user_id, kind, scope_kind, context_id, statement, value, origin, source_ref)
     values ($1, 'condition', 'context', $2, '디자인 확정 뒤 개발 시작', '{"start_after": {"kind": "design_approved"}}', 'explicit', $3)
     returning id`,
    [userId, work_contexts, JSON.stringify({ message_id: conversation_messages })],
  );
  const identity_links = await one(
    `insert into public.identity_links (user_id, provider, account_ref, email, connection_id, verified_via)
     values ($1, 'notion', 'notion-user-1', 'me@example.com', $2, 'oauth') returning id`,
    [userId, connection],
  );
  const source_chunks = await one(
    `insert into public.source_chunks (user_id, source_id, source_revision, seq, text, embedding) values ($1, $2, 'v1', 0, 'Shape 출시 준비', $3) returning id`,
    [userId, source, vector(0)],
  );
  const inbox_events = await one(
    `insert into public.inbox_events (user_id, type, dedup_key, refs) values ($1, 'source_processed', $2, $3) returning id`,
    [userId, `source:${source}:v1`, JSON.stringify({ source_id: source })],
  );
  return {
    connection,
    source,
    action,
    people,
    work_contexts,
    context_members,
    memory_items,
    identity_links,
    source_chunks,
    inbox_events,
    conversations,
    conversation_messages,
  };
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  alice = await seed(ALICE);
  bob = await seed(BOB);
}, 60_000);

describe("맥락층 · 대화 표 RLS · 권한 (20261102000000_context_core)", () => {
  it("9개 표 모두 RLS가 켜져 있고 정책은 owner_all 하나다 (authenticated, 본인 행)", async () => {
    const { rows } = await db.query<{ tablename: string; policyname: string; cmd: string; roles: string[]; qual: string; with_check: string }>(
      `select tablename, policyname, cmd, roles, qual, with_check from pg_policies where schemaname = 'public' and tablename = any($1) order by tablename`,
      [[...TABLES]],
    );
    expect(rows.map((r) => r.tablename)).toEqual([...TABLES].sort());
    for (const row of rows) {
      expect(row, row.tablename).toMatchObject({ policyname: "owner_all", cmd: "ALL", roles: ["authenticated"] });
      expect(row.qual, row.tablename).toMatch(/user_id = \(\s*SELECT auth\.uid\(\)/);
      expect(row.with_check, row.tablename).toMatch(/user_id = \(\s*SELECT auth\.uid\(\)/);
    }
    const rls = await db.query<{ relname: string; relrowsecurity: boolean }>(
      `select c.relname, c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = any($1)`,
      [[...TABLES]],
    );
    expect(rls.rows).toHaveLength(TABLES.length);
    for (const row of rls.rows) expect(row, row.relname).toMatchObject({ relrowsecurity: true });
  });

  it("앱(authenticated)은 select 권한만 있고 anon은 아무 권한도 없다", async () => {
    const { rows } = await db.query<{ relname: string; privileges: Record<string, boolean> }>(
      `select c.relname, jsonb_build_object(
          'auth_select', has_table_privilege('authenticated', c.oid, 'select'),
          'auth_insert', has_table_privilege('authenticated', c.oid, 'insert'),
          'auth_update', has_table_privilege('authenticated', c.oid, 'update'),
          'auth_delete', has_table_privilege('authenticated', c.oid, 'delete'),
          'auth_truncate', has_table_privilege('authenticated', c.oid, 'truncate'),
          'anon_select', has_table_privilege('anon', c.oid, 'select'),
          'anon_insert', has_table_privilege('anon', c.oid, 'insert'),
          'service_insert', has_table_privilege('service_role', c.oid, 'insert')) as privileges
       from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = any($1)`,
      [[...TABLES]],
    );
    expect(rows).toHaveLength(TABLES.length);
    for (const row of rows) {
      expect(row.privileges, row.relname).toEqual({
        auth_select: true,
        auth_insert: false,
        auth_update: false,
        auth_delete: false,
        auth_truncate: false,
        anon_select: false,
        anon_insert: false,
        service_insert: true,
      });
    }
  });

  it.each(TABLES)("%s: 사용자는 자기 행을 RLS로 읽는다", async (table) => {
    await asUser(db, ALICE, async () => {
      const { rows } = await db.query<{ id: string; user_id: string }>(`select id, user_id from public.${table}`);
      expect(rows.map((r) => r.id)).toContain(alice[table]);
      expect(rows.every((r) => r.user_id === ALICE)).toBe(true);
    });
  });

  it.each(TABLES)("%s: 다른 사용자의 행은 보이지 않는다 (0행)", async (table) => {
    await asUser(db, BOB, async () => {
      expect((await db.query(`select * from public.${table} where id = $1`, [alice[table]])).rows).toHaveLength(0);
      expect((await db.query(`select * from public.${table} where user_id = $1`, [ALICE])).rows).toHaveLength(0);
      // 자기 행은 보인다
      expect((await db.query(`select * from public.${table} where id = $1`, [bob[table]])).rows).toHaveLength(1);
    });
  });

  it.each(TABLES)("%s: 앱은 만들거나 고치거나 지울 수 없고, anon은 읽지도 못한다", async (table) => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`insert into public.${table} (user_id) values ($1)`, [ALICE])).rejects.toThrow(/permission denied/);
      await expect(db.query(`update public.${table} set user_id = user_id where id = $1`, [alice[table]])).rejects.toThrow(/permission denied/);
      await expect(db.query(`delete from public.${table} where id = $1`, [alice[table]])).rejects.toThrow(/permission denied/);
    });
    await db.exec("set role anon");
    try {
      await expect(db.query(`select * from public.${table}`)).rejects.toThrow(/permission denied/);
    } finally {
      await db.exec("reset role");
    }
    // 서버가 쓴 행은 그대로다
    expect((await db.query(`select 1 from public.${table} where id = $1`, [alice[table]])).rows).toHaveLength(1);
  });
});

describe("복합 외래키: 다른 사용자의 부모를 가리킬 수 없다 (서버 코드가 섞어도 막힌다)", () => {
  // work_contexts · inbox_events는 auth.users 말고 부모가 없다. 남의 user_id로 만드는 것은 위의 권한 · RLS 검사가 막는다
  const cases: Array<[string, () => [string, unknown[]]]> = [
    ["context_members.context_id → work_contexts", () => [
      `insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user')`,
      [ALICE, bob.work_contexts, alice.action],
    ]],
    ["context_members.action_id → actions", () => [
      `insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user')`,
      [ALICE, alice.work_contexts, bob.action],
    ]],
    ["context_members.source_id → sources", () => [
      `insert into public.context_members (user_id, context_id, member_kind, source_id, origin) values ($1, $2, 'source', $3, 'auto')`,
      [ALICE, alice.work_contexts, bob.source],
    ]],
    ["context_members.person_id → people", () => [
      `insert into public.context_members (user_id, context_id, member_kind, person_id, origin) values ($1, $2, 'person', $3, 'auto')`,
      [ALICE, alice.work_contexts, bob.people],
    ]],
    ["memory_items.context_id → work_contexts", () => [
      `insert into public.memory_items (user_id, kind, scope_kind, context_id, statement, origin) values ($1, 'goal', 'context', $2, '출시', 'explicit')`,
      [ALICE, bob.work_contexts],
    ]],
    ["memory_items.action_id → actions", () => [
      `insert into public.memory_items (user_id, kind, scope_kind, action_id, statement, origin) values ($1, 'goal', 'action', $2, '출시', 'explicit')`,
      [ALICE, bob.action],
    ]],
    ["memory_items.person_id → people", () => [
      `insert into public.memory_items (user_id, kind, scope_kind, person_id, statement, origin) values ($1, 'relationship', 'counterpart', $2, '결정권자', 'explicit')`,
      [ALICE, bob.people],
    ]],
    ["memory_items.superseded_by → memory_items", () => [
      `insert into public.memory_items (user_id, kind, scope_kind, statement, origin, superseded_by) values ($1, 'fact', 'global', '옛 사실', 'explicit', $2)`,
      [ALICE, bob.memory_items],
    ]],
    ["people.merged_into → people", () => [
      `insert into public.people (user_id, display_name, origin, merged_into) values ($1, '지훈', 'user', $2)`,
      [ALICE, bob.people],
    ]],
    ["identity_links.connection_id → connections", () => [
      `insert into public.identity_links (user_id, provider, account_ref, connection_id, verified_via) values ($1, 'notion', 'other', $2, 'oauth')`,
      [ALICE, bob.connection],
    ]],
    ["source_chunks.source_id → sources", () => [
      `insert into public.source_chunks (user_id, source_id, source_revision, seq, text) values ($1, $2, 'v9', 0, '조각')`,
      [ALICE, bob.source],
    ]],
    ["conversations.context_id → work_contexts", () => [
      `insert into public.conversations (user_id, context_id) values ($1, $2)`,
      [ALICE, bob.work_contexts],
    ]],
    ["conversation_messages.conversation_id → conversations", () => [
      `insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text) values ($1, $2, 99, 'user', gen_random_uuid(), '안녕')`,
      [ALICE, bob.conversations],
    ]],
  ];

  it.each(cases)("%s", async (_label, build) => {
    const [sql, params] = build();
    await expect(db.query(sql, params)).rejects.toThrow(/foreign key/);
  });
});

describe("CHECK · unique 제약", () => {
  const memory = (columns: Record<string, unknown>) => {
    const row = { user_id: ALICE, kind: "fact", scope_kind: "global", statement: "사실", origin: "explicit", ...columns };
    const names = Object.keys(row);
    return db.query(
      `insert into public.memory_items (${names.join(", ")}) values (${names.map((_, i) => `$${i + 1}`).join(", ")}) returning id`,
      Object.values(row),
    );
  };

  it("memory_items: observed는 source_ref가 있어야 하고, source_ref는 원문 id를 하나 이상 담는다", async () => {
    await expect(memory({ origin: "observed" })).rejects.toThrow(/memory_items_observed_source/);
    await expect(memory({ origin: "observed", source_ref: JSON.stringify({ quote: "인용만" }) })).rejects.toThrow(/memory_items_source_ref_check/);
    await expect(memory({ origin: "observed", source_ref: JSON.stringify(["source_id"]) })).rejects.toThrow(/memory_items_source_ref_check/);
    const ok = await memory({ origin: "observed", source_ref: JSON.stringify({ source_id: alice.source, quote: "Shape 출시 준비" }) });
    expect(ok.rows).toHaveLength(1);
  });

  it("memory_items: confidence는 inferred에만, inferred에는 반드시", async () => {
    await expect(memory({ origin: "explicit", confidence: 0.9 })).rejects.toThrow(/memory_items_confidence_inferred/);
    await expect(memory({ origin: "inferred" })).rejects.toThrow(/memory_items_confidence_inferred/);
    await expect(memory({ origin: "inferred", confidence: 1.5 })).rejects.toThrow(/memory_items_confidence_check/);
    expect((await memory({ origin: "inferred", confidence: 0.6 })).rows).toHaveLength(1);
  });

  it("memory_items: 범위와 대상 열이 맞아야 한다", async () => {
    await expect(memory({ scope_kind: "context" })).rejects.toThrow(/memory_items_scope_target/);
    await expect(memory({ scope_kind: "global", action_id: alice.action })).rejects.toThrow(/memory_items_scope_target/);
    await expect(memory({ scope_kind: "action", context_id: alice.work_contexts })).rejects.toThrow(/memory_items_scope_target/);
    await expect(memory({ scope_kind: "agent" })).rejects.toThrow(/memory_items_scope_target/);
    expect((await memory({ scope_kind: "agent", kind: "working_rule", agent_adapter: "agent:claude-code" })).rows).toHaveLength(1);
    expect((await memory({ scope_kind: "counterpart", kind: "relationship", person_id: alice.people })).rows).toHaveLength(1);
    expect((await memory({ scope_kind: "action", kind: "outcome_criteria", action_id: alice.action })).rows).toHaveLength(1);
  });

  it("memory_items: 빈 statement는 출처 글이 지워진 observed 항목뿐이다", async () => {
    await expect(memory({ statement: "" })).rejects.toThrow(/memory_items_statement_purged/);
    await expect(memory({ statement: "남은 글", origin: "observed", source_ref: JSON.stringify({ source_id: alice.source }), source_purged: true })).rejects.toThrow(
      /memory_items_statement_purged/,
    );
    await expect(memory({ statement: "", source_purged: true })).rejects.toThrow(/memory_items_purged_observed/);
    const purged = await memory({ statement: "", origin: "observed", source_ref: JSON.stringify({ source_id: alice.source }), source_purged: true });
    expect(purged.rows).toHaveLength(1);
  });

  it("memory_items: 종류 · 범위 · origin 값, 유효 구간, 자기 자신으로 정정, version", async () => {
    await expect(memory({ kind: "preference" })).rejects.toThrow(/memory_items_kind_check/);
    await expect(memory({ scope_kind: "team" })).rejects.toThrow(/memory_items_scope_kind_check/);
    await expect(memory({ origin: "user" })).rejects.toThrow(/memory_items_origin_check/);
    await expect(memory({ valid_from: "2026-10-10T00:00:00Z", valid_until: "2026-10-09T00:00:00Z" })).rejects.toThrow(/memory_items_valid_range/);
    const id = "22222222-2222-4222-8222-222222222222";
    await expect(memory({ id, superseded_by: id })).rejects.toThrow(/memory_items_not_superseded_by_self/);
    await expect(memory({ version: 0 })).rejects.toThrow(/memory_items_version_check/);
  });

  it("context_members: 멤버 열은 정확히 하나이고 member_kind와 맞는다. 같은 범위에 같은 멤버는 한 번", async () => {
    const member = (columns: string, values: unknown[]) =>
      db.query(`insert into public.context_members (user_id, context_id, ${columns}) values ($1, $2, ${values.map((_, i) => `$${i + 3}`).join(", ")})`, [
        ALICE,
        alice.work_contexts,
        ...values,
      ]);
    await expect(member("member_kind, origin", ["action", "user"])).rejects.toThrow(/context_members_one_member/);
    await expect(member("member_kind, action_id, source_id, origin", ["action", alice.action, alice.source, "user"])).rejects.toThrow(
      /context_members_one_member/,
    );
    await expect(member("member_kind, action_id, origin", ["source", alice.action, "user"])).rejects.toThrow(/context_members_one_member/);
    // 시드가 이미 이 범위에 이 Action을 넣었다
    await expect(member("member_kind, action_id, origin", ["action", alice.action, "auto"])).rejects.toThrow(
      /duplicate key value violates unique constraint "context_members_context_id_action_id_key"/,
    );
    await expect(member("member_kind, source_id, origin, confidence", ["source", alice.source, "auto", 0.5])).rejects.toThrow(
      /context_members_confidence_inferred/,
    );
    await expect(member("member_kind, source_id, origin", ["source", alice.source, "inferred"])).rejects.toThrow(/context_members_confidence_inferred/);
    await expect(member("member_kind, source_id, origin", ["source", alice.source, "manual"])).rejects.toThrow(/context_members_origin_check/);
    await member("member_kind, source_id, origin, confidence", ["source", alice.source, "inferred", 0.7]);
    await member("member_kind, person_id, origin", ["person", alice.people, "auto"]);
    await expect(member("member_kind, person_id, origin", ["person", alice.people, "user"])).rejects.toThrow(/context_members_context_id_person_id_key/);
  });

  it("conversation_messages: 같은 대화에서 client_message_id · seq는 한 번, 사용자 메시지는 id가 있고 4,000자 이하", async () => {
    const conversation = await one(`insert into public.conversations (user_id) values ($1) returning id`, [ALICE]);
    const other = await one(`insert into public.conversations (user_id) values ($1) returning id`, [ALICE]);
    const clientId = "33333333-3333-4333-8333-333333333333";
    const message = (conversationId: string, seq: number, role: string, client: string | null, text: string) =>
      db.query(
        `insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text) values ($1, $2, $3, $4, $5, $6)`,
        [ALICE, conversationId, seq, role, client, text],
      );

    await message(conversation, 1, "user", clientId, "이 세 건 진행해줘");
    await expect(message(conversation, 2, "user", clientId, "이 세 건 진행해줘")).rejects.toThrow(
      /conversation_messages_conversation_id_client_message_id_key/,
    );
    await message(other, 1, "user", clientId, "다른 대화에서는 같은 id여도 된다");
    await expect(message(conversation, 1, "assistant", null, "중복 seq")).rejects.toThrow(/conversation_messages_conversation_id_seq_key/);
    await expect(message(conversation, 0, "assistant", null, "seq는 1부터")).rejects.toThrow(/conversation_messages_seq_check/);
    await expect(message(conversation, 3, "user", null, "id 없는 사용자 메시지")).rejects.toThrow(/conversation_messages_user_message/);
    await expect(message(conversation, 3, "user", "44444444-4444-4444-8444-444444444444", "가".repeat(4001))).rejects.toThrow(
      /conversation_messages_user_message/,
    );
    await message(conversation, 3, "user", "44444444-4444-4444-8444-444444444444", "가".repeat(4000));
    await message(conversation, 4, "assistant", null, "가".repeat(4001));
    await message(conversation, 5, "event", null, "");
    await expect(message(conversation, 6, "system", null, "x")).rejects.toThrow(/conversation_messages_role_check/);
    await expect(
      db.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, refs) values ($1, $2, 7, 'event', '[]')`, [ALICE, conversation]),
    ).rejects.toThrow(/conversation_messages_refs_check/);
    await expect(db.query(`insert into public.conversations (user_id, title) values ($1, $2)`, [ALICE, "가".repeat(201)])).rejects.toThrow(
      /conversations_title_check/,
    );
  });

  it("inbox_events: dedup_key는 사용자마다 한 번, type은 소문자 이름", async () => {
    await expect(
      db.query(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'source_processed', $2)`, [ALICE, `source:${alice.source}:v1`]),
    ).rejects.toThrow(/inbox_events_user_id_dedup_key_key/);
    // 다른 사용자는 같은 키를 써도 된다 (시드가 이미 Bob의 키를 넣었다. 키 문자열이 같으면 된다)
    await db.query(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'timer', 'same-key')`, [ALICE]);
    await db.query(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'timer', 'same-key')`, [BOB]);
    await expect(db.query(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'Reply Observed', 'k2')`, [ALICE])).rejects.toThrow(
      /inbox_events_type_check/,
    );
    await expect(db.query(`insert into public.inbox_events (user_id, type, dedup_key) values ($1, 'timer', '')`, [ALICE])).rejects.toThrow(
      /inbox_events_dedup_key_check/,
    );
  });

  it("identity_links · people · work_contexts 값", async () => {
    await expect(
      db.query(`insert into public.identity_links (user_id, provider, account_ref, verified_via) values ($1, 'slack', 'U1', 'guess')`, [ALICE]),
    ).rejects.toThrow(/identity_links_verified_via_check/);
    await expect(
      db.query(`insert into public.identity_links (user_id, provider, account_ref, verified_via) values ($1, 'notion', 'notion-user-1', 'profile')`, [ALICE]),
    ).rejects.toThrow(/identity_links_user_id_provider_account_ref_key/);
    await db.query(`insert into public.identity_links (user_id, provider, account_ref, verified_via, shared_account) values ($1, 'gmail', 'team@example.com', 'user_confirmed', true)`, [
      ALICE,
    ]);

    await expect(db.query(`insert into public.people (user_id, display_name, origin) values ($1, 'x', 'guess')`, [ALICE])).rejects.toThrow(/people_origin_check/);
    await expect(db.query(`insert into public.people (user_id, display_name, origin, handles) values ($1, 'x', 'user', '[]')`, [ALICE])).rejects.toThrow(
      /people_handles_check/,
    );
    const self = "55555555-5555-4555-8555-555555555555";
    await expect(db.query(`insert into public.people (id, user_id, display_name, origin, merged_into) values ($1, $2, 'x', 'user', $1)`, [self, ALICE])).rejects.toThrow(
      /people_not_merged_into_self/,
    );

    await expect(db.query(`insert into public.work_contexts (user_id, name, kind) values ($1, 'x', 'team')`, [ALICE])).rejects.toThrow(/work_contexts_kind_check/);
    await expect(db.query(`insert into public.work_contexts (user_id, name, kind, status) values ($1, 'x', 'goal', 'done')`, [ALICE])).rejects.toThrow(
      /work_contexts_status_check/,
    );
    await expect(db.query(`insert into public.work_contexts (user_id, name, kind, context_version) values ($1, 'x', 'goal', 0)`, [ALICE])).rejects.toThrow(
      /work_contexts_context_version_check/,
    );
    await expect(db.query(`insert into public.work_contexts (user_id, name, kind) values ($1, '', 'goal')`, [ALICE])).rejects.toThrow(/work_contexts_name_check/);
    // 같은 이름의 범위 둘은 둘로 둔다 (자동 병합 없음)
    await db.query(`insert into public.work_contexts (user_id, name, kind) values ($1, 'Shape 출시 준비', 'project')`, [ALICE]);
    const defaults = await db.query(`select status, context_version from public.work_contexts where id = $1`, [alice.work_contexts]);
    expect(defaults.rows).toEqual([{ status: "active", context_version: 1 }]);
  });

  it("source_chunks: (원문, revision, 순번)은 한 번 (revision 없는 원문 포함), 임베딩은 1536차원", async () => {
    const chunk = (revision: string | null, seq: number, embedding: string | null = null) =>
      db.query(`insert into public.source_chunks (user_id, source_id, source_revision, seq, text, embedding) values ($1, $2, $3, $4, '조각', $5)`, [
        ALICE,
        alice.source,
        revision,
        seq,
        embedding,
      ]);
    await expect(chunk("v1", 0)).rejects.toThrow(/source_chunks_position/);
    await chunk("v2", 0); // 새 revision은 새 조각
    await chunk(null, 0);
    await expect(chunk(null, 0)).rejects.toThrow(/source_chunks_position/);
    await expect(chunk("v3", -1)).rejects.toThrow(/source_chunks_seq_check/);
    await expect(chunk("v3", 0, vector(0, 2))).rejects.toThrow(/expected 1536 dimensions/);
    await expect(
      db.query(`insert into public.source_chunks (user_id, source_id, seq, text) values ($1, $2, 9, '')`, [ALICE, alice.source]),
    ).rejects.toThrow(/source_chunks_text_check/);
  });
});

describe("on delete: 부모를 지우면", () => {
  it("범위를 지우면 그 멤버 · 범위 기억은 지워지고 대화는 범위만 비운다 (All work)", async () => {
    const context = await one(`insert into public.work_contexts (user_id, name, kind) values ($1, '지울 범위', 'goal') returning id`, [ALICE]);
    await db.query(`insert into public.context_members (user_id, context_id, member_kind, action_id, origin) values ($1, $2, 'action', $3, 'user')`, [
      ALICE,
      context,
      alice.action,
    ]);
    const memoryId = await one(
      `insert into public.memory_items (user_id, kind, scope_kind, context_id, statement, origin) values ($1, 'goal', 'context', $2, '목표', 'explicit') returning id`,
      [ALICE, context],
    );
    const conversation = await one(`insert into public.conversations (user_id, context_id) values ($1, $2) returning id`, [ALICE, context]);

    await db.query(`delete from public.work_contexts where id = $1`, [context]);

    expect((await db.query(`select 1 from public.context_members where context_id = $1`, [context])).rows).toHaveLength(0);
    expect((await db.query(`select 1 from public.memory_items where id = $1`, [memoryId])).rows).toHaveLength(0);
    expect((await db.query(`select context_id from public.conversations where id = $1`, [conversation])).rows).toEqual([{ context_id: null }]);
    // 멤버였던 Action은 그대로다
    expect((await db.query(`select 1 from public.actions where id = $1`, [alice.action])).rows).toHaveLength(1);
  });

  it("원문을 지우면 그 조각 · 멤버십이 지워진다", async () => {
    const source = await one(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'note', '메모', now()) returning id`, [ALICE]);
    await db.query(`insert into public.source_chunks (user_id, source_id, seq, text) values ($1, $2, 0, '메모')`, [ALICE, source]);
    await db.query(`insert into public.context_members (user_id, context_id, member_kind, source_id, origin) values ($1, $2, 'source', $3, 'auto')`, [
      ALICE,
      alice.work_contexts,
      source,
    ]);
    await db.query(`delete from public.sources where id = $1`, [source]);
    expect((await db.query(`select 1 from public.source_chunks where source_id = $1`, [source])).rows).toHaveLength(0);
    expect((await db.query(`select 1 from public.context_members where source_id = $1`, [source])).rows).toHaveLength(0);
  });

  it("연결을 끊으면(행 삭제) 그 연결에서 온 신원 링크만 지워진다", async () => {
    const connection = await one(`insert into public.connections (user_id, provider, external_account_id) values ($1, 'slack', 'T9:U9') returning id`, [ALICE]);
    await db.query(`insert into public.identity_links (user_id, provider, account_ref, connection_id, verified_via) values ($1, 'slack', 'T9:U9', $2, 'oauth')`, [
      ALICE,
      connection,
    ]);
    await db.query(`insert into public.identity_links (user_id, provider, account_ref, verified_via) values ($1, 'slack', 'T9:U8', 'profile')`, [ALICE]);
    await db.query(`delete from public.connections where id = $1`, [connection]);
    const { rows } = await db.query<{ account_ref: string }>(`select account_ref from public.identity_links where user_id = $1 and provider = 'slack'`, [ALICE]);
    expect(rows).toEqual([{ account_ref: "T9:U8" }]);
  });

  it("합친 대상 사람 · 정정한 새 기억을 지우면 가리키던 쪽은 null이 된다 (옛 행은 남는다)", async () => {
    const target = await one(`insert into public.people (user_id, display_name, origin) values ($1, '대상', 'user') returning id`, [ALICE]);
    const merged = await one(`insert into public.people (user_id, display_name, origin, merged_into) values ($1, '합쳐진 사람', 'source', $2) returning id`, [
      ALICE,
      target,
    ]);
    await db.query(`delete from public.people where id = $1`, [target]);
    expect((await db.query(`select merged_into from public.people where id = $1`, [merged])).rows).toEqual([{ merged_into: null }]);

    const newer = await one(`insert into public.memory_items (user_id, kind, scope_kind, statement, origin) values ($1, 'fact', 'global', '지금은 Y', 'explicit') returning id`, [
      ALICE,
    ]);
    const older = await one(
      `insert into public.memory_items (user_id, kind, scope_kind, statement, origin, superseded_by) values ($1, 'fact', 'global', '이전엔 X', 'explicit', $2) returning id`,
      [ALICE, newer],
    );
    await db.query(`delete from public.memory_items where id = $1`, [newer]);
    expect((await db.query(`select superseded_by from public.memory_items where id = $1`, [older])).rows).toEqual([{ superseded_by: null }]);
  });

  it("대화를 지우면 메시지가 지워진다", async () => {
    const conversation = await one(`insert into public.conversations (user_id) values ($1) returning id`, [ALICE]);
    await db.query(`insert into public.conversation_messages (user_id, conversation_id, seq, role, client_message_id, text) values ($1, $2, 1, 'user', gen_random_uuid(), '안녕')`, [
      ALICE,
      conversation,
    ]);
    await db.query(`delete from public.conversations where id = $1`, [conversation]);
    expect((await db.query(`select 1 from public.conversation_messages where conversation_id = $1`, [conversation])).rows).toHaveLength(0);
  });
});

describe("updated_at · 트리거", () => {
  const UPDATED = ["people", "work_contexts", "context_members", "memory_items", "identity_links"] as const;

  it("updated_at이 있는 표는 기존 set_updated_at 트리거만 쓴다 (새 함수 없음)", async () => {
    const { rows } = await db.query<{ table: string; fn: string }>(
      `select c.relname as table, p.proname as fn from pg_trigger t
       join pg_class c on c.oid = t.tgrelid join pg_proc p on p.oid = t.tgfoid
       where not t.tgisinternal and c.relname = any($1) order by c.relname`,
      [[...TABLES]],
    );
    expect(rows).toEqual([...UPDATED].sort().map((table) => ({ table, fn: "set_updated_at" })));
  });

  it.each(UPDATED)("%s: 고치면 updated_at이 갱신된다", async (table) => {
    await db.query(`update public.${table} set updated_at = '2000-01-01' where id = $1`, [alice[table]]);
    const { rows } = await db.query<{ updated_at: Date }>(`select updated_at from public.${table} where id = $1`, [alice[table]]);
    expect(rows[0].updated_at.getFullYear()).toBeGreaterThan(2000);
  });
});
