import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { createLocalSupabase } from "./local-supabase";

const USER = "00000000-0000-0000-0000-00000000000a";

let db: PGlite;
let actionId: string;
let sourceId: string;

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com')", [USER]);
  actionId = (await db.query<{ id: string }>("insert into public.actions (user_id, title) values ($1, '제안서 발송') returning id", [USER])).rows[0].id;
  sourceId = (
    await db.query<{ id: string }>(
      "insert into public.sources (user_id, kind, raw_text, occurred_at) values ($1, 'email', '보내겠습니다', now()) returning id",
      [USER],
    )
  ).rows[0].id;
}, 60_000);

describe("claims.speaker_role", () => {
  it("원문 화자를 판별하지 못했을 때 unknown Claim을 저장한다", async () => {
    const { rows } = await db.query<{ speaker_role: string }>(
      `insert into public.claims
         (user_id, action_id, source_id, field, value, quote, occurred_at, speaker_role,
          certainty, directness, audience, channel, origin)
       values ($1, $2, $3, 'status', 'done', '보내겠습니다', now(), 'unknown',
               'firm', 'first_hand', 'shared', 'email', 'source')
       returning speaker_role`,
      [USER, actionId, sourceId],
    );

    expect(rows).toEqual([{ speaker_role: "unknown" }]);
  });
});
