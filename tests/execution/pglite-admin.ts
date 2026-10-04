import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";

// 운영 store.ts의 크레딧 읽기(loadCredits · loadCreditDetails · executionGloballyBlocked)를 PGlite에서 그대로 부르는 작은 supabase-js 흉내.
// PostgREST가 하는 일 중 그 함수들이 쓰는 것만 같은 뜻의 SQL로 옮긴다: from().select().eq().in().order().range() · maybeSingle() · throwOnError().
// 열 · 표 이름은 운영 코드가 정한 리터럴이라 그대로 SQL에 넣는다 (테스트 전용). 시각은 PostgREST처럼 ISO 문자열로 돌려준다.

export function pgliteAdmin(db: PGlite): SupabaseClient {
  const from = (table: string) => {
    const where: string[] = [];
    const params: unknown[] = [];
    let columns = "*";
    let order = "";
    let page = "";
    let single = false;
    const run = async () => {
      const { rows } = await db.query<Record<string, unknown>>(
        `select ${columns} from public.${table}${where.length ? ` where ${where.join(" and ")}` : ""}${order}${page}`,
        params,
      );
      const data = rows.map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v instanceof Date ? v.toISOString() : v])));
      return single ? { data: data[0] ?? null, error: null } : { data, error: null };
    };
    const builder = {
      select: (c: string) => ((columns = c), builder),
      eq: (c: string, v: unknown) => (params.push(v), where.push(`${c} = $${params.length}`), builder),
      in: (c: string, v: unknown[]) => (params.push(v.map(String)), where.push(`${c}::text = any($${params.length}::text[])`), builder),
      order: (c: string) => ((order = order ? `${order}, ${c}` : ` order by ${c}`), builder),
      range: (a: number, b: number) => ((page = ` offset ${a} limit ${b - a + 1}`), builder),
      maybeSingle: () => ((single = true), builder),
      throwOnError: () => builder,
      then: (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) => run().then(resolve, reject),
    };
    return builder;
  };
  return { from } as unknown as SupabaseClient;
}
