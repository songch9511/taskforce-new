import type { SupabaseClient } from "@supabase/supabase-js";

// 시험 전용: PostgREST 질의 일부(select · eq · in · order · limit · single · insert · update · upsert · rpc)를 메모리 표로 흉내 낸다.
// 앱 코드는 가져오지 않는다. 호출 기록(calls)으로 "쓰기 0" · "RPC 0"을 센다.

type Row = Record<string, unknown>;
export type FakeCall = { kind: "select" | "insert" | "update" | "upsert" | "rpc"; target: string; args?: unknown; filters?: [string, string, unknown][] };
export type FakeError = { code: string; message: string; name?: string };

/** 'args->>x' 같은 jsonb 경로 열을 읽는다 */
function read(row: Row, column: string): unknown {
  const [head, ...rest] = column.split("->>");
  const value = row[head];
  if (!rest.length) return value;
  return value && typeof value === "object" ? (value as Row)[rest[0]] : undefined;
}

export function fakeAdmin(options: {
  tables?: Record<string, Row[]>;
  rpc?: Record<string, (args: Record<string, unknown>) => unknown>;
  /** table.op → 던질 오류 (op: select · insert · update · upsert) */
  fail?: Record<string, FakeError>;
  /** insert 때 DB 기본값처럼 채울 열 (표 이름 → 열) */
  defaults?: Record<string, Row>;
  /** 쓰기를 실행하기 직전 (동시에 끼어드는 다른 요청을 흉내 낸다) */
  beforeWrite?: (call: { table: string; op: "insert" | "update" | "upsert"; payload: unknown }) => void;
} = {}) {
  const tables = options.tables ?? {};
  const calls: FakeCall[] = [];

  function builder(table: string) {
    const filters: [string, string, unknown][] = [];
    let op: "select" | "insert" | "update" | "upsert" = "select";
    let payload: unknown;
    let single: "maybe" | "single" | null = null;
    let order: { column: string; ascending: boolean } | null = null;
    let limit: number | null = null;
    let returning = false;
    let columns: string[] | null = null;

    const run = () => {
      const failure = options.fail?.[`${table}.${op}`];
      calls.push({ kind: op, target: table, args: payload, filters: [...filters] });
      if (failure) return { data: null, error: failure };
      if (op !== "select") options.beforeWrite?.({ table, op, payload });
      const rows = (tables[table] ??= []);
      const matches = (row: Row) =>
        filters.every(([column, kind, value]) =>
          kind === "eq"
            ? read(row, column) === value
            : kind === "neq"
              ? read(row, column) !== value
              : kind === "gt"
                ? (read(row, column) as number) > (value as number)
                : (value as unknown[]).includes(read(row, column)),
        );
      let result: Row[];
      if (op === "insert" || op === "upsert") {
        const inserted = (Array.isArray(payload) ? payload : [payload]) as Row[];
        result = [];
        for (const item of inserted) {
          const clash = op === "upsert" && item.id !== undefined && rows.some((row) => row.id === item.id);
          if (clash) continue; // ignoreDuplicates
          const row = { ...options.defaults?.[table], ...item };
          rows.push(row);
          result.push({ ...row });
        }
      } else if (op === "update") {
        result = rows.filter(matches);
        for (const row of result) Object.assign(row, payload as Row);
        result = result.map((row) => ({ ...row }));
      } else {
        result = rows.filter(matches).map((row) => ({ ...row }));
      }
      if (order) {
        const { column, ascending } = order;
        result.sort((a, b) => {
          const left = read(a, column) as number | string;
          const right = read(b, column) as number | string;
          return (left < right ? -1 : left > right ? 1 : 0) * (ascending ? 1 : -1);
        });
      }
      if (limit !== null) result = result.slice(0, limit);
      if (columns) result = result.map((row) => Object.fromEntries(columns!.map((column) => [column, row[column]])));
      if ((op === "insert" || op === "update") && !returning) return { data: null, error: null };
      if (single === "maybe") return { data: result[0] ?? null, error: null };
      if (single === "single") return result[0] ? { data: result[0], error: null } : { data: null, error: { code: "PGRST116", message: "no rows" } };
      return { data: result, error: null };
    };

    const api: Record<string, unknown> = {
      select: (list?: string) => {
        returning = true;
        // PostgREST처럼 고른 열만 돌려준다 (공백 · 쉼표로 나눈 열 이름)
        columns = list && list.trim() !== "*" ? list.split(",").map((column) => column.trim()) : null;
        return api;
      },
      insert: (value: unknown) => {
        op = "insert";
        payload = value;
        return api;
      },
      update: (value: unknown) => {
        op = "update";
        payload = value;
        return api;
      },
      upsert: (value: unknown) => {
        op = "upsert";
        payload = value;
        return api;
      },
      eq: (column: string, value: unknown) => {
        filters.push([column, "eq", value]);
        return api;
      },
      in: (column: string, values: unknown[]) => {
        filters.push([column, "in", values]);
        return api;
      },
      neq: (column: string, value: unknown) => {
        filters.push([column, "neq", value]);
        return api;
      },
      gt: (column: string, value: unknown) => {
        filters.push([column, "gt", value]);
        return api;
      },
      order: (column: string, opts?: { ascending?: boolean }) => {
        order = { column, ascending: opts?.ascending ?? true };
        return api;
      },
      limit: (n: number) => {
        limit = n;
        return api;
      },
      maybeSingle: () => {
        single = "maybe";
        return api;
      },
      single: () => {
        single = "single";
        return api;
      },
      throwOnError: () => {
        const { data, error } = run();
        if (error) return Promise.reject(Object.assign(new Error(error.message), error));
        return Promise.resolve({ data, error: null });
      },
      then: (resolve: (value: unknown) => unknown, reject?: (reason: unknown) => unknown) => Promise.resolve(run()).then(resolve, reject),
    };
    return api;
  }

  function rpc(name: string, args: Record<string, unknown>) {
    calls.push({ kind: "rpc", target: name, args });
    const handler = options.rpc?.[name];
    const settle = () => {
      if (!handler) throw new Error(`fake rpc ${name} 없음`);
      return handler(args);
    };
    const chain: Record<string, unknown> = {
      single: () => chain,
      throwOnError: () => {
        try {
          return Promise.resolve({ data: settle(), error: null });
        } catch (error) {
          return Promise.reject(error);
        }
      },
    };
    return chain;
  }

  const admin = { from: (table: string) => builder(table), rpc } as unknown as SupabaseClient;
  return { admin, tables, calls, rpcCalls: (name?: string) => calls.filter((call) => call.kind === "rpc" && (name === undefined || call.target === name)) };
}
