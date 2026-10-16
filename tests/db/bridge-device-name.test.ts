import { readFileSync } from "node:fs";
import path from "node:path";

import type { PGlite } from "@electric-sql/pglite";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { bridgeDeviceNameTests, F1S_MIGRATION } from "./bridge-device-name.scenarios";
import { asUser, createLocalSupabase } from "./local-supabase";

// OA F1s: Mac 기기 이름(표시용) — PGlite. 같은 시나리오를 실제 Postgres로: tests/pg/bridge-device-name.test.ts (경합 P1–P3 포함)
let db: PGlite;

beforeAll(async () => {
  db = await createLocalSupabase();
}, 60_000);
afterAll(async () => {
  await db?.close();
});

describe("bridge 기기 이름 (PGlite)", () => {
  bridgeDeviceNameTests(() => ({
    query: async (sql, params) => (await db.query<Record<string, unknown>>(sql, params)).rows,
    asUser: (userId, fn) => asUser(db, userId, fn),
  }));
});

// 마이그레이션 파일 자체의 경계 (주석을 뺀 SQL): bridges 열 하나 · 작은 함수 둘 · 트리거 하나 · withdraw_bridge_command 교체 하나뿐
describe("마이그레이션 파일이 건드리는 것", () => {
  const sql = readFileSync(path.resolve(__dirname, "../../supabase/migrations", F1S_MIGRATION), "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n");

  it("alter table은 bridges의 열 하나(device_name)와 그 CHECK뿐이다", () => {
    expect([...sql.matchAll(/alter table\s+(\S+)/gi)].map((m) => m[1])).toEqual(["public.bridges"]);
    expect([...sql.matchAll(/add column\s+(\w+)/gi)].map((m) => m[1])).toEqual(["device_name"]);
    expect([...sql.matchAll(/add constraint\s+(\w+)/gi)].map((m) => m[1])).toEqual(["bridges_device_name_shape"]);
    expect(sql).not.toMatch(/\bdrop\s+(column|table|constraint|trigger|function)/i);
  });

  it("새 함수는 둘이고, 통째로 교체하는 기존 함수는 withdraw_bridge_command 하나뿐이다", () => {
    expect([...sql.matchAll(/create function\s+public\.(\w+)/gi)].map((m) => m[1]).sort()).toEqual(["bridges_clear_device_name", "set_bridge_device_name"]);
    expect([...sql.matchAll(/create or replace function\s+public\.(\w+)/gi)].map((m) => m[1])).toEqual(["withdraw_bridge_command"]);
    for (const untouched of ["register_bridge", "bridge_heartbeat", "revoke_bridge", "start_agent_turn_auto", "take_rate_limit"]) {
      expect(sql, untouched).not.toMatch(new RegExp(`function\\s+public\\.${untouched}\\b`, "i"));
    }
  });

  it("트리거는 bridges에 하나, select 열 권한은 device_name 하나, 지표 표를 건드리지 않는다", () => {
    expect([...sql.matchAll(/create trigger\s+(\w+)\s+(?:before|after)\s+update of status on\s+(\S+)/gi)].map((m) => [m[1], m[2]])).toEqual([["bridges_clear_device_name", "public.bridges"]]);
    expect([...sql.matchAll(/grant select\s*\(([^)]*)\)\s*on\s+(\S+)\s+to\s+(\w+)/gi)].map((m) => [m[1].trim(), m[2], m[3]])).toEqual([["device_name", "public.bridges", "authenticated"]]);
    expect(sql).not.toMatch(/metric_events/i);
    expect(sql).not.toMatch(/\b(insert|delete)\s+(into|from)\b/i);
  });
});
