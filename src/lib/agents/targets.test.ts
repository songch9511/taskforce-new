import { describe, expect, it } from "vitest";

import { assistantTargetsResponseSchema, assistantTargetsWithDeviceResponseSchema } from "@/lib/api/contract";

import { fakeAdmin } from "./fake-admin";
import { AGENT_REGISTRY } from "./registry";
import { BRIDGE_STALE_SECONDS, listAssistantTargets, resolveAgentTarget } from "./targets";

const USER = "10000000-0000-4000-8000-000000000001";
const OTHER = "20000000-0000-4000-8000-000000000002";
const NOW = new Date("2026-10-14T12:00:00.000Z");
const CODEX = { AGENT_BETA_USER_IDS: USER, CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true" };
const BOTH = { AGENT_BETA_USER_IDS: USER, CONVERSATIONS_V2_ENABLED: "true", AGENT_ADAPTER_CODEX_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" };
const id = (n: number) => `c0000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const secondsAgo = (n: number) => new Date(NOW.getTime() - n * 1000).toISOString();

type Tables = Record<string, Record<string, unknown>[]>;
function world(options: { connections?: Record<string, unknown>[]; bridges?: Record<string, unknown>[]; policy?: string | null } = {}) {
  const tables: Tables = {
    agent_connections: options.connections ?? [],
    bridges: options.bridges ?? [],
    execution_policies: options.policy ? [{ user_id: USER, mode: options.policy }] : [],
  };
  return fakeAdmin({ tables });
}
const connection = (n: number, adapter: string, extra: Record<string, unknown> = {}) => ({
  id: id(n), user_id: USER, adapter, status: "active", bridge_id: id(100 + n), created_at: `2026-10-0${n}T00:00:00Z`, ...extra,
});
const bridge = (n: number, extra: Record<string, unknown> = {}) => ({ id: id(100 + n), user_id: USER, status: "active", last_heartbeat_at: secondsAgo(10), ...extra });

describe("resolveAgentTarget (turns.ts startNextQueuedTurn과 같은 규칙: 등록된 adapter · 정책 mode · 연결 상태)", () => {
  it("연결이 없거나 남의 연결이면 null", async () => {
    const fake = world({ connections: [connection(1, "agent:codex", { user_id: OTHER })] });
    expect(await resolveAgentTarget(fake.admin, USER, id(1), CODEX)).toBeNull();
    expect(await resolveAgentTarget(fake.admin, USER, id(9), CODEX)).toBeNull();
  });

  it("registry에 없는 adapter 연결은 null (등록하지 않은 에이전트는 대상이 아니다)", async () => {
    const fake = world({ connections: [connection(1, "agent:cursor")] });
    expect(await resolveAgentTarget(fake.admin, USER, id(1), { ...CODEX })).toBeNull();
  });

  it("registry capability · 정책 mode(없으면 manual) · adapter gate · 연결 상태를 돌려준다", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], policy: "auto" });
    expect(await resolveAgentTarget(fake.admin, USER, id(1), CODEX)).toEqual({
      adapter: "agent:codex", capability: AGENT_REGISTRY["agent:codex"], mode: "auto", connectionStatus: "active", enabled: true,
    });
    const noPolicy = world({ connections: [connection(1, "agent:codex")] });
    expect(await resolveAgentTarget(noPolicy.admin, USER, id(1), {})).toMatchObject({ mode: "manual", enabled: false });
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });

  it.each(["error", "revoked"])("연결 상태 %s는 not_connected로 본다 (active만 active)", async (status) => {
    const fake = world({ connections: [connection(1, "agent:codex", { status })] });
    expect(await resolveAgentTarget(fake.admin, USER, id(1), CODEX)).toMatchObject({ connectionStatus: "not_connected" });
  });

  it("모르는 정책 mode는 던진다 (fail closed)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], policy: "wild" });
    await expect(resolveAgentTarget(fake.admin, USER, id(1), CODEX)).rejects.toThrow();
  });
});

describe("listAssistantTargets (R15, OD-20)", () => {
  const list = (fake: ReturnType<typeof world>, env: Record<string, string>) => listAssistantTargets(fake.admin, USER, env, NOW);
  const agentRows = (targets: Awaited<ReturnType<typeof listAssistantTargets>>) => targets.filter((target) => target.kind === "agent");

  it("플래그가 모두 꺼져 있으면 [taskforce]뿐이다. 연결이 있어도 켜지지 않은 adapter는 빠진다", async () => {
    const fake = world({ connections: [connection(1, "agent:codex"), connection(2, "agent:claude-code")], bridges: [bridge(1), bridge(2)] });
    expect(await list(fake, {})).toEqual([{ kind: "taskforce" }]);
  });

  it("taskforce가 먼저, 그다음 registry 순서(claude-code · codex). 연결이 없으면 not_connected 한 행 (connection_id null)", async () => {
    const fake = world();
    expect(await list(fake, BOTH)).toEqual([
      { kind: "taskforce" },
      { kind: "agent", adapter: "agent:claude-code", display_name: "Claude Code", connection_id: null, state: "not_connected", access: "write", device_name: null, bridge_id: null },
      { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: null, state: "not_connected", access: "read_only", device_name: null, bridge_id: null },
    ]);
  });

  it("Codex(플래그 켬 · 연결 active · heartbeat 새것)는 ready/read_only, Claude Code는 ready/write (R1 증거로 승격된 registry, 정책 mode 기본 manual)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex"), connection(2, "agent:claude-code")], bridges: [bridge(1), bridge(2)] });
    expect(await list(fake, BOTH)).toEqual([
      { kind: "taskforce" },
      { kind: "agent", adapter: "agent:claude-code", display_name: "Claude Code", connection_id: id(2), state: "ready", access: "write", device_name: null, bridge_id: id(102) },
      { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: id(1), state: "ready", access: "read_only", device_name: null, bridge_id: id(101) },
    ]);
  });

  it("Claude Code의 등급은 정책 mode와 registry 증거를 따른다: manual · auto · full 모두 write이고, 증거 하나가 빠지면 그 등급만 닫힌다", async () => {
    for (const policy of ["manual", "auto", "full"]) {
      const fake = world({ connections: [connection(2, "agent:claude-code")], bridges: [bridge(2)], policy });
      expect(agentRows(await list(fake, BOTH)).find((row) => row.adapter === "agent:claude-code")).toMatchObject({ state: "ready", access: "write" });
    }
    const claude = AGENT_REGISTRY["agent:claude-code"];
    const saved = claude.enforcement.target_scope.verified;
    claude.enforcement.target_scope.verified = false;
    try {
      const rows = async (policy: string) => agentRows(await list(world({ connections: [connection(2, "agent:claude-code")], bridges: [bridge(2)], policy }), BOTH)).find((row) => row.adapter === "agent:claude-code");
      expect(await rows("manual")).toMatchObject({ state: "ready", access: "write" });
      expect(await rows("auto")).toMatchObject({ state: "ready", access: "read_only" });
      expect(await rows("full")).toMatchObject({ state: "ready", access: "read_only" });
    } finally {
      claude.enforcement.target_scope.verified = saved;
    }
  });

  it("응답은 assistantTargetsWithDeviceResponseSchema를 지킨다 (F1s 전 스키마는 새 키를 strict로 거절한다)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1, { device_name: "Studio" })] });
    const targets = await list(fake, BOTH);
    expect(assistantTargetsWithDeviceResponseSchema.safeParse({ targets }).success).toBe(true);
    expect(assistantTargetsResponseSchema.safeParse({ targets }).success).toBe(false);
  });

  it(`heartbeat가 ${BRIDGE_STALE_SECONDS}초를 넘었거나 없으면 unreachable (정확히 ${BRIDGE_STALE_SECONDS}초는 아직 ready)`, async () => {
    for (const [heartbeat, state] of [[secondsAgo(BRIDGE_STALE_SECONDS), "ready"], [secondsAgo(BRIDGE_STALE_SECONDS + 1), "unreachable"], [null, "unreachable"]] as const) {
      const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1, { last_heartbeat_at: heartbeat })] });
      expect(agentRows(await list(fake, CODEX))[0], String(heartbeat)).toMatchObject({ state, connection_id: id(1) });
    }
  });

  it("bridge가 없거나(bridge_id null · 행 없음) revoked이면 not_connected, 연결 상태 error도 not_connected", async () => {
    const cases: [Record<string, unknown>[], Record<string, unknown>[]][] = [
      [[connection(1, "agent:codex", { bridge_id: null })], []],
      [[connection(1, "agent:codex")], []],
      [[connection(1, "agent:codex")], [bridge(1, { status: "revoked" })]],
      [[connection(1, "agent:codex", { status: "error" })], [bridge(1)]],
    ];
    for (const [connections, bridges] of cases) {
      const fake = world({ connections, bridges });
      expect(agentRows(await list(fake, CODEX))[0]).toMatchObject({ state: "not_connected", connection_id: id(1) });
    }
  });

  it("내 연결이 가리키는 bridge가 남의 것이면 보이지 않는다 (사용자 id로 좁힌다): not_connected", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1, { user_id: OTHER })] });
    expect(agentRows(await list(fake, CODEX))[0]).toMatchObject({ connection_id: id(1), state: "not_connected" });
  });

  it("revoked 연결은 행이 아니다: 그것뿐이면 연결 없음(not_connected, connection_id null)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex", { status: "revoked" })], bridges: [bridge(1)] });
    expect(agentRows(await list(fake, CODEX))).toEqual([{ kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: null, state: "not_connected", access: "read_only", device_name: null, bridge_id: null }]);
  });

  it("연결이 둘이면 행이 둘 (만든 순서). 연결이 있는 adapter에는 not_connected 행을 따로 더하지 않는다", async () => {
    const fake = world({ connections: [connection(2, "agent:codex"), connection(1, "agent:codex", { status: "error" })], bridges: [bridge(1), bridge(2)] });
    const rows = agentRows(await list(fake, CODEX));
    expect(rows.map((row) => [row.connection_id, row.state])).toEqual([[id(1), "not_connected"], [id(2), "ready"]]);
  });

  it("registry 밖 adapter의 연결은 행이 되지 않는다 (그 adapter의 연결로 세지도 않는다)", async () => {
    const fake = world({ connections: [connection(1, "agent:cursor"), connection(2, "agent:codex")], bridges: [bridge(1), bridge(2)] });
    const rows = agentRows(await list(fake, CODEX));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ adapter: "agent:codex", connection_id: id(2), state: "ready" });
  });

  it("남의 연결 · 남의 bridge는 보지 않는다 (사용자 id로 좁힌다)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex", { user_id: OTHER })], bridges: [bridge(1)] });
    expect(agentRows(await list(fake, CODEX))[0]).toMatchObject({ connection_id: null, state: "not_connected" });
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });

  it("access는 registry · 정책 mode로 계산한다 (쓰기 gate가 닫혀 있어 write가 나오지 않는다)", async () => {
    for (const policy of ["manual", "auto", "full"]) {
      const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1)], policy });
      expect(agentRows(await list(fake, CODEX))[0]).toMatchObject({ state: "ready", access: "read_only" });
    }
  });

  it("쓰기만 한다면: 읽기만 한다 (쓰기 0)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1)] });
    await list(fake, CODEX);
    expect(fake.calls.filter((call) => call.kind !== "select")).toEqual([]);
  });
});

// ─── F1s: 기기 이름 · bridge_id (계약 3.4) ───
describe("listAssistantTargets device_name · bridge_id (F1s C4)", () => {
  const list = (fake: ReturnType<typeof world>, env: Record<string, string>) => listAssistantTargets(fake.admin, USER, env, NOW);
  const agentRows = (targets: Awaited<ReturnType<typeof listAssistantTargets>>) => targets.filter((target) => target.kind === "agent");

  it("연결 행마다 그 연결 bridge의 device_name · bridge_id를 낸다 (같은 adapter 연결 둘 → 이름 둘)", async () => {
    const fake = world({
      connections: [connection(1, "agent:codex"), connection(2, "agent:codex")],
      bridges: [bridge(1, { device_name: "Studio" }), bridge(2, { device_name: "Test Mac" })],
    });
    const rows = agentRows(await list(fake, CODEX));
    expect(rows.map((row) => [row.connection_id, row.device_name, row.bridge_id])).toEqual([[id(1), "Studio", id(101)], [id(2), "Test Mac", id(102)]]);
    expect(assistantTargetsWithDeviceResponseSchema.safeParse({ targets: [{ kind: "taskforce" }, ...rows] }).success).toBe(true);
  });

  it("bridge가 이름을 아직 보내지 않았으면(옛 Mac) device_name은 null이고 bridge_id는 그대로다", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1, { device_name: null })] });
    expect(agentRows(await list(fake, CODEX))[0]).toMatchObject({ connection_id: id(1), state: "ready", device_name: null, bridge_id: id(101) });
  });

  it("연결 없는 행은 둘 다 null이다", async () => {
    const fake = world({ bridges: [bridge(1, { device_name: "Studio" })] });
    expect(agentRows(await list(fake, BOTH))).toEqual([
      expect.objectContaining({ adapter: "agent:claude-code", connection_id: null, device_name: null, bridge_id: null }),
      expect.objectContaining({ adapter: "agent:codex", connection_id: null, device_name: null, bridge_id: null }),
    ]);
  });

  it("bridge 행이 없으면(지워짐 · bridge_id null) 이름은 null이고, bridge_id는 연결 값 그대로다", async () => {
    const gone = world({ connections: [connection(1, "agent:codex")], bridges: [] });
    expect(agentRows(await list(gone, CODEX))[0]).toMatchObject({ state: "not_connected", device_name: null, bridge_id: id(101) });
    const unset = world({ connections: [connection(1, "agent:codex", { bridge_id: null })], bridges: [] });
    expect(agentRows(await list(unset, CODEX))[0]).toMatchObject({ state: "not_connected", device_name: null, bridge_id: null });
  });

  it("남의 bridge의 이름은 내지 않는다 (사용자 id로 좁힌다)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1, { user_id: OTHER, device_name: "Studio" })] });
    expect(agentRows(await list(fake, CODEX))[0]).toMatchObject({ device_name: null, bridge_id: id(101) });
    for (const call of fake.calls) expect(call.filters).toContainEqual(["user_id", "eq", USER]);
  });

  it("bridges는 device_name 열까지 골라 읽는다", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1, { device_name: "Studio" })] });
    await list(fake, CODEX);
    expect(fake.calls.filter((call) => call.target === "bridges" && call.kind === "select")).toHaveLength(1);
    expect(agentRows(await list(fake, CODEX))[0]).toMatchObject({ device_name: "Studio" });
  });

  it("이름은 상태 계산에 쓰지 않는다: 이름이 있든 없든 상태 · 순서가 같다", async () => {
    const cases: Record<string, unknown>[] = [{ last_heartbeat_at: secondsAgo(10) }, { last_heartbeat_at: secondsAgo(BRIDGE_STALE_SECONDS + 1) }, { last_heartbeat_at: null }, { status: "revoked" }];
    for (const extra of cases) {
      const plain = world({ connections: [connection(1, "agent:codex"), connection(2, "agent:claude-code")], bridges: [bridge(1, extra), bridge(2, extra)] });
      const named = world({ connections: [connection(1, "agent:codex"), connection(2, "agent:claude-code")], bridges: [bridge(1, { ...extra, device_name: "Studio" }), bridge(2, { ...extra, device_name: "Studio" })] });
      const strip = (targets: Awaited<ReturnType<typeof listAssistantTargets>>) => targets.map((target) => (target.kind === "agent" ? { ...target, device_name: null } : target));
      expect(strip(await list(named, BOTH)), JSON.stringify(extra)).toEqual(strip(await list(plain, BOTH)));
    }
  });

  it("쓰기 0: 이름을 읽기만 한다", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1, { device_name: "Studio" })] });
    await list(fake, CODEX);
    expect(fake.calls.filter((call) => call.kind !== "select")).toEqual([]);
  });
});
