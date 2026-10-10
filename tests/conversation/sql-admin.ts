import type { SupabaseClient } from "@supabase/supabase-js";

// 운영 서버 코드(src/lib/conversation/store.ts · src/lib/context/store.ts의 읽기)를 PGlite · 실제 Postgres에서 그대로 부르는 작은 supabase-js 흉내 (테스트 전용).
// PostgREST가 하는 일 중 그 코드가 쓰는 것만 같은 뜻의 SQL로 옮긴다:
//   from().select(열, {count}).eq().neq().lt().lte().gt().gte().in().is().or("a.eq.x,b.in.(y,z)").order().limit().maybeSingle().single() ·
//   insert() · upsert({onConflict, ignoreDuplicates}) · update() · delete() (+ .select()) · rpc(이름, 이름 붙인 인자).single() · throwOnError()
// 열 · 표 이름은 운영 코드가 정한 리터럴이라 그대로 SQL에 넣는다. 시각은 PostgREST처럼 ISO 문자열, numeric은 숫자로 돌려준다.
// 서버(service role)처럼 RLS 없이 돈다: 운영 코드가 user_id로 좁히는지가 그대로 시험된다.

export type Query = (sql: string, params?: unknown[]) => Promise<Record<string, unknown>[]>;

type Filter = { sql: (p: (v: unknown) => string) => string };

const NUMERIC_COLUMNS = new Set(["confidence", "similarity"]);

function normalizeRow(row: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(row).map(([key, value]) => {
      if (value instanceof Date) return [key, value.toISOString()];
      if (NUMERIC_COLUMNS.has(key) && typeof value === "string") return [key, Number(value)];
      return [key, value];
    }),
  );
}

/** "a.eq.x,b.in.(y,z)" → 위쪽 쉼표로 나눈 조건들 */
function splitOr(expression: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let current = "";
  for (const ch of expression) {
    if (ch === "(") depth++;
    if (ch === ")") depth--;
    if (ch === "," && depth === 0) {
      parts.push(current);
      current = "";
    } else current += ch;
  }
  if (current) parts.push(current);
  return parts;
}

