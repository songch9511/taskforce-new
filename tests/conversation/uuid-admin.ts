import type { PGlite } from "@electric-sql/pglite";
import type { SupabaseClient } from "@supabase/supabase-js";

// verifySelected(src/lib/conversation/store.ts)가 쓰는 읽기만 흉내 내는 작은 supabase-js (테스트 전용):
//   from(표).select(열).eq("user_id", 사용자).in("id", id들).throwOnError()
// sql-admin.ts는 .in을 id::text로 견주지만 실제 uuid 열은 대소문자와 상관없이 같은 값으로 견준다(PostgREST는 id=in.(...)를 uuid로 바꿔 견준다).
// 여기서는 id = any($::uuid[])로 그 뜻을 그대로 쓴다: 대소문자만 다른 같은 uuid는 한 행에 맞는다.
// 쓰지 않는 메서드는 만들지 않는다: verifySelected가 다른 방식으로 읽으면 시험이 바로 깨진다.

const TABLES = new Set(["actions", "execution_runs", "execution_artifacts"]);

export function uuidAdmin(db: PGlite): SupabaseClient {
  const from = (table: string) => {
    if (!TABLES.has(table)) throw new Error(`uuidAdmin: 모르는 표 ${table}`);
    let columns = "";
    let owner: string | undefined;
    let ids: string[] | undefined;
    const builder = {
      select: (c: string) => {
        if (!/^[a-z_, ]+$/.test(c)) throw new Error(`uuidAdmin: 모르는 열 ${c}`);
        columns = c;
        return builder;
      },
      eq: (column: string, value: string) => {
        if (column !== "user_id") throw new Error(`uuidAdmin: eq(${column})는 만들지 않았다`);
        owner = value;
        return builder;
      },
      in: (column: string, values: string[]) => {
        if (column !== "id") throw new Error(`uuidAdmin: in(${column})는 만들지 않았다`);
        ids = values;
        return builder;
      },
      throwOnError: () => builder,
      then: (resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) =>
        db
          .query(`select ${columns} from public.${table} where user_id = $1::uuid and id = any($2::uuid[])`, [owner, ids])
          .then((result) => ({ data: result.rows, error: null }))
          .then(resolve, reject),
    };
    return builder;
  };
  return { from } as unknown as SupabaseClient;
}
