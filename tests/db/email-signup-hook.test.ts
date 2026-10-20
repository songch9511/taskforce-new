import type { PGlite } from "@electric-sql/pglite";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import {
  BLOCKLIST_FILE,
  blocklistUrl,
  isCommitSha,
  MIN_DOMAINS,
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

const event = (provider: string, email: string | null) => ({
  metadata: { uuid: "8b34dcdd-9df1-4c10-850a-b3277c653040", name: "before-user-created", ip_address: "203.0.113.7" },
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
      add column is_sso_user boolean not null default false;
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
    await unconfirmedSignups(100);
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

describe("hook_before_user_created: 한 시간 미확인 가입 상한", () => {
  it("지난 1시간의 미확인 이메일 사용자가 99명이면 받고 100명이면 429", async () => {
    await unconfirmedSignups(99);
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
    await unconfirmedSignups(100, { minutesAgo: 59 });
    expect(await hook("email", "someone@example.com")).toEqual(tooMany);
    await db.exec(`delete from auth.users where email like '%@bulk.test'`);
    await unconfirmedSignups(100, { minutesAgo: 61 });
    expect(await hook("email", "someone@example.com")).toEqual({});
  });

  it("차단 도메인 검사가 상한보다 먼저다 (막힌 주소는 403)", async () => {
    await unconfirmedSignups(100);
    expect(await hook("email", "x@mailinator.com")).toEqual(blocked);
  });
});

describe("hook_before_user_created: Apple · Google은 영향이 없다", () => {
  it("차단 도메인 · 상한이 가득 차 있어도 그대로 받는다", async () => {
    await unconfirmedSignups(100);
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

  function fakeAdmin() {
    const calls: { op: string; table: string; args: unknown }[] = [];
    const chain = (op: string, table: string, args: unknown) => {
      calls.push({ op, table, args });
      const self: Record<string, unknown> = {};
      for (const method of ["like", "neq", "throwOnError"]) {
        self[method] = (...a: unknown[]) => {
          calls.push({ op: `${op}.${method}`, table, args: a });
          return method === "throwOnError" ? Promise.resolve({ data: null }) : self;
        };
      }
      return self;
    };
    const admin = {
      from: (table: string) => ({
        upsert: (rows: unknown, options: unknown) => chain("upsert", table, { rows, options }),
        delete: () => chain("delete", table, null),
      }),
    };
    return { admin: admin as never, calls };
  }

  const many = Array.from({ length: MIN_DOMAINS }, (_, i) => `domain${i}.example`);

  it("--yes가 없으면 아무것도 쓰지 않고 서비스 키도 읽지 않는다", async () => {
    const { admin, calls } = fakeAdmin();
    const getAdmin = vi.fn(() => admin);
    const log = vi.fn();
    const result = await runSync({ commit: SHA, yes: false, fetchText: async () => many.join("\n"), admin: getAdmin, log });
    expect(result).toEqual({ written: false, domains: MIN_DOMAINS });
    expect(calls).toEqual([]);
    expect(getAdmin).not.toHaveBeenCalled();
    expect(log.mock.calls.flat().join("\n")).toContain("--yes");
  });

  it("--yes면 새 출처 표로 upsert하고 그 출처에서 빠진 도메인만 지운다", async () => {
    const { admin, calls } = fakeAdmin();
    const result = await runSync({ commit: SHA, yes: true, fetchText: async () => many.join("\n"), admin: () => admin, log: () => {} });
    expect(result).toEqual({ written: true, domains: MIN_DOMAINS });
    const upserts = calls.filter((c) => c.op === "upsert");
    expect(upserts.length).toBeGreaterThanOrEqual(1);
    const rows = upserts.flatMap((c) => (c.args as { rows: { domain: string; source: string }[] }).rows);
    expect(rows).toHaveLength(MIN_DOMAINS);
    expect(new Set(rows.map((r) => r.source))).toEqual(new Set([sourceTag(SHA)]));
    for (const call of upserts) expect((call.args as { options: unknown }).options).toEqual({ onConflict: "domain" });
    // 지우기는 upsert가 모두 끝난 뒤, 이 도구가 넣은 출처(disposable-email-domains@…) 중 지금 출처가 아닌 것만
    const lastUpsert = calls.map((c) => c.op).lastIndexOf("upsert");
    const deleteIndex = calls.findIndex((c) => c.op === "delete");
    expect(deleteIndex).toBeGreaterThan(lastUpsert);
    expect(calls.find((c) => c.op === "delete.like")?.args).toEqual(["source", "disposable-email-domains@%"]);
    expect(calls.find((c) => c.op === "delete.neq")?.args).toEqual(["source", sourceTag(SHA)]);
  });

  it("도메인이 너무 적으면(잘못 받은 목록) 쓰지 않고 멈춘다", async () => {
    const { admin, calls } = fakeAdmin();
    await expect(runSync({ commit: SHA, yes: true, fetchText: async () => "only.example", admin: () => admin, log: () => {} })).rejects.toThrow(/적/);
    expect(calls).toEqual([]);
  });

  it("커밋 해시가 아니면 받지도 않는다", async () => {
    const { admin, calls } = fakeAdmin();
    const fetchText = vi.fn();
    await expect(runSync({ commit: "main", yes: true, fetchText, admin: () => admin, log: () => {} })).rejects.toThrow(/커밋/);
    expect(fetchText).not.toHaveBeenCalled();
    expect(calls).toEqual([]);
  });
});
