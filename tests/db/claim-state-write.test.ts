import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { createLocalSupabase } from "./local-supabase";

const USER = "00000000-0000-0000-0000-00000000000a";
const ACTION_DISPUTED = "11111111-1111-4111-8111-111111111111";
const ACTION_ACTIVE = "22222222-2222-4222-8222-222222222222";
const ACTION_INVALID = "33333333-3333-4333-8333-333333333333";
const CLAIM_DISPUTED = "44444444-4444-4444-8444-444444444444";
const CLAIM_ACTIVE = "55555555-5555-4555-8555-555555555555";
const CLAIM_INVALID = "66666666-6666-4666-8666-666666666666";

let db: PGlite;
let sourceId: string;

const action = JSON.stringify({
  title: "회의록 보내기",
  counterpart: null,
  owner: "me",
  due_date: null,
  due_at: null,
  status: "open",
  needs_confirmation: false,
  confirm_reasons: [],
  resolution: {},
  embedding: null,
});

function claim(id: string, state?: string) {
  return JSON.stringify([
    {
      id,
      source_id: sourceId,
      field: "owner",
      value: "me",
      quote: "내가 보낼게요",
      occurred_at: "2026-09-30T10:00:00Z",
      speaker_role: "me",
      certainty: "tentative",
      directness: "first_hand",
      audience: "shared",
      origin: "source",
      channel: "meeting",
      ...(state ? { state } : {}),
    },
  ]);
}

async function write(actionId: string, claims: string) {
  return db.query<{ write_action: boolean }>(
    `select public.write_action($1, $2, null, $3::jsonb, $4::jsonb, '[]'::jsonb, '[]'::jsonb)`,
    [USER, actionId, action, claims],
  );
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com')", [USER]);
  sourceId = (
    await db.query<{ id: string }>(
      `insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'meeting', 'fixture', now()) returning id`,
      [USER],
    )
  ).rows[0].id;
}, 60_000);

describe("write_action: Claim.state persistence", () => {
  it("RPC write/read 경로에서 disputed 상태를 보존한다", async () => {
    const result = await write(ACTION_DISPUTED, claim(CLAIM_DISPUTED, "disputed"));
    expect(result.rows[0].write_action).toBe(true);

    const stored = await db.query<{ state: string }>(`select state from public.claims where id = $1`, [CLAIM_DISPUTED]);
    expect(stored.rows[0].state).toBe("disputed");
  });

  it("state가 없는 기존 RPC payload는 active 기본값을 유지한다", async () => {
    const result = await write(ACTION_ACTIVE, claim(CLAIM_ACTIVE));
    expect(result.rows[0].write_action).toBe(true);

    const stored = await db.query<{ state: string }>(`select state from public.claims where id = $1`, [CLAIM_ACTIVE]);
    expect(stored.rows[0].state).toBe("active");
  });

  it("허용되지 않은 상태는 거부하고 Action 쓰기도 되돌린다", async () => {
    await expect(write(ACTION_INVALID, claim(CLAIM_INVALID, "unknown"))).rejects.toThrow();
    const stored = await db.query<{ n: number }>(`select count(*)::int n from public.actions where id = $1`, [ACTION_INVALID]);
    expect(stored.rows[0].n).toBe(0);
  });
});
