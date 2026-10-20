// 일회용 메일 도메인 차단 목록을 채운다 (이메일 가입 훅 hook_before_user_created가 읽는다: 20261201000000_email_signup_open). 운영자가 운영 DB에 돌린다.
//
//   npx tsx --conditions react-server scripts/sync-blocked-email-domains.ts --commit <40자리 커밋 해시> [--yes]
//
// 1. https://github.com/disposable-email-domains/disposable-email-domains(CC0)의 disposable_email_blocklist.conf를 **고정 커밋**으로 받는다
//    (브랜치 이름은 받지 않는다: 목록이 모르는 사이에 바뀌지 않게). 주석 · 빈 줄을 버리고 소문자로 맞춘다.
// 2. blocked_email_domains에 upsert하고(source = disposable-email-domains@<커밋>), 같은 출처의 옛 커밋에서만 있던 도메인은 지운다.
//    다른 출처로 손으로 넣은 도메인은 지우지 않는다.
// 목록을 마이그레이션에 넣지 않는 이유: 목록은 자주 바뀌고 마이그레이션은 고칠 수 없다.
// server-only 모듈을 불러오므로 react-server 조건이 필요하다. 키는 .env.local에서 읽는다 (SUPABASE_SERVICE_ROLE_KEY 등).
// 어느 DB에 쓰는지 먼저 출력하고, --yes가 없으면 아무것도 쓰지 않는다 (목록을 받아 개수만 보인다).
import { existsSync } from "node:fs";
import { parseArgs } from "node:util";

import type { SupabaseClient } from "@supabase/supabase-js";

export const BLOCKLIST_FILE = "disposable_email_blocklist.conf";
const BLOCKLIST_REPO = "disposable-email-domains/disposable-email-domains";
const SOURCE_PREFIX = "disposable-email-domains@";
/** 이보다 적으면 잘못 받은 목록으로 보고 쓰지 않는다 (실제 목록은 수천 개) */
export const MIN_DOMAINS = 500;
const BATCH = 1000;

// 영문 소문자 · 숫자 · 하이픈 라벨 둘 이상 (xn-- 로 시작하는 국제화 도메인 포함). 3–253자
const DOMAIN = /^(?=.{3,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;

export const isCommitSha = (value: string): boolean => /^[0-9a-f]{40}$/.test(value);
export const blocklistUrl = (commit: string): string => `https://raw.githubusercontent.com/${BLOCKLIST_REPO}/${commit}/${BLOCKLIST_FILE}`;
export const sourceTag = (commit: string): string => `${SOURCE_PREFIX}${commit}`;

/** 줄마다 도메인 하나. `#` 뒤는 주석. 도메인 모양이 아닌 줄은 버리고, 중복은 처음 것만 남긴다 */
export function parseBlocklist(text: string): string[] {
  const seen = new Set<string>();
  for (const line of text.split("\n")) {
    const domain = line.split("#")[0].trim().toLowerCase();
    if (domain && DOMAIN.test(domain)) seen.add(domain);
  }
  return [...seen];
}

export type SyncAdmin = Pick<SupabaseClient, "from">;

/**
 * `admin`은 쓸 때만 부른다 (--yes 없이는 서비스 키를 읽지도 않는다). 쓰지 않으면 `written: false`.
 * 도메인이 `MIN_DOMAINS`보다 적으면 쓰지 않고 멈춘다.
 */
export async function runSync(options: {
  commit: string;
  yes: boolean;
  fetchText: (url: string) => Promise<string>;
  admin: () => SyncAdmin | Promise<SyncAdmin>;
  log: (line: string) => void;
}): Promise<{ written: boolean; domains: number }> {
  const { commit, yes, fetchText, admin, log } = options;
  if (!isCommitSha(commit)) throw new Error("--commit에 40자리 커밋 해시가 필요합니다 (브랜치 이름은 받지 않습니다).");
  const domains = parseBlocklist(await fetchText(blocklistUrl(commit)));
  if (domains.length < MIN_DOMAINS) throw new Error(`도메인이 너무 적습니다 (${domains.length}개 < ${MIN_DOMAINS}). 잘못 받은 목록으로 지우지 않고 멈춥니다.`);
  const source = sourceTag(commit);
  log(`출처 ${source}: 도메인 ${domains.length}개`);
  if (!yes) {
    log("--yes를 붙이면 위 DB에 씁니다. 아무것도 쓰지 않고 끝냅니다.");
    return { written: false, domains: domains.length };
  }

  const client = await admin();
  for (let start = 0; start < domains.length; start += BATCH) {
    const rows = domains.slice(start, start + BATCH).map((domain) => ({ domain, source }));
    await client.from("blocked_email_domains").upsert(rows, { onConflict: "domain" }).throwOnError();
  }
  // 이 도구가 넣은 옛 커밋의 도메인 중 새 목록에 없는 것 (새 목록에 있던 것은 위 upsert가 출처를 새 커밋으로 바꿨다)
  await client.from("blocked_email_domains").delete().like("source", `${SOURCE_PREFIX}%`).neq("source", source).throwOnError();
  log(`${domains.length}개를 반영했습니다.`);
  return { written: true, domains: domains.length };
}

async function main() {
  if (existsSync(".env.local")) process.loadEnvFile(".env.local");
  const { values } = parseArgs({ options: { commit: { type: "string" }, yes: { type: "boolean", default: false } } });
  console.log(`대상 Supabase: ${process.env.NEXT_PUBLIC_SUPABASE_URL}`);
  await runSync({
    commit: values.commit ?? "",
    yes: values.yes ?? false,
    fetchText: async (url) => {
      const response = await fetch(url);
      if (!response.ok) throw new Error(`목록을 받지 못했습니다 (${response.status}): ${url}`);
      return response.text();
    },
    // server-only 모듈은 쓸 때만 불러온다 (시험이 이 파일을 불러올 때 막히지 않게)
    admin: async () => (await import("../src/lib/supabase/admin")).createAdminClient(),
    log: console.log,
  });
}

// 시험이 이 파일을 불러올 때는 돌리지 않는다 (직접 실행할 때만)
if (process.argv[1]?.endsWith("sync-blocked-email-domains.ts")) {
  main().catch((error) => {
    console.error("실패:", error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
