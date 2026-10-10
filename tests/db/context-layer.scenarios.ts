import { randomUUID } from "node:crypto";

import { describe, expect, it } from "vitest";

import { buildContextBundle } from "@/lib/context/bundle";
import type { MemoryLike } from "@/lib/context/memory";
import type { SourceState } from "@/lib/context/retrieve";

// 0.2.0 맥락층 (20261104000000_context_layer, 구현 계획 B1): 정정 규칙 · 삭제 전파(아키텍처 6.5) · 사람 계정 · 신원 링크 · 조각 교체 · 범위 version.
// 같은 시나리오를 PGlite(tests/db/context-layer.test.ts)와 실제 Postgres(tests/pg/context-layer.test.ts)에서 돌린다. 동시성은 실제 Postgres 파일에만 있다.

export type Rows = Record<string, unknown>[];

export type ContextLayerDb = {
  /** 서버(service role)처럼 RLS 없이 */
  query: (sql: string, params?: unknown[]) => Promise<Rows>;
  /** 앱처럼 authenticated + 그 사용자의 JWT로 */
  asUser: <T>(userId: string, fn: () => Promise<T>) => Promise<T>;
};

/** 1536차원 임베딩 문자열 (hot 자리만 1) */
export const vector = (hot: number) => `[${Array.from({ length: 1536 }, (_, i) => (i === hot ? 1 : 0)).join(",")}]`;

/** 시나리오 · 동시성 테스트가 함께 쓰는 시드 함수 */
export function contextLayerFixtures(db: () => ContextLayerDb) {
  const one = async (sql: string, params: unknown[] = []) => (await db().query(sql, params))[0];
  const id = async (sql: string, params: unknown[] = []) => (await one(sql, params)).id as string;

  return {
    one,
    id,
    async user(): Promise<string> {
      const userId = randomUUID();
      await db().query(`insert into auth.users (id, email) values ($1, $2)`, [userId, `${userId}@example.com`]);
      return userId;
    },
    connection: (userId: string, provider: string, account: string = randomUUID()) =>
      id(`insert into public.connections (user_id, provider, external_account_id) values ($1, $2, $3) returning id`, [userId, provider, account]),
    source: (
      userId: string,
      options: { connectionId?: string | null; externalId?: string | null; version?: string | null; text?: string; occurredAt?: string; url?: string | null } = {},
    ) =>
      id(
        `insert into public.sources (user_id, kind, raw_text, occurred_at, connection_id, external_id, external_version, external_url)
         values ($1, 'doc', $2, $3, $4, $5, $6, $7) returning id`,
        [
          userId,
          options.text ?? "Shape 출시는 목요일. 디자인 확정 뒤 개발 시작.",
          options.occurredAt ?? "2026-10-01T00:00:00Z",
          options.connectionId ?? null,
          options.externalId ?? null,
          options.version ?? null,
          options.url ?? null,
        ],
      ),
    context: (userId: string, name = "Shape 출시 준비") =>
      id(`insert into public.work_contexts (user_id, name, kind) values ($1, $2, 'project') returning id`, [userId, name]),
    member: (userId: string, contextId: string, sourceId: string, origin = "auto") =>
      id(`insert into public.context_members (user_id, context_id, member_kind, source_id, origin, confidence) values ($1, $2, 'source', $3, $4, $5) returning id`, [
        userId,
        contextId,
        sourceId,
        origin,
        origin === "inferred" ? 0.6 : null,
      ]),
    version: async (contextId: string) => Number((await one(`select context_version from public.work_contexts where id = $1`, [contextId])).context_version),
    chunks: async (userId: string, sourceId: string, texts: string[], embeddings?: (string | null)[]) =>
      (await one(`select * from public.replace_source_chunks($1, $2, $3, $4)`, [userId, sourceId, texts, embeddings ?? texts.map((_, i) => vector(i))])) as {
        status: string;
        chunks: number;
      },
    chunkTexts: async (sourceId: string) =>
      (await db().query(`select text from public.source_chunks where source_id = $1 order by seq`, [sourceId])).map((r) => r.text as string),
    /** 기억 쓰기 (서버의 remember_memory_item) */
    remember: async (userId: string, item: Record<string, unknown>, corrects: string | null = null, expectedVersion: number | null = null) =>
      (await one(`select * from public.remember_memory_item($1, $2::jsonb, $3, $4)`, [userId, JSON.stringify(item), corrects, expectedVersion])) as {
        status: string;
        id: string | null;
        superseded: string[];
        superseded_by: string | null;
      },
    memory: async (memoryId: string) =>
      (await one(
        `select id, statement, value, origin, source_ref, source_purged, superseded_by, superseded_at, revoked_at, version, subject from public.memory_items where id = $1`,
        [memoryId],
      )) as
        | {
            id: string;
            statement: string;
            value: Record<string, unknown>;
            origin: string;
            source_ref: Record<string, unknown> | null;
            source_purged: boolean;
            superseded_by: string | null;
            superseded_at: Date | null;
            revoked_at: Date | null;
            version: number;
            subject: string | null;
          }
        | undefined,
    person: async (personId: string) =>
      (await one(`select display_name, emails, handles, origin from public.people where id = $1`, [personId])) as {
        display_name: string | null;
        emails: string[];
        handles: Record<string, string>;
        origin: string;
      },
  };
}

