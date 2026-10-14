import { randomUUID } from "node:crypto";
import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { createLocalSupabase } from "./local-supabase";

let db: PGlite;
let user: string, otherUser: string, bridge: string, otherBridge: string, foreignBridge: string;
beforeAll(async () => { db = await createLocalSupabase(); }, 60_000);
afterAll(async () => { await db?.close(); });
beforeEach(async () => {
  [user, otherUser, bridge, otherBridge, foreignBridge] = Array.from({ length: 5 }, () => randomUUID());
  await db.query("insert into auth.users(id) values($1),($2)", [user, otherUser]);
  await db.query("insert into public.bridges(id,user_id,device_ref) values($1,$2,'first'),($3,$2,'second'),($4,$5,'first')",
    [bridge, user, otherBridge, foreignBridge, otherUser]);
});
const take = async (kind: string, max: number, owner = user, device: string | null = bridge) =>
  (await db.query<{ retry_at: Date | null }>("select public.take_rate_limit($1,$2,$3,60,$4) as retry_at", [owner, kind, max, device])).rows[0].retry_at;
const rows = async () => (await db.query<{ user_id: string; bridge_id: string; kind: string; created_at: Date }>("select user_id,bridge_id,kind,created_at from public.rate_limit_events where user_id=any($1::uuid[]) order by user_id,bridge_id,kind,created_at", [[user, otherUser]])).rows;

describe("bridge rate limits (PGlite)", () => {
  it.each([["bridge_events", 120], ["bridge_ack", 240], ["bridge_poll", 90]] as const)("%s admits exactly %i requests per minute", async (kind, max) => {
    for (let n = 0; n < max; n++) expect(await take(kind, max)).toBeNull();
    const before = await rows();
    expect(before).toHaveLength(max);
    const retry = (await db.query<{ retry_at: Date }>("select min(created_at)+interval '60 seconds' as retry_at from public.rate_limit_events where user_id=$1 and bridge_id=$2 and kind=$3", [user, bridge, kind])).rows[0].retry_at;
    expect(await take(kind, max)).toEqual(retry);
    expect(await take(kind, max)).toEqual(retry);
    expect(await rows()).toEqual(before);
    await db.query("update public.rate_limit_events set created_at=clock_timestamp()-interval '61 seconds' where user_id=$1 and bridge_id=$2 and kind=$3", [user, bridge, kind]);
    expect(await take(kind, max)).toBeNull();
    expect(await rows()).toHaveLength(max + 1);
  });

  it("separates kind, device and user buckets", async () => {
    expect(await take("bridge_events", 1)).toBeNull();
    expect(await take("bridge_events", 1)).toBeInstanceOf(Date);
    expect(await take("bridge_ack", 1)).toBeNull();
    expect(await take("bridge_poll", 1)).toBeNull();
    expect(await take("bridge_events", 1, user, otherBridge)).toBeNull();
    expect(await take("bridge_events", 1, otherUser, foreignBridge)).toBeNull();
    expect((await rows()).map(({ user_id, bridge_id, kind }) => ({ user_id, bridge_id, kind }))).toEqual(expect.arrayContaining([
      { user_id: user, bridge_id: bridge, kind: "bridge_events" },
      { user_id: user, bridge_id: bridge, kind: "bridge_ack" },
      { user_id: user, bridge_id: bridge, kind: "bridge_poll" },
      { user_id: user, bridge_id: otherBridge, kind: "bridge_events" },
      { user_id: otherUser, bridge_id: foreignBridge, kind: "bridge_events" },
    ]));
    expect(await rows()).toHaveLength(5);
  });

  it.each(["bridge_events", "bridge_ack", "bridge_poll"])("%s rejects missing and foreign device identities without inserts", async (kind) => {
    const before = await rows();
    for (const device of [null, foreignBridge, randomUUID()]) {
      await expect(take(kind, 1, user, device)).rejects.toMatchObject({ code: "22023" });
      expect(await rows()).toEqual(before);
    }
  });
});
