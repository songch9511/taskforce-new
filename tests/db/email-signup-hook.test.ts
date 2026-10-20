import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import {
  BLOCKLIST_FILE,
  blocklistUrl,
  isCommitSha,
  MIN_DOMAINS,
  NEVER_BLOCK_DOMAINS,
  parseBlocklist,
  runSync,
  sourceTag,
} from "../../scripts/sync-blocked-email-domains";
import { asUser, createLocalSupabase } from "./local-supabase";

// 이메일 가입 열기 (20261201000000_email_signup_open): Before User Created 훅이 일회용 도메인과 한 시간 미확인 가입 상한만 막는다.
// Supabase Auth가 supabase_auth_admin 역할로 훅 함수를 부르는 것을 흉내 낸다.
// 시험 DB의 auth.users는 (id, email)뿐이라(tests/db/local-supabase.ts) 훅이 읽는 실제 Supabase 열을 여기서 더한다.

const ALICE = "00000000-0000-0000-0000-00000000000a";

let db: PGlite;

// userMetadata: undefined면 user_metadata 키가 없는 이벤트
const event = (provider: string, email: string | null, userMetadata?: unknown) => ({
  metadata: { uuid: "8b34dcdd-9df1-4c10-850a-b3277c653040", name: "before-user-created", ip_address: "203.0.113.7" },
  user: {
    id: "ff7fc9ae-3b1b-4642-9241-64adb9848a03",
    email: email ?? "",
    app_metadata: { provider, providers: [provider] },
    ...(userMetadata === undefined ? {} : { user_metadata: userMetadata }),
    identities: [],
  },
});

async function hook(provider: string, email: string | null, userMetadata?: unknown): Promise<Record<string, unknown>> {
  await db.exec("set role supabase_auth_admin");
  try {
    const { rows } = await db.query<{ result: Record<string, unknown> }>(`select public.hook_before_user_created($1::jsonb) as result`, [
      JSON.stringify(event(provider, email, userMetadata)),
    ]);
    return rows[0].result;
  } finally {
    await db.exec("reset role");
  }
}

/** 방금 만든 미확인 이메일 사용자 n명 (코드를 요청하고 넣지 않은 가입) */
async function unconfirmedSignups(n: number, { minutesAgo = 10, provider = "email", confirmed = false } = {}) {
  await db.query(
    `insert into auth.users (id, email, raw_app_meta_data, email_confirmed_at, created_at)
     select gen_random_uuid(), 'bulk' || g || '-' || $4::text || '@bulk.test', jsonb_build_object('provider', $2::text),
            case when $3::boolean then now() else null end, now() - make_interval(mins => $1::int)
     from generate_series(1, $5::int) g`,
    [minutesAgo, provider, confirmed, `${provider}-${minutesAgo}-${confirmed}`, n],
  );
}

const blocked = { error: { http_code: 403, message: "This email address can't be used." } };
const tooMany = { error: { http_code: 429, message: "Too many new sign-ups. Try again later." } };

beforeAll(async () => {
  db = await createLocalSupabase();
  await db.exec(`
    alter table auth.users
      add column raw_app_meta_data jsonb not null default '{}'::jsonb,
      add column email_confirmed_at timestamptz,
      add column last_sign_in_at timestamptz,
      add column created_at timestamptz not null default now(),
      add column is_sso_user boolean not null default false,
      add column encrypted_password text;
    grant usage on schema auth to supabase_auth_admin;
    grant select on auth.users to supabase_auth_admin;
  `);
  await db.query("insert into auth.users (id, email) values ($1, 'alice@example.com')", [ALICE]);
  await db.query(`insert into public.review_accounts (email, note) values ('appreview@taskforcelabs.dev', 'App Store 심사')`);
  await db.query(`insert into public.blocked_email_domains (domain, source) values ('mailinator.com', 'test'), ('burner.example', 'test')`);
}, 60_000);

afterEach(async () => {
  await db.exec(`delete from auth.users where email like '%@bulk.test'`);
});

describe("hook_before_user_created: 이메일 가입을 연다", () => {
  it("일반 이메일 가입은 받는다 (대소문자 · 앞뒤 공백 무시)", async () => {
    expect(await hook("email", "someone@example.com")).toEqual({});
    expect(await hook("email", "  Someone@Example.COM ")).toEqual({});
  });

  it("심사 허용 목록의 가입은 늘 받는다 (차단 도메인 · 상한이 있어도)", async () => {
    expect(await hook("email", "appreview@taskforcelabs.dev")).toEqual({});
    await db.query(`insert into public.blocked_email_domains (domain, source) values ('taskforcelabs.dev', 'test')`);
    await unconfirmedSignups(15);
    try {
      expect(await hook("email", " AppReview@TaskforceLabs.dev ")).toEqual({});
      // 같은 도메인의 다른 주소는 막힌다
      expect(await hook("email", "other@taskforcelabs.dev")).toEqual(blocked);
    } finally {
      await db.query(`delete from public.blocked_email_domains where domain = 'taskforcelabs.dev'`);
    }
  });

  it("이메일이 없거나 @가 없으면 403", async () => {
    expect(await hook("email", null)).toEqual(blocked);
    expect(await hook("email", "   ")).toEqual(blocked);
    expect(await hook("email", "no-at-sign.example.com")).toEqual(blocked);
    expect(await hook("email", "trailing@")).toEqual(blocked);
  });
});

