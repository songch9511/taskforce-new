import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { answerQuestionFixture } from "./agent-questions-stop.scenarios";
import { bridgeCommandFixtures } from "./bridge-commands.scenarios";
import type { ConversationAgentDb } from "./conversation-agent-target.scenarios";

// OA F1s: Mac 기기 이름(표시용) 저장 — bridges.device_name · set_bridge_device_name · 폐기 때 비우는 트리거 · withdraw_bridge_command 교체(항목 5).
// 같은 시나리오를 PGlite(tests/db/bridge-device-name.test.ts)와 실제 Postgres(tests/pg/bridge-device-name.test.ts)에서 돌린다. 경합(P1–P3)은 실제 Postgres 파일에만 있다.
export const F1S_MIGRATION = "20261127000000_bridge_device_name.sql";
export const BRIDGE_COMMANDS_MIGRATION = "20261118000000_bridge_commands.sql";
const MIGRATIONS = path.resolve(__dirname, "../../supabase/migrations");
const STUDIO = "Studio";

/** 에러 메시지가 정규식과 맞는지 (PGlite와 실제 Postgres 모두 같은 문구) */
const rejects = (promise: Promise<unknown>, pattern: RegExp) => expect(promise).rejects.toThrow(pattern);

export function bridgeDeviceNameFixtures(db: () => ConversationAgentDb) {
  const f = bridgeCommandFixtures(db);
  return {
    ...f,
    /** set_bridge_device_name 결과 (service role 호출) */
    async setName(user: string, bridge: string, name: string | null) {
      return (await f.one("select public.set_bridge_device_name($1,$2,$3) as result", [user, bridge, name])).result as { status: string };
    },
    name: async (bridge: string) => (await f.one("select device_name from public.bridges where id=$1", [bridge])).device_name,
    /** 행이 새로 쓰였는지 보는 값: 같은 값으로 UPDATE를 해도 xmin은 바뀐다 */
    version: async (bridge: string) => await f.one("select xmin::text as xmin, updated_at::text as updated_at from public.bridges where id=$1", [bridge]),
    /** 운영의 BC 마이그레이션에서 withdraw_bridge_command 한 함수의 본문 (달러 인용 안) */
    originalWithdrawBody: () => functionBody(readFileSync(path.join(MIGRATIONS, BRIDGE_COMMANDS_MIGRATION), "utf8"), "withdraw_bridge_command"),
    newWithdrawBody: () => functionBody(readFileSync(path.join(MIGRATIONS, F1S_MIGRATION), "utf8"), "withdraw_bridge_command"),
  };
}

/** `create [or replace] function public.<name>(…) … as $$ BODY $$;` 의 BODY (주석 줄 제외, 공백은 하나로) */
export function functionBody(sql: string, name: string): string {
  const stripped = sql.split("\n").filter((line) => !line.trim().startsWith("--")).join("\n");
  const match = stripped.match(new RegExp(`create (?:or replace )?function public\\.${name}\\([^)]*\\)[\\s\\S]*?as \\$\\$([\\s\\S]*?)\\$\\$;`));
  if (!match) throw new Error(`function ${name} not found`);
  return match[1].replace(/\s+/g, " ").trim();
}

