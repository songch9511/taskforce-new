import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { z } from "zod";
import {
  bridgeV1AckRequestSchema,
  bridgeV1AckResponseSchema,
  bridgeV1CommandsResponseSchema,
  bridgeV1EventSchema,
  bridgeV1EventsRequestSchema,
  bridgeV1EventsResponseSchema,
  bridgeV1HeartbeatRequestSchema,
  bridgeV1HeartbeatResponseSchema,
  bridgeV1RegisterRequestSchema,
  bridgeV1RegisterResponseSchema,
  bridgeV1RevokeRequestSchema,
  bridgeV1RevokeResponseSchema,
} from "@/lib/api/contract";

// OA D2b Q13: Swift 시험(TaskforceKitTests/BridgeV1ContractsTests)이 읽는 같은 JSON 파일을 서버 zod 스키마로 parse한다.
// Swift는 요청 파일과 같은 키 집합을 내보내야 하고(strictObject), 응답 파일은 서버가 실제로 줄 수 있는 모양이어야 한다.
const dir = path.resolve(import.meta.dirname, "../../../apple/Packages/TaskforceKit/Tests/TaskforceKitTests/Fixtures/bridge-v1");
const load = (name: string): Record<string, unknown> => JSON.parse(readFileSync(path.join(dir, `${name}.json`), "utf8"));
const parseEach = (schema: z.ZodType, group: unknown, label: string) => {
  const entries = Object.entries(group as Record<string, unknown>);
  expect(entries.length, `${label} has fixtures`).toBeGreaterThan(0);
  for (const [name, value] of entries) {
    const result = schema.safeParse(value);
    expect(result.success, `${label}.${name}: ${result.success ? "" : JSON.stringify(result.error.issues)}`).toBe(true);
  }
};

