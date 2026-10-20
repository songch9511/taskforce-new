import type { PGlite } from "@electric-sql/pglite";
import { afterEach, beforeAll, describe, expect, it } from "vitest";

import { asUser, createLocalSupabase } from "./local-supabase";

// 미확인 이메일 가입 정리 (20261201000000_email_signup_open): 코드를 요청하고 24시간 안에 넣지 않은 가입을 매일 지운다.
// 시험 DB의 auth.users는 (id, email)뿐이라(tests/db/local-supabase.ts) 정리가 읽는 실제 Supabase 열과 auth.identities를 여기서 더한다.

const ALICE = "00000000-0000-0000-0000-00000000000a";

let db: PGlite;

type Row = { id: string; email: string };

/** auth.users 한 행 (기본값은 24시간이 지난 미확인 이메일 가입 = 지우는 행) */
async function user(
  email: string,
  {
    hoursAgo = 25,
    provider = "email",
    confirmed = false,
    signedIn = false,
    sso = false,
    identities = ["email"],
  }: { hoursAgo?: number; provider?: string; confirmed?: boolean; signedIn?: boolean; sso?: boolean; identities?: string[] } = {},
): Promise<string> {
  const { rows } = await db.query<{ id: string }>(
    `insert into auth.users (id, email, raw_app_meta_data, email_confirmed_at, last_sign_in_at, is_sso_user, created_at)
     values (gen_random_uuid(), $1, jsonb_build_object('provider', $2::text), case when $3::boolean then now() else null end,
             case when $4::boolean then now() else null end, $5::boolean, now() - make_interval(hours => $6::int))
     returning id`,
    [email, provider, confirmed, signedIn, sso, hoursAgo],
  );
  for (const identity of identities) {
    await db.query(`insert into auth.identities (user_id, provider) values ($1, $2)`, [rows[0].id, identity]);
  }
  return rows[0].id;
}

async function purge(role = "service_role"): Promise<number> {
  await db.exec(`set role ${role}`);
  try {
    const { rows } = await db.query<{ n: number }>(`select public.purge_unconfirmed_email_signups() as n`);
    return rows[0].n;
  } finally {
    await db.exec("reset role");
  }
}

async function emails(): Promise<string[]> {
  const { rows } = await db.query<Row>(`select id, email from auth.users where email <> 'alice@example.com' order by email`);
  return rows.map((r) => r.email);
}

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.exec(`
    alter table auth.users
      add column raw_app_meta_data jsonb not null default '{}'::jsonb,
      add column email_confirmed_at timestamptz,
      add column last_sign_in_at timestamptz,
      add column created_at timestamptz not null default now(),
      add column is_sso_user boolean not null default false;
    create table auth.identities (
      id uuid primary key default gen_random_uuid(),
      user_id uuid not null references auth.users (id) on delete cascade,
      provider text not null
    );
  `);
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com')", [ALICE]);
  await db.query(`insert into public.review_accounts (email, note) values ('appreview@taskforcelabs.dev', 'App Store 심사')`);
}, 60_000);

afterEach(async () => {
  await db.exec(`delete from auth.users where email <> 'alice@example.com'`);
});

