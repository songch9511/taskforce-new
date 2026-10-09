import { randomUUID } from "node:crypto";

import { expect, it } from "vitest";

import { effectiveMemory } from "@/lib/context/retrieve";
import type { MemoryLike } from "@/lib/context/memory";

// 기억의 정정 · 잊기 이력 (20261103000000_context_core, 아키텍처 5.3): 정정된 옛 항목과 잊은 항목은 어떤 삭제 경로로도 "지금 쓰는 기억"으로 돌아오지 않는다.
// 같은 시나리오를 PGlite(tests/db/memory-history.test.ts)와 실제 Postgres(tests/pg/memory-history.test.ts)에서 돌린다.
//
// B1(20261104000000_context_layer)이 바꾼 것 — 이 파일은 A2의 회귀 시나리오이고 B1 PR이 의도적으로 고쳤다:
// 정정(superseded_by)은 같은 범위 · 같은 사실(kind + 비어 있지 않은 subject) 안에서만 된다 (사용자 결정 2026-10-10).
// 그래서 A2의 (3) "다른 범위의 새 항목이 옛 전체 항목을 정정" 시나리오는 이제 DB가 거절한다. (3)은 "범위 예외와 전체 기본값이 둘 다 지금 것이고,
// 읽을 때 그 범위 안에서만 예외가 이긴다. 범위를 지우면 예외만 사라지고 전체 기본값은 처음부터 정정되지 않았으므로 그대로 지금 것이다"로 바꿨다.
// (1) · (2) · (4) · (5)와 삭제 안전성 확인은 그대로다: 사슬의 행들이 같은 사실(SUBJECT)을 갖게만 했다.

export type Rows = Record<string, unknown>[];

export type MemoryHistoryDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

/** 지금 쓰는 기억: 앱이 RLS로 읽는 조건 (`isCurrentMemoryItem`, 인덱스 memory_items_user_current_idx와 같다) */
const CURRENT = `select id from public.memory_items where superseded_at is null and revoked_at is null`;

type Scope = "context" | "action" | "counterpart";

/** 시나리오의 "같은 사실": 배포 요일 */
const SUBJECT = "deploy day";