describe("hook_before_user_created: 차단 도메인", () => {
  it("일회용 도메인은 403 (대소문자 · 공백 · 끝 점 무시)", async () => {
    expect(await hook("email", "x@mailinator.com")).toEqual(blocked);
    expect(await hook("email", " X@MAILINATOR.com ")).toEqual(blocked);
    expect(await hook("email", "x@mailinator.com.")).toEqual(blocked);
    expect(await hook("email", "x@burner.example")).toEqual(blocked);
  });

  it("하위 도메인도 403 (x.mailinator.com → mailinator.com)", async () => {
    expect(await hook("email", "x@sub.mailinator.com")).toEqual(blocked);
    expect(await hook("email", "x@a.b.c.mailinator.com")).toEqual(blocked);
  });

  it("이름만 비슷한 다른 도메인은 받는다", async () => {
    expect(await hook("email", "x@notmailinator.com")).toEqual({});
    expect(await hook("email", "x@mailinator.com.evil.example")).toEqual({});
    expect(await hook("email", "mailinator.com@gmail.com")).toEqual({});
    expect(await hook("email", "x@xmailinator.com")).toEqual({});
  });

  it("@가 둘이면 마지막 @ 뒤를 도메인으로 본다", async () => {
    expect(await hook("email", "a@mailinator.com@example.com")).toEqual({});
    expect(await hook("email", "a@example.com@mailinator.com")).toEqual(blocked);
  });

  it("_ 와 %는 글자 그대로 비교한다 (패턴 문자로 읽지 않는다)", async () => {
    await db.query(`insert into public.blocked_email_domains (domain, source) values ('under_score.test', 'test')`);
    try {
      expect(await hook("email", "x@under_score.test")).toEqual(blocked);
      expect(await hook("email", "x@underXscore.test")).toEqual({});
      expect(await hook("email", "x@sub.under_score.test")).toEqual(blocked);
    } finally {
      await db.query(`delete from public.blocked_email_domains where domain = 'under_score.test'`);
    }
  });
});

describe("hook_before_user_created: user_metadata", () => {
  it("비어 있거나 없으면 받는다 (null · 빈 객체 · 키 없음)", async () => {
    expect(await hook("email", "someone@example.com")).toEqual({});
    expect(await hook("email", "someone@example.com", {})).toEqual({});
    expect(await hook("email", "someone@example.com", null)).toEqual({});
  });

  it("Auth가 스스로 넣는 키(email · email_verified · phone_verified · sub)만 있으면 받는다", async () => {
    expect(
      await hook("email", "someone@example.com", {
        email: "someone@example.com",
        email_verified: false,
        phone_verified: false,
        sub: "ff7fc9ae-3b1b-4642-9241-64adb9848a03",
      }),
    ).toEqual({});
  });

  it("공격자가 넣은 키가 하나라도 있으면 403 (가입 때 임의의 user_metadata를 심지 못한다)", async () => {
    expect(await hook("email", "someone@example.com", { name: "x" })).toEqual(blocked);
    expect(await hook("email", "someone@example.com", { is_admin: true })).toEqual(blocked);
    expect(await hook("email", "someone@example.com", { email_verified: true, role: "admin" })).toEqual(blocked);
    expect(await hook("email", "someone@example.com", "not-an-object")).toEqual(blocked);
    expect(await hook("email", "someone@example.com", ["name"])).toEqual(blocked);
  });

  it("심사 허용 목록의 주소는 user_metadata가 있어도 받는다 (심사 계정은 이름을 넣어 만든다)", async () => {
    expect(await hook("email", "appreview@taskforcelabs.dev", { name: "Alex Kim" })).toEqual({});
  });

  it("Apple · Google 가입은 user_metadata를 보지 않는다 (제공자가 넣는 이름 · 사진)", async () => {
    expect(await hook("apple", "abc@privaterelay.appleid.com", { name: "x", picture: "y" })).toEqual({});
    expect(await hook("google", "someone@example.com", { full_name: "x", avatar_url: "y" })).toEqual({});
  });
});