export function contextLayerTests(db: () => ContextLayerDb) {
  const f = contextLayerFixtures(db);

  /** 범위 기억 (observed · explicit · inferred)을 원문 하나에 붙여 넣는다 */
  async function sourceMemories(userId: string, sourceId: string, contextId: string) {
    const ref = (quote?: string) => ({ source_id: sourceId, ...(quote ? { quote } : {}) });
    const observed = await f.remember(userId, {
      kind: "fact", scope_kind: "context", context_id: contextId, subject: "launch day", statement: "출시는 목요일", origin: "observed",
      value: { day: "thu" }, source_ref: ref("Shape 출시는 목요일"),
    });
    const explicit = await f.remember(userId, {
      kind: "condition", scope_kind: "context", context_id: contextId, subject: "start", statement: "디자인 확정 뒤 개발 시작", origin: "explicit",
      value: { start_after: "design" }, source_ref: ref("디자인 확정 뒤 개발 시작"),
    });
    const inferred = await f.remember(userId, {
      kind: "goal", scope_kind: "context", context_id: contextId, subject: "launch", statement: "이번 주 출시가 목표인 듯", origin: "inferred",
      confidence: 0.6, source_ref: ref(),
    });
    return { observed: observed.id!, explicit: explicit.id!, inferred: inferred.id! };
  }

  describe("정정 규칙 (remember_memory_item): 같은 범위 · 같은 사실 안에서만", () => {
    const fact = (statement: string, extra: Record<string, unknown> = {}) => ({
      kind: "fact", scope_kind: "global", subject: "deploy day", statement, origin: "explicit", ...extra,
    });

    it("같은 범위에서 같은 사실을 다시 말하면(explicit) 옛 행은 정정된 이력이 된다 (version + 1)", async () => {
      const me = await f.user();
      const first = await f.remember(me, fact("금요일 배포"));
      expect(first).toMatchObject({ status: "written", superseded: [], superseded_by: null });
      const second = await f.remember(me, fact("목요일 배포"));
      expect(second.superseded).toEqual([first.id]);
      const old = await f.memory(first.id!);
      expect(old).toMatchObject({ superseded_by: second.id, version: 2 });
      expect(old?.superseded_at).toBeInstanceOf(Date);
    });

    it("프로젝트의 예외는 전체 기본값을 정정하지 않고, 다른 프로젝트의 같은 사실도 건드리지 않는다", async () => {
      const me = await f.user();
      const [a, b] = [await f.context(me, "A"), await f.context(me, "B")];
      const global = await f.remember(me, fact("금요일 배포"));
      const inA = await f.remember(me, fact("A는 목요일", { scope_kind: "context", context_id: a }));
      const inB = await f.remember(me, fact("B는 수요일", { scope_kind: "context", context_id: b }));
      expect(inA.superseded).toEqual([]);
      expect(inB.superseded).toEqual([]);
      for (const memoryId of [global.id!, inA.id!, inB.id!]) expect((await f.memory(memoryId))?.superseded_at).toBeNull();
      // A 안에서 다시 말하면 A의 예외만 정정된다
      const inA2 = await f.remember(me, fact("A는 화요일", { scope_kind: "context", context_id: a }));
      expect(inA2.superseded).toEqual([inA.id]);
      expect((await f.memory(global.id!))?.superseded_at).toBeNull();
      expect((await f.memory(inB.id!))?.superseded_at).toBeNull();
    });

    it("kind만 같거나 주제가 없으면 덮지 않는다", async () => {
      const me = await f.user();
      const deploy = await f.remember(me, fact("금요일 배포"));
      const meeting = await f.remember(me, fact("화요일 회의", { subject: "meeting day" }));
      const loose1 = await f.remember(me, fact("주제 없는 사실 1", { subject: null }));
      const loose2 = await f.remember(me, fact("주제 없는 사실 2", { subject: null }));
      const rule = await f.remember(me, fact("배포 전 확인", { kind: "working_rule" }));
      for (const written of [meeting, loose1, loose2, rule]) expect(written.superseded).toEqual([]);
      for (const memoryId of [deploy.id!, meeting.id!, loose1.id!, loose2.id!, rule.id!]) expect((await f.memory(memoryId))?.superseded_at).toBeNull();
    });

    it("observed는 explicit을 이기지 못하고(처음부터 정정된 이력으로), observed끼리는 늦게 읽은 쪽이 이긴다. inferred는 덮지도 덮이지도 않는다", async () => {
      const me = await f.user();
      const source = await f.source(me);
      const observed = (statement: string, at: string) =>
        f.remember(me, fact(statement, { origin: "observed", source_ref: { source_id: source, quote: "Shape 출시는 목요일" }, observed_at: at }));
      const o1 = await observed("자료: 금요일", "2026-10-01T00:00:00Z");
      const older = await observed("더 옛 자료: 수요일", "2026-09-01T00:00:00Z");
      expect(older).toMatchObject({ superseded: [], superseded_by: o1.id });
      const o2 = await observed("새 자료: 목요일", "2026-10-02T00:00:00Z");
      expect(o2.superseded).toEqual([o1.id]);
      const guess = await f.remember(me, fact("아마 화요일", { origin: "inferred", confidence: 0.4 }));
      expect(guess).toMatchObject({ superseded: [], superseded_by: null });
      const said = await f.remember(me, fact("내가 정함: 월요일"));
      expect(new Set(said.superseded)).toEqual(new Set([o2.id, guess.id])); // 사용자의 말은 후보까지 정리한다
      const late = await observed("나중 자료: 일요일", "2026-10-09T00:00:00Z");
      expect(late).toMatchObject({ superseded: [], superseded_by: said.id });
      const current = await db().query(`select id from public.memory_items where user_id = $1 and superseded_at is null and revoked_at is null`, [me]);
      expect(current.map((r) => r.id)).toEqual([said.id]);
    });

    it("가리킨 항목의 정정(p_corrects): 범위 · kind · 주제를 물려받고, 주제 없는 항목은 그 항목이 사실의 열쇠가 된다. version이 다르면 conflict", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const loose = await f.remember(me, fact("디자인 확정 뒤 시작", { subject: null, kind: "condition", scope_kind: "context", context_id: context }));
      // 정정은 사용자가 말한 것만: 추정 · 관찰은 가리킨 항목을 정정하지 못한다
      await expect(f.remember(me, fact("추정", { origin: "inferred", confidence: 0.5 }), loose.id, 1)).rejects.toThrow(/correction must be explicit/);
      const conflict = await f.remember(me, fact("정정", { scope_kind: "global" }), loose.id, 9);
      expect(conflict).toMatchObject({ status: "conflict", id: null });
      const corrected = await f.remember(me, fact("QA 통과 뒤 시작", { scope_kind: "global", subject: "ignored" }), loose.id, 1);
      expect(corrected).toMatchObject({ status: "written", superseded: [loose.id] });
      const [oldRow, newRow] = [await f.memory(loose.id!), await f.memory(corrected.id!)];
      expect(oldRow?.subject).toBe(`memory:${loose.id}`);
      expect(newRow?.subject).toBe(`memory:${loose.id}`);
      expect(await f.one(`select kind, scope_kind, context_id from public.memory_items where id = $1`, [corrected.id])).toEqual({
        kind: "condition",
        scope_kind: "context",
        context_id: context,
      });
      // 이미 정정된 항목 · 잊은 항목은 다시 정정하지 못한다 (다시 보낸 요청은 conflict)
      expect((await f.remember(me, fact("또"), loose.id, 2)).status).toBe("conflict");
      await db().query(`update public.memory_items set revoked_at = now() where id = $1`, [corrected.id]);
      expect((await f.remember(me, fact("또"), corrected.id, 1)).status).toBe("conflict");
      await expect(f.remember(me, fact("없음"), randomUUID(), 1)).rejects.toThrow(/memory not found/);

      // 글이 지워진 observed 항목(주제가 비었다)을 사용자가 정정하면 그 항목이 정정된 이력이 된다
      const source = await f.source(me);
      const seen = await f.remember(me, fact("자료: 수요일", { origin: "observed", source_ref: { source_id: source, quote: "수요일" } }));
      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now() where id = $1`, [source]);
      expect(await f.memory(seen.id!)).toMatchObject({ statement: "", subject: null, source_purged: true });
      const fixed = await f.remember(me, fact("내가 정함: 목요일"), seen.id, 2);
      expect(fixed).toMatchObject({ status: "written", superseded: [seen.id] });
      expect(await f.memory(seen.id!)).toMatchObject({ subject: `memory:${seen.id}`, superseded_by: fixed.id });
    });
  });

  describe("출처 · 후보 · 예약 주제", () => {
    it("출처 원문은 그 사용자의 것이어야 한다 (없거나 남의 원문이면 거절). 이미 가리키던 원문이 지워진 행은 그대로 고칠 수 있다", async () => {
      const [me, other] = [await f.user(), await f.user()];
      const theirs = await f.source(other);
      const missing = randomUUID();
      const observed = (sourceId: string) => ({ kind: "fact", scope_kind: "global", statement: "자료", origin: "observed", source_ref: { source_id: sourceId } });
      await expect(f.remember(me, observed(theirs))).rejects.toThrow(/source not found for this user/);
      await expect(f.remember(me, observed(missing))).rejects.toThrow(/source not found for this user/);
      await expect(
        db().query(`insert into public.memory_items (user_id, kind, scope_kind, statement, origin, source_ref) values ($1, 'fact', 'global', '직접', 'observed', $2)`, [
          me,
          JSON.stringify({ source_id: theirs }),
        ]),
      ).rejects.toThrow(/source not found for this user/);
      const mine = await f.source(me);
      const said = await f.remember(me, { kind: "fact", scope_kind: "global", statement: "내 기억", origin: "explicit", source_ref: { source_id: mine, quote: "인용" } });
      await db().query(`delete from public.sources where id = $1`, [mine]);
      await db().query(`update public.memory_items set revoked_at = now() where id = $1`, [said.id]);
      expect((await f.memory(said.id!))?.source_ref).toEqual({ source_id: mine });
    });

    it("추정(inferred) 후보는 explicit · observed 항목을 정정하지 못한다", async () => {
      const me = await f.user();
      const said = await f.remember(me, { kind: "fact", scope_kind: "global", subject: "deploy day", statement: "금요일", origin: "explicit" });
      const guess = await f.remember(me, { kind: "fact", scope_kind: "global", subject: "deploy day", statement: "아마 목요일", origin: "inferred", confidence: 0.4 });
      await expect(db().query(`update public.memory_items set superseded_by = $1 where id = $2`, [guess.id, said.id])).rejects.toThrow(
        /inferred item cannot supersede/,
      );
      expect((await f.memory(said.id!))?.superseded_at).toBeNull();
    });

    it("'memory:'로 시작하는 주제는 정정만 만든다 (새 기억은 쓸 수 없다)", async () => {
      const me = await f.user();
      await expect(
        f.remember(me, { kind: "fact", scope_kind: "global", subject: `memory:${randomUUID()}`, statement: "끼어들기", origin: "explicit" }),
      ).rejects.toThrow(/reserved/);
    });
  });

  describe("삭제 전파 (아키텍처 6.5): 사건마다 따로", () => {
    it("(a) 보관 기간: 조각 지움 · observed 글 · 인용 · 값 비움 · inferred 지움 · explicit 그대로(인용 포함). 사람 · 신원은 그대로. 다시 돌려도 같다", async () => {
      const me = await f.user();
      const notion = await f.connection(me, "notion");
      const source = await f.source(me, { connectionId: notion, externalId: "page-1", version: "v1" });
      const context = await f.context(me);
      await f.member(me, context, source);
      expect(await f.chunks(me, source, ["Shape 출시는 목요일", "디자인 확정 뒤 개발 시작"])).toEqual({ status: "replaced", chunks: 2 });
      const m = await sourceMemories(me, source, context);
      const person = await db().query(`select public.observe_person_handle($1, 'notion', 'u-jihoon', '지훈', null, $2) as id`, [me, notion]);
      const before = await f.version(context);

      await db().query(`update public.sources set created_at = now() - interval '100 days' where id = $1`, [source]);
      await db().query(`select * from public.purge_expired_source_text(now() - interval '90 days')`);

      expect(await f.chunkTexts(source)).toEqual([]);
      // 주제도 원문에서 온 글자라 비운다 (비운 행은 같은 사실의 비교에 끼지 않는다)
      expect(await f.memory(m.observed)).toMatchObject({ statement: "", source_purged: true, value: {}, subject: null, version: 2 });
      expect((await f.memory(m.observed))?.source_ref).toEqual({ source_id: source }); // 인용까지 정확히 빠졌다 (부분 일치가 아니라)
      expect(await f.memory(m.inferred)).toBeUndefined();
      expect(await f.memory(m.explicit)).toMatchObject({
        statement: "디자인 확정 뒤 개발 시작",
        value: { start_after: "design" },
        source_ref: { source_id: source, quote: "디자인 확정 뒤 개발 시작" },
        source_purged: false,
      });
      expect(await f.person(person[0].id as string)).toMatchObject({ display_name: "지훈", handles: { notion: "u-jihoon" } });
      expect(await f.version(context)).toBeGreaterThan(before);

      // 지운 원문에는 조각 · observed 글 · inferred를 새로 넣지 못한다 (늦게 끝난 처리)
      await expect(db().query(`insert into public.source_chunks (user_id, source_id, seq, text) values ($1, $2, 0, '늦은 조각')`, [me, source])).rejects.toThrow(
        /source text was purged/,
      );
      expect(await f.chunks(me, source, ["늦은 조각"])).toEqual({ status: "purged", chunks: 0 });
      await expect(
        f.remember(me, { kind: "fact", scope_kind: "global", statement: "늦은 관찰", origin: "observed", source_ref: { source_id: source } }),
      ).rejects.toThrow(/source text was purged/);
      await expect(
        f.remember(me, { kind: "fact", scope_kind: "global", statement: "늦은 추정", origin: "inferred", confidence: 0.5, source_ref: { source_id: source } }),
      ).rejects.toThrow(/source text was purged/);
      // 비운 모양이어도 주제(원문에서 온 글자)를 담으면 넣지 못한다
      await expect(
        db().query(
          `insert into public.memory_items (user_id, kind, scope_kind, subject, statement, origin, source_ref, source_purged) values ($1, 'fact', 'global', 'launch day', '', 'observed', $2, true)`,
          [me, JSON.stringify({ source_id: source })],
        ),
      ).rejects.toThrow(/source text was purged/);
      // 비운 행은 같은 사실의 비교에 끼지 않는다: 같은 주제의 새 관찰은 (더 옛날 것이어도) 지금 행이 된다
      const fresh = await f.remember(me, {
        kind: "fact", scope_kind: "context", context_id: context, subject: "launch day", statement: "다른 자료: 금요일", origin: "observed",
        source_ref: { source_id: await f.source(me) }, observed_at: "2026-09-01T00:00:00Z",
      });
      expect(fresh).toMatchObject({ status: "written", superseded: [], superseded_by: null });
      // 사용자가 저장하는 기억은 원문이 지워져도 쓸 수 있다 (보관 기간이면 인용도)
      expect((await f.remember(me, { kind: "fact", scope_kind: "global", statement: "내가 기억할 것", origin: "explicit", source_ref: { source_id: source, quote: "출시" } })).status).toBe(
        "written",
      );

      // 다시 돌려도 같다 (이미 비운 행 · 지운 조각)
      const again = await f.memory(m.observed);
      await db().query(`select * from public.purge_expired_source_text(now() - interval '90 days')`);
      expect(await f.memory(m.observed)).toEqual(again);
    });

    it("(b) Slack 끊기: 원문 · 조각 · 기억 글 + explicit 인용 + 그 연결의 신원 링크 · Slack 계정(출처 이름 · 이메일). 다른 출처가 보여 준 값 · 사용자가 저장한 값은 남는다", async () => {
      const me = await f.user();
      const slack = await f.connection(me, "slack", "T1:U1");
      const gmail = await f.connection(me, "gmail", "google-sub-1");
      const source = await f.source(me, { connectionId: slack, externalId: "C1:1.0", version: "1.0", url: "https://team.slack.com/archives/C1/p1" });
      const context = await f.context(me);
      await f.member(me, context, source);
      await f.chunks(me, source, ["슬랙 조각"]);
      const m = await sourceMemories(me, source, context);
      // 신원: 연결 결과(oauth)는 연결에 묶이고, 사용자가 확인한 Slack 계정은 묶이지 않는다
      await db().query(
        `insert into public.identity_links (user_id, provider, account_ref, connection_id, verified_via) values ($1, 'slack', 'T1:U1', $2, 'oauth'), ($1, 'slack', 'T9:U1', null, 'user_confirmed')`,
        [me, slack],
      );
      await db().query(`insert into public.identity_links (user_id, provider, account_ref, connection_id, verified_via) values ($1, 'slack', 'T1:U7', $2, 'inferred')`, [me, slack]);
      // 사람: Slack에서만 본 사람 / Slack + Gmail에서 본 사람(이름이 다름) / 이름이 같은 Slack · Gmail / 사용자가 만든 사람
      const observe = async (provider: string, account: string, name: string | null, email: string | null, connection: string | null) =>
        (await f.one(`select public.observe_person_handle($1, $2, $3, $4, $5, $6) as id`, [me, provider, account, name, email, connection])).id as string;
      const slackOnly = await observe("slack", "T1:U2", "슬랙 이름", "u2@slack-only.dev", slack);
      const both = await observe("gmail", "jihoon@example.com", "김지훈", "jihoon@example.com", gmail);
      expect(await observe("slack", "T1:U3", "jihoon (slack)", "jihoon@example.com", slack)).toBe(both); // 이메일로 같은 사람
      const sameName = await observe("gmail", "mina@example.com", "미나", "mina@example.com", gmail);
      expect(await observe("slack", "T1:U4", "미나", "mina@example.com", slack)).toBe(sameName);
      const userMade = await f.id(`insert into public.people (user_id, display_name, emails, origin) values ($1, '내가 적은 이름', '{me-typed@example.com}', 'user') returning id`, [me]);
      await f.one(`insert into public.people_handles (user_id, person_id, provider, account_ref, display_name, origin, connection_id) values ($1, $2, 'slack', 'T1:U5', 'Slack 이름', 'source', $3) returning id`, [
        me,
        userMade,
        slack,
      ]);
      expect(await f.person(both)).toMatchObject({ handles: { gmail: "jihoon@example.com", slack: "T1:U3" } });

      expect(await f.one(`select public.disconnect_connection($1, $2) as ok`, [me, slack])).toEqual({ ok: true });

      expect(await f.chunkTexts(source)).toEqual([]);
      expect(await f.memory(m.observed)).toMatchObject({ statement: "", source_purged: true, value: {} });
      expect((await f.memory(m.observed))?.source_ref).toEqual({ source_id: source });
      expect(await f.memory(m.inferred)).toBeUndefined();
      expect(await f.memory(m.explicit)).toMatchObject({ statement: "디자인 확정 뒤 개발 시작", value: { start_after: "design" } });
      expect((await f.memory(m.explicit))?.source_ref).toEqual({ source_id: source }); // Slack 인용이 정확히 빠졌다
      // 신원: 그 연결의 oauth · inferred는 지워지고 사용자가 확인한 링크는 남는다
      expect((await db().query(`select account_ref, verified_via from public.identity_links where user_id = $1 order by account_ref`, [me]))).toEqual([
        { account_ref: "T9:U1", verified_via: "user_confirmed" },
      ]);
      // 사람: Slack에서만 온 이름 · 이메일 · 계정은 없어지고, 다른 출처(Gmail)가 보여 준 값과 사용자가 적은 값은 남는다
      expect(await f.person(slackOnly)).toEqual({ display_name: null, emails: [], handles: {}, origin: "source" });
      expect(await f.person(both)).toEqual({ display_name: "김지훈", emails: ["jihoon@example.com"], handles: { gmail: "jihoon@example.com" }, origin: "source" });
      expect(await f.person(sameName)).toEqual({ display_name: "미나", emails: ["mina@example.com"], handles: { gmail: "mina@example.com" }, origin: "source" });
      expect(await f.person(userMade)).toEqual({ display_name: "내가 적은 이름", emails: ["me-typed@example.com"], handles: {}, origin: "user" });
      expect(await db().query(`select 1 from public.people_handles where user_id = $1 and provider = 'slack'`, [me])).toEqual([]);
      // 끊은 Slack 원문에는 explicit도 인용(Slack 글자)을 담지 못한다
      await expect(
        f.remember(me, { kind: "fact", scope_kind: "global", statement: "내 기억", origin: "explicit", source_ref: { source_id: source, quote: "슬랙 글" } }),
      ).rejects.toThrow(/source text was purged/);
    });

    it("(b) Slack 앱 제거(revoke_slack_connections): 연결 행은 남아도 신원 링크 · Slack 계정 · 조각 · 기억 글이 지워진다. 다시 불러도 같다", async () => {
      const me = await f.user();
      const team = `T${randomUUID().slice(0, 8)}`;
      const slack = await f.connection(me, "slack", `${team}:U1`);
      const source = await f.source(me, { connectionId: slack, externalId: "C1:2.0", version: "2.0" });
      const context = await f.context(me);
      await f.member(me, context, source);
      await f.chunks(me, source, ["슬랙 조각"]);
      const m = await sourceMemories(me, source, context);
      await db().query(`insert into public.identity_links (user_id, provider, account_ref, connection_id, verified_via) values ($1, 'slack', $2, $3, 'oauth')`, [
        me,
        `${team}:U1`,
        slack,
      ]);
      const person = (await f.one(`select public.observe_person_handle($1, 'slack', $2, '슬랙 사람', null, $3) as id`, [me, `${team}:U2`, slack])).id as string;

      const revoke = () => f.one(`select public.revoke_slack_connections($1, null, now()) as n`, [team]);
      expect(await revoke()).toEqual({ n: 1 });
      expect(await f.one(`select status from public.connections where id = $1`, [slack])).toEqual({ status: "revoked" });
      expect(await db().query(`select 1 from public.identity_links where connection_id = $1`, [slack])).toEqual([]);
      expect(await f.person(person)).toEqual({ display_name: null, emails: [], handles: {}, origin: "source" });
      expect(await f.chunkTexts(source)).toEqual([]);
      expect(await f.memory(m.observed)).toMatchObject({ statement: "", source_purged: true });
      expect((await f.memory(m.explicit))?.source_ref).toEqual({ source_id: source });
      // 안전망: Slack 대기 정리가 끊은 원문을 다시 지워도 기억 · 조각은 그대로(다시 돌지 않음)
      const snapshot = await f.memory(m.explicit);
      await db().query(`select public.purge_slack_sources(array[$1]::uuid[])`, [source]);
      await db().query(`select * from public.purge_slack_buffers(now(), now())`);
      expect(await f.memory(m.explicit)).toEqual(snapshot);
    });

    it("(c) 다른 연결 끊기: 그 연결의 oauth 링크만 지워진다. 원문 · 조각 · 기억은 보관 정책대로 남고, 사람 계정은 출처 연결만 비운다", async () => {
      const me = await f.user();
      const gmail = await f.connection(me, "gmail", "sub-1");
      const otherGmail = await f.connection(me, "gmail", "sub-2");
      const source = await f.source(me, { connectionId: gmail, externalId: "m-1", version: "1" });
      const context = await f.context(me);
      await f.member(me, context, source);
      await f.chunks(me, source, ["메일 조각"]);
      const m = await sourceMemories(me, source, context);
      // 한 서비스에 계정 여럿: 두 연결의 oauth 링크 + 사용자가 적은 주소(profile)
      await db().query(
        `insert into public.identity_links (user_id, provider, account_ref, email, connection_id, verified_via) values
           ($1, 'gmail', 'sub-1', 'me@work.dev', $2, 'oauth'), ($1, 'gmail', 'sub-2', 'me@home.dev', $3, 'oauth'), ($1, 'gmail', 'alias', 'alias@work.dev', null, 'profile')`,
        [me, gmail, otherGmail],
      );
      const person = (await f.one(`select public.observe_person_handle($1, 'gmail', 'peer@example.com', '상대', 'peer@example.com', $2) as id`, [me, gmail])).id as string;

      expect(await f.one(`select public.disconnect_connection($1, $2) as ok`, [me, gmail])).toEqual({ ok: true });

      expect((await db().query(`select account_ref from public.identity_links where user_id = $1 order by account_ref`, [me])).map((r) => r.account_ref)).toEqual([
        "alias",
        "sub-2",
      ]);
      expect(await f.one(`select raw_text, raw_text_purged_at, connection_id from public.sources where id = $1`, [source])).toMatchObject({
        raw_text: "Shape 출시는 목요일. 디자인 확정 뒤 개발 시작.",
        raw_text_purged_at: null,
        connection_id: null,
      });
      expect(await f.chunkTexts(source)).toEqual(["메일 조각"]);
      // 연결을 끊어 connection_id가 비어도 범위 검색은 그대로 찾고, 다시 연결해 들어온 새 revision은 같은 문서로 묶여 옛 조각을 바꾼다
      const search = async () => (await db().query(`select text from public.match_context_chunks($1, $2, $3, 5)`, [me, context, vector(0)])).map((r) => r.text);
      expect(await search()).toEqual(["메일 조각"]);
      const reconnected = await f.connection(me, "gmail", "sub-1b");
      const v2 = await f.source(me, { connectionId: reconnected, externalId: "m-1", version: "2" });
      expect(await f.chunks(me, v2, ["다시 연결한 뒤 조각"], [vector(0)])).toEqual({ status: "replaced", chunks: 1 });
      expect(await f.chunkTexts(source)).toEqual([]);
      expect(await search()).toEqual(["다시 연결한 뒤 조각"]);
      expect(await f.memory(m.observed)).toMatchObject({ statement: "출시는 목요일", source_purged: false });
      expect(await f.memory(m.inferred)).toBeDefined();
      expect(await f.person(person)).toEqual({ display_name: "상대", emails: ["peer@example.com"], handles: { gmail: "peer@example.com" }, origin: "source" });
      expect(await f.one(`select connection_id, origin from public.people_handles where person_id = $1`, [person])).toEqual({ connection_id: null, origin: "source" });
    });

    it("(d) 접근 상실: 조각 · 기억 · 행은 남고 범위 검색에서 빠진다. 되찾으면 다시 나온다. 범위 version이 오른다", async () => {
      const me = await f.user();
      const notion = await f.connection(me, "notion");
      const kept = await f.source(me, { connectionId: notion, externalId: "page-a", version: "v1" });
      const lost = await f.source(me, { connectionId: notion, externalId: "page-b", version: "v1" });
      const context = await f.context(me);
      await f.member(me, context, kept);
      await f.member(me, context, lost);
      await f.chunks(me, kept, ["남는 조각"], [vector(0)]);
      await f.chunks(me, lost, ["잃은 조각"], [vector(0)]);
      const m = await sourceMemories(me, lost, context);
      const search = async () =>
        (await db().query(`select text from public.match_context_chunks($1, $2, $3, 10) order by text`, [me, context, vector(0)])).map((r) => r.text);
      expect(await search()).toEqual(["남는 조각", "잃은 조각"]);
      const before = await f.version(context);

      await db().query(`update public.sources set access_lost_at = now() where id = $1`, [lost]);
      expect(await search()).toEqual(["남는 조각"]);
      expect(await f.chunkTexts(lost)).toEqual(["잃은 조각"]);
      expect(await f.memory(m.observed)).toMatchObject({ statement: "출시는 목요일", source_purged: false });
      expect(await f.version(context)).toBe(before + 1);

      await db().query(`update public.sources set access_lost_at = null where id = $1`, [lost]);
      expect(await search()).toEqual(["남는 조각", "잃은 조각"]);
      expect(await f.version(context)).toBe(before + 2);

      // 접근은 문서의 성질: 멤버인 옛 revision만 잃음으로 표시돼도 최신 revision의 조각까지 빠진다. 서버 함수는 모든 revision을 함께 바꾼다
      const lostV2 = await f.source(me, { connectionId: notion, externalId: "page-b", version: "v2" });
      await f.chunks(me, lostV2, ["잃은 문서의 새 조각"], [vector(0)]);
      expect(await search()).toEqual(["남는 조각", "잃은 문서의 새 조각"]);
      await db().query(`update public.sources set access_lost_at = now() where id = $1`, [lost]);
      expect(await search()).toEqual(["남는 조각"]);
      await db().query(`update public.sources set access_lost_at = null where id = $1`, [lost]);
      expect(await f.one(`select public.set_sources_access($1, $2::uuid[], true) as n`, [me, [lostV2]])).toEqual({ n: 2 });
      expect((await db().query(`select access_lost_at is not null as lost from public.sources where id = any ($1::uuid[])`, [[lost, lostV2]])).map((r) => r.lost)).toEqual([true, true]);
      expect(await search()).toEqual(["남는 조각"]);
      expect(await f.one(`select public.set_sources_access($1, $2::uuid[], false) as n`, [me, [lost]])).toEqual({ n: 2 });
      expect(await search()).toEqual(["남는 조각", "잃은 문서의 새 조각"]);

      // 앱(authenticated)은 서버가 정하는 원문 열을 바꾸지 못한다: 바꾸면 접근 상실 · 지운 원문 가드가 풀린다
      await db().query(`update public.sources set access_lost_at = now() where id = $1`, [lost]);
      await expect(db().asUser(me, () => db().query(`update public.sources set access_lost_at = null where id = $1`, [lost]))).rejects.toThrow(
        /set by the server only/,
      );
      await expect(db().asUser(me, () => db().query(`update public.sources set raw_text_purged_at = now() where id = $1`, [kept]))).rejects.toThrow(
        /set by the server only/,
      );
      // 다른 열은 지금처럼 고칠 수 있다 (owner_all 정책 그대로)
      await db().asUser(me, () => db().query(`update public.sources set title = '앱이 고친 제목' where id = $1`, [kept]));
      expect(await f.one(`select title, access_lost_at is not null as lost from public.sources where id = $1`, [lost])).toEqual({ title: null, lost: true });
    });

    it("(e) 사용자의 기억 삭제 · 잊기: 행 삭제는 이력 포인터만 비우고, 잊기는 revoked_at. 둘 다 범위 version을 올린다", async () => {
      const me = await f.user();
      const context = await f.context(me);
      const item = (statement: string) => ({ kind: "fact", scope_kind: "context", context_id: context, subject: "deploy day", statement, origin: "explicit" });
      const x = await f.remember(me, item("X"));
      const y = await f.remember(me, item("Y"));
      let v = await f.version(context);
      await db().query(`delete from public.memory_items where id = $1`, [y.id]);
      expect(await f.version(context)).toBe(v + 1);
      expect(await f.memory(x.id!)).toMatchObject({ superseded_by: null });
      expect((await f.memory(x.id!))?.superseded_at).toBeInstanceOf(Date);
      const z = await f.remember(me, { ...item("Z"), subject: "other" });
      v = await f.version(context);
      await db().query(`update public.memory_items set revoked_at = now() where id = $1`, [z.id]);
      expect(await f.version(context)).toBe(v + 1);
    });

    it("원문 행 삭제: 조각은 외래키로, observed 글 · 인용은 비우고, inferred는 지우고, explicit은 인용만 뺀다", async () => {
      const me = await f.user();
      const source = await f.source(me);
      const context = await f.context(me);
      await f.chunks(me, source, ["조각"]);
      const m = await sourceMemories(me, source, context);
      await db().query(`delete from public.sources where id = $1`, [source]);
      expect(await f.chunkTexts(source)).toEqual([]);
      expect(await f.memory(m.observed)).toMatchObject({ statement: "", source_purged: true });
      expect(await f.memory(m.inferred)).toBeUndefined();
      expect(await f.memory(m.explicit)).toMatchObject({ statement: "디자인 확정 뒤 개발 시작" });
      expect((await f.memory(m.explicit))?.source_ref).toEqual({ source_id: source });
    });

    it("(f) 계정 삭제: 사람 계정 · 조각 · 기억까지 cascade로 지워지고 다른 사용자의 행은 그대로다", async () => {
      const [leaving, staying] = [await f.user(), await f.user()];
      for (const owner of [leaving, staying]) {
        const slack = await f.connection(owner, "slack", `T-${owner}:U1`);
        const source = await f.source(owner, { connectionId: slack, externalId: "C:1", version: "1" });
        const context = await f.context(owner);
        await f.member(owner, context, source);
        await f.chunks(owner, source, ["조각"]);
        await sourceMemories(owner, source, context);
        await db().query(`select public.observe_person_handle($1, 'slack', 'T:U9', '사람', null, $2)`, [owner, slack]);
      }
      const tables = ["people", "people_handles", "source_chunks", "memory_items", "work_contexts", "context_members"];
      const count = async (userId: string) =>
        Object.fromEntries(
          await Promise.all(tables.map(async (t) => [t, Number((await f.one(`select count(*) as n from public.${t} where user_id = $1`, [userId])).n)])),
        );
      const stayingBefore = await count(staying);
      await db().query(`delete from auth.users where id = $1`, [leaving]);
      expect(await count(leaving)).toEqual(Object.fromEntries(tables.map((t) => [t, 0])));
      expect(await count(staying)).toEqual(stayingBefore);
    });
  });

  describe("사람 계정 (people_handles): 1차 키 유일 · 이름만으로 합치지 않음", () => {
    it("이름이 같아도 계정이 다르면 다른 사람이고, 같은 계정은 한 사람에게만 붙는다 (사용자마다)", async () => {
      const [me, other] = [await f.user(), await f.user()];
      const slack = await f.connection(me, "slack", "T1:U1");
      const observe = async (userId: string, account: string, name: string, email: string | null = null, connection: string | null = null) =>
        (await f.one(`select public.observe_person_handle($1, 'slack', $2, $3, $4, $5) as id`, [userId, account, name, email, connection])).id as string;
      const a = await observe(me, "T1:U2", "김민수", null, slack);
      const b = await observe(me, "T1:U3", "김민수", null, slack);
      expect(a).not.toBe(b);
      expect(await observe(me, "T1:U2", "김민수 (이름 바뀜)", null, slack)).toBe(a);
      expect(await f.person(a)).toMatchObject({ display_name: "김민수 (이름 바뀜)", handles: { slack: "T1:U2" } });
      // 다른 사용자는 같은 계정을 따로 가진다
      const theirs = await observe(other, "T1:U2", "김민수");
      expect(theirs).not.toBe(a);
      // 같은 사용자의 같은 계정을 두 사람에게 직접 붙이지 못한다 (unique)
      await expect(
        db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, origin) values ($1, $2, 'slack', 'T1:U2', 'user')`, [me, b]),
      ).rejects.toThrow(/people_handles_user_id_provider_account_ref_key/);
      // 긴 이름은 200자로 자르고, 주소 모양이 아닌 이메일은 2차 키 · 이메일로 쓰지 않는다
      const long = await observe(me, "T1:U8", "가".repeat(250), "not-an-email", slack);
      expect(await f.person(long)).toMatchObject({ display_name: "가".repeat(200), emails: [] });
      expect(await f.one(`select email from public.people_handles where user_id = $1 and account_ref = 'T1:U8'`, [me])).toEqual({ email: null });
      // 이메일이 두 사람과 같으면 고르지 않고 새 사람
      await db().query(`insert into public.people (user_id, display_name, emails, origin) values ($1, '갑', '{dup@example.com}', 'user'), ($1, '을', '{DUP@example.com}', 'user')`, [me]);
      const third = await observe(me, "T1:U9", "병", "dup@example.com", slack);
      expect(await f.person(third)).toMatchObject({ display_name: "병", origin: "source" });
      // 사용자가 적은 계정(origin user)은 관찰이 고치지 않는다
      const typed = await f.id(`insert into public.people (user_id, display_name, origin) values ($1, '내가 적음', 'user') returning id`, [me]);
      await db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, display_name, origin) values ($1, $2, 'notion', 'n-1', '내가 적음', 'user')`, [
        me,
        typed,
      ]);
      expect(await f.one(`select public.observe_person_handle($1, 'notion', 'n-1', '노션 이름', 'n@example.com', null) as id`, [me])).toEqual({ id: typed });
      expect(await f.one(`select display_name, email, origin from public.people_handles where user_id = $1 and account_ref = 'n-1'`, [me])).toEqual({
        display_name: "내가 적음",
        email: null,
        origin: "user",
      });
    });

    it("앱은 자기 계정 행만 읽고 쓰지 못한다. 다른 사용자의 사람 · 연결을 가리키지 못한다 (복합 외래키). 사용자가 적은 계정은 연결이 없다", async () => {
      const [me, other] = [await f.user(), await f.user()];
      const mine = await f.id(`insert into public.people (user_id, display_name, origin) values ($1, '나의 상대', 'user') returning id`, [me]);
      const theirs = await f.id(`insert into public.people (user_id, display_name, origin) values ($1, '남의 상대', 'user') returning id`, [other]);
      const theirConnection = await f.connection(other, "slack", "T2:U1");
      await db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, origin) values ($1, $2, 'slack', 'T1:U1', 'user')`, [me, mine]);
      await expect(
        db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, origin) values ($1, $2, 'slack', 'T1:U2', 'user')`, [me, theirs]),
      ).rejects.toThrow(/foreign key/);
      await expect(
        db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, origin, connection_id) values ($1, $2, 'slack', 'T1:U3', 'source', $3)`, [
          me,
          mine,
          theirConnection,
        ]),
      ).rejects.toThrow(/foreign key/);
      const myConnection = await f.connection(me, "slack", "T1:U0");
      await expect(
        db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, origin, connection_id) values ($1, $2, 'slack', 'T1:U4', 'user', $3)`, [
          me,
          mine,
          myConnection,
        ]),
      ).rejects.toThrow(/people_handles_user_unbound/);
      await expect(
        db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, origin) values ($1, $2, 'Slack App', 'x', 'user')`, [me, mine]),
      ).rejects.toThrow(/people_handles_provider_check/);

      const seen = await db().asUser(other, () => db().query(`select account_ref from public.people_handles`));
      expect(seen).toEqual([]);
      expect(await db().asUser(me, () => db().query(`select account_ref from public.people_handles`))).toEqual([{ account_ref: "T1:U1" }]);
      await expect(db().asUser(me, () => db().query(`delete from public.people_handles`))).rejects.toThrow(/permission denied/);
      await expect(
        db().asUser(me, () => db().query(`insert into public.people_handles (user_id, person_id, provider, account_ref, origin) values ($1, $2, 'notion', 'z', 'user')`, [me, mine])),
      ).rejects.toThrow(/permission denied/);
    });
  });

  describe("신원 링크 (identity_links): 연결에 묶이는 링크", () => {
    it("oauth · inferred는 연결이 있어야 하고 profile · user_confirmed는 연결이 없다. 한 서비스에 계정 여럿은 된다", async () => {
      const me = await f.user();
      const google = await f.connection(me, "google", "sub-a");
      const link = (account: string, via: string, connection: string | null) =>
        db().query(`insert into public.identity_links (user_id, provider, account_ref, connection_id, verified_via) values ($1, 'google', $2, $3, $4)`, [
          me,
          account,
          connection,
          via,
        ]);
      await expect(link("a1", "oauth", null)).rejects.toThrow(/identity_links_connection_bound/);
      await expect(link("a2", "inferred", null)).rejects.toThrow(/identity_links_connection_bound/);
      await expect(link("a3", "profile", google)).rejects.toThrow(/identity_links_connection_bound/);
      await expect(link("a4", "user_confirmed", google)).rejects.toThrow(/identity_links_connection_bound/);
      await link("sub-a", "oauth", google);
      await link("sub-b", "oauth", await f.connection(me, "google", "sub-b"));
      await link("alias", "profile", null);
      expect((await db().query(`select count(*)::int as n from public.identity_links where user_id = $1 and provider = 'google'`, [me]))[0].n).toBe(3);
    });
  });

  describe("주제(subject)는 두 경우만 바뀐다", () => {
    it("주제 없던 항목에 아무 주제나 붙여 다른 사실에 끼우지 못한다 ('memory:<id>'만), 주제 있는 항목은 바꾸지 못한다", async () => {
      const me = await f.user();
      const loose = await f.remember(me, { kind: "fact", scope_kind: "global", statement: "주제 없음", origin: "explicit" });
      await expect(db().query(`update public.memory_items set subject = 'deploy day' where id = $1`, [loose.id])).rejects.toThrow(/kind, scope and subject are fixed/);
      await db().query(`update public.memory_items set subject = $2 where id = $1`, [loose.id, `memory:${loose.id}`]);
      await expect(db().query(`update public.memory_items set subject = null where id = $1`, [loose.id])).rejects.toThrow(/kind, scope and subject are fixed/);
    });
  });

  describe("원문 조각 (replace_source_chunks): revision 교체는 한 번에", () => {
    it("같은 문서의 새 revision은 옛 revision 조각을 바꾸고, 늦게 끝난 옛 처리는 새 조각을 덮지 못한다(stale). 멤버 원문의 새 revision은 범위 version을 올린다", async () => {
      const me = await f.user();
      const notion = await f.connection(me, "notion");
      const v1 = await f.source(me, { connectionId: notion, externalId: "page-1", version: "v1", occurredAt: "2026-10-01T00:00:00Z" });
      const context = await f.context(me);
      await f.member(me, context, v1);
      expect(await f.chunks(me, v1, ["v1 첫 조각", "v1 둘째 조각"])).toEqual({ status: "replaced", chunks: 2 });
      expect(await f.chunks(me, v1, ["v1 다시"])).toEqual({ status: "replaced", chunks: 1 });
      expect(await f.chunkTexts(v1)).toEqual(["v1 다시"]);

      const before = await f.version(context);
      const v2 = await f.source(me, { connectionId: notion, externalId: "page-1", version: "v2", occurredAt: "2026-10-02T00:00:00Z" });
      expect(await f.version(context)).toBe(before + 1);
      expect(await f.chunks(me, v2, ["v2 조각"])).toEqual({ status: "replaced", chunks: 1 });
      expect(await f.chunkTexts(v1)).toEqual([]);
      expect(await db().query(`select source_revision, seq, text from public.source_chunks where source_id = $1`, [v2])).toEqual([
        { source_revision: "v2", seq: 0, text: "v2 조각" },
      ]);
      expect(await f.chunks(me, v1, ["늦은 v1"])).toEqual({ status: "stale", chunks: 0 });
      expect(await f.chunkTexts(v2)).toEqual(["v2 조각"]);
      // 범위의 멤버는 옛 revision(v1) 행이지만, 검색은 같은 문서의 최신 revision 조각을 찾는다
      expect((await db().query(`select text from public.match_context_chunks($1, $2, $3, 5)`, [me, context, vector(0)])).map((r) => r.text)).toEqual(["v2 조각"]);
      // 다른 문서 · 다른 사용자의 조각은 그대로
      const other = await f.source(me, { connectionId: notion, externalId: "page-2", version: "v1" });
      await f.chunks(me, other, ["다른 문서"]);
      await f.chunks(me, v2, ["v2 다시"]);
      expect(await f.chunkTexts(other)).toEqual(["다른 문서"]);
      await expect(f.chunks(await f.user(), v2, ["남의 원문"])).rejects.toThrow(/source not found/);

      // 순서는 수집 순서다(occurred_at이 아니다): Notion 페이지의 날짜 속성을 앞당기거나 지운 새 revision도 최신이다
      const v3 = await f.source(me, { connectionId: notion, externalId: "page-1", version: "v3", occurredAt: "2026-09-01T00:00:00Z" });
      expect(await f.chunks(me, v3, ["날짜를 앞당긴 v3"])).toEqual({ status: "replaced", chunks: 1 });
      expect(await f.chunkTexts(v2)).toEqual([]);
      expect(await f.chunks(me, v2, ["늦은 v2"])).toEqual({ status: "stale", chunks: 0 });
      expect(await f.chunkTexts(v3)).toEqual(["날짜를 앞당긴 v3"]);
      await expect(db().query(`select * from public.replace_source_chunks($1, $2, $3, $4)`, [me, v2, ["a", "b"], [vector(0)]])).rejects.toThrow(/differ in length/);
    });
  });

  describe("조각이 바뀌면 범위 version이 오른다 (묶음의 자료가 바뀐다)", () => {
    it("멤버 문서의 조각이 실제로 바뀔 때만 1 오른다: 같은 조각을 다시 넣으면(unchanged) · 옛 revision(stale) · 지운 원문(purged) · 멤버가 아닌 문서 · 후보 멤버는 오르지 않는다", async () => {
      const me = await f.user();
      const notion = await f.connection(me, "notion");
      const v1 = await f.source(me, { connectionId: notion, externalId: "doc-v", version: "v1" });
      const outside = await f.source(me, { connectionId: notion, externalId: "doc-out", version: "v1" });
      const guessed = await f.source(me, { connectionId: notion, externalId: "doc-guess", version: "v1" });
      const context = await f.context(me);
      await f.member(me, context, v1);
      await f.member(me, context, guessed, "inferred");
      const v = () => f.version(context);
      let at = await v();

      expect(await f.chunks(me, v1, ["첫 조각"], [vector(1)])).toEqual({ status: "replaced", chunks: 1 });
      expect(await v()).toBe(at + 1);
      at = await v();
      expect(await f.chunks(me, v1, ["첫 조각"], [vector(1)])).toEqual({ status: "unchanged", chunks: 1 });
      expect(await v()).toBe(at);
      expect(await f.chunks(me, v1, ["첫 조각"], [vector(2)])).toEqual({ status: "replaced", chunks: 1 }); // 임베딩만 달라도 바뀐 것
      expect(await v()).toBe(at + 1);
      at = await v();

      const v2 = await f.source(me, { connectionId: notion, externalId: "doc-v", version: "v2" });
      expect(await v()).toBe(at + 1); // 새 revision (기존 규칙)
      at = await v();
      expect(await f.chunks(me, v2, ["둘째 revision 조각"])).toEqual({ status: "replaced", chunks: 1 });
      expect(await v()).toBe(at + 1);
      at = await v();
      expect(await f.chunks(me, v1, ["늦은 옛 조각"])).toEqual({ status: "stale", chunks: 0 });
      expect(await f.chunks(me, outside, ["멤버 아닌 문서"])).toEqual({ status: "replaced", chunks: 1 });
      expect(await f.chunks(me, guessed, ["후보 멤버 문서"])).toEqual({ status: "replaced", chunks: 1 });
      expect(await v()).toBe(at);

      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now() where id = $1`, [v2]);
      at = await v();
      expect(await f.chunks(me, v2, ["지운 원문"])).toEqual({ status: "purged", chunks: 0 });
      expect(await v()).toBe(at);
      expect(await db().query(`select 1 from public.context_version_bumps`)).toEqual([]);
    });
  });

  describe("멤버가 아닌 원문을 인용한 범위 기억도 원문의 변화에 version이 오른다", () => {
    it("범위 observed 기억이 인용한 문서(멤버 아님)의 접근 상실 · 되찾음에 오르고, 관계없는 범위 · 쓰지 않는 기억(잊음 · 후보)은 오르지 않는다", async () => {
      const me = await f.user();
      const notion = await f.connection(me, "notion");
      const v1 = await f.source(me, { connectionId: notion, externalId: "cited", version: "v1" });
      const v2 = await f.source(me, { connectionId: notion, externalId: "cited", version: "v2" });
      const elsewhere = await f.source(me, { connectionId: notion, externalId: "other-doc", version: "v1" });
      const [context, unrelated, forgotten, guessed] = [await f.context(me), await f.context(me, "관계없음"), await f.context(me, "잊음"), await f.context(me, "후보")];
      const cite = (contextId: string, sourceId: string, extra: Record<string, unknown> = {}) =>
        f.remember(me, { kind: "fact", scope_kind: "context", context_id: contextId, statement: "자료에서 읽음", origin: "observed", source_ref: { source_id: sourceId }, ...extra });
      await cite(context, v1); // 옛 revision을 인용
      await cite(unrelated, elsewhere);
      const gone = await cite(forgotten, v2);
      await db().query(`update public.memory_items set revoked_at = now() where id = $1`, [gone.id]);
      await f.remember(me, { kind: "fact", scope_kind: "context", context_id: guessed, statement: "추정", origin: "inferred", confidence: 0.5, source_ref: { source_id: v2 } });
      const versions = async () => Promise.all([context, unrelated, forgotten, guessed].map((id) => f.version(id)));
      const [c0, u0, f0, g0] = await versions();

      await db().query(`select public.set_sources_access($1, $2::uuid[], true)`, [me, [v2]]);
      expect(await versions()).toEqual([c0 + 1, u0, f0, g0]);
      await db().query(`select public.set_sources_access($1, $2::uuid[], false)`, [me, [v2]]);
      expect(await versions()).toEqual([c0 + 2, u0, f0, g0]);

      // 새 revision · external_version 변경은 인용한 기억(묶음에 든 글)을 바꾸지 않는다: 멤버가 아닌 범위는 오르지 않는다 (CTX12)
      await f.source(me, { connectionId: notion, externalId: "cited", version: "v3" });
      await db().query(`update public.sources set external_version = 'v1b' where id = $1`, [v1]);
      expect(await versions()).toEqual([c0 + 2, u0, f0, g0]);

      // 정정된 기억 · 글이 지워진(비운) 기억은 쓰지 않으므로 그 범위는 오르지 않는다
      const [corrected, blanked] = [await f.context(me, "정정됨"), await f.context(me, "비움")];
      const fact = { kind: "fact", scope_kind: "context", subject: "launch", origin: "observed", source_ref: { source_id: v2 } };
      await f.remember(me, { ...fact, context_id: corrected, statement: "자료: 목요일" });
      await f.remember(me, { kind: "fact", scope_kind: "context", context_id: corrected, subject: "launch", statement: "내가 정함: 금요일", origin: "explicit" });
      const purgedDoc = await f.source(me, { connectionId: notion, externalId: "purged-doc", version: "v1" });
      await cite(blanked, purgedDoc);
      await db().query(`update public.sources set raw_text = '', raw_text_purged_at = now() where id = $1`, [purgedDoc]);
      const [k0, b0] = [await f.version(corrected), await f.version(blanked)];
      await db().query(`select public.set_sources_access($1, $2::uuid[], true)`, [me, [v2, purgedDoc]]);
      expect([await f.version(corrected), await f.version(blanked)]).toEqual([k0, b0]);
      expect(await f.version(context)).toBe(c0 + 3); // 쓰는 기억이 있는 범위는 오른다
    });
  });

  describe("접근 상실은 문서 단위로 기억 · 묶음에도 (검색과 같은 기준)", () => {
    it("옛 revision이 접근을 잃은 문서는 늦게 들어온 새 revision을 인용한 기억도 묶음에서 빠지고, 서버가 되찾음을 표시해야 다시 들어온다. 다른 문서 · 다른 사용자는 그대로", async () => {
      const [me, other] = [await f.user(), await f.user()];
      const notion = await f.connection(me, "notion");
      const v1 = await f.source(me, { connectionId: notion, externalId: "doc-acl", version: "v1" });
      const fine = await f.source(me, { connectionId: notion, externalId: "doc-fine", version: "v1" });
      const theirs = await f.source(other, { connectionId: await f.connection(other, "notion"), externalId: "doc-acl", version: "v1" });
      await db().query(`select public.set_sources_access($1, $2::uuid[], true)`, [me, [v1]]);
      const v2 = await f.source(me, { connectionId: notion, externalId: "doc-acl", version: "v2" }); // 늦게 들어온 새 revision (접근 표시 없음)
      const context = await f.context(me);
      const observed = (sourceId: string, statement: string) =>
        f.remember(me, { kind: "fact", scope_kind: "context", context_id: context, statement, origin: "observed", source_ref: { source_id: sourceId } });
      await observed(v2, "새 revision에서 읽음");
      await observed(fine, "다른 문서에서 읽음");

      const states = async (userId: string, ids: string[]) =>
        (await db().query(`select * from public.context_source_states($1, $2::uuid[]) order by id`, [userId, ids])).map(
          (r): SourceState => ({ id: r.id as string, provider: r.provider as string | null, purged: r.purged as boolean, purgeReason: r.purge_reason as string | null, accessLost: r.access_lost as boolean, externalUrl: r.external_url as string | null }),
        );
      const lostOf = async (userId: string, ids: string[]) => Object.fromEntries((await states(userId, ids)).map((st) => [st.id, st.accessLost]));
      expect(await lostOf(me, [v1, v2, fine])).toEqual({ [v1]: true, [v2]: true, [fine]: false });
      expect(await lostOf(other, [theirs, v2])).toEqual({ [theirs]: false }); // 남의 원문은 보이지 않고, 같은 외부 id여도 다른 사용자는 그대로

      const bundleMemory = async () => {
        const rows = (await db().query(
          `select id, kind, scope_kind, context_id, action_id, person_id, agent_adapter, subject, statement, origin, source_ref, observed_at,
                  valid_from, valid_until, superseded_at, revoked_at, source_purged from public.memory_items where user_id = $1`,
          [me],
        )) as MemoryLike[];
        const { bundle } = buildContextBundle({
          context: { id: context, context_version: await f.version(context) },
          me: { display_name: "나", emails: [] },
          memory: rows,
          people: [],
          chunks: [],
          sources: await states(me, [v1, v2, fine]),
          now: new Date(),
        });
        return bundle.memory.map((m) => m.statement).sort();
      };
      expect(await bundleMemory()).toEqual(["다른 문서에서 읽음"]);
      // 서버가 되찾음을 표시하면 (문서의 모든 revision) 다시 들어온다
      await db().query(`select public.set_sources_access($1, $2::uuid[], false)`, [me, [v2]]);
      expect(await lostOf(me, [v1, v2])).toEqual({ [v1]: false, [v2]: false });
      expect(await bundleMemory()).toEqual(["다른 문서에서 읽음", "새 revision에서 읽음"]);
    });
  });

  describe("범위 version: 멤버 · 범위 기억 변화에 오르고 관계없는 변화에는 오르지 않는다", () => {
    it("멤버 추가 · 빼기 · 다시 넣기 · 후보 확인, 범위 기억 추가 · 정정에 오른다. 다른 범위 · 전체 기억 · updated_at만 바뀐 것에는 오르지 않는다", async () => {
      const me = await f.user();
      const [context, other] = [await f.context(me), await f.context(me, "다른 범위")];
      const action = await f.id(`insert into public.actions (user_id, title) values ($1, '디자인') returning id`, [me]);
      const v = () => f.version(context);
      expect(await v()).toBe(1);
      const member = await f.id(`insert into public.context_members (user_id, context_id, member_kind, action_id, origin, confidence) values ($1, $2, 'action', $3, 'inferred', 0.5) returning id`, [
        me,
        context,
        action,
      ]);
      expect(await v()).toBe(1); // 모델 후보 멤버는 묶음에 들지 않아 올리지 않는다 (CTX12)
      await db().query(`update public.context_members set origin = 'auto', confidence = null where id = $1`, [member]);
      expect(await v()).toBe(2); // 후보 확인
      await db().query(`update public.context_members set origin = 'user', removed_at = now() where id = $1`, [member]);
      expect(await v()).toBe(3);
      await db().query(`update public.context_members set updated_at = now() where id = $1`, [member]);
      expect(await v()).toBe(3);
      await db().query(`update public.context_members set removed_at = null where id = $1`, [member]);
      expect(await v()).toBe(4);

      const item = (statement: string, contextId = context) => ({ kind: "fact", scope_kind: "context", context_id: contextId, subject: "s", statement, origin: "explicit" });
      const first = await f.remember(me, item("첫"));
      expect(await v()).toBe(5);
      await f.remember(me, item("정정"));
      expect(await v()).toBe(6); // 새 행 + 옛 행의 정정 표시가 한 트랜잭션이라 1 (commit 직전 한 번)
      await f.remember(me, item("다른 범위", other));
      await f.remember(me, { kind: "fact", scope_kind: "global", statement: "전체", origin: "explicit" });
      await db().query(`update public.memory_items set updated_at = now() where id = $1`, [first.id]);
      expect(await v()).toBe(6);
      // 범위 기억 후보(inferred)는 넣거나 지워도 올리지 않는다
      const guess = await f.remember(me, { ...item("추정"), subject: "guess", origin: "inferred", confidence: 0.5 });
      await db().query(`delete from public.memory_items where id = $1`, [guess.id]);
      expect(await v()).toBe(6);
      await db().query(`delete from public.context_members where id = $1`, [member]);
      expect(await v()).toBe(7);
      // 큐는 commit마다 비고, 앱 · 익명은 큐에 넣을 수 없다 (남의 범위 version을 올리게 할 수 없다)
      expect(await db().query(`select 1 from public.context_version_bumps`)).toEqual([]);
      await expect(
        db().asUser(me, () => db().query(`insert into public.context_version_bumps (txid, context_id) values (txid_current(), $1)`, [context])),
      ).rejects.toThrow(/permission denied/);
    });
  });

  describe("권한 · 경계 (I04 · I14 · D-13)", () => {
    it("B1의 함수는 서버만 부른다(search_path 고정). 소유자 권한은 cascade · 앱의 원문 쓰기로도 도는 트리거 함수뿐이다", async () => {
      const rpc = ["observe_person_handle", "replace_source_chunks", "match_context_chunks", "remember_memory_item", "set_sources_access", "context_source_states"];
      const internal = [
        "source_chunks_purged_source_guard", "memory_items_purged_source_guard", "purge_source_context", "sources_purge_context",
        "people_refresh_from_handles", "people_handles_refresh", "purge_slack_identity", "bump_context_versions", "queue_context_bumps",
        "flush_context_bumps", "context_members_bump_version", "memory_items_bump_context_version", "sources_bump_member_contexts",
        "source_document_ids", "sources_server_columns_guard",
      ];
      const rows = await db().query(
        `select p.proname as name, has_function_privilege('anon', p.oid, 'execute') as anon, has_function_privilege('authenticated', p.oid, 'execute') as auth,
                has_function_privilege('service_role', p.oid, 'execute') as service, p.prosecdef as definer, p.proconfig as config
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = any ($1) order by p.proname`,
        [[...rpc, ...internal]],
      );
      expect(rows.map((r) => r.name)).toEqual([...rpc, ...internal].sort());
      for (const row of rows) {
        expect(row, String(row.name)).toMatchObject({ anon: false, auth: false });
        expect(row.config, String(row.name)).toContain('search_path=""');
        if (rpc.includes(row.name as string)) expect(row.service, String(row.name)).toBe(true);
      }
      // 계정 삭제(supabase_auth_admin)의 cascade · 앱(authenticated)의 원문 쓰기로도 도는 트리거: new · old 행만 본다 (tests/pg/context-layer.test.ts가 그 역할로 지운다)
      expect(rows.filter((r) => r.definer).map((r) => r.name)).toEqual([
        "context_members_bump_version",
        "flush_context_bumps",
        "memory_items_bump_context_version",
        "people_handles_refresh",
        "queue_context_bumps",
        "sources_bump_member_contexts",
        "sources_purge_context",
      ]);
    });

    it("맥락층 표는 실행 표를 가리키지 않고 실행 표도 맥락층 표를 가리키지 않는다 (외래키 · 트리거). 맥락층 함수 본문은 execution_* 표를 쓰지 않는다", async () => {
      const contextTables = [
        "people", "people_handles", "work_contexts", "context_members", "memory_items", "identity_links", "source_chunks", "inbox_events",
        "conversations", "conversation_messages", "context_version_bumps",
      ];
      const fks = await db().query(
        `select c.conrelid::regclass::text as from_table, c.confrelid::regclass::text as to_table from pg_constraint c
          where c.contype = 'f' and (c.conrelid::regclass::text = any ($1) or c.confrelid::regclass::text = any ($1))`,
        [contextTables],
      );
      const touching = fks.filter((r) => /execution_|credit_/.test(String(r.from_table)) || /execution_|credit_/.test(String(r.to_table)));
      expect(touching).toEqual([]);
      const bodies = await db().query(
        `select p.proname as name, p.prosrc as body from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and (
            p.oid in (select t.tgfoid from pg_trigger t where not t.tgisinternal and t.tgrelid::regclass::text = any ($1))
            or p.proname in ('observe_person_handle', 'replace_source_chunks', 'match_context_chunks', 'remember_memory_item', 'purge_source_context',
                             'purge_slack_identity', 'bump_context_versions', 'queue_context_bumps', 'people_refresh_from_handles', 'set_sources_access',
                             'source_document_ids')
          )`,
        [contextTables],
      );
      expect(bodies.length).toBeGreaterThan(8);
      for (const row of bodies) expect(String(row.body), String(row.name)).not.toMatch(/execution_|credit_|approval/);
    });
  });
}
