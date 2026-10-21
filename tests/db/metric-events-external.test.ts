import { randomUUID } from "node:crypto";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 외부 세션 지표 (OA 외부 세션 PR1): external_sessions_shown은 route(서버 권한)가 남긴다 — 앱 insert 정책은 그대로(app_opened · assistant_opened)라
// 앱이 직접 이 종류나 props를 쓸 수 없다. 하루 한 번(UTC 날짜별 부분 unique 인덱스).

let db: PGlite;
beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);
afterAll(async () => {
  await db?.close();
});

async function user() {
  const id = randomUUID();
  await db.query("insert into auth.users (id, email) values ($1, $2)", [id, `${id}@example.com`]);
  return id;
}

const shown = (owner: string, at?: string) =>
  db.query("insert into public.metric_events (user_id, type, props, at) values ($1, 'external_sessions_shown', $2::jsonb, coalesce($3::timestamptz, now()))", [
    owner,
    JSON.stringify({ rows_bucket: "2-5", held_bucket: "0" }),
    at ?? null,
  ]);

describe("metric_events: external_sessions_shown", () => {
  it("종류 검사가 받고, 기존 종류는 그대로 받는다", async () => {
    const owner = await user();
    await shown(owner);
    for (const type of ["app_opened", "assistant_opened", "session_resumed", "billing_checkout_started", "ai_key_saved"]) {
      await db.query("insert into public.metric_events (user_id, type) values ($1, $2)", [owner, type]);
    }
    await expect(db.query("insert into public.metric_events (user_id, type) values ($1, 'external_sessions_hidden')", [owner])).rejects.toMatchObject({ code: "23514" });
  });

  it("앱(authenticated)은 자기 행으로 app_opened · assistant_opened만 직접 남기고, 이 종류와 props는 직접 쓸 수 없다", async () => {
    const owner = await user();
    const other = await user();
    await asUser(db, owner, async () => {
      await db.query("insert into public.metric_events (type) values ('app_opened')");
      await db.query("insert into public.metric_events (type) values ('assistant_opened')");
      for (const type of ["external_sessions_shown", "agent_message_sent", "session_resumed", "billing_checkout_started", "session_attached"]) {
        await expect(db.query("insert into public.metric_events (type) values ($1)", [type]), type).rejects.toMatchObject({ code: expect.stringMatching(/^(42501|23514)$/) });
      }
      await expect(db.query("insert into public.metric_events (type, props) values ('app_opened', '{\"rows_bucket\":\"1\"}')")).rejects.toMatchObject({ code: "42501" });
      await expect(db.query("insert into public.metric_events (user_id, type) values ($1, 'app_opened')", [other])).rejects.toMatchObject({ code: "42501" });
    });
  });

  it("하루(UTC 날짜)에 한 번만 들어가고, 다른 날과 다른 사용자는 따로 센다", async () => {
    const owner = await user();
    const other = await user();
    await shown(owner, "2026-10-21T00:00:00Z");
    await expect(shown(owner, "2026-10-21T23:59:59Z")).rejects.toMatchObject({ code: "23505" });
    await shown(owner, "2026-10-22T00:00:00Z");
    await shown(other, "2026-10-21T12:00:00Z");
    const { rows } = await db.query<{ n: number }>("select count(*)::int as n from public.metric_events where user_id = $1 and type = 'external_sessions_shown'", [owner]);
    expect(rows[0].n).toBe(2);
  });

  it("같은 날 다른 종류는 막지 않는다 (인덱스는 이 종류만)", async () => {
    const owner = await user();
    await db.query("insert into public.metric_events (user_id, type) values ($1, 'app_opened'), ($1, 'app_opened')", [owner]);
  });
});
