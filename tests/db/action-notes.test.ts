import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

const ALICE = "00000000-0000-0000-0000-00000000000a";
const BOB = "00000000-0000-0000-0000-00000000000b";
const vector = (hot: number) => `[${Array.from({ length: 1536 }, (_, i) => (i === hot ? 1 : 0)).join(",")}]`;

let db: PGlite;

async function newAction(options: { status?: "open" | "done" | "dropped"; updatedAt?: string; embedding?: boolean } = {}) {
  const { rows } = await db.query<{ id: string }>(
    `insert into public.actions (user_id, title, status, updated_at, last_activity_at, embedding)
     values ($1, '제안서 발송', $2, $3, $3, $4) returning id`,
    [ALICE, options.status ?? "open", options.updatedAt ?? "2026-10-01T00:00:00Z", options.embedding ? vector(0) : null],
  );
  return rows[0].id;
}

async function save(actionId: string, markdown: string, expectedRevision: number, userId = ALICE) {
  return db.query<{ status: string; action_id: string | null; markdown: string | null; revision: number | null }>(
    "select * from public.save_action_notes($1, $2, $3, $4)",
    [userId, actionId, markdown, expectedRevision],
  );
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com'), ($2, 'bob@example.com')", [ALICE, BOB]);
}, 60_000);

describe("Action Markdown notes (20261029000000)", () => {
  it("defaults empty at revision zero and preserves exact whitespace/blank clearing through revisioned saves", async () => {
    const action = await newAction();
    const initial = (await db.query<{ notes_markdown: string; notes_revision: number }>("select notes_markdown, notes_revision from public.actions where id = $1", [action])).rows[0];
    expect(initial).toEqual({ notes_markdown: "", notes_revision: 0 });

    const markdown = "  \n## Constraints\n\tkeep whitespace\n\n";
    expect((await save(action, markdown, 0)).rows).toEqual([{ status: "saved", action_id: action, markdown, revision: 1 }]);
    expect((await save(action, "", 1)).rows).toEqual([{ status: "saved", action_id: action, markdown: "", revision: 2 }]);
    expect((await db.query<{ notes_markdown: string; notes_revision: number }>("select notes_markdown, notes_revision from public.actions where id = $1", [action])).rows[0])
      .toEqual({ notes_markdown: "", notes_revision: 2 });
  });

  it("uses compare-and-set revisions and does not emit a duplicate event for an exact no-op", async () => {
    const action = await newAction();
    await save(action, "first", 0);
    expect((await save(action, "first", 1)).rows[0]).toEqual({ status: "saved", action_id: action, markdown: "first", revision: 1 });
    expect((await save(action, "stale", 0)).rows[0]).toEqual({ status: "conflict", action_id: action, markdown: null, revision: 1 });
    expect((await db.query<{ n: number }>("select count(*)::int n from public.action_events where action_id = $1 and type = 'user_notes_updated'", [action])).rows[0].n).toBe(1);
    expect((await db.query<{ notes_markdown: string; notes_revision: number }>("select notes_markdown, notes_revision from public.actions where id = $1", [action])).rows[0])
      .toEqual({ notes_markdown: "first", notes_revision: 1 });
  });

  it("writes revision-only event metadata without changing Action activity, status, version, or closed-Action Ask recency", async () => {
    const old = "2026-08-01T00:00:00Z";
    const action = await newAction({ status: "done", updatedAt: old, embedding: true });
    const before = (await db.query<{ title: string; status: string; last_activity_at: Date; version: number; updated_at: Date }>(
      "select title, status, last_activity_at, version, updated_at from public.actions where id = $1", [action],
    )).rows[0];

    await save(action, "Constraint: three options", 0);

    const after = (await db.query<{ title: string; status: string; last_activity_at: Date; version: number; updated_at: Date; notes_revision: number }>(
      "select title, status, last_activity_at, version, updated_at, notes_revision from public.actions where id = $1", [action],
    )).rows[0];
    expect(after).toMatchObject({ ...before, notes_revision: 1 });
    const events = await db.query<{ type: string; actor: string; before: unknown; after: unknown; source_id: string | null }>(
      "select type, actor, before, after, source_id from public.action_events where action_id = $1", [action],
    );
    expect(events.rows).toEqual([{ type: "user_notes_updated", actor: "user", before: { revision: 0 }, after: { revision: 1 }, source_id: null }]);
    expect(JSON.stringify(events.rows)).not.toContain("Constraint: three options");

    const ask = (since: string) => db.query<{ id: string }>("select id from public.match_actions_for_ask($1, $2, 8, $3)", [ALICE, vector(0), since]);
    expect((await ask("2026-10-01T00:00:00Z")).rows).toEqual([]);
    await db.query("update public.actions set title = 'A field changed' where id = $1", [action]);
    const normallyUpdated = (await db.query<{ updated_at: Date }>("select updated_at from public.actions where id = $1", [action])).rows[0].updated_at;
    expect(normallyUpdated.getTime()).toBeGreaterThan(before.updated_at.getTime());
    expect((await ask("2026-10-01T00:00:00Z")).rows).toEqual([{ id: action }]);
  });

  it("returns not-found for another owner's Action and authenticated clients cannot write notes, events, or call the RPC", async () => {
    const action = await newAction();
    expect((await save(action, "private", 0, BOB)).rows[0]).toMatchObject({ status: "not_found", action_id: null, markdown: null });

    await asUser(db, ALICE, async () => {
      expect((await db.query("select notes_markdown from public.actions where id = $1", [action])).rows).toEqual([{ notes_markdown: "" }]);
      await expect(db.query("update public.actions set notes_markdown = 'direct' where id = $1", [action])).rejects.toThrow(/permission denied/);
      await expect(db.query("insert into public.action_events (action_id, type, actor) values ($1, 'user_notes_updated', 'user')", [action])).rejects.toThrow(/permission denied/);
      await expect(db.query("select * from public.save_action_notes($1, $2, 'rpc', 0)", [ALICE, action])).rejects.toThrow(/permission denied/);
    });
    await asUser(db, BOB, async () => {
      expect((await db.query("select notes_markdown from public.actions where id = $1", [action])).rows).toEqual([]);
    });
  });

  it("enforces the additive database character bound and nonnegative revision", async () => {
    const action = await newAction();
    await expect(db.query("update public.actions set notes_markdown = $2 where id = $1", [action, "x".repeat(10_001)])).rejects.toThrow(/actions_notes_markdown_length/);
    await expect(db.query("update public.actions set notes_revision = -1 where id = $1", [action])).rejects.toThrow(/actions_notes_revision_nonnegative/);
  });

  it("does not lose notes when a regular Action write updates judged fields", async () => {
    const action = await newAction();
    await save(action, "keep me", 0);
    const actionJson = JSON.stringify({ title: "Updated from source", counterpart: null, owner: "me", due_date: null, due_at: null, status: "open", needs_confirmation: false, confirm_reasons: [], resolution: null, embedding: null });
    await db.query("select public.write_action($1, $2, 0, $3::jsonb, '[]', '[]', '[]')", [ALICE, action, actionJson]);
    expect((await db.query<{ title: string; notes_markdown: string; notes_revision: number }>("select title, notes_markdown, notes_revision from public.actions where id = $1", [action])).rows[0])
      .toEqual({ title: "Updated from source", notes_markdown: "keep me", notes_revision: 1 });
  });
});