describe("hook_before_user_created: 절대 막지 않을 도메인", () => {
  // 차단 목록(외부 목록)에 잘못 들어와도 흔한 개인 메일은 막지 않는다. scripts/sync-blocked-email-domains.ts의 NEVER_BLOCK_DOMAINS와 같다 (그 시험이 맞춰 본다)
  const NEVER = ["gmail.com", "outlook.com", "icloud.com", "naver.com", "daum.net", "hanmail.net", "kakao.com", "yahoo.com", "hotmail.com", "proton.me"];

  it("차단 목록에 들어가 있어도 받는다 (대소문자 · 끝 점 무시)", async () => {
    await db.query(`insert into public.blocked_email_domains (domain, source) select d, 'test' from unnest($1::text[]) d`, [NEVER]);
    try {
      for (const domain of NEVER) {
        expect(await hook("email", `someone@${domain}`), domain).toEqual({});
        expect(await hook("email", ` Someone@${domain.toUpperCase()}. `), domain).toEqual({});
      }
    } finally {
      await db.query(`delete from public.blocked_email_domains where domain = any($1::text[])`, [NEVER]);
    }
  });

  it("이름만 비슷한 도메인은 막을 수 있다 (정확히 같은 도메인만 면제)", async () => {
    await db.query(`insert into public.blocked_email_domains (domain, source) values ('gmail.com.evil.example', 'test'), ('notgmail.com', 'test')`);
    try {
      expect(await hook("email", "x@gmail.com.evil.example")).toEqual(blocked);
      expect(await hook("email", "x@notgmail.com")).toEqual(blocked);
    } finally {
      await db.query(`delete from public.blocked_email_domains where domain in ('gmail.com.evil.example', 'notgmail.com')`);
    }
  });
});

describe("hook_before_user_created: 한 시간 미확인 가입 상한", () => {
  it("지난 1시간의 미확인 이메일 사용자가 14명이면 받고 15명이면 429 (Supabase 메일 한도 시간당 30의 절반: 한 곳이 메일 예산을 바닥내지 못하게)", async () => {
    await unconfirmedSignups(14);
    expect(await hook("email", "someone@example.com")).toEqual({});
    await unconfirmedSignups(1, { minutesAgo: 5 });
    expect(await hook("email", "someone@example.com")).toEqual(tooMany);
  });

  it("확인된 사용자 · 한 시간이 지난 행 · 이메일이 아닌 가입은 세지 않는다", async () => {
    await unconfirmedSignups(60, { confirmed: true });
    await unconfirmedSignups(60, { minutesAgo: 61 });
    await unconfirmedSignups(60, { provider: "google" });
    expect(await hook("email", "someone@example.com")).toEqual({});
  });

  it("59분 전 가입은 세고 61분 전 가입은 세지 않는다", async () => {
    await unconfirmedSignups(15, { minutesAgo: 59 });
    expect(await hook("email", "someone@example.com")).toEqual(tooMany);
    await db.exec(`delete from auth.users where email like '%@bulk.test'`);
    await unconfirmedSignups(15, { minutesAgo: 61 });
    expect(await hook("email", "someone@example.com")).toEqual({});
  });

  it("차단 도메인 검사가 상한보다 먼저다 (막힌 주소는 403)", async () => {
    await unconfirmedSignups(15);
    expect(await hook("email", "x@mailinator.com")).toEqual(blocked);
  });
});

describe("hook_before_user_created: Apple · Google은 영향이 없다", () => {
  it("차단 도메인 · 상한이 가득 차 있어도 그대로 받는다", async () => {
    await unconfirmedSignups(15);
    expect(await hook("apple", "abc@privaterelay.appleid.com")).toEqual({});
    expect(await hook("apple", null)).toEqual({});
    expect(await hook("google", "someone@mailinator.com")).toEqual({});
    expect(await hook("google", "Someone@Example.com")).toEqual({});
  });
});

describe("blocked_email_domains 권한", () => {
  it("소문자 도메인만 받는다", async () => {
    await expect(db.query(`insert into public.blocked_email_domains (domain, source) values ('Upper.Example', 'test')`)).rejects.toThrow(/check/);
  });

  it("클라이언트는 훅을 부르거나 차단 목록을 읽고 쓸 수 없다", async () => {
    await asUser(db, ALICE, async () => {
      await expect(db.query(`select public.hook_before_user_created('{}'::jsonb)`)).rejects.toThrow(/permission denied/);
      await expect(db.query(`select * from public.blocked_email_domains`)).rejects.toThrow(/permission denied/);
      await expect(db.query(`insert into public.blocked_email_domains (domain, source) values ('mine.example', 'test')`)).rejects.toThrow(/permission denied/);
    });
    await db.exec("set role anon");
    try {
      await expect(db.query(`select * from public.blocked_email_domains`)).rejects.toThrow(/permission denied/);
    } finally {
      await db.exec("reset role");
    }
  });

  it("Auth(supabase_auth_admin)는 읽을 수만 있다", async () => {
    await db.exec("set role supabase_auth_admin");
    try {
      const { rows } = await db.query<{ n: number }>(`select count(*)::int as n from public.blocked_email_domains`);
      expect(rows[0].n).toBeGreaterThanOrEqual(2);
      await expect(db.query(`delete from public.blocked_email_domains`)).rejects.toThrow(/permission denied/);
    } finally {
      await db.exec("reset role");
    }
  });
});