export function bridgeDeviceNameTests(db: () => ConversationAgentDb) {
  const f = bridgeDeviceNameFixtures(db);

  describe("T1 열 · CHECK", () => {
    it("device_name은 text null이고 기본값이 없다 (옛 행은 null)", async () => {
      expect(await f.one(`select data_type, is_nullable, column_default from information_schema.columns where table_schema='public' and table_name='bridges' and column_name='device_name'`))
        .toEqual({ data_type: "text", is_nullable: "YES", column_default: null });
      const bridge = await f.bridge(await f.user());
      expect(await f.name(bridge)).toBeNull();
    });

    it("모양 CHECK(bridges_device_name_shape): 빈 문자열 · 65자 · 앞뒤 공백 · 제어 문자는 23514, 1–64자 · 한글 · 이모지 · null은 통과한다", async () => {
      const user = await f.user();
      for (const bad of ["", "x".repeat(65), " Studio", "Studio ", "Stu\u0007dio", "Stu\ndio", "Stu\tdio", "\u{1f34e}".repeat(65)]) {
        await expect(f.bridge(user, { device_name: bad }), JSON.stringify(bad)).rejects.toMatchObject({ code: "23514" });
        await rejects(f.bridge(user, { device_name: bad }), /bridges_device_name_shape/);
      }
      for (const good of ["x", "x".repeat(64), "한".repeat(64), "\u{1f34e}".repeat(64), "Test Mac", "스튜디오 맥", null]) {
        const bridge = await f.bridge(user, { device_name: good });
        expect(await f.name(bridge), String(good)).toBe(good);
      }
    });
  });

  describe("T2 권한 · RLS", () => {
    it("authenticated는 device_name을 select할 수 있고 insert · update는 못 한다. anon은 아무것도 못 한다. service role은 읽고 쓴다", async () => {
      const privilege = async (role: string, kind: string) => (await f.one(`select has_column_privilege($1,'public.bridges','device_name',$2) as ok`, [role, kind])).ok;
      expect(await privilege("authenticated", "select")).toBe(true);
      for (const kind of ["insert", "update", "references"]) expect(await privilege("authenticated", kind), `authenticated ${kind}`).toBe(false);
      for (const kind of ["select", "insert", "update", "references"]) expect(await privilege("anon", kind), `anon ${kind}`).toBe(false);
      for (const kind of ["select", "insert", "update"]) expect(await privilege("service_role", kind), `service_role ${kind}`).toBe(true);
    });

    it("앱은 자기 bridge 행의 이름만 읽는다 (남의 행은 0행). 쓰기는 권한 오류", async () => {
      const [a, b] = [await f.user(), await f.user()];
      const [mine, theirs] = [await f.bridge(a, { device_name: STUDIO }), await f.bridge(b, { device_name: "Test Mac" })];
      await db().asUser(a, async () => {
        expect(await f.q("select id, device_name from public.bridges where id=any($1) order by id", [[mine, theirs]])).toEqual([{ id: mine, device_name: STUDIO }]);
        await expect(f.q("update public.bridges set device_name='x' where id=$1", [mine])).rejects.toMatchObject({ code: "42501" });
        await expect(f.q("update public.bridges set device_name='x'")).rejects.toMatchObject({ code: "42501" });
        await expect(f.q("insert into public.bridges(device_ref, device_name) values('r','x')")).rejects.toMatchObject({ code: "42501" });
      });
      expect(await f.name(mine)).toBe(STUDIO);
    });

    it("secret_hash · heartbeat_result는 여전히 읽지 못한다 (BC 열 단위 select 회귀 방지). 이름 열을 같이 골라도 같다", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user, { device_name: STUDIO });
      await db().asUser(user, async () => {
        for (const sql of ["select secret_hash from public.bridges where id=$1", "select heartbeat_result from public.bridges where id=$1", "select device_name, secret_hash from public.bridges where id=$1", "select * from public.bridges where id=$1"]) {
          await expect(f.q(sql, [bridge]), sql).rejects.toMatchObject({ code: "42501" });
        }
      });
    });

    it("bridges의 읽을 수 있는 열은 secret_hash · heartbeat_result만 빼고 모두다 (device_name 포함)", async () => {
      const columns = await f.q(`select column_name, has_column_privilege('authenticated','public.bridges',column_name,'select') as readable from information_schema.columns where table_schema='public' and table_name='bridges'`);
      expect(columns.map((c) => c.column_name)).toContain("device_name");
      for (const column of columns) expect(column.readable, String(column.column_name)).toBe(!["secret_hash", "heartbeat_result"].includes(String(column.column_name)));
    });
  });

  describe("T3 set_bridge_device_name", () => {
    it("active bridge: 새 이름 → updated, 같은 이름 → unchanged (행을 쓰지 않는다: xmin · updated_at 그대로), 다른 이름 → updated", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user);
      expect(await f.setName(user, bridge, STUDIO)).toEqual({ status: "updated" });
      expect(await f.name(bridge)).toBe(STUDIO);
      const before = await f.version(bridge);
      expect(await f.setName(user, bridge, STUDIO)).toEqual({ status: "unchanged" });
      expect(await f.version(bridge)).toEqual(before);
      expect(await f.setName(user, bridge, "Test Mac")).toEqual({ status: "updated" });
      expect(await f.name(bridge)).toBe("Test Mac");
      expect((await f.version(bridge)).xmin).not.toBe(before.xmin);
    });

    it("폐기한 bridge · 남의 bridge · 없는 bridge는 not_found이고 값이 바뀌지 않는다", async () => {
      const [owner, other] = [await f.user(), await f.user()];
      const revoked = await f.bridge(owner, { status: "revoked", revoked_at: new Date().toISOString(), device_name: "old" });
      const live = await f.bridge(owner, { device_name: STUDIO });
      expect(await f.setName(owner, revoked, "new")).toEqual({ status: "not_found" });
      expect(await f.name(revoked)).toBe("old");
      expect(await f.setName(other, live, "stolen")).toEqual({ status: "not_found" });
      expect(await f.name(live)).toBe(STUDIO);
      expect(await f.setName(owner, randomUUID(), "x")).toEqual({ status: "not_found" });
    });

    it("null 인자는 22023이다 (셋 모두)", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user);
      for (const args of [[null, bridge, "x"], [user, null, "x"], [user, bridge, null]]) {
        await expect(f.q("select public.set_bridge_device_name($1::uuid,$2::uuid,$3::text)", args), JSON.stringify(args)).rejects.toMatchObject({ code: "22023" });
      }
      expect(await f.name(bridge)).toBeNull();
    });

    it("모양이 틀린 이름은 CHECK 23514로 거절된다 (TS가 먼저 정규화하므로 정상 경로에서는 안 난다)", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user);
      await expect(f.setName(user, bridge, " padded ")).rejects.toMatchObject({ code: "23514" });
      await expect(f.setName(user, bridge, "x".repeat(65))).rejects.toMatchObject({ code: "23514" });
      expect(await f.name(bridge)).toBeNull();
    });

    it("실행 권한은 service role만이고 (anon · authenticated 거절), 불변 호출자 · search_path 비움이다", async () => {
      const row = await f.one(`select prosecdef, proconfig, has_function_privilege('anon',p.oid,'execute') as anon, has_function_privilege('authenticated',p.oid,'execute') as app,
        has_function_privilege('service_role',p.oid,'execute') as server from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname='set_bridge_device_name'`);
      expect(row).toEqual({ prosecdef: false, proconfig: ['search_path=""'], anon: false, app: false, server: true });
      const user = await f.user();
      const bridge = await f.bridge(user);
      await db().asUser(user, async () => {
        await expect(f.q("select public.set_bridge_device_name($1,$2,'x')", [user, bridge])).rejects.toMatchObject({ code: "42501" });
      });
    });

    it("본문은 bridges 하나만 건드린다: 다른 표 · metric_events 0, 삽입 · 삭제 0", async () => {
      const source = String((await f.one("select prosrc from pg_proc where proname='set_bridge_device_name'")).prosrc);
      expect([...new Set([...source.matchAll(/public\.([a-z_]+)/g)].map((m) => m[1]))]).toEqual(["bridges"]);
      expect(source).not.toMatch(/metric_events|insert\s+into|delete\s+from|execution_events/i);
    });
  });

  describe("T4 withdraw_bridge_command 교체는 한 곳만 다르다", () => {
    it("새 본문 = BC 본문에서 `delivery_reason=p_reason` 한 곳만 바꾼 것 (공백 무시)", async () => {
      const original = f.originalWithdrawBody();
      expect(original.split("delivery_reason=p_reason").length - 1, "원본에 그 글자가 정확히 한 번").toBe(1);
      const expected = original.replace("delivery_reason=p_reason", "delivery_reason=case when p_reason='expired' then null else p_reason end");
      expect(f.newWithdrawBody()).toBe(expected);
      // 실제로 적용된 본문도 파일과 같다
      const applied = String((await f.one("select prosrc from pg_proc where proname='withdraw_bridge_command'")).prosrc).replace(/\s+/g, " ").trim();
      expect(applied).toBe(expected);
    });

    it("시그니처 · 반환 · 권한이 BC 그대로다 (service role만, 불변 호출자, search_path 비움). 같은 이름의 함수는 하나", async () => {
      const rows = await f.q(`select pg_get_function_identity_arguments(p.oid) as args, pg_get_function_result(p.oid) as result, prosecdef, proconfig, has_function_privilege('anon',p.oid,'execute') as anon,
        has_function_privilege('authenticated',p.oid,'execute') as app, has_function_privilege('service_role',p.oid,'execute') as server
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and proname='withdraw_bridge_command'`);
      expect(rows).toEqual([{ args: "p_command_id uuid, p_reason text", result: "jsonb", prosecdef: false, proconfig: ['search_path=""'], anon: false, app: false, server: true }]);
    });
  });

  describe("T5 폐기하면 이름을 비운다", () => {
    it("revoke_bridge → device_name null, 폐기 결과는 그대로 (status · revoked_at · secret_hash)", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user);
      await f.setName(user, bridge, STUDIO);
      await f.q("update public.bridges set secret_hash=$2 where id=$1", [bridge, "a".repeat(64)]);
      expect(await f.name(bridge)).toBe(STUDIO);
      expect((await f.one("select public.revoke_bridge($1,$2) as result", [user, bridge])).result).toMatchObject({ status: "revoked" });
      expect(await f.one("select status, device_name, secret_hash, revoked_at is not null as revoked from public.bridges where id=$1", [bridge])).toEqual({ status: "revoked", device_name: null, secret_hash: null, revoked: true });
    });

    it("트리거는 status가 revoked로 바뀌고 이름이 있을 때만 걸린다", async () => {
      const definition = String((await f.one(`select pg_get_triggerdef(t.oid) as def from pg_trigger t where t.tgrelid='public.bridges'::regclass and t.tgname='bridges_clear_device_name'`)).def);
      expect(definition).toMatch(/BEFORE UPDATE OF status ON public\.bridges FOR EACH ROW/);
      expect(definition).toMatch(/WHEN [\s\S]*status[\s\S]* = 'revoked'[\s\S]*device_name IS NOT NULL/);
      // 이름이 없는 bridge의 폐기는 그대로 된다
      const user = await f.user();
      const bridge = await f.bridge(user);
      expect((await f.one("select public.revoke_bridge($1,$2) as result", [user, bridge])).result).toMatchObject({ status: "revoked" });
      expect(await f.one("select status, device_name from public.bridges where id=$1", [bridge])).toEqual({ status: "revoked", device_name: null });
    });

    it("재활성화(register_bridge reactivate)는 이름을 비운 채 두고, 같은 요청의 이름 쓰기가 다시 채운다", async () => {
      const user = await f.user();
      const register = async (reactivate: boolean) => (await f.one("select public.register_bridge($1,$2,$3,'1',$4::jsonb,'{}'::text[],$5) as result", [user, "dev-ref", "b".repeat(64), JSON.stringify({ adapters: {} }), reactivate])).result as { status: string; bridge_id: string };
      const first = await register(false);
      expect(first.status).toBe("registered");
      await f.setName(user, first.bridge_id, STUDIO);
      await f.q("select public.revoke_bridge($1,$2)", [user, first.bridge_id]);
      expect(await f.name(first.bridge_id)).toBeNull();
      const again = await register(true);
      expect(again).toMatchObject({ status: "reactivated", bridge_id: first.bridge_id });
      expect(await f.name(first.bridge_id)).toBeNull();
      expect(await f.setName(user, first.bridge_id, "Test Mac")).toEqual({ status: "updated" });
      expect(await f.name(first.bridge_id)).toBe("Test Mac");
    });

    it("폐기한 뒤 늦게 온 이름 쓰기는 not_found이고 이름은 비어 있다", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user);
      await f.q("select public.revoke_bridge($1,$2)", [user, bridge]);
      expect(await f.setName(user, bridge, STUDIO)).toEqual({ status: "not_found" });
      expect(await f.name(bridge)).toBeNull();
    });
  });

  describe("T6 계정 삭제", () => {
    it("사용자를 지우면 이름이 있는 bridges 행도 함께 사라진다", async () => {
      const user = await f.user();
      const bridge = await f.bridge(user, { device_name: STUDIO });
      expect(await f.name(bridge)).toBe(STUDIO);
      await f.q("delete from auth.users where id=$1", [user]);
      expect(await f.count("select 1 from public.bridges where id=$1", [bridge])).toBe(0);
      expect(await f.count("select 1 from public.bridges where device_name=$1 and user_id=$2", [STUDIO, user])).toBe(0);
    });
  });

  describe("W1 항목 5: 만료 회수는 이유를 쓰지 않는다", () => {
    it("만료한 메시지의 lease → withdrawn/expired, 메시지는 expired + 이유 null", async () => {
      const w = await f.world();
      await f.updateRow("conversation_messages", w.message, { delivery_expires_at: "2000-01-01T00:00:00Z" });
      expect(await f.lease(w)).toEqual({ status: "withdrawn", reason: "expired" });
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "expired", delivery_reason: null });
      expect(await f.one("select state, receipt from public.execution_steps where id=$1", [w.step])).toEqual({ state: "failed", receipt: { never_sent: true, reason: "expired" } });
      expect(await f.one("select outcome from public.bridge_commands where id=$1", [w.command])).toEqual({ outcome: "withdrawn" });
    });

    it("write_gate_closed 회수는 이유를 그대로 쓴다 (not_sent/write_gate_closed)", async () => {
      const w = await f.world();
      expect(await f.lease(w, null)).toEqual({ status: "withdrawn", reason: "write_gate_closed" });
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "write_gate_closed" });
    });

    it("그 밖의 회수 이유도 그대로다 (not_connected · session_closed · session_external · unsupported)", async () => {
      for (const reason of ["not_connected", "session_closed", "session_external"]) {
        const w = await f.world();
        if (reason === "not_connected") await f.updateRow("agent_connections", w.connection, { status: "error" });
        else await f.updateRow("agent_sessions", w.session, { status: reason.slice(8) });
        expect(await f.lease(w)).toMatchObject({ status: "withdrawn", reason });
        expect(await f.msg(w.message)).toMatchObject({ delivery_state: "not_sent", delivery_reason: reason });
      }
      const w = await f.world();
      expect(await f.settle(w, "decline", "unsupported_kind")).toMatchObject({ status: "withdrawn", reason: "unsupported" });
      expect(await f.msg(w.message)).toMatchObject({ delivery_state: "not_sent", delivery_reason: "unsupported" });
    });

    it("stale_answer(answer 명령)는 메시지 행을 쓰지 않는다", async () => {
      const w = await f.world();
      await f.lease(w);
      await f.bridgeEvent(w, f.event(w, "question", { text: "Choose", question: answerQuestionFixture() }));
      const answered = await f.answer(w.user, w.task);
      const command = String((await f.one("select id from public.bridge_commands where step_id=$1", [answered.step_id])).id);
      await f.updateRow("agent_tasks", w.task, { step_id: w.step }); // 답 단계가 더는 작업의 현재 단계가 아니다
      const message = await f.msg(w.message);
      expect(await f.lease({ ...w, command })).toEqual({ status: "withdrawn", reason: "stale_answer" });
      expect(await f.msg(w.message)).toEqual(message);
      expect(await f.one("select state, receipt from public.execution_steps where id=$1", [answered.step_id])).toEqual({ state: "skipped", receipt: { never_sent: true, reason: "stale_answer" } });
    });
  });
}
