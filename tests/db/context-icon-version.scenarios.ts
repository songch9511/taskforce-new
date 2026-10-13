import { randomUUID } from "node:crypto";

import { describe, expect, it } from "vitest";
import { PROJECT_ICON_POOL } from "@/lib/api/contract";

const ICONS: readonly string[] = PROJECT_ICON_POOL;

export type ContextIconVersionDb = {
  query: (sql: string, params?: unknown[]) => Promise<Record<string, unknown>[]>;
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

export function contextIconVersionTests(db: () => ContextIconVersionDb) {
  const one = async (sql: string, params: unknown[] = []) => (await db().query(sql, params))[0];
  const user = async () => {
    const id = randomUUID();
    await db().query("insert into auth.users (id, email) values ($1, $2)", [id, `${id}@example.com`]);
    return id;
  };

  describe("프로젝트 아이콘 · optimistic version (D4c-1s)", () => {
    it("새 열 기본값과 제약, 기존 행 backfill 값이 enum 안이고 결정적이다", async () => {
      const userId = await user();
      const first = await one(`insert into public.work_contexts (user_id, name, kind) values ($1, 'Backfill A', 'project') returning id, icon, version`, [userId]);
      expect(first).toMatchObject({ icon: "compass", version: 1 });
      const rows = await db().query(`select icon from public.work_contexts where user_id = $1 order by id`, [userId]);
      expect(rows.every((row) => ICONS.includes(String(row.icon)))).toBe(true);
      await expect(db().query(`update public.work_contexts set icon = 'star' where id = $1`, [first.id])).rejects.toThrow(/check constraint/);
      await expect(db().query(`update public.work_contexts set version = 0 where id = $1`, [first.id])).rejects.toThrow(/check constraint/);
    });

    it("생성 함수는 요청 아이콘 또는 랜덤 풀 아이콘을 저장하고 project_created를 남긴다", async () => {
      const userId = await user();
      for (const icon of ICONS) {
        const created = await one(`select public.create_work_context($1, $2, 'project', $3) as result`, [userId, icon, icon]);
        expect(created.result).toMatchObject({ user_id: userId, name: icon, icon, version: 1 });
      }
      const random = await db().query(`select public.create_work_context($1, 'Random ' || n, 'project', null)->>'icon' as icon from generate_series(1, 400) n`, [userId]);
      expect(new Set(random.map((row) => row.icon))).toEqual(new Set(ICONS));
      expect(random.filter((row) => !ICONS.includes(String(row.icon)))).toHaveLength(0);
      expect(await one(`select count(*)::int as n from public.metric_events where user_id = $1 and type = 'project_created'`, [userId])).toEqual({ n: 412 });
    });

    it("조건부 수정은 이벤트별 정확한 개수, stale · no-op · not_found는 쓰지 않는다", async () => {
      const userId = await user();
      const context = await one(`select public.create_work_context($1, 'Before', 'project', 'compass') as result`, [userId]);
      const id = String((context.result as { id: string }).id);
      const changed = await one(`select public.update_work_context($1, $2, 1, 'After', 'rocket', null) as result`, [userId, id]);
      expect(changed.result).toMatchObject({ status: "ok", context: { name: "After", icon: "rocket", version: 2 } });
      expect(await one(`select count(*)::int as n from public.metric_events where user_id = $1 and type = 'project_renamed'`, [userId])).toEqual({ n: 1 });
      expect(await one(`select count(*)::int as n from public.metric_events where user_id = $1 and type = 'project_icon_changed'`, [userId])).toEqual({ n: 1 });
      const eventCount = await one(`select count(*)::int as n from public.metric_events`);
      const before = await one(`select name, icon, status, version from public.work_contexts where id = $1`, [id]);
      const stale = await one(`select public.update_work_context($1, $2, 1, 'Stale', null, null) as result`, [userId, id]);
      expect(stale.result).toEqual({ status: "conflict", context: null });
      expect(await one(`select name, icon, status, version from public.work_contexts where id = $1`, [id])).toEqual(before);
      expect(await one(`select count(*)::int as n from public.metric_events`)).toEqual(eventCount);
      const unchanged = await one(`select public.update_work_context($1, $2, 2, 'After', 'rocket', 'active') as result`, [userId, id]);
      expect(unchanged.result).toMatchObject({ status: "unchanged", context: { version: 2 } });
      expect(await one(`select version from public.work_contexts where id = $1`, [id])).toEqual({ version: 2 });
      expect(await one(`select count(*)::int as n from public.metric_events`)).toEqual(eventCount);
      const nullVersion = await one(`select public.update_work_context($1, $2, null, 'Null', null, null) as result`, [userId, id]);
      expect(nullVersion.result).toEqual({ status: "conflict", context: null });
      expect(await one(`select name, icon, status, version from public.work_contexts where id = $1`, [id])).toEqual(before);
      expect(await one(`select count(*)::int as n from public.metric_events`)).toEqual(eventCount);
      const notFound = await one(`select public.update_work_context($1, $2, 2, 'Missing', null, null) as result`, [userId, "ffffffff-ffff-4fff-8fff-ffffffffffff"]);
      expect(notFound.result).toEqual({ status: "not_found", context: null });
      expect(await one(`select count(*)::int as n from public.metric_events`)).toEqual(eventCount);
    });

    it("보관은 범위 version을 기존 큐로 올리고 active 복귀 이벤트는 만들지 않는다", async () => {
      const userId = await user();
      const context = await one(`select public.create_work_context($1, 'Archive', 'project', 'compass') as result`, [userId]);
      const id = String((context.result as { id: string }).id);
      const archived = await one(`select public.update_work_context($1, $2, 1, null, null, 'archived') as result`, [userId, id]);
      expect(archived.result).toMatchObject({ status: "ok", context: { status: "archived", version: 2, context_version: 2 } });
      expect(await one(`select context_version from public.work_contexts where id = $1`, [id])).toEqual({ context_version: 2 });
      const eventCount = await one(`select count(*)::int as n from public.metric_events`);
      const archivedEdit = await one(`select public.update_work_context($1, $2, 2, 'Still archived', null, 'archived') as result`, [userId, id]);
      expect(archivedEdit.result).toMatchObject({ status: "ok", context: { status: "archived", version: 3, context_version: 2 } });
      expect(await one(`select count(*)::int as n from public.metric_events where user_id = $1 and type = 'project_archived'`, [userId])).toEqual({ n: 1 });
      expect(await one(`select count(*)::int as n from public.metric_events where user_id = $1 and type = 'project_renamed'`, [userId])).toEqual({ n: 1 });
      expect(await one(`select count(*)::int as n from public.metric_events`)).not.toEqual(eventCount);
      const contextVersion = await one(`select context_version from public.work_contexts where id = $1`, [id]);
      expect(contextVersion).toEqual({ context_version: 2 });
      const restored = await one(`select public.update_work_context($1, $2, 3, null, null, 'active') as result`, [userId, id]);
      expect(restored.result).toMatchObject({ status: "ok", context: { status: "active", version: 4, context_version: 2 } });
      expect(await one(`select context_version from public.work_contexts where id = $1`, [id])).toEqual(contextVersion);
      expect(await one(`select count(*)::int as n from public.metric_events where user_id = $1 and type = 'project_archived'`, [userId])).toEqual({ n: 1 });
    });

    it("authenticated는 서버 함수와 icon/version 쓰기에 접근하지 못하고, 공통 이벤트 정책만 허용한다", async () => {
      const userId = await user();
      const context = await one(`select public.create_work_context($1, 'Private', 'project', 'compass') as result`, [userId]);
      const id = String((context.result as { id: string }).id);
      const privileges = await db().query(`
        select p.proname, has_function_privilege('anon', p.oid, 'execute') as anon,
               has_function_privilege('authenticated', p.oid, 'execute') as authenticated,
               has_function_privilege('service_role', p.oid, 'execute') as service_role,
               p.prosecdef, p.proconfig
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname in ('create_work_context', 'update_work_context') order by p.proname`);
      expect(privileges).toHaveLength(2);
      for (const fn of privileges) expect(fn).toMatchObject({ anon: false, authenticated: false, service_role: true, prosecdef: true, proconfig: ["search_path=\"\""] });
      await db().asUser(userId, async () => {
        await expect(db().query(`update public.work_contexts set icon = 'rocket' where id = $1`, [id])).rejects.toThrow(/permission denied/);
        await expect(db().query(`update public.work_contexts set version = 2 where id = $1`, [id])).rejects.toThrow(/permission denied/);
        await expect(db().query(`insert into public.metric_events (type) values ('project_created')`)).rejects.toThrow(/row-level security|permission denied/);
        await db().query(`insert into public.metric_events (type) values ('app_opened')`);
        await db().query(`insert into public.metric_events (type) values ('assistant_opened')`);
        await expect(db().query(`insert into public.metric_events (type) values ('action_started')`)).rejects.toThrow(/row-level security|permission denied/);
      });
      await expect(db().query(`insert into public.metric_events (user_id, type) values ($1, 'unknown_event')`, [userId])).rejects.toThrow(/check constraint/);
      await expect(db().query(`insert into public.metric_events (user_id, type, props) values ($1, 'assistant_opened', '[]'::jsonb)`, [userId])).rejects.toThrow(/check constraint/);
    });

    it("다른 사용자 ID로는 존재 여부를 읽지 못한다", async () => {
      const owner = await user();
      const stranger = await user();
      const context = await one(`select public.create_work_context($1, 'Owner', 'project', null) as result`, [owner]);
      const id = (context.result as { id: string }).id;
      expect(await one(`select public.update_work_context($1, $2, 1, 'Hijack', null, null) as result`, [stranger, id])).toEqual({ result: { status: "not_found", context: null } });
      await db().asUser(stranger, async () => {
        expect(await db().query(`select id from public.work_contexts where id = $1`, [id])).toEqual([]);
      });
    });
  });
}