// auth.users 트리거 strip_unverified_email_password (20261201000000): 심사 계정 밖 이메일 사용자는 비밀번호를 가질 수 없다.
// 가입 전 비밀번호 탈취(pre-account takeover) 막기: 공격자가 피해자 주소를 비밀번호와 함께 미리 가입 → 피해자가 코드로 확인 →
// 공격자가 처음 정한 비밀번호로 로그인. 이메일 로그인을 모두에게 열면 누구나 할 수 있는 일이라 가입 때와 비밀번호가 바뀔 때마다 비운다.
// 비워진 값은 빈 문자열이다: 비밀번호 없는 사용자(Apple · Google)의 GoTrue 값과 같고 어떤 비밀번호와도 맞지 않는다 (실제 GoTrue로 보는 것은 L2: handoffs 노트).
describe("auth.users 트리거: 이메일 사용자는 비밀번호를 가질 수 없다", () => {
  const VICTIM = "victim@trg.test";
  const ATTACKER_HASH = "$2a$10$attackerchosenpasswordhashxxxxxxxxxxxxxxxxxxxxxxxxxxx";

  async function signUp(email: string, { password = ATTACKER_HASH, provider = "email", confirmed = false }: { password?: string | null; provider?: string; confirmed?: boolean } = {}) {
    await db.query(
      `insert into auth.users (id, email, raw_app_meta_data, email_confirmed_at, encrypted_password)
       values (gen_random_uuid(), $1, jsonb_build_object('provider', $2::text), case when $3::boolean then now() else null end, $4)`,
      [email, provider, confirmed, password],
    );
  }
  async function stored(email: string): Promise<{ password: string | null; confirmed: boolean; signedIn: boolean }> {
    const { rows } = await db.query<{ password: string | null; confirmed: boolean; signed_in: boolean }>(
      `select encrypted_password as password, email_confirmed_at is not null as confirmed, last_sign_in_at is not null as signed_in from auth.users where email = $1`,
      [email],
    );
    return { password: rows[0].password, confirmed: rows[0].confirmed, signedIn: rows[0].signed_in };
  }
  /** 비밀번호 로그인이 될 수 있는 행인가 (GoTrue는 NULL · 빈 해시를 거절한다) */
  const canPasswordLogin = async (email: string) => {
    const { password } = await stored(email);
    return password !== null && password !== "";
  };

  afterEach(async () => {
    await db.exec(`delete from auth.users where email like '%@trg.test'`);
    await db.exec(`delete from public.review_accounts where email like '%@trg.test'`);
  });

  it("가입할 때 공격자가 정한 비밀번호를 저장하지 않는다", async () => {
    await signUp(VICTIM);
    expect((await stored(VICTIM)).password).toBe("");
  });

  it("전체 공격 순서: 미리 가입(비밀번호) → 같은 주소로 다시 가입해 비밀번호 바꾸기 → 피해자가 코드로 확인 → 비밀번호 로그인은 불가능하다", async () => {
    // 1) 공격자가 피해자 주소로 비밀번호를 정해 가입 (확인 전)
    await signUp(VICTIM);
    // 2) GoTrue는 확인 전 사용자가 다시 가입하면 비밀번호를 갈아 끼운다
    await db.query(`update auth.users set encrypted_password = $2 where email = $1`, [VICTIM, "$2a$10$secondattackerpasswordxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"]);
    expect(await canPasswordLogin(VICTIM)).toBe(false);
    // 3) 피해자가 자기 메일의 코드로 확인 (GoTrue가 모든 열을 다시 쓰는 갱신: 비밀번호 열을 그대로 싣는다)
    await db.query(`update auth.users set email_confirmed_at = now(), last_sign_in_at = now(), encrypted_password = encrypted_password where email = $1`, [VICTIM]);
    // 4) 확인은 반영되고(다른 열은 그대로) 비밀번호로는 들어갈 수 없다
    expect(await stored(VICTIM)).toEqual({ password: "", confirmed: true, signedIn: true });
    expect(await canPasswordLogin(VICTIM)).toBe(false);
  });

  it("이 트리거가 생기기 전에 만든 미확인 행(비밀번호가 남아 있음)도 처음 확인할 때 비운다", async () => {
    await db.exec("set session_replication_role = replica"); // 트리거 없이 만든 옛 행
    try {
      await signUp(VICTIM);
    } finally {
      await db.exec("set session_replication_role = origin");
    }
    expect((await stored(VICTIM)).password).toBe(ATTACKER_HASH);
    await db.query(`update auth.users set email_confirmed_at = now(), encrypted_password = encrypted_password where email = $1`, [VICTIM]);
    expect(await stored(VICTIM)).toMatchObject({ password: "", confirmed: true });
  });

  it("확인한 뒤에 비밀번호를 새로 정해도 비운다 (이 서비스 이메일 사용자에게 비밀번호는 없다)", async () => {
    await signUp(VICTIM, { password: null, confirmed: true });
    await db.query(`update auth.users set encrypted_password = $2 where email = $1`, [VICTIM, ATTACKER_HASH]);
    expect(await canPasswordLogin(VICTIM)).toBe(false);
  });

  it("심사 허용 목록의 주소는 비밀번호를 가진다 (가입 · 확인 · 바꾸기 모두, 대소문자 무시)", async () => {
    await db.query(`insert into public.review_accounts (email, note) values ('reviewer@trg.test', 'App Store 심사')`);
    await signUp("reviewer@trg.test", { password: "$2a$10$reviewerhash", confirmed: true });
    expect((await stored("reviewer@trg.test")).password).toBe("$2a$10$reviewerhash");
    await db.query(`update auth.users set encrypted_password = '$2a$10$changed' where email = 'reviewer@trg.test'`);
    expect((await stored("reviewer@trg.test")).password).toBe("$2a$10$changed");
    // 확인 전에 만든 뒤 나중에 확인해도 (create-review-account.ts는 email_confirm: true로 만든다)
    await db.query(`insert into public.review_accounts (email, note) values ('reviewer2@trg.test', 'App Store 심사')`);
    await signUp("Reviewer2@TRG.test", { password: "$2a$10$second" });
    expect((await stored("Reviewer2@TRG.test")).password).toBe("$2a$10$second");
    await db.query(`update auth.users set email_confirmed_at = now() where email = 'Reviewer2@TRG.test'`);
    expect((await stored("Reviewer2@TRG.test")).password).toBe("$2a$10$second");
  });

  it("이메일 제공자가 아닌 가입(Apple · Google)과 비밀번호가 없는 행은 건드리지 않는다", async () => {
    await signUp("g@trg.test", { provider: "google", password: "$2a$10$notours", confirmed: true });
    expect((await stored("g@trg.test")).password).toBe("$2a$10$notours");
    await signUp("empty@trg.test", { password: "" });
    expect((await stored("empty@trg.test")).password).toBe("");
    await signUp("none@trg.test", { password: null });
    expect((await stored("none@trg.test")).password).toBeNull();
  });

  it("비밀번호와 상관없는 갱신은 행을 바꾸지 않는다 (로그인 시각 갱신 등)", async () => {
    await signUp(VICTIM, { password: null, confirmed: true });
    const before = await db.query(`select to_jsonb(u) as row from auth.users u where email = $1`, [VICTIM]);
    await db.query(`update auth.users set last_sign_in_at = '2026-10-20T00:00:00Z' where email = $1`, [VICTIM]);
    const after = await db.query<{ row: Record<string, unknown> }>(`select to_jsonb(u) as row from auth.users u where email = $1`, [VICTIM]);
    expect({ ...after.rows[0].row, last_sign_in_at: null }).toEqual({ ...(before.rows[0] as { row: Record<string, unknown> }).row, last_sign_in_at: null });
    expect(after.rows[0].row.last_sign_in_at).toBe("2026-10-20T00:00:00+00:00");
  });

  it("트리거 함수는 클라이언트가 부를 수 없다", async () => {
    const { rows } = await db.query<{ anon: boolean; authenticated: boolean }>(
      `select has_function_privilege('anon', 'public.strip_unverified_email_password()', 'execute') as anon,
              has_function_privilege('authenticated', 'public.strip_unverified_email_password()', 'execute') as authenticated`,
    );
    expect(rows[0]).toEqual({ anon: false, authenticated: false });
  });
});

