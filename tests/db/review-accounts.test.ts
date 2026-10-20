import type { PGlite } from "@electric-sql/pglite";
import { beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// App Store 심사 계정 (20261007000000_review_account_signup_hook): 허용 목록의 주소는 늘 받는다.
// 이메일 가입은 이제 모두에게 열려 있다 (20261201000000_email_signup_open): 목록 밖의 주소는 일회용 도메인 · 상한만 막는다 (email-signup-hook.test.ts가 자세히 본다).
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
  // 시험 DB의 auth.users는 (id, email)뿐이라(tests/db/local-supabase.ts) 훅이 읽는 실제 Supabase 열을 더한다
  await db.exec(`
    alter table auth.users
      add column raw_app_meta_data jsonb not null default '{}'::jsonb,
      add column email_confirmed_at timestamptz,
      add column created_at timestamptz not null default now();
    grant usage on schema auth to supabase_auth_admin;
    grant select on auth.users to supabase_auth_admin;
  `);
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com')", [ALICE]);
  await db.query(`insert into public.review_accounts (email, note) values ('appreview@taskforcelabs.dev', 'App Store 심사')`);
}, 60_000);

describe("hook_before_user_created", () => {
  it("허용 목록의 이메일 가입은 받는다 (대소문자 · 앞뒤 공백 무시)", async () => {
    expect(await hook("email", "appreview@taskforcelabs.dev")).toEqual({});
    expect(await hook("email", " AppReview@TaskforceLabs.dev ")).toEqual({});
  });

  it("목록에 없는 이메일 가입도 받는다 (이메일 가입을 모두에게 열었다). 이메일이 비면 403", async () => {
    expect(await hook("email", "someone@example.com")).toEqual({});
    expect((await hook("email", null)).error).toMatchObject({ http_code: 403 });
  });

  it("Sign in with Apple 가입은 그대로 받는다", async () => {
    expect(await hook("apple", "abc@privaterelay.appleid.com")).toEqual({});
    expect(await hook("apple", null)).toEqual({});
  });

  it("Sign in with Google 가입은 그대로 받는다", async () => {
    expect(await hook("google", "someone@gmail.com")).toEqual({});
    expect(await hook("google", "Someone@Example.com")).toEqual({});
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
