// 저장된 원문을 다시 처리해 Action으로 반영한다 (Phase 3 이전에 들어온 원문 채우기, 처리 실패 재시도).
// 기본: 아직 근거(evidence)가 하나도 없는 원문만 오래된 순서로. 이미 반영된 원문을 다시 돌려도 매칭이 "중복"으로 판정하지만,
// Claim이 한 번 더 쌓이므로 기본에서는 뺀다.
// 외부 AI 처리에 동의한 사용자의 원문만 처리한다 (profiles.ai_consent_at). 보관 기간이 지나 글이 지워진 원문은 건너뛴다.
// 도중에 동의를 철회하면 그 사용자의 남은 원문은 처리하지 않는다 (processSource가 모델 호출 직전에 다시 확인한다).
//
//   npx tsx --conditions react-server scripts/reprocess-sources.ts [--source <id>] [--dry-run]
//
// --notion-authors <user id>: 그 사용자의 Notion 문서 원문(kind doc) 중 작성자를 모르는 것(written_by_me null)의 만든 사람을
// 저장된 연결 토큰으로 Notion에서 확인해 written_by_me를 채우고, 사용자가 쓴 문서로 밝혀진 원문만 다시 처리한다
// (written_by_me가 생기기 전에 들어온 원문 채우기, docs/TRUTH_RULES.md 1장). 근거가 이미 있는 원문은 --source로만 다시 처리한다.
// --dry-run이면 Notion에서 확인만 하고 DB에 쓰지 않는다.
//
//   npx tsx --conditions react-server scripts/reprocess-sources.ts --notion-authors <user id> [--dry-run]
//
// server-only 모듈을 불러오므로 react-server 조건이 필요하다. 키는 .env.local에서 읽는다.
import { existsSync } from "node:fs";
import { parseArgs } from "node:util";

import { ConsentRequiredError } from "../src/lib/consent/gate";
import { pageWrittenByMe } from "../src/lib/connectors/notion/map";
import { withNotionClient } from "../src/lib/connectors/notion/run";
import { savedNotionUserId } from "../src/lib/connectors/notion/sync";
import { loadIdentity } from "../src/lib/connectors/store";
import type { Connection } from "../src/lib/connectors/types";
import type { ExtractInput } from "../src/lib/pipeline/extract";
import type { UserIdentity } from "../src/lib/pipeline/identity";
import { createAdminClient } from "../src/lib/supabase/admin";
import { processSource } from "../src/lib/sources/process";

if (existsSync(".env.local")) process.loadEnvFile(".env.local");