// take_login_code_attempt (20261201000000): 웹 /login의 코드 확인 시도를 이메일 해시별로 센다 (가입 전이라 user_id 키인 take_rate_limit을 쓸 수 없다).
describe("take_login_code_attempt: 이메일별 확인 시도 상한", () => {
  const HASH = "a".repeat(64);
  const OTHER = "b".repeat(64);

  async function attempt(hash = HASH, max = 5, windowSeconds = 600): Promise<Date | null> {
    await db.exec("set role service_role");
    try {
      const { rows } = await db.query<{ retry_at: Date | null }>(`select public.take_login_code_attempt($1, $2, $3) as retry_at`, [hash, max, windowSeconds]);
      return rows[0].retry_at;
    } finally {
      await db.exec("reset role");
    }
  }
  const count = async (hash = HASH) => (await db.query<{ n: number }>(`select count(*)::int as n from public.login_code_attempts where email_hash = $1`, [hash])).rows[0].n;

  afterEach(async () => {
    await db.exec(`delete from public.login_code_attempts`);
  });

  it("5번까지는 null(남기고 통과), 6번째부터는 다시 할 수 있는 시각을 돌려주고 남기지 않는다", async () => {
    for (let i = 0; i < 5; i++) expect(await attempt(), `시도 ${i + 1}`).toBeNull();
    expect(await count()).toBe(5);
    const retryAt = await attempt();
    expect(retryAt).toBeInstanceOf(Date);
    expect(await attempt()).toBeInstanceOf(Date);
    expect(await count()).toBe(5);
    // 가장 오래된 시도 + 10분
    const { rows } = await db.query<{ oldest: Date }>(`select min(created_at) as oldest from public.login_code_attempts`);
    expect(Math.abs(retryAt!.getTime() - (rows[0].oldest.getTime() + 600_000))).toBeLessThan(2_000);
  });

  it("주소(해시)마다 따로 센다", async () => {
    for (let i = 0; i < 5; i++) await attempt();
    expect(await attempt()).toBeInstanceOf(Date);
    expect(await attempt(OTHER)).toBeNull();
  });

  it("가장 오래된 시도가 10분 밖으로 나가면 한 번이 다시 열린다", async () => {
    for (let i = 0; i < 5; i++) await attempt();
    await db.query(`update public.login_code_attempts set created_at = now() - interval '601 seconds' where id = (select id from public.login_code_attempts order by created_at limit 1)`);
    expect(await attempt()).toBeNull();
    // 창 밖 행은 지워 표가 커지지 않는다: 5개가 남는다
    expect(await count()).toBe(5);
    expect(await attempt()).toBeInstanceOf(Date);
  });

  it("모든 시도가 창 밖이면 처음처럼 센다", async () => {
    for (let i = 0; i < 5; i++) await attempt();
    await db.query(`update public.login_code_attempts set created_at = now() - interval '11 minutes'`);
    expect(await attempt()).toBeNull();
    expect(await count()).toBe(1);
  });

  it("창과 한도는 인자대로다 (1분에 2번)", async () => {
    expect(await attempt(HASH, 2, 60)).toBeNull();
    expect(await attempt(HASH, 2, 60)).toBeNull();
    const retryAt = await attempt(HASH, 2, 60);
    expect(retryAt).toBeInstanceOf(Date);
    expect(retryAt!.getTime() - Date.now()).toBeLessThanOrEqual(60_000);
  });

  it("해시 모양이 아니거나(원본 이메일 등) 한도 · 창이 1보다 작으면 거절한다", async () => {
    await expect(attempt("operator@example.com")).rejects.toThrow(/잘못된 인자/);
    await expect(attempt("A".repeat(64))).rejects.toThrow(/잘못된 인자/);
    await expect(attempt(HASH, 0, 600)).rejects.toThrow(/잘못된 인자/);
    await expect(attempt(HASH, 5, 0)).rejects.toThrow(/잘못된 인자/);
    expect(await count()).toBe(0);
    await expect(db.query(`insert into public.login_code_attempts (email_hash) values ('operator@example.com')`)).rejects.toThrow(/check/);
  });

  it("서버(service_role)만 부르고, 클라이언트 · Auth는 부르거나 읽을 수 없다", async () => {
    await attempt();
    for (const role of ["anon", "authenticated", "supabase_auth_admin"]) {
      await db.exec(`set role ${role}`);
      try {
        await expect(db.query(`select public.take_login_code_attempt($1, 5, 600)`, [HASH]), role).rejects.toThrow(/permission denied/);
        await expect(db.query(`select * from public.login_code_attempts`), role).rejects.toThrow(/permission denied/);
        await expect(db.query(`delete from public.login_code_attempts`), role).rejects.toThrow(/permission denied/);
      } finally {
        await db.exec("reset role");
      }
    }
  });
});

