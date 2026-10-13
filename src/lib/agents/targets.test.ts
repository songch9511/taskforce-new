import { describe, expect, it } from "vitest";

import { assistantTargetsResponseSchema } from "@/lib/api/contract";

import { fakeAdmin } from "./fake-admin";
import { AGENT_REGISTRY } from "./registry";
import { BRIDGE_STALE_SECONDS, listAssistantTargets, resolveAgentTarget } from "./targets";

const USER = "10000000-0000-4000-8000-000000000001";
const OTHER = "20000000-0000-4000-8000-000000000002";
const NOW = new Date("2026-10-14T12:00:00.000Z");
const CODEX = { AGENT_ADAPTER_CODEX_ENABLED: "true" };
const BOTH = { AGENT_ADAPTER_CODEX_ENABLED: "true", AGENT_ADAPTER_CLAUDE_CODE_ENABLED: "true" };
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
      { kind: "agent", adapter: "agent:claude-code", display_name: "Claude Code", connection_id: null, state: "not_connected", access: null },
      { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: null, state: "not_connected", access: "read_only" },
    ]);
  });

  it("Codex(플래그 켬 · 연결 active · heartbeat 새것)는 ready/read_only, Claude Code는 unsupported/null (초기 registry)", async () => {
    const fake = world({ connections: [connection(1, "agent:codex"), connection(2, "agent:claude-code")], bridges: [bridge(1), bridge(2)] });
    expect(await list(fake, BOTH)).toEqual([
      { kind: "taskforce" },
      { kind: "agent", adapter: "agent:claude-code", display_name: "Claude Code", connection_id: id(2), state: "unsupported", access: null },
      { kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: id(1), state: "ready", access: "read_only" },
    ]);
  });

  it("응답은 assistantTargetsResponseSchema를 지킨다", async () => {
    const fake = world({ connections: [connection(1, "agent:codex")], bridges: [bridge(1)] });
    expect(assistantTargetsResponseSchema.safeParse({ targets: await list(fake, BOTH) }).success).toBe(true);
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
    expect(agentRows(await list(fake, CODEX))).toEqual([{ kind: "agent", adapter: "agent:codex", display_name: "Codex", connection_id: null, state: "not_connected", access: "read_only" }]);
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
