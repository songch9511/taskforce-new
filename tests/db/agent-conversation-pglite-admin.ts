import type { SupabaseClient } from "@supabase/supabase-js";

import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

// 시험 전용: 운영 TS(next-turn.ts · messages.ts)를 실제 SQL(PGlite)에 그대로 붙이는 작은 supabase-js 흉내.
// from().select().eq().in().maybeSingle().throwOnError()와 rpc(이름, 인자).throwOnError()만 같은 뜻의 SQL로 옮긴다.
// 열 · 표 · 함수 이름은 운영 코드가 정한 리터럴이라 그대로 SQL에 넣는다. before(name)는 그 RPC를 실행하기 직전에 끼어드는 "다른 요청"을 흉내 낸다.

type Row = Record<string, unknown>;

export function pgliteAgentAdmin(db: ConversationAgentDb, options: { before?: (name: string) => Promise<void> } = {}): SupabaseClient {
  const plain = (row: Row) => Object.fromEntries(Object.entries(row).map(([key, value]) => [key, value instanceof Date ? value.toISOString() : value]));

  const from = (table: string) => {
    const where: string[] = [];
    const params: unknown[] = [];
    let columns = "*";
    let order = "";
    let limit = "";
    let single = false;
    const run = async () => {
      const rows = await db.query(`select ${columns} from public.${table}${where.length ? ` where ${where.join(" and ")}` : ""}${order}${limit}`, params);
      const data = rows.map(plain);
      return single ? { data: data[0] ?? null, error: null } : { data, error: null };
    };
    const builder = {
      select: (value: string) => ((columns = value), builder),
      eq: (column: string, value: unknown) => (params.push(value), where.push(`${column} = $${params.length}`), builder),
      in: (column: string, values: unknown[]) => (params.push(values.map(String)), where.push(`${column}::text = any($${params.length}::text[])`), builder),
      order: (column: string, direction?: { ascending?: boolean }) => ((order = ` order by ${column}${direction?.ascending === false ? " desc" : ""}`), builder),
      limit: (count: number) => ((limit = ` limit ${count}`), builder),
      maybeSingle: () => ((single = true), builder),
      throwOnError: () => builder,
      then: (resolve: (value: unknown) => unknown, reject: (error: unknown) => unknown) => run().then(resolve, reject),
    };
    return builder;
  };

  const rpc = (name: string, args: Record<string, unknown> = {}) => {
    const run = async () => {
      await options.before?.(name);
      const keys = Object.keys(args);
      const rows = await db.query(`select public.${name}(${keys.map((key, index) => `${key} => $${index + 1}`).join(", ")}) as result`, keys.map((key) => args[key]));
      return { data: rows[0]?.result ?? null, error: null };
    };
    const builder = {
      throwOnError: () => builder,
      then: (resolve: (value: unknown) => unknown, reject: (error: unknown) => unknown) => run().then(resolve, reject),
    };
    return builder;
  };

  return { from, rpc } as unknown as SupabaseClient;
}