const { values } = parseArgs({
  options: { source: { type: "string" }, "dry-run": { type: "boolean", default: false }, "notion-authors": { type: "string" } },
});
type SourceRow = {
  id: string;
  user_id: string;
  kind: ExtractInput["kind"];
  raw_text: string;
  occurred_at: string;
  participants: ExtractInput["participants"] | null;
  written_by_me: boolean | null;
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

type Admin = ReturnType<typeof createAdminClient>;

/**
 * 사용자의 Notion 문서 원문 중 작성자를 모르는 것의 만든 사람을 확인해 written_by_me를 채운다. 사용자가 쓴 것으로 밝혀진 원문 id를 돌려준다.
 * 연결한 사람은 연결 설정의 notionUserId, 없으면 봇 주인(GET /v1/users/me). 페이지가 지워졌거나 공유가 빠졌으면 모름으로 둔다.
 */
async function fillNotionAuthors(admin: Admin, userId: string, dryRun: boolean): Promise<Set<string>> {
  const mine = new Set<string>();
  const { data: rows } = await admin
    .from("connections")
    .select("id, user_id, provider, settings, sync_cursor")
    .eq("user_id", userId)
    .eq("provider", "notion")
    .throwOnError();
  for (const row of (rows ?? []) as { id: string; user_id: string; settings: Record<string, unknown> | null; sync_cursor: Record<string, unknown> | null }[]) {
    const connection: Connection = { id: row.id, userId: row.user_id, provider: "notion", settings: row.settings ?? {}, syncCursor: row.sync_cursor };
    const sources = await readAll<{ id: string; external_id: string }>((from, to) =>
      admin
        .from("sources")
        .select("id, external_id")
        .eq("user_id", userId)
        .eq("connection_id", connection.id)
        .eq("kind", "doc")
        .is("written_by_me", null)
        .order("id")
        .range(from, to),
    );
    if (sources.length === 0) continue;

    // 토큰이 만료돼 갱신하면 withNotionClient가 처음부터 다시 부르므로, 세는 값은 부를 때마다 새로 만든다.
    const counts = await withNotionClient(admin, connection.id, async (client) => {
      const counts = { mine: 0, others: 0, unknown: 0 };
      const owner = savedNotionUserId(connection) ?? (await client.botOwnerId());
      if (!owner) {
        console.log(`연결 ${connection.id}: 연결한 사람을 알 수 없어 건너뜁니다`);
        return { ...counts, unknown: sources.length };
      }
      for (const source of sources) {
        const page = await client.page(source.external_id);
        const writtenByMe = page ? pageWrittenByMe(page, "doc", owner) : null;
        if (writtenByMe === null) {
          counts.unknown++;
          continue;
        }
        counts[writtenByMe ? "mine" : "others"]++;
        if (writtenByMe) mine.add(source.id);
        if (!dryRun) {
          await admin.from("sources").update({ written_by_me: writtenByMe }).eq("id", source.id).eq("user_id", userId).throwOnError();
        }
      }
      return counts;
    });
    console.log(`연결 ${connection.id}: 문서 ${sources.length}건 — 내가 씀 ${counts.mine} · 다른 사람 ${counts.others} · 모름 ${counts.unknown}${dryRun ? " (dry-run, 쓰지 않음)" : ""}`);
  }
  return mine;
}

async function main() {
  const admin = createAdminClient();
  const notionAuthorsOf = values["notion-authors"];
  const writtenByMine = notionAuthorsOf ? await fillNotionAuthors(admin, notionAuthorsOf, values["dry-run"]) : null;

  const sources = await readAll<SourceRow>((from, to) => {
    // 구조화된 할 일(kind = task)은 LLM으로 다시 읽지 않는다. 실패한 버전은 동기화가 다시 처리한다 (connectors/tasks-ingest.ts).
    let query = admin
      .from("sources")
      .select("id, user_id, kind, raw_text, occurred_at, participants, written_by_me")
      .neq("kind", "task")
      .is("raw_text_purged_at", null)
      .order("occurred_at")
      .order("id");
    if (values.source) query = query.eq("id", values.source);
    return query.range(from, to);
  });
  const withEvidence = await readAll<{ source_id: string }>((from, to) => admin.from("evidence").select("source_id").order("id").range(from, to));
  const reflected = new Set(withEvidence.map((row) => row.source_id));
  const consented = new Set(
    (
      await readAll<{ user_id: string }>((from, to) =>
        admin.from("profiles").select("user_id").not("ai_consent_at", "is", null).order("user_id").range(from, to),
      )
    ).map((row) => row.user_id),
  );
  const scoped = writtenByMine ? sources.filter((s) => writtenByMine.has(s.id)) : sources;
  if (writtenByMine) console.log(`사용자가 쓴 문서 ${writtenByMine.size}건 중 이미 근거가 있어 다시 처리하지 않는 원문 ${scoped.filter((s) => reflected.has(s.id)).length}건`);
  const candidates = scoped.filter((s) => values.source || !reflected.has(s.id));
  const targets = candidates.filter((s) => consented.has(s.user_id));
  console.log(`원문 ${sources.length}건 중 처리 대상 ${targets.length}건 (동의하지 않은 사용자의 원문 ${candidates.length - targets.length}건 제외)`);
  if (values["dry-run"]) process.exit(0);

  const identities = new Map<string, UserIdentity>();
  async function identityOf(userId: string) {
    const identity = identities.get(userId) ?? (await loadIdentity(admin, userId));
    identities.set(userId, identity);
    return identity;
  }

  // 순서가 중요하다 (나중 원문이 앞 원문의 약속을 바꾼다): 하나씩 오래된 것부터.
  const withdrawn = new Set<string>();
  for (const [i, source] of targets.entries()) {
    if (withdrawn.has(source.user_id)) continue;
    const started = Date.now();
    try {
      const result = await processSource(admin, { id: source.id, userId: source.user_id }, {
        text: source.raw_text,
        kind: source.kind,
        occurredAt: new Date(source.occurred_at),
        identity: await identityOf(source.user_id),
        participants: source.participants ?? undefined,
        writtenByMe: source.written_by_me,
      });
      const { data: row } = await admin.from("sources").select("processing_status, processing_summary").eq("id", source.id).single();
      console.log(
        `[${i + 1}/${targets.length}] ${source.id} ${row?.processing_status} ${((Date.now() - started) / 1000).toFixed(1)}s`,
        JSON.stringify(row?.processing_summary ?? {}),
        result.needsConfirmation.length > 0 ? `확인 요청 ${result.needsConfirmation.length}` : "",
      );
    } catch (error) {
      if (error instanceof ConsentRequiredError) withdrawn.add(source.user_id);
      console.error(`[${i + 1}/${targets.length}] ${source.id} 실패:`, error instanceof Error ? error.message : error);
    }
  }
}

main();