export function memoryHistoryTests(db: () => MemoryHistoryDb) {
  async function user(): Promise<string> {
    const id = randomUUID();
    await db().query(`insert into auth.users (id) values ($1)`, [id]);
    return id;
  }

  /** 범위 부모 하나 (범위 · 할 일 · 사람) */
  async function parent(userId: string, scope: Scope): Promise<string> {
    const sql = {
      context: `insert into public.work_contexts (user_id, name, kind) values ($1, 'Shape 출시 준비', 'project') returning id`,
      action: `insert into public.actions (user_id, title) values ($1, 'Shape 디자인') returning id`,
      counterpart: `insert into public.people (user_id, display_name, origin) values ($1, '지훈', 'user') returning id`,
    }[scope];
    return (await db().query(sql, [userId]))[0].id as string;
  }

  /**
   * 기억 하나. `supersedes`를 주면 서버의 정정처럼 새 행을 넣고 옛 행의 superseded_by만 쓴다 (superseded_at은 트리거가 남긴다).
   * 기본 subject는 SUBJECT(같은 사실): 정정 사슬은 같은 범위 · 같은 사실이어야 한다. subject: null이면 주제 없는 항목
   */
  async function remember(
    userId: string,
    statement: string,
    options: { supersedes?: string; scope?: { kind: Scope; id: string }; subject?: string | null } = {},
  ): Promise<string> {
    const scope = options.scope;
    const rows = await db().query(
      `insert into public.memory_items (user_id, kind, scope_kind, context_id, action_id, person_id, subject, statement, origin)
       values ($1, 'fact', $2, $3, $4, $5, $6, $7, 'explicit') returning id`,
      [
        userId,
        scope?.kind ?? "global",
        scope?.kind === "context" ? scope.id : null,
        scope?.kind === "action" ? scope.id : null,
        scope?.kind === "counterpart" ? scope.id : null,
        options.subject === undefined ? SUBJECT : options.subject,
        statement,
      ],
    );
    const id = rows[0].id as string;
    if (options.supersedes) {
      await db().query(`update public.memory_items set superseded_by = $1 where id = $2`, [id, options.supersedes]);
    }
    return id;
  }

  async function current(userId: string): Promise<string[]> {
    const rows = await db().asUser(userId, () => db().query(CURRENT));
    return rows.map((row) => row.id as string).sort();
  }

  async function row(id: string) {
    const rows = await db().query(`select superseded_by, superseded_at, revoked_at from public.memory_items where id = $1`, [id]);
    return rows[0] as { superseded_by: string | null; superseded_at: Date | null; revoked_at: Date | null } | undefined;
  }

  const sorted = (...ids: string[]) => [...ids].sort();

  it("이력 보호 트리거 함수는 앱 · 익명 역할이 부를 수 없다", async () => {
    const rows = await db().query(
      `select has_function_privilege('anon', 'public.memory_items_keep_history()', 'execute') as anon,
              has_function_privilege('authenticated', 'public.memory_items_keep_history()', 'execute') as authenticated`,
    );
    expect(rows[0]).toEqual({ anon: false, authenticated: false });
  });

  it("지금 쓰는 기억의 인덱스는 superseded_at · revoked_at으로 고른다 (포인터 superseded_by가 아니다)", async () => {
    const rows = await db().query(
      `select pg_get_expr(i.indpred, i.indrelid) as predicate from pg_index i where i.indexrelid = 'public.memory_items_user_current_idx'::regclass`,
    );
    const predicate = String(rows[0].predicate);
    expect(predicate).toMatch(/superseded_at IS NULL/);
    expect(predicate).toMatch(/revoked_at IS NULL/);
    expect(predicate).not.toMatch(/superseded_by/);
  });

  it("(1) X → Y로 정정한 뒤 Y를 지워도 X는 지금 쓰는 기억으로 돌아오지 않는다", async () => {
    const me = await user();
    const x = await remember(me, "이전엔 X");
    const y = await remember(me, "지금은 Y", { supersedes: x });
    const corrected = await row(x);
    expect(corrected?.superseded_by).toBe(y);
    expect(corrected?.superseded_at).toBeInstanceOf(Date);
    expect(await current(me)).toEqual([y]);

    await db().query(`delete from public.memory_items where id = $1`, [y]);
    const after = await row(x);
    expect(after?.superseded_by).toBeNull();
    expect(after?.superseded_at).toEqual(corrected?.superseded_at);
    expect(await current(me)).toEqual([]);
  });

  it("(2) X → Y → Z 사슬: 가운데를 지워도, 끝을 지워도 옛 항목은 돌아오지 않는다", async () => {
    const me = await user();
    const x = await remember(me, "X");
    const y = await remember(me, "Y", { supersedes: x });
    const z = await remember(me, "Z", { supersedes: y });
    expect(await current(me)).toEqual([z]);

    // 가운데(Y) 삭제: X의 포인터만 빈다. Z는 그대로 지금 것
    await db().query(`delete from public.memory_items where id = $1`, [y]);
    expect((await row(x))?.superseded_by).toBeNull();
    expect((await row(x))?.superseded_at).toBeInstanceOf(Date);
    expect(await current(me)).toEqual([z]);
    // 끝(Z) 삭제: 지금 쓰는 기억이 없다 (X가 살아나지 않는다)
    await db().query(`delete from public.memory_items where id = $1`, [z]);
    expect(await current(me)).toEqual([]);

    // 끝부터 지우는 사슬: Z를 지우면 Y는 정정된 채, Y를 지워도 X는 정정된 채
    const x2 = await remember(me, "X2");
    const y2 = await remember(me, "Y2", { supersedes: x2 });
    const z2 = await remember(me, "Z2", { supersedes: y2 });
    await db().query(`delete from public.memory_items where id = $1`, [z2]);
    expect((await row(y2))?.superseded_at).toBeInstanceOf(Date);
    expect(await current(me)).toEqual([]);
    await db().query(`delete from public.memory_items where id = $1`, [y2]);
    expect((await row(x2))?.superseded_at).toBeInstanceOf(Date);
    expect(await current(me)).toEqual([]);
  });

  /** 앱이 RLS로 읽은 지금 기억 행 (읽을 때의 해석 effectiveMemory에 넘긴다) */
  async function currentRows(userId: string): Promise<MemoryLike[]> {
    return (await db().asUser(userId, () =>
      db().query(
        `select id, kind, scope_kind, context_id, action_id, person_id, agent_adapter, subject, statement, origin, source_ref,
                observed_at, valid_from, valid_until, superseded_at, revoked_at, source_purged
           from public.memory_items where superseded_at is null and revoked_at is null`,
      ),
    )) as MemoryLike[];
  }

  const targetOf = (scope: Scope, id: string) =>
    ({ context: { contextId: id }, action: { actionIds: [id] }, counterpart: { personIds: [id] } })[scope];

  it.each([
    ["context", "work_contexts"],
    ["action", "actions"],
    ["counterpart", "people"],
  ] as const)(
    "(3) %s 범위의 예외와 전체 기본값은 둘 다 지금 것이다: 읽을 때 그 범위 안에서만 예외가 이기고, 범위를 지우면(cascade) 예외만 사라지고 기본값은 그대로다",
    async (scope, table) => {
      const me = await user();
      const target = await parent(me, scope);
      const elsewhere = await parent(me, scope);
      const fallback = await remember(me, "모든 일에서: 금요일 배포");
      const override = await remember(me, "이 범위에서: 목요일 배포", { scope: { kind: scope, id: target } });
      // 다른 범위의 새 항목으로는 정정하지 못한다 (B1: 범위가 다르면 다른 사실). 둘 다 지금 것으로 남는다
      await expect(db().query(`update public.memory_items set superseded_by = $1 where id = $2`, [override, fallback])).rejects.toThrow(
        /superseded_by must be the same fact/,
      );
      expect((await row(fallback))?.superseded_at).toBeNull();
      const keep = await remember(me, "관계없는 사실", { subject: null });
      expect(await current(me)).toEqual(sorted(fallback, override, keep));

      const now = new Date();
      const inside = effectiveMemory(await currentRows(me), targetOf(scope, target), { now }).map((m) => m.id);
      const outside = effectiveMemory(await currentRows(me), targetOf(scope, elsewhere), { now }).map((m) => m.id);
      const global = effectiveMemory(await currentRows(me), {}, { now }).map((m) => m.id);
      expect(inside).toEqual([override, keep]);
      expect(outside.sort()).toEqual(sorted(fallback, keep));
      expect(global.sort()).toEqual(sorted(fallback, keep));

      await db().query(`delete from public.${table} where id = $1`, [target]);
      expect(await row(override)).toBeUndefined();
      const after = await row(fallback);
      expect(after?.superseded_by).toBeNull();
      expect(after?.superseded_at).toBeNull(); // 처음부터 정정되지 않았다 (무효가 된 적이 없다)
      expect(await current(me)).toEqual(sorted(fallback, keep));
      expect(effectiveMemory(await currentRows(me), targetOf(scope, elsewhere), { now }).map((m) => m.id).sort()).toEqual(sorted(fallback, keep));
    },
  );

  it("(3) 범위가 다르면 어느 쪽으로도 정정하지 못한다: 전체 → 범위, 범위 → 전체, 범위 → 다른 범위", async () => {
    const me = await user();
    const a = await parent(me, "context");
    const b = await parent(me, "context");
    const global = await remember(me, "모든 일에서: 금요일");
    const inA = await remember(me, "A에서: 목요일", { scope: { kind: "context", id: a } });
    const inB = await remember(me, "B에서: 수요일", { scope: { kind: "context", id: b } });
    const update = (older: string, newer: string) => db().query(`update public.memory_items set superseded_by = $1 where id = $2`, [newer, older]);
    await expect(update(global, inA)).rejects.toThrow(/superseded_by must be the same fact/);
    await expect(update(inA, global)).rejects.toThrow(/superseded_by must be the same fact/);
    await expect(update(inA, inB)).rejects.toThrow(/superseded_by must be the same fact/);
    expect(await current(me)).toEqual(sorted(global, inA, inB));
    // 범위 안의 행을 지워도 다른 범위 · 전체는 그대로다
    await db().query(`delete from public.work_contexts where id = $1`, [a]);
    expect(await current(me)).toEqual(sorted(global, inB));
  });

  it("(3) kind만 같으면 덮지 못한다: 주제가 다르거나 없는 항목은 정정하지 못하고, 주제가 같아도 kind가 다르면 못한다", async () => {
    const me = await user();
    const deploy = await remember(me, "금요일 배포");
    const other = await remember(me, "회의는 화요일", { subject: "meeting day" });
    const loose = await remember(me, "주제 없는 사실", { subject: null });
    const update = (older: string, newer: string) => db().query(`update public.memory_items set superseded_by = $1 where id = $2`, [newer, older]);
    await expect(update(deploy, other)).rejects.toThrow(/superseded_by must be the same fact/);
    await expect(update(deploy, loose)).rejects.toThrow(/superseded_by must be the same fact/);
    await expect(update(loose, deploy)).rejects.toThrow(/superseded_by must be the same fact/);
    const rule = (await db().query(
      `insert into public.memory_items (user_id, kind, scope_kind, subject, statement, origin) values ($1, 'working_rule', 'global', $2, '배포 전 확인', 'explicit') returning id`,
      [me, SUBJECT],
    ))[0].id as string;
    await expect(update(deploy, rule)).rejects.toThrow(/superseded_by must be the same fact/);
    expect(await current(me)).toEqual(sorted(deploy, other, loose, rule));
    // 행의 정체(범위 · kind · 주제)는 고치지 못한다: 고쳐서 정정 규칙을 우회할 수 없다
    await expect(db().query(`update public.memory_items set subject = 'meeting day' where id = $1`, [deploy])).rejects.toThrow(/kind, scope and subject are fixed/);
    await expect(db().query(`update public.memory_items set kind = 'goal' where id = $1`, [deploy])).rejects.toThrow(/kind, scope and subject are fixed/);
  });

  it("(4) 잊은 항목은 잊은 채로 남는다: 되돌리기 · 바꾸기는 막히고, 관련 항목이 지워져도 그대로다", async () => {
    const me = await user();
    const forgotten = await remember(me, "잊은 것");
    await db().query(`update public.memory_items set revoked_at = now() where id = $1`, [forgotten]);
    const revokedAt = (await row(forgotten))?.revoked_at;
    expect(revokedAt).toBeInstanceOf(Date);
    expect(await current(me)).toEqual([]);

    await expect(db().query(`update public.memory_items set revoked_at = null where id = $1`, [forgotten])).rejects.toThrow(/revoked_at is permanent/);
    await expect(db().query(`update public.memory_items set revoked_at = now() + interval '1 day' where id = $1`, [forgotten])).rejects.toThrow(
      /revoked_at is permanent/,
    );

    // 잊은 항목을 정정한 새 항목이 지워져도 잊은 채
    const newer = await remember(me, "새 것", { supersedes: forgotten });
    await db().query(`delete from public.memory_items where id = $1`, [newer]);
    const after = await row(forgotten);
    expect(after?.revoked_at).toEqual(revokedAt);
    expect(after?.superseded_at).toBeInstanceOf(Date);
    expect(await current(me)).toEqual([]);
  });

  it("정정 표시는 지우거나 바꿀 수 없다 (서버도). 포인터만 새 항목이 지워질 때 빈다", async () => {
    const me = await user();
    const x = await remember(me, "X");
    await remember(me, "Y", { supersedes: x });
    await expect(db().query(`update public.memory_items set superseded_at = null, superseded_by = null where id = $1`, [x])).rejects.toThrow(
      /superseded_at is permanent/,
    );
    await expect(db().query(`update public.memory_items set superseded_at = now() - interval '1 day' where id = $1`, [x])).rejects.toThrow(
      /superseded_at is permanent/,
    );
    // 처음부터 정정된 채로 넣는 행(이력 가져오기)도 시각이 남는다 (같은 범위 · 같은 사실)
    const y = await remember(me, "Y2");
    const imported = await db().query(
      `insert into public.memory_items (user_id, kind, scope_kind, subject, statement, origin, superseded_by) values ($1, 'fact', 'global', $3, '옛 기록', 'explicit', $2) returning superseded_at`,
      [me, y, SUBJECT],
    );
    expect(imported[0].superseded_at).toBeInstanceOf(Date);
  });

  it("(5) 계정을 지우면 그 사용자의 기억 사슬 · 범위 기억이 모두 지워지고, 다른 사용자의 행 · 지금 쓰는 기억은 그대로다", async () => {
    const leaving = await user();
    const staying = await user();
    for (const owner of [leaving, staying]) {
      const context = await parent(owner, "context");
      // 전체 사슬 X → Y → Z와 범위 안 사슬 CX → CY (B1: 사슬은 같은 범위 · 같은 사실 안에서만)
      const x = await remember(owner, "X");
      const y = await remember(owner, "Y", { supersedes: x });
      await remember(owner, "Z", { supersedes: y });
      const cx = await remember(owner, "CX", { scope: { kind: "context", id: context } });
      await remember(owner, "CY", { supersedes: cx, scope: { kind: "context", id: context } });
      const forgotten = await remember(owner, "잊은 것", { subject: null });
      await db().query(`update public.memory_items set revoked_at = now() where id = $1`, [forgotten]);
    }
    const stayingRows = await db().query(`select id, superseded_by, superseded_at, revoked_at from public.memory_items where user_id = $1 order by id`, [staying]);
    const stayingCurrent = await current(staying);
    expect(stayingCurrent).toHaveLength(2);
    // 다른 사용자의 기억은 RLS로 보이지 않는다
    expect(await db().asUser(staying, () => db().query(`select id from public.memory_items where user_id = $1`, [leaving]))).toEqual([]);

    await db().query(`delete from auth.users where id = $1`, [leaving]);
    expect(await db().query(`select id from public.memory_items where user_id = $1`, [leaving])).toEqual([]);
    expect(await db().query(`select id from public.work_contexts where user_id = $1`, [leaving])).toEqual([]);
    expect(await db().query(`select id, superseded_by, superseded_at, revoked_at from public.memory_items where user_id = $1 order by id`, [staying])).toEqual(stayingRows);
    expect(await current(staying)).toEqual(stayingCurrent);
  });
}
