import type { PGlite } from "@electric-sql/pglite";

import { CLAIM_COLUMNS, claimFromRow, type ClaimRow } from "@/lib/actions/rows";
import type { ReceiptStore, ReceiptTarget, ReceiptWriteResult } from "@/lib/execution/receipt";

// receipt 쓰기(src/lib/execution/receipt.ts)를 PGlite에서 돌리는 store. 운영 store(receipt-store.ts, supabase-js)와 같은 SQL 함수를 부르고,
// 읽기만 같은 뜻의 SQL로 옮겼다.

export function pgliteReceiptStore(db: PGlite): ReceiptStore {
  const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0];

  return {
    async receiptTarget(stepId) {
      const row = await one<{ run_id: string; user_id: string; action_id: string; artifact_id: string; title: string; created_at: Date }>(
        `select s.run_id, s.user_id, r.action_id, a.id as artifact_id, a.title, a.created_at
         from public.execution_steps s
         join public.execution_runs r on r.id = s.run_id and r.user_id = s.user_id
         join public.execution_artifacts a on a.step_id = s.id and a.user_id = s.user_id
         where s.id = $1 and s.kind = 'draft' and s.state = 'called'`,
        [stepId],
      );
      if (!row) return null;
      const target: ReceiptTarget = {
        stepId,
        runId: row.run_id,
        userId: row.user_id,
        actionId: row.action_id,
        artifact: { id: row.artifact_id, title: row.title, createdAt: new Date(row.created_at) },
      };
      return target;
    },
    async loadAction(userId, actionId) {
      const row = await one<{ version: number; title: string; confirm_reasons: string[] }>(
        "select version, title, confirm_reasons from public.actions where id = $1 and user_id = $2",
        [actionId, userId],
      );
      if (!row) return null;
      // PGlite는 시각을 Date로 돌려준다 (claimFromRow는 문자열 · Date 모두 읽는다)
      const claims = (await db.query<ClaimRow>(`select ${CLAIM_COLUMNS} from public.claims where action_id = $1 and user_id = $2`, [actionId, userId])).rows;
      return { version: row.version, title: row.title, confirmReasons: row.confirm_reasons, claims: claims.map(claimFromRow) };
    },
    async writeReceipt(stepId, expectedVersion, action, receipt) {
      const row = await one<{ r: ReceiptWriteResult }>("select public.write_execution_receipt($1, $2, $3::jsonb, $4::jsonb) as r", [
        stepId,
        expectedVersion,
        JSON.stringify(action),
        JSON.stringify(receipt),
      ]);
      return row.r;
    },
    async missingReceipts(limit) {
      return (await db.query<{ step_id: string }>("select step_id from public.missing_execution_receipts($1)", [limit])).rows.map((r) => r.step_id);
    },
  };
}
