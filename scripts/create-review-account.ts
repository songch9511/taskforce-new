// App Store 심사용 계정을 만든다 (이메일 + 비밀번호, 만료 없음). 운영자가 한 번 돌린다. 다시 돌려도 안전하다.
//
//   REVIEW_ACCOUNT_EMAIL=… REVIEW_ACCOUNT_PASSWORD=… npx tsx --conditions react-server scripts/create-review-account.ts --yes [--reseed]
//
// 1. 주소를 허용 목록(review_accounts)에 넣는다: Before User Created 훅(20261007000000)이 목록에 없는 이메일 가입을 막는다.
// 2. 사용자를 만들거나(이미 있으면 비밀번호만 바꾼다) 이메일 확인을 마친 상태로 둔다.
// 3. 프로필 이름 · 별칭(Alex Kim · Alex)을 정하고 외부 AI 처리에 동의한 상태로 둔다 (심사자가 동의 화면을 거치지 않아도 할 일이 보이게).
// 4. "[Review] …" 합성 원문 두 개를 보통 파이프라인(추출 → 검증 → Jev → 병합)으로 처리해 근거가 붙은 할 일을 만든다.
//    이미 있으면 건너뛴다 (--reseed면 지우고 다시 만든다). 실제 사용자 데이터는 쓰지 않는다.
// server-only 모듈을 불러오므로 react-server 조건이 필요하다. 키는 .env.local에서 읽는다 (SUPABASE_SERVICE_ROLE_KEY 등).
// 어느 DB에 쓰는지 먼저 출력하고, --yes가 없으면 아무것도 쓰지 않는다. 비밀번호는 출력하지 않는다.
import { existsSync } from "node:fs";
import { parseArgs } from "node:util";

import type { SupabaseClient } from "@supabase/supabase-js";

import { loadIdentity } from "../src/lib/connectors/store";
import type { SourceKind } from "../src/lib/pipeline/extract";
import { processSource } from "../src/lib/sources/process";
import { createAdminClient } from "../src/lib/supabase/admin";

if (existsSync(".env.local")) process.loadEnvFile(".env.local");

const { values } = parseArgs({ options: { yes: { type: "boolean", default: false }, reseed: { type: "boolean", default: false } } });

// 심사용 가상 워크스페이스(docs/go-live/google-verification.md 6장)가 "나"를 Alex로 쓴다: 프로필 이름 · 별칭도 같게 둬야
// 그 워크스페이스를 연결했을 때 Alex의 약속이 이 계정의 할 일이 된다.
const REVIEWER_NAME = "Alex Kim";
const REVIEWER_ALIAS = "Alex";
const TITLE_PREFIX = "[Review]";
const DAY = 86_400_000;

type DemoSource = {
  title: string;
  kind: SourceKind;
  daysAgo: number;
  text: string;
  participants?: { from?: { name: string; email?: string }; to?: { name: string; email?: string }[]; attendees?: { name: string }[] };
};

/** 합성 원문 (실제 사람 · 회사가 아니다). 심사자가 영어로 보므로 영어로 쓴다. */
function demoSources(email: string): DemoSource[] {
  return [
    {
      title: `${TITLE_PREFIX} Weekly product sync`,
      kind: "meeting",
      daysAgo: 1,
      participants: { attendees: [{ name: REVIEWER_NAME }, { name: "Priya" }, { name: "Marcus" }] },
      text: [
        "Weekly product sync",
        `Attendees: ${REVIEWER_NAME}, Priya, Marcus`,
        "",
        "Priya: Can someone send the updated pricing deck to Northwind before Friday?",
        `${REVIEWER_ALIAS}: I'll send the pricing deck to Northwind by Friday.`,
        "Marcus: I'll book the venue for the team offsite next week.",
        `Priya: ${REVIEWER_ALIAS}, could you also draft the onboarding email for new beta users?`,
        `${REVIEWER_ALIAS}: Sure, I'll have a draft ready by Wednesday.`,
        "Priya: Great, thanks everyone.",
      ].join("\n"),
    },
    {
      title: `${TITLE_PREFIX} Re: Contract review`,
      kind: "email",
      daysAgo: 0,
      participants: { from: { name: "Lena Ortiz", email: "lena@example.com" }, to: [{ name: REVIEWER_NAME, email }] },
      text: [
        "From: Lena Ortiz <lena@example.com>",
        `To: ${REVIEWER_NAME} <${email}>`,
        "Subject: Re: Contract review",
        "",
        `Hi ${REVIEWER_ALIAS},`,
        "",
        "Thanks for the call today. Could you send me your comments on the contract by next Tuesday?",
        "Our legal team wants to sign before the end of the month.",
        "",
        "Best,",
        "Lena",
      ].join("\n"),
    },
  ];
}

