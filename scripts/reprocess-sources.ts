// 저장된 원문을 다시 처리해 Action으로 반영한다 (Phase 3 이전에 들어온 원문 채우기, 처리 실패 재시도).
// 기본: 아직 근거(evidence)가 하나도 없는 원문만 오래된 순서로. 이미 반영된 원문을 다시 돌려도 매칭이 "중복"으로 판정하지만,
// Claim이 한 번 더 쌓이므로 기본에서는 뺀다.
//
//   npx tsx --conditions react-server scripts/reprocess-sources.ts [--source <id>] [--dry-run]
//
// server-only 모듈을 불러오므로 react-server 조건이 필요하다. 키는 .env.local에서 읽는다.
import { existsSync } from "node:fs";
import { parseArgs } from "node:util";

import { profileSchema } from "../src/lib/api/contract";
import { accountDisplayName, resolveIdentity } from "../src/lib/api/profile";
import type { ExtractInput } from "../src/lib/pipeline/extract";
import { createAdminClient } from "../src/lib/supabase/admin";
import { processSource } from "../src/lib/sources/process";

if (existsSync(".env.local")) process.loadEnvFile(".env.local");

const { values } = parseArgs({ options: { source: { type: "string" }, "dry-run": { type: "boolean", default: false } } });
type SourceRow = {
  id: string;
  user_id: string;
  kind: ExtractInput["kind"];
  raw_text: string;
  occurred_at: string;
  participants: ExtractInput["participants"] | null;
};

/** PostgREST는 한 번에 최대 행 수(기본 1000)까지만 주므로 끝까지 나눠 읽는다. */
async function readAll<T>(page: (from: number, to: number) => PromiseLike<{ data: unknown[] | null; error: unknown }>): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await page(from, from + 999);
    if (error) throw error;
    rows.push(...((data ?? []) as T[]));
    if ((data ?? []).length < 1000) return rows;
  }
}

async function main() {
  const admin = createAdminClient();

  const sources = await readAll<SourceRow>((from, to) => {
    let query = admin.from("sources").select("id, user_id, kind, raw_text, occurred_at, participants").order("occurred_at").order("id");
    if (values.source) query = query.eq("id", values.source);
    return query.range(from, to);
  });
  const withEvidence = await readAll<{ source_id: string }>((from, to) => admin.from("evidence").select("source_id").order("id").range(from, to));
  const reflected = new Set(withEvidence.map((row) => row.source_id));
  const targets = sources.filter((s) => values.source || !reflected.has(s.id));
  console.log(`원문 ${sources.length}건 중 처리 대상 ${targets.length}건`);
  if (values["dry-run"]) process.exit(0);

  const identities = new Map<string, ReturnType<typeof resolveIdentity>>();
  async function identityOf(userId: string) {
    const cached = identities.get(userId);
    if (cached) return cached;
    const [{ data: profileRow }, { data: account }] = await Promise.all([
      admin.from("profiles").select("display_name, aliases, emails").eq("user_id", userId).maybeSingle(),
      admin.auth.admin.getUserById(userId),
    ]);
    const email = account.user?.email ?? null;
    const identity = resolveIdentity(profileSchema.safeParse(profileRow).data ?? null, {
      name: accountDisplayName(account.user?.user_metadata, email),
      email,
    });
    identities.set(userId, identity);
    return identity;
  }

  // 순서가 중요하다 (나중 원문이 앞 원문의 약속을 바꾼다): 하나씩 오래된 것부터.
  for (const [i, source] of targets.entries()) {
    const started = Date.now();
    try {
      const result = await processSource(admin, { id: source.id, userId: source.user_id }, {
        text: source.raw_text,
        kind: source.kind,
        occurredAt: new Date(source.occurred_at),
        identity: await identityOf(source.user_id),
        participants: source.participants ?? undefined,
      });
      const { data: row } = await admin.from("sources").select("processing_status, processing_summary").eq("id", source.id).single();
      console.log(
        `[${i + 1}/${targets.length}] ${source.id} ${row?.processing_status} ${((Date.now() - started) / 1000).toFixed(1)}s`,
        JSON.stringify(row?.processing_summary ?? {}),
        result.needsConfirmation.length > 0 ? `확인 요청 ${result.needsConfirmation.length}` : "",
      );
    } catch (error) {
      console.error(`[${i + 1}/${targets.length}] ${source.id} 실패:`, error instanceof Error ? error.message : error);
    }
  }
}

main();