describe("Swift fixtures parse with the D2a server schemas", () => {
  it("register", () => {
    const file = load("register");
    parseEach(bridgeV1RegisterRequestSchema, { request: file.request, request_reactivate: file.request_reactivate }, "register request");
    parseEach(bridgeV1RegisterResponseSchema, { response: file.response }, "register response");
  });

  it("revoke", () => {
    const file = load("revoke");
    parseEach(bridgeV1RevokeRequestSchema, { request: file.request }, "revoke request");
    parseEach(bridgeV1RevokeResponseSchema, { response: file.response }, "revoke response");
  });

  it("commands", () => {
    const file = load("commands");
    parseEach(bridgeV1CommandsResponseSchema, file, "commands response");
  });

  it("ack", () => {
    const file = load("ack");
    parseEach(bridgeV1AckRequestSchema, file.requests, "ack request");
    parseEach(bridgeV1AckResponseSchema, file.responses, "ack response");
  });

  it("events", () => {
    const file = load("events");
    parseEach(bridgeV1EventSchema, file.events, "event");
    parseEach(bridgeV1EventsRequestSchema, { request: file.request }, "events request");
    for (const event of (file.request as { events: unknown[] }).events) expect(bridgeV1EventSchema.safeParse(event).success).toBe(true);
    parseEach(bridgeV1EventsResponseSchema, { response: file.response }, "events response");
  });

  it("heartbeat", () => {
    const file = load("heartbeat");
    parseEach(bridgeV1HeartbeatRequestSchema, { request: file.request, request_minimal: file.request_minimal }, "heartbeat request");
    parseEach(bridgeV1HeartbeatResponseSchema, { response: file.response, response_throttled: file.response_throttled }, "heartbeat response");
  });

  // OA D2b 검토 반영 B8: Swift 정리기(OutgoingValues)의 한도는 서버 zod의 한도 그대로여야 한다. 한도는 sanitizer-limits.json 한 파일에 있고,
  // 이 시험이 그 값마다 "한도에서는 받고 한 칸 넘으면 거절"을 서버 스키마로 확인한다 (Swift 쪽은 같은 파일로 자기 상수를 확인한다).
  it("sanitizer limits match the server zod limits", () => {
    const limits = load("sanitizer-limits") as Record<string, number>;
    const base = {
      adapter: "agent:claude-code",
      session_ref: { agent_session_id: "5e551011-0000-4000-8000-000000000001" },
      agent_task_id: "7a5c0001-0000-4000-8000-000000000002",
      event_id: "7a5c0001-0000-4000-8000-000000000002:1",
      turn_seq: 1,
      observed_at: "2026-10-14T05:00:03.123Z",
    };
    const accepts = (event: unknown) => bridgeV1EventSchema.safeParse(event).success;
    const sessionBound = (payload: Record<string, unknown>) => ({ ...base, event_id: "s:1", type: "session_bound", payload });
    const artifact = (payload: Record<string, unknown>) => ({ ...base, type: "artifact", seq: 1, payload });

    // 200자 identity: external_task_id · external_session_id · event_id · 산출물 hash
    const idMax = limits.identity_max_chars;
    expect(accepts({ ...base, seq: 1, type: "progress", external_task_id: "e".repeat(idMax) })).toBe(true);
    expect(accepts({ ...base, seq: 1, type: "progress", external_task_id: "e".repeat(idMax + 1) })).toBe(false);
    expect(accepts({ ...base, seq: 1, type: "progress", external_task_id: "" })).toBe(false);
    expect(accepts(sessionBound({ external_session_id: "x".repeat(idMax) }))).toBe(true);
    expect(accepts(sessionBound({ external_session_id: "x".repeat(idMax + 1) }))).toBe(false);
    expect(accepts(sessionBound({ external_session_id: "pending:1" }))).toBe(false);
    // workspace_ref: 비어 있지 않고 500자까지
    const wsMax = limits.workspace_ref_max_chars;
    expect(accepts(sessionBound({ external_session_id: "x", workspace_ref: "w".repeat(wsMax) }))).toBe(true);
    expect(accepts(sessionBound({ external_session_id: "x", workspace_ref: "w".repeat(wsMax + 1) }))).toBe(false);
    expect(accepts(sessionBound({ external_session_id: "x", workspace_ref: "" }))).toBe(false);
    // 산출물: path 1000 · summary 2000자, payload는 JSONB 글자 모양 4096바이트
    expect(accepts(artifact({ path: "p".repeat(limits.artifact_path_max_chars), hash: "h", summary: "" }))).toBe(true);
    expect(accepts(artifact({ path: "p".repeat(limits.artifact_path_max_chars + 1), hash: "h", summary: "" }))).toBe(false);
    expect(accepts(artifact({ path: "", hash: "h", summary: "" }))).toBe(false);
    expect(accepts(artifact({ path: "p", hash: "h", summary: "s".repeat(limits.artifact_summary_max_chars) }))).toBe(true);
    expect(accepts(artifact({ path: "p", hash: "h", summary: "s".repeat(limits.artifact_summary_max_chars + 1) }))).toBe(false);
    const jsonb = (path: string, hash: string, summary: string) => `{"path": ${JSON.stringify(path)}, "hash": ${JSON.stringify(hash)}, "summary": ${JSON.stringify(summary)}}`;
    const bytes = (text: string) => new TextEncoder().encode(text).length;
    // 3바이트 글자로 payload를 정확히 한도 / 한도 + 1바이트로 맞춘다 (요약 2000자 안에서)
    const summaryFor = (target: number) => "가".repeat(Math.floor(target / 3)) + "s".repeat(target % 3);
    const longPath = "가".repeat(limits.artifact_path_max_chars);
    const summaryRoom = limits.artifact_payload_max_bytes - bytes(jsonb(longPath, "h", ""));
    expect(bytes(jsonb(longPath, "h", summaryFor(summaryRoom)))).toBe(limits.artifact_payload_max_bytes);
    expect(accepts(artifact({ path: longPath, hash: "h", summary: summaryFor(summaryRoom) }))).toBe(true);
    expect(accepts(artifact({ path: longPath, hash: "h", summary: summaryFor(summaryRoom + 1) }))).toBe(false);
    // adapter version 50자
    const register = (version: string) => ({ device_id: "d".repeat(43), app_version: "0.2.0", adapters: [{ adapter: "agent:claude-code", installed: true, version, signed_in: "yes", managed_settings: false }], connect: [], reactivate: false });
    expect(bridgeV1RegisterRequestSchema.safeParse(register("9".repeat(limits.adapter_version_max_chars))).success).toBe(true);
    expect(bridgeV1RegisterRequestSchema.safeParse(register("9".repeat(limits.adapter_version_max_chars + 1))).success).toBe(false);
    // 글 32KB (UTF-8 바이트)
    const message = (text: string) => ({ ...base, seq: 1, type: "message", text });
    expect(accepts(message("a".repeat(limits.text_max_bytes)))).toBe(true);
    expect(accepts(message("a".repeat(limits.text_max_bytes + 1)))).toBe(false);
  });

  it("covers every fixture file", () => {
    expect(readdirSync(dir).sort()).toEqual(["ack.json", "commands.json", "events.json", "heartbeat.json", "register.json", "revoke.json", "sanitizer-limits.json"]);
  });
});