async function findUserId(admin: SupabaseClient, email: string): Promise<string | null> {
  for (let page = 1; ; page++) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 200 });
    if (error) throw error;
    const found = data.users.find((u) => u.email?.toLowerCase() === email);
    if (found) return found.id;
    if (data.users.length < 200) return null;
  }
}

async function main() {
  const email = process.env.REVIEW_ACCOUNT_EMAIL?.trim().toLowerCase();
  const password = process.env.REVIEW_ACCOUNT_PASSWORD ?? "";
  if (!email || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error("REVIEW_ACCOUNT_EMAIL이 필요합니다.");
  if (password.length < 12) throw new Error("REVIEW_ACCOUNT_PASSWORD는 12자 이상이어야 합니다.");

  console.log(`대상 Supabase: ${process.env.NEXT_PUBLIC_SUPABASE_URL}`);
  console.log(`심사 계정: ${email}`);
  if (!values.yes) {
    console.log("--yes를 붙이면 위 DB에 씁니다. 아무것도 쓰지 않고 끝냅니다.");
    return;
  }

  const admin = createAdminClient();

  // 1) 허용 목록 (훅이 가입을 막지 않게, 사용자를 만들기 전에)
  await admin.from("review_accounts").upsert({ email, note: "App Store 심사 계정 (scripts/create-review-account.ts)" }).throwOnError();

  // 2) 사용자
  let userId = await findUserId(admin, email);
  if (userId) {
    const { error } = await admin.auth.admin.updateUserById(userId, { password, email_confirm: true });
    if (error) throw error;
    console.log("기존 사용자의 비밀번호를 바꿨습니다.");
  } else {
    const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { name: REVIEWER_NAME } });
    if (error) throw error;
    userId = data.user.id;
    console.log("사용자를 만들었습니다.");
  }

  // 3) 프로필 + 외부 AI 처리 동의
  await admin
    .from("profiles")
    .upsert({ user_id: userId, display_name: REVIEWER_NAME, aliases: [REVIEWER_ALIAS], ai_consent_at: new Date().toISOString() }, { onConflict: "user_id" })
    .throwOnError();

  // 4) 합성 원문 → 보통 파이프라인
  const { data: existing } = await admin.from("sources").select("id").eq("user_id", userId).like("title", `${TITLE_PREFIX}%`).throwOnError();
  if ((existing ?? []).length > 0 && !values.reseed) {
    console.log(`"${TITLE_PREFIX}" 원문이 이미 ${(existing ?? []).length}개 있어 건너뜁니다 (--reseed로 다시 만들 수 있습니다).`);
    return;
  }
  if (values.reseed) {
    // 심사 계정의 할 일 · 원문을 모두 비우고 다시 만든다 (근거 · Claim은 원문과 함께 지워진다)
    await admin.from("actions").delete().eq("user_id", userId).throwOnError();
    await admin.from("sources").delete().eq("user_id", userId).throwOnError();
  }

  const identity = await loadIdentity(admin, userId);
  const now = Date.now();
  for (const demo of demoSources(email)) {
    const occurredAt = new Date(now - demo.daysAgo * DAY);
    const { data } = await admin
      .from("sources")
      .insert({ user_id: userId, kind: demo.kind, title: demo.title, raw_text: demo.text, occurred_at: occurredAt.toISOString(), participants: demo.participants ?? null })
      .select("id")
      .single()
      .throwOnError();
    await processSource(admin, { id: data.id as string, userId }, { text: demo.text, kind: demo.kind, occurredAt, identity, participants: demo.participants });
    const { data: row } = await admin.from("sources").select("processing_status, processing_summary").eq("id", data.id).single();
    console.log(`${demo.title}: ${row?.processing_status}`, JSON.stringify((row?.processing_summary as { merge?: unknown } | null)?.merge ?? {}));
  }
  const { count } = await admin.from("actions").select("id", { count: "exact", head: true }).eq("user_id", userId).eq("status", "open");
  console.log(`열린 할 일 ${count ?? 0}개. 심사 메모에 이메일과 비밀번호를 적어 제출하세요.`);
}

main().catch((error) => {
  console.error("실패:", error instanceof Error ? error.message : error);
  process.exit(1);
});