export function sqlAdmin(query: Query): SupabaseClient {
  const from = (table: string) => {
    let mode: "select" | "insert" | "upsert" | "update" | "delete" = "select";
    let columns = "*";
    let returning: string | null = null;
    let count = false;
    let rows: Record<string, unknown>[] = [];
    let values: Record<string, unknown> = {};
    let conflict: { columns: string; ignore: boolean } | null = null;
    const filters: Filter[] = [];
    let order: string[] = [];
    let limit: number | null = null;
    let single: "maybe" | "one" | null = null;

    const run = async () => {
      const params: unknown[] = [];
      const p = (v: unknown) => {
        params.push(v !== null && typeof v === "object" && !Array.isArray(v) ? JSON.stringify(v) : v);
        return `$${params.length}`;
      };
      const where = () => (filters.length ? ` where ${filters.map((f) => f.sql(p)).join(" and ")}` : "");
      let sql: string;
      if (mode === "select") {
        sql = `select ${columns} from public.${table}${where()}${order.length ? ` order by ${order.join(", ")}` : ""}${limit !== null ? ` limit ${limit}` : ""}`;
      } else if (mode === "insert" || mode === "upsert") {
        const keys = [...new Set(rows.flatMap((r) => Object.keys(r)))];
        const tuples = rows.map((r) => `(${keys.map((k) => p(r[k] ?? null)).join(", ")})`).join(", ");
        const onConflict = conflict ? ` on conflict (${conflict.columns}) ${conflict.ignore ? "do nothing" : `do update set ${keys.map((k) => `${k} = excluded.${k}`).join(", ")}`}` : "";
        sql = `insert into public.${table} (${keys.join(", ")}) values ${tuples}${onConflict}${returning ? ` returning ${returning}` : ""}`;
      } else if (mode === "update") {
        const sets = Object.entries(values).map(([k, v]) => `${k} = ${p(v)}`);
        sql = `update public.${table} set ${sets.join(", ")}${where()}${returning ? ` returning ${returning}` : ""}`;
      } else {
        sql = `delete from public.${table}${where()}${returning ? ` returning ${returning}` : ""}`;
      }
      const data = (await query(sql, params)).map(normalizeRow);
      let total: number | null = null;
      if (count && mode === "select") {
        const countParams: unknown[] = [];
        const cp = (v: unknown) => {
          countParams.push(v);
          return `$${countParams.length}`;
        };
        const countRows = await query(`select count(*)::int as n from public.${table}${filters.length ? ` where ${filters.map((f) => f.sql(cp)).join(" and ")}` : ""}`, countParams);
        total = Number(countRows[0].n);
      }
      if (single === "one") {
        if (data.length !== 1) throw new Error(`single: ${data.length}행`);
        return { data: data[0], error: null, count: total };
      }
      if (single === "maybe") return { data: data[0] ?? null, error: null, count: total };
      return { data: mode === "select" || returning ? data : null, error: null, count: total };
    };

    const builder = {
      select: (c = "*", options: { count?: string } = {}) => {
        if (mode === "select") columns = c;
        else returning = c;
        count = options.count === "exact";
        return builder;
      },
      insert: (r: Record<string, unknown> | Record<string, unknown>[]) => ((mode = "insert"), (rows = Array.isArray(r) ? r : [r]), builder),
      upsert: (r: Record<string, unknown> | Record<string, unknown>[], options: { onConflict?: string; ignoreDuplicates?: boolean } = {}) => {
        mode = "upsert";
        rows = Array.isArray(r) ? r : [r];
        conflict = { columns: options.onConflict ?? "id", ignore: options.ignoreDuplicates ?? false };
        return builder;
      },
      update: (v: Record<string, unknown>) => ((mode = "update"), (values = v), builder),
      delete: () => ((mode = "delete"), builder),
      eq: (c: string, v: unknown) => (filters.push({ sql: (p) => `${c} = ${p(v)}` }), builder),
      neq: (c: string, v: unknown) => (filters.push({ sql: (p) => `${c} <> ${p(v)}` }), builder),
      lt: (c: string, v: unknown) => (filters.push({ sql: (p) => `${c} < ${p(v)}` }), builder),
      lte: (c: string, v: unknown) => (filters.push({ sql: (p) => `${c} <= ${p(v)}` }), builder),
      gt: (c: string, v: unknown) => (filters.push({ sql: (p) => `${c} > ${p(v)}` }), builder),
      gte: (c: string, v: unknown) => (filters.push({ sql: (p) => `${c} >= ${p(v)}` }), builder),
      in: (c: string, v: unknown[]) => (filters.push({ sql: (p) => `${c}::text = any(${p(v.map(String))}::text[])` }), builder),
      is: (c: string, v: null | boolean) => (filters.push({ sql: () => `${c} is ${v === null ? "null" : v ? "true" : "false"}` }), builder),
      or: (expression: string) => {
        const parts = splitOr(expression).map((part) => {
          const [column, op, ...rest] = part.split(".");
          const value = rest.join(".");
          if (op === "eq") return (p: (v: unknown) => string) => `${column}::text = ${p(value)}`;
          if (op === "in") return (p: (v: unknown) => string) => `${column}::text = any(${p(value.replace(/^\(|\)$/g, "").split(","))}::text[])`;
          throw new Error(`or: 모르는 연산 ${op}`);
        });
        filters.push({ sql: (p) => `(${parts.map((f) => f(p)).join(" or ")})` });
        return builder;
      },
      order: (c: string, options: { ascending?: boolean } = {}) => ((order = [...order, `${c} ${options.ascending === false ? "desc" : "asc"}`]), builder),
      limit: (n: number) => ((limit = n), builder),
      maybeSingle: () => ((single = "maybe"), builder),
      single: () => ((single = "one"), builder),
      throwOnError: () => builder,
      then: (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) => run().then(resolve, reject),
    };
    return builder;
  };

  const rpc = (fn: string, args: Record<string, unknown>) => {
    let single = false;
    const run = async () => {
      const keys = Object.keys(args);
      const params = keys.map((k) => {
        const v = args[k];
        return v !== null && typeof v === "object" && !Array.isArray(v) ? JSON.stringify(v) : v;
      });
      const rows = (await query(`select * from public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(", ")})`, params)).map(normalizeRow);
      if (single) return { data: rows[0], error: null };
      // 스칼라를 돌려주는 함수는 그 값 하나 (supabase-js와 같다)
      if (rows.length === 1 && Object.keys(rows[0]).length === 1 && Object.keys(rows[0])[0] === fn) return { data: rows[0][fn], error: null };
      return { data: rows, error: null };
    };
    const call = {
      single: () => ((single = true), call),
      throwOnError: () => call,
      then: (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) => run().then(resolve, reject),
    };
    return call;
  };

  return { from, rpc } as unknown as SupabaseClient;
}
