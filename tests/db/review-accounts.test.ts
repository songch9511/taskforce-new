import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// App Store 심사 계정 (20261007000000_review_account_signup_hook): 이메일 가입은 허용 목록에 있는 주소만.
// Supabase Auth가 supabase_auth_admin 역할로 훅 함수를 부르는 것을 흉내 낸다.

const ALICE = "00000000-0000-0000-0000-00000000000a";

let db: PGlite;

const event = (provider: string, email: string | null) => ({
  metadata: { uuid: "8b34dcdd-9df1-4c10-850a-b3277c653040", name: "before-user-created" },
  user: { id: "ff7fc9ae-3b1b-4642-9241-64adb9848a03", email: email ?? "", app_metadata: { provider, providers: [provider] }, identities: [] },
});

async function hook(provider: string, email: string | null): Promise<Record<string, unknown>> {
  await db.exec("set role supabase_auth_admin");
  try {
    const { rows } = await db.query<{ result: Record<string, unknown> }>(`select public.hook_before_user_created($1::jsonb) as result`, [
      JSON.stringify(event(provider, email)),
    ]);
    return rows[0].result;
  } finally {
    await db.exec("reset role");
  }
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com')", [ALICE]);
  await db.query(`insert into public.review_accounts (email, note) values ('appreview@taskforcelabs.dev', 'App Store 심사')`);
}, 60_000);

describe("hook_before_user_created", () => {
  it("허용 목록의 이메일 가입은 받는다 (대소문자 · 앞뒤 공백 무시)", async () => {
    expect(await hook("email", "appreview@taskforcelabs.dev")).toEqual({});
    expect(await hook("email", " AppReview@TaskforceLabs.dev ")).toEqual({});
  });

  it("목록에 없는 이메일 가입은 403으로 거절한다", async () => {
    expect(await hook("email", "someone@example.com")).toEqual({
      error: { http_code: 403, message: "이메일로는 새로 가입할 수 없어요. Sign in with Apple을 사용해 주세요." },
    });
    expect((await hook("email", null)).error).toBeDefined();
  });

  it("Sign in with Apple 가입은 그대로 받는다", async () => {
    expect(await hook("apple", "abc@privaterelay.appleid.com")).toEqual({});
    expect(await hook("apple", null)).toEqual({});
  });

  it("Sign in with Google 가입은 그대로 받고, 같은 주소의 이메일 가입은 여전히 거절한다", async () => {
    expect(await hook("google", "someone@gmail.com")).toEqual({});
    expect(await hook("google", "Someone@Example.com")).toEqual({});
    expect((await hook("email", "someone@gmail.com")).error).toMatchObject({ http_code: 403 });
  });

  it("허용 목록은 소문자 주소만 받는다", async () => {
    await expect(db.query(`insert into public.review_accounts (email) values ('Upper@Example.com')`)).rejects.toThrow(/check/);
  });

  it("클라이언트는 훅을 부르거나 허용 목록을 읽을 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.hook_before_user_created('{}'::jsonb)`)).rejects.toThrow(/permission denied/);
      await expect(db.query(`select * from public.review_accounts`)).rejects.toThrow(/permission denied/);
      await expect(db.query(`insert into public.review_accounts (email) values ('me@example.com')`)).rejects.toThrow(/permission denied/);
    });
  });
});