describe("purge_unconfirmed_email_signups", () => {
  it("24시간이 지난 미확인 이메일 가입만 지우고 identity도 함께 지운다", async () => {
    const gone = await user("gone@example.com");
    await user("also-gone@example.com", { hoursAgo: 24 * 30 });
    expect(await purge()).toBe(2);
    expect(await emails()).toEqual([]);
    const { rows } = await db.query(`select 1 from auth.identities where user_id = $1`, [gone]);
    expect(rows).toEqual([]);
  });

  it("23시간 된 가입은 남긴다", async () => {
    await user("recent@example.com", { hoursAgo: 23 });
    expect(await purge()).toBe(0);
    expect(await emails()).toEqual(["recent@example.com"]);
  });

  it("코드를 넣어 확인된 사용자는 남긴다", async () => {
    await user("confirmed@example.com", { confirmed: true });
    expect(await purge()).toBe(0);
    expect(await emails()).toEqual(["confirmed@example.com"]);
  });

  it("로그인한 적이 있으면 남긴다", async () => {
    await user("signed-in@example.com", { signedIn: true });
    expect(await purge()).toBe(0);
  });

  it("Google · Apple identity가 붙었으면 남긴다 (미확인이어도)", async () => {
    await user("linked-google@example.com", { identities: ["email", "google"] });
    await user("linked-apple@example.com", { identities: ["apple"] });
    expect(await purge()).toBe(0);
    expect(await emails()).toEqual(["linked-apple@example.com", "linked-google@example.com"]);
  });

  it("Apple · Google · 그 밖의 방법으로 가입한 사용자는 남긴다", async () => {
    await user("g@example.com", { provider: "google", identities: ["google"] });
    await user("a@example.com", { provider: "apple", identities: ["apple"] });
    await user("p@example.com", { provider: "phone", identities: [] });
    expect(await purge()).toBe(0);
    expect(await emails()).toHaveLength(3);
  });

  it("심사 허용 목록의 주소는 남긴다 (대소문자 무시)", async () => {
    await user("AppReview@TaskforceLabs.dev");
    expect(await purge()).toBe(0);
    expect(await emails()).toEqual(["AppReview@TaskforceLabs.dev"]);
  });

  it("SSO 사용자는 남긴다", async () => {
    await user("sso@example.com", { sso: true });
    expect(await purge()).toBe(0);
  });

  it("지울 것과 남길 것이 섞여 있으면 지울 것만 지운다", async () => {
    await user("gone1@example.com");
    await user("keep-recent@example.com", { hoursAgo: 2 });
    await user("gone2@example.com", { hoursAgo: 50 });
    await user("keep-confirmed@example.com", { confirmed: true });
    expect(await purge()).toBe(2);
    expect(await emails()).toEqual(["keep-confirmed@example.com", "keep-recent@example.com"]);
  });

  it("한 번에 1,000행까지만 지우고 남은 것은 다음 실행에 지운다 (오래된 것부터)", async () => {
    await db.query(
      `insert into auth.users (id, email, raw_app_meta_data, created_at)
       select gen_random_uuid(), 'bulk' || lpad(g::text, 4, '0') || '@example.com', '{"provider":"email"}', now() - make_interval(hours => 25, mins => 2000 - g)
       from generate_series(1, 1205) g`,
    );
    expect(await purge()).toBe(1000);
    const left = await emails();
    expect(left).toHaveLength(205);
    // 만든 지 오래된 것부터 지운다: g가 작을수록 오래됐으니 남는 것은 1001–1205번이다
    expect(left[0]).toBe("bulk1001@example.com");
    expect(left[204]).toBe("bulk1205@example.com");
    expect(await purge()).toBe(205);
    expect(await emails()).toEqual([]);
  }, 120_000);

  it("다른 사용자의 데이터는 건드리지 않는다", async () => {
    await user("gone@example.com");
    await purge();
    const { rows } = await db.query<{ email: string }>(`select email from auth.users`);
    expect(rows.map((r) => r.email)).toEqual(["alice@example.com"]);
  });
});

describe("purge_unconfirmed_email_signups 실행 권한", () => {
  it("service_role만 실행한다", async () => {
    await user("gone@example.com");
    for (const role of ["anon", "authenticated", "supabase_auth_admin"]) {
      await db.exec(`set role ${role}`);
      try {
        await expect(db.query(`select public.purge_unconfirmed_email_signups()`), role).rejects.toThrow(/permission denied/);
      } finally {
        await db.exec("reset role");
      }
    }
    expect(await emails()).toEqual(["gone@example.com"]);
    expect(await purge("service_role")).toBe(1);
  });

  it("로그인한 사용자도 부를 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.purge_unconfirmed_email_signups()`)).rejects.toThrow(/permission denied/);
    });
  });
});
