import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { actionRowValues, claimToRow } from "@/lib/actions/rows";
import { userCreatedAction } from "@/lib/actions/user-claims";

import { asUser, createLocalSupabase } from "./local-supabase";

// 직접 추가 (20261008000000_user_created_actions_doc_author): 사용자 Claim만으로 만든 Action과 user_created 이벤트.
// 서버(createUserAction)가 write_action에 넘기는 것과 같은 모양으로 쓴다 (lib/actions/db-store.ts writeAction).

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const NO_SOURCE = "44444444-4444-4444-8444-444444444444";
const WITH_SOURCE = "55555555-5555-4555-8555-555555555555";

let db: PGlite;
let source: string;
let n = 0;

async function createUserAction(actionId: string, input: { title: string; dueDate: string | null; source: { id: string; quote: string } | null }) {
  const { claims, projected, event } = userCreatedAction(
    { title: input.title, dueDate: input.dueDate, sourceId: input.source?.id ?? null },
    new Date("2026-09-28T10:00:00+09:00"),
    () => `66666666-6666-4666-8666-${String(++n).padStart(12, "0")}`,
  );
  const evidence = input.source ? { sourceId: input.source.id, quote: input.source.quote } : { sourceId: null, quote: null };
  await db.query(`select public.write_action($1, $2, null, $3::jsonb, $4::jsonb, $5::jsonb, $6::jsonb)`, [
    ALICE,
    actionId,
    JSON.stringify({ ...actionRowValues(projected), counterpart: null, embedding: null }),
    JSON.stringify(claims.map((c) => claimToRow(c, ALICE, actionId, evidence))),
    JSON.stringify(input.source ? [{ source_id: input.source.id, quote: input.source.quote, role: "created" }] : []),
    JSON.stringify([{ ...event, actor: "user", source_id: evidence.sourceId }]),
  ]);
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
  source = (
    await db.query<{ id: string }>(`insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'meeting', '금요일까지 견적서 보내드릴게요', now()) returning id`, [ALICE])
  ).rows[0].id;
}, 60_000);

describe("직접 추가한 Action", () => {
  it("원문 없이: 사용자 Claim · user_created 이벤트만 남고 근거는 없다", async () => {
    await createUserAction(NO_SOURCE, { title: "견적서 보내기", dueDate: "2026-10-02", source: null });

    const { rows: actions } = await db.query(`select title, owner, status, due_date::text, needs_confirmation, confirm_reasons from public.actions where id = $1`, [NO_SOURCE]);
    expect(actions).toEqual([{ title: "견적서 보내기", owner: "me", status: "open", due_date: "2026-10-02", needs_confirmation: false, confirm_reasons: [] }]);
    const { rows: claims } = await db.query(`select field, origin, channel, source_id from public.claims where action_id = $1 order by field`, [NO_SOURCE]);
    expect(claims).toEqual(
      ["due", "owner", "scope", "status"].map((field) => ({ field, origin: "user", channel: "note", source_id: null })),
    );
    expect((await db.query(`select id from public.evidence where action_id = $1`, [NO_SOURCE])).rows).toEqual([]);
    const { rows: events } = await db.query(`select type, actor, source_id, after->>'source_id' as after_source from public.action_events where action_id = $1`, [NO_SOURCE]);
    expect(events).toEqual([{ type: "user_created", actor: "user", source_id: null, after_source: null }]);
  });

  it("원문 구절을 고르면 근거(created)와 이벤트에 원문이 붙는다", async () => {
    await createUserAction(WITH_SOURCE, { title: "견적서 보내기", dueDate: null, source: { id: source, quote: "금요일까지 견적서 보내드릴게요" } });

    const { rows: evidence } = await db.query(`select source_id, quote, role from public.evidence where action_id = $1`, [WITH_SOURCE]);
    expect(evidence).toEqual([{ source_id: source, quote: "금요일까지 견적서 보내드릴게요", role: "created" }]);
    const { rows: events } = await db.query(`select type, actor, source_id, after->>'source_id' as after_source from public.action_events where action_id = $1`, [WITH_SOURCE]);
    expect(events).toEqual([{ type: "user_created", actor: "user", source_id: source, after_source: source }]);
  });

  it("모르는 이벤트 종류는 여전히 거절한다", async () => {
    await expect(
      db.query(`insert into public.action_events (user_id, action_id, type, actor) values ($1, $2, 'user_invented', 'user')`, [ALICE, NO_SOURCE]),
    ).rejects.toThrow(/action_events_type_check/);
  });

  it("본인 것만 보이고, 클라이언트는 직접 만들 수 없다", async () => {
    await asUser(db, BOB, async () => {
      expect((await db.query(`select id from public.actions`)).rows).toEqual([]);
      await expect(db.query(`insert into public.action_events (action_id, type, actor) values ($1, 'user_created', 'user')`, [NO_SOURCE])).rejects.toThrow();
    });
    await asUser(db, ALICE, async () => {
      expect((await db.query(`select id from public.actions order by id`)).rows).toEqual([{ id: NO_SOURCE }, { id: WITH_SOURCE }]);
    });
  });

  it("임베딩 없이 만든 Action은 매칭 후보가 아니고, 원문 처리가 채우면(service role) 후보가 된다", async () => {
    // lib/actions/db-store.ts unembedded · saveEmbedding과 같은 쿼리
    const vector = `[${Array.from({ length: 1536 }, (_, i) => (i === 0 ? 1 : 0)).join(",")}]`;
    const match = async () =>
      (await db.query<{ id: string }>(`select id from public.match_open_actions($1, $2, 10)`, [ALICE, vector])).rows.map((r) => r.id).sort();
    expect(await match()).toEqual([]);

    await db.exec("set role service_role");
    try {
      const { rows: unembedded } = await db.query<{ id: string; quote: string | null }>(
        `select a.id, (select e.quote from public.evidence e where e.user_id = a.user_id and e.action_id = a.id and e.role = 'created' order by e.created_at limit 1) as quote
         from public.actions a where a.user_id = $1 and a.status = 'open' and a.embedding is null order by a.created_at limit 20`,
        [ALICE],
      );
      expect(unembedded).toEqual([
        { id: NO_SOURCE, quote: null },
        { id: WITH_SOURCE, quote: "금요일까지 견적서 보내드릴게요" },
      ]);
      for (const { id } of unembedded) {
        await db.query(`update public.actions set embedding = $3 where user_id = $1 and id = $2 and embedding is null`, [ALICE, id, vector]);
      }
    } finally {
      await db.exec("reset role");
    }
    expect(await match()).toEqual([NO_SOURCE, WITH_SOURCE].sort());
  });
});