// scripts/sync-blocked-email-domains.ts: 차단 목록 채우기 (사용자가 운영 DB에 돌린다). 목록은 마이그레이션에 넣지 않는다 (자주 바뀐다).
// 이 파일에서 시험하는 이유: vitest가 찾는 경로가 src · tests뿐이라 scripts/*.test.ts는 npm run test에 들지 않는다.
describe("sync-blocked-email-domains", () => {
  const SHA = "0123456789abcdef0123456789abcdef01234567";

  it("고정 커밋 주소로만 받는다", () => {
    expect(BLOCKLIST_FILE).toBe("disposable_email_blocklist.conf");
    expect(blocklistUrl(SHA)).toBe(
      `https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/${SHA}/disposable_email_blocklist.conf`,
    );
    expect(sourceTag(SHA)).toBe(`disposable-email-domains@${SHA}`);
    expect(isCommitSha(SHA)).toBe(true);
    for (const bad of ["main", "HEAD", "abc123", `${SHA}0`, "0123456789ABCDEF0123456789abcdef01234567", "../../etc", ""]) {
      expect(isCommitSha(bad), bad).toBe(false);
    }
  });

  it("주석 · 빈 줄 · 대문자 · 공백을 정리하고 중복을 없앤다", () => {
    const text = ["# header comment", "", "Mailinator.COM  ", "  burner.example", "mailinator.com", "trailing.example # note", "\r", "10minutemail.com\r"].join("\n");
    expect(parseBlocklist(text)).toEqual(["mailinator.com", "burner.example", "trailing.example", "10minutemail.com"]);
  });

  it("도메인 모양이 아닌 줄은 버린다 (@ · 공백 · 점 없음 · 글자 밖)", () => {
    expect(parseBlocklist(["ok.example", "a@b.example", "has space.example", "nodots", ".leading.example", "trailing.example.", "bad_underscore.example", "한글.example", "-dash.example", "a..b.example"].join("\n"))).toEqual(["ok.example"]);
  });

  type Row = { domain: string; source: string };

  /**
   * blocked_email_domains를 흉내 내는 상태 있는 가짜 표: 코드가 부르는 메서드만 받는다 (모르는 필터 · 조건 없는 지우기는 던진다).
   * upsert(ignoreDuplicates) = 있으면 그대로 · 없으면 넣기 / update·delete = like(끝의 %만) · neq · in 필터가 모두 맞는 행에만
   */
  function fakeTable(initial: Row[] = []) {
    const rows = new Map<string, Row>(initial.map((r) => [r.domain, { ...r }]));
    const calls: { op: string; filters: [string, ...unknown[]][]; size: number }[] = [];
    const matches = (row: Row, filters: [string, ...unknown[]][]) =>
      filters.every(([kind, column, value]) => {
        const actual = (row as Record<string, string>)[column as string];
        if (kind === "like") {
          expect(String(value).endsWith("%") && !String(value).slice(0, -1).includes("%"), `like는 끝의 %만 쓴다: ${value}`).toBe(true);
          return actual.startsWith(String(value).slice(0, -1));
        }
        if (kind === "neq") return actual !== value;
        if (kind === "in") return (value as string[]).includes(actual);
        throw new Error(`모르는 필터 ${kind}`);
      });
    const filtered = (op: "update" | "delete", apply: (row: Row) => void, size: number) => {
      const filters: [string, ...unknown[]][] = [];
      const self = {
        like: (column: string, pattern: string) => (filters.push(["like", column, pattern]), self),
        neq: (column: string, value: string) => (filters.push(["neq", column, value]), self),
        in: (column: string, list: string[]) => (filters.push(["in", column, list]), self),
        throwOnError: async () => {
          expect(filters.length, `${op}에는 필터가 있어야 한다 (조건 없는 ${op} 금지)`).toBeGreaterThan(0);
          expect(filters.some(([kind, column]) => kind === "like" && column === "source"), `${op}는 이 도구의 출처(source like …)로 좁힌다`).toBe(true);
          calls.push({ op, filters, size });
          for (const row of [...rows.values()]) if (matches(row, filters)) apply(row);
          return { data: null };
        },
      };
      return self;
    };
    const admin = {
      from: (table: string) => {
        expect(table).toBe("blocked_email_domains");
        return {
          upsert: (batch: Row[], options: { onConflict?: string; ignoreDuplicates?: boolean }) => ({
            throwOnError: async () => {
              expect(options).toEqual({ onConflict: "domain", ignoreDuplicates: true });
              calls.push({ op: "upsert", filters: [], size: batch.length });
              for (const row of batch) if (!rows.has(row.domain)) rows.set(row.domain, { ...row });
              return { data: null };
            },
          }),
          update: (values: { source: string }) => filtered("update", (row) => Object.assign(row, values), 0),
          delete: () => filtered("delete", (row) => rows.delete(row.domain), 0),
        };
      },
    };
    return { admin: admin as never, rows, calls };
  }

  const many = Array.from({ length: MIN_DOMAINS }, (_, i) => `domain${i}.example`);
  const OLD = sourceTag("f".repeat(40));
  const NEW = sourceTag(SHA);

  it("--yes가 없으면 아무것도 쓰지 않고 서비스 키도 읽지 않는다", async () => {
    const { admin, calls } = fakeTable();
    const getAdmin = vi.fn(() => admin);
    const log = vi.fn();
    const result = await runSync({ commit: SHA, yes: false, fetchText: async () => many.join("\n"), admin: getAdmin, log });
    expect(result).toEqual({ written: false, domains: MIN_DOMAINS });
    expect(calls).toEqual([]);
    expect(getAdmin).not.toHaveBeenCalled();
    expect(log.mock.calls.flat().join("\n")).toContain("--yes");
  });

  it("--yes면 새 도메인을 새 출처로 넣는다 (한 번에 1,000개까지)", async () => {
    const { admin, rows, calls } = fakeTable();
    const result = await runSync({ commit: SHA, yes: true, fetchText: async () => [...many, ...Array.from({ length: 1500 }, (_, i) => `extra${i}.example`)].join("\n"), admin: () => admin, log: () => {} });
    expect(result.written).toBe(true);
    expect(rows.size).toBe(MIN_DOMAINS + 1500);
    expect(new Set([...rows.values()].map((r) => r.source))).toEqual(new Set([NEW]));
    for (const call of calls.filter((c) => c.op === "upsert")) expect(call.size).toBeLessThanOrEqual(1000);
  });

  it("손으로 넣은 도메인 · 다른 출처의 도메인은 갱신도 삭제도 하지 않는다 (목록에 같은 도메인이 있어도 출처가 그대로다)", async () => {
    const { admin, rows } = fakeTable([
      { domain: "manual-block.example", source: "manual:ops" },
      { domain: "domain0.example", source: "manual:ops" }, // 새 목록에도 있지만 손으로 넣은 행이다
      { domain: "other-tool.example", source: "other-list@abc123" },
      { domain: "lookalike.example", source: "xdisposable-email-domains@abc" }, // 접두사가 같아 보여도 이 도구의 출처가 아니다
      { domain: "also-lookalike.example", source: "disposable-email-domains" }, // @ 없음
    ]);
    await runSync({ commit: SHA, yes: true, fetchText: async () => many.join("\n"), admin: () => admin, log: () => {} });
    expect(rows.get("manual-block.example")?.source).toBe("manual:ops");
    expect(rows.get("domain0.example")?.source).toBe("manual:ops");
    expect(rows.get("other-tool.example")?.source).toBe("other-list@abc123");
    expect(rows.get("lookalike.example")?.source).toBe("xdisposable-email-domains@abc");
    expect(rows.get("also-lookalike.example")?.source).toBe("disposable-email-domains");
    // 목록의 나머지는 들어갔다
    expect(rows.get("domain1.example")?.source).toBe(NEW);
  });

  it("이 도구의 옛 커밋 행: 아직 목록에 있으면 새 출처로 바꾸고, 목록에서 빠졌으면 지운다", async () => {
    const { admin, rows } = fakeTable([
      { domain: "domain1.example", source: OLD },
      { domain: "gone.example", source: OLD },
      { domain: "gone-too.example", source: sourceTag("e".repeat(40)) },
    ]);
    await runSync({ commit: SHA, yes: true, fetchText: async () => many.join("\n"), admin: () => admin, log: () => {} });
    expect(rows.get("domain1.example")?.source).toBe(NEW);
    expect(rows.has("gone.example")).toBe(false);
    expect(rows.has("gone-too.example")).toBe(false);
    expect(rows.size).toBe(MIN_DOMAINS);
  });

  it("지우기는 넣기 · 출처 바꾸기가 모두 끝난 뒤에 하고, 갱신 한 번에 도메인 200개까지만 싣는다 (주소 길이)", async () => {
    const { admin, calls } = fakeTable([{ domain: "gone.example", source: OLD }]);
    await runSync({ commit: SHA, yes: true, fetchText: async () => many.join("\n"), admin: () => admin, log: () => {} });
    const ops = calls.map((c) => c.op);
    expect(ops.lastIndexOf("upsert")).toBeLessThan(ops.indexOf("delete"));
    expect(ops.lastIndexOf("update")).toBeLessThan(ops.indexOf("delete"));
    for (const call of calls.filter((c) => c.op === "update")) {
      const list = call.filters.find(([kind]) => kind === "in")?.[2] as string[] | undefined;
      expect(list, "갱신은 이 묶음의 도메인으로 좁힌다").toBeDefined();
      expect(list!.length).toBeLessThanOrEqual(200);
    }
    const deleteCall = calls.find((c) => c.op === "delete")!;
    expect(deleteCall.filters).toEqual([
      ["like", "source", "disposable-email-domains@%"],
      ["neq", "source", NEW],
    ]);
  });

  it("절대 막지 않을 도메인(gmail.com 등)은 목록에 있어도 넣지 않고, 옛 커밋에 있었다면 지운다", async () => {
    const { admin, rows } = fakeTable([{ domain: "gmail.com", source: OLD }]);
    const log = vi.fn();
    const result = await runSync({ commit: SHA, yes: true, fetchText: async () => [...many, "gmail.com", "naver.com", "daum.net", "icloud.com"].join("\n"), admin: () => admin, log });
    expect(result.domains).toBe(MIN_DOMAINS);
    for (const domain of ["gmail.com", "naver.com", "daum.net", "icloud.com"]) expect(rows.has(domain), domain).toBe(false);
    expect(log.mock.calls.flat().join("\n")).toMatch(/4개/);
  });

  it("절대 막지 않을 도메인 목록은 훅(마이그레이션)의 목록과 같다", () => {
    const migration = readFileSync(path.resolve(__dirname, "../../supabase/migrations/20261201000000_email_signup_open.sql"), "utf8");
    const block = migration.match(/v_never_block constant text\[\] := array\[([\s\S]*?)\];/)?.[1] ?? "";
    const sqlList = [...block.matchAll(/'([^']+)'/g)].map((m) => m[1]);
    expect(sqlList.length).toBeGreaterThan(10);
    expect([...NEVER_BLOCK_DOMAINS].sort()).toEqual([...sqlList].sort());
    for (const domain of ["gmail.com", "outlook.com", "icloud.com", "naver.com", "daum.net"]) expect(NEVER_BLOCK_DOMAINS).toContain(domain);
  });

  it("도메인이 너무 적으면(잘못 받은 목록) 쓰지 않고 멈춘다", async () => {
    const { admin, calls } = fakeTable();
    await expect(runSync({ commit: SHA, yes: true, fetchText: async () => "only.example", admin: () => admin, log: () => {} })).rejects.toThrow(/적/);
    expect(calls).toEqual([]);
  });

  it("커밋 해시가 아니면 받지도 않는다", async () => {
    const { admin, calls } = fakeTable();
    const fetchText = vi.fn();
    await expect(runSync({ commit: "main", yes: true, fetchText, admin: () => admin, log: () => {} })).rejects.toThrow(/커밋/);
    expect(fetchText).not.toHaveBeenCalled();
    expect(calls).toEqual([]);
  });
});
