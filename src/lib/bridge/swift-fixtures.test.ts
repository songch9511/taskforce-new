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

  it("covers every fixture file", () => {
    expect(readdirSync(dir).sort()).toEqual(["ack.json", "commands.json", "events.json", "heartbeat.json", "register.json", "revoke.json"]);
  });
});
