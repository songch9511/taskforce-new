import type { Connection, IngestItem } from "./types";

// 연동에서 가져온 항목을 원문으로 저장하고 파이프라인에 넘긴다. 모든 연동이 이 한 곳을 지난다.
//
// 규칙
// - 막 바뀐 항목은 기다린다: 회의록은 회의가 끝난 뒤 AI 요약이 채워지므로, 마지막 수정 후 settleMinutes가 지나야 넣는다.
// - 한 항목은 한 번만 넣는다: 이미 넣은 항목이 나중에 고쳐져도 지금은 다시 넣지 않는다.
//   다시 넣으면 같은 약속이 두 번 생기므로, 기존 할 일과 맞춰 보는 Phase 2(매칭) 이후에 바뀐 부분만 넣는다.
// - 너무 짧은 항목(빈 페이지 등)은 넣지 않는다.

export type IngestOptions = {
  now: Date;
  settleMinutes: number;
  /** 한 번 동기화에서 새로 넣는 최대 개수 (비용 · 실행 시간 상한) */
  maxItems: number;
  minTextLength: number;
  /** 이 시각(ms)을 넘기면 새 항목 처리를 시작하지 않는다. 남은 항목은 다음 동기화에서 */
  deadline?: number;
};

export const DEFAULT_INGEST_OPTIONS: Omit<IngestOptions, "now"> = { settleMinutes: 30, maxItems: 20, minTextLength: 30 };

/** 동시에 처리하는 항목 수. 느린 항목 하나가 나머지를 붙잡지 않게 하되, 모델 · Notion 속도 제한은 넘지 않게 작게 둔다. */
const CONCURRENCY = 3;

export type IngestDeps = {
  /** 이 연결에서 이미 넣은 외부 id 목록 */
  ingestedIds: (connection: Connection, externalIds: string[]) => Promise<Set<string>>;
  /** 원문을 저장하고 id를 돌려준다. 동시에 같은 항목이 들어와 충돌하면 null */
  insertSource: (connection: Connection, item: IngestItem) => Promise<string | null>;
  process: (connection: Connection, sourceId: string, item: IngestItem) => Promise<void>;
};

export type IngestResult = {
  created: string[];
  /** 시간 한도에 걸려 이번에 처리하지 못한 항목의 외부 id */
  notReached: string[];
  skipped: { tooShort: number; settling: number; alreadyIngested: number; overLimit: number };
};

export async function ingestItems(
  connection: Connection,
  items: IngestItem[],
  deps: IngestDeps,
  options: IngestOptions,
): Promise<IngestResult> {
  const result: IngestResult = { created: [], notReached: [], skipped: { tooShort: 0, settling: 0, alreadyIngested: 0, overLimit: 0 } };
  const settledBefore = options.now.getTime() - options.settleMinutes * 60_000;

  const ready = items.filter((item) => {
    if (item.text.trim().length < options.minTextLength) {
      result.skipped.tooShort++;
      return false;
    }
    if (item.lastEditedAt.getTime() > settledBefore) {
      result.skipped.settling++;
      return false;
    }
    return true;
  });

  const already = await deps.ingestedIds(connection, ready.map((item) => item.externalId));
  const fresh = ready.filter((item) => {
    if (already.has(item.externalId)) {
      result.skipped.alreadyIngested++;
      return false;
    }
    return true;
  });

  // 오래된 것부터 넣는다. 상한을 넘은 항목은 다음 동기화에서 다시 본다.
  fresh.sort((a, b) => a.occurredAt.getTime() - b.occurredAt.getTime());
  result.skipped.overLimit = Math.max(0, fresh.length - options.maxItems);

  const batch = fresh.slice(0, options.maxItems);
  const created = new Array<string | null>(batch.length).fill(null);
  const notReached = new Set<number>();
  let next = 0;
  const worker = async () => {
    while (next < batch.length) {
      const index = next++;
      if (options.deadline && Date.now() > options.deadline) {
        notReached.add(index);
        continue;
      }
      const sourceId = await deps.insertSource(connection, batch[index]);
      if (!sourceId) {
        result.skipped.alreadyIngested++;
        continue;
      }
      created[index] = sourceId;
      await deps.process(connection, sourceId, batch[index]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, batch.length) }, worker));

  result.created = created.filter((id): id is string => id !== null);
  result.notReached = batch.filter((_, index) => notReached.has(index)).map((item) => item.externalId);
  return result;
}
