import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

import type { AgentCapability, AssistantTargetWithDevice } from "@/lib/api/contract";

import { agentAccess, directChat, type AgentPolicyMode } from "./capability";
import { adapterEnabled, AGENT_REGISTRY } from "./registry";

type Env = Record<string, string | undefined>;
export type AgentAdapter = keyof typeof AGENT_REGISTRY;
const ADAPTERS = Object.keys(AGENT_REGISTRY) as AgentAdapter[];
const isAdapter = (value: string): value is AgentAdapter => Object.hasOwn(AGENT_REGISTRY, value);

/** bridge heartbeat는 30초마다 오고 3회 누락이면 unreachable이다 (contract.ts bridge 주석 · 아키텍처 9.1). 그 90초를 넘기면 대상 목록은 unreachable */
export const BRIDGE_STALE_SECONDS = 90;

const modeSchema = z.object({ mode: z.enum(["manual", "auto", "full"]) });

/** 사용자의 실행 정책 mode. 정책 행이 없으면 DB 기본값 manual (turns.ts startNextQueuedTurn과 같다) */
export async function loadPolicyMode(admin: SupabaseClient, userId: string): Promise<AgentPolicyMode> {
  const { data } = await admin.from("execution_policies").select("mode").eq("user_id", userId).maybeSingle().throwOnError();
  return data === null ? "manual" : modeSchema.parse(data).mode;
}

export type ResolvedAgentTarget = {
  adapter: AgentAdapter;
  capability: AgentCapability;
  mode: AgentPolicyMode;
  /** active가 아니면(error · revoked) 전달은 not_sent/not_connected로 기록된다 */
  connectionStatus: "active" | "not_connected";
  /** 서버 adapter gate (OD-2). 꺼져 있으면 에이전트 route는 404 */
  enabled: boolean;
};

/**
 * 대화의 연결을 보내기 입력으로 해석한다: 연결 · registry · 정책 mode · 연결 상태 (turns.ts startNextQueuedTurn의 규칙과 같다).
 * 연결이 없거나 남의 것이거나 registry에 없는 adapter면 null. bridge 상태(heartbeat)는 보지 않는다: 끊김 표시는 D2a (OD-11)
 */
export async function resolveAgentTarget(admin: SupabaseClient, userId: string, connectionId: string, env: Env = process.env): Promise<ResolvedAgentTarget | null> {
  const { data } = await admin.from("agent_connections").select("adapter, status").eq("user_id", userId).eq("id", connectionId).maybeSingle().throwOnError();
  if (!data) return null;
  const connection = z.object({ adapter: z.string(), status: z.enum(["active", "error", "revoked"]) }).parse(data);
  if (!isAdapter(connection.adapter)) return null;
  return {
    adapter: connection.adapter,
    capability: AGENT_REGISTRY[connection.adapter],
    mode: await loadPolicyMode(admin, userId),
    connectionStatus: connection.status === "active" ? "active" : "not_connected",
    enabled: adapterEnabled(connection.adapter, env),
  };
}

type ConnectionRow = { id: string; adapter: string; status: "active" | "error" | "revoked"; bridge_id: string | null; created_at: string };
type BridgeRow = { id: string; status: "active" | "revoked"; last_heartbeat_at: string | null; device_name: string | null };

/**
 * GET /api/v2/assistant/targets (계약 4.5 · OD-20): taskforce 먼저, 그다음 registry 순서(claude-code · codex). 켜지지 않은 adapter와 registry 밖 adapter의 연결은 뺀다.
 * 연결(revoked 제외)마다 한 행, 활성 연결이 없는 adapter는 not_connected 한 행(connection_id null).
 * 상태 순서: error · bridge 없음 · bridge revoked → not_connected / heartbeat 없음 · 90초 넘음 → unreachable / 서버 registry가 직접 대화를 못 하면 → unsupported / 그 밖 ready.
 * access는 registry · 정책 mode로 계산한 등급이다. sign_in_needed는 bridge 사전 점검(D2a)에서 오므로 여기서는 내지 않는다.
 * F1s: 행마다 device_name(그 연결 bridge의 표시용 이름, 모르면 null)과 bridge_id(연결의 bridge, 연결이 없으면 null)를 더한다 — 이름은 상태 계산에 쓰지 않는다
 */
export async function listAssistantTargets(admin: SupabaseClient, userId: string, env: Env = process.env, now: Date = new Date()): Promise<AssistantTargetWithDevice[]> {
  const enabled = ADAPTERS.filter((adapter) => adapterEnabled(adapter, env));
  const targets: AssistantTargetWithDevice[] = [{ kind: "taskforce" }];
  if (!enabled.length) return targets;

  const [{ data: connectionData }, mode] = await Promise.all([
    admin.from("agent_connections").select("id, adapter, status, bridge_id, created_at").eq("user_id", userId).throwOnError(),
    loadPolicyMode(admin, userId),
  ]);
  const connections = ((connectionData ?? []) as ConnectionRow[])
    .filter((row) => row.status !== "revoked" && isAdapter(row.adapter))
    .sort((a, b) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const bridgeIds = [...new Set(connections.map((row) => row.bridge_id).filter((bridgeId): bridgeId is string => bridgeId !== null))];
  const bridges = new Map<string, BridgeRow>();
  if (bridgeIds.length) {
    const { data } = await admin.from("bridges").select("id, status, last_heartbeat_at, device_name").eq("user_id", userId).in("id", bridgeIds).throwOnError();
    for (const row of (data ?? []) as BridgeRow[]) bridges.set(row.id, row);
  }

  const stateOf = (row: ConnectionRow, capability: AgentCapability): Extract<AssistantTargetWithDevice, { kind: "agent" }>["state"] => {
    const bridge = row.bridge_id === null ? undefined : bridges.get(row.bridge_id);
    if (row.status !== "active" || !bridge || bridge.status === "revoked") return "not_connected";
    const heartbeat = bridge.last_heartbeat_at === null ? null : Date.parse(bridge.last_heartbeat_at);
    if (heartbeat === null || Number.isNaN(heartbeat) || now.getTime() - heartbeat > BRIDGE_STALE_SECONDS * 1000) return "unreachable";
    return directChat(capability, mode) === "supported" ? "ready" : "unsupported";
  };

  for (const adapter of enabled) {
    const capability = AGENT_REGISTRY[adapter];
    const base = { kind: "agent" as const, adapter, display_name: capability.display_name ?? adapter, access: agentAccess(capability, mode) };
    const own = connections.filter((row) => row.adapter === adapter);
    if (!own.length) targets.push({ ...base, connection_id: null, state: "not_connected", device_name: null, bridge_id: null });
    for (const row of own) {
      const bridge = row.bridge_id === null ? undefined : bridges.get(row.bridge_id);
      targets.push({ ...base, connection_id: row.id, state: stateOf(row, capability), device_name: bridge?.device_name ?? null, bridge_id: row.bridge_id });
    }
  }
  return targets;
}
